-- Run from repository root: lua tests/d24_batch191.lua
-- (d24 batch191 QAG1, viewer Aurora site:4818) spider_kite (spiderkite.lua): kite for a spidertron ridden or sent by
-- remote view: its targeting switches, route targets as its remote sets them, the band, backing off, the ends; and the
-- addendum (Aurora site:4826): routes round water its legs cannot cross (spiderpath.lua), no progress re-routed once,
-- then shore recovery, for spider_kite and vehicle {go_to} (spiderroute.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={spider_ammo=3}}
storage={}
local function state() return storage end
local enemy={name='enemy'}
local player={name='player'}
player.get_friend=function() return false end
player.get_cease_fire=function() return false end
local visible=true
player.is_chunk_visible=function() return visible end
game={tick=1000,forces={player=player,enemy=enemy,neutral={name='neutral'}}}
local units,entities={},{}
game.get_entity_by_unit_number=function(u) return units[u] end
-- water: x in [wx1,wx2] (and |y| < wy when set)
local wx1,wx2,wy
local surface={name='nauvis'}
surface.get_tile=function(x,y)
  local w=wx1 and x>=wx1 and x<=wx2 and (not wy or math.abs(y)<wy)
  local name=w and 'deepwater' or 'grass-1'
  return {name=name,collides_with=function(l) return w and l=='water_tile' or false end,
    prototype={collision_mask={layers=w and {player=true,water_tile=true} or {}}}}
