#!/usr/bin/env python3
"""Native legacy-depot migration probe, before and after deploying retired-depot code.

stage creates a real old-format accepted pact and stocks its send chest with 37 plates.
verify proves migration preserves stock/cease-fire/shares/obligations and credits a new market arrival.
Only on the engine acceptance map after market_engine.py resume passes. Never starts a server.
"""
import argparse
import json
from pathlib import Path
import time
from market_fixture import Client, lua_string
from market_engine import wait

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('phase',choices=['stage','verify']);p.add_argument('--execute',action='store_true');a=p.parse_args()
    if not a.execute:print('Plan: '+a.phase+' native depot migration on the claimed acceptance map.');return
    claim=Path('/Users/owner/code/pog-operator/server-claim.txt');assert 'eng-mt296' in claim.read_text()
    root=Path('/Users/owner/code/personal/player-of-games/artifacts/mt296')
    assert json.loads((root/'engine-resume.json').read_text())['status']=='passed'
    dst=root/('engine-migration-'+a.phase+'.json');assert not dst.exists()
    c=Client();out={'phase':a.phase,'status':'running'}
    def raw(action,args,bot='mg1'):
        q={'id':'migration-'+str(time.time_ns()),'bot':bot,'action':action,'args':args}
        return c.lua('rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(q))+'))')
    try:
        if a.phase=='stage':
            c.call('mt_pacts',{'config':{'move_s':216000}})
            c.lua('''local sf=game.surfaces.nauvis
for _,e in ipairs(sf.find_entities_filtered{area={{2518,2518},{2526,2523}}}) do assert(e.force.name=='neutral' or e.force.name=='enemy');e.destroy() end
local tiles={};for x=2518,2526 do for y=2518,2523 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end;sf.set_tiles(tiles)
rcon.print('{}')''')
            terms={'cease_fire':True,'shares':{'green':.5,'yellow':.5},'depot':{'x':2520,'y':2520},
                'obligations':[{'kind':'deliver','who':'green','item':'iron-plate','count':10}]}
            r=raw('pact_propose',{'with':'yellow','terms':terms});assert r['ok'],r
            pid=r['result']['pact']['id'];r=raw('pact_accept',{'id':pid},'my1');assert r['ok'],r
            out['pact_id']=pid
            out['before']=c.lua('''local p=storage.agent_harness.mt.pacts.by_id['''+str(pid)+''']
assert(p.status=='active');local ch=p.terms.depot.chests
assert(ch['green send'].insert{name='iron-plate',count=37}==37)
rcon.print(helpers.table_to_json{send=ch['green send'].get_inventory(defines.inventory.chest).get_item_count('iron-plate'),receive=ch['yellow receive'].get_inventory(defines.inventory.chest).get_item_count('iron-plate')})''')
            assert out['before']=={'send':37,'receive':0}
        else:
            pid=json.loads((root/'engine-migration-stage.json').read_text())['pact_id'];out['pact_id']=pid
            out['migrated']=c.lua('''local p=storage.agent_harness.mt.pacts.by_id['''+str(pid)+''']
assert(p.status=='active' and p.terms.depot==nil and p.legacy_depot)
assert(p.terms.cease_fire and p.terms.shares.green==.5 and p.terms.obligations[1].count==10)
assert(game.forces.green.get_cease_fire('yellow') and game.forces.yellow.get_cease_fire('green'))
local ch=p.legacy_depot.chests
assert(ch['green send'].get_inventory(defines.inventory.chest).get_item_count('iron-plate')==37)
assert(ch['yellow receive'].get_inventory(defines.inventory.chest).get_item_count('iron-plate')==0)
assert(storage.agent_harness.mt.market.teams.green.post.insert{name='iron-plate',count=10}==10)
rcon.print(helpers.table_to_json{status=p.status,retired_tick=p.depot_retired_tick,send=37,receive=0})''')
            r=raw('pact_amend',{'id':pid,'terms':{'depot':{'x':2520,'y':2520}}});assert not r['ok'] and 'depot retired' in r['error']['message'];out['refusal']=r['error']
            assert raw('sell',{'item':'iron-plate','price':20,'keep':0,'count':10})['ok']
            assert raw('buy',{'item':'iron-plate','price':20,'count':10},'my1')['ok']
            c.h.command('/silent-command game.speed=20; game.tick_paused=false')
            state=wait(c,lambda s:len(s['pairs']['green>yellow']['transactions'])==3 and s['pairs']['green>yellow']['transactions'][2]['status']=='delivered',120)
            out['audit']=state['audit'];assert not out['audit']['faults']
            out['arrived']=c.lua('''local p=storage.agent_harness.mt.pacts.by_id['''+str(pid)+''']
local received=0;for _,l in pairs(p.ledger) do received=received+((l.received and l.received.yellow or {})['iron-plate'] or 0) end
assert(received==10);assert(p.legacy_depot.chests['green send'].get_inventory(defines.inventory.chest).get_item_count('iron-plate')==37)
rcon.print(helpers.table_to_json{received=received,legacy_stock=37})''')
            c.h.command('/silent-command game.speed=1; game.server_save("m296-migration-passed")')
        out['status']='passed'
    except Exception as e:out.update(status='failed',error=str(e));raise
    finally:
        if a.phase=='verify':c.h.command('/silent-command game.speed=1')
        dst.write_text(json.dumps(out,indent=2)+'\n')
    print(dst)

if __name__=='__main__':main()
