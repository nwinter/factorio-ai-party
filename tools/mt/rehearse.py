#!/usr/bin/env python3
"""Closed two-shift controller with exact-save restore and bounded final teardown."""
import argparse
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import threading
import time

from run_state import ROOT,alert,command,lock,op_dir,pinned,read,rcon,write
import full_run
import restore
from map_probe import call


def weekly_usage(profile):
    brief=read(Path.home()/'.cache/ai-usage/agent-brief.json',{})
    if not 0<=time.time()-brief.get('generated_at',0)<=900:return None
    for p in brief.get('profiles',[]):
        if p.get('command')==profile and not p.get('stale') and p.get('available',True):
            if not 0<=time.time()-p.get('observed_at',brief.get('generated_at',0))<=900:return None
            values=[w['percent'] for w in p.get('windows',[]) if w.get('duration_minutes')==10080 and 'percent' in w]
            return max(values) if values else None
    return None

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true')
    p.add_argument('--shift-minutes',type=int,default=180)
    p.add_argument('--quota-profile',default='codex-b');p.add_argument('--quota-stop',type=float,default=70)
    p.add_argument('--measure',action='store_true')
    p.add_argument('--unlisted',action='store_true',help='require an unlisted stream at restore and prove its recovery')
    a=p.parse_args();assert a.shift_minutes>=1 and 0<a.quota_stop<=100
    if not a.execute:print(f'Two {a.shift_minutes}-minute closed shifts; exact-save restore; teardown retaining claim for server restoration.');return
    op=op_dir(a.run);pinned();assert os.environ.get('POG_MT_PUBLIC','0')=='0' or a.unlisted
    stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    receipt=op/'rehearsal.json';assert not receipt.exists(),'rehearsal already attempted'
    state=dict(started=time.time(),phase='launching',run=a.run,errors=[])
    collectors=[]
    archive=Path('/Volumes/POG Media/pog-runs/team-runs')/a.run/'metrics'
    deadline=time.time()+(2*a.shift_minutes+60)*60
    def record(**fields):state.update(fields,heartbeat=time.time());write(receipt,state)
    def start_bench(shift):
        if not a.measure:return None
        assert Path('/Volumes/POG Media').is_mount()
        archive.mkdir(parents=True,exist_ok=True)
        dest=ROOT.parent.parent/'artifacts/mt307';dest.mkdir(parents=True,exist_ok=True)
        host=os.environ.get('IMAC_HOST','imac.local')
        logcmd=shlex.join(['ssh','-o','BatchMode=yes',host,'tail -n 15000 /Users/owner/pog-mt21/data/factorio-current.log'])
        cmd=[sys.executable,'-u',ROOT/'tools/mt/load_bench.py','--host',host,'--port','27475',
             '--password-file',Path.home()/'.config/pog/rcon-imac2.pw','--log-cmd',logcmd,
             '--minutes',str(a.shift_minutes),'--window','60','--every','10',
             '--label',a.run+'-shift'+str(shift)+'-'+state['runtime'],
             '--out',dest/(a.run+'-performance-shift'+str(shift)+'.json')]
        with (archive/f'performance-shift{shift}.jsonl').open('a') as log:
            proc=subprocess.Popen([str(x) for x in cmd],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        collectors.append(proc);return proc
    def finish_bench(proc,shift):
        if proc is None:return
        try:code=proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGTERM);code=proc.wait(timeout=15)
        if code:alert(op,'performance-collector-exit',f'shift {shift}: {code}; partial stdout retained')
        with (archive/f'factorio-shift{shift}.log').open('wb') as log:
            subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',os.environ.get('IMAC_HOST','imac.local'),
                            'cat /Users/owner/pog-mt21/data/factorio-current.log'],stdout=log,check=True,timeout=90)
    def wait_for(predicate,limit):
        end=min(deadline,time.time()+limit)
        while time.time()<end:
            if stop.is_set():raise RuntimeError('rehearsal interrupted')
            used=weekly_usage(a.quota_profile)
            if used is None:raise RuntimeError(f'{a.quota_profile} weekly quota is unavailable or stale')
            if used>a.quota_stop:raise RuntimeError(f'{a.quota_profile} weekly {used}% exceeds {a.quota_stop}% stop rule')
            if predicate():return
            record(engineering_profile=a.quota_profile,engineering_weekly=used);stop.wait(10)
        raise RuntimeError('rehearsal phase timed out')
    try:
        record()
        wait_for(lambda:(op/'full-run.json').exists(),600)
        os.environ.update(read(op/'full-env.json'))
        record(runtime=command(['git','rev-parse','HEAD'],cwd=ROOT).strip(),shift_minutes=a.shift_minutes)
        first=read(op/'full-run.json');assert first['minutes']==a.shift_minutes and first['max_shifts']==1
        assert len(first['agents'])==6 and all(full_run.live_client(r) for r in first['agents'].values())
        names='{'+','.join(json.dumps(t) for t in sorted({r['team'] for r in first['agents'].values()}))+'}'
        initial=json.loads(rcon('local out={tick=game.tick,version=script.active_mods.base,teams={}}; '
            'for _,n in ipairs('+names+') do local f=game.forces[n]; out.teams[n]={players=#f.players,connected=#f.connected_players} end; '
            'rcon.print(helpers.table_to_json(out))'))
        record(initial=initial,baseline=os.environ.get('POG_MT_FRESH_SAVE'),agent_count=len(first['agents']))
        game=call('mt_game');market=call('mt_market')
        assert game['config']['target']=='solar-system-edge' and not game['config'].get('deadline_tick'),game['config']
        assert not game.get('result') and game['config'].get('wipe_win')!='auto',game
        assert all(market['settings'].get(k) is True for k in ('destructible','wreck','research_enabled')),market['settings']
        assert not market['audit']['faults'],market['audit']
        record(game_preflight=game,market_preflight=market)
        with lock(op/'agents.lock'):
            first=read(op/'full-run.json')
            end=(int(time.time()/60)+a.shift_minutes+1)*60
            for row in first['agents'].values():full_run.set_deadline(row,end)
            write(op/'full-run.json',first)
        rcon('game.tick_paused=false; rcon.print(game.tick)')
        record(phase='shift1',shift1_resumed=time.time(),shift1_end=max(r['deadline'] for r in first['agents'].values()))
        if a.measure:
            with (op/'metrics.log').open('a') as log:
                metrics=subprocess.Popen([sys.executable,ROOT/'tools/mt/rehearsal_metrics.py',a.run,'--execute'],cwd=ROOT,
                                         stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            with (op/'helpers.pid').open('a') as out:out.write(str(metrics.pid)+'\n')
        bench=start_bench(1)
        wait_for(lambda:read(op/'full-run.json')['phase']=='shifts-complete',(a.shift_minutes+10)*60)
        record(phase='restore',shift1_complete=time.time())
        finish_bench(bench,1)
        result=restore.drill(a.run,allow_unlisted_stream=a.unlisted);record(restore=result['exact'])
        with lock(op/'agents.lock'):
            current=read(op/'full-run.json');current.update(phase='running',max_shifts=2)
            full_run.change(op,current,list(current['agents']),a.shift_minutes,reason='shift')
            full_run.indexes(op,current);write(op/'full-run.json',current)
        with (op/'full-watch.log').open('a') as log:
            watcher=subprocess.Popen([sys.executable,ROOT/'tools/mt/full_run.py','watch',a.run],cwd=ROOT,
                                     stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        with (op/'helpers.pid').open('a') as out:out.write(str(watcher.pid)+'\n')
        rcon('game.tick_paused=false; rcon.print(game.tick)')
        record(phase='shift2',shift2_resumed=time.time(),shift2_end=max(r['deadline'] for r in current['agents'].values()))
        bench=start_bench(2)
        if a.unlisted:
            from rehearsal_stream import RecoveryProof
            wait_for(RecoveryProof(a.run,result['stream_before']),600)
            record(stream_restore_verified=time.time())
        wait_for(lambda:read(op/'full-run.json')['phase']=='shifts-complete',(a.shift_minutes+10)*60)
        record(phase='completed',shift2_complete=time.time())
        finish_bench(bench,2)
    except Exception as e:
        state['errors'].append(str(e));record(phase='failed');alert(op,'rehearsal-failed',e)
    finally:
        if a.unlisted:
            try:
                from rehearsal_stream import stop_publication
                stop_publication(a.run)
            except Exception as e:
                state['errors'].append('publication stop: '+str(e));record(phase='failed')
                alert(op,'rehearsal-publication-stop-failed',e)
        for proc in collectors:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=15)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
        with (op/'rehearsal-stop.log').open('a') as log:
            result=subprocess.run([ROOT/'tools/mt/stop-mt.sh',a.run],cwd=ROOT,env=dict(os.environ,POG_STOP_WORLD='1'),
                                  stdout=log,stderr=subprocess.STDOUT,timeout=240)
        status=command([ROOT/'tools/mt/imac_mt.sh','status'])
        record(ended=time.time(),stop_exit=result.returncode,server=status.strip())
        if result.returncode==0 and status.startswith('not running'):
            alert(op,'rehearsal-claim-retained','server stopped; restore prior saves/mods/config and verify before releasing claim')
        else:alert(op,'rehearsal-teardown-needs-review',status)
    print(json.dumps(state),flush=True)
    return bool(state['errors'])

if __name__=='__main__':sys.exit(main())
