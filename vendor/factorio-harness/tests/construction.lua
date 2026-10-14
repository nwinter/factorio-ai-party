local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn);assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function distance(a,b)return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
local function integer(v,default,lo,hi) v=v or default;assert(v%1==0 and v>=lo and v<=hi);return v end
prototypes={item={['transport-belt']={place_result={name='transport-belt',type='transport-belt'}}}}
defines={input_action={start_walking=1}}; game={tick=0}
local p={position={x=.5,y=2.5},build_distance=3,force={}}
local placed,stock,blocked={},100,nil
local function key(pos)return pos.x..','..pos.y end
local ghosts,marked,obstacles={},{},{}
p.surface={find_entities_filtered=function(a)
  if a.type=='entity-ghost' or (type(a.type)=='table' and a.type[1]=='entity-ghost') then return ghosts end
  if a.to_be_deconstructed then return marked end
  if type(a.type)=='table' and a.type[1]=='tree' then return obstacles end
  local e=placed[key(a.position)];return e and {e} or {}
end}
local C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  steer=function(_,target)p.target=target;p.walking=true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,
  reason=function(e)return tostring(e) end,waypoint_goal=function(_,_,goal)return goal end,
  request_path=function(_,a)a.path_state='pending';p.path_requests=(p.path_requests or 0)+1 end,
  navigate=function(_,nav)
    if p.walled then return 'blocked' end
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d);p.navigated=(p.navigated or 0)+1
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
  build=function(_,a)
    assert(distance(p.position,a.position)<=p.build_distance)
    assert(key(a.position)~=blocked,'placement blocked');assert(stock>0,'item is not in main inventory')
    stock=stock-1
    for _,g in ipairs(ghosts) do if key(g.position)==key(a.position) then g.valid=false;p.revived=a end end
    local direction=({north=0,east=4,south=8,west=12})[a.direction]
    placed[key(a.position)]={valid=true,name='transport-belt',direction=direction,force=p.force}
    return {consumed=1}
  end,
}
local points={{x=.5,y=.5},{x=10.5,y=.5},{x=10.5,y=5.5}}
local action=C.plan(p,{points=points})
eq(#action.cells,16);eq(action.cells[11].direction,8)
C.tick(p,action);assert(action.placed>0 and p.walking,'must place and walk in the same tick')
local function run(a)
  for _=1,1000 do
    local outcome=C.tick(p,a);if outcome then return outcome end
    if a.nav then goto continue end -- the pathfinder walk moves the character itself
    local dx,dy=p.target.x-p.position.x,p.target.y-p.position.y
    do local d=distance(p.position,p.target);p.position={x=p.position.x+dx/d*.25,y=p.position.y+dy/d*.25} end
    ::continue::
  end
  error('controller did not complete')
end
eq(run(action),'path_built');eq(stock,84)
-- A rejected placement reports an exact resume index without consuming that item.
p.position={x=20.5,y=2.5};blocked='24.5,0.5'
local route={{x=20.5,y=.5},{x=30.5,y=.5}}
local broken=C.plan(p,{points=route});eq(run(broken),'build_failed');eq(broken.next_index,5);eq(broken.placed,4)
blocked=nil
local resumed=C.plan(p,{points=route,start_index=broken.next_index});eq(run(resumed),'path_built');eq(resumed.placed,7)
-- Existing matching belts are skipped, conflicting directions are never overwritten.
p.position={x=20.5,y=2.5};local rerun=C.plan(p,{points=route});eq(run(rerun),'path_built');eq(rerun.placed,0);eq(rerun.skipped,11)
p.position={x=20.5,y=2.5};placed['20.5,0.5'].direction=0
local conflict=C.plan(p,{points=route});eq(C.tick(p,conflict),'build_failed');eq(conflict.next_index,1)
fails(function()C.plan(p,{points={{x=0,y=0},{x=1,y=0}}})end,'tile centres')
fails(function()C.plan(p,{points={{x=.5,y=.5},{x=1.5,y=1.5}}})end,'axis aligned')
fails(function()C.plan(p,{points={{x=.5,y=.5},{x=2.5,y=.5},{x=.5,y=.5}}})end,'revisits')
-- A far start is reached with the pathfinder, not by steering straight at it.
p.position={x=.5,y=30.5};p.path_requests=0;p.navigated=0;p.walking=false
local far=C.plan(p,{points={{x=60.5,y=.5},{x=62.5,y=.5}}})
eq(run(far),'path_built');eq(p.path_requests,1);assert(p.navigated>100);eq(far.placed,3)
p.position={x=.5,y=30.5};p.walled=true
local walled=C.plan(p,{points={{x=70.5,y=.5},{x=72.5,y=.5}}})
eq(C.tick(p,walled),'blocked');assert(walled.error:find('could not walk to tile 1 (70.5,0.5): blocked',1,true),walled.error)
p.walled=nil
-- Along the line the character steers directly; no progress for 120 ticks is a stall.
p.position={x=36.8,y=.5}
local stalled=C.plan(p,{points={{x=40.5,y=.5},{x=42.5,y=.5}}})
for _=1,120 do eq(C.tick(p,stalled),nil); game.tick=game.tick+1 end
eq(C.tick(p,stalled),'blocked')
-- Jittering in place (a belt pushing back) is not progress either.
p.position={x=37.3,y=.5}
local pushed=C.plan(p,{points={{x=40.5,y=.5},{x=42.5,y=.5}}})
for i=1,120 do p.position={x=37.3-(i%3)*0.2,y=.5}; eq(C.tick(p,pushed),nil); game.tick=game.tick+1 end
p.position={x=37.3,y=.5}; eq(C.tick(p,pushed),"blocked")
-- Ghost construction: build everything in reach before walking, walk to stand
-- points (off ghost footprints) that cover the most ghosts, skip and report
-- missing items, retry a blocked ghost once after moving, then report it.
local function ghost(x,item)
  return {valid=true,ghost_name=item,position={x=x,y=.5},direction=4,quality={name='normal'},
    ghost_prototype={items_to_place_this={{name=item,count=1}}}}
end
ghosts={ghost(51.5,'stone-furnace'),ghost(54.5,'stone-furnace'),ghost(56.5,'assembler'),ghost(58.5,'stone-furnace'),
  ghost(60.5,'stone-furnace'),ghost(75.5,'stone-furnace'),ghost(78.5,'stone-furnace')}
local inventory={['stone-furnace']=10}
p.get_main_inventory=function() return {get_item_count=function(f) return inventory[f.name] or 0 end} end
p.surface.can_place_entity=function(a) return a.position.y>-3 end -- a wall north of y=-3
-- A belt strip over tiles y=2..4: standing there would carry the character off.
p.surface.count_entities_filtered=function(f)
  local belt=false
  for _,t in ipairs(f.type) do belt=belt or t=='transport-belt' end
  return belt and f.area[2][2]>2 and f.area[1][2]<4 and 1 or 0
end
local navs,walls={},nil
C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
  request_path=function(_,nav) nav.requested=true end,crafting_count=function() return 0 end,
  navigate=function(_,nav)
    if navs[#navs]~=nav then navs[#navs+1]=nav end
    for _,g in ipairs(ghosts) do assert(not (g.valid and math.abs(g.position.x-nav.position.x)<.8 and math.abs(g.position.y-nav.position.y)<.8),'stand point on a footprint') end
    assert(not (nav.position.y>1.6 and nav.position.y<4.4),'stand point on a belt')
    if walls and nav.position.x>walls then return 'blocked' end
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d)
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
  build=function(_,a)
    assert(distance(p.position,a.position)<=p.build_distance,'out of reach')
    assert(key(a.position)~=blocked,'placement blocked')
    for _,g in ipairs(ghosts) do if key(g.position)==key(a.position) then g.valid=false;p.revived=a end end
    return {consumed=1}
  end,
}
p.build_distance=10;p.position={x=50.5,y=2.5};blocked='58.5,0.5'
local function run_ghosts(a)
  for _=1,2000 do local outcome=C.tick_ghosts(p,a);if outcome then return outcome end end
  error('construct did not complete')
