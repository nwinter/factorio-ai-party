#!/usr/bin/env python3
"""Operator-only fast track: save a running 2.1 test, stage real chart contact.

Keeps factories and team-private stores. Relocates only the launched roster into
an empty Nauvis test plaza, supplies a documented trade kit, and lets the engine
produce contact events. Never edits contact records or accepts pacts for agents.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'tools/stream'),str(ROOT/'tools/mt')]
from harness import Harness,lua_string,one_line


def run_fixture(run,execute):
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,24}',run)
    op=ROOT/'runs'/run/'op'
    roster={}
    for line in (op/'teams.tsv').read_text().splitlines():
        if line and not line.startswith('#'):
            team,name,*_=line.split('\t');roster.setdefault(team,[]).append(name)
    assert list(roster)==['green','yellow','blue'] and all(len(v)==2 for v in roster.values()),'requires paired test roster'
    receipt=op/'contact-fixture.json'
    assert not receipt.exists(),'fixture already attempted: inspect receipt before another run'
    if not execute:
        print('Plan: preserve '+run+'-before-contact, stage six roster agents at an empty central plaza with a supplied trade kit, trigger real chart events, deliver diplomacy objectives.')
        return
    h=Harness('imac2')
    def lua(code):
        raw=h.command('/silent-command '+one_line(code))
        try:return json.loads(raw)
        except ValueError:raise RuntimeError(raw[:1500]) from None
    log=[]
    def call(action,args=None,bot=None):
        req={'id':'fixture-'+uuid.uuid4().hex[:12],'action':action,'args':args or {}}
        if bot:req['bot']=bot
        else:req['operator']=True
        raw=h.command('/silent-command rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(req))+'))')
        out=json.loads(raw);log.append({'request':req,'response':out});return out
    engine=lua("rcon.print(helpers.table_to_json{version=script.active_mods.base,tick=game.tick,paused=game.tick_paused})")
    assert engine['version']=='2.1.24' and not engine['paused']
    contacts=call('mt_contacts')['result'].get('contacts') or []
    assert not contacts,'start from a pre-contact save'
    for names in roster.values():
        pre=call('pacts',bot=names[0]);assert not pre['ok'] and 'no contact' in pre['error']['message']
    saved=run+'-before-contact'
    h.command('/silent-command game.server_save('+lua_string(saved)+')')
    meta={'run':run,'phase':'preparing','before':engine,'save_before':saved,'center':{'x':150,'y':150},'supplied':{'iron-plate':200,'copper-plate':100,'steel-plate':50,'automation-science-pack':50,'wooden-chest':4},'calls':log}
    receipt.write_text(json.dumps(meta,indent=2))
    try:
        h.command('/silent-command game.tick_paused=true')
        for names in roster.values():
            for name in names:
                assert call('queue_cancel',{'clear':True},name)['ok']
                assert call('wait_ticks',{'ticks':1},name)['ok']
        names={name:team for team,pair in roster.items() for name in pair}
        bots=json.loads(h.command('/silent-command rcon.print(remote.call("agent_harness","bots"))'))['bots']
        chosen=[b for b in bots if b['name'] in names]
        assert len(chosen)==6 and all(b['alive'] and b['force']==names[b['name']] for b in chosen)
        meta['relocated_from']=chosen
        payload=lua_string(json.dumps({'bots':chosen,'kit':meta['supplied']}))
        prepared=lua("""
local a=helpers.json_to_table(PAYLOAD)
local s=game.surfaces.nauvis
s.request_to_generate_chunks({150,150},3);s.force_generate_chunk_requests()
for _,e in ipairs(s.find_entities_filtered{area={{102,102},{198,198}}}) do
 assert(e.force.name=='neutral' or e.force.name=='enemy','test plaza contains an owned entity')
