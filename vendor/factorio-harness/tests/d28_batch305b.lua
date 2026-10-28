-- Run from repository root: lua tests/d28_batch305b.lua
-- (d28 batch305 NR) cp2: stored routes used by the routing calls. A spidertron's go_to (spiderroute.set ->
-- spiderpath.plan) and a car's or tank's drive (vehicles.request) take a stored route from near here to near the target
-- (either way), read again in the call: all unchanged, it is the route at once ("reused route N (checked at tick T)");
-- stale legs are asked again as one stretch and spliced in; asked over MAX_AGE ago, a named route that does not fit, or
-- reuse: false: the pathfinder, saying why.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
storage={}
local function state() return storage end
defines={events={}}
local player={name='player'}
game={tick=1000,forces={player=player}}
local units={}
game.get_entity_by_unit_number=function(u) return units[u] end
local tiles={}
local function paint(name,x1,y1,x2,y2) for x=x1,x2 do for y=y1,y2 do tiles[x..','..y]=name end end end
local surface={name='nauvis',index=1}
surface.get_tile=function(x,y)
  local name=tiles[math.floor(x)..','..math.floor(y)] or 'grass-1'
  local w=name=='water' or name=='deepwater'
  return {valid=true,name=name,collides_with=function(l) return w and (l=='water_tile' or l=='player' or l=='doodad') or false end,
    prototype={collision_mask={layers=w and {player=true,water_tile=true} or {}}}}
end
local ents={}
local function inside(q,area) return q.x>=area[1][1] and q.x<=area[2][1] and q.y>=area[1][2] and q.y<=area[2][2] end
local function meets(layers,mask) for _,l in ipairs(mask) do if layers[l] then return true end end return false end
surface.count_entities_filtered=function(f)
  local types
  if f.type then types={} for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end end
  local n=0
  for _,e in ipairs(ents) do if inside(e.position,f.area) and (not f.collision_mask or meets(e.layers,f.collision_mask)) and (not types or types[e.type]) then n=n+1 end end
  return n
end
surface.count_tiles_filtered=function(f)
  local n=0
  for k,name in pairs(tiles) do
    local x,y=k:match('(-?%d+),(-?%d+)')
    if (name=='water' or name=='deepwater') and inside({x=tonumber(x)+0.5,y=tonumber(y)+0.5},f.area) and meets({water_tile=true},f.collision_mask) then n=n+1 end
  end
  return n
