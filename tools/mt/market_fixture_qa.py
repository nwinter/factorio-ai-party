#!/usr/bin/env python3
"""Verify a disposable prepared map at accelerated simulation speed, with no agents.

Run after saving the canonical paused prepared baseline. This consumes that loaded
map; restore the baseline afterward for both actual trials, at normal game speed.
"""
import argparse
import json
from pathlib import Path
import time
from market_fixture import Client, ROOT, RELEASE
from market_metrics import SNAPSHOT

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true');a=p.parse_args()
    if not a.execute:print('Plan: ten simulated minutes of prepared-base QA; no agent or server launch.');return
    claim=Path('/Users/owner/code/pog-operator/server-claim.txt');assert claim.exists() and 'eng-mt296' in claim.read_text()
    dst=ROOT/'runs'/a.run/'op/market-fixture-qa.json';assert not dst.exists(),'inspect existing QA before retry'
    c=Client();out={'phase':'running','samples':[]};dst.parent.mkdir(parents=True,exist_ok=True)
    try:
        c.lua('''assert(storage.mt296_fixture and not storage.mt296_fixture.activated)
assert(not next(storage.agent_harness.bots and storage.agent_harness.bots.by_index or {}),'QA requires no agents')
assert(not next(storage.agent_harness.mt.first or {}),'QA must stay pre-contact')
'''+RELEASE+'''game.speed=20;game.tick_paused=false;rcon.print('{}')''')
        first=c.lua(SNAPSHOT);out['samples'].append(first)
        for elapsed in (60,600):
            deadline=time.time()+240
            while True:
                s=c.lua(SNAPSHOT)
                if s['tick']>=first['tick']+elapsed*60:break
                assert time.time()<deadline,'fixture QA simulation timeout';time.sleep(2)
            out['samples'].append(s);dst.write_text(json.dumps(out,indent=2)+'\n')
            for team,row in s['teams'].items():
                for item in ('iron-plate','copper-plate','copper-cable','iron-gear-wheel','electronic-circuit','automation-science-pack'):
                    assert row['made'][item]>first['teams'][team]['made'][item],f'{team}: no {item} produced'
            assert not s['contact'],'fixture contacted before activation'
        out['measured']={t:{'ore_left_after_ten_minutes':r['poor_ore'],
            'produced':{n:v-first['teams'][t]['made'][n] for n,v in r['made'].items()}} for t,r in s['teams'].items()}
        assert all(r['poor_ore']<=30 for r in s['teams'].values()),'poor patch did not deplete near ten minutes'
        out['phase']='passed'
    except Exception as e:out.update(phase='failed',error=str(e));raise
    finally:
        c.h.command('/silent-command game.tick_paused=true; game.speed=1')
        dst.write_text(json.dumps(out,indent=2)+'\n')
    print(dst)

if __name__=='__main__':main()
