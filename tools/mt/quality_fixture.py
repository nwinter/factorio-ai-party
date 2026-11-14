#!/usr/bin/env python3
"""Supply a labelled quality/spoilage trade exercise in an active 2.1 test pact.

The agents choose and execute transfers. This does not create pacts, move depot
items, unlock technologies, or change another world's state.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'tools/stream'),str(ROOT/'tools/mt')]
from harness import Harness,lua_string,one_line
from team_views import Reader


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('run');p.add_argument('--execute',action='store_true')
    a=p.parse_args();assert re.fullmatch(r'[A-Za-z0-9_-]{1,24}',a.run)
    op=ROOT/'runs'/a.run/'op'
    receipt=op/'quality-fixture.json'
    assert not receipt.exists(),'already supplied; inspect receipt instead of duplicating items'
    roster={}
    for line in (op/'teams.tsv').read_text().splitlines():
        if line and not line.startswith('#'):
            team,name,*_=line.split('\t');roster.setdefault(team,[]).append(name)
    assert set(roster)=={'green','yellow','blue'} and all(len(v)==2 for v in roster.values())
    contact=json.loads((op/'contact-fixture.json').read_text())
    assert contact['run']==a.run and contact['phase']=='ready'
    if not a.execute:
        print('Plan: save before supplying each pair with 50 uncommon iron, 50 rare copper and 20 bioflux at 40% spoilage; agents exercise quality-preserving trade and verify 20% cut.')
        return
    h=Harness('imac2');r=Reader()
    state=json.loads(h.command('/silent-command rcon.print(helpers.table_to_json{version=script.active_mods.base,paused=game.tick_paused})'))
    assert state['version']=='2.1.24' and not state['paused']
    pacts=r.op('mt_pacts')['pacts']
    assert any(p['status']=='active' and 'depot' in p['terms'] for p in pacts),'requires an agent-accepted trade pact'
    bots=r.bots();leaders={names[0]:team for team,names in roster.items()}
    chosen=[b for b in bots if b['name'] in leaders]
    assert len(chosen)==3 and all(b['alive'] and b['force']==leaders[b['name']] for b in chosen)
    h.command('/silent-command game.server_save('+lua_string(a.run+'-before-quality')+')')
    meta={'run':a.run,'phase':'preparing','started':time.time(),'pacts_before':pacts}
    receipt.write_text(json.dumps(meta,indent=2))
    payload=lua_string(json.dumps(leaders))
    raw=h.command('/silent-command '+one_line("""
local names=helpers.json_to_table(PAYLOAD)
local bots=helpers.json_to_table(remote.call("agent_harness","bots")).bots
local targets={}
for _,b in ipairs(bots) do if names[b.name] then
 assert(b.alive and b.force==names[b.name],"unexpected roster character")
 local es=game.surfaces.nauvis.find_entities_filtered{type="character",force=b.force,position=b.position,radius=1}
 local chosen,best=nil,math.huge
 for _,e in ipairs(es) do local dx,dy=e.position.x-b.position.x,e.position.y-b.position.y;local d=dx*dx+dy*dy;if d<best then chosen,best=e,d end end
 assert(chosen and best<.01,"cannot locate "..b.name)
 targets[#targets+1]={bot=b,entity=chosen}
end end
assert(#targets==3,"missing roster character")
local out={}
for _,target in ipairs(targets) do
 local b,e=target.bot,target.entity
 local kit={{name="iron-plate",count=50,quality="uncommon"},{name="copper-plate",count=50,quality="rare"},{name="bioflux",count=20,spoil_percent=.4}}
 local given={}
 for _,spec in ipairs(kit) do given[#given+1]={item=spec.name,quality=spec.quality or "normal",spoil_percent=spec.spoil_percent,count=e.insert(spec)} end
 out[#out+1]={name=b.name,team=b.force,given=given}
end
rcon.print(helpers.table_to_json(out))
""".replace('PAYLOAD',payload)))
    try:meta['supplied']=json.loads(raw)
    except ValueError:
        meta.update(phase='failed',error=raw[:1500]);receipt.write_text(json.dumps(meta,indent=2))
        raise RuntimeError(raw[:1500]) from None
    receipt.write_text(json.dumps(meta,indent=2))
    text='First finish your normal iron/copper/science exchange already agreed, then do this advanced check. Controlled advanced trade fixture: your first roster agent received 50 uncommon iron plates, 50 rare copper plates and 20 bioflux already 40 percent spoiled (check actual insertion/counts in inventory). These are supplied test items, not earned production or unlocked technology. With an active depot, coordinate with your teammate and counterpart: send a distinct quality stack and bioflux, then verify receive count after the 20 percent cut, exact quality and that freshness was not reset. Your teammate independently inspects the receipt and reports agreement or discrepancy. Use board/tells/chat for your own teammate; use diplomacy_send {to: TEAM, text: MESSAGE} and diplomacy {with: TEAM} for the other team. Ordinary say/chat/tells stay private to your team. Do not mix normal and quality counts. After receipt, negotiate a modest amendment at the SAME depot and verify its inventories survive. If no active pact, first negotiate and accept one with an available counterpart. Do not repeatedly retry a failed call.'
    for team in roster:r.op('mt_rules',{'team':team,'text':text,'summary':'Supplied quality/spoilage trade test: verify quality, cut, freshness, then same-depot amendment with teammate.'})
    meta.update(phase='ready',finished=time.time());receipt.write_text(json.dumps(meta,indent=2))
    print(json.dumps({'phase':'ready','receipt':str(receipt)}))


if __name__=='__main__':main()
