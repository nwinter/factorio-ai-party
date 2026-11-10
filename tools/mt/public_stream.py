#!/usr/bin/env python3
"""Public stream staging (never starts OBS streaming or a YouTube broadcast).

  python3 tools/mt/public_stream.py start RUN
  python3 tools/mt/public_stream.py status RUN
  python3 tools/mt/public_stream.py stop RUN

Requires the run's per-team services and op/streams.txt. POG_MT_PUBLIC_PORT=8790,
POG_MT_PUBLIC_DWELL=30, POG_MT_YOUTUBE=VIDEO_ID (optional display-only chat).
One supervisor owns its SSH children, pogwin camera task and OBS recording. An
exclusive machine-local lock prevents two checkouts competing for the camera.
"""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / 'stream'))
from obsws import OBS
from public_overlay import PublicOverlay, CAMERA
from udp_bridge import Bridge

SCENE = 'mt-stream'
REMOTE = 'D:/pog/mt-stream21' if os.environ.get('MT_EXPECT_VERSION') == '2.1.24' else 'D:/pog/mt-stream'
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=no', '-o', 'ControlPath=none']
LOCK = Path.home() / '.local/state/pog/mt-public.lock'


def write(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2) + '\n')
    tmp.replace(path)


def powershell(script):
    return SSH + ['pogwin', 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' +
                  base64.b64encode(('$ProgressPreference="SilentlyContinue"; ' + script).encode('utf-16le')).decode()]


def checked(args, **kw):
    return subprocess.run(args, check=True, timeout=120, **kw)


def remote_camera(action):
    return checked(powershell(f"& '{REMOTE}/public-camera.ps1' -Action {action} -Version {os.environ.get('MT_EXPECT_VERSION', '2.0.77')}"), capture_output=True, text=True)


def stage():
    checked(powershell(f"New-Item -ItemType Directory -Force '{REMOTE}/client/mods' | Out-Null"))
    for name in ('public-camera.ps1', 'bridge.ps1'):
        checked(['scp', '-q', str(HERE / name), f'pogwin:{REMOTE}/{name}'])
    # Copy the running server's on-disk mods, not a different branch's runtime.
    with tempfile.TemporaryDirectory(prefix='mt-stream-mods-') as tmp:
        checked(['scp', '-q', '-r', f"imac.local:{os.environ.get('MT_DIR', '/Users/owner/pog-mt')}/mods", tmp])
        checked(['scp', '-q', '-r', tmp + '/mods/.', f'pogwin:{REMOTE}/client/mods/'])


def setup_obs(obs, url, receipt):
    if obs.call('GetStreamStatus')['outputActive']:
        raise RuntimeError('OBS is streaming; public staging requires it offline')
    receipt['previous_scene'] = obs.call('GetCurrentProgramScene')['currentProgramSceneName']
    receipt['record_was_active'] = obs.call('GetRecordStatus')['outputActive']
    scenes = [s['sceneName'] for s in obs.call('GetSceneList')['scenes']]
    if SCENE not in scenes:
        obs.call('CreateScene', {'sceneName': SCENE})
    specs = [
        ('mt background', 'color_source_v3', {'color': 0xff201810, 'width': 1920, 'height': 1080}, (0, 0, 1920, 1080)),
        ('mt camera', 'game_capture', {'capture_mode': 'window', 'window': f"Factorio {os.environ.get('MT_EXPECT_VERSION', '2.0.77')}:Factorio:factorio-mtcam.exe",
                                     'priority': 2, 'capture_cursor': False, 'allow_transparency': False}, (0, 72, 1440, 810)),
        ('mt overlay', 'browser_source', {'url': url, 'width': 1920, 'height': 1080, 'fps': 30,
                                        'shutdown': False, 'restart_when_active': True}, (0, 0, 1920, 1080))]
    names = [i['inputName'] for i in obs.call('GetInputList')['inputs']]
    for order, (name, kind, settings, rect) in enumerate(specs):
        if name in names:
            obs.call('SetInputSettings', {'inputName': name, 'inputSettings': settings, 'overlay': True})
            items = obs.call('GetSceneItemList', {'sceneName': SCENE})['sceneItems']
            if name not in [i['sourceName'] for i in items]:
                obs.call('CreateSceneItem', {'sceneName': SCENE, 'sourceName': name, 'sceneItemEnabled': True})
        else:
            obs.call('CreateInput', {'sceneName': SCENE, 'inputName': name, 'inputKind': kind,
                                     'inputSettings': settings, 'sceneItemEnabled': True})
        item = obs.call('GetSceneItemId', {'sceneName': SCENE, 'sourceName': name})['sceneItemId']
        x, y, w, h = rect
        obs.call('SetSceneItemTransform', {'sceneName': SCENE, 'sceneItemId': item, 'sceneItemTransform': {
            'positionX': x, 'positionY': y, 'boundsType': 'OBS_BOUNDS_SCALE_INNER',
            'boundsWidth': w, 'boundsHeight': h, 'alignment': 5, 'boundsAlignment': 0,
            'cropLeft': 0, 'cropRight': 0, 'cropTop': 0, 'cropBottom': 0}})
        obs.call('SetSceneItemEnabled', {'sceneName': SCENE, 'sceneItemId': item, 'sceneItemEnabled': True})
        obs.call('SetSceneItemIndex', {'sceneName': SCENE, 'sceneItemId': item, 'sceneItemIndex': order})
    obs.call('SetCurrentProgramScene', {'sceneName': SCENE})
    if not receipt['record_was_active']:
        # Mark before the request, so a lost response still gets cleanup.
        receipt['record_started'] = True
        obs.call('StartRecord')
    # OBS acknowledges StartRecord before the encoder has opened the file.
    for _ in range(30):
        if obs.call('GetRecordStatus')['outputActive']:
            break
        time.sleep(.5)
    else:
        raise RuntimeError('OBS recording failed to start within 15s')


