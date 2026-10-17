-- Run from the harness root: lua tests/d17_batch17.lua
-- d17 batch17 module contracts (the runtime ones are in tests/d17_batch17_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A1: what goes up beside a load: cargo aboard not in the list, and automatic requests on.
do
  defines={inventory={rocket_silo_rocket=21}}
  prototypes={item={['gun-turret']={weight=20000,stack_size=50},['solid-fuel']={weight=1000,stack_size=50},['iron-plate']={weight=1000,stack_size=100}}}
  game={tick=0}
  local cargo={get_contents=function() return {{name='gun-turret',quality='normal',count=1},{name='solid-fuel',quality='normal',count=10}} end}
  local silo={valid=true,use_transitional_requests=true,get_inventory=function(i) if i==21 then return cargo end end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local up=R.goes_up_with(silo,{{name='solid-fuel',quality='normal',count=10}})
  eq(up.foreign,'gun-turret 1')
  has(up.auto_requests,'automatic requests are on')
  has(up.line,'aboard and not in this load, goes up with it: gun-turret 1; automatic requests are on')
  silo.use_transitional_requests=false
  up=R.goes_up_with(silo,{{name='gun-turret',count=1},{name='solid-fuel',count=10}})
  eq(up.line,nil,'nothing foreign, requests off')
end
print('d17_batch17 A1 what goes up with a load: ok')

-- A4 (Sol 10:56: salvage on Meridian took 26 tiles under underground pipe spans and cut propulsion): salvage keeps
-- every tile an underground belt or pipe-to-ground span passes under, paired as the floor plan pairs them.
do
  game={tick=0}
  prototypes={entity={['pipe-to-ground']={fluidbox_prototypes={{pipe_connections={{},{max_underground_distance=10}}}}},
    ['underground-belt']={max_underground_distance=5}}}
  local tiles={}
  for x=0,9 do for y=0,9 do tiles[#tiles+1]={position={x=x,y=y}} end end
  local function ent(t,name,x,y,dir,io) return {valid=true,type=t,name=name,position={x=x,y=y},direction=dir,belt_to_ground_type=io,
    bounding_box={left_top={x=x-.4,y=y-.4},right_bottom={x=x+.4,y=y+.4}}} end
  -- a pipe tunnel along the edge column x=9, from (9.5,0.5) south to (9.5,6.5); each faces its pipe, outward
  local ents={ent('pipe-to-ground','pipe-to-ground',9.5,0.5,0),ent('pipe-to-ground','pipe-to-ground',9.5,6.5,8)}
  local s={find_tiles_filtered=function() return tiles end,find_entities_filtered=function(f)
    if f.type=='tile-ghost' then return {} end
    if type(f.type)=='table' then local out={} for _,e in ipairs(ents) do for _,t in ipairs(f.type) do if e.type==t then out[#out+1]=e end end end return out end
    return ents
  end}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){}
  local taken=PP.salvage(s,{},{position={x=0.5,y=0.5},valid=true},100)
  assert(#taken>0,'some tiles go')
  for _,t in ipairs(taken) do assert(not (t.x==9 and t.y>=1 and t.y<=5),'a tile under the pipe span was taken: ('..t.x..','..t.y..')') end
  for _,t in ipairs(taken) do assert(not (t.x==9 and (t.y==0 or t.y==6)),'an endpoint tile was taken') end
end
print('d17_batch17 A4 salvage keeps tiles under underground pipe spans: ok')

-- A5 (Astra, board #842: Swift's reserve tanks had no departure guard): wait_until fluid_count and circuit_signal on a
-- platform, and platform_schedule's conditions in the forms circuit_set takes.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={hub_main=1}}
  prototypes={item={['iron-plate']={}},fluid={['thruster-fuel']={},water={}},virtual_signal={['signal-A']={}}}
  game={tick=0}
  local tanks={{get_fluid_count=function(f) return f=='thruster-fuel' and 6000 or 0 end},{get_fluid_count=function(f) return f=='thruster-fuel' and 5000 or 0 end}}
  local red={get_signal=function(s) return s.name=='thruster-fuel' and 11000 or 0 end}
  local hub={valid=true,get_circuit_network=function(id) return id==1 and red or nil end}
  local swift={valid=true,name='Swift',hub=hub,surface={find_entities_filtered=function(f) assert(f.type=='storage-tank'); return tanks end}}
  local p={force={platforms={swift}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  C.validate({['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=10000})
  local met,saw=C.check(p,{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=10000})
  eq(met,true); has(saw,"thruster-fuel 11000 in Swift's 2 storage tanks")
  met=C.check(p,{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000})
  eq(met,false)
  met,saw=C.check(p,{['until']='circuit_signal',platform='Swift',signal='thruster-fuel',at_least=10000})
  eq(met,true); has(saw,"thruster-fuel 11000 on Swift's hub (red)")
  assert(not pcall(C.validate,{['until']='fluid_count',platform='Swift',fluid='iron-plate',at_least=1}),'a fluid name')
  assert(not pcall(C.validate,{['until']='circuit_signal',platform='Swift',signal='nonsense',at_least=1}),'a known signal')
  hub.get_circuit_network=function() return nil end
  met,saw=C.check(p,{['until']='circuit_signal',platform='Swift',signal='thruster-fuel',at_least=1})
  eq(met,false); has(saw,'no red or green wire')
end
print('d17_batch17 A5 fluid_count and circuit_signal waits: ok')

-- A6 (Gemini 10:56): platform_bom {surface}: every platform's active requests importing from that planet, short ones.
do
  defines={inventory={hub_main=1}}
  prototypes={space_location={gleba={},nauvis={}},item={}}
  local function hub(held, filters)
    return {valid=true,get_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end,
      get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
  end
  local swift={valid=true,name='Swift',space_location={name='nauvis'},hub=hub({['agricultural-science-pack']=120},{
    {value={name='agricultural-science-pack'},min=500,import_from={name='gleba'}},{value={name='bioflux'},min=40,import_from='gleba'},
    {value={name='processing-unit'},min=50,import_from={name='nauvis'}}})}
  local wren={valid=true,name='Wren',space_location={name='gleba'},hub=hub({bioflux=40},{{value={name='bioflux'},min=40,import_from={name='gleba'}}})}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){}
  local r=B.read({force={platforms={swift,wren}}},{surface='gleba'})
  eq(#r.requests,3,'nauvis requests left out')
  eq(r.lines[1],'Swift (at nauvis) lacks from gleba: agricultural-science-pack 380 (asks 500, holds 120), bioflux 40 (asks 40, holds 0)')
  eq(#r.lines,1,'Wren holds what it asks')
  assert(not pcall(B.read,{force={platforms={}}},{surface='nowhere'}),'a planet')
end
print('d17_batch17 A6 platform_bom by surface: ok')

-- B1 (Haiku: a rearm walked into attack #5203 at the guns it went to): an attack that starts at a tour's stop while the
-- walk is under way holds the walk short until the attack has had no hit for 30 s, then it goes on; said in held_short.
do
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local function integer(v,d) return v or d end
  local f={is_chunk_visible=function() return true end}
  local p={force=f,position={x=0,y=0},reach_distance=10}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  local turret={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=76,y=-191}}
  local attack
  local stopped,navs=0,0
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=integer,
    goal_inside=function() return nil end,
    goal_check=function() return attack end,goal_text=function(_,to) return 'place' end,
    visit=function() return {transferred=10} end,
    request_path=function(_,nav) nav.requested=true end,navigate=function() navs=navs+1 end,stop_walking=function() stopped=stopped+1 end}
  local action=S.start_tour(p,'rearm',{turret},3600,{avoid_mode={}})
  local function step() game.tick=game.tick+1; return S.tick(p,action) end
  step(); assert(action.nav and action.nav.requested,'walking')
  -- the attack starts at the guns while the walk is under way
  attack={m={attack=true,name='attack #5203',x=70,y=-185}}
  for _=1,61 do step() end
  assert(action.holding,'held')
  has(action.held_short,'the stop (76,-191) is in attack #5203 at (70,-185), under attack now; the walk goes on when it has had no hit for 30 s')
  eq(stopped,1,'stopped walking once')
  local before=navs
  for _=1,30 do step() end
  eq(navs,before,'no walking while held')
  -- the attack over: the walk goes on (a new path)
  attack=nil
  for _=1,61 do step() end
  eq(action.holding,nil); eq(action.held_short,nil)
  p.position={x=74,y=-188}
  local r
  for _=1,5 do r=step(); if r then break end end
  eq(r,'topped_up')
end
print('d17_batch17 B1 a tour holds short of a live attack at its stop: ok')

-- B2 (Haiku ~6x: turrets in solar-panel pockets said only "no path request found a way"): an unreachable stop names
-- the fewest of our entities to mine for a way, as move_to does.
do
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local f={is_chunk_visible=function() return true end}
  local p={force=f,position={x=120,y=-80},reach_distance=10}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  local turret={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=143,y=-85}}
  local asked
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=function(v,d) return v or d end,
    request_path=function(_,nav) nav.requested=true end,
    navigate=function(_,nav) nav.why='no path request found a way for the character to (143,-85), nor to anywhere within 4 tiles of it'; nav.reachable={x=139.5,y=-80.5}; return 'unreachable' end,
    stop_walking=function() end,
    corridor=function(_,from,goal,near) asked={from=from,goal=goal,near=near}
      return {mine={{name='solar-panel',position={x=141,y=-82}},{name='solar-panel',position={x=141,y=-85}}},from={x=139.5,y=-80.5},to={x=141.6,y=-85}} end}
  local action=S.start_tour(p,'rearm',{turret},3600,{})
  local r
  for _=1,3 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  has(action.first_unreached,'(143,-85): unreachable: no path request found a way')
  has(action.first_unreached,'mining solar-panel (141,-82) and solar-panel (141,-85) opens a way from (139.5,-80.5) to (141.6,-85.0)')
  eq(asked.from.x,139.5,'from the nearest reachable point')
  eq(#action.mine_for_a_way,2)
end
print('d17_batch17 B2 an unreachable tour stop names what to mine: ok')
