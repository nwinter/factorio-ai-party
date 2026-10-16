-- d16 batch7 (operator 15:15, agents' requests 12:20-14:49). Run from the harness root: lua tests/d16_batch7.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A3 (Haiku: belt_gaps refused a route with corners): a leg that is not straight follows the remembered belt from its
-- start, round its corners, across a gap toward the end; from the other end when the belt runs that way.
do
  game={tick=10}; defines={inventory={chest=1},direction={north=0}}
  local mem={}
  local f={name='player',is_chunk_visible=function() return true end}
  local list={}
  local s={name='nauvis',find_entities_filtered=function() return list end}
  game.forces={player=f}; game.surfaces={nauvis=s}
  local B=dofile('mod/agent-harness_0.1.0/beltgaps.lua'){state=function() return mem end,position=function(a) return a end}
  local function belt(x,y,dir)
    return {valid=true,name='transport-belt',type='transport-belt',position={x=x+.5,y=y+.5},direction=dir,force=f,surface=s,
      bounding_box={left_top={x=x+.1,y=y+.1},right_bottom={x=x+.9,y=y+.9}},get_item_count=function() return 1 end}
  end
  -- east along y=0 to x=4, south from (4,0) to (4,5) with (4,3) gone, then east to (6,5)
  for x=0,3 do list[#list+1]=belt(x,0,4) end
  list[#list+1]=belt(4,0,8); list[#list+1]=belt(4,1,8); list[#list+1]=belt(4,2,8); list[#list+1]=belt(4,4,8)
  list[#list+1]=belt(4,5,4); list[#list+1]=belt(5,5,4); list[#list+1]=belt(6,5,4)
  local p={force=f,surface=s,position={x=0,y=0}}
  local r=B.read(p,{from={x=.5,y=.5},to={x=6.5,y=5.5}})
  eq(r.tiles,12); eq(r.belts,11); eq(#r.missing,1); eq(r.missing[1].position.x,4.5); eq(r.missing[1].position.y,3.5)
  has(r.followed,'1 leg not straight: followed the remembered belt round its corners')
  -- from the downstream end: followed from the other end, the tiles in the order asked
  r=B.read(p,{from={x=6.5,y=5.5},to={x=.5,y=.5}})
  eq(r.tiles,12); eq(#r.missing,1)
  -- no belt remembered at either end: refused
  fails(function() B.read(p,{from={x=20.5,y=20.5},to={x=22.5,y=25.5}}) end,'not horizontal or vertical, and no belt remembered at either end')
  -- straight legs as before
  r=B.read(p,{from={x=.5,y=.5},to={x=3.5,y=.5}}); eq(r.belts,4); eq(r.followed,nil)
  defines=nil
end
print('d16_batch7 A3 belt_gaps follows corners: ok')

-- A8 (Sol 13:50: a long coolant collect woke the sleep every 30 s as queue_stalled): a collect standing at its machine
-- while the machine crafts is no stall; one whose machine stopped says so.
do
  game={tick=100}
  defines={entity_status={working=1,no_ingredients=2}}
  local st={active={}}
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return st end,integer=function(v,d) return v or d end}
  local crafting=true
  local m={valid=true,name='chemical-plant',position={x=3.5,y=4.5},is_crafting=function() return crafting end,crafting_progress=0.4,
    status=1}
  st.active[1]={kind='gather',wait=true,item='fluoroketone-cold-barrel',got=12,targets={{entity=m,position=m.position}}}
  local w=W.collect_waiting(1)
  eq(w.working,true); has(w.line,'collect waits at chemical-plant (3.5,4.5) for fluoroketone-cold-barrel: the machine works: the products come as it crafts (status working, craft 40%), got 12 so far')
  crafting=false; m.status=2
  w=W.collect_waiting(1)
  eq(w.working,false); has(w.line,'the machine is not crafting (status no_ingredients')
  st.active[1]={kind='move_to'}
  eq(W.collect_waiting(1),nil)
  defines=nil
end
print('d16_batch7 A8 a collect waiting on a working machine: ok')

-- A9 (Sonnet 15:20: load_silo waits ran out with an ingredient missing): what the silo lacks of each rocket-part
-- ingredient, for the next part and the parts left.
do
  game={tick=0}
  defines={inventory={assembling_machine_input=2,rocket_silo_rocket=3}}
  local held={['processing-unit']=10,['low-density-structure']=3,['rocket-fuel']=0}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=15.5,y=59.5},rocket_parts=48,prototype={rocket_parts_required=50},
    get_recipe=function() return {name='rocket-part',ingredients={{type='item',name='processing-unit',amount=10},{type='item',name='low-density-structure',amount=10},
      {type='item',name='rocket-fuel',amount=10}}} end,
    get_inventory=function(i) if i==2 then return {get_item_count=function(n) return held[n] or 0 end} end return nil end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local r=R.parts_short(silo)
  eq(#r.rows,2)
  eq(r.line,'the silo at (15.5,59.5) makes no part: low-density-structure: 7 short of the next part, 17 of the 2 parts left (its input holds 3); rocket-fuel: 10 short of the next part, 20 of the 2 parts left (its input holds 0)')
  held['low-density-structure']=20; held['rocket-fuel']=20
  eq(R.parts_short(silo),nil)
  -- switches as they stand (A12): load_silo never sets them
  silo.use_transitional_requests=false; silo.send_to_orbit_automatically=true
  eq(R.switches_text(silo),'automatic requests off, send to orbit automatically on')
  silo.use_transitional_requests=true
  has(R.switches_text(silo),'automatic requests on, send to orbit automatically on: the game fills and launches this silo\'s rockets for platforms\' requests')
  defines=nil
end
print('d16_batch7 A9 load_silo names the missing ingredient: ok')

-- A11 (Sol 15:22): a helper's train {stops, surface} was refused for the injected helper field.
do
  game={tick=0,train_manager={get_train_stops=function() return {} end,get_trains=function() return {} end},get_surface=function(n) return {name=n} end}
  local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}
  local r=T.stops({surface={name='aquilo'},force={}},{stops=true,surface='nauvis',helper=true})
  eq(r.surface,'nauvis'); eq(r.count,0)
  fails(function() T.stops({surface={name='aquilo'},force={}},{stops=true,limit=3}) end,'stops takes surface only (not limit)')
end
print('d16_batch7 A11 a helper call reads train stops: ok')
