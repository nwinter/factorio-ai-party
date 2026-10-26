-- Run from repository root: lua tests/d26_batch243.lua
-- (d26 batch243 SR, viewer Aurora 13:42) solo spidertron routing round water (spiderpath.lua, spiderroute.lua): on d26
-- spidertron #27069154 stood 1 tile from water at (78,339) for 8 min while each path round it came back "found no path":
-- starts and goals whose box touches water move to the nearest spot with room; a failed path is asked again from spots
-- its legs step to (island escape); a long detour is thinned coarser instead of failing; a target on water ends at the
-- dry spot nearest it; a stall 1 tile from water with no path being asked backs off along its trail and asks again.
-- The engine facts (what legs step over, the box, narrow passes) are measured on a copy; this is the logic.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
local function state() return storage end
local player={name='player'}
game={tick=1000,forces={player=player}}
local units={}
game.get_entity_by_unit_number=function(u) return units[u] end
-- the map: a set of wet tiles by "x,y" (tile corners), else dry
local wetset={}
local function water(x1,y1,x2,y2) for x=x1,x2 do for y=y1,y2 do wetset[x..','..y]=true end end end
local surface={name='nauvis'}
surface.get_tile=function(x,y)
  local w=wetset[math.floor(x)..','..math.floor(y)] or false
  local name=w and 'water' or 'grass-1'
  return {name=name,collides_with=function(l) return w and (l=='water_tile' or l=='player' or l=='doodad') or false end,
    prototype={collision_mask={layers=w and {player=true,water_tile=true} or {}}}}
