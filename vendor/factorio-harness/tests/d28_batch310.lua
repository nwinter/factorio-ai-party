-- Run from repository root: lua tests/d28_batch310.lua
-- (d28 batch310 PS, viewer Aurora site:4841) two spidertrons on one route (spiderpair.lua): vehicle {pair: {lead,
-- follower, distance}}; a go_to on the lead moves both, the follower on the lead's steps (spots it stood on, given once
-- the lead is distance past them); the lead waits while the follower is far behind and past each water step or narrow
-- pass until the follower is past it; both arrived said once; the follower stalled splits the pair; a retreat, spider_kite
-- or a call on the follower ends it at once, never waiting for or moving the partner. A small engine moves each
-- spidertron toward its first route point every tick (up to 0.2 tiles a tick, 12 a second; the copy read 13-13.6),
-- braking to stop at its route's last point, and pops a point within 1 tile; a spidertron marked `nowet` does not step onto water (a follower that cannot take a step).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end
storage={}
local function state() return storage end
defines={events={}}
local player={name='player'}
game={tick=1000,forces={player=player}}
local units={}
game.get_entity_by_unit_number=function(u) return units[u] end
local tiles={}
local function paint(name,x1,y1,x2,y2) for x=x1,x2 do for y=y1,y2 do tiles[x..','..y]=name end end end
local function unpaint() for k in pairs(tiles) do tiles[k]=nil end end
local surface={name='nauvis',index=1}
local function wet_at(x,y) local n=tiles[math.floor(x)..','..math.floor(y)] return n=='water' or n=='deepwater' end
surface.get_tile=function(x,y)
  local name=tiles[math.floor(x)..','..math.floor(y)] or 'grass-1'
  local w=name=='water' or name=='deepwater'
  return {valid=true,name=name,collides_with=function(l) return w and (l=='water_tile' or l=='player' or l=='doodad') or false end,
    prototype={collision_mask={layers=w and {player=true,water_tile=true} or {}}}}
end
surface.count_entities_filtered=function() return 0 end
surface.count_tiles_filtered=function() return 0 end
surface.find_entities_filtered=function() return {} end
local requests={}
surface.request_path=function(r) requests[#requests+1]=r; return 900+#requests end
local function position(q) return {x=q.x or q[1],y=q.y or q[2]} end
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end

local S=dofile('mod/agent-harness_0.1.0/sharedroutes.lua'){state=state}
local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state,routes=S}
local R=dofile('mod/agent-harness_0.1.0/spiderroute.lua'){state=state,position=position,who=function(x) return x.name end,path=P}
local Pair
Pair=dofile('mod/agent-harness_0.1.0/spiderpair.lua'){state=state,path=P,
  say=function(text,to,unit) return R.say(text,to,unit) end,route=function(e) return R.route(e) end,
  seq=function(u) return R.seq(u) end,set_of=function(u) return R.set_of(u) end,held=function(e) return R.held(e) end,
  hold=function(e,why) return R.hold(e,why) end,resume=function(e) return R.resume(e) end,retreated=function(e) return R.retreated(e) end,
  ahead=function(e,q) return q and R.ahead(e,q) or nil end,unadopt=function(e,c) return R.unadopt(e,c) end,
  adopt=function(e,pr) return R.adopt(e,Pair.owner(e) or pr.agents[1],nil,pr.id) end,
  sender=function(u) local s=R.set_of(u) return s and s.by or nil end}
