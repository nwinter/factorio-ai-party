#!/usr/bin/env python3
"""Inject one fault into an explicitly authorized, unlisted closed stream drill.

No server stop, gameplay mutation or reboot. Evidence includes live service
observations after recovery and the progressing iMac game tick.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

from run_state import op_dir, pinned, read, write, rcon, alert
from public_stream import powershell, checked, remote_camera
from public_session import broadcast, transition, site_state, fresh_feed, roster_of, owns_site
from broadcast_rotation import LiveAPI
from obsws import OBS


def ps(pid):
    return subprocess.check_output(['ps','-p',str(int(pid)),'-o','command='],text=True).strip()


def snapshot(op):
    obs=OBS(port=4458,timeout=5)
    out=dict(at=time.time(),staging=read(op/'public-stream.json'),session=read(op/'public-session.json'))
    try:
        out['output']=obs.call('GetStreamStatus')
        out['recording']=obs.call('GetRecordStatus')
        out['camera']=json.loads(remote_camera('status').stdout or '{}')
        out['game']=json.loads(rcon("local p=game.get_player('pog-director2'); rcon.print(helpers.table_to_json{tick=game.tick,paused=game.tick_paused,connected=p and p.connected or false})"))
        out['site']=site_state()
        receipt=read(op/'broadcast.json')
        out['youtube']=broadcast(LiveAPI(),receipt)['status']
        out['video']=receipt['id']
    finally:
        obs.close()
    return out


def healthy(s,op):
    return (s['output']['outputActive'] and not s['output'].get('outputReconnecting')
            and s['recording']['outputActive'] and s['camera'] and s['game']['connected']
            and not s['game']['paused'] and s['youtube']['lifeCycleStatus']=='live'
            and s['session']['phase']=='live'
            and all(s['staging'].get('health',{}).get(k) for k in ('wire','obs','camera'))
            and time.time()-s['staging'].get('heartbeat',0)<45
            and owns_site(s['site'],s['video']) and fresh_feed(s['site'],time.time(),roster_of(op)))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('run');p.add_argument('fault',choices=['obs','camera','tunnel','relay','publisher','youtube','modal'])
    p.add_argument('--execute',action='store_true');p.add_argument('--timeout',type=int,default=600)
    a=p.parse_args();op=op_dir(a.run)
    if not a.execute:
        print('Plan: inject',a.fault,'into this unlisted drill and wait for observed recovery');return
    pinned();before=snapshot(op)
    assert before['session']['privacy']=='unlisted' and before['youtube']['privacyStatus']=='unlisted'
    assert healthy(before,op),'drill must be healthy before injection'
    evidence=op/'faults';evidence.mkdir(exist_ok=True)
    path=evidence/(a.fault+'-'+str(int(time.time()))+'.json')
    result=dict(fault=a.fault,started=time.time(),before=before)
    write(path,result)
    alert(op,'fault-injection',a.fault+' in closed unlisted drill')
    if a.fault=='obs':
        # This stream's selected program and unlisted publication were checked.
        checked(powershell("$p=Get-CimInstance Win32_Process -Filter \"Name='obs64.exe'\"; if (@($p).Count -ne 1 -or $p.ExecutablePath -ne 'C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe') {throw 'unexpected OBS process'}; Stop-Process -Id $p.ProcessId -Force"),capture_output=True)
    elif a.fault=='camera':
        remote_camera('stop')
    elif a.fault=='modal':
        from harness import Harness
        Harness('imac2').command('/kick pog-director2 Closed stream recovery drill')
    elif a.fault in ('tunnel','relay','publisher'):
        owner=before['session'] if a.fault=='publisher' else before['staging']
        pid=owner[a.fault+'_pid'];command=ps(pid)
        assert ('site/push_live.py' in command and '--team-tests' in command) if a.fault=='publisher' else ('ssh ' in command and 'pogwin' in command)
        if a.fault=='tunnel':assert '8790:127.0.0.1:8790' in command
        os.kill(pid,signal.SIGTERM)
    else:
        transition(LiveAPI(),read(op/'broadcast.json'),'complete',threading.Event())
    result['injected']=time.time();write(path,result)
    deadline=time.time()+a.timeout
    stable_since, stable_key, previous_bytes = None, None, None
    while time.time()<deadline:
        time.sleep(5)
        try:
            after=snapshot(op)
            changed = (after['video']!=before['video'] if a.fault=='youtube' else
                       after['camera'].get('ProcessId')!=before['camera'].get('ProcessId') if a.fault in ('camera','modal') else
                       after['staging'][a.fault+'_pid']!=before['staging'][a.fault+'_pid'] if a.fault in ('tunnel','relay') else
                       after['session']['publisher_pid']!=before['session']['publisher_pid'] if a.fault=='publisher' else
                       after['output']['outputDuration']<before['output']['outputDuration'])
            key=(after['camera'].get('ProcessId'),after['staging'].get('tunnel_pid'),after['video'])
            if changed and healthy(after,op) and after['game']['tick']>before['game']['tick']:
                # Factorio can remain "connected" until its network timeout, even
                # after SSH has recovered. Require a full healthy minute with
                # advancing output bytes before certifying the entire chain.
                if stable_since is None or stable_key!=key or (previous_bytes is not None and after['output']['outputBytes']<=previous_bytes):
                    stable_since,stable_key=time.time(),key
                previous_bytes=after['output']['outputBytes']
                if time.time()-stable_since>=60:
                    result.update(recovered=time.time(),seconds=time.time()-result['injected'],stable_since=stable_since,stable_seconds=time.time()-stable_since,after=after)
                    write(path,result)
                    obs=OBS(port=4458,timeout=10)
                    data=obs.call('GetSourceScreenshot',{'sourceName':'mt-stream','imageFormat':'png','imageWidth':1280,'imageHeight':720})['imageData']
                    path.with_suffix('.png').write_bytes(base64.b64decode(data.split(',',1)[1]));obs.close()
                    alert(op,'fault-recovered',f'{a.fault} in {result["seconds"]:.1f}s; iMac tick advanced')
                    print(json.dumps({k:result[k] for k in ('fault','seconds','recovered')}),flush=True)
                    return
            else:
                stable_since,stable_key,previous_bytes=None,None,None
        except Exception as e:
            stable_since,stable_key,previous_bytes=None,None,None
            result['last_error']=type(e).__name__+': '+str(e)[:200]
            write(path,result)
    result['failed']=time.time();write(path,result)
    alert(op,'fault-drill-failed',a.fault+'; inspect '+str(path))
    raise SystemExit('fault did not recover within deadline')


if __name__=='__main__':
    main()