end
surface.find_entities_filtered=function() return {} end
local requests={}
surface.request_path=function(r) requests[#requests+1]=r; return 900+#requests end
local route={}
local sd={valid=true,name='spidertron',unit_number=8101,position={x=0.3,y=0.3},surface=surface,force=player,health=3000,max_health=3000}
local spider=setmetatable({},{__index=function(_,k)
  if k=='autopilot_destinations' then return route end
  if k=='autopilot_destination' then return route[1] end
  return sd[k]
end,__newindex=function(_,k,v) if k=='autopilot_destination' then route={}; if v then route[1]=v end else sd[k]=v end end})
sd.get_spider_legs=function() return {{prototype={collision_mask={layers={player=true,rail=true}}}}} end
sd.add_autopilot_destination=function(q) route[#route+1]={x=q.x or q[1],y=q.y or q[2]} end
units[8101]=spider
local function position(q) return {x=q.x or q[1],y=q.y or q[2]} end
local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state}
local R=dofile('mod/agent-harness_0.1.0/spiderroute.lua'){state=state,position=position,who=function(x) return x.name end,path=P}
local function routed(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end
local function answer(id,path) return P.on_path({id=id,path=path},routed) end
local function lines() return R.lines({name='sol'},{spiderroute_seen=storage.spiderroute.eseq-1}) end
local function line(a,b,n) local out={} for i=0,n do out[#out+1]={position={x=a.x+(b.x-a.x)*i/n,y=a.y+(b.y-a.y)*i/n}} end return out end

-- 1. clear / dry: a spot whose box (BOX each side) touches water has no room; the nearest spot with room.
water(2,-50,40,50)                                  -- a lake east of x 2
eq(P.clear(surface,{x=0.5,y=0.5}),true)
eq(P.clear(surface,{x=1.5,y=0.5}),true,'a 1x1 box at a tile centre covers that tile'); eq(P.clear(surface,{x=1.9,y=0.5}),false,'the box reaches x 2')
local d=P.dry(surface,{x=1.8,y=0.5},8); assert(d.x<2 and P.clear(surface,d),'west of the water: '..d.x)
eq(P.dry(surface,{x=20,y=0},8),nil,'mid-lake: none within 8')

-- 2. go_to from the water's edge: the path starts from the spot with room (on d26 every start was 1 tile from water).
-- From here the map is an island: a channel of 7 tiles (x 2..8, its legs step across), land, then a lake (x 20..50).
wetset={}; water(2,-50,8,50); water(20,-50,50,50)
sd.position={x=1.6,y=0.4}
local r=R.set(spider,{go_to={x=60,y=0}},'sol')
eq(#requests,1); assert(requests[1].start.x<2 and P.clear(surface,requests[1].start),'the start moved off the edge'); eq(requests[1].goal.x,60)
-- the doodad layer (the 13 tiles legs stand on none of; most buildings and trees carry water_tile), the cache off
eq(requests[1].collision_mask.layers.doodad,true); eq(requests[1].collision_mask.layers.water_tile,nil)
eq(requests[1].pathfind_flags.cache,false)
assert(r.water and r.water.crossing[1]:find('crosses 31 tiles of water',1,true),r.water and r.water.crossing[1])
eq(R.facts(spider).path,'a path round the water is being asked')

-- 3. island escape: no path from the start; asked again from up to HOPS spots its legs step to across the water
-- (straight, no run over GAP), nearest the goal first; the first path that comes wins, its spot first.
local before=#requests
answer(900+before)                                  -- no path
local hops=#requests-before
assert(hops>=1 and hops<=P.HOPS,'hops '..hops)
for k=before+1,#requests do
  local h=requests[k].start
  eq(P.clear(surface,h),true); eq(P.segment(surface,{x=1.6,y=0.4},h),nil,'a step its legs take')
  assert(h.x>8 and h.x<20,'across the channel, not the same land: '..h.x)
end
answer(900+before+1)                                -- the nearest hop: none either
local hop=requests[before+2].start
answer(900+before+2,line(hop,{x=60,y=0},60))        -- the next one: a path
for k=before+3,#requests do answer(900+k) end
eq(route[1].x,hop.x); eq(route[1].y,hop.y)
local l=lines()
assert(l[1]:find('its route goes round the water now',1,true) and l[1]:find('its legs step first to '..P.at(hop),1,true),l[1])
eq(R.facts(spider).path,nil); eq(R.facts(spider).no_path,nil)

-- 3b. hops on open land come first: a 2-tile islet in a channel (x 2..14, islet x 6..7) is nearer the goal, the far
-- shore (x 15 on) is open land (copy: from the islet at (76,338) the 4 nearest the goal were other islets)
do
  local keep=wetset
  wetset={}; water(2,-50,14,50)
  for x=6,7 do for y=-1,1 do wetset[x..','..y]=nil end end
  local hs=P.hops(surface,{x=0.5,y=0.5},{x=6.5,y=0.5})
  assert(#hs>=1 and hs[1].x>=15,'open land first: '..(hs[1] and hs[1].x or 'none'))
  wetset=keep
end

-- 4. none at all: said, with the spots tried; the vehicle read says it too (never a silent stall)
R.set(spider,{go_to={x=60,y=0}},'sol')
before=#requests
answer(900+before)
for k=before+1,#requests do answer(900+k) end
l=lines()
assert(l[1]:find('the pathfinder found no path round the water to (60,0); asked again from '..(#requests-before)..' spot',1,true),l[1])
assert(R.facts(spider).no_path:find('found no path',1,true))

-- 5. a target on water: the route ends at the dry spot nearest it, said in the reply
local w=R.set(spider,{go_to={x=30,y=0}},'sol')
assert(w.landed[1]:find('the target (30,0) is on water: the route ends at ',1,true),w.landed[1])
assert(route[#route].x>50 or route[#route].x<20,'dry: '..route[#route].x)

-- 6. a long detour (over MAX_POINTS at SPACING) is thinned coarser, not "no path"
local long={}
for i=0,3000 do long[#long+1]={position={x=-1-i*0.5,y=0.5}} end   -- 1500 tiles west on dry ground
local pts=P.thin(surface,long)
assert(pts and #pts<=P.MAX_POINTS and #pts>P.MAX_POINTS/4,'thinned: '..tostring(pts and #pts))

-- 7. stall recovery: 1 tile from water with no path being asked, 3 s, it backs off along its trail (the newest spot
-- 3 tiles or more back) and asks again; 3 times, then the stall line names them.
wetset={}; water(10,-50,40,50)
route={}
sd.position={x=0.5,y=0.5}
R.set(spider,{go_to={x=9,y=0.5}},'sol')            -- dry target: no plan
local function ticks(n) for _=1,n,60 do game.tick=game.tick+60; R.tick() end end
for x=1,8 do sd.position={x=x+0.5,y=0.5}; ticks(60) end  -- walking east: its trail
eq(#storage.spiderroute.spiders[8101].trail,6)
R.set(spider,{go_to={x=60,y=0.5}},'sol')
for k=#requests-5,#requests do answer(900+k) end   -- whatever was asked: none
storage.spiderpaths.plans[8101]=nil
sd.position={x=9.1,y=0.5}                           -- 1 tile from the water
local seen=storage.spiderroute.eseq
ticks(R.STALL_WATER+120)
l=R.lines({name='sol'},{spiderroute_seen=seen})
assert(l and l[#l]:find('backed off to (5.5,0.5), the last spot it stood 3 tiles or more back with room for a path',1,true),l and l[#l])
assert(l[#l]:find('(recovery 1 of 3)',1,true))
eq(route[1].x,5.5)
assert(R.facts(spider).recovery[1]:find('backed off to (5.5,0.5)',1,true))

-- 8. short water its legs did not cross (5 tiles, under GAP: go_to asked for no path): the recovery asks for one anyway
wetset={}; water(10,-50,14,50)
route={}
sd.position={x=9.1,y=0.5}
local before8=#requests
R.set(spider,{go_to={x=30,y=0.5}},'sol')
eq(#requests,before8,'5 tiles: crossable by the rule, no path asked')
storage.spiderroute.spiders[8101].trail=nil
ticks(R.STALL_WATER+120)
eq(#requests,before8+1,'after the stall: asked'); eq(requests[#requests].goal.x,30)
assert(storage.spiderroute.spiders[8101].tries[1]:find('asked again for a path round the water to (30,0.5)',1,true))
print('d26_batch243: ok')
