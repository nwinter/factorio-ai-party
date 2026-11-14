#!/usr/bin/env python3
"""Private minute samples: progress, contacts, market, quota, UPS and heap.

No messages or game changes. Restore
outages are recorded as gaps. Quota is account-wide; resets are separate periods.
"""
import argparse
import json
from pathlib import Path
import signal
import threading
import time

from run_state import alert, lock, op_dir, pinned, read, write
from map_probe import call, lua


def quota_snapshot():
    b=read(Path.home()/'.cache/ai-usage/agent-brief.json',{})
    return dict(generated_at=b.get('generated_at'),profiles=[{k:p.get(k) for k in
        ('command','source','observed_at','stale','available','windows','status_note')} for p in b.get('profiles',[])
        if p.get('command') in ('codex-b','agy','grok','muse')])


def world():
    return lua('local h=storage.agent_harness; rcon.print(helpers.table_to_json{tick=game.tick,paused=game.tick_paused, '
        'speed=game.speed,version=script.active_mods.base,heap_kb=collectgarbage("count"),fault=h.runtime_fault})',True)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run')
    p.add_argument('--every',type=int,default=60)
    p.add_argument('--execute',action='store_true');a=p.parse_args()
    assert a.every>=10
    if not a.execute:print(f'Private {a.every}s samples; no agent messages or profiler.');return
    op=op_dir(a.run);pinned();stop=threading.Event()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    archive=Path('/Volumes/POG Media/pog-runs/team-runs')/a.run/'metrics'
    assert Path('/Volumes/POG Media').is_mount();archive.mkdir(parents=True,exist_ok=True)
    previous=None;last_error=0;seq=0
    with lock(op/'metrics.lock'),(archive/'samples.jsonl').open('a') as out:
        while not stop.is_set():
            started=time.time();row=dict(at=started,quota=quota_snapshot());seq+=1
            state=read(op/'full-run.json',{})
            if state.get('phase')=='stopped':break
            row['agents']={n:{k:v.get(k) for k in ('kind','route','shift','held','hold_reason','rest_until','started','completed')}
                           for n,v in state.get('agents',{}).items()}
            row['rehearsal_phase']=read(op/'rehearsal.json',{}).get('phase')
            row['stream']={name:{k:v for k,v in read(op/(name+'.json'),{}).items()
                                if k in ('phase','heartbeat','health','video','privacy','warnings','available_gib','nonpaged_gib')}
                           for name in ('public-stream','public-session','memory')}
            try:
                pinned();row['world']=w=world()
                assert w['version']=='2.1.24' and w['speed']==1,w
                row['ups']=None
                if previous and w['tick']>=previous[1] and not w['paused'] and not previous[2]:
                    row['ups']=(w['tick']-previous[1])/(started-previous[0])
                previous=(started,w['tick'],w['paused'])
                row['game']=call('mt_game');row['contacts']=call('mt_contacts');row['market']=call('mt_market')
                row['shipments']=lua('local out={}; local m=storage.agent_harness.mt.market; '
                    'for key,p in pairs(m.pairs or {}) do for _,t in ipairs(p.transactions or {}) do '
                    'if t.status=="in_transit" then for _,l in ipairs(t.legs) do out[#out+1]={pair=key,id=t.id,mode=l.mode, '
                    'position=l.entity and l.entity.valid and l.entity.position or l.position,unit=l.unit} end end end end; '
                    'rcon.print(helpers.table_to_json(out))',True)
                if w.get('fault') or row['market']['audit']['faults']:
                    alert(op,'rehearsal-runtime-fault',dict(runtime=w.get('fault'),market=row['market']['audit']['faults']))
            except Exception as e:
                row['error']=str(e);previous=None
                if started-last_error>=300:alert(op,'metrics-gap',str(e));last_error=started
            out.write(json.dumps(row)+'\n');out.flush()
            write(op/'metrics-health.json',dict(at=time.time(),samples=seq,error=row.get('error'),archive=str(archive)))
            stop.wait(max(1,a.every-(time.time()-started)))


if __name__=='__main__':main()
