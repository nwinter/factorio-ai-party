#!/usr/bin/env python3
"""Closed restore drill: stop clients, archive a paused restore point, reload and verify it."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

from run_state import ROOT, alert, command, lock, op_dir, pinned, read, rcon, write
from team_views import Reader
from full_run import change, indexes
from autosave import copy_new, verified


def fingerprint():
    value=json.loads(rcon('local out={tick=game.tick,paused=game.tick_paused,forces={}}; '
        'for _,name in ipairs({"green","yellow","blue"}) do local f=game.forces[name]; if f then '
        'local t={research={},progress=f.research_progress,queue={}}; '
        'for k,v in pairs(f.technologies) do if v.researched then t.research[k]=v.level end end; '
        'for _,q in ipairs(f.research_queue or {}) do t.queue[#t.queue+1]=q.name end; out.forces[name]=t end end; '
        'rcon.print(helpers.table_to_json(out))'))
    reader=Reader()
    value['bots']=reader.bots()
    value['profiles']={t:reader.profiles(n) for t,n in [('green','gemini'),('yellow','grok'),('blue','muse')]}
    return value

def checkpoint(run):
    # The save itself must contain tick_paused=true for exact loaded-tick verification.
    lua='rcon.print(remote.call("agent_harness","autosave_save",'+json.dumps(run)+'))'
    record=json.loads(rcon(lua))
    for _ in range(30):
        time.sleep(2)
        try:index=copy_new(run)
        except BlockingIOError:continue
        for row in index['copies']:
            if row['sequence']==record['sequence'] and row['tick']==record['tick'] and row['name']==record['name']:
                return verified(run,row['file'])
    raise RuntimeError('paused restore point never reached verified archive')

def drill(run):
    op=op_dir(run);os.environ.update(read(op/'full-env.json'));pinned()
    assert not (op/'public-session.json').exists(),'closed drill only'
    receipt=op/'restore-drill.json'
    assert not receipt.exists(),'drill receipt already exists'
    with lock(op/'agents.lock'):
        state=read(op/'full-run.json')
        change(op,state,list(state['agents']),reason='restore-hold',hold=True)
        indexes(op,state);write(op/'full-run.json',state)
        rcon('game.tick_paused=true; rcon.print(game.tick)')
        before=fingerprint();write(receipt,dict(phase='paused',before=before,at=time.time()))
        path,row=checkpoint(run)
        write(receipt,dict(phase='archived',before=before,archive=str(path),proof=row,at=time.time()))
        command([ROOT/'tools/mt/imac_mt.sh','stop'],timeout=90)
        command([ROOT/'tools/mt/imac_mt.sh','start',path],timeout=240)
        after=fingerprint()
        # Bot counters can include volatile wall-clock observations. The stable engine
        # tick, research and profiles are compared separately from the full evidence.
        exact={k:before[k]==after[k] for k in ('tick','paused','forces','profiles')}
        write(receipt,dict(phase='verified' if all(exact.values()) else 'mismatch',before=before,after=after,
                           exact=exact,archive=str(path),proof=row,at=time.time()))
        if not all(exact.values()):
            alert(op,'restore-mismatch',exact);raise RuntimeError('restore mismatch; world left paused, agents held')
        # Caller owns when the next shift begins. No stream operation or fresh setup.
        return read(receipt)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    if not a.execute:print('Closed drill: hold agents, pause, verify archive, reload exact save; leave paused for next shift.');return
    print(json.dumps(drill(a.run),indent=2))

if __name__=='__main__':main()
