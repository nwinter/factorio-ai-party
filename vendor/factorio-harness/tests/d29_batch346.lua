-- Run from repository root: lua tests/d29_batch346.lua
-- d29 batch346 LC (Astra, board #2754: "Asterion minimum safe cap 5 AQ launches/hour was verbal; native requests/min
-- payload 10 produced 23 pods before audit (81886081..81928832), 18 repair pods 303 packs. Count requests does not cap
-- launches; teammate correction races already loaded/in flight pods.")
-- 1. launchcount.count: the rockets to a platform in a window or since a tick, by origin: launched (the pod log's
--    rockets: landed, in flight, gone) + loaded (silos with a rocket ready whose request target is it), each shown.
-- 2. launches_at_least: met at n, the counts as its evidence, counted at most every LAUNCH_EVERY ticks; arguments
--    checked; the harness stops nothing (the reply says what follows is the guard's own steps).
-- 3. shipment {launches}; the remote lane takes the condition.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
defines={inventory={cargo_unit=2},events={on_cargo_pod_started_ascending=901,on_cargo_pod_finished_ascending=902,on_cargo_pod_finished_descending=903,
  on_cargo_pod_delivered_cargo=904},rocket_silo_status={building_rocket=0,rocket_ready=7,launch_started=9}}
storage={}
prototypes={item={['repair-pack']={}},space_location={aquilo={},nauvis={},['solar-system-edge']={}}}
local function inv(list) local x={list=list}; x.get_contents=function() return x.list end; x.get_item_count=function() return 0 end; return x end
local aquilo,nauvis={name='aquilo'},{name='nauvis'}
local asterion={name='Asterion',valid=true,space_location={name='aquilo'}}
local resolute={name='Resolute',valid=true,space_location={name='aquilo'}}
local function hub_of(pl) return {valid=true,type='space-platform-hub',surface={name='platform-'..pl.name,platform=pl},position={x=0,y=0}} end
local hubs={Asterion=hub_of(asterion),Resolute=hub_of(resolute)}
local platform_surface={name='platform-5',platform=asterion}
game={tick=81886000,surfaces={aquilo=aquilo,nauvis=nauvis,['platform-5']=platform_surface},get_player=function() return nil end}
local force={platforms={asterion,resolute}}
local function silo(surface,x,status,target) return {valid=true,type='rocket-silo',name='rocket-silo',unit_number=x,surface=surface,position={x=x,y=0},
  rocket_silo_status=status,transitional_request_target=target} end
local aq_silos={silo(aquilo,10,7,asterion),silo(aquilo,20,7,resolute),silo(aquilo,30,0,asterion)}
local nv_silos={silo(nauvis,40,7,asterion)}
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}
local units=0
local pods={}
local function launch(from,to,tick,items)
  units=units+1
  local cargo=inv(items or {{name='repair-pack',quality='normal',count=17}})
  local p={valid=true,unit_number=units,cargo_pod_origin=from,cargo_pod_destination={station=hubs[to.name],type=1},surface=from.surface,position={x=0,y=0}}
  p.get_inventory=function() return cargo end
  pods[#pods+1]=p
  P.on_launch{rocket={attached_cargo_pod=p},rocket_silo=from,tick=tick}
  return p
end
local LC=dofile('mod/agent-harness_0.1.0/launchcount.lua'){ups=function(...) return P.ups(...) end,
  silos=function(f,s) eq(f,force); if s==aquilo then return aq_silos elseif s==nauvis then return nv_silos end return {} end}

-- Astra's 23 pods from Aquilo to Asterion, 81886081..81928832 (one every 1943.2 ticks, about 32 s), each landing 35 s
-- later; a rocket from Nauvis to Asterion and one from Aquilo to Resolute in between, and a hub pod down: none of them
-- Aquilo's to Asterion
local first,last=81886081,81928832
for i=0,22 do
  local t=first+math.floor((last-first)*i/22+0.5)
  game.tick=t
  local p=launch(aq_silos[1],asterion,t)
  if i==10 then launch(nv_silos[1],asterion,t+5); launch(aq_silos[2],resolute,t+7) end
  if i<21 then P.on_event{name=903,tick=t+2100,cargo_pod=p} end  -- the last two still in flight
end
P.on_event{name=901,tick=last+10,cargo_pod={valid=true,unit_number=999,cargo_pod_origin=hubs.Asterion,cargo_pod_destination={surface='aquilo',type=2},
  surface=hubs.Asterion.surface,position={x=0,y=0},get_inventory=function() return inv({}) end}}
game.tick=last+60

do
  local r=LC.count(force,'Asterion',{window=3600,origin='aquilo'})
  eq(r.launched,23); eq(r.landed,21); eq(r.in_flight,2); eq(r.loaded,1); eq(r.total,24); eq(r.complete,true)
  eq(r.since_tick,last+60-216000); eq(r.newest_tick,last); eq(r.oldest_tick,first); eq(r.by_planet.aquilo,23); eq(r.by_planet.nauvis,nil)
  has(r.line,'rockets to Asterion in the last 3600 s (since tick 81712892) from aquilo: 23 launched (21 landed, 2 in flight; aquilo 23) + 1 loaded in silos aimed at it (aquilo (10,0)) = 24')
  -- every origin: Nauvis's rocket and its ready silo too; Resolute's rocket and silo never
  r=LC.count(force,'Asterion',{window=3600})
  eq(r.launched,24); eq(r.loaded,2); eq(r.total,26); has(r.line,'aquilo 23, nauvis 1')
  -- since a tick (at or after it): Astra's first pod counts
  r=LC.count(force,'Asterion',{since_tick=first,origin='aquilo'})
  eq(r.launched,23); has(r.line,'since tick 81886081 from aquilo')
  eq(LC.count(force,'Asterion',{since_tick=first+1,origin='aquilo'}).launched,22)
  -- a 5-minute window: the last 10 pods (every 1943 ticks back from 81928832, 17940 ticks)
  r=LC.count(force,'Asterion',{window=300,origin='aquilo'})
  eq(r.launched,10); eq(r.in_flight,2)
  -- a platform not ours: launches counted, no silo read, said
  r=LC.count(force,'Nobody',{window=3600})
  eq(r.total,0); has(r.line,'no platform of ours named Nobody')
  -- a pod gone with no landing (removed with its platform, or in orbit) counts as launched, said apart
  pods[#pods].valid=false
  P.sweep(game.tick)
  r=LC.count(force,'Asterion',{window=3600,origin='aquilo'})
  eq(r.launched,23); eq(r.in_flight,1); eq(r.gone,1); has(r.line,'(21 landed, 1 in flight, 1 gone unlanded; aquilo 23)')
  -- the census has not read a planet's silos yet: said
  local LC2=dofile('mod/agent-harness_0.1.0/launchcount.lua'){ups=function(...) return P.ups(...) end,silos=function() return nil end}
  r=LC2.count(force,'Asterion',{window=3600,origin='aquilo'})
  eq(r.loaded,0); has(r.line,'silos not read yet on aquilo')
end
print('d29_batch346 1. launch count: launched (landed, in flight, gone) + loaded, by origin, window or since: ok')

do
  local C=require('conditions'){launch_count=function(f,name,o) return LC.count(f,name,o) end}
  local p={force=force}
  -- Astra's cap: 5 Aquilo launches to Asterion an hour, guarded
  local c={['until']='launches_at_least',platform='Asterion',n=5,window=3600,origin='aquilo'}
  C.validate(c)
  local met,saw=C.check(p,c)
  eq(met,true)
  has(saw,'= 24 (met at 5); the harness stops nothing: what follows is this guard\'s own steps, or the plan\'s next step')
  eq(c.evidence.launched,23); eq(c.evidence.loaded,1); eq(c.evidence.total,24); eq(c.evidence.in_flight,1)
  -- under n: not met, no evidence; counted at most every LAUNCH_EVERY ticks
  local d={['until']='launches_at_least',platform='Asterion',n=30,since_tick=first,origin='aquilo'}
  C.validate(d)
  met,saw=C.check(p,d); eq(met,false); eq(d.evidence,nil); has(saw,'(met at 30)')
  local t0=game.tick
  for i=1,6 do launch(aq_silos[1],asterion,t0+i) end
  game.tick=t0+30
  met,saw=C.check(p,d); eq(met,false); has(saw,'counted at tick '..t0)
  game.tick=t0+60
  met,saw=C.check(p,d); eq(met,true); has(saw,'29 launched'); eq(d.evidence.tick,t0+60)
  -- the remote lane takes it in a wait and a guard's when (queue_lanes.lua's check text)
  local src=io.open('mod/agent-harness_0.1.0/queue_lanes.lua'):read('a')
  has(src,"c['until']=='launches_at_least') and type(c.platform)=='string'")
  -- arguments
  fails(function() C.validate({['until']='launches_at_least',n=5,window=3600}) end,'launches_at_least requires platform')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',window=3600}) end,'launches_at_least n: 1..100000')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=2.5,window=3600}) end,'launches_at_least n: 1..100000')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=5}) end,'window (seconds back from now, 1..86400) or since_tick')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=5,window=60,since_tick=1}) end,'one of them')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=5,window=90000}) end,'window: 1..86400')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=5,since_tick=game.tick+1}) end,'since_tick is a whole game tick 0..now')
  fails(function() C.validate({['until']='launches_at_least',platform='Asterion',n=5,window=60,origin='mars'}) end,'origin: a planet name')
end
print('d29_batch346 2. launches_at_least: met at n with its counts as evidence, counted every 60 ticks, arguments checked: ok')

do
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){launches=function(p,a) return LC.read(p,a) end,state=function() return storage end}
  local r=S.read({force=force},{launches=true,platform='Asterion',window=3600,origin='aquilo'})
  eq(r.launched,29); eq(r.loaded,1); eq(r.total,30); has(r.line,'rockets to Asterion in the last 3600 s'); has(r.note,'a cap is your own guard')
  fails(function() S.read({force=force},{launches=true,platform='Asterion',window=3600,item='rail'}) end,'launches takes platform, window or since_tick, and origin')
  fails(function() S.read({force=force},{launches=true,platform='Asterion'}) end,'window (seconds, 1..86400) or since_tick')
end
print('d29_batch346 3. shipment {launches}: ok')

-- the pod log keeps its last KEEP journeys a planet: a window reaching past its oldest says so (at least)
do
  local keep=P.KEEP  -- last: it trims the log
  P.KEEP=20
  launch(aq_silos[1],asterion,game.tick)  -- trims Aquilo's list to its last 20
  local r=LC.count(force,'Asterion',{since_tick=first,origin='aquilo'})
  eq(r.complete,false); has(r.line,'some may be missing (at least)')
  eq(LC.count(force,'Asterion',{window=60,origin='aquilo'}).complete,true)
  P.KEEP=keep
end
print('d29_batch346 4. a window past the pod log\'s oldest kept journey: complete false, said: ok')
