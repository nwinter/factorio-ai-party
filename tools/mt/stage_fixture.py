#!/usr/bin/env python3
"""Supply a labelled 2.1 cargo/circuit exercise after all three pairs have met.

Only the isolated imac2 server is used. Save before staging; keep original bases,
pacts and identities. Agents perform the actual requests, wiring and launches.
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
from game_test import roster

PAYLOAD=['iron-plate','copper-plate','steel-plate','stone','coal','iron-ore','copper-ore',
         'iron-gear-wheel','copper-cable','electronic-circuit','advanced-circuit','processing-unit',
         'battery','plastic-bar','sulfur','solid-fuel','rocket-fuel','low-density-structure',
         'transport-belt','underground-belt','splitter','inserter','fast-inserter',
         'small-electric-pole','pipe','pipe-to-ground']

SETUP=r'''
local a=helpers.json_to_table(PAYLOAD)
local f=game.forces[a.team];local s=game.surfaces.nauvis;local x,y=a.x,a.y
s.request_to_generate_chunks({x,y},3);s.force_generate_chunk_requests()
local area={{x-36,y-32},{x+36,y+32}}
for _,e in ipairs(s.find_entities_filtered{area=area}) do
 assert(e.force.name=='neutral' or e.force.name=='enemy','fixture yard contains an owned entity')
end
for _,e in ipairs(s.find_entities_filtered{area=area}) do e.destroy() end
local tiles={} for xx=x-36,x+36 do for yy=y-32,y+32 do tiles[#tiles+1]={name='refined-concrete',position={xx,yy}} end end
s.set_tiles(tiles)
local out={team=a.team,researched={},entities={},supplied={},platforms={}}
for _,n in ipairs{'automation','automation-2','logistics','electronics','circuit-network','logistic-robotics',
 'construction-robotics','logistic-system','rocket-silo','space-platform','space-science-pack','quality-module'} do
 if f.technologies[n] then f.technologies[n].researched=true;out.researched[#out.researched+1]=n end
end
local function entity(name,dx,dy)
 local e=assert(s.create_entity{name=name,position={x+dx,y+dy},force=f},name)
 out.entities[name]={position=e.position,unit_number=e.unit_number};return e
end
local power=entity('electric-energy-interface',8,2);power.electric_buffer_size=1000000000;power.energy=1000000000;power.power_production=100000000
local p1=entity('substation',10,5);local p2=entity('substation',-4,5)
local w1=p1.get_wire_connector(defines.wire_connector_id.pole_copper,true)
local w2=p2.get_wire_connector(defines.wire_connector_id.pole_copper,true)
if not w1.is_connected_to(w2) then assert(w1.connect_to(w2)) end
local port=entity('roboport',0,10);port.energy=port.electric_buffer_size
assert(port.get_inventory(defines.inventory.roboport_robot).insert{name='logistic-robot',count=20}==20)
entity('constant-combinator',.5,-4.5)
entity('requester-chest',3.5,-4.5)
local provider=entity('passive-provider-chest',6.5,-4.5);assert(provider.insert{name='iron-plate',count=200}==200)
entity('storage-chest',9.5,-4.5)
local tank=entity('storage-tank',-12,-8);assert(tank.set_fluid(1,{name='water',amount=1000,temperature=50})==1000)
local silo=entity('rocket-silo',16,8);silo.rocket_parts=silo.prototype.rocket_parts_required;silo.energy=silo.electric_buffer_size
for _,name in ipairs{'Freight Store','Freight Lab'} do
 local pl=assert(f.create_space_platform{name=name,planet='nauvis',starter_pack='space-platform-starter-pack'})
 assert(pl.apply_starter_pack(true))
 pl.schedule={current=1,records={{station='nauvis',wait_conditions={{type='time',compare_type='and',ticks=360000}}}}};pl.paused=false
 local hub=assert(pl.hub);hub.providing_to_other_platforms=false
 local sec=hub.get_logistic_sections().add_section('Fixture storage')
 for i,item in ipairs(a.manifest) do
  sec.set_slot(i,{value={type='item',name=item,quality='normal',comparator='='},min=0,max=1000,request_from='planet',import_from='nauvis'})
 end
 sec.set_slot(#a.manifest+1,{value={type='item',name='agricultural-science-pack',quality='rare',comparator='='},min=0,max=1000,request_from='planet',import_from='nauvis'})
 if name=='Freight Store' then assert(hub.insert{name='iron-plate',count=100}==100) end
 out.platforms[#out.platforms+1]={name=pl.name,surface=pl.surface.name,hub=hub.position,iron=hub.get_item_count('iron-plate')}
end
for i,b in ipairs(a.bots) do
 local surface=game.surfaces[b.surface or 'nauvis']
 local es=surface.find_entities_filtered{type='character',force=f,position=b.position,radius=1}
 local e,best=nil,math.huge
 for _,v in ipairs(es) do local dx,dy=v.position.x-b.position.x,v.position.y-b.position.y;local d=dx*dx+dy*dy;if d<best then e,best=v,d end end
 assert(e and best<.01,'cannot locate '..b.name)
 assert(e.teleport({x-1+3*i,y},s))
 local given={}
 for _,item in ipairs(a.manifest) do given[item]=e.insert{name=item,count=1} end
 local extra={{name='iron-plate',count=100},{name='copper-plate',count=50},{name='electronic-circuit',count=20},
  {name='assembling-machine-2',count=2},{name='constant-combinator',count=2},{name='transport-belt',count=30},
  {name='inserter',count=10},{name='small-electric-pole',count=10},{name='repair-pack',count=10},
  {name='agricultural-science-pack',count=8,quality='rare',spoil_percent=.25}}
 for _,item in ipairs(extra) do given[item.name..'@'..(item.quality or 'normal')]=e.insert(item) end
 out.supplied[#out.supplied+1]={agent=b.name,position=e.position,items=given}
end
f.chart(s,{{x-64,y-64},{x+64,y+64}})
rcon.print(helpers.table_to_json(out))
'''


def instruction(names,prepared):
    ent=prepared['entities'];pos=lambda name:json.dumps(ent[name]['position'],separators=(',',':'))
    return (f'Controlled later-stage Factorio 2.1 exercise: your pair was relocated to a supplied yard with power, robots, '
        f'a ready silo at {pos("rocket-silo")}, and two of your own orbital platforms Freight Store and Freight Lab. '
        'The technology, structures and items are supplied test fixtures, not earned progress. Your previous base and pacts remain. '
        f'{names[0]} handles cargo/platforms; {names[1]} handles circuits, then independently cross-check each other. '
        'Send concrete private tells agreeing the plan, handing off work and reporting measured results; use the board. '
        'Read describe schemas before new calls. Cargo task: use cargo to weigh one each of '+', '.join(PAYLOAD)+'. '
        'Load those 26 kinds with load_silo, inspect the actual native rocket inventory, then unload three kinds to verify the changing slots. '
        'Also load four supplied rare agricultural science packs; verify quality and that their freshness is not reset. '
        'Launch to Freight Lab with the normal launch action and have your partner verify receipt. This tests dynamic 2.1 cargo, not just a settings echo. '
        'Platform task: enable providing_to_other_platforms on Freight Store; on Freight Lab request 10 iron plates with request_from:platforms '
        'and min_payload:1. Change only the minimum once, and toggle construction_requests off/on: verify the platform source and payload survive. '
        'Use shipment and actual hub counts to distinguish settings accepted from goods delivered. '
        f'Circuit task: wire the constant combinator at {pos("constant-combinator")} to the requester chest at {pos("requester-chest")}; '
        'set a 20-iron signal. On the chest enable set_requests and read.contents simultaneously with separate input/output wire selections; '
        'verify the settings and actual robot delivery from the supplied provider. '
        f'The water tank is at {pos("storage-tank")}: test contents/temperature readout, then segment-contents mode, and read back the settings. '
        'If a call fails, read its error/schema and change the request; report any unresolved defect without looping. '
        'After these checks, use remaining supplies to build a small working automated gear line and have your partner verify output. '
        'Keep doing useful work until the deadline; no kill rewards or market features are part of this exercise.')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('run');ap.add_argument('--execute',action='store_true');a=ap.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,20}',a.run)
    op=ROOT/'runs'/a.run/'op';receipt=op/'stage-fixture.json'
    teams=roster(op/'teams.tsv');assert set(teams)=={'green','yellow','blue'} and all(len(v)==2 for v in teams.values())
    assert not receipt.exists(),'fixture already attempted; inspect its receipt'
    if not a.execute:
        print('Plan: save; supply separate powered cargo/circuit yards and two own platforms per pair; agents execute and verify.');return
    h=Harness('imac2');r=Reader()
    def lua(code):
        raw=h.command('/silent-command '+one_line(code))
        try:return json.loads(raw)
        except ValueError:raise RuntimeError(raw[:1500]) from None
    engine=lua('rcon.print(helpers.table_to_json{version=script.active_mods.base,paused=game.tick_paused,tick=game.tick})')
    assert engine['version']=='2.1.24' and not engine['paused']
    contacts=r.op('mt_contacts').get('contacts') or []
    pairs={tuple(sorted((v['team'],v['other']))) for v in contacts if v['team'] in teams and v['other'] in teams and v['team']!=v['other']}
    assert len(pairs)==3,'later exercise requires prior real contact among the three pairs'
    h.command('/silent-command game.server_save('+lua_string(a.run+'-before-stage')+')')
    state={'run':a.run,'phase':'preparing','started':time.time(),'engine':engine,'supplied':True,'teleported':True,'teams':[]}
    def save():receipt.write_text(json.dumps(state,indent=2)+'\n')
    save()
    try:
        h.command('/silent-command game.tick_paused=true')
        bots=r.bots()
        for i,(team,names) in enumerate(teams.items()):
            chosen=[b for b in bots if b['name'] in names]
            assert len(chosen)==2 and all(b['alive'] and b['force']==team for b in chosen)
            for name in names:
                for action,args in [('queue_cancel',{'clear':True}),('wait_ticks',{'ticks':1})]:
                    q={'id':'stage-stop-'+str(time.time_ns()),'bot':name,'action':action,'args':args}
                    reply=lua('rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(q))+'))');assert reply['ok'],reply
            payload={'team':team,'bots':chosen,'x':1500+500*i,'y':1500,'manifest':PAYLOAD}
            row=lua(SETUP.replace('PAYLOAD',lua_string(json.dumps(payload))));state['teams'].append(row);save()
        for row in state['teams']:
            r.op('mt_rules',{'team':row['team'],'text':instruction(teams[row['team']],row),
                            'summary':'Supplied 2.1 cargo/circuit exercise: split work, measure actual delivery, cross-check with teammate.'})
        state['phase']='ready';state['finished']=time.time();save()
    except Exception as e:
        state.update(phase='failed',error=str(e));save();raise
    finally:
        h.command('/silent-command game.tick_paused=false')
    h.command('/silent-command game.server_save('+lua_string(a.run+'-stage-ready')+')')
    print(json.dumps({'phase':state['phase'],'receipt':str(receipt)}))


if __name__=='__main__':main()
