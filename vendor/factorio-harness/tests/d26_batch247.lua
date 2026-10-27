-- Run from repository root: lua tests/d26_batch247.lua
-- (d26 batch247 NV1, viewer Aurora 14:13) vehicle {go_to, wait: true} (fh --wait): a waited go_to ends arrived,
-- stalled, unreachable, route_changed, retreated, route_emptied or destroyed (spiderroute.lua watch, finish), read
-- after the route's samples; a plain go_to replies at once as before.
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


local function ticks(n) for _=1,n,60 do game.tick=game.tick+60; R.tick() end end
local function waited(go)
  R.set(spider,go,'sol')
  local r=route
  return {kind='spider_go',spider=spider,unit=8101,set_tick=game.tick,start_tick=game.tick,target={x=r[#r].x,y=r[#r].y}}
end

-- 1. arrived: its route ends within 4 tiles of its last target
route={}; sd.position={x=0.5,y=0.5}
local a=waited({go_to={x=20.5,y=0.5}})
ticks(60); eq(R.watch(a),nil,'walking')
sd.position={x=20.2,y=0.6}; route={}
ticks(60); eq(R.watch(a),'arrived')
local last={}; R.finish(a,'arrived',last)
eq(last.why,'arrived at (20.2,0.6) (its route ended at (20.5,0.5))'); eq(last.spidertron,'spidertron #8101'); eq(last.position.x,20.2)

-- 2. route_changed: another go_to set its route; a plain go_to (no wait) replies at once as before
route={}; sd.position={x=0.5,y=0.5}
a=waited({go_to={x=30.5,y=0.5}})
game.tick=game.tick+1
R.set(spider,{go_to={x=-30.5,y=0.5}},'luna')
eq(R.watch(a),'route_changed'); last={}; R.finish(a,'route_changed',last)
assert(last.why:find('its route was set again',1,true) and last.why:find('(-30.5,0.5)',1,true),last.why)

-- 3. stalled, then unreachable: no progress after the recoveries; with no path found it is unreachable
wetset={}; water(10,-50,40,50)
route={}; sd.position={x=9.1,y=0.5}
a=waited({go_to={x=60.5,y=0.5}})
for k=#requests-3,#requests do if k>0 then P.on_path({id=900+k},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end) end end
storage.spiderpaths.plans[8101]=nil
local t=storage.spiderroute.spiders[8101]
t.stalled=true
eq(R.watch(a),'unreachable','no path found')
last={}; R.finish(a,'unreachable',last)
assert(last.no_path and last.no_path:find('found no path',1,true),tostring(last.no_path))
t.no_path=nil
eq(R.watch(a),'stalled','a path was found or none was asked: stalled')
-- a target on water with no tile its legs stand on near it: unreachable
a.unlanded='the target (30,0) is on water with no tile its legs stand on within 48 tiles'
eq(R.watch(a),'unreachable')
a.unlanded=nil; t.stalled=nil

-- 4. retreated: its guard sent it back
t.retreated={guard='standing retreat_guard',why='health 30% under 40%',from={x=0,y=0},health='30%',route_line='1 target: (0,0)',tick=game.tick}
eq(R.watch(a),'retreated'); t.retreated=nil

-- 5. route_emptied: its route ended far from its last target
route={}
ticks(60); eq(R.watch(a),'route_emptied'); last={}; R.finish(a,'route_emptied',last)
assert(last.why:find('its route ended at (9.1,0.5)',1,true),last.why)

-- 6. destroyed
sd.valid=false; eq(R.watch(a),'destroyed'); sd.valid=true
-- 7. (operator 16:44, Opus's (0,850) and (400,850) on d26) a target mid-lake: the landing search goes past 48 tiles,
-- on rings to 160, then along the line back toward the spidertron; with nothing dry it is said once, no path is
-- asked and no recovery spent.
-- a lake x -100..100, y -100..100; target (0,0): dry 101 tiles away: the rings find it
wetset={}; water(-100,-100,100,100)
local d,note,none=P.landing(surface,{x=0.5,y=0.5},{x=-150,y=0.5})
assert(d and P.clear(surface,d) and note:find('the nearest spot its legs stand on (',1,true) and not none,tostring(note))
assert(math.abs(d.x)>100 or math.abs(d.y)>100,'beyond the lake')
-- a lake x -200..200: nothing within 160 round it; along the line back toward the spidertron at x -250: x -201
wetset={}; water(-200,-200,200,200)
d,note,none=P.landing(surface,{x=0.5,y=0.5},{x=-250.5,y=0.5})
assert(d and d.x<-200 and note:find('the first spot its legs stand on along the line back toward the spidertron',1,true) and not none,tostring(note))
-- the spidertron itself out on the water too (no dry spot on the line): unlanded
d,note,none=P.landing(surface,{x=0.5,y=0.5},{x=-150,y=0.5})
eq(none,true); assert(note:find('no path is asked and no recovery spent on it',1,true),note)
-- go_to there: said in the reply, no path asked; at its stall no recovery, the stall line once; a waited go_to: unreachable
wetset={}; water(-200,-200,200,200)
for x=-205,-201 do for y=-3,3 do wetset[x..','..y]=nil end end   -- it stands on a dry spit at the lake's west edge
-- from the spit: the line back reaches its own dry ground, so the route ends there (d26's case: it arrives at the
-- shore instead of stalling there through 3 recoveries)
route={}; sd.position={x=-203.5,y=0.5}
local r6=R.set(spider,{go_to={x=0.5,y=0.5}},'sol')
eq(r6.unlanded,nil); assert(r6.landed[1]:find('along the line back toward the spidertron',1,true),r6.landed[1])
assert(route[#route].x<=-200,'the route ends at the spit: '..route[#route].x)
-- its body out over the water (no dry spot on its line either): unlanded
route={}; sd.position={x=-150.5,y=0.5}
local before7=#requests
local r7=R.set(spider,{go_to={x=0.5,y=0.5}},'sol')
eq(#requests,before7,'no path asked'); eq(r7.water,nil)
assert(r7.unlanded and r7.landed[1]==r7.unlanded,tostring(r7.unlanded))
local a7={kind='spider_go',spider=spider,unit=8101,set_tick=game.tick,start_tick=game.tick,target={x=0.5,y=0.5},unlanded=r7.unlanded}
sd.position={x=-201.2,y=0.5}                       -- at the shore, 1 tile from the water
local seen7=storage.spiderroute.eseq
ticks(R.STALL_WATER+120)
local l7=R.lines({name='sol'},{spiderroute_seen=seen7})
eq(#l7,1,'said once'); assert(l7[1]:find('no path is asked and no recovery spent on it',1,true) and not l7[1]:find('recovery 1',1,true),l7[1])
eq(storage.spiderroute.spiders[8101].tries,nil,'no recovery spent')
eq(R.watch(a7),'unreachable')
print('d26_batch247: ok')