end
for _,e in ipairs(s.find_entities_filtered{area={{102,102},{198,198}}}) do e.destroy() end
local tiles={} for x=102,198 do for y=102,198 do tiles[#tiles+1]={name='refined-concrete',position={x,y}} end end s.set_tiles(tiles)
local centers={green={x=126,y=150},yellow={x=174,y=150},blue={x=150,y=174}}
local count,out={},{}
for _,b in ipairs(a.bots) do
 local es=s.find_entities_filtered{type='character',force=b.force,position=b.position,radius=1}
 assert(#es==1,'cannot uniquely locate '..b.name)
 local e=es[1];count[b.force]=(count[b.force] or 0)+1
 local c=centers[b.force];local p={x=c.x+4*(count[b.force]-1),y=c.y}
 assert(e.teleport(p,s),'teleport failed')
 local given={} for item,n in pairs(a.kit) do given[item]=e.insert{name=item,count=n} end
 out[#out+1]={name=b.name,team=b.force,position=e.position,given=given}
end
for name,c in pairs(centers) do
 s.create_entity{name='wooden-chest',position={c.x+.5,c.y+5.5},force=name}
 game.forces[name].chart(s,{{102,102},{198,198}})
end
rcon.print(helpers.table_to_json(out))
""".replace('PAYLOAD',payload))
        meta['prepared']=prepared
    except Exception as e:
        meta.update(phase='failed',error=str(e))
        raise
    finally:
        h.command('/silent-command game.tick_paused=false')
        receipt.write_text(json.dumps(meta,indent=2))
    for _ in range(10):
        contacts=call('mt_contacts')['result'].get('contacts') or []
        pairs={tuple(sorted((r['team'],r['other']))) for r in contacts if r['team'] in roster and r['other'] in roster}
        if len(pairs)==3:break
        time.sleep(1)
    assert len(pairs)==3,contacts
    meta['contacts']=contacts
    objectives={
      'green':'Negotiate with Yellow first: propose a cease-fire, equal shares, and a trade depot at (150,134) on Nauvis. Agree terms with your teammate before proposing; ask Yellow to accept. Deposit 100 iron plates and verify what Yellow receives after the 20 percent cut. Later propose one modest amendment and have your teammate verify the result.',
      'yellow':'Review Green\'s first proposal with your teammate. If it is a cease-fire with fair shares and a depot near (150,134), accept it, inspect the depot, and verify the received iron after the 20 percent cut. Return 50 copper plates. Later negotiate independently with Blue; keep your team\'s internal discussion private.',
      'blue':'Negotiate a separate cease-fire and equal-share pact with Yellow. Use a depot near (166,166), send 50 automation science packs, and verify the delivery with your teammate. After a successful exchange, exercise pact amendment or end with a clear team decision and explanation.'}
    rules='Controlled contact/trade test: your pair has been relocated to a central test plaza and given iron, copper, steel, science packs and chests. Your original factory remains. Inspect current status and position rather than walking to old tasks. You have encountered other forces. Pact tools now unlock: pacts, pact_propose, pact_accept, pact_decline, pact_withdraw, pact_amend, pact_end. Cease-fire stops attacks but does not share chart or permit access to foreign inventories. A depot moves items between your own send/receive chests with a 20 percent cut. Describe schemas before using them. This is a test fixture, not earned production. Coordinate privately with your teammate through your own board/tells/chat. For the OTHER team use diplomacy_send {to: TEAM, text: MESSAGE} and read diplomacy {with: TEAM}; ordinary say/chat/tells do not reach them. Pact notes also carry offers. Report observed failures without repeatedly retrying identical requests. '
    for team,note in objectives.items():
        reply=call('mt_rules',{'team':team,'text':rules+note,'summary':'Contact test: inspect new position, coordinate with teammate, negotiate and verify pact trade.'})
        assert reply['ok'],reply
    for pair in roster.values():assert call('pacts',bot=pair[0])['ok']
    meta.update(phase='ready',contacts=contacts,finished=time.time())
    receipt.write_text(json.dumps(meta,indent=2))
    h.command('/silent-command game.server_save('+lua_string(run+'-contact-ready')+')')
    print(json.dumps({'phase':meta['phase'],'contacts':len(contacts),'teams':list(roster),'receipt':str(receipt)}))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run');p.add_argument('--execute',action='store_true')
    a=p.parse_args();run_fixture(a.run,a.execute)
