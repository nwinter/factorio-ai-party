#!/usr/bin/env python3
"""Real Factorio 2.1 acceptance, split around a real server save/restart.

begin: pre-contact secrecy, swaps, cache eviction, teammates, in-transit save.
resume: replay after load, exact partial receiver, settlement, Coinage, raids.
Never starts or stops a server; requires eng-mt296's existing server claim.
"""
import argparse,json,time
from pathlib import Path
from market_fixture import Client,ROOT,lua_string

BOTS={'mg1':'green','mg2':'green','my1':'yellow','my2':'yellow','mb1':'blue'}
OFFER={'give':{'item':'iron-plate','count':100},'get':{'item':'copper-plate','count':80}}
INVERSE={'give':OFFER['get'],'get':OFFER['give']}


def wait(c,predicate,seconds=130):
    deadline=time.time()+seconds
    while time.time()<deadline:
        state=c.call('mt_market')
        if predicate(state):return state
        time.sleep(.5)
    raise RuntimeError('engine acceptance timeout')


def txn(state):
    p=state.get('pairs',{}).get('green>yellow',{})
    return (p.get('transactions') or [None])[0]


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('phase',choices=['begin','resume']);ap.add_argument('--execute',action='store_true');a=ap.parse_args()
    if not a.execute:print('Plan: '+a.phase+' real engine acceptance on claimed imac2.');return
    claim=Path('/Users/owner/code/pog-operator/server-claim.txt');assert claim.exists() and 'eng-mt296' in claim.read_text()
    folder=Path('/Users/owner/code/personal/player-of-games/artifacts/mt296');folder.mkdir(parents=True,exist_ok=True)
    receipt=folder/('engine-'+a.phase+'.json');assert not receipt.exists(),'receipt exists: inspect before retry'
    c=Client();evidence={'phase':a.phase,'status':'running','started':time.time(),'checks':[]}
    def record(name,data=True):evidence['checks'].append({'name':name,'data':data});receipt.write_text(json.dumps(evidence,indent=2)+'\n')
    def raw(action,args=None,bot='mg1',ident=None):
        q={'id':ident or 'engine-'+str(time.time_ns()),'bot':bot,'action':action,'args':args or {}}
        return c.lua('rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(q))+'))')
    try:
        engine=c.lua('rcon.print(helpers.table_to_json{version=script.active_mods.base,tick=game.tick,paused=game.tick_paused})')
        assert engine['version']=='2.1.24';record('engine',engine)
        if a.phase=='begin':
            have=c.lua('rcon.print(remote.call("agent_harness","bots"))').get('bots') or []
            have={b['name']:b for b in have}
            for name,team in BOTS.items():
                if name in have:
                    assert have[name]['force']==team and have[name]['alive'];continue
                r=c.lua('rcon.print(remote.call("agent_harness","bot_create",{name='+lua_string(name)+',force='+lua_string(team)+'}))')
                assert r.get('ok'),r
            for action in ('market','offer','buy','sell','cancel','embargo'):
                r=raw(action);assert not r['ok'] and r['error']['message']=='unsupported action; call describe',r
            describe=raw('describe')['result'];assert not set(describe['actions']).intersection({'market','offer','buy','sell','cancel','embargo'})
            record('precontact_surface_absent')
            c.lua('''
local h=storage.agent_harness;assert(not next(h.mt.first or {}));game.tick_paused=true
local sf=game.surfaces.nauvis;sf.request_to_generate_chunks({2500,2500},2);sf.force_generate_chunk_requests()
for _,p in ipairs{{2500.5,2500.5,'green'},{2504.5,2500.5,'yellow'}} do
 for _,e in ipairs(sf.find_entities_filtered{area={{p[1]-1,p[2]-1},{p[1]+1,p[2]+1}}}) do assert(e.force.name=='neutral' or e.force.name=='enemy');e.destroy() end
 sf.set_tiles{{name='grass-1',position={p[1],p[2]}}};assert(sf.create_entity{name='steel-chest',position={p[1],p[2]},force=p[3]})
end
game.forces.green.chart(sf,{{2498,2498},{2506,2502}})
game.tick_paused=false;rcon.print('{}')
''')
            wait(c,lambda s: all(s.get('teams',{}).get(t,{}).get('post') for t in ('green','yellow')),10)
            c.lua('''local m=storage.agent_harness.mt.market
assert(m.teams.green.post.insert{name='iron-plate',count=100}==100)
assert(m.teams.yellow.post.insert{name='copper-plate',count=80}==80)
rcon.print('{}')''')
            d=raw('describe')['result']['actions'];assert 'offer' in d and 'market' not in d and 'to' not in d['offer'];record('swap_rung_and_addressing')
            r=raw('offer',OFFER,ident='engine-durable-swap');assert r['ok'],r
            race=raw('offer',OFFER,bot='mg2');assert not race['ok'] and 'shared order' in race['error']['message'];record('teammate_race',race)
            r=raw('offer',INVERSE,bot='my1');assert r['ok'],r
            matched=wait(c,lambda s:txn(s) is not None,15);t=txn(matched);assert t['eta']-t['tick']==5400
            assert sum(l['removed'] for l in t['legs'])==180;record('matched_swap',t)
            c.lua('''local i=storage.agent_harness.mt.market.teams.yellow.post.get_inventory(defines.inventory.chest)
assert(i.is_empty())
for j=1,#i do i[j].set_stack{name='stone',count=prototypes.item.stone.stack_size} end
i[1].set_stack{name='iron-plate',count=prototypes.item['iron-plate'].stack_size-1};rcon.print('{}')''')
            # Evict the generic 256-entry mutation cache before the real save/load replay.
            c.lua('''for i=1,300 do
local q={id='engine-cache-'..i,bot='mg1',action='market',args={}}
remote.call('agent_harness','dispatch',helpers.table_to_json(q))
end
assert(not storage.agent_harness.cache['engine-durable-swap'])
rcon.print('{}')''')
            again=raw('offer',OFFER,ident='engine-durable-swap');assert again['ok'],again
            assert len(c.call('mt_market')['pairs']['green>yellow']['transactions'])==1
            record('replay_after_300_requests')
            c.h.command('/silent-command game.tick_paused=true; game.server_save("m296-engine-transit")')
            record('restart_required',{'save':'/Users/owner/pog-mt21/data/saves/m296-engine-transit.zip','transaction':t['id']})
        else:
            before=c.call('mt_market');assert txn(before)['status']=='in_transit';record('loaded_in_transit',txn(before))
            again=raw('offer',OFFER,ident='engine-durable-swap');assert again['ok'],again
            assert len(c.call('mt_market')['pairs']['green>yellow']['transactions'])==1
            c.h.command('/silent-command game.tick_paused=false')
            partial=wait(c,lambda s:txn(s)['status']=='waiting');t=txn(partial)
            legs={l['to']:l for l in t['legs']};assert legs['yellow']['delivered']==1 and legs['green']['delivered']==80;record('exact_partial_swap_after_load',t)
            c.lua('''storage.agent_harness.mt.market.teams.yellow.post.get_inventory(defines.inventory.chest)[2].clear()
rcon.print('{}')''')
            done=wait(c,lambda s:txn(s)['status']=='delivered',10);assert not done['audit']['faults'];record('swap_complete',done['audit'])
            # Force-specific technology research grants once, not once per Post or request.
            c.lua('''game.forces.green.technologies['mt-coinage'].researched=true
game.forces.yellow.technologies['mt-coinage'].researched=true
rcon.print('{}')''')
            state=wait(c,lambda s:s['audit']['issuance']==20000,10);record('coinage_grants',state['audit'])
            assert raw('market',bot='mb1')['ok'] is False
            x=raw('buy',{'item':'iron-ore','price':10,'count':1,'from':'blue'})
            y=raw('buy',{'item':'iron-ore','price':10,'count':1,'from':'invented'})
            assert x['error']['message']==y['error']['message'];record('unknown_counterparty_identical',x['error'])
            c.lua('''local t=storage.agent_harness.mt.market.teams
assert(t.green.post.insert{name='iron-ore',count=100}==100)
local i=t.yellow.post.get_inventory(defines.inventory.chest);i.clear()
for j=1,#i do i[j].set_stack{name='stone',count=prototypes.item.stone.stack_size} end
i[1].set_stack{name='iron-ore',count=prototypes.item['iron-ore'].stack_size-1}
rcon.print('{}')''')
            assert raw('sell',{'item':'iron-ore','price':10,'keep':0,'count':100})['ok']
            assert raw('buy',{'item':'iron-ore','price':20,'count':100},bot='my1',ident='engine-durable-buy')['ok']
            matched=wait(c,lambda s:len(s['pairs']['green>yellow']['transactions'])==2,15);t=matched['pairs']['green>yellow']['transactions'][1]
            assert t['price']==10 and t['escrow']==1000;assert matched['teams']['green']['wallet']==10000
            record('payment_waits_for_arrival',t)
            cancelled=raw('cancel',{'item':'iron-ore','side':'buy'},bot='my2');assert not cancelled['ok'];record('matched_cancel_refused',cancelled['error'])
            # Use the real human-freeze implementation; committed transit must still progress.
            c.call('mt_humans',{'team':'yellow','players':['m296-probe'],'test':True,
                'warm_min':0,'quiet_min':0,'block_h':.005,'offline_min':60})
            c.call('mt_freeze',{'start':True,'hours':.1})
            deadline=time.time()+10
            while c.call('mt_freeze')['state']!='frozen':
                assert time.time()<deadline,'freeze did not start';time.sleep(.25)
            state=wait(c,lambda s:s['pairs']['green>yellow']['transactions'][1]['status']=='waiting');t=state['pairs']['green>yellow']['transactions'][1]
            assert t['legs'][0]['delivered']==1 and t['escrow']==990 and state['teams']['green']['wallet']==10010;record('exact_partial_coin_and_freeze',t)
            c.call('mt_freeze',{'stop':True})
            c.lua('''storage.agent_harness.mt.humans=nil
local i=storage.agent_harness.mt.market.teams.yellow.post.get_inventory(defines.inventory.chest)
i[2].clear();i[3].clear()
rcon.print('{}')''')
            state=wait(c,lambda s:s['pairs']['green>yellow']['transactions'][1]['status']=='delivered',10)
            assert state['teams']['green']['wallet']==11000 and state['teams']['yellow']['wallet']==9000;record('coin_settled',state['audit'])
            c.call('mt_market',{'config':{'destructible':True}})
            c.lua('''local t=storage.agent_harness.mt.market.teams
-- Rebalance existing issuance for the specified arithmetic example; no new coin.
t.green.wallet=14000;t.yellow.wallet=6000
local p=t.green.post;p.destructible=true;assert(p.die(game.forces.yellow));rcon.print('{}')''')
            state=wait(c,lambda s:s['audit']['physical']==3500,10);assert state['teams']['green']['wallet']==10500;record('first_raid',state['audit'])
            c.lua('''local t=storage.agent_harness.mt.market.teams.green
assert(t.post and t.post.valid);t.post.destructible=true;assert(t.post.die(game.forces.yellow));rcon.print('{}')''')
            state=wait(c,lambda s:s['audit']['physical']==6125,10);assert state['teams']['green']['wallet']==7875;record('second_raid',state['audit'])
            coins=c.lua('''local m=storage.agent_harness.mt.market;local f=game.forces.green;local home=storage.agent_harness.mt.spawns.green.nauvis
local dst=m.teams.yellow.post.get_inventory(defines.inventory.chest)
for j=1,#dst do if dst[j].valid_for_read and dst[j].name=='stone' then dst[j].clear() end end
local n,ground,carried=0,0,{}
for _,e in ipairs(game.surfaces.nauvis.find_entities_filtered{type='item-entity',position=home,radius=64}) do
 if e.stack.valid_for_read and e.stack.name=='mt-coin' then
  local k=m.teams.yellow.post.insert(e.stack);e.stack.count=e.stack.count-k;n=n+k;ground=ground+k
 end
end
-- A nearby native character may have automatically picked up the looted spill.
for name,b in pairs(storage.agent_harness.bots.by_name) do if b.character and b.character.valid then
 local i=b.character.get_inventory(defines.inventory.character_main);local held=i.get_item_count('mt-coin')
 if held>0 then
  local k=m.teams.yellow.post.insert{name='mt-coin',count=held}
  assert(i.remove{name='mt-coin',count=k}==k);carried[name]=k;n=n+k
 end
end end
rcon.print(helpers.table_to_json{collected=n,ground=ground,carried=carried})''')
            assert coins['collected']==6125,coins
            record('native_coin_items_recovered',coins)
            state=wait(c,lambda s:s['audit']['physical']==0,10);assert state['teams']['yellow']['wallet']==12125
            assert not state['audit']['faults'];record('coin_recovery_conserves',state['audit'])
            c.h.command('/silent-command game.server_save("m296-engine-passed")')
        evidence.update(status='passed',finished=time.time())
    except Exception as e:evidence.update(status='failed',error=str(e));raise
    finally:receipt.write_text(json.dumps(evidence,indent=2)+'\n')
    print(receipt)

if __name__=='__main__':main()
