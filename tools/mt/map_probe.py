#!/usr/bin/env python3
"""Disposable-map freight acceptance. Reload the untouched baseline after this probe.

Uses real market orders and shipment entities on Nauvis. Adds research, contacts,
three stand-in bots and stock only to the disposable running copy. Never saves it.
"""
import argparse
import itertools
import json
from pathlib import Path
import time
import uuid

from run_state import pinned, rcon, write


def lua(code, harness=False):
    # Scenario event listeners are separate from the harness mod's listeners.
    out = rcon(('__agent-harness__ ' if harness else '') + ' '.join(code.splitlines()))
    try:
        return json.loads(out)
    except ValueError:
        raise RuntimeError(out[:3000]) from None


def call(action, args=None, bot=None):
    q = dict(id='map-proof-'+uuid.uuid4().hex, action=action, args=args or {})
    q.update(dict(bot=bot) if bot else dict(operator=True))
    s = json.dumps(q)
    level = '='
    while ']'+level+']' in s:
        level += '='
    out = lua('rcon.print(remote.call("agent_harness","dispatch",['+level+'['+s+']'+level+']))')
    assert out.get('ok'), out
    return out['result']


def setup(names):
    names_lua = '{'+','.join(json.dumps(n) for n in names)+'}'
    before = lua('assert(script.active_mods.base=="2.1.24"); game.tick_paused=true; game.speed=1; '
                 'rcon.print(remote.call("agent_harness","bots"))')
    assert not before.get('bots'), 'requires a fresh disposable baseline, with no existing agents'
    lua('storage.mt307_path_proof={}; script.on_event(defines.events.on_script_path_request_finished,function(e) '
        'local length=0; for i=2,#(e.path or {}) do local a=e.path[i-1].position; local b=e.path[i].position; '
        'length=length+math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end; '
        'storage.mt307_path_proof[tostring(e.id)]={tick=game.tick,id=e.id,points=e.path and #e.path or 0, '
        'length=length,retry=e.try_again_later or false} end); rcon.print("{}")')
    for n in names:
        bot = 'proof-'+n
        lua('rcon.print(remote.call("agent_harness","bot_create",{name='+json.dumps(bot)+',force='+json.dumps(n)+'}))')
    lua('local h=storage.agent_harness; for _,n in ipairs('+names_lua+') do '
        'local f=game.forces[n]; f.technologies["mt-coinage"].enabled=true; '
        'f.technologies["mt-coinage"].researched=true; f.technologies["logistic-science-pack"].researched=true; '
        'for _,other in ipairs('+names_lua+') do if n~=other then h.mt.first["chart "..n..">"..other]=game.tick end end end; '
        'rcon.print("{}")', True)
    call('mt_market', {'profile':'full'})
    return before


def state():
    return lua('local m=storage.agent_harness.mt.market; local out={tick=game.tick,legs={},teams={},fault=storage.agent_harness.runtime_fault}; '
        'for key,p in pairs(m.pairs) do for _,tx in ipairs(p.transactions or {}) do for _,l in ipairs(tx.legs) do '
        'out.legs[#out.legs+1]={pair=key,id=tx.id,state=tx.status,escrow=tx.escrow,mode=l.mode,unit=l.unit, '
        'request=l.path_request,position=l.entity and l.entity.valid and l.entity.position or l.position, '
        'origin=l.origin,destination=l.destination,from=l.from,to=l.to,delivered=l.delivered,loss=tx.loss} end end end; '
        'for n,t in pairs(m.teams) do out.teams[n]={wallet=t.wallet,iron=t.post and t.post.valid and '
        't.post.get_inventory(defines.inventory.chest).get_item_count("iron-plate"), '
        'post=t.post and t.post.valid and t.post.position} end; rcon.print(helpers.table_to_json(out))', True)