def restore_obs(obs, receipt):
    # If an operator deliberately went live after staging, stop must not blank
    # that program or silently end the broadcast. Stop OBS streaming manually
    # before stopping this run; stop() enforces that before signalling us.
    if obs.call('GetStreamStatus')['outputActive']:
        print('OBS is live: leaving program and recording unchanged', flush=True)
        return
    if receipt.get('record_started') and obs.call('GetRecordStatus')['outputActive']:
        result = obs.call('StopRecord')
        receipt['recording'] = result.get('outputPath')
        for _ in range(30):
            if not obs.call('GetRecordStatus')['outputActive']:
                break
            time.sleep(.5)
        else:
            raise RuntimeError('OBS recording did not finish stopping within 15s')
    receipt['recording_active'] = obs.call('GetRecordStatus')['outputActive']
    if receipt.get('previous_scene') and obs.call('GetCurrentProgramScene')['currentProgramSceneName'] == SCENE:
        obs.call('SetCurrentProgramScene', {'sceneName': receipt['previous_scene']})


def supervise(op, run):
    if os.environ.get('POG_TEST') == '1':
        raise RuntimeError('POG_TEST=1: no remote public stream setup')
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    lock = LOCK.open('a+')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    statefile = op / 'public-stream.json'
    receipt = {'pid': os.getpid(), 'run': run, 'root': str(ROOT), 'phase': 'starting', 'started': time.time()}
    write(statefile, receipt)
    children, bridge, overlay, obs, camera_started = [], None, None, None, False
    try:
        tree = Path((op / 'launch-tree').read_text().strip())
        port = int(os.environ.get('POG_MT_PUBLIC_PORT', '8790'))
        if port in range(8791, 8801) or not 1024 <= port <= 65535:
            raise ValueError('public port must avoid per-team ports 8791..8800')
        dwell = float(os.environ.get('POG_MT_PUBLIC_DWELL', '30'))
        if not 10 <= dwell <= 300:
            raise ValueError('camera dwell must be 10..300 seconds')
        bridge = Bridge()
        bridge.start()
        overlay = PublicOverlay(op, tree, run, port, dwell, os.environ.get('POG_MT_YOUTUBE'))
        overlay.start()
        tunnel_args = SSH + ['-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=10',
                            '-o', 'ServerAliveCountMax=3', '-R', f'127.0.0.1:{port}:127.0.0.1:{port}',
                            '-R', '127.0.0.1:34478:127.0.0.1:34478', '-L', '127.0.0.1:4458:127.0.0.1:4455', 'pogwin']
        tunnel = subprocess.Popen(tunnel_args)
        children.append(tunnel)
        obs = OBS(port=4458)
        for _ in range(40):
            if tunnel.poll() is not None or stop.is_set():
                raise RuntimeError('tunnel failed or startup cancelled')
            try:
                obs.call('GetVersion')
                break
            except Exception:
                stop.wait(.5)
        if obs.call('GetStreamStatus')['outputActive']:
            raise RuntimeError('OBS is streaming; staging refused')
        stage()
        if stop.is_set():
            raise RuntimeError('startup cancelled')
        if remote_camera('status').stdout.strip():
            raise RuntimeError('an earlier mt camera still exists; stop its owning run before starting')
        relay = subprocess.Popen(powershell(f"& '{REMOTE}/bridge.ps1'"))
        children.append(relay)
        # The bridge's C# compilation finishes before the client needs UDP.
        camera_started = True  # includes a partially started task
        print(remote_camera('start').stdout, flush=True)
        deadline = time.monotonic() + 240
        h = next(iter(overlay.harnesses.values()))
        while time.monotonic() < deadline:
            if stop.is_set() or relay.poll() is not None or tunnel.poll() is not None:
                raise RuntimeError('camera startup interrupted or bridge exited')
            connected = h.lua(f"local p=game.get_player('{CAMERA}') rcon.print(helpers.table_to_json{{connected=p and p.connected or false}})")
            if connected.get('connected') and overlay.state.get('camera'):
                break
            stop.wait(2)
        else:
            raise RuntimeError('camera did not join and frame a team within 240s; inspect pogwin camera log')
        setup_obs(obs, f'http://127.0.0.1:{port}/', receipt)
        receipt.update(phase='ready', overlay=f'http://127.0.0.1:{port}/', camera=CAMERA, scene=SCENE,
                       streaming=False, recording_active=True)
        write(statefile, receipt)
        print('READY: public overlay, one camera, mt-stream scene, recording; OBS streaming is OFF', flush=True)
        while not stop.wait(2):
            if tunnel.poll() is not None or relay.poll() is not None:
                raise RuntimeError('public SSH/UDP connection lost; stop and start public stream to reconnect')
    except Exception as e:
        receipt.update(phase='failed', error=str(e))
        print(f'public stream failed: {e}', flush=True)
    finally:
        if overlay:
            overlay.close()
        if obs and receipt.get('previous_scene'):
            try:
                restore_obs(obs, receipt)
            except Exception as e:
                receipt['cleanup_error'] = f'OBS cleanup: {e}'
        if camera_started:
            try:
                remote_camera('stop')
            except Exception as e:
                receipt['cleanup_camera_error'] = str(e)
        # Closing the TCP server's client requires closing the SSH tunnel. Its
        # EOF ends the remote bridge, before its owning SSH child is terminated.
        for child in children:
            child.terminate() if child.poll() is None else None
        for child in children:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if bridge:
            bridge.shutdown()
            bridge.server_close()
        if obs:
            obs.close()
        if receipt['phase'] != 'failed':
            receipt['phase'] = 'stopped'
        receipt['stopped'] = time.time()
        write(statefile, receipt)
        lock.close()