end
surface.find_entities_filtered=function() return {} end
local requests={}
surface.request_path=function(r) requests[#requests+1]=r; return 900+#requests end
local function position(q) return {x=q.x or q[1],y=q.y or q[2]} end
local S=dofile('mod/agent-harness_0.1.0/sharedroutes.lua'){state=state}
local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state,routes=S}
local R=dofile('mod/agent-harness_0.1.0/spiderroute.lua'){state=state,position=position,who=function(x) return x.name end,path=P}
local function routed(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end
local function answer(id,path) return P.on_path({id=id,path=path},routed) end
local function alert() return storage.spiderroute.events[#storage.spiderroute.events].text end

-- a spidertron at (0.5,0.5); a lake from x 10 to 40 between y -40 and 40; the target (60.5,0.5) beyond it
local route={}
local sd={valid=true,name='spidertron',unit_number=8101,position={x=0.5,y=0.5},surface=surface,force=player}
local spider=setmetatable({},{__index=function(_,k)
  if k=='autopilot_destinations' then return route end
  if k=='autopilot_destination' then return route[1] end
  return sd[k]
end,__newindex=function(_,k,v) if k=='autopilot_destination' then route={}; if v then route[1]=v end else sd[k]=v end end})
sd.get_spider_legs=function() return {{prototype={collision_mask={layers={player=true,rail=true}}}}} end
sd.add_autopilot_destination=function(q) route[#route+1]={x=q.x or q[1],y=q.y or q[2]} end
units[8101]=spider
paint('water',10,-40,40,40)
local around={}
for _,q in ipairs({{0.5,0.5},{0.5,-45.5},{12.5,-45.5},{24.5,-45.5},{36.5,-45.5},{48.5,-45.5},{60.5,-45.5},{60.5,-30.5},{60.5,-15.5},{60.5,0.5}}) do around[#around+1]={position={x=q[1],y=q[2]}} end

-- 1. the first go_to asks the pathfinder; its path is kept (route 1, by sol)
local out=R.set(spider,{go_to={x=60.5,y=0.5}},'sol')
eq(#requests,1); eq(out.shared_route,nil,'nothing stored yet: nothing said')
answer(901,around)
local kept=storage.sharedroutes.routes[1]
assert(kept,'kept'); eq(kept.by,'sol'); eq(kept.pts[1].x,0.5); eq(kept.pts[#kept.pts].x,60.5)
has(alert(),'its route goes round the water now')

-- 2. another agent's go_to from about there: the stored route read again and used in the call, no path asked
route={}; sd.position={x=2.2,y=1.1}; game.tick=1600
local n0=#storage.spiderroute.events
out=R.set(spider,{go_to={x=60.5,y=0.5}},'luna')
eq(#requests,1,'no path asked')
eq(out.shared_route,'reused route 1 (checked at tick 1600): asked by sol at tick 1000 (10s ago); its '..#kept.legs..' legs unchanged')
eq(out.water.note,'its route goes round the water now, by stored routes read again in this call (no path asked)')
eq(#route,#kept.pts,'its route is the stored one (from its start, which is 1.9 tiles off)'); eq(route[2].y,-45.5); eq(route[#route].x,60.5)
has(out.route_line,'(0.5,-45.5)')
eq(#storage.spiderroute.events,n0,'said in the reply, no alert'); eq(kept.uses,1)
-- either way: from the far side back
route={}; sd.position={x=60.5,y=1.5}
out=R.set(spider,{go_to={x=0.5,y=0.5}},'luna')
eq(#requests,1); has(out.shared_route,'reused route 1 (checked at tick 1600)'); has(out.shared_route,', walked from its end')
eq(route[1].y,0.5,'its stored start, 1 tile off'); eq(route[2].y,-15.5); eq(route[#route].x,0.5)

-- 3. a tile changed on one leg: that leg asked again from its ends, the path spliced in, the route updated
route={}; sd.position={x=0.5,y=0.5}; game.tick=2000
paint('water',30,-46,32,-44)
local legs=#kept.legs
out=R.set(spider,{go_to={x=60.5,y=0.5}},'astra')
eq(#requests,2,'one path asked: the stale stretch')
has(out.shared_route,'route 1 (checked at tick 2000): asked by sol at tick 1000 (16s ago); of its '..legs..' legs,')
has(out.shared_route,'legs 1-3, 5-9 reused, leg 4 asked again (leg 4: the tile at (30.5,-45.5) was grass-1, now water)')
local rq=requests[2]
eq(rq.start.x,24.5); eq(rq.goal.x,36.5,'from the stale leg\'s start to its end')
answer(902,{{position={x=24.5,y=-45.5}},{position={x=28.5,y=-48.5}},{position={x=33.5,y=-48.5}},{position={x=36.5,y=-45.5}}})
-- the path thinned back to the straight leg (3 tiles of water: its legs step across up to 14), now read with the water
eq(kept.respliced,1); eq(#kept.legs,legs); eq(S.check(kept,surface).n,0,'the new leg read now')
has(alert(),'route 1: the path for legs 4-4 came and was spliced in (the route now has '..legs..' legs)')
eq(#route,#kept.pts-1,'its route: the stored points after its start')

-- 4. no path for the stale stretch: the whole way asked again (and kept anew when it comes)
route={}; game.tick=2500
paint('water',2,-46,2,-46)
out=R.set(spider,{go_to={x=60.5,y=0.5}},'astra')
eq(#requests,3); eq(requests[3].start.x,0.5)
P.on_path({id=903},routed)
eq(#requests,4,'asked again in full'); eq(requests[4].start.x,0.5); eq(requests[4].goal.x,60.5)
answer(904,{{position={x=0.5,y=0.5}},{position={x=0.5,y=-50.5}},{position={x=60.5,y=-50.5}},{position={x=60.5,y=0.5}}})
has(alert(),'route 1: no path came for legs 2-2; the whole way was asked again')
eq(storage.sharedroutes.routes[1],nil,'the new path from and to the same places replaces it'); eq(storage.sharedroutes.count,1)
local id2=next(storage.sharedroutes.routes)
eq(storage.sharedroutes.routes[id2].by,'astra')

-- 5. reuse: false asks the pathfinder; a named route that does not fit says why and asks it; a named route with no
-- crossing is not used
route={}
out=R.set(spider,{go_to={x=60.5,y=0.5},reuse=false},'astra')
eq(#requests,5); eq(out.shared_route,nil)
route={}
out=R.set(spider,{go_to={x=60.5,y=0.5},route=77},'astra')
eq(#requests,6); eq(out.shared_route,'route 77 not used: no stored route 77 (kept: 1; vehicle {routes: true} lists them); a path was asked')
route={}
out=R.set(spider,{go_to={x=5.5,y=0.5},route=id2},'astra')
eq(#requests,6); eq(out.shared_route,'route '..id2..' not used: no leg of this go_to crosses water its legs cannot step across')
local ok,err=pcall(R.set,spider,{clear=true,reuse=false},'astra')
assert(not ok); has(err,'reuse and route go with go_to')

-- 6. asked over MAX_AGE ago: asked again in full, said
route={}; game.tick=2500+S.MAX_AGE+60
out=R.set(spider,{go_to={x=60.5,y=0.5}},'astra')
eq(#requests,7); has(out.shared_route,'over the 2h00m a route is kept without asking again: asked again in full')

-- 7. a recovery after a stall (gap 0: its legs failed to cross) never takes a stored route
local before=#requests
P.plan(spider,{{x=60.5,y=0.5}},{owner='route',by='astra',gap=0,reuse=true,from={x=0.5,y=0.5}})
eq(#requests,before+1)
-- 7b. stalled on a stored route it took: the route dropped from the store, said in the stall's alert
storage.sharedroutes=nil; storage.spiderroute=nil; storage.spiderpaths=nil; tiles={}; paint('water',10,-40,40,40)
game.tick=900000
local sr=S.save('spider',surface,{{x=0.5,y=0.5},{x=0.5,y=-45.5},{x=30.5,y=-45.5},{x=60.5,y=-45.5},{x=60.5,y=0.5}},{by='sol'})
route={}; sd.position={x=0.5,y=0.5}
before=#requests
out=R.set(spider,{go_to={x=60.5,y=0.5}},'luna')
eq(#requests,before,'reused'); has(out.shared_route,'reused route '..sr.id)
eq(storage.spiderroute.spiders[8101].from_store[1],sr.id)
for _=1,12 do game.tick=game.tick+60; R.tick() end
eq(S.get(sr.id),nil,'dropped')
has(alert(),'; stored route '..sr.id..' dropped (it stalled on it)')
print('d28_batch305b spidertron go_to: ok')

-- 8. a drive: its first path kept; the next drive from about there reuses it in the call; a wall built on a leg: that
-- stretch asked again and spliced; reuse: false; a bigger box; something between the vehicle and the route's start
storage={}; requests={}; tiles={}; game.tick=10000
local paths={}
local V=dofile('mod/agent-harness_0.1.0/vehicles.lua'){routes=S,distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end,
  who=function(q) return q.name end,paths=function() return paths end}
local car={valid=true,name='car',position={x=0.5,y=0.5},surface=surface,
  prototype={collision_box={left_top={x=-0.7,y=-1},right_bottom={x=0.7,y=1}},collision_mask={layers={player=true,train=true,is_object=true,water_tile=true}}}}
local astra={name='astra',index=3,force=player}
local function drive(to,extra)
  local nav={position=to,tolerance=3,vehicle=true,vehicle_entity=car}
  for k,v in pairs(extra or {}) do nav[k]=v end
  V.request(astra,nav)
  return nav
end
local corner={{position={x=0.5,y=0.5}},{position={x=30.5,y=0.5}},{position={x=30.5,y=40.5}},{position={x=60.5,y=40.5}}}
local nav=drive({x=60.5,y=40.5})
eq(#requests,1); eq(nav.path_state,'pending'); eq(nav.shared,nil)
V.on_path(astra,{nav=nav},{id=901,path=corner})
eq(nav.path_state,'found')
local d=storage.sharedroutes.routes[nav.kept]
assert(d); eq(d.kind,'drive'); eq(d.by,'astra'); eq(#d.legs,7,'30 + 40 + 30 tiles in legs of 16 or less: 2 + 3 + 2')
-- sol's drive from 2 tiles off: reused at once
car.position={x=1.5,y=2.0}; game.tick=10600
local sol={name='sol',index=4,force=player}
nav={position={x=60.5,y=40.5},tolerance=3,vehicle=true,vehicle_entity=car}
V.request(sol,nav)
eq(#requests,1,'no path asked'); eq(nav.path_state,'found'); eq(nav.from_store,d.id)
eq(nav.shared,'reused route '..d.id..' (checked at tick 10600): asked by astra at tick 10000 (10s ago); its 7 legs unchanged')
eq(nav.waypoints[1].position.x,1.5); eq(nav.waypoints[2].position.x,0.5); eq(nav.waypoints[#nav.waypoints].position.y,40.5)
eq(nav.kept,nil,'a reused route is not kept again'); eq(d.uses,1)
-- a wall built on leg 4 (x 30.5, y 0.5..13.8): that leg's stretch asked again
car.position={x=0.5,y=0.5}; game.tick=11000
ents[#ents+1]={position={x=30.5,y=8.5},type='wall',layers={player=true,is_object=true}}
nav=drive({x=60.5,y=40.5})
eq(#requests,2); eq(nav.path_state,'pending')
has(nav.shared,'leg 3 asked again (leg 3: 1 entities it collides with in its corridor, 0 when read)')
eq(requests[2].start.x,30.5); eq(requests[2].start.y,0.5); eq(requests[2].radius,1)
local half=(1.0^2+0.7^2)^0.5+0.5
eq(requests[2].bounding_box[2][1],half,'the turning room')
V.on_path(astra,{nav=nav},{id=902,path={{position={x=30.5,y=0.5}},{position={x=34.5,y=4.5}},{position={x=34.5,y=12.5}},{position={x=30.5,y=14.8333}}}})
eq(nav.path_state,'found'); has(nav.shared,'; the path for legs 3-3 came and was spliced in')
eq(d.respliced,1)
local wp=false for _,w in ipairs(nav.waypoints) do if w.position.x==34.5 then wp=true end end
assert(wp,'the drive takes the new stretch')
-- reuse: false; a bigger box; a named route
nav=drive({x=60.5,y=40.5},{reuse=false}); eq(#requests,3); eq(nav.shared,nil)
local tank={valid=true,name='tank',position={x=0.5,y=0.5},surface=surface,
  prototype={collision_box={left_top={x=-0.9,y=-1.3},right_bottom={x=0.9,y=1.3}},collision_mask=car.prototype.collision_mask}}
nav={position={x=60.5,y=40.5},tolerance=3,vehicle=true,vehicle_entity=tank}
V.request(astra,nav); eq(#requests,4,'a tank\'s turning room is bigger than the car\'s route'); eq(nav.shared,nil)
nav={position={x=60.5,y=40.5},tolerance=3,vehicle=true,vehicle_entity=tank,route_id=d.id}
V.request(astra,nav); eq(#requests,5)
eq(nav.shared,'route '..d.id..' not used: route '..d.id..' is a car or tank route for a box '..string.format('%.1f',half*2)..' tiles wide on this surface: not for this one; a path was asked')
-- something it collides with between the vehicle and the route's start
car.position={x=-4.5,y=0.5}
ents[#ents+1]={position={x=-2,y=0.5},type='stone-wall',layers={player=true}}
nav=drive({x=60.5,y=40.5})
eq(#requests,6); has(nav.shared,'not used: between the car and its start (0.5,0.5), 1 entities and 0 tiles it collides with; a path was asked')
-- the span's path fails: asked in full
car.position={x=0.5,y=0.5}; ents={}; game.tick=11500
ents[#ents+1]={position={x=60.5,y=40.5-1},type='wall',layers={player=true}}
nav=drive({x=60.5,y=40.5})
eq(#requests,7); eq(nav.path_state,'pending')
V.on_path(astra,{nav=nav},{id=907})
eq(#requests,8,'asked in full'); has(nav.shared,'; no path came for legs')
eq(requests[8].start.x,0.5); eq(nav.from_store,nil)
print('d28_batch305b drive: ok')

-- 9. the routes read: nearest first, a line each
storage={}; tiles={}; game.tick=20000
S.save('spider',surface,{{x=100.5,y=0.5},{x=130.5,y=0.5}},{by='sol'})
S.save('drive',surface,{{x=0.5,y=0.5},{x=20.5,y=0.5}},{by='astra',h=1.7,layers={'player'}})
S.save('spider',{index=2,name='vulcanus',get_tile=surface.get_tile},{{x=0.5,y=0.5},{x=12.5,y=0.5}},{by='luna'})
local lst=S.list(surface,{x=0,y=0})
eq(lst.routes,3); eq(lst.on_surface,2); eq(#lst.routes_here,2)
eq(lst.routes_here[1],'route 2: car or tank (a box 3.4 tiles wide), (0.5,0.5) -> (20.5,0.5), 20 tiles in 2 legs, asked by astra at tick 20000 (0s ago); used 0 times (an end 1 tiles from (0,0))')
has(lst.routes_here[2],'route 1: spidertron, (100.5,0.5) -> (130.5,0.5), 30 tiles in 1 legs')
print('d28_batch305b routes read: ok')
