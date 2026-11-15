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

def drill(run, allow_unlisted_stream=False):
    op=op_dir(run);os.environ.update(read(op/'full-env.json'));pinned()
    stream_before=None
    if allow_unlisted_stream:
        from rehearsal_stream import before_restore
        stream_before=before_restore(run)
    else:
        assert not (op/'public-session.json').exists(),'closed drill only; unlisted stream requires explicit opt-in'
    receipt=op/'restore-drill.json'
    assert not receipt.exists(),'drill receipt already exists'
    with lock(op/'agents.lock'):
        state=read(op/'full-run.json')
        change(op,state,list(state['agents']),reason='restore-hold',hold=True)
        indexes(op,state);write(op/'full-run.json',state)
        rcon('game.tick_paused=true; rcon.print(game.tick)')
        before=fingerprint();write(receipt,dict(phase='paused',before=before,at=time.time()))
        camera=rcon('local p=game.get_player("pog-cam1"); rcon.print(p and p.connected and "yes" or "no")').strip()=='yes'
        path,row=checkpoint(run)
        write(receipt,dict(phase='archived',before=before,archive=str(path),proof=row,at=time.time()))
        if camera:command([sys.executable,ROOT/'tools/mt/imac_cam.py','stop'],timeout=90)
        command([ROOT/'tools/mt/imac_mt.sh','stop'],timeout=90)
        command([ROOT/'tools/mt/imac_mt.sh','start',path],timeout=240)
        after=fingerprint()
        # Bot counters can include volatile wall-clock observations. The stable engine
        # tick, research and profiles are compared separately from the full evidence.
        exact={k:before[k]==after[k] for k in ('tick','paused','forces','profiles')}
        write(receipt,dict(phase='verified' if all(exact.values()) else 'mismatch',before=before,after=after,
                           exact=exact,archive=str(path),proof=row,at=time.time(),stream_before=stream_before))
        if not all(exact.values()):
            alert(op,'restore-mismatch',exact);raise RuntimeError('restore mismatch; world left paused, agents held')
        if camera:
            # A disconnected native renderer stays in its modal, so relaunch it.
            # Exact loaded-state proof is captured above, before any join ticks.
            try:
                rcon('game.tick_paused=false')
                joined=command([sys.executable,ROOT/'tools/mt/imac_cam.py','start'],timeout=300)
            except Exception as e:
                result=read(receipt);result.update(phase='camera-failed',error=str(e));write(receipt,result)
                raise
            finally:rcon('game.tick_paused=true')
            health=json.loads(rcon('local p=game.get_player("pog-cam1"); rcon.print(helpers.table_to_json{tick=game.tick,connected=p and p.connected or false})'))
            result=read(receipt);result['camera']=dict(health,detail=joined);write(receipt,result)
            assert health['connected'],'restored camera did not rejoin'
        # Caller owns when the next shift begins. No stream operation or fresh setup.
        return read(receipt)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true')
    a=p.parse_args()
    if not a.execute:print('Closed drill: hold agents, pause, verify archive, reload exact save; leave paused for next shift.');return
    print(json.dumps(drill(a.run),indent=2))

if __name__=='__main__':main()