def owned(receipt, run):
    if receipt.get('run') != run or receipt.get('root') != str(ROOT):
        return False
    pid = receipt.get('pid')
    if not isinstance(pid, int) or pid <= 1:
        return False
    ps = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
    return f'{HERE / "public_stream.py"} run {run}' in ps


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['start', 'run', 'stop', 'status'])
    ap.add_argument('run')
    a = ap.parse_args()
    import re
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', a.run):
        ap.error('RUN must be a plain run ID')
    op = ROOT / 'runs' / a.run / 'op'
    if not op.is_dir():
        ap.error(f'no operator run directory: {op}')
    path = op / 'public-stream.json'
    receipt = json.loads(path.read_text()) if path.exists() else {}
    if a.command == 'status':
        print(json.dumps(dict(receipt, running=owned(receipt, a.run)), indent=2))
    elif a.command == 'run':
        supervise(op, a.run)
    elif a.command == 'stop':
        if owned(receipt, a.run):
            obs = OBS(port=4458)
            try:
                if obs.call('GetStreamStatus')['outputActive']:
                    raise SystemExit('OBS is live: stop OBS streaming before stopping the public run')
            except (OSError, RuntimeError):
                pass  # a broken tunnel still needs cleanup
            finally:
                obs.close()
            os.kill(receipt['pid'], signal.SIGTERM)
            for _ in range(80):
                if not owned(receipt, a.run):
                    break
                time.sleep(.5)
            else:
                raise SystemExit('public stream cleanup still running; inspect public-stream.log')
        final = json.loads(path.read_text()) if path.exists() else {}
        if final.get('cleanup_error') or final.get('cleanup_camera_error'):
            raise SystemExit(f'public supervisor exited with cleanup errors; inspect {path}')
        print('public stream stopped (only its owned processes)')
    else:
        if owned(receipt, a.run):
            raise SystemExit('public stream already running; use status')
        with (op / 'public-stream.log').open('a') as log:
            child = subprocess.Popen([sys.executable, str(HERE / 'public_stream.py'), 'run', a.run],
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(360):
            if path.exists():
                state = json.loads(path.read_text())
                if state.get('pid') == child.pid and state.get('phase') in ('ready', 'failed'):
                    print(json.dumps(state, indent=2))
                    if state['phase'] == 'failed':
                        raise SystemExit(1)
                    return
            if child.poll() is not None:
                raise SystemExit(f'public setup exited; see {op / "public-stream.log"}')
            time.sleep(1)
        child.terminate()
        raise SystemExit(f'public setup timed out; see {op / "public-stream.log"}')


if __name__ == '__main__':
    main()