R.pair=Pair
local function routed(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end
local function answer(id,path) return P.on_path({id=id,path=path},routed) end

-- spidertrons: name, unit, position, speed (tiles a tick); nowet: never steps onto water
local spiders={}
local function mk(unit,x,y,o)
  o=o or {}
  local route={}
  local d={valid=true,name=o.name or 'spidertron',unit_number=unit,position={x=x,y=y},surface=surface,force=player,v=o.v or 0.2,nowet=o.nowet}
  local e=setmetatable({},{__index=function(_,k)
    if k=='autopilot_destinations' then return route end
    if k=='autopilot_destination' then return route[1] end
    if k=='route' then return route end
    return d[k]
  end,__newindex=function(_,k,v) if k=='autopilot_destination' then for i=#route,1,-1 do route[i]=nil end; if v then route[1]=v end else d[k]=v end end})
  d.get_spider_legs=function() return {{prototype={collision_mask={layers={player=true,rail=true}}}}} end
  d.add_autopilot_destination=function(q) route[#route+1]={x=q.x or q[1],y=q.y or q[2]} end
  units[unit]=e
  spiders[#spiders+1]=e
  return e
end
-- each tick: speed toward the route's last point, braking to stop there (the copy: from full speed it stopped within
-- 3-4 tiles, and reached full speed again in under 1 s): accel 0.006 tiles a tick each tick
local ACC=0.006
local function move(e)
  local r=e.route
  local q=r[1]
  if not q then e.cur=0; return end
  local p=e.position
  local rem=dist(p,q)
  for i=2,#r do rem=rem+dist(r[i-1],r[i]) end
  local want=math.min(e.v,math.sqrt(2*ACC*rem))
  e.cur=math.min(want,(e.cur or 0)+ACC)
  local v=math.max(e.cur,0.01)
  local d=dist(p,q)
  if d<=v then e.position={x=q.x,y=q.y} else e.position={x=p.x+(q.x-p.x)*v/d,y=p.y+(q.y-p.y)*v/d} end
  if e.nowet and wet_at(e.position.x,e.position.y) then e.position=p; e.cur=0 end
  if dist(e.position,q)<1 then table.remove(r,1) end
end
-- n ticks of the game: moves, then the samples as runtime.lua runs them
local function run(n,stop)
  for _=1,n do
    game.tick=game.tick+1
    for _,e in ipairs(spiders) do if e.valid then move(e) end end
    if game.tick%60==37 then R.tick() end
    if game.tick%10==3 then Pair.tick() end
    if stop and stop() then return true end
  end
end
local function alerts(to)
  local out={}
  for _,ev in ipairs(storage.spiderroute.events) do if not to or ev.to==to then out[#out+1]=ev.text end end
  return table.concat(out,'\n')
end
local function resolve(ref) return units[ref] end
local function call(a,me) return Pair.call(a,me,resolve) end
local function err(fn) local ok,e=pcall(fn); assert(not ok,'refused'); return tostring(e) end

-- 1. pairing: refusals, then one agent's two spidertrons (sent last by sol: hers)
local L=mk(7001,0.5,100.5)
local F=mk(7002,-9.5,100.5)
has(err(function() call({pair={lead=7001}},'sol') end),'pair is {lead, follower, distance}')
has(err(function() call({pair={lead=7001,follower=7001}},'sol') end),'two spidertrons')
has(err(function() call({pair={lead=7001,follower=7002,distance=3}},'sol') end),'distance is 6..40')
has(err(function() call({pair={lead=7001,follower=7002,gap=3}},'sol') end),'not gap')
R.claim(L,'sol','go_to'); R.claim(F,'sol','go_to')
local out=call({pair={lead=7001,follower=7002}},'sol')
has(out.pair,'pair 1 (#7001 leads, #7002 follows), 10 tiles apart on the lead\'s steps (agreed by sol); a go_to on #7001 moves both')
has(out.rule,'both are spidertron (one prototype, the same legs)'); has(out.rule,'up to 14 tiles of water')
-- either one already in it: refused naming the pair
local X=mk(7003,40.5,140.5)
has(err(function() call({pair={lead=7003,follower=7002}},'sol') end),'spidertron #7002 is in pair 1 (#7001 leads, #7002 follows): vehicle {pair: false, vehicle: 7002} ends it first')

-- 2. open ground: the follower 10 tiles behind on the lead's steps; both arrived said once; no wait at equal speed
game.tick=2000
out=R.set(L,{go_to={x=120.5,y=100.5}},'sol')
has(out.pair.join,'#7002 joins from (-9.5,100.5), 10 tiles from #7001'); eq(out.pair.gates,'no water step or narrow pass on its route')
has(out.pair.line,'walking: #7001 at (0.5,100.5)')
eq(storage.spiderroute.spiders[7002].paired,1,'the follower: an entry its guard reads, sampled by the pair')
local worst=0
run(900,function()
  local pr=Pair.of(7001)
  if os.getenv('DBG') and pr and pr.walk and game.tick%10==4 and game.tick<2300 then print(game.tick,L.position.x,F.position.x,#F.route,pr.walk.given,#pr.walk.crumbs,R.held(L),pr.walk.lead_s-pr.walk.f_s) end
  if pr and pr.walk and L.route[1] and F.position.x>0 then worst=math.max(worst,dist(L.position,F.position)) end
  return pr and pr.done
end)
local pr=Pair.of(7001)
assert(pr.done,'both arrived')
assert(L.position.x>=119.5,'the lead at its target (the small engine pops a point within 1 tile)'); assert(worst<=10+6,'never far apart walking: '..worst)
local gap=dist(L.position,F.position); assert(gap>=7 and gap<=13,'the follower about distance behind: '..gap)
eq(pr.done.holds,0,'equal speed: the lead never waited')
has(alerts('sol'),'pair 1 (#7001 leads, #7002 follows) arrived: #7001 at (119.6,100.5), #7002 at (110.8,100.5) (9 tiles apart)')
eq(storage.spiderroute.spiders[7002] and storage.spiderroute.spiders[7002].paired or nil,nil,'released from the pair\'s sampling')
lacks(alerts('sol'),'no progress')

-- 3. a waited go_to of the lead: arrived only once both have; a slower follower: the lead waits (counted), resumes
F.v=0.1
F.position={x=100.5,y=100.5}
game.tick=4000
out=R.set(L,{go_to={x=20.5,y=100.5}},'sol')
local pw=Pair.walk_of(7001)
local action={kind='spider_go',spider=L,unit=7001,set_tick=game.tick,start_tick=game.tick,until_tick=game.tick+18000,target={x=20.5,y=100.5},set_seq=R.seq(7001),pair=pw.id,walk=pw.walk}
local outcome
local lead_at
run(3000,function()
  if not L.route[1] and not R.held(L) and not lead_at then lead_at=game.tick end
  if game.tick%60==40 then outcome=R.watch(action) end
  return outcome
end)
eq(outcome,'arrived'); assert(lead_at and lead_at<game.tick,'the lead\'s route ended before the follower arrived')
local last={}
R.finish(action,'arrived',last)
has(last.pair,'both arrived: #7001 at (21.5,100.5), its follower at (31.4,100.5) (10 tiles apart); it waited'); has(last.pair,'it waited')
assert(Pair.of(7001).done.holds>=1,'the slower follower: the lead waited')
has(last.why,'arrived at (21.5,100.5)')
F.v=0.2

-- 4. another agent's spidertron: an ask until that agent makes the same call; then paired with both agents
local A=mk(7004,0.5,160.5)
local B=mk(7005,-9.5,160.5)
R.claim(B,'astra','go_to')
out=call({pair={lead=7004,follower=7005,distance=12}},'sol')
has(out.offered,'#7004 (lead) and #7005 (follower): each spidertron another agent has is paired once that agent makes the same call (within 10 min): #7005: astra sent it last')
has(alerts('astra'),'sol asks to pair spidertron #7004 (lead) and #7005 (follower), 12 tiles apart: vehicle {pair: {lead: 7004, follower: 7005}} agrees')
eq(Pair.of(7004),nil,'not paired yet')
local lines=Pair.mine('sol'); has(lines[1],'asked to pair #7004 (lead) and #7005 (follower)')
out=call({pair={lead=7004,follower=7005,distance=12}},'astra')
has(out.pair,'pair 2 (#7004 leads, #7005 follows), 12 tiles apart on the lead\'s steps (agreed by astra, sol)')
-- the ask lapses after 10 minutes; pair: false with either spidertron declines or withdraws an ask
R.claim(X,'luna','go_to')
local Y=mk(7006,30.5,140.5)
call({pair={lead=7006,follower=7003}},'sol')
assert(next(storage.spiderpairs.offers),'asked')
game.tick=game.tick+36001
Pair.tick()
eq(next(storage.spiderpairs.offers),nil,'the ask lapsed')
call({pair={lead=7006,follower=7003}},'sol')
out=call({pair=false,vehicle=7003},'luna'); has(out.withdrawn,'1 offer to pair spidertron #7003 withdrawn')
eq(next(storage.spiderpairs.offers),nil)
has(err(function() call({pair=false,vehicle=7003},'luna') end),'spidertron #7003 is in no pair')
out=call({pair=false,vehicle=7005},'astra'); has(out.released,'pair 2')
has(alerts('sol'),'pair 2 (#7004 leads, #7005 follows) ended: astra ended it (vehicle {pair: false})')
eq(Pair.of(7004),nil)

-- 5. a stored route round water (batch305): the lead's go_to reuses it in the call; the follower walks its steps round
-- the lake and arrives with it; both legs fit the stored route (the follower joins at its start)
unpaint()
paint('water',10,-40,40,40)
L.position={x=0.5,y=0.5}; F.position={x=-9.5,y=0.5}
for _,e in ipairs({L,F}) do e.autopilot_destination=nil end
local around={}
for _,q in ipairs({{0.5,0.5},{0.5,-45.5},{12.5,-45.5},{24.5,-45.5},{36.5,-45.5},{48.5,-45.5},{60.5,-45.5},{60.5,-30.5},{60.5,-15.5},{60.5,0.5}}) do around[#around+1]={position={x=q[1],y=q[2]}} end
-- astra's spidertron asked the path once (kept as a stored route)
local Z=mk(7009,0.5,2.5)
local n0=#requests
R.set(Z,{go_to={x=60.5,y=0.5}},'astra')
answer(900+#requests,around)
Z.autopilot_destination=nil; Z.position={x=-200.5,y=0.5}
game.tick=game.tick+600
out=R.set(L,{go_to={x=60.5,y=0.5}},'sol')
eq(#requests,n0+1,'no path asked: the stored route read again')
has(out.shared_route,'reused route'); has(out.shared_route,'legs unchanged')
eq(out.pair.gates,'no water step or narrow pass on its route')
pr=Pair.of(7001)
run(1600,function() return Pair.of(7001).done end)
assert(Pair.of(7001).done,'both arrived round the lake')
for _,c in ipairs(pr.walk and pr.walk.crumbs or {}) do assert(not wet_at(c.x,c.y),'a step on water') end
assert(dist(F.position,{x=60.5,y=0.5})<16,'the follower by the target: '..F.position.x..','..F.position.y)
assert(F.position.y<0,'the follower came round by the lead\'s steps (north of the lake): '..F.position.y)

-- 6. retreats stay independent. The lead waiting for a slow follower retreats at once (its guard): its route becomes the
-- retreat, its kept route dropped; the pair ends at the next sample; the follower stops where it stands.
unpaint()
local function fresh(lx,fx,y)
  R.rearm('sol')  -- a retreat holds its spidertron until re-armed (retreat_guard)
  for _,e in ipairs({L,F}) do e.autopilot_destination=nil; e.cur=0 end
  L.position={x=lx,y=y}; F.position={x=fx,y=y}
  if not Pair.of(7001) then R.claim(L,'sol','go_to'); R.claim(F,'sol','go_to'); call({pair={lead=7001,follower=7002}},'sol') end
end
fresh(0.5,-30.5,200.5)
F.v=0.05
R.set(L,{go_to={x=150.5,y=200.5}},'sol')
run(200,function() return R.held(L) end)
assert(R.held(L),'the lead waits for the slow follower'); eq(#L.route,0,'its route kept aside')
local t=storage.spiderroute.spiders[7001]
R.retreat(L,7001,t,{to={x=0.5,y=230.5}},{why='health 30% under 40%',from={x=L.position.x,y=L.position.y},health='300/1000'})
eq(#L.route,1); eq(L.route[1].y,230.5,'its route is the retreat at once, not waiting for its partner'); eq(R.held(L),false)
local fbefore=#F.route
assert(fbefore>0,'the follower was walking')
run(10)
eq(Pair.of(7001),nil,'the pair ended')
has(alerts('sol'),'pair 1 (#7001 leads, #7002 follows) ended: #7001 retreated (the go_to\'s retreat: health 30% under 40%) from (')
has(alerts('sol'),'its retreat goes on alone; #7002 stops where it stands at (')
eq(#F.route,0,'the follower stops: never dragged along the retreat'); eq(L.route[1].y,230.5,'the retreat route stays')
-- the follower retreats: the lead gets its route back and goes on alone; the follower's retreat is its own
F.v=0.05
fresh(0.5,-30.5,260.5)
R.set(L,{go_to={x=150.5,y=260.5}},'sol')
run(200,function() return R.held(L) end)
assert(R.held(L))
local tf=storage.spiderroute.spiders[7002]
assert(tf and tf.paired,'the follower has an entry its guard reads')
R.retreat(F,7002,tf,{to={x=-40.5,y=260.5}},{why='shield 10% under 20%',from={x=F.position.x,y=F.position.y},health='900/1000'})
eq(F.route[1].x,-40.5,'the follower retreats at once')
run(10)
eq(Pair.of(7001),nil)
has(alerts('sol'),'ended: #7002 retreated (the go_to\'s retreat: shield 10% under 20%)'); has(alerts('sol'),'#7001 goes on alone (its route stays)')
eq(R.held(L),false); eq(L.route[#L.route].x,150.5,'the lead\'s route given back'); eq(F.route[1].x,-40.5,'the follower\'s retreat untouched')
F.v=0.2
-- spider_kite on the lead (runtime: its entry dropped, the route claimed): the pair ends, the follower stops
fresh(0.5,-9.5,300.5)
R.set(L,{go_to={x=150.5,y=300.5}},'sol')
run(120)
storage.spiderroute.spiders[7001]=nil; R.claim(L,'luna','spider_kite'); L.autopilot_destination=nil
run(10)
eq(Pair.of(7001),nil); has(alerts('sol'),'luna set #7001\'s route (spider_kite) outside the pair; #7002 stops where it stands'); eq(#F.route,0)
-- a go_to on the follower ends it at once; the lead goes on
fresh(0.5,-9.5,330.5)
R.set(L,{go_to={x=150.5,y=330.5}},'sol')
run(120)
out=R.set(F,{go_to={x=0.5,y=360.5}},'astra')
has(out.pair.released,'astra set #7002\'s route (go_to): a call on the follower ends the pair; #7001 goes on alone (its route stays)')
eq(Pair.of(7001),nil); eq(F.route[#F.route].y,360.5,'its own go_to'); eq(L.route[#L.route].x,150.5)
-- the lead's clear stops both, the pair stays
fresh(0.5,-9.5,390.5)
R.set(L,{go_to={x=150.5,y=390.5}},'sol')
run(120)
out=R.set(L,{clear=true},'sol')
has(out.pair.note,'#7002 stops where it stands'); eq(#F.route,0); assert(Pair.of(7001),'still paired')

-- 7. a water step the lead's legs take and the follower's do not (nowet): said before the move; the lead waits past it
-- for the follower (said once); the follower stalls at the shore: the pair splits, said with where and the step; the
-- lead goes on alone; a waited go_to ends stalled naming the follower
fresh(0.5,-9.5,420.5)
paint('water',40,415,45,426)
F.nowet=true
out=R.set(L,{go_to={x=120.5,y=420.5}},'sol')
eq(out.pair.gates,'a water step of 6 tiles at (40.5,420.5)')
pw=Pair.walk_of(7001)
action={kind='spider_go',spider=L,unit=7001,set_tick=game.tick,start_tick=game.tick,until_tick=game.tick+18000,target={x=120.5,y=420.5},set_seq=R.seq(7001),pair=pw.id,walk=pw.walk}
outcome=nil
run(1500,function() if game.tick%60==40 then outcome=R.watch(action) end return outcome end)
eq(outcome,'stalled')
has(alerts('sol'),'(#7001 leads, #7002 follows): #7001 waits past the water step at (40.5,420.5) (6 tiles of water) for #7002 to cross it')
has(alerts('sol'),'ended: #7002 made no progress for 5s at (40,420.5), 13 tiles behind #7001 on its steps')
has(alerts('sol'),'at the water step at (40.5,420.5) (6 tiles of water) that #7001 crossed')
has(alerts('sol'),'on the straight line ahead: water at (40.5,420.5), 1 tile ahead'); has(alerts('sol'),'#7001 goes on alone (its route stays); #7002 stops there (its route cleared)')
last={}
R.finish(action,'stalled',last)
eq(last.stalled_one,'follower'); has(last.why,'its follower stalled: #7002 made no progress'); has(last.pair,'ended 10s after this go_to: #7002 made no progress')
eq(R.held(L),false); assert(#L.route>0,'the lead goes on alone')
F.nowet=nil

-- 8. two prototypes: the route planned for the shorter reach (another prototype's not measured: any water counts)
unpaint()
paint('water',20,470,22,490)
local M2=mk(7010,0.5,480.5,{name='spidertron-mk9'})
R.claim(M2,'sol','go_to')
call({pair={lead=7004,follower=7010}},'sol')
A.position={x=0.5,y=482.5}
eq(Pair.gap(A),0)
local n1=#requests
out=R.set(A,{go_to={x=60.5,y=480.5}},'sol')
eq(#requests,n1+1,'a 3-tile water step its legs take alone: a path asked for the pair')
has(out.pair.rule,'spidertron: its legs step across up to 14 tiles of water and spidertron-mk9: its legs\' reach is not measured, so any water on its line counts')

-- 9. the follower's way to the lead crosses a lake: a path is asked for it (said before the move); no steps are given
-- until it comes; the lead waits while it is far behind; then both arrive
unpaint()
paint('water',-30,500,-10,560)
fresh(0.5,-40.5,530.5)
n1=#requests
out=R.set(L,{go_to={x=60.5,y=530.5}},'sol')
has(out.pair.join,'#7002\'s line to #7001 crosses water its legs do not step across ((-40.5,530.5) -> (0.5,530.5) crosses 21 tiles of water from (-29.5,530.5)): a path round it was asked for #7002; #7001 waits for it')
eq(#requests,n1+1); eq(requests[#requests].goal.x,0.5,'the follower\'s path to the lead\'s spot')
run(60)
eq(#F.route,1,'no steps given while its path is asked'); assert(R.held(L),'the lead waits')
answer(900+#requests,{{position={x=-40.5,y=530.5}},{position={x=-40.5,y=565.5}},{position={x=0.5,y=565.5}},{position={x=0.5,y=530.5}}})
assert(#F.route>1,'its path to the lead\'s spot')
run(2500,function() return Pair.of(7001).done end)
assert(Pair.of(7001).done,'both arrived'); assert(dist(F.position,L.position)<16)

-- 10. a narrow pass 10 tiles long, 2 wide (a neck in a water wall): one gate on the route and on the steps
unpaint()
for x=60,69 do for y=590,620 do if y~=605 and y~=606 then tiles[x..','..y]='water' end end end
fresh(0.5,-9.5,605.5)
out=R.set(L,{go_to={x=120.5,y=605.5}},'sol')
eq(out.pair.gates,'a narrow pass 2 tiles wide at (60.5,605.5)')
local gates10=0
run(1500,function()
  local p=Pair.of(7001)
  if p.walk then local n=0 for _,c in ipairs(p.walk.crumbs) do if c.gate then n=n+1 end end gates10=math.max(gates10,n) end
  return p.done
end)
assert(Pair.of(7001).done,'both through the neck')
eq(gates10,1,'the neck read at each step inside it is one gate')

print('d28_batch310 ok')
