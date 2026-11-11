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
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
MAIN = Path('/Users/owner/code/player-of-games')
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tools/stream')]
from yt_upload import Api, API
from obsws import OBS


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
    assert row['status']['privacyStatus'] == 'unlisted', 'test must stay unlisted'
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


def owns_site(state, video):
    return state.get('mode') == 'team-tests' and (state.get('stream') or {}).get('youtube_video_id') == video


def owned_pid(pid, run):
    try:
        command = subprocess.check_output(['ps','-p',str(int(pid)),'-o','command='],text=True)
        return str(Path(__file__).resolve())+' _supervise '+run+' ' in command
    except (subprocess.CalledProcessError, ValueError, TypeError):
        return False


def supervise(run, minutes):
    op = ROOT/'runs'/run/'op'
    lock = open('/tmp/pog-team-test-session.lock', 'a+')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    receipt = read(op/'broadcast.json')
    assert receipt['bound'] and receipt['request']['status']['privacyStatus'] == 'unlisted'
    ready = read(op/'public-stream.json')
    assert ready['phase'] == 'ready' and ready['run'] == run and ready['root'] == str(ROOT)
    assert os.environ.get('MT_DIR') == '/Users/owner/pog-mt21' and os.environ.get('MT_EXPECT_VERSION') == '2.1.24', 'missing isolated 2.1 pins'
    state = {'pid':os.getpid(), 'run':run, 'video':receipt['id'], 'phase':'starting', 'started':time.time(), 'deadline':time.time()+minutes*60}
    statefile = op/'public-session.json'
    write(statefile,state)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    api, obs, publisher = Api(False), OBS(timeout=20), None
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
        env = dict(os.environ, POG_YOUTUBE=receipt['id'])
        with (op/'site-push.log').open('a') as log:
            publisher = subprocess.Popen([sys.executable,str(MAIN/'site/push_live.py'),'--team-tests','--source','http://127.0.0.1:8790/state.json','--report','30'],env=env,stdout=log,stderr=subprocess.STDOUT)
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
        while time.time() < state['deadline'] and not stop.wait(10):
            if publisher.poll() is not None:
                raise RuntimeError('site publisher exited')
            if read(op/'public-stream.json').get('phase') != 'ready':
                raise RuntimeError('public camera/overlay supervisor failed')
            if not obs.call('GetStreamStatus')['outputActive']:
                raise RuntimeError('OBS stream stopped')
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
                subprocess.run([sys.executable,str(MAIN/'site/push_live.py'),'--team-tests-off'],check=True,timeout=40)
        except Exception as e:
            errors.append('site off: '+str(e))
        try:
            subprocess.run([str(ROOT/'tools/mt/stop-mt.sh'),run],cwd=ROOT,env=dict(os.environ,POG_STOP_WORLD='1'),check=True,timeout=180)
        except Exception as e:
            errors.append('run stop: '+str(e))
        state.update(phase='stopped' if not errors else 'needs-review', ended=time.time(), errors=errors)
        write(statefile,state)
        print(json.dumps(state),flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['start','_supervise','status','stop'])
    p.add_argument('run')
    p.add_argument('--minutes',type=int,default=40)
    p.add_argument('--execute',action='store_true')
    a = p.parse_args()
    assert a.run and '/' not in a.run and not a.run.startswith('.')
    assert 1 <= a.minutes <= 90
    op = ROOT/'runs'/a.run/'op'; statefile = op/'public-session.json'
    if a.action == '_supervise':
        supervise(a.run,a.minutes)
    elif a.action == 'status':
        print(json.dumps(read(statefile),indent=2))
    elif a.action == 'stop':
        state=read(statefile)
        if owned_pid(state.get('pid'),a.run):
            os.kill(state['pid'],signal.SIGTERM)
        elif state.get('phase') not in ('stopped','needs-review'):
            raise SystemExit('owner not running: inspect receipt and stop explicitly')
    else:
        if not a.execute:
            print(f'Plan: go live unlisted, publish site test mode, stop/save {a.run} after {a.minutes} minutes. Inspect staged OBS before --execute.')
            return
        if statefile.exists() and owned_pid(read(statefile).get('pid'),a.run):
            raise SystemExit('session already running')
        with (op/'public-session.log').open('a') as log:
            child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'_supervise',a.run,'--minutes',str(a.minutes)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        print('supervisor',child.pid,op/'public-session.log')


if __name__ == '__main__':
    main()
