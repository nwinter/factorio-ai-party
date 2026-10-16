package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn);assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=0};defines={inventory={chest=1},direction={north=0}}
local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
local function pos(a) assert(type(a)=='table' and type(a.x)=='number' and type(a.y)=='number','position');return a end
local function integer(a,b,lo,hi) a=a or b;assert(a==math.floor(a) and a>=lo and a<=hi);return a end
-- Memory refuses hidden engine reads; remembered gaps/ghosts keep their tick.
do
  local mem,shown,list,reads={},true,{},0
  local f={name='player',is_chunk_visible=function() return shown end}
  local s={name='nauvis',find_entities_filtered=function() assert(shown,'hidden query');reads=reads+1;return list end}
  game.forces={player=f};game.surfaces={nauvis=s}
  local B=require('beltgaps'){state=function() return mem end,position=pos}
  local function belt(x,ghost)
    return {valid=true,name='transport-belt',type=ghost and 'entity-ghost' or 'transport-belt',ghost_name='transport-belt',ghost_type='transport-belt',
      position={x=x+.5,y=.5},direction=4,force=f,surface=s,bounding_box={left_top={x=x+.1,y=.1},right_bottom={x=x+.9,y=.9}}}
  end
  list={belt(0),belt(2,true)};game.tick=12
  local p={force=f,surface=s}
  local r=B.read(p,{from={x=.5,y=.5},to={x=2.5,y=.5}})
  eq(r.belts,1);eq(#r.missing,1);eq(r.missing[1].position.x,1.5);eq(#r.ghosts,1);eq(#r.unknown,0)
  eq(r.missing[1].observed_tick,12);eq(reads,1)
  shown=false;list={belt(1)};game.tick=60;B.tick(60)
  r=B.read(p,{from={x=.5,y=.5},to={x=2.5,y=.5}})
  eq(reads,1);eq(r.belts,1);eq(r.missing[1].observed_tick,12);eq(r.missing[1].current,false)
  r=B.read(p,{from={x=64.5,y=.5},to={x=66.5,y=.5}});eq(#r.unknown,3);eq(#r.missing,0);eq(reads,1)
  shown=true;game.tick=70
  local a,b=belt(0),belt(3);a.type='underground-belt';b.type='underground-belt';a.neighbours=b;b.neighbours=a;a.belt_to_ground_type='input';b.belt_to_ground_type='output';list={a,b}
  r=B.read(p,{from={x=.5,y=.5},to={x=3.5,y=.5}});eq(r.underground,2);eq(#r.missing,0)
  fails(function() B.read(p,{from={x=0,y=0},to={x=2,y=2}}) end,'horizontal or vertical')
  fails(function() B.read(p,{from={x=0,y=0},to={x=512,y=0}}) end,'512 tiles')
  list={};for i=1,1025 do list[i]=belt(1) end
  r=B.read(p,{from={x=.5,y=.5},to={x=3.5,y=.5}});eq(r.observations[1].capped,true);eq(r.observations[1].tick,70)
end
-- The cold surface, freeze flag, adjacent buffers and network links are separate.
do
  local heat={specific_heat=1000000,max_temperature=1000,min_working_temperature=15,max_transfer=1000000}
  local asm={name='assembler',heating_energy=100000/60,collision_box={left_top={x=-1.2,y=-1.2},right_bottom={x=1.2,y=1.2}}}
  local pipe={name='heat-pipe',type='heat-pipe',heat_buffer_prototype=heat,collision_box={left_top={x=-.4,y=-.4},right_bottom={x=.4,y=.4}}}
  local function footprint(pr,p) local b=pr.collision_box;return {left_top={x=p.x+b.left_top.x,y=p.y+b.left_top.y},right_bottom={x=p.x+b.right_bottom.x,y=p.y+b.right_bottom.y}} end
  local list={}
  local p={force={is_chunk_visible=function() return true end},surface={planet={prototype={entities_require_heating=true}},find_entities_filtered=function() return list end}}
  local H=require('heating'){footprint=footprint}
  local e={valid=true,name='assembler',type='assembling-machine',prototype=asm,position={x=.5,y=.5},direction=0,is_freezable=true,frozen=true,heat_neighbours={}}
  local r=H.inspect(p,e);eq(r.demand_kw,100);eq(r.frozen,true);eq(#r.heaters,0)
  local h={valid=true,name='heat-pipe',type='heat-pipe',prototype=pipe,position={x=2.5,y=2.5},direction=0,temperature=29,heat_neighbours={},is_freezable=false,frozen=false}
  list={h};r=H.inspect(p,e);eq(#r.heaters,1);eq(r.heaters[1].at_least_30c,false);assert(r.reason:find('below 30'))
  h.temperature=100;e.frozen=false;r=H.inspect(p,e);eq(r.heaters[1].at_least_30c,true);eq(r.frozen,false);eq(#r.heat_neighbours,0)
  h.position.x=3.5;r=H.inspect(p,e);eq(#r.heaters,0)
  -- A heat exchanger touching it is no heater (Sol, shift17 10:50; a private 2.0.77 server: one at 431 C and at 600 C
  -- left the machine beside it frozen); the reply states the rule.
  local hx={name='heat-exchanger',type='boiler',heat_energy_source_prototype=heat,collision_box={left_top={x=-1.4,y=-.9},right_bottom={x=1.4,y=.9}}}
  list={{valid=true,name='heat-exchanger',type='boiler',prototype=hx,position={x=.5,y=-1.5},direction=0,temperature=431}}
  e.frozen=true;r=H.inspect(p,e);eq(#r.heaters,0);assert(r.reason:find('no built heater',1,true),r.reason)
  assert(r.heater_rule:find('a heat exchanger does not heat',1,true),r.heater_rule)
  local tower={name='heating-tower',type='reactor',heat_buffer_prototype=heat,collision_box={left_top={x=-1.4,y=-1.4},right_bottom={x=1.4,y=1.4}}}
  list={{valid=true,name='heating-tower',type='reactor',prototype=tower,position={x=.5,y=-2.5},direction=0,temperature=30}}
  r=H.inspect(p,e);eq(#r.heaters,1);eq(r.heaters[1].at_least_30c,true);assert(r.reason:find('thaws a few to about 30 s',1,true),r.reason)
  e.frozen=false;list={h}
  h.heat_neighbours={e};r=H.inspect(p,h);eq(r.thermal_mass_mj_per_c,1);eq(#r.heat_neighbours,1)
  local rows=H.plan(p,{{index=1,name='assembler',proto=asm,pos=e.position,dir=0},{index=2,name='heat-pipe',proto=pipe,pos={x=2.5,y=.5},dir=0}})
  eq(rows[1].proposed,true);eq(rows[1].frozen,nil);eq(rows[1].heaters[1].planned_index,2)
end
-- Refuelling uses stock's real tour/guard machinery, including belt pickup reach.
do
  local F,S,action,carried,capacity,targets,sources= nil,nil,nil,0,100,{},{}
  local f={is_chunk_visible=function() return true end}
  local p={force=f,position={x=0,y=0},character={prototype={item_pickup_distance=1}},reach_distance=10}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  p.surface={find_entities_filtered=function() return sources end}
  local function inv(e) return {get_item_count=function() return e.n end} end
  local function entity(x,n,t) local e={valid=true,type=t or 'furnace',name=t or 'furnace',force=f,position={x=x,y=0},n=n,unit_number=x};e.get_inventory=function() return inv(e) end;return e end
  local danger={}
  local function give(e,n) n=math.min(n,carried);e.n=e.n+n;carried=carried-n;return n end
  S=require('stock'){distance=distance,integer=integer,avoid_mode=function(v) return v~=false and {} or nil end,
    goal_inside=function(_,to) return danger[to.x] end,goal_check=function(_,_,to) return danger[to.x] end,goal_text=function(_,to) return 'enemy at '..to.x end,
    visit=function(pp,a,e)
      if a.op=='refuel_source' then return F.source_visit(pp,a,e) end
      return F.feed_visit(pp,a,e)
    end,request_path=function(_,nav) nav.requested=true end,navigate=function() end,stop_walking=function() end}
  F=require('fuelround'){distance=distance,position=pos,integer=integer,find_kinds=function() return targets end,fuel_inventory=inv,
    accepts=function() return true end,entity=function() return sources[1] end,held=function() return carried end,
    give=function(_,e,_,_,count) return {transferred=give(e,math.max(0,count-e.n))} end,
    start_tour=S.start_tour,screen=S.screen,tick=S.tick,start=function(_,a) action=a end,stop=function() end,
    take=function(_,e,_,_,n) local k=math.min(n,e.n,capacity-carried);e.n=e.n-k;carried=carried+k;return {transferred=k,inventory_full=carried==capacity} end,
    belt_count=function(e) return e.n end,belt_take=function(_,e,_,n) local k=math.min(n,e.n,capacity-carried);e.n=e.n-k;carried=carried+k;return k,k==0 and 'inventory_full' or nil end,
    chest_inventory=inv,give_chest=function(_,e,_,_,count) return {transferred=give(e,count)} end,feed_chests=function(_,b) return b.feeders or {} end}
  local function step(n) local result;for _=1,n or 1 do game.tick=game.tick+1;result=F.tick(p,action);if result then break end end;return result end
  local function start(from) return F.start(p,{radius=64,from=from or 'nearest'},'coal',10) end
  targets={entity(20,0),entity(40,0)};sources={entity(-20,50,'container')};game.tick=0
  start();eq(step(),nil);step();assert(action.nav.requested);eq(carried,0)
  p.position={x=-15,y=0};step();eq(carried,20);eq(action.fuel_round.taken,20)
  p.position={x=15,y=0};step();eq(targets[1].n,10);p.position={x=35,y=0};eq(step(),'topped_up');eq(targets[2].n,10)
  -- Capacity-limited takes return to the same chest; supply is not discarded.
  carried=0;capacity=10;targets={entity(2,0),entity(4,0)};sources={entity(0,30,'container')};p.position={x=0,y=0};start()
  local result;for _=1,20 do result=step();if result then break end end
  eq(result,'topped_up');eq(action.got,20);eq(action.fuel_round.taken,20);eq(sources[1].n,10)
  carried=0;capacity=3;targets={entity(2,0)};sources={entity(0,30,'container')};start()
  for _=1,30 do result=step();if result then break end end
  eq(result,'topped_up');eq(targets[1].n,10);eq(action.got,10);eq(action.fuel_round.taken,10)
  -- Belts require pickup reach, not transfer reach, and take six per six ticks.
  carried=0;capacity=100;targets={entity(8,0)};sources={entity(6,20,'transport-belt')};start();step();step();eq(carried,0);assert(action.nav.tolerance<1.5)
  p.position={x=5,y=0};step();eq(carried,6);step();eq(carried,6);step(5);step(5);eq(targets[1].n,10)
  -- Enemy source is skipped in favor of the safe one; all unsafe targets refuse.
  carried=0;targets={entity(8,0)};sources={entity(6,10,'container'),entity(12,10,'container')};danger[6]={};start();step();eq(action.fuel_round.source.targets[1].entity.position.x,12)
  danger[8]={};fails(start,'enemy reach');danger={}
  carried=0;targets={entity(8,0)};sources={};start();eq(step(),'out_of_items')
  -- feed_chests (Haiku, d15 06:20): the chests inserters feed the boilers from are topped up, not the boilers.
  carried=30;capacity=100;danger={};p.position={x=0,y=0}
  local boiler=entity(3,0,'boiler');local fc=entity(4,2,'container');boiler.feeders={fc,fc}
  targets={boiler};sources={}
  local out=F.start(p,{radius=64,from='nearest',feed_chests=true},'coal',10)
  eq(out.feed_chests,'1 chest that inserters feed those burners from, each topped up to 10 coal')
  eq(#action.targets,1); eq(action.targets[1].entity,fc)
  for _=1,10 do if step() then break end end
  eq(fc.n,10); eq(boiler.n,0)
  -- Over 1024 entities (Opus 01:51: a base-sized boiler area): refused with the counts by type and the types filter.
  targets={}
  for i=1,900 do targets[#targets+1]=entity(i,0,'boiler') end
  for i=1,300 do targets[#targets+1]=entity(i,1,'furnace') end
  fails(function() F.start(p,{radius=64,from='nearest'},'coal',10) end,
    'the area holds more than 1024 entities this refuel reads (900 boiler, 300 furnace); types: ["boiler"] (or entity names')
end
print('round0320b2: ok')