def native_path(seller, buyer, before):
    src,dst=(before['teams'][n]['post'] for n in (seller,buyer))
    request=lua('local s=game.surfaces.nauvis; local p=prototypes.entity["mt-shipment"]; '
        f'local start=s.find_non_colliding_position("mt-shipment",{{{src["x"]},{src["y"]}}},16,.5); assert(start); '
        'local id=s.request_path{bounding_box=p.collision_box,collision_mask=p.collision_mask,start=start, '
        f'goal={{{dst["x"]},{dst["y"]}}},force=game.forces[{json.dumps(buyer)}],radius=12,can_open_gates=true}}; '
        'game.tick_paused=false; rcon.print(helpers.table_to_json{id=id,start=start})')
    for _ in range(120):
        paths=lua('rcon.print(helpers.table_to_json(storage.mt307_path_proof))')
        result=paths.get(str(request['id']))
        if result:
            lua('game.tick_paused=true; rcon.print("{}")')
            assert result['points']>0 and not result['retry'], result
            return dict(request=request, result=result, seller=seller,buyer=buyer)
        time.sleep(.5)
    raise RuntimeError(f'native path result timed out: {seller}->{buyer}')


def probe(names, directory, timeout=1800):
    pinned();directory.mkdir(parents=True, exist_ok=True)
    assert not (directory/'freight-proof.json').exists(), 'proof already exists; use a new evidence directory'
    write(directory/'before-probe.json', setup(names))
    results = []
    try:
        for seller,buyer in itertools.combinations(names,2):
            lua('local h=storage.agent_harness; local m=h.mt.market; '
                'for _,n in ipairs({'+json.dumps(seller)+','+json.dumps(buyer)+'}) do '
                'local p=m.teams[n].post; assert(p and p.valid); local b=h.bots.by_name["proof-"..n]; '
                'local pos=p.surface.find_non_colliding_position("character",p.position,16,.5); '
                'assert(b.character.teleport(pos,p.surface)); b.character.force.chart(p.surface,{{pos.x-32,pos.y-32},{pos.x+32,pos.y+32}}) end; '
                'assert(m.teams['+json.dumps(seller)+'].post.insert{name="iron-plate",count=100}==100); rcon.print("{}")', True)
            before = state()
            path=native_path(seller,buyer,before)
            write(directory/(seller+'-'+buyer+'-path.json'),path)
            call('sell', dict(item='iron-plate',price=1,keep=0,count=100), 'proof-'+seller)
            call('buy', dict(item='iron-plate',price=1,count=100), 'proof-'+buyer)
            started=time.time();observed=[];unit_seen=False
            lua('game.tick_paused=false; rcon.print("{}")')
            while time.time()-started<timeout:
                s=state();assert not s.get('fault'),s
                legs=[l for l in s['legs'] if l['from']==seller and l['to']==buyer]
                observed.append(s)
                if legs:
                    leg=legs[-1]
                    unit_seen |= leg.get('mode')=='unit'
                    assert leg.get('mode')!='timer', f'no connected native freight path: {seller}->{buyer}'
                    assert leg['state']!='lost',leg
                    if leg['state']=='delivered':
                        assert unit_seen and leg['delivered']==100 and leg['escrow']==0,leg
                        break
                time.sleep(1)
            else:raise RuntimeError(f'freight arrival timed out: {seller}->{buyer}')
            lua('game.tick_paused=true; rcon.print("{}")')
            positions=[l['position'] for s in observed for l in s['legs'] if l['from']==seller and l['to']==buyer and l.get('position')]
            assert len({(round(p['x']),round(p['y'])) for p in positions})>=3,'unit movement not observed'
            after=state()
            assert after['teams'][buyer]['iron']-before['teams'][buyer]['iron']==100,after
            audit=call('mt_market')['audit'];assert not audit['faults'] and audit['total']==audit['issuance'],audit
            result=dict(seller=seller,buyer=buyer,elapsed_wall=time.time()-started,path=path,arrival=leg,audit=audit)
            write(directory/(seller+'-'+buyer+'-samples.json'),observed)
            results.append(result);write(directory/'freight-proof.json',dict(complete=False,pairs=results))
            print(json.dumps(result),flush=True)
        write(directory/'freight-proof.json',dict(complete=True,pairs=results,disposable=True))
    finally:
        lua('game.tick_paused=true; rcon.print("{}")')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir',type=Path,required=True);p.add_argument('--teams',nargs='+',default=['green','yellow','blue'])
    p.add_argument('--execute',action='store_true');a=p.parse_args()
    if not a.execute:
        print('Disposable copy only: native shipment path, movement and 100-item arrival per pair; then reload untouched baseline.');return
    probe(a.teams,a.dir)


if __name__=='__main__':main()
