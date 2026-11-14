#!/usr/bin/env python3
"""Public stream staging (never starts OBS streaming or a YouTube broadcast).

  python3 tools/mt/public_stream.py start RUN
  python3 tools/mt/public_stream.py status RUN
  python3 tools/mt/public_stream.py stop RUN

Requires the run's per-team services and op/streams.txt. POG_MT_PUBLIC_PORT=8790,
POG_MT_PUBLIC_DWELL=30, POG_MT_YOUTUBE=VIDEO_ID (operator/display-only chat).
The existing music slot D:\\pog\\music\\bed.mp3 must exist. POG_MT_TTS defaults
to eleven-fast; a failed cloud voice falls back to the main stream's local say.
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
from public_overlay import PublicOverlay, CAMERA, CAMERA_RECT
from udp_bridge import Bridge
from obs_audio import setup_audio, MUSIC_FILE
from stream_recovery import Recovery, FrameProgress, require, terminate, recording_space_ok
from run_state import pinned

SCENE = 'mt-stream'
REMOTE = 'D:/pog/mt-stream21' if os.environ.get('MT_EXPECT_VERSION') == '2.1.24' else 'D:/pog/mt-stream'
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=no', '-o', 'ControlPath=none']
LOCK = Path.home() / '.local/state/pog/mt-public.lock'
SPLIT_SETTINGS = {'RecSplitFile':'true', 'RecSplitFileType':'Time', 'RecSplitFileTime':'15'}


def write(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2) + '\n')
    tmp.replace(path)


def powershell(script):
    return SSH + ['pogwin', 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' +
                  base64.b64encode(('$ProgressPreference="SilentlyContinue"; ' + script).encode('utf-16le')).decode()]


def checked(args, **kw):
    return subprocess.run(args, check=True, timeout=kw.pop('timeout',120), **kw)


def remote_camera(action):
    return checked(powershell(f"& '{REMOTE}/public-camera.ps1' -Action {action} -Version {os.environ.get('MT_EXPECT_VERSION', '2.0.77')}"), capture_output=True, text=True)


def stage():
    checked(powershell(f"New-Item -ItemType Directory -Force '{REMOTE}/client/mods' | Out-Null"))
    for name in ('public-camera.ps1', 'bridge.ps1'):
        checked(['scp', '-q', str(HERE / name), f'pogwin:{REMOTE}/{name}'])
    checked(['scp', '-q', str(HERE.parent/'win/obs-restart.ps1'), f'pogwin:{REMOTE}/obs-restart.ps1'])
    # Copy the running server's on-disk mods, not a different branch's runtime.
    with tempfile.TemporaryDirectory(prefix='mt-stream-mods-') as tmp:
        checked(['scp', '-q', '-r', f"imac.local:{os.environ.get('MT_DIR', '/Users/owner/pog-mt')}/mods", tmp])
        checked(['scp', '-q', '-r', tmp + '/mods/.', f'pogwin:{REMOTE}/client/mods/'])


def setup_obs(obs, url, receipt, recovering=False):
    if not recovering and obs.call('GetStreamStatus')['outputActive']:
        raise RuntimeError('OBS is streaming; public staging requires it offline')
    if not recovering:
        receipt['previous_scene'] = obs.call('GetCurrentProgramScene')['currentProgramSceneName']
        receipt['record_was_active'] = obs.call('GetRecordStatus')['outputActive']
    scenes = [s['sceneName'] for s in obs.call('GetSceneList')['scenes']]
    if SCENE not in scenes:
        obs.call('CreateScene', {'sceneName': SCENE})
    specs = [
        ('mt background', 'color_source_v3', {'color': 0xff201810, 'width': 1920, 'height': 1080}, (0, 0, 1920, 1080)),
        ('mt camera', 'game_capture', {'capture_mode': 'window', 'window': f"Factorio {os.environ.get('MT_EXPECT_VERSION', '2.0.77')}:Factorio:factorio-mtcam.exe",
                                     'priority': 2, 'capture_cursor': False, 'allow_transparency': False, 'capture_audio': False}, CAMERA_RECT),
        ('mt overlay', 'browser_source', {'url': url, 'width': 1920, 'height': 1080, 'fps': 30,
                                        'shutdown': False, 'restart_when_active': True}, (0, 0, 1920, 1080))]
    names = [i['inputName'] for i in obs.call('GetInputList')['inputs']]
    for order, (name, kind, settings, rect) in enumerate(specs):
        if name in names:
            if name == 'mt camera':
                # OBS can retain the closed client's last frame when the next isolated
                # process has the same window title. Release that hook before rebinding.
                obs.call('SetInputSettings', {'inputName': name, 'inputSettings': {'window': ''}, 'overlay': True})
                time.sleep(1)
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
    receipt['audio'] = setup_audio(obs)
    obs.call('SetCurrentProgramScene', {'sceneName': SCENE})
    if receipt.get('recording_hold'):
        return
    if not receipt['record_was_active'] and not obs.call('GetRecordStatus')['outputActive']:
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


def split_settings(obs, values):
    for key, value in values.items():
        obs.call('SetProfileParameter', {'parameterCategory':'AdvOut','parameterName':key,'parameterValue':value})


def supervise(op, run):
    if os.environ.get('POG_TEST') == '1':
        raise RuntimeError('POG_TEST=1: no remote public stream setup')
    pinned()
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
    archivist = None
    memory = None
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
        overlay = PublicOverlay(op, tree, run, port, dwell, os.environ.get('POG_MT_YOUTUBE'), audio=True)
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
        checked(powershell(f"if (!(Test-Path -LiteralPath '{MUSIC_FILE}' -PathType Leaf)) {{ throw 'stream music bed is missing' }}"), capture_output=True)
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
        require(not obs.call('GetRecordStatus')['outputActive'], 'existing recording must be stopped before staging')
        require(os.path.ismount('/Volumes/POG Media'), 'POG Media must be mounted for recording archive')
        receipt['previous_record_directory']=obs.call('GetRecordDirectory')['recordDirectory']
        receipt['record_directory']=f'{REMOTE}/recordings/{run}'
        receipt['previous_split_settings']={key:obs.call('GetProfileParameter',{
            'parameterCategory':'AdvOut','parameterName':key})['parameterValue'] for key in SPLIT_SETTINGS}
        write(statefile,receipt)
        checked(powershell(f"New-Item -ItemType Directory -Force '{receipt['record_directory']}' | Out-Null"),capture_output=True)
        obs.call('SetRecordDirectory',{'recordDirectory':receipt['record_directory']})
        split_settings(obs,SPLIT_SETTINGS)
        setup_obs(obs, f'http://127.0.0.1:{port}/?audio=1', receipt)
        with (op/'recording-archive.log').open('a') as log:
            archivist=subprocess.Popen([sys.executable,str(HERE/'stream_recordings.py'),str(op)],
                                       stdout=log,stderr=subprocess.STDOUT)
        # One independent observer per run. A lock prevents duplicate samples if
        # the operator already started it before bringing up the camera.
        with (op/'memory-watch.log').open('a') as log:
            memory=subprocess.Popen([sys.executable,str(HERE/'stream_memory.py'),str(op)],stdout=log,stderr=subprocess.STDOUT)
        receipt.update(phase='ready', overlay=f'http://127.0.0.1:{port}/', camera=CAMERA, scene=SCENE,
                       streaming=False, recording_active=True)
        receipt['audio']['tts'] = overlay.audio.backend
        write(statefile, receipt)
        print('READY: public overlay, one camera, mt-stream scene, recording; OBS streaming is OFF', flush=True)
        recovery, frame = Recovery(op, 'staging'), FrameProgress()
        last_frame, rehooked = 0, False
        last_memory_spawn = last_archive_spawn = time.time()

        def wire_check():
            require(tunnel.poll() is None and relay.poll() is None, 'owned tunnel or UDP relay exited')
            # Also detect a living SSH process with a broken reverse HTTP forward.
            probe = checked(powershell(f"(Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 'http://127.0.0.1:{port}/health').Content"), capture_output=True, text=True)
            require(probe.stdout.strip() == 'ok', 'reverse overlay forward unavailable')

        def wire_repair():
            nonlocal tunnel, relay
            terminate(relay)
            terminate(tunnel)
            obs.close()
            # TCP EOF frees the remote UDP port. Keep the local Bridge and overlay.
            if stop.wait(3):
                return
            tunnel = subprocess.Popen(tunnel_args)
            children[:] = [tunnel]
            if stop.wait(4):
                return
            require(tunnel.poll() is None, 'replacement tunnel exited')
            relay = subprocess.Popen(powershell(f"& '{REMOTE}/bridge.ps1'"))
            children.append(relay)

        def obs_check():
            obs.call('GetVersion')
            require(obs.call('GetCurrentProgramScene')['currentProgramSceneName'] == SCENE, 'mt scene not selected')
            require(receipt.get('recording_hold') or obs.call('GetRecordStatus')['outputActive'], 'recording stopped')

        def obs_repair():
            restart = recovery.states.get('obs',{}).get('attempts',0)>=2
            try:
                obs.call('GetVersion')
            except Exception:
                restart = True
            if restart:
                obs.close()
                subprocess.run(powershell(f"& '{REMOTE}/obs-restart.ps1' -WaitClose 5 -WaitStart 60"),
                               check=True, timeout=200, capture_output=True, text=True)
            split_settings(obs,SPLIT_SETTINGS)
            setup_obs(obs, f'http://127.0.0.1:{port}/?audio=1', receipt, recovering=True)

        def camera_check():
            p = json.loads(remote_camera('status').stdout or '{}')
            require(p and p.get('responding', True), 'camera absent or unresponsive')
            connected = h.lua(f"local p=game.get_player('{CAMERA}') rcon.print(helpers.table_to_json{{connected=p and p.connected or false}})")
            require(connected.get('connected'), 'camera disconnected or in a disconnect/lag modal')
            snap=overlay.snapshot()
            eligible=[t for t in snap.get('teams',[]) if not t.get('stale') and not t.get('paused')]
            if len(eligible)>=2:
                require(time.time()-(snap.get('camera') or {}).get('since',0)<max(180,dwell*len(eligible)*3),
                        'camera director has not framed any fresh team within its rotation window')

        def camera_repair():
            pinned()
            remote_camera('stop')
            # The relay pins one UDP source endpoint. A new client uses a new
            # ephemeral port. Closing only its ssh.exe parent can leave the
            # Windows PowerShell child alive and holding UDP. Close the owning
            # TCP tunnel as well: EOF makes that bridge release its socket.
            wire_repair()
            remote_camera('start')
            rehook()

        def rehook():
            obs.call('SetInputSettings', {'inputName':'mt camera','inputSettings':{'window':''},'overlay':True})
            stop.wait(1)
            obs.call('SetInputSettings', {'inputName':'mt camera','inputSettings':{
                'window':f"Factorio {os.environ.get('MT_EXPECT_VERSION', '2.0.77')}:Factorio:factorio-mtcam.exe"},'overlay':True})

        def frame_repair():
            nonlocal rehooked
            if rehooked:
                camera_repair()
            else:
                rehook()
                rehooked = True

        def space_check(free):
            require(recording_space_ok(free,receipt.get('recording_hold',False)),
                    'recording spool low on space; streaming/game retained, archive must catch up')
            receipt['recording_hold']=False

        def space_repair():
            receipt['recording_hold']=True
            if obs.call('GetRecordStatus')['outputActive']:
                obs.call('StopRecord')

        while not stop.wait(10):
            pinned()
            wire_ok = recovery.run('wire', wire_check, wire_repair, grace=0)
            if wire_ok:
                # Do not let an archive outage fill D: and take down the stream.
                # OBS transport errors belong to obs recovery, not a disk hold.
                try:
                    free=obs.call('GetStats')['availableDiskSpace']
                except Exception:
                    pass
                else:
                    recovery.run('recording-space',lambda:space_check(free),space_repair,grace=0,cooldown=60)
            obs_ok = wire_ok and recovery.run('obs', obs_check, obs_repair)
            cam_ok = wire_ok and recovery.run('camera', camera_check, camera_repair, grace=30, cooldown=180)
            now = time.time()
            if obs_ok and cam_ok and now-last_frame >= 30:
                last_frame = now
                def frame_check():
                    data = obs.call('GetSourceScreenshot', {'sourceName':'mt camera', 'imageFormat':'jpg',
                                                           'imageWidth':320, 'imageHeight':180})['imageData']
                    game = h.lua('rcon.print(helpers.table_to_json{tick=game.tick,paused=game.tick_paused})')
                    camera = (overlay.snapshot().get('camera') or {}).get('since')
                    require(frame.observe(data, game['tick'], camera, game['paused'], now), 'camera pixels frozen despite advancing game and camera cuts')
                if recovery.run('frame', frame_check, frame_repair, grace=0, cooldown=60):
                    rehooked = False
            if archivist.poll() is not None and now-last_archive_spawn>=60:
                last_archive_spawn=now
                with (op/'recording-archive.log').open('a') as log:
                    archivist=subprocess.Popen([sys.executable,str(HERE/'stream_recordings.py'),str(op)],stdout=log,stderr=subprocess.STDOUT)
            if memory.poll() is not None:
                # An independently owned observer can legitimately hold the lock.
                from run_state import read as read_json
                sample=read_json(op/'memory.json',{})
                if now-sample.get('heartbeat',0)>600 and now-last_memory_spawn>=600:
                    last_memory_spawn=now
                    with (op/'memory-watch.log').open('a') as log:
                        memory=subprocess.Popen([sys.executable,str(HERE/'stream_memory.py'),str(op)],stdout=log,stderr=subprocess.STDOUT)
            # Overlay poll errors are contained in its thread; a stall still wakes the operator.
            recovery.run('overlay', lambda: require(now-overlay.snapshot().get('now', 0)<30, 'overlay poll stalled'),
                         lambda: None, grace=30)
            receipt.update(heartbeat=now, tunnel_pid=tunnel.pid, relay_pid=relay.pid,
                           health={'wire':wire_ok,'obs':bool(obs_ok),'camera':bool(cam_ok)})
            write(statefile, receipt)
    except Exception as e:
        receipt.update(phase='failed', error=str(e))
        print(f'public stream failed: {e}', flush=True)
    finally:
        if overlay:
            overlay.close()
        if obs and (receipt.get('previous_scene') or receipt.get('previous_record_directory')):
            try:
                if receipt.get('previous_scene'):
                    restore_obs(obs, receipt)
                if receipt.get('previous_record_directory') and not obs.call('GetRecordStatus')['outputActive']:
                    obs.call('SetRecordDirectory',{'recordDirectory':receipt['previous_record_directory']})
                    split_settings(obs,receipt.get('previous_split_settings',{}))
            except Exception as e:
                receipt['cleanup_error'] = f'OBS cleanup: {e}'
        if archivist is not None and archivist.poll() is None:
            # Finish an in-flight checksum/copy before final archival. SIGTERM
            # requests a graceful worker stop; it never abandons an scp child.
            archivist.terminate()
            try:
                archivist.wait(timeout=660)
            except subprocess.TimeoutExpired:
                receipt['cleanup_archive_error']='archive worker still copying; retained for operator inspection'
        terminate(memory)
        if receipt.get('record_directory') and not receipt.get('cleanup_archive_error'):
            try:
                from stream_recordings import archive
                archive(op,run)
            except Exception as e:
                receipt['cleanup_archive_error']=str(e)
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
        if any(key.startswith('cleanup_') and value for key,value in final.items()):
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
