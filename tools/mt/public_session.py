#!/usr/bin/env python3
"""Operator-authorized bounded live test: existing YouTube, OBS and site paths.

Stage with start-mt.sh and inspect OBS first. start is a plan unless --execute.
The supervisor owns publication and the stop deadline; no agent quota override.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
MAIN = Path('/Users/owner/code/player-of-games')
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tools/stream')]
from yt_upload import Api, API
from obsws import OBS
from stream_recovery import Recovery, require, terminate
from broadcast_rotation import LiveAPI, Rotation


def read(path):
    return json.loads(path.read_text())


def write(path, state):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2)+'\n')
    tmp.replace(path)


def broadcast(api, receipt):
    rows = api.call('GET', API+'/liveBroadcasts?'+urlencode({'id':receipt['id'], 'part':'id,status,contentDetails'}))['items']
    assert len(rows) == 1, 'broadcast missing'
    row = rows[0]
    expected = receipt.get('session_privacy', 'unlisted')
    assert row['status']['privacyStatus'] == expected, 'broadcast privacy changed'
    assert row['contentDetails']['boundStreamId'] == receipt['stream_id'], 'broadcast binding changed'
    return row


def transition(api, receipt, target, stop):
    if broadcast(api, receipt)['status']['lifeCycleStatus'] == target:
        return
    if target != 'complete':
        for _ in range(30):
            rows = api.call('GET', API+'/liveStreams?'+urlencode({'id':receipt['stream_id'], 'part':'status'}))['items']
            if rows and rows[0]['status']['streamStatus'] == 'active':
                break
            if stop.wait(2):
                raise RuntimeError('start cancelled')
        else:
            raise RuntimeError('YouTube ingest did not become active')
    api.call('POST', API+'/liveBroadcasts/transition?'+urlencode({'id':receipt['id'], 'broadcastStatus':target, 'part':'id,status'}))
    for _ in range(30):
        if broadcast(api, receipt)['status']['lifeCycleStatus'] == target:
            return
        time.sleep(2)
    raise RuntimeError('YouTube transition timed out: '+target)


def site_state():
    req = Request('https://player-of-games-live.your-subdomain.workers.dev/v1/state', headers={'User-Agent':'pog-push-live/1'})
    with urlopen(req, timeout=15) as r:
        return json.load(r).get('state') or {}


def roster_of(op):
    active={line.split()[0] for line in (op/'streams.txt').read_text().splitlines() if line.strip()}
    expected={team:set() for team in active}
    for line in (op/'teams.tsv').read_text().splitlines():
        fields=line.split('\t')
        if not line.startswith('#') and len(fields)>=2 and fields[0] in expected:
            expected[fields[0]].add(fields[1])
    assert expected and all(len(names)>=2 for names in expected.values()), 'missing paired stream roster'
    return expected


def fresh_feed(state, now, expected):
    teams = state.get('teams')
    stamp = state.get('now')
    return (isinstance(stamp, (int, float)) and 0 <= now - stamp <= 60
            and isinstance(teams, list) and len(teams) == len(expected)
            and all(isinstance(t,dict) for t in teams)
            and {t.get('team') for t in teams} == set(expected)
            and all(not t.get('stale', True) and isinstance(t.get('agents'),list)
                    and len(t['agents']) == len(expected[t['team']])
                    and {a.get('name') for a in t['agents'] if isinstance(a,dict)} == expected[t['team']]
                    for t in teams))


def owns_site(state, video):
    return state.get('mode') == 'team-tests' and (state.get('stream') or {}).get('youtube_video_id') == video


def owned_pid(pid, run):
    try:
        command = subprocess.check_output(['ps','-p',str(int(pid)),'-o','command='],text=True)
        return str(Path(__file__).resolve())+' _supervise '+run+' ' in command
    except (subprocess.CalledProcessError, ValueError, TypeError):
        return False


def publisher_command(run, op, off=False, source="http://127.0.0.1:8790/state.json"):
    cmd = [sys.executable, str(ROOT/'site/push_live.py')]
    if off:
        return cmd + ['--team-tests-off']
    return cmd + ['--team-tests', '--team-run-id', run, '--team-archive-dir', str(op/'public-site'),
                  '--source', source, '--report', '30']


def publisher_env(video):
    env = dict(os.environ, POG_YOUTUBE=video)
    # The source checkout can differ from the operator's credential checkout.
    if not env.get('POG_LIVE_TOKEN'):
        path = MAIN/'site/worker/.secrets.json'
        if path.is_file():
            env['POG_LIVE_TOKEN'] = read(path)['PUBLISH_TOKEN']
    return env


def supervise(run, minutes, run_mode='test', public=False, closed_drill=False):
    op = ROOT/'runs'/run/'op'
    lock = open('/tmp/pog-team-test-session.lock', 'a+')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    receipt = read(op/'broadcast.json')
    privacy = 'public' if public else 'unlisted'
    assert not public or run_mode == 'full', 'public needs explicit full mode'
    assert receipt['bound'] and receipt['request']['status']['privacyStatus'] == privacy
    receipt['session_privacy'] = privacy
    ready = read(op/'public-stream.json')
    assert ready['phase'] == 'ready' and ready['run'] == run and ready['root'] == str(ROOT)
    source=ready['overlay'].rstrip('/')+'/state.json'
    parsed=urlsplit(source)
    assert parsed.scheme=='http' and parsed.hostname=='127.0.0.1' and parsed.port, 'invalid local overlay source'
    assert os.environ.get('MT_DIR') == '/Users/owner/pog-mt21' and os.environ.get('MT_EXPECT_VERSION') == '2.1.24', 'missing isolated 2.1 pins'
    expected = roster_of(op)
    state = {'pid':os.getpid(), 'run':run, 'video':receipt['id'], 'phase':'starting', 'started':time.time(),
             'run_mode':run_mode, 'privacy':privacy, 'deadline':None if run_mode=='full' and not closed_drill else time.time()+minutes*60}
    statefile = op/'public-session.json'
    write(statefile,state)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    api, obs, publisher = LiveAPI(), OBS(port=4458, timeout=8), None
    started_obs = False
    errors = []
    try:
        assert not obs.call('GetStreamStatus')['outputActive'], 'OBS already streaming'
        assert obs.call('GetCurrentProgramScene')['currentProgramSceneName'] == 'mt-stream'
        assert obs.call('GetRecordStatus')['outputActive'], 'staged recording is not active'
        assert broadcast(api,receipt)['status']['lifeCycleStatus'] in ('ready','created','testing')
        started_obs = True
        obs.call('StartStream')
        transition(api,receipt,'testing',stop)
        transition(api,receipt,'live',stop)
        env = publisher_env(receipt['id'])
        with (op/'site-push.log').open('a') as log:
            publisher = subprocess.Popen(publisher_command(run, op, source=source),env=env,stdout=log,stderr=subprocess.STDOUT)
        state['publisher_pid'] = publisher.pid
        confirmed = False
        for _ in range(12):
            if publisher.poll() is not None:
                raise RuntimeError('site publisher exited; inspect its log/lock')
            if owns_site(site_state(),receipt['id']):
                confirmed = True
                break
            if stop.wait(3):
                raise RuntimeError('start cancelled')
        if not confirmed:
            raise RuntimeError('site did not confirm this test')
        state.update(phase='live', live_at=time.time())
        write(statefile,state)
        print('LIVE https://factorio.nickwinter.net/live/ https://www.youtube.com/watch?v='+receipt['id'],flush=True)
        recovery = Recovery(op, 'session')
        rotation = Rotation(op, api, privacy, stop, transition, broadcast,
                            float(os.environ.get('POG_MT_ROTATE_SECONDS', 11*3600)))
        last_youtube = 0
        output_progress = {'bytes':None,'at':time.time()}

        def start_publisher():
            nonlocal publisher
            terminate(publisher)
            env = publisher_env(receipt['id'])
            with (op/'site-push.log').open('a') as log:
                publisher = subprocess.Popen(publisher_command(run, op, source=source),env=env,stdout=log,stderr=subprocess.STDOUT)
            state['publisher_pid'] = publisher.pid

        def stream_check():
            require(read(op/'public-stream.json').get('phase') == 'ready', 'camera supervisor not ready')
            s = obs.call('GetStreamStatus')
            require(s['outputActive'], 'OBS output stopped')
            count = s.get('outputBytes')
            if count != output_progress['bytes']:
                output_progress.update(bytes=count, at=time.time())
            require(not s.get('outputReconnecting') and time.time()-output_progress['at']<90,
                    'OBS output disconnected or stopped sending bytes')

        def stream_repair():
            # public_stream owns OBS process recovery, scene/capture and recording.
            require(read(op/'public-stream.json').get('health',{}).get('obs',True), 'waiting for OBS process recovery')
            require(obs.call('GetCurrentProgramScene')['currentProgramSceneName']=='mt-stream', 'not our scene')
            if obs.call('GetStreamStatus')['outputActive']:
                obs.call('StopStream')
                for _ in range(20):
                    if not obs.call('GetStreamStatus')['outputActive']:
                        break
                    if stop.wait(1):
                        return
            obs.call('StartStream')
            output_progress['at']=time.time()

        def youtube_check():
            pending=read(op/'broadcast-rotation.json') if (op/'broadcast-rotation.json').exists() else {}
            row=broadcast(api,receipt)
            require(row['status']['lifeCycleStatus']=='live', 'YouTube broadcast ended or is not live')
            require(time.time()-state['live_at']<rotation.interval, 'archive rotation due')
            require(not pending or pending.get('phase')=='committed', 'rollover awaiting completion')

        def youtube_repair():
            nonlocal receipt
            receipt, state['live_at'], changed = rotation.advance(receipt, state['live_at'])
            if changed:
                state['video']=receipt['id']
                write(statefile,state)
                start_publisher()

        def site_check():
            require(publisher.poll() is None, 'site publisher exited')
            remote=site_state()
            require(owns_site(remote,receipt['id']), 'site link has not reached current broadcast')
            require(fresh_feed(remote,time.time(),expected), 'site live data stale or roster incomplete')

        while (state['deadline'] is None or time.time() < state['deadline']) and not stop.wait(10):
            recovery.run('output', stream_check, stream_repair, grace=30)
            if time.time()-last_youtube>=60:
                last_youtube=time.time()
                recovery.run('youtube',youtube_check,youtube_repair,grace=0,cooldown=60)
            recovery.run('site',site_check,start_publisher,grace=30,cooldown=60)
            try:
                with urlopen(source, timeout=5) as response:
                    healthy = fresh_feed(json.load(response), time.time(), expected)
            except (OSError, ValueError):
                healthy = False
            from stream_feeds import restart_stale
            recovery.run('feeds',lambda:require(healthy,'team feeds stale; world retained'),lambda:restart_stale(op),grace=60,cooldown=120)
            state['heartbeat'] = time.time()
            write(statefile,state)
    except Exception as e:
        errors.append(str(e))
        print('session:',str(e),flush=True)
    finally:
        state['phase'] = 'stopping'
        write(statefile,state)
        if started_obs:
            try:
                if broadcast(api,receipt)['status']['lifeCycleStatus'] in ('live','testing'):
                    transition(api,receipt,'complete',stop)
            except Exception as e:
                errors.append('YouTube completion: '+str(e))
            try:
                if obs.call('GetStreamStatus')['outputActive']:
                    obs.call('StopStream')
                for _ in range(30):
                    if not obs.call('GetStreamStatus')['outputActive']:
                        break
                    time.sleep(1)
                else:
                    raise RuntimeError('OBS still streaming')
            except Exception as e:
                errors.append('OBS stop: '+str(e))
        if publisher is not None and publisher.poll() is None:
            publisher.terminate()
            try:
                publisher.wait(timeout=20)
            except subprocess.TimeoutExpired:
                publisher.kill(); publisher.wait(timeout=5)
        try:
            if owns_site(site_state(),receipt['id']):
                subprocess.run(publisher_command(run, op, off=True),env=publisher_env(receipt['id']),check=True,timeout=40)
        except Exception as e:
            errors.append('site off: '+str(e))
        hold = read(op/'stream-hold.json') if (op/'stream-hold.json').exists() else {}
        if closed_drill or hold.get('keep_world'):
            # A fixture's controller owns its server and restores the prior save.
            pass
        elif run_mode == 'test' or not errors:
            try:
                subprocess.run([str(ROOT/'tools/mt/stop-mt.sh'),run],cwd=ROOT,env=dict(os.environ,POG_STOP_WORLD='1'),check=True,timeout=180)
            except Exception as e:
                errors.append('run stop: '+str(e))
        else:
            from run_state import alert
            alert(op, 'broadcast-failed-world-retained', '; '.join(errors))
        state.update(phase='stopped' if not errors else 'needs-review', ended=time.time(), errors=errors)
        write(statefile,state)
        print(json.dumps(state),flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['start','_supervise','status','stop'])
    p.add_argument('run')
    p.add_argument('--minutes',type=int,default=40)
    p.add_argument('--execute',action='store_true')
    p.add_argument('--run-mode',choices=['test','full'],default='test')
    p.add_argument('--public',action='store_true',help='explicitly permit a public full-run broadcast')
    p.add_argument('--closed-drill',action='store_true',help='bounded unlisted full-mode stream; fixture controller owns server cleanup')
    p.add_argument('--keep-world',action='store_true',help='with stop: stop publication only, for a staffed stream-box maintenance window')
    a = p.parse_args()
    assert a.run and '/' not in a.run and not a.run.startswith('.')
    assert a.minutes >= 1 and (a.run_mode=='full' or a.minutes<=90)
    assert not a.public or a.run_mode=='full', '--public requires --run-mode full'
    assert not a.closed_drill or (a.run_mode=='full' and not a.public and a.minutes<=720), 'closed drill: unlisted full mode, at most 12 hours'
    assert not a.keep_world or a.action=='stop', '--keep-world is a stop option'
    op = ROOT/'runs'/a.run/'op'; statefile = op/'public-session.json'
    if a.action == '_supervise':
        supervise(a.run,a.minutes,a.run_mode,a.public,a.closed_drill)
    elif a.action == 'status':
        print(json.dumps(read(statefile),indent=2))
    elif a.action == 'stop':
        state=read(statefile)
        if owned_pid(state.get('pid'),a.run):
            if a.keep_world:
                write(op/'stream-hold.json',dict(keep_world=True,at=time.time(),reason='operator stream maintenance'))
            os.kill(state['pid'],signal.SIGTERM)
        elif state.get('phase') not in ('stopped','needs-review'):
            raise SystemExit('owner not running: inspect receipt and stop explicitly')
    else:
        if not a.execute:
            end = 'until explicit stop; agent shifts leave the broadcast running' if a.run_mode=='full' else f'for {a.minutes} minutes, then stop/save'
            print(f'Plan: go live {"public" if a.public else "unlisted"}, publish site test mode, {end}. Inspect staged OBS before --execute.')
            return
        if statefile.exists() and owned_pid(read(statefile).get('pid'),a.run):
            raise SystemExit('session already running')
        if (op/'stream-hold.json').exists():
            (op/'stream-hold.json').unlink()
        with (op/'public-session.log').open('a') as log:
            child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'_supervise',a.run,'--minutes',str(a.minutes),
                                    '--run-mode',a.run_mode,*(['--public'] if a.public else []),
                                    *(['--closed-drill'] if a.closed_drill else [])],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        print('supervisor',child.pid,op/'public-session.log')


if __name__ == '__main__':
    main()
