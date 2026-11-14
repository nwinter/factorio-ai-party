#!/usr/bin/env python3
"""Closed two-shift controller with exact-save restore and bounded final teardown."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

from run_state import ROOT,CLAIM,alert,command,lock,op_dir,pinned,read,rcon,write
import full_run
import restore


def personal_usage():
    brief=read(Path.home()/'.cache/ai-usage/agent-brief.json',{})
    if time.time()-brief.get('generated_at',0)>900:return None
    for p in brief.get('profiles',[]):
        if p.get('command')=='codex' and not p.get('stale'):
            return max([w.get('percent',0) for w in p.get('windows',[]) if w.get('duration_minutes')==10080] or [0])
    return None

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true');a=p.parse_args()
    if not a.execute:print('Two 90-minute closed shifts; exact-save restore in between; teardown and claim release.');return
    op=op_dir(a.run);pinned();assert os.environ.get('POG_MT_PUBLIC','0')=='0'
    stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    receipt=op/'rehearsal.json';assert not receipt.exists(),'rehearsal already attempted'
    state=dict(started=time.time(),phase='launching',run=a.run,errors=[])
    deadline=time.time()+4*3600
    def record(**fields):state.update(fields,heartbeat=time.time());write(receipt,state)
    def wait_for(predicate,limit):
        end=min(deadline,time.time()+limit)
        while time.time()<end:
            if stop.is_set():raise RuntimeError('rehearsal interrupted')
            used=personal_usage()
            if used is not None and used>88:raise RuntimeError(f'personal Codex weekly {used}% exceeds 88% stop rule')
            if predicate():return
            record(codex_weekly=used);stop.wait(10)
        raise RuntimeError('rehearsal phase timed out')
    try:
        record()
        wait_for(lambda:(op/'full-run.json').exists(),600)
        os.environ.update(read(op/'full-env.json'))
        first=read(op/'full-run.json');assert first['minutes']==90 and first['max_shifts']==1
        assert len(first['agents'])==6 and all(full_run.live_client(r) for r in first['agents'].values())
        with lock(op/'agents.lock'):
            first=read(op/'full-run.json')
            end=(int(time.time()/60)+91)*60
            for row in first['agents'].values():full_run.set_deadline(row,end)
            write(op/'full-run.json',first)
        rcon('game.tick_paused=false; rcon.print(game.tick)')
        record(phase='shift1',shift1_resumed=time.time(),shift1_end=max(r['deadline'] for r in first['agents'].values()))
        wait_for(lambda:read(op/'full-run.json')['phase']=='shifts-complete',100*60)
        record(phase='restore',shift1_complete=time.time())
        result=restore.drill(a.run);record(restore=result['exact'])
        with lock(op/'agents.lock'):
            current=read(op/'full-run.json');current.update(phase='running',max_shifts=2)
            full_run.change(op,current,list(current['agents']),90,reason='shift')
            full_run.indexes(op,current);write(op/'full-run.json',current)
        with (op/'full-watch.log').open('a') as log:
            watcher=subprocess.Popen([sys.executable,ROOT/'tools/mt/full_run.py','watch',a.run],cwd=ROOT,
                                     stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        with (op/'helpers.pid').open('a') as out:out.write(str(watcher.pid)+'\n')
        rcon('game.tick_paused=false; rcon.print(game.tick)')
        record(phase='shift2',shift2_resumed=time.time(),shift2_end=max(r['deadline'] for r in current['agents'].values()))
        wait_for(lambda:read(op/'full-run.json')['phase']=='shifts-complete',100*60)
        record(phase='completed',shift2_complete=time.time())
    except Exception as e:
        state['errors'].append(str(e));record(phase='failed');alert(op,'rehearsal-failed',e)
    finally:
        with (op/'rehearsal-stop.log').open('a') as log:
            result=subprocess.run([ROOT/'tools/mt/stop-mt.sh',a.run],cwd=ROOT,env=dict(os.environ,POG_STOP_WORLD='1'),
                                  stdout=log,stderr=subprocess.STDOUT,timeout=240)
        status=command([ROOT/'tools/mt/imac_mt.sh','status'])
        record(ended=time.time(),stop_exit=result.returncode,server=status.strip())
        if result.returncode==0 and status.startswith('not running') and not state['errors'] and CLAIM.exists() and 'eng-mt300' in CLAIM.read_text().split():
            (op/'server-claim-released.txt').write_text(CLAIM.read_text());CLAIM.unlink()
        elif state['errors'] and result.returncode==0 and status.startswith('not running'):
            alert(op,'rehearsal-failed-claim-retained','server stopped; owner must inspect and explicitly release or retry')
        else:alert(op,'rehearsal-teardown-needs-review',status)
    print(json.dumps(state),flush=True)
    return bool(state['errors'])

if __name__=='__main__':sys.exit(main())