end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(entities) do
    if e.valid and math.sqrt((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)<=f.radius then out[#out+1]=e end
  end
  return out
end
local requests={}
surface.request_path=function(r) requests[#requests+1]=r; return 500+#requests end
local function spidertron()
  local data={valid=true,name='spidertron',unit_number=7101,position={x=0,y=0},surface=surface,force=player,health=3000,max_health=3000,
    vehicle_automatic_targeting_parameters={auto_target_with_gunner=false,auto_target_without_gunner=false}}
  local route={}
  local ammo={count=40}
  local s=setmetatable({},{__index=function(_,k)
    if k=='autopilot_destinations' then return route end
    if k=='autopilot_destination' then return route[1] end
    return data[k]
  end,__newindex=function(_,k,v)
    if k=='autopilot_destination' then route={}; if v then route[1]=v end else data[k]=v end
  end})
  data.prototype={guns={['spidertron-rocket-launcher-1']={attack_parameters={range=36}}}}
  data.get_spider_legs=function() return {{prototype={collision_mask={layers={player=true,rail=true}}}}} end
  data.get_inventory=function(i) eq(i,defines.inventory.spider_ammo); return {get_item_count=function() return ammo.count end} end
  data.add_autopilot_destination=function(q) route[#route+1]={x=q.x or q[1],y=q.y or q[2]} end
  data.grid={shield=100,max_shield=100}
  data.ammo=ammo
  units[7101]=s
  return s,data
end
local function position(q) return {x=q.x or q[1],y=q.y or q[2]} end
local function integer(v,d,lo,hi,what) if v==nil then return d end assert(type(v)=='number' and v>=lo and v<=hi,what..' out of range'); return v end
local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state}
local K=dofile('mod/agent-harness_0.1.0/spiderkite.lua'){position=position,integer=integer,path=P}
local p={index=7,force=player}
local function biter(x,y,name) local e={valid=true,name=name or 'medium-biter',type='unit',position={x=x,y=y},force=enemy}; entities[#entities+1]=e; return e end
local function run(action,ticks)
  local out
  for _=1,ticks do
    game.tick=game.tick+1
    if game.tick>=action.next_scan then out=K.tick(action,game.tick); if out then return out end end
  end
  return out
end

-- 1. The call's checks: its guns' range bounds the band; rockets under ammo_below and health under min_health refused.
local spider,sd=spidertron()
fails(function() K.plan(p,{min_distance=20,max_distance=40},spider,'remote') end,"max_distance <= 36 (its guns' range)")
fails(function() K.plan(p,{ammo_below=50},spider,'remote') end,'holds 40 rockets in its ammo slots, under ammo_below 50')
sd.health=1000
fails(function() K.plan(p,{},spider,'remote') end,'at 33% health, under min_health 40%')
sd.health=3000
-- the standing retreat_guard's thresholds and point apply when the call gives none
local a=K.plan(p,{},spider,'remote',{to={x=-50,y=0},health_below=0.5,shield_below=0.2})
eq(a.min_health,0.5); eq(a.min_shield,0.2); eq(a.back.x,-50); eq(a.back_standing,true); eq(a.band_min,16); eq(a.band_max,28); eq(a.range,34)
eq(K.plan(p,{retreat=false},spider,'remote',{to={x=-50,y=0}}).back,nil)

-- 2. Its guns on (both switches), back as they were at the end; a unit within the band: it stands.
a=K.plan(p,{},spider,'remote')
local sw=K.start(a)
eq(sw.now.auto_target_without_gunner,true); eq(sw.now.auto_target_with_gunner,true); eq(sw.before.auto_target_with_gunner,false)
local b1=biter(20,0)
eq(run(a,10),nil); eq(a.mode,'holding'); eq(#spider.autopilot_destinations,0); eq(a.seen,1)

-- 3. A unit nearer than min_distance: a route away from the group's centre out to the band's far side.
b1.position={x=10,y=0}; biter(12,2); biter(12,-2)
eq(run(a,10),nil); eq(a.mode,'backing off')
local q=spider.autopilot_destinations[1]
assert(q.x<-10 and math.abs(q.y)<1,'away from the group: '..q.x..','..q.y)
eq(a.writes,1)
-- the same target again (within 3 tiles) is not written again
eq(run(a,10),nil); eq(a.writes,1)

-- 4. A back-off target over water its legs cannot cross: turned onto ground with a walkable straight line.
wx1,wx2=-40,-3
a.dest=nil; spider.autopilot_destination=nil; sd.position={x=0,y=0}
eq(run(a,10),nil)
q=spider.autopilot_destinations[1]
assert(q.x>-3,'turned off the water: '..q.x..','..q.y)
wx1,wx2=nil,nil

-- 5. Ends: route_changed (another call set its route), then low_shield, low_health, out_of_ammo with a retreat point.
spider.autopilot_destination={x=99,y=99}
local out=run(a,10); eq(out,'route_changed'); assert(a.why:find('leads to (99,99)',1,true),a.why)
local last={}
K.finish(a,out,last,function() error('no retreat point') end,'sol')
eq(spider.vehicle_automatic_targeting_parameters.auto_target_without_gunner,false,'switches back'); eq(spider.autopilot_destinations[1].x,99,'its new route kept')
assert(last.targeting:find('switches back as they were',1,true))
spider.autopilot_destination=nil
a=K.plan(p,{min_shield=0.5,retreat={x=-60,y=5}},spider,'remote'); K.start(a)
sd.grid.shield=40
eq(run(a,10),'low_shield'); eq(a.why,'shield 40% fell below min_shield 50%')
local sent
last={}
K.finish(a,'low_shield',last,function(e,args,by) sent={args.go_to,by}; return {route_line='1 target: (-60,5)'} end,'sol')
eq(sent[1].x,-60); eq(sent[2],'sol'); assert(last.retreat:find('its route became 1 target: (-60,5) (retreat); its guns stay on',1,true),last.retreat)
eq(spider.vehicle_automatic_targeting_parameters.auto_target_without_gunner,true,'guns left on for the walk back')
sd.grid.shield=100
a=K.plan(p,{},spider,'remote'); K.start(a); sd.health=1100
eq(run(a,10),'low_health'); eq(a.why,'health 37% fell below min_health 40%')
sd.health=3000
a=K.plan(p,{ammo_below=10},spider,'remote'); K.start(a); sd.ammo.count=9
eq(run(a,10),'out_of_ammo'); eq(a.why,'9 rockets left in its ammo slots, under ammo_below 10')
sd.ammo.count=40

-- 6. By remote view its chunk out of our force's sight ends it; gone ends it destroyed; a kill counts.
a=K.plan(p,{},spider,'remote'); K.start(a)
visible=false; eq(run(a,10),'out_of_coverage'); visible=true
a=K.plan(p,{},spider,'riding'); K.start(a)
visible=false; assert(run(a,10)~='out_of_coverage','riding: its own sight'); visible=true
a=K.plan(p,{},spider,'riding'); K.start(a)
K.died(a,spider,b1); K.died(a,{type='character',vehicle=spider},entities[2]); K.died(a,{type='car'},entities[3])
eq(a.kills,2); eq(a.kills_by['medium-biter'],2)
sd.valid=false; eq(run(a,10),'destroyed'); sd.valid=true

-- 7. None left: back to position, then clear.
for _,e in ipairs(entities) do e.valid=false end
a=K.plan(p,{position={x=30,y=0}},spider,'remote'); K.start(a)
eq(run(a,10),nil); eq(a.mode,'to position'); eq(spider.autopilot_destinations[1].x,30)
sd.position={x=28,y=0}
eq(run(a,10),'clear'); assert(a.why:find('no enemies left within 40 tiles',1,true))

-- 8. No progress: re-routed once (no water on the line: turned 60 degrees), then with water ahead the shore toward the
-- target, then stalled; the reply says what was tried.
sd.position={x=0,y=0}; spider.autopilot_destination=nil
a=K.plan(p,{position={x=100,y=0}},spider,'remote'); K.start(a)
eq(run(a,10),nil)
eq(run(a,K.STALL+10),nil); assert(a.tried=='re-routed once (its route turned 60 degrees)',a.tried)
q=spider.autopilot_destinations[1]; assert(q.y>50,'turned: '..q.x..','..q.y)
wx1,wx2=6,200  -- water ahead of it, all the way
eq(run(a,K.STALL+10),nil); assert(a.tried:find('; shore recovery: to (',1,true),a.tried)
q=spider.autopilot_destinations[1]; assert(q.x<6,'on dry ground: '..q.x)
eq(run(a,K.STALL+10),'stalled'); assert(a.why:find('no progress toward (100,0) for ',1,true) and a.why:find('re-routed once',1,true),a.why)
last={}; K.finish(a,'stalled',last,function() end,'sol'); eq(last.recovery,a.tried); eq(last.turns,2)
wx1,wx2=nil,nil

-- 9. spiderpath: a run of more than GAP tiles blocks a straight line (14 crossed on the copy, 16 did not).
wx1,wx2=10,21  -- 12 tiles: crossable
eq(P.segment(surface,{x=0,y=0},{x=40,y=0}),nil)
wx1,wx2=10,23  -- 14 tiles
local seg=P.segment(surface,{x=0,y=0},{x=40,y=0})
assert(seg and seg.run==14 and seg.tile=='deepwater',seg and seg.line); eq(seg.line,'(0,0) -> (40,0) crosses 14 tiles of deepwater from (10.5,0.5)')
-- the shore: the dry tile nearest the target within 24 tiles (water 10..40: this side)
wx2=40
local s2=P.shore(surface,{x=5,y=0},{x=40,y=0}); assert(s2.x<10,'dry: '..s2.x)

-- 10. A long leg over water: a path requested with the water_tile layer only; when it comes, thinned, the route goes
-- round (spider_kite's own route), and its next point is what progress is read toward.
wx1,wx2,wy=10,40,30
requests={}
sd.position={x=0,y=0}; spider.autopilot_destination=nil
a=K.plan(p,{position={x=60,y=0}},spider,'remote'); K.start(a)
eq(run(a,10),nil); eq(#requests,1); eq(requests[1].collision_mask.layers.water_tile,true); eq(requests[1].goal.x,60)
assert(a.water:find('crosses 31 tiles of deepwater',1,true),a.water)
local path={}
for i=0,50 do path[#path+1]={position={x=i*0.2,y=-i}} end         -- north, along the dry side
for i=1,60 do path[#path+1]={position={x=10+i,y=-50}} end           -- east past the water (it ends at x 41 dry)
for i=1,50 do path[#path+1]={position={x=70-i*0.2,y=-50+i}} end     -- south to the target
local routed
local handled=P.on_path({id=501,path=path},function(rec,plan,sp,pts,notes) routed={rec,plan,pts}; K.routed(a,plan,sp,pts) end)
eq(handled,true); eq(routed[1].owner,'kite'); eq(routed[1].index,7)
assert(#routed[3]>4 and #routed[3]<20,'thinned: '..#routed[3])
eq(#spider.autopilot_destinations,#routed[3]); assert(a.routed:find('round the water to (60,0)',1,true),a.routed)
eq(run(a,10),nil,'its own waypoints are no route change')
eq(P.on_path({id=999},function() error('not ours') end),false)
wx1,wx2=nil,nil

-- 11. vehicle {go_to} (spiderroute.lua): a target over water gets paths; when in, the route goes round and its sender
-- reads it; no progress with water ahead: (d26 batch243) backed off and asked again 3 times, then the stall line.
local R=dofile('mod/agent-harness_0.1.0/spiderroute.lua'){state=state,position=position,who=function(x) return x.name end,path=P}
wx1,wx2=10,40
requests={}
sd.position={x=0,y=0}; spider.autopilot_destination=nil
local r=R.set(spider,{go_to={x=60,y=0}},'sol')
eq(r.route_line,'1 target: (60,0)'); assert(r.water and r.water.crossing[1]:find('crosses 31 tiles of deepwater',1,true),r.water and r.water.crossing[1])
eq(#requests,1)
P.on_path({id=500+#requests,path=path},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end)
assert(#spider.autopilot_destinations>4)
local lines=R.lines({name='sol'},{})
assert(lines and lines[1]:find('its route goes round the water now: ',1,true),lines and lines[1])
-- (d26 batch243) a target on water ends at the dry spot nearest it; no path: asked again from spots its legs step to
-- (island escape), none either: said, the route kept straight to that spot
local r2=R.set(spider,{go_to={x=30,y=0}},'sol')
assert(r2.landed and r2.landed[1]:find('the target (30,0) is on water: the route ends at (41.5,0.5), the nearest spot its legs stand on',1,true),r2.landed and r2.landed[1])
eq(r2.route_line,'1 target: (41.5,0.5)')
local asked=#requests
P.on_path({id=500+#requests},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end)
local hops=#requests-asked; assert(hops>=1 and hops<=P.HOPS,'hops '..hops)
for k=1,hops do P.on_path({id=500+asked+k},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end) end
lines=R.lines({name='sol'},{spiderroute_seen=storage.spiderroute.eseq-1})
assert(lines[1]:find('the pathfinder found no path round the water to (41.5,0.5); asked again from '..hops..' spot',1,true) and lines[1]:find('its route stays 1 target: (41.5,0.5)',1,true),lines[1])
-- standing 2 tiles from the water (within WATER_NEAR) with no path being asked: 3 s, it backs off and asks again (3 times), then the stall line
sd.position={x=8,y=0}
local seen=storage.spiderroute.eseq
local function ticks(n) for _=1,n,60 do game.tick=game.tick+60; R.tick() end end
local function answer() local n=#requests; P.on_path({id=500+n},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end); for k=n+1,#requests do P.on_path({id=500+k},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end) end end
ticks(R.STALL_WATER+60)
lines=R.lines({name='sol'},{spiderroute_seen=seen}); seen=storage.spiderroute.eseq
assert(lines and lines[1]:find('stalled (8,0), ',1,true) and lines[1]:find('with no path being asked: backed off to (',1,true) and lines[1]:find('(recovery 1 of 3)',1,true),lines and lines[1])
local first=spider.autopilot_destinations[1]; assert(first.x<8,'backed off west: '..first.x)
answer()
eq(R.facts(spider).recovery[1],storage.spiderroute.spiders[7101].tries[1])
-- the game: it reaches the back-off spot (the route's first point is done) and walks to the water's edge again
local function again() table.remove(spider.autopilot_destinations,1); sd.position={x=8,y=0} end
for k=2,3 do
  again(); ticks(R.STALL_WATER+120)
  lines=R.lines({name='sol'},{spiderroute_seen=seen}); seen=storage.spiderroute.eseq
  assert(lines and lines[#lines]:find('(recovery '..k..' of 3)',1,true),lines and lines[#lines])
  answer()
end
eq(#storage.spiderroute.spiders[7101].tries,3)
again()
ticks(R.STALL+60)
lines=R.lines({name='sol'},{spiderroute_seen=storage.spiderroute.eseq-1})
assert(lines and lines[#lines]:find('no progress toward',1,true) and lines[#lines]:find('3 recoveries tried',1,true) and lines[#lines]:find('vehicle {go_to, mode: "replace"} sets a new one',1,true),lines and lines[#lines])
-- 12. batch189's retreat route (its guard fired) over water: a path round it requested; the reply's retreat says so,
-- and its re-route and shore recovery run again on that route.
wx1,wx2,wy=10,40,30
sd.position={x=0,y=0}; spider.autopilot_destination=nil
storage.spiderroute.locks=nil
R.set(spider,{go_to={x=-20,y=0}},'sol',7,false)
local tr=storage.spiderroute.spiders[7101]; tr.rerouted, tr.recovered = true, true
local before=#requests
R.retreat(spider,7101,tr,{to={x=60,y=0},standing=true},{why='health 30% under 40%',from={x=0,y=0},health='30%'})
eq(#requests,before+1); eq(requests[#requests].goal.x,60)
assert(tr.retreated.water and tr.retreated.water:find('crosses 31 tiles of deepwater',1,true),tr.retreated.water)
eq(tr.rerouted,nil); eq(tr.recovered,nil)
P.on_path({id=500+#requests,path=path},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end)
assert(#spider.autopilot_destinations>4,'the retreat goes round')
print('d24_batch191: ok')
