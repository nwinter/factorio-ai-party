#!/usr/bin/env python3
"""Prepared complementary bases for the private stage-1 market/control experiment.

prepare runs once on a fresh baseline, before agents. Save that map and
reuse its exact bytes for both treatments. activate performs real chart contact
and either enables markets/Coinage or keeps the same stock chest without markets.
No server is started here. The caller owns the shared-server claim.
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

TEAMS=('green','yellow')
TARGETS={'electronic-circuit':1800,'iron-gear-wheel':1500,'automation-science-pack':600}
CLAIM=Path('/Users/owner/code/pog-operator/server-claim.txt')

def require_claim(owner, path=CLAIM):
    assert owner in ('eng-mt296','eng-mt290'),'unknown server owner'
    assert path.exists() and owner in path.read_text(),owner+' server claim required'

PREPARE=r'''
assert(script.active_mods.base=='2.1.24','wrong engine')
assert(not storage.mt296_fixture,'fixture already exists')
local h=storage.agent_harness;assert(h and h.mt and not next(h.mt.first or {}),'requires fresh pre-contact map')
local sf=game.surfaces.nauvis;game.tick_paused=true;sf.always_day=true
h.mt.teams={green=true,yellow=true};h.mt.order={'green','yellow'};h.mt.market=nil
local fxt={version=1,prepared_tick=game.tick,teams={},targets=helpers.json_to_table(TARGETS),market=false,enemy_cease_fire=true}
storage.mt296_fixture=fxt
for k,name in ipairs{'green','yellow'} do
 local f=game.forces[name];local x,y=2000*k+.5,2000.5
 f.set_cease_fire(game.forces.enemy,true);game.forces.enemy.set_cease_fire(f,true)
 local area={{x-55,y-55},{x+55,y+55}}
 sf.request_to_generate_chunks({x,y},3);sf.force_generate_chunk_requests()
 for _,e in pairs(sf.find_entities_filtered{area=area}) do assert(e.force.name=='neutral' or e.force.name=='enemy','owned entity in fixture yard') end
 for _,e in pairs(sf.find_entities_filtered{area=area}) do e.destroy() end
 local tiles={};for xx=math.floor(x)-55,math.floor(x)+55 do for yy=math.floor(y)-55,math.floor(y)+55 do
  tiles[#tiles+1]={name='grass-1',position={xx,yy}}
 end end;sf.set_tiles(tiles)
 f.set_spawn_position({x=x,y=y},sf);h.mt.spawns[name]={nauvis={x=x,y=y}}
 f.research_queue={}
 for _,n in ipairs{'automation','logistics','electronics','steel-processing','electric-mining-drill','steam-power','automation-science-pack'} do
  if f.technologies[n] then f.technologies[n].researched=true end
 end
 f.technologies['mt-coinage'].researched=false;f.technologies['mt-coinage'].enabled=false
 local row={team=name,spawn={x=x,y=y},rich=k==1 and 'iron-ore' or 'copper-ore',poor=k==1 and 'copper-ore' or 'iron-ore',
  supplied={},entities={},poor_patch_ore=1200,poor_patch_expected_minutes=10}
 fxt.teams[#fxt.teams+1]=row
 local function make(n,dx,dy,d)
  assert(sf.can_place_entity{name=n,position={x+dx,y+dy},force=f,direction=d},'fixture collision: '..n..' at '..dx..','..dy)
  local e=assert(sf.create_entity{name=n,position={x+dx,y+dy},force=f,direction=d},n)
  if n=='inserter' then assert(e.pickup_position.x<e.drop_position.x,'fixture inserter must carry west to east') end
  local held=({['assembling-machine']=true,furnace=true,['mining-drill']=true,inserter=true,lab=true})[e.type]
  if held then e.disabled_by_script=true;assert(e.disabled_by_script,'fixture hold refused: '..n) end
  row.entities[#row.entities+1]={name=n,position=e.position,unit=e.unit_number,held=held};return e
 end
 local function put(e,n,count)
  local v=e.insert{name=n,count=count};assert(v==count,n..' insert short')
  row.supplied[n]=(row.supplied[n] or 0)+v
 end
 -- A labelled test power supply avoids varying coal logistics between arms.
 local power=make('electric-energy-interface',-3,4);power.electric_buffer_size=100000000;power.energy=100000000;power.power_production=10000000
 local poles={}
 for _,xx in ipairs{-36,-18,0,18,36} do for _,yy in ipairs{-36,-18,0,18,36} do
  local p=make('substation',xx,yy);poles[#poles+1]=p
 end end
 for i,p in ipairs(poles) do for j=i+1,#poles do
  local q=poles[j];local dx,dy=p.position.x-q.position.x,p.position.y-q.position.y
  if dx*dx+dy*dy<=18*18 then
   local a=p.get_wire_connector(defines.wire_connector_id.pole_copper,true)
   local b=q.get_wire_connector(defines.wire_connector_id.pole_copper,true)
   if not a.is_connected_to(b) then assert(a.connect_to(b)) end
  end
 end end
 local chest=make('steel-chest',4,0);row.stock_position=chest.position;row.stock_unit=chest.unit_number
 put(chest,'iron-plate',1750);put(chest,'copper-plate',500)
 -- Each drill outputs into its ore chest; a fueled furnace smelts into an output chest.
 -- Rich: 8 cells / 150 plates per minute. Poor: 4 cells / 75 plates per minute,
 -- 1,200 ore mined at 120/minute: the patch runs dry in about ten minutes.
 for j=1,12 do
  local rich=j<=8;local ore=rich and row.rich or row.poor
  local dx=-43+math.floor((j-1)/4)*13;local dy=-41+((j-1)%4)*10
  for xx=-2,2 do for yy=-2,2 do sf.create_entity{name=ore,position={x+dx+xx,y+dy+yy},amount=rich and 2000 or 12} end end
  make('electric-mining-drill',dx,dy,defines.direction.east)
  make('steel-chest',dx+2,dy)
  make('inserter',dx+3,dy,defines.direction.west)
  local furnace=make('stone-furnace',dx+4.5,dy+.5);put(furnace,'coal',50)
  make('inserter',dx+6,dy,defines.direction.west);make('steel-chest',dx+7,dy)
 end
 local function cell(recipe,dx,dy,inputs)
  local src=make('steel-chest',dx-3,dy);make('inserter',dx-2,dy,defines.direction.west)
  local machine=make('assembling-machine-1',dx,dy);machine.set_recipe(recipe);assert(machine.get_recipe().name==recipe)
  make('inserter',dx+2,dy,defines.direction.west);local dst=make('steel-chest',dx+3,dy)
  for n,c in pairs(inputs) do put(src,n,c) end
  return {recipe=recipe,input=src.position,output=dst.position,machine=machine.position}
 end
 row.production={cell('copper-cable',-32,8,{['copper-plate']=50}),cell('copper-cable',-32,15,{['copper-plate']=50}),
  cell('electronic-circuit',-15,8,{['iron-plate']=50,['copper-cable']=100}),cell('iron-gear-wheel',-15,15,{['iron-plate']=100}),
  cell('automation-science-pack',4,12,{['iron-gear-wheel']=20,['copper-plate']=20}),
  cell('automation-science-pack',4,20,{['iron-gear-wheel']=20,['copper-plate']=20}),
  cell('automation-science-pack',4,28,{['iron-gear-wheel']=20,['copper-plate']=20})}
 make('lab',24,30);make('lab',30,30)
 local kit=make('steel-chest',12,0);row.kit=kit.position
 for n,c in pairs{['transport-belt']=400,inserter=100,['small-electric-pole']=50,['wooden-chest']=20,
   ['assembling-machine-1']=8,['stone-furnace']=12,['electric-mining-drill']=4,coal=1000,['repair-pack']=20} do put(kit,n,c) end
 row.expected_target_inputs={['iron-plate']=4800,['copper-plate']=3300}
 -- Supplied gears do not reduce the target of 1,500 NEW gears. Do not double-count
 -- gears used in red science as additional production or iron demand.
 row.initial_metal_equivalent={['iron-plate']=1900,['copper-plate']=710}
 row.expected_shortfall=k==1 and 1390 or 1700
 row.grant_fraction=10000/(row.expected_shortfall*20)
 local stats=f.get_item_production_statistics(sf)
 row.prepared_counts={made={},used={}}
 for _,n in ipairs{'iron-plate','copper-plate','copper-cable','electronic-circuit','iron-gear-wheel','automation-science-pack'} do
  row.prepared_counts.made[n]=stats.get_input_count(n);row.prepared_counts.used[n]=stats.get_output_count(n)
 end
 f.chart(sf,area)
end
-- An isolated shared contact marker reveals neither base nor its distance.
local c={x=150.5,y=150.5};sf.request_to_generate_chunks(c,2);sf.force_generate_chunk_requests()
for _,e in pairs(sf.find_entities_filtered{area={{148,148},{156,154}}}) do assert(e.force.name=='neutral' or e.force.name=='enemy');e.destroy() end
sf.set_tiles{{name='grass-1',position={150,150}},{name='grass-1',position={153,150}}}
fxt.contact_area={{148,148},{156,154}}
rcon.print(helpers.table_to_json(fxt))
'''
ACTIVATE=r'''
local fxt=assert(storage.mt296_fixture,'prepare first');assert(not fxt.activated,'already activated')
assert(not next(storage.agent_harness.mt.first or {}),'contact must begin at activation')
game.tick_paused=true
local on=MARKET;fxt.market=on;fxt.started_tick=game.tick;fxt.activated=true
for _,row in ipairs(fxt.teams) do
 local st=game.forces[row.team].get_item_production_statistics(game.surfaces.nauvis)
 for n,v in pairs(row.prepared_counts.made) do assert(st.get_input_count(n)==v,'production before start: '..row.team..' '..n) end
 for n,v in pairs(row.prepared_counts.used) do assert(st.get_output_count(n)==v,'consumption before start: '..row.team..' '..n) end
 local e=assert(game.surfaces.nauvis.find_entity('steel-chest',row.stock_position));assert(e.unit_number==row.stock_unit)
 local i=e.get_inventory(defines.inventory.chest)
 assert(i.get_item_count('iron-plate')==1750 and i.get_item_count('copper-plate')==500,'stock moved before start')
end
BASELINE
local held={}
if on then
 for _,row in ipairs(fxt.teams) do
  local e=assert(game.surfaces.nauvis.find_entity('steel-chest',row.stock_position));assert(e.unit_number==row.stock_unit)
  local inv=e.get_inventory(defines.inventory.chest)
  held[row.team]=inv.get_contents();e.destroy()
 end
end
assert(game.surfaces.nauvis.create_entity{name='steel-chest',position={150.5,150.5},force='green'})
assert(game.surfaces.nauvis.create_entity{name='steel-chest',position={153.5,150.5},force='yellow'})
for _,row in ipairs(fxt.teams) do game.forces[row.team].chart(game.surfaces.nauvis,fxt.contact_area) end
-- Contact events are processed by the real engine on the next simulation tick.
storage.mt296_fixture.held=held
rcon.print(helpers.table_to_json{started_tick=fxt.started_tick,market=on})
'''
FINISH=r'''
local fxt=storage.mt296_fixture
for _,row in ipairs(fxt.teams) do
 local f=game.forces[row.team]
 if fxt.market then
  local t=storage.agent_harness.mt.market.teams[row.team]
  assert(t and t.post and t.post.valid,'contact did not create Post')
  assert(math.abs(t.post.position.x-row.stock_position.x)<.1 and math.abs(t.post.position.y-row.stock_position.y)<.1,'Post moved from stock chest position')
  for _,q in pairs(fxt.held[row.team]) do assert(t.post.insert(q)==q.count,'Post stock transfer short') end
  f.technologies['mt-coinage'].researched=true
 end
end
fxt.held=nil
RELEASE
rcon.print(helpers.table_to_json(fxt))
'''
RELEASE=r'''
for _,row in ipairs(storage.mt296_fixture.teams) do for _,v in ipairs(row.entities) do if v.held then
 local e=assert(game.surfaces.nauvis.find_entity(v.name,v.position),'fixture machine missing before activation')
 assert(e.unit_number==v.unit,'fixture machine replaced before activation');e.disabled_by_script=false
 assert(not e.disabled_by_script,'fixture release refused')
end end end
'''

class Client:
    def __init__(self): self.h=Harness('imac2')
    def lua(self,code):
        raw=self.h.command('/silent-command __agent-harness__ '+one_line('\n'.join(l for l in code.splitlines() if not l.lstrip().startswith('--'))))
        try:return json.loads(raw)
        except ValueError:raise RuntimeError(raw[:1800]) from None
    def call(self,action,args=None,bot=None,ident=None):
        q={'id':ident or 'm296-'+uuid.uuid4().hex,'action':action,'args':args or {}}
        q.update({'bot':bot} if bot else {'operator':True})
        r=self.lua('rcon.print(remote.call("agent_harness","dispatch",'+lua_string(json.dumps(q))+'))')
        if not r['ok']:raise RuntimeError(str(r))
        return r.get('result') or {}


def instructions(row,on):
    pos=lambda v:json.dumps(v,separators=(',',':'))
    cells='; '.join(v['recipe']+' input '+pos(v['input'])+' output '+pos(v['output']) for v in row['production'])
    text=("Prepared factory: power, technology, buildings and initial items are supplied, not earned. "
        f"Stock {'Post' if on else 'chest'} {pos(row['stock_position'])}; construction kit {pos(row['kit'])}. "
        f"Rich {row['rich']}; small {row['poor']} patch should run out around minute ten. "
        "For this experiment, replace the edge goal with: manufacture 1,800 electronic circuits, 1,500 iron gears and 600 red science packs after contact. "
        "Production counts score; supplied items, money and trade volume do not. Split work: one maintains smelting, "
        "input logistics and expansion; one supplies/connects production cells and verifies output. "
        "Automate input/output chests with belts and inserters. Keep useful work running while supplies arrive. "
        +("Coinage is researched. market {} shows the 10,000 coin grant, orders and accepting calls. Put surplus rich metal "
          "in the Post, sell with a safe keep/finite count, and buy scarce metal. Selling funds further buying. "
          "Orders are shared: coordinate once to avoid duplicates. Batches every 10s; delivery 90s. " if on else "")
        +"Use brief teammate handoffs; report concrete blockers/refusals; do not poll unchanged state. Cells: "+cells)
    assert len(text.encode())<=2000,'fixture brief exceeds harness limit'
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('action',choices=['prepare','activate','brief'])
    ap.add_argument('run');ap.add_argument('--market',choices=['on','off'],default='on');ap.add_argument('--execute',action='store_true')
    ap.add_argument('--claim-owner',choices=['eng-mt296','eng-mt290'],default='eng-mt296',
                    help='existing server claimant; eng-mt290 owns approved public launches')
    a=ap.parse_args();assert re.fullmatch(r'[A-Za-z0-9_-]{1,16}',a.run)
    if not a.execute:print(f'Plan: {a.action} {a.run}, market {a.market}; use the claimed imac2 server only.');return
    require_claim(a.claim_owner)
    op=ROOT/'runs'/a.run/'op';op.mkdir(parents=True,exist_ok=True)
    out=op/('market-'+a.action+'.json');assert not out.exists(),'receipt exists; inspect rather than retry'
    c=Client();receipt={'action':a.action,'run':a.run,'phase':'preparing','wall_started':time.time()}
    out.write_text(json.dumps(receipt,indent=2))
    try:
        if a.action=='prepare':
            receipt['fixture']=c.lua(PREPARE.replace('TARGETS',lua_string(json.dumps(TARGETS))))
            # Deployment needs simulation ticks. Save unpaused with production held;
            # POG_MT_PAUSED_START pauses after deploy, before any agent is launched.
            c.h.command('/silent-command game.tick_paused=false; game.server_save('+lua_string(a.run+'-base')+')')
        elif a.action=='activate':
            from market_metrics import BASELINE
            c.call('mt_market',{'config':{'enabled':a.market=='on'}})
            receipt['start']=c.lua(ACTIVATE.replace('MARKET','true' if a.market=='on' else 'false').replace('BASELINE',BASELINE))
            c.h.command('/silent-command game.tick_paused=false')
            for _ in range(20):
                contacts=c.call('mt_contacts').get('contacts') or []
                if any({v['team'],v['other']}==set(TEAMS) for v in contacts):break
                time.sleep(.25)
            else:raise RuntimeError('real chart contact did not occur')
            c.h.command('/silent-command game.tick_paused=true')
            c.call('mt_market')
            receipt['fixture']=c.lua(FINISH.replace('RELEASE',RELEASE))
            c.call('mt_market')
            c.h.command('/silent-command game.tick_paused=false')
        else:
            receipt['fixture']=c.lua('rcon.print(helpers.table_to_json(storage.mt296_fixture))')
            for row in receipt['fixture']['teams']:
                c.call('mt_rules',{'team':row['team'],'text':instructions(row,receipt['fixture']['market']),
                    'summary':'Prepared factory race: split production/logistics and keep both metals flowing.'})
        receipt.update(phase='ready',wall_finished=time.time())
    except Exception as e:
        receipt.update(phase='failed',error=str(e));raise
    finally:out.write_text(json.dumps(receipt,indent=2)+'\n')
    print(out)

if __name__=='__main__':main()