end
local tour=C.plan_ghosts(p,{},{})
eq(#tour.pending,7);eq(C.tick_ghosts(p,tour),nil)
eq(tour.built,2);eq(tour.missing.assembler,1);eq(#navs,0);eq(p.walking_state.walking,false) -- built in place first
eq(run_ghosts(tour),'incomplete');eq(tour.built,5);eq(#navs,2) -- one stand point per cluster
eq(#tour.failed,1);eq(tour.failed[1].position.x,58.5);assert(tour.failed[1].error:find('placement blocked',1,true))
eq(p.revived.direction,'east');eq(C.remaining(tour),0)
blocked=nil
-- Standing on a ghost's footprint blocks it: step off to a free stand point first.
ghosts={ghost(90.5,'stone-furnace')};navs={};p.position={x=90.5,y=.5}
local own=C.plan_ghosts(p,{},{});eq(run_ghosts(own),'constructed');eq(own.built,1);eq(#navs,1)
-- Stand points that keep blocking are abandoned; after three the ghost is unreachable.
ghosts={ghost(120.5,'stone-furnace')};navs={};walls=100;p.position={x=95.5,y=.5}
local far=C.plan_ghosts(p,{},{});eq(run_ghosts(far),'incomplete');eq(far.built,0);eq(#navs,3)
eq(far.failed[1].error,'unreachable');eq(far.pending[1],nil)
walls=nil
-- Deconstruction marks are hand-mined: timed like mine, one at a time, from a
-- stand point in reach; a full inventory stops the action and names the entity.
local neutral={name='neutral'}
local function tree(x) return {valid=true,name='tree',type='tree',minable=true,force=neutral,position={x=x,y=.5},prototype={},to_be_deconstructed=function() return true end} end
ghosts={};marked={tree(140.5),tree(141.5),tree(160.5),{valid=true,name='rock',type='simple-entity',minable=true,force={name='enemy'},position={x=141,y=1},to_be_deconstructed=function() return true end}}
-- Hand-mining reaches only resource_reach_distance (to the entity edge).
p.resource_reach_distance=2.7
p.can_reach_entity=function(e) return distance(p.position,e.position)<=3 end
local mined_at={}
p.mine_entity=function(e,force) assert(force==false);mined_at[#mined_at+1]=game.tick;if p.full then return false end;e.valid=false;return true end
navs={};p.position={x=141,y=2.5};game.tick=0
C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
  hand_mining_ticks=function() return 30 end,
  request_path=function(_,nav) nav.requested=true end,
  navigate=function(_,nav)
    if navs[#navs]~=nav then navs[#navs+1]=nav end
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d)
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
}
local function run_timed(a)
  for _=1,4000 do local outcome=C.tick_ghosts(p,a);if outcome then return outcome end;game.tick=game.tick+1 end
  error('construct did not complete')
end
local clear=C.plan_ghosts(p,{},{})
eq(#clear.pending,3) -- other forces' entities are not ours to mine
eq(run_timed(clear),'constructed');eq(clear.mined,3);eq(#navs,1)
eq(mined_at[1],30);eq(mined_at[2],60) -- sequential, each after its full mining time
marked={tree(170.5),tree(171.5)};p.full=true;mined_at={};p.position={x=170.5,y=3.5}
local full=C.plan_ghosts(p,{},{})
eq(run_timed(full),'inventory_full');eq(full.mined,0);eq(full.failed[1].name,'tree');eq(full.failed[1].error,'inventory_full')
eq(C.remaining(full),1)
marked={};p.full=nil
-- Trees under a ghost are marked like a player's ghost placement and mined
-- before it is built; a ghost whose item is still being hand-crafted is
-- awaited in reach rather than reported missing.
local crafting=0
C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
  hand_mining_ticks=function() return 30 end,crafting_count=function(_,item) return item=='boiler' and crafting or 0 end,
  real=function(x) return x.luaplayer end,
  request_path=function(_,nav) nav.requested=true end,
  navigate=function(_,nav)
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d)
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
  build=function(_,a)
    for _,o in ipairs(obstacles) do assert(not (o.valid and distance(o.position,a.position)<1),'placement blocked') end
    assert((inventory[a.item] or 0)>0,'item is not in main inventory'); inventory[a.item]=inventory[a.item]-1
    for _,g in ipairs(ghosts) do if key(g.position)==key(a.position) then g.valid=false end end
    return {consumed=1}
  end,
}
local under=tree(200.5); local was_marked=false
under.to_be_deconstructed=function() return was_marked end
-- The mark names the LuaPlayer behind the proxy, or no player for a bot
-- (shake2: a proxy failed with "Invalid PlayerIdentification").
local marked_by='unset'
under.order_deconstruction=function(force,player)
  assert(force==p.force and (player==nil or player=='LuaPlayer'),'Invalid PlayerIdentification. Expected LuaPlayer, index or name.')
  marked_by=player; was_marked=true; return true
end
obstacles={under};ghosts={ghost(200.5,'stone-furnace')};p.position={x=200.5,y=6.5};inventory['stone-furnace']=1
p.luaplayer=nil -- a bot
local cleared=C.plan_ghosts(p,{},{});eq(#cleared.pending,2);assert(was_marked);eq(marked_by,nil)
eq(run_timed(cleared),"constructed");eq(cleared.mined,1);eq(cleared.built,1)
under=tree(201.5); was_marked=false; marked_by='unset'
under.to_be_deconstructed=function() return was_marked end
under.order_deconstruction=function(force,player) assert(player=='LuaPlayer','Invalid PlayerIdentification'); marked_by=player; was_marked=true; return true end
obstacles={under};ghosts={ghost(201.5,'stone-furnace')};p.luaplayer='LuaPlayer' -- a player in map view
C.plan_ghosts(p,{},{});eq(marked_by,'LuaPlayer')
p.luaplayer=nil
obstacles={}
inventory.boiler=0;crafting=1;ghosts={ghost(220.5,'boiler')};p.position={x=212.5,y=6.5}
local awaiting=C.plan_ghosts(p,{},{})
for _=1,300 do eq(C.tick_ghosts(p,awaiting),nil);game.tick=game.tick+1 end
eq(awaiting.awaiting_craft,true);eq(next(awaiting.missing),nil)
assert(distance(p.position,ghosts[1].position)<=9.5,'walks into reach while the craft finishes')
crafting=0;inventory.boiler=1
eq(run_timed(awaiting),'constructed');eq(awaiting.built,1)
-- With nothing crafting, the same ghost is missing.
ghosts={ghost(230.5,'boiler')};p.position={x=230.5,y=6.5}
local short=C.plan_ghosts(p,{},{});eq(run_timed(short),'incomplete');eq(short.missing.boiler,1)
-- Request #167: tree-08s whose collision box only met a belt ghost's edge
-- (the engine counts that as blocking) were outside the old search inside
-- the footprint, so construct ended with the ghost still blocked. Area
-- searches here return what overlaps the area, as the engine does.
local blocking_margin=0
local function edge_tree(x,y,box)
  local t={valid=true,name='tree-08',type='tree',minable=true,force=neutral,position={x=x,y=y},bounding_box=box,prototype={},marked=false}
  t.to_be_deconstructed=function() return t.marked end
  t.order_deconstruction=function() t.marked=true; return true end
  return t
end
local function overlaps(b,area) return b.left_top.x<area.right_bottom.x and b.right_bottom.x>area.left_top.x and b.left_top.y<area.right_bottom.y and b.right_bottom.y>area.left_top.y end
local find=p.surface.find_entities_filtered
p.surface.find_entities_filtered=function(a)
  if type(a.type)=='table' and a.type[1]=='tree' then
    local out={}
    for _,o in ipairs(obstacles) do if o.valid and overlaps(o.bounding_box,a.area) then out[#out+1]=o end end
    return out
  end
  return find(a)
end
C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
  hand_mining_ticks=function() return 30 end,crafting_count=function() return 0 end,real=function() return nil end,
  request_path=function(_,nav) nav.requested=true end,
  navigate=function(_,nav)
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d)
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
  -- The engine: a tree whose box touches the belt's box (edges count) blocks it.
  build=function(_,a)
    local m=blocking_margin
    for _,o in ipairs(obstacles) do
      local b=o.bounding_box
      if o.valid and b.left_top.x<=a.position.x+.5+m and b.right_bottom.x>=a.position.x-.5-m and b.left_top.y<=a.position.y+.5+m and b.right_bottom.y>=a.position.y-.5-m then
        error(string.format('placement blocked by %s (%g,%g)',o.name,o.position.x,o.position.y))
      end
    end
    for _,g in ipairs(ghosts) do if key(g.position)==key(a.position) then g.valid=false end end
    return {consumed=1}
  end,
}
inventory['transport-belt']=4
-- The tree's box meets the ghost's bottom edge (y=1): marked with the plan, mined first.
local edge=edge_tree(300.9375,1.25,{left_top={x=300.6,y=1.0},right_bottom={x=301.3,y=1.5}})
obstacles={edge};ghosts={ghost(300.5,'transport-belt')};p.position={x=300.5,y=5.5}
local plan167=C.plan_ghosts(p,{},{})
eq(edge.marked,true);eq(#plan167.pending,2)
eq(run_timed(plan167),'constructed');eq(plan167.built,1);eq(plan167.mined,1);eq(#plan167.failed,0)
eq(plan167.blockers[1].name,'tree-08');eq(plan167.blockers[1].position.x,300.9375);eq(plan167.blockers[1].at.x,300.5)
-- One the plan does not see (0.2 off the edge) but the build bumps into: the
-- build failure marks and mines that tree, and the build goes again without
-- spending a try.
blocking_margin=0.25
local near=edge_tree(310.9,1.4,{left_top={x=310.6,y=1.2},right_bottom={x=311.2,y=1.6}})
obstacles={near};ghosts={ghost(310.5,'transport-belt')};p.position={x=310.5,y=5.5}
local late=C.plan_ghosts(p,{},{})
eq(near.marked,false);eq(#late.pending,1)
eq(run_timed(late),'constructed');eq(late.built,1);eq(late.mined,1);eq(#late.failed,0);eq(near.marked,true)
eq(late.blockers[1].position.y,1.4)
-- A blocker that cannot be mined fails the ghost, naming it and where it stands.
local stuck=edge_tree(320.9,1.25,{left_top={x=320.6,y=1.0},right_bottom={x=321.3,y=1.5}})
stuck.order_deconstruction=function() return false end
blocking_margin=0
obstacles={stuck};ghosts={ghost(320.5,'transport-belt')};p.position={x=320.5,y=5.5}
local fail167=C.plan_ghosts(p,{},{})
eq(run_timed(fail167),'incomplete');eq(fail167.built,0)
assert(fail167.failed[1].error:find('placement blocked by tree-08 (320.9,1.25)',1,true),fail167.failed[1].error)
p.surface.find_entities_filtered=find;obstacles={}
-- shift01 (22:32-22:37 UTC): Opus's construct over 255 pipe ghosts waited
-- for 560 hand-crafted pipes, and every tick redid the nearest-ghost search
-- once per waiting ghost (engine reads ~N^2 a tick): the world ran at 9
-- ticks/s. Engine reads are counted here; a tick's cost stays linear and a
-- wait looks again only every 10 ticks.
local reads,craft_calls,pipes_crafting=0,0,255
local function counted(t)
  return setmetatable({},{__index=function(_,k) reads=reads+1; return t[k] end,__newindex=t})
end
C=dofile('mod/agent-harness_0.1.0/construction.lua'){
  position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
  directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
  hand_mining_ticks=function() return 30 end,real=function() return nil end,
  crafting_count=function(_,item) craft_calls=craft_calls+1; return item=='pipe' and pipes_crafting or 0 end,
  request_path=function(_,nav) nav.requested=true end,
  navigate=function(_,nav)
    local d=distance(p.position,nav.position)
    if d<=nav.tolerance then return 'arrived' end
    local step=math.min(.25,d)
    p.position={x=p.position.x+(nav.position.x-p.position.x)/d*step,y=p.position.y+(nav.position.y-p.position.y)/d*step}
  end,
  build=function(_,a)
    assert(distance(p.position,a.position)<=p.build_distance,'out of reach')
    assert((inventory[a.item] or 0)>0,'item is not in main inventory'); inventory[a.item]=inventory[a.item]-1
    for _,g in ipairs(ghosts) do if key(g.position)==key(a.position) then g.valid=false end end
    return {consumed=1}
  end,
}
ghosts={}
for i=0,254 do ghosts[#ghosts+1]=counted(ghost(400.5+i,'pipe')) end
inventory.pipe=0;p.position={x=400.5,y=6.5};game.tick=1000
local pipeline=C.plan_ghosts(p,{},{})
eq(#pipeline.pending,255)
for _=1,200 do eq(C.tick_ghosts(p,pipeline),nil);game.tick=game.tick+1 end
eq(pipeline.awaiting_craft,true);eq(next(pipeline.missing),nil)
reads,craft_calls=0,0
for _=1,60 do eq(C.tick_ghosts(p,pipeline),nil);game.tick=game.tick+1 end
assert(reads<=60*255,'engine reads over 60 waiting ticks: '..reads)
assert(craft_calls<=12,'crafting_count calls over 60 waiting ticks: '..craft_calls)
-- The pipes arrive: all 255 are built, nearest first.
inventory.pipe=255;pipes_crafting=0
eq(run_timed(pipeline),'constructed');eq(pipeline.built,255);eq(inventory.pipe,0)
-- A pole ghost over a landfill tile ghost (pole_route on Gleba wetland, Sol shift09): the landfill goes down first,
-- and the pole waits for it instead of spending a try on the wetland; with no landfill it fails on the tile.
do
  local tile_ghost={valid=true,type='tile-ghost',ghost_name='landfill',position={x=600.5,y=.5},quality={name='normal'},
    ghost_prototype={items_to_place_this={{name='landfill',count=1}}}}
  local pole=ghost(600.5,'medium-electric-pole')
  pole.type='entity-ghost'; pole.direction=0
  pole.ghost_prototype.collision_box={left_top={x=-0.15,y=-0.15},right_bottom={x=0.15,y=0.15}}
  local tries={}
  C=dofile('mod/agent-harness_0.1.0/construction.lua'){
    position=function(v)return {x=v.x,y=v.y}end,distance=distance,integer=integer,visible=function()return true end,
    directions={north=0,east=4,south=8,west=12},known=function()return true end,reason=function(e)return tostring(e) end,
    hand_mining_ticks=function() return 30 end,crafting_count=function() return 0 end,
    request_path=function(_,nav) nav.requested=true end,
    navigate=function(_,nav) p.position={x=nav.position.x,y=nav.position.y}; return 'arrived' end,
    build=function(_,a)
      tries[#tries+1]=a.item
      assert((inventory[a.item] or 0)>0,'item is not in main inventory')
      assert(a.item=='landfill' or not tile_ghost.valid,'placement blocked by tiles: wetland-blue-slime (needs landfill, or a shore position)')
      inventory[a.item]=inventory[a.item]-1
      if a.item=='landfill' then tile_ghost.valid=false else pole.valid=false end
      return {consumed=1}
    end,
  }
  ghosts={pole,tile_ghost}; inventory['medium-electric-pole']=1; inventory.landfill=1; p.position={x=602.5,y=2.5}
  local site=C.plan_ghosts(p,{},{})
  eq(run_timed(site),'constructed'); eq(site.built,2); eq(#tries,2); eq(tries[1],'landfill'); eq(tries[2],'medium-electric-pole')
  -- no landfill: the tile ghost is missing, and the pole then fails on the tile it stands on
  tile_ghost.valid=true; pole.valid=true; tries={}; ghosts={pole,tile_ghost}; inventory['medium-electric-pole']=1; inventory.landfill=0
  site=C.plan_ghosts(p,{},{})
  eq(run_timed(site),'incomplete'); eq(site.missing.landfill,1); eq(site.missing['medium-electric-pole'],nil); eq(#tries,2)
  assert(site.failed[1] and site.failed[1].error:find('placement blocked by tiles: wetland-blue-slime',1,true),site.failed[1] and site.failed[1].error)
end
print('continuous construction tests passed')
