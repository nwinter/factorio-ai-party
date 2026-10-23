-- Run with lua tests/pushalerts.lua: the game's alerts and key warnings,
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
-- pushed to the agents they concern (pushalerts.lua). Viewer Enginerd,
-- shift07 15:30: "The agents would be a lot more efficient if they'd react to
-- the alerts in the UI, like reacting to unpowered buildings."
local find_fail  -- (d20 batch55: a find that raises)
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3},inventory={turret_ammo=7},
  alert_type={entity_destroyed=1,no_material_for_construction=2,turret_out_of_ammo=3,not_enough_repair_packs=4,custom=5}}
storage={board={items={}}}
local force={name='player',players={}}
local ents={nauvis={},vulcanus={},['platform-1']={}}
local finds,wholes={},0
local standing={}   -- what stands on a point (targets.standing): entities by position, any type
local function surface(name,index,platform)
  return {name=name,index=index,platform=platform,find_entities_filtered=function(f)
    if f.position and not f.type then
      local out={}
      for _,e in ipairs(standing) do
        if e.valid and math.abs(e.position.x-f.position.x)<=0.5 and math.abs(e.position.y-f.position.y)<=0.5 then out[#out+1]=e end
      end
      return out
    end
    eq(f.force,force); assert(f.type and f.limit,'by type, bounded')
    local types={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
    finds[#finds+1]=f.type
    if find_fail then error(find_fail) end
    if not f.area then wholes=wholes+1 end
    local a=f.area
    local out={}
    for _,e in ipairs(ents[name]) do
      local p=e.position
      if e.valid and types[e.type] and (not a or (p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2])) then out[#out+1]=e end
    end
    return out end}
end
local nauvis,vulcanus=surface('nauvis',1),surface('vulcanus',2)
game={tick=100000,surfaces={nauvis,vulcanus,surface('platform-1',3,{name='Sunward'})}}
game.get_surface=function(n) for _,s in pairs(game.surfaces) do if s.name==n then return s end end end
local function user(name) return name and {name=name} or nil end
local function ent(s,name,type,x,y,f)
  local e={valid=true,name=name,type=type,position={x=x,y=y},status=0,electric_network_id=7}
  for k,v in pairs(f or {}) do e[k]=v end
  if type=='ammo-turret' then
    e.get_inventory=function(i) eq(i,7); return {get_item_count=function() return e.rounds or 0 end} end
  end
  ents[s][#ents[s]+1]=e
  return e
end
-- The east block: 8 assemblers without power and 2 no pole reaches, built by luna.
for i=1,8 do ent('nauvis','assembling-machine-2','assembling-machine',120+i,40,{status=1,last_user=user('luna')}) end
for i=1,2 do ent('nauvis','assembling-machine-2','assembling-machine',130+i,44,{status=1,electric_network_id=false,last_user=user('luna')}) end
-- 12 empty gun turrets in sol's claim, 3 armed.
local turrets={}
for i=1,12 do turrets[i]=ent('nauvis','gun-turret','ammo-turret',60+i,-170) end
for i=1,3 do ent('nauvis','gun-turret','ammo-turret',60+i,-160,{rounds=50}) end
storage.board.items[1]={kind='claim',status='claimed',owner='sol',id=4,area={left_top={x=40,y=-190},right_bottom={x=100,y=-150}}}
storage.board.items[2]={kind='claim',status='done',owner='luna',area={left_top={x=-200,y=-200},right_bottom={x=200,y=200}}}
-- 5 furnaces out of fuel near the start, built by nobody known: the nearest agent (astra).
for i=1,5 do ent('nauvis','stone-furnace','furnace',i*2,2,{status=3}) end
-- A dry flamer and a working assembler on Vulcanus; a platform's entities are platalerts' (never scanned).
-- Flamers as the 2.0 engine has them (a fluidbox on the pipe line and a buffer it fires from; get_fluid_contents holds
-- both): a dry one, and one on a drained line (fluidbox[1] nil) with 87.2 crude oil in its buffer (Astra, shift11 16:36:
-- that one fired and burnt a reactor), which is not out of oil.
local FLAMER={name='flamethrower-turret',fluidbox_prototypes={{volume=100}},fluid_buffer_size=100,
  attack_parameters={fluids={{type='crude-oil'},{type='heavy-oil'},{type='light-oil'}}}}
ent('vulcanus','flamethrower-turret','fluid-turret',10,10,{prototype=FLAMER,fluidbox={},get_fluid_contents=function() return {} end})
ent('vulcanus','flamethrower-turret','fluid-turret',12,10,{prototype=FLAMER,fluidbox={},
  get_fluid_contents=function() return {['crude-oil']=87.2} end})
ent('platform-1','assembling-machine-1','assembling-machine',0,0,{status=1})
-- The game's alert panel (an agent player's): ghosts waiting for materials; turret and loss alerts are told elsewhere.
local ghost={valid=true,name='entity-ghost',position={x=-40.5,y=10.5}}
local reader={get_alerts=function(f) eq(next(f),nil); return {
  [1]={[2]={{target=ghost},{position={x=-41,y=12},prototype={name='transport-belt'}}},[3]={{target=turrets[1]}},[1]={{position={x=0,y=0}}}}} end}
local places={[1]={key='nauvis',position={x=5,y=5}},[2]={key='nauvis',position={x=60,y=-150}},[3]={key='vulcanus',position={x=0,y=0}}}
local A=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return storage end,
  agents=function() return {{index=1,name='astra'},{index=2,name='sol'},{index=3,name='luna'}} end,
  who=function(p) return p.name end,
  place=function(index) return places[index] end,
  alert_reader=function(f) eq(f,force); return reader end}
local function agent(name,s) return {name=name,force=force,surface=s} end
local astra,sol,luna=agent('astra',nauvis),agent('sol',nauvis),agent('luna',vulcanus)
local ha,hs,hl={},{},{}
local function has(lines,text) for _,l in ipairs(lines) do if l:find(text,1,true) then return l end end end

-- 1. Each group goes to whoever it concerns: a claim, the builder, else the nearest agent there.
local l=A.lines(sol,hs)
eq(#l,1); eq(l[1],'12 gun-turret out of ammo near (67,-170): (61,-170), (62,-170), (63,-170), (64,-170), (65,-170), (66,-170), (67,-170), (68,-170), +4 more; rearm {alert: "no_ammo|nauvis|0,-3"}')
l=A.lines(luna,hl)
eq(#l,3,table.concat(l,' | '))
assert(has(l,'8 assembling-machine-2 no power near (125,40) on nauvis; fh call power'),table.concat(l,' | '))
assert(has(l,'2 assembling-machine-2 not connected to power (no pole reaches them) near (132,44) on nauvis'))
assert(has(l,'1 flamethrower-turret out of flamer oil near (10,10); fh call flamers'),'the nearest on Vulcanus')
l=A.lines(astra,ha)
eq(#l,2,table.concat(l,' | '))
-- (d17 batch12 C1: the exact positions and the alert's key for refuel)
assert(has(l,'5 stone-furnace out of fuel near (6,2): stone-furnace ') and has(l,'; refuel {alert: "no_fuel|nauvis|'),table.concat(l,' | '))
assert(has(l,'2 (1 entity-ghost, 1 transport-belt) ghosts waiting for materials (no robot can bring them) near (-41,11)'),table.concat(l,' | '))
assert(not has(l,'Sunward') and not has(l,'entity_destroyed'))

-- 2. One digest per 150 s, and nothing repeated until it changes.
for i=13,16 do turrets[i]=ent('nauvis','gun-turret','ammo-turret',60+i,-170) end
game.tick=game.tick+60*60
eq(#A.lines(sol,hs),0,'within 150 s')
game.tick=game.tick+91*60
l=A.lines(sol,hs); eq(#l,1); eq(l[1],'16 gun-turret out of ammo near (69,-170) (was 12): (61,-170), (62,-170), (63,-170), (64,-170), (65,-170), (66,-170), (67,-170), (68,-170), +8 more; rearm {alert: "no_ammo|nauvis|0,-3"}')
game.tick=game.tick+151*60
eq(#A.lines(sol,hs),0,'unchanged: not told again')
eq(#A.lines(luna,hl),0); eq(#A.lines(astra,ha),0)
-- Rearmed, then empty again: news again.
for _,t in ipairs(turrets) do t.rounds=20 end
game.tick=game.tick+151*60
eq(#A.lines(sol,hs),0); eq(next(hs.push.told),nil,'gone: forgotten')
for i=1,4 do turrets[i].rounds=0 end
game.tick=game.tick+151*60
l=A.lines(sol,hs); eq(l[1],'4 gun-turret out of ammo near (63,-170): (61,-170), (62,-170), (63,-170), (64,-170); rearm {alert: "no_ammo|nauvis|0,-3"}')

-- 3. The game_alerts read: every group, worst first, with who it goes to.
local r=A.read(astra,{})
eq(#r.groups,6); eq(r.groups[1].kind,'no_power'); eq(r.groups[1].count,8); eq(r.groups[1].to[1],'luna (built)')
local by={}
for _,g in ipairs(r.groups) do by[g.kind]=g end
eq(by.no_ammo.to[1],'sol (claim)'); eq(by.no_fuel.to[1],'astra (nearest)'); eq(by.flamer_dry.surface,'vulcanus')
eq(#A.read(astra,{kind='no_fuel'}).groups,1); eq(#A.read(astra,{surface='vulcanus'}).groups,1)
-- The scan is kept 30 s: a change shows at the next scan.
ents.nauvis={}; ents.vulcanus={}; reader.get_alerts=function() return {} end
eq(#A.read(astra,{}).groups,6,'kept')
game.tick=game.tick+1800
local none=A.read(astra,{}); eq(#none.groups,0); eq(none.note,'no alerts or warnings')

-- 4. Network groups (networks.lua): their own line and level, the same routing, digest and new-or-worse rule.
local net={}
local B=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return storage end,
  agents=function() return {{index=1,name='astra'},{index=2,name='sol'},{index=3,name='luna'}} end,
  who=function(p) return p.name end,
  place=function(index) return places[index] end,
  network_groups=function(f) eq(f,force); return net end}
local power={key='power_high|nauvis|7',kind='power_high',surface='nauvis',n=85,unit='%',names={},by={},at={},center={x=70,y=-160},
  line='electric #7 draw at or above 85% of capacity for 2 min: 18.9 MW of 22.1 MW now; 0 machines on low power'}
net[1]=power
game.tick=game.tick+1800
local hb={}
l=B.lines(sol,hb)
eq(#l,1); eq(l[1],'electric #7 draw at or above 85% of capacity for 2 min: 18.9 MW of 22.1 MW now; 0 machines on low power','in sol\'s claim')
game.tick=game.tick+151*60
eq(#B.lines(sol,hb),0,'the same level: not told again')
power.n=95; power.line='electric #7 draw at or above 85% of capacity for 2 min: 21.0 MW of 22.1 MW now; 4 machines on low power'
game.tick=game.tick+151*60
l=B.lines(sol,hb); eq(l[1],'electric #7 draw at or above 85% of capacity for 2 min: 21.0 MW of 22.1 MW now; 4 machines on low power (was 85%)')
-- Another surface's group says where; the read filters by kind.
net[2]={key='robots_busy|vulcanus|3',kind='robots_busy',surface='vulcanus',n=1,names={},by={},at={},center={x=0,y=0},
  line='logistic #3: no idle logistic robot for 10 min (40 robots; 2 requests unfilled 60+ s)'}
game.tick=game.tick+1800
local rows=B.read(sol,{kind='robots_busy'}).groups
eq(#rows,1); eq(rows[1].line,'logistic #3: no idle logistic robot for 10 min (40 robots; 2 requests unfilled 60+ s) on vulcanus'); eq(rows[1].to[1],'luna (nearest)')
-- boiler_fuel (Haiku, shift09: 10 minutes was too late): told at 20 min, again at 10 and 5 or when more boilers drop
-- under 20; the same step and count is not told again; what it was comes from its now_text.
local function fuel(level,count,low)
  return {key='boiler_fuel|nauvis|7',kind='boiler_fuel',surface='nauvis',n=count,rank=level*10000+count,names={boiler=count},by={},at={},
    center={x=70,y=-160},now_text=string.format('%d under 20 min, lowest %d min',count,low),line=string.format('%d boilers ... lowest %d min',count,low)}
end
net={fuel(1,3,17)}; local hf={}
game.tick=game.tick+1800
l=B.lines(sol,hf); eq(l[1],'3 boilers ... lowest 17 min')
game.tick=game.tick+151*60; net={fuel(1,3,15)}
eq(#B.lines(sol,hf),0,'same step, same count: not told again')
game.tick=game.tick+151*60; net={fuel(1,4,14)}
l=B.lines(sol,hf); eq(l[1],'4 boilers ... lowest 14 min (was 3 under 20 min, lowest 17 min)')
game.tick=game.tick+151*60; net={fuel(2,4,9)}
l=B.lines(sol,hf); eq(l[1],'4 boilers ... lowest 9 min (was 4 under 20 min, lowest 14 min)')
game.tick=game.tick+151*60; net={fuel(3,4,4)}
l=B.lines(sol,hf); eq(l[1],'4 boilers ... lowest 4 min (was 4 under 20 min, lowest 9 min)')
-- Fed: better is remembered, and a fall from there is news again.
game.tick=game.tick+151*60; net={fuel(1,2,18)}
eq(#B.lines(sol,hf),0)
game.tick=game.tick+151*60; net={fuel(2,2,8)}
l=B.lines(sol,hf); eq(l[1],'2 boilers ... lowest 8 min (was 2 under 20 min, lowest 18 min)')
net={power}; game.tick=game.tick+1800  -- past the 30 s the scan is kept
-- What is open in an agent's own claims, for its review (selfview.lua): claim groups only, no hints.
local mine=B.claim_lines(sol)
eq(#mine,1); eq(mine[1],power.line)
eq(#B.claim_lines(luna),0,'the nearest agent has no claim there')
eq(A.text({kind='no_ammo',n=3,names={['gun-turret']=3},center={x=1,y=2},surface='nauvis'},'nauvis',nil,true),'3 gun-turret out of ammo near (1,2)')

-- 5. The background read (task-statuscost, 01:15 on world n: pushalerts.lines up to 150 ms when a reply ran the whole
-- read; operator 04:00: a whole-surface find a stage burst to 138 ms in a game second): a stage per planet walked a band
-- of chunks a step (walk.lua) with every type in one find, then the game's alerts, the network groups, the merge; one
-- step every few ticks (4 before any read, then spread over 80% of the 30 s by the last read's steps); its state in
-- storage; replies read the last finished one and never read the world themselves.
local st5={board={items={}}}
local netcalls=0
local C=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
  state=function() return st5 end,
  agents=function() return {{index=1,name='astra'},{index=2,name='sol'},{index=3,name='luna'}} end,
  who=function(p) return p.name end,
  place=function(index) return places[index] end,
  network_groups=function() netcalls=netcalls+1; return {} end}
ents.nauvis={}; ents.vulcanus={}
for i=1,3 do ent('nauvis','stone-furnace','furnace',i*2,2,{status=3}) end
for i=1,2 do ent('vulcanus','gun-turret','ammo-turret',i,1) end
force.players={{}}; game.forces={player=force}
-- (the walk's pace alone here: d22_batch96 tests the pace by each step's cost)
C.SECOND_COST=math.huge
local function run(n) for _=1,n do game.tick=game.tick+1; finds={}; C.tick(game.tick); assert(#finds<=1,'at most one find a tick') end end
run(1); eq(#finds,0,'the job starts'); assert(st5.push_jobs.player)
local stages=#st5.push_jobs.player.stages
eq(stages,2+4,'each of 2 planets, then alerts, networks, merge, drill sites')
local function pass()
  local ticks,steps=0,0
  repeat
    game.tick=game.tick+1; finds={}; C.tick(game.tick); ticks=ticks+1
    assert(#finds<=1,'at most one find a tick')
    for _,t in ipairs(finds) do eq(type(t),'table','every type in one find') end
  until not st5.push_jobs.player or ticks>2000
  return ticks
end
wholes=0
local ticks=pass()
eq(st5.push_jobs.player,nil,'done'); eq(netcalls,1)
local steps=st5.push_steps.player
eq(ticks,4*steps,'a step every 4 ticks before any read')
eq(wholes,2,'no box known yet: one whole-surface find per planet')
local done=C.read(astra,{}).groups
eq(#done,2); local kinds={}; for _,g in ipairs(done) do kinds[g.kind]=g.count end
eq(kinds.no_fuel,3); eq(kinds.no_ammo,2)
-- The next read: bands of chunks only, its steps spread over 80% of the 30 s.
game.tick=game.tick+1800; wholes=0
run(1); local every=st5.push_jobs.player.every
eq(every,math.floor(1800*0.8/steps))
ticks=pass()
eq(wholes,0,'bands only once the box is known')
assert(ticks<=1800,'within the 30 s: '..ticks)
-- (this read took more steps than the first, so past 80% of the 30 s it went on every 4 ticks; the next is paced by it)
game.tick=game.tick+1800
run(1); every=st5.push_jobs.player.every
eq(every,math.floor(1800*0.8/st5.push_steps.player))
ticks=pass()
eq(ticks,every*st5.push_steps.player,'spread evenly')
done=C.read(astra,{}).groups
kinds={}; for _,g in ipairs(done) do kinds[g.kind]=g.count end
eq(kinds.no_fuel,3); eq(kinds.no_ammo,2)
-- A reply later than 30 s reads the last finished read and nothing else; the job reads anew in the background.
game.tick=game.tick+5000; finds={}
eq(#C.read(astra,{}).groups,2); eq(#finds,0,'no read in the reply')
run(1); assert(st5.push_jobs.player,'a new job')
-- (d20 batch55 P1, viewer Aurora) A job that fails: the last read keeps the tick it was scanned at, the reply says its
-- age and the failure, and the next job starts SCAN_TICKS after the failure.
local held=st5.push_alerts.player
local scanned_at=held.tick
find_fail='chunk find broke'
repeat game.tick=game.tick+1; C.tick(game.tick) until not st5.push_jobs.player
eq(st5.push_errors.count,1); eq(held.tick,scanned_at,'the read keeps its tick'); eq(st5.push_alerts.player,held)
local failed_at=game.tick
find_fail=nil
game.tick=game.tick+600
local told=C.read(astra,{})
eq(told.scanned,string.format('%ds ago',math.floor((game.tick-scanned_at)/60)))
eq(told.refresh_failed,string.format('the last refresh of the alert scan failed 10s ago (%s); the alert scan is from %ds ago',held.refresh_failed.error,
  math.floor((game.tick-scanned_at)/60)))
assert(held.refresh_failed.error:find('chunk find broke',1,true))
game.tick=failed_at+1799; C.tick(game.tick); eq(st5.push_jobs.player,nil,'no job within SCAN_TICKS of the failure')
game.tick=game.tick+1; C.tick(game.tick); assert(st5.push_jobs.player,'the next job')
-- A job finishing after a newer read (a force's first read, made in a reply) never replaces it.
local job_start=st5.push_jobs.player.start
run(8)
st5.push_alerts.player=nil
local first=C.read(astra,{})
local newer=st5.push_alerts.player
eq(newer.tick,game.tick); eq(first.refresh_failed,nil)
repeat game.tick=game.tick+1; C.tick(game.tick) until not st5.push_jobs.player
assert(job_start<newer.tick)
eq(st5.push_alerts.player,newer,'the job\'s older read was dropped')
force.players={}; game.forces=nil

-- 6. Lost sources (Haiku, 04:52: "a chest gone alert when a feed chest disappears, since an inserter with no source
-- fails silently"): an inserter that had a pickup target and has none now, or whose drop target is gone, grouped by
-- area and by what it feeds, with the inserter, what it read and what it puts into; told when new or more.
do
  local st6={board={items={}}}
  local T=dofile('mod/agent-harness_0.1.0/targets.lua'){}
  local D=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st6 end,
    agents=function() return {{index=1,name='astra'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=50,y=10}} end,
    targets=T}
  ents.nauvis={}; ents.vulcanus={}
  local function thing(name,type,x,y) return {valid=true,name=name,type=type,position={x=x,y=y}} end
  local chest=thing('wooden-chest','container',41.5,13.5)
  local boiler,furnace,lab=thing('boiler','boiler',60,16.5),thing('stone-furnace','furnace',44,16),thing('lab','lab',70.5,20.5)
  local u=0
  local function inserter(name,x,y,pick,drop)
    u=u+1
    return ent('nauvis',name,'inserter',x,y,{unit_number=700+u,pickup_target=pick,drop_target=drop})
  end
  local a=inserter('burner-inserter',60.5,14.5,chest,boiler)
  local b=inserter('inserter',44.5,14.5,chest,furnace)
  local c=inserter('inserter',30.5,30.5,nil,boiler)          -- takes from the ground: never had a pickup target
  local d=inserter('fast-inserter',70.5,18.5,chest,lab)
  local function read() game.tick=game.tick+1800; return D.read(astra,{}).groups end
  local function lost(groups) local out={} for _,g in ipairs(groups) do if g.kind:find('^lost_') then out[g.kind]=g end end return out end
  local ha6={}
  eq(next(lost(read())),nil,'the first read only remembers')
  -- The chest is gone: a and b lost their source (by what they feed); c never had one.
  chest.valid=false; a.pickup_target=nil; b.pickup_target=nil; d.pickup_target=nil
  local g=lost(read())
  eq(g['lost_source.boiler'].count,1); eq(g['lost_source.furnace'].count,1); eq(g['lost_source.lab'].count,1)
  eq(g['lost_source.boiler'].line,'1 inserter feeding boiler lost its pickup target near (60.5,14.5): burner-inserter (60.5,14.5) read wooden-chest (41.5,13.5), puts into boiler (60,16.5)')
  eq(g['lost_source.boiler'].lost[1],'burner-inserter (60.5,14.5) read wooden-chest (41.5,13.5), puts into boiler (60,16.5)')
  eq(#D.read(astra,{kind='lost_source'}).groups,3,'kind lost_source: every fed kind')
  local told=D.lines(astra,ha6)
  assert(has(told,'1 inserter feeding furnace lost its pickup target near (44.5,14.5): inserter (44.5,14.5) read wooden-chest (41.5,13.5), puts into stone-furnace (44,16)'),table.concat(told,' | '))
  -- Still lost a read later: kept with what it read then; not told again.
  g=lost(read())
  eq(g['lost_source.boiler'].count,1); assert(g['lost_source.boiler'].line:find('read wooden-chest (41.5,13.5)',1,true))
  game.tick=game.tick+9000
  eq(#D.lines(astra,ha6),0,'not new, not worse')
  -- The lab is gone too: d lost both; still under the lab it fed.
  lab.valid=false; d.drop_target=nil
  g=lost(read())
  eq(g['lost_source.lab'].lost[1],'fast-inserter (70.5,18.5) read wooden-chest (41.5,13.5), put into lab (70.5,20.5) (gone too)')
  -- A new chest: a reads it again and leaves the group; b's furnace goes: a drop target lost.
  local chest2=thing('iron-chest','container',41.5,13.5)
  a.pickup_target=chest2; b.pickup_target=chest2; furnace.valid=false; b.drop_target=nil
  g=lost(read())
  eq(g['lost_source.boiler'],nil,'a reads again')
  -- (d22 batch110 BT1: each inserter's record is rewritten in place) what it lost is cleared, what it reads now kept
  local ra=st6.push_inserters.player.units[701]
  eq(ra.lost_p,nil); eq(ra.lost_d,nil); eq(ra.ldt,nil); eq(ra.p,'iron-chest (41.5,13.5)'); eq(ra.d,'boiler (60,16.5)'); eq(ra.dt,'boiler')
  eq(ra.g,st6.push_inserters.player.gen)
  local rb=st6.push_inserters.player.units[702]
  eq(rb.d,nil); eq(rb.dt,nil); eq(rb.lost_d,'stone-furnace (44,16)'); eq(rb.ldt,'furnace'); eq(rb.lost_p,nil)
  eq(g['lost_target.furnace'].line,'1 inserter feeding furnace lost its drop target near (44.5,14.5): inserter (44.5,14.5) put into stone-furnace (44,16), reads iron-chest (41.5,13.5)')
  -- An inserter that is gone is forgotten.
  b.valid=false
  g=lost(read())
  eq(g['lost_target.furnace'],nil); eq(st6.push_inserters.player.units[702],nil)
  -- A chest upgraded in place (Astra, 07:26: a wooden chest fast-replaced by a requester; the inserter, holding cable,
  -- worked from it while the engine's pickup target was still empty): what stands on the pickup point is its target
  -- and the one remembered from now on; not lost.
  local wood=thing('wooden-chest','container',-68.5,-0.5)
  local asm=thing('assembling-machine-2','assembling-machine',-68.5,-3.5)
  local f=inserter('fast-inserter',-68.5,-1.5,wood,asm)
  f.pickup_position={x=-68.5,y=-0.5}; f.drop_position={x=-68.5,y=-2.5}
  read()
  eq(st6.push_inserters.player.units[f.unit_number].p,'wooden-chest (-68.5,-0.5)')
  wood.valid=false; f.pickup_target=nil
  local req=thing('requester-chest','logistic-container',-68.5,-0.5)
  standing[#standing+1]=req
  g=lost(read())
  eq(g['lost_source.assembler'],nil,'the requester on its pickup point is its source')
  eq(st6.push_inserters.player.units[f.unit_number].p,'requester-chest (-68.5,-0.5)','the remembered source is the new chest')
  -- The engine links it later: still the requester, still not lost.
  f.pickup_target=req
  g=lost(read())
  eq(g['lost_source.assembler'],nil)
  -- Nothing on the point (the requester mined too): lost, reading the requester.
  req.valid=false; f.pickup_target=nil
  g=lost(read())
  eq(g['lost_source.assembler'].lost[1],'fast-inserter (-68.5,-1.5) read requester-chest (-68.5,-0.5), puts into assembling-machine-2 (-68.5,-3.5)')
  ents.nauvis={}
end
-- 7. Turrets rebuilt empty (Astra, shift10: 15+ gun turrets rebuilt by robots with no ammo and destroyed again): a
-- turret first seen after a whole read was built since; empty 60 s or more after it was first seen, it leaves no_ammo
-- for a rebuilt_empty group that names it with its ammo request; armed, it is like any other turret.
do
  local st7={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st7 end,
    agents=function() return {{index=1,name='astra'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=200,y=10}} end}
  ents.nauvis={}; ents.vulcanus={}
  ent('nauvis','gun-turret','ammo-turret',200.5,10.5,{unit_number=900})   -- empty, there before the first read
  local function read() game.tick=game.tick+1800; local out={} for _,g in ipairs(R.read(astra,{}).groups) do out[g.kind]=g end return out end
  local g=read()
  eq(g.no_ammo.count,1,'the first read: every turret was there before it'); eq(g.rebuilt_empty,nil)
  local a=ent('nauvis','gun-turret','ammo-turret',210,10,{unit_number=901,
    item_request_proxy={item_requests={{name='firearm-magazine',count=10,quality='normal'}}}})
  local b=ent('nauvis','gun-turret','ammo-turret',214,10,{unit_number=902})
  g=read(); eq(g.no_ammo.count,3,'first seen empty: out of ammo'); eq(g.rebuilt_empty,nil)
  g=read(); eq(g.no_ammo.count,3,'30 s on: still out of ammo')
  g=read()
  eq(g.no_ammo.count,1,'60 s on: the old one only'); eq(g.rebuilt_empty.count,2)
  eq(g.rebuilt_empty.line,'2 gun-turret rebuilt empty near (212,10): no ammo since built, 60+ s: gun-turret (210,10) requests 10 firearm-magazine; gun-turret (214,10) no ammo request; rearm {alert: "rebuilt_empty|nauvis|3,0"}')
  eq(#R.read(astra,{kind='rebuilt_empty'}).groups,1)
  local told=R.lines(astra,{})
  assert(has(told,'2 gun-turret rebuilt empty near (212,10)'),table.concat(told,' | '))
  -- Armed, it leaves; gone, it is forgotten; a turret armed when first seen is never named.
  a.rounds=10; b.valid=false
  ent('nauvis','gun-turret','ammo-turret',220,10,{unit_number=903,rounds=5})
  g=read(); eq(g.rebuilt_empty,nil); eq(g.no_ammo.count,1); eq(st7.push_turrets.player.units[902],nil)
  a.rounds=0
  g=read(); g=read(); g=read()
  eq(g.rebuilt_empty,nil,'armed once: an empty turret like any other'); eq(g.no_ammo.count,2)
  -- A turret that died and was rebuilt from its ghost has its old unit number again (2.0): the death marks it, so
  -- rebuilt between two reads it is still named.
  local c=ent('nauvis','gun-turret','ammo-turret',240,10,{unit_number=905,rounds=20,force=force})
  g=read(); eq(st7.push_turrets.player.units[905].new,nil,'an armed turret like any other')
  c.valid=false; R.turret_died(c)
  local c2=ent('nauvis','gun-turret','ammo-turret',240,10,{unit_number=905})
  g=read(); g=read(); g=read()
  eq(g.rebuilt_empty.count,1); eq(g.rebuilt_empty.lost[1],'gun-turret (240,10) no ammo request')
  c2.valid=false
  -- The background read (the banded walk) keeps the same memory.
  local st8={board={items={}}}
  local BG=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st8 end,
    agents=function() return {{index=1,name='astra'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=200,y=10}} end,
    network_groups=function() return {} end}
  force.players={{}}; game.forces={player=force}
  local function bgpass()
    game.tick=game.tick+1800
    local n=0
    repeat game.tick=game.tick+1; finds={}; BG.tick(game.tick); n=n+1 until (st8.push_jobs and not st8.push_jobs.player and n>1) or n>5000
    assert(n<=5000,'a pass ends')
    local out={} for _,x in ipairs(BG.read(astra,{}).groups) do out[x.kind]=x end return out
  end
  g=bgpass(); eq(g.rebuilt_empty,nil); eq(g.no_ammo.count,2)
  ent('nauvis','gun-turret','ammo-turret',230,10,{unit_number=904})
  g=bgpass(); eq(g.rebuilt_empty,nil); eq(g.no_ammo.count,3)
  g=bgpass(); g=bgpass()
  eq(g.rebuilt_empty.count,1); eq(g.rebuilt_empty.lost[1],'gun-turret (230,10) no ammo request')
  -- A read under way when the memory first exists (a deploy mid-read) saw part of the map before it: it marks nothing
  -- built since; the next whole read does.
  local st9={board={items={}}}
  local B2=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st9 end,
    agents=function() return {{index=1,name='astra'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=200,y=10}} end,
    network_groups=function() return {} end}
  game.tick=game.tick+1; B2.tick(game.tick)
  assert(st9.push_jobs.player,'a read under way'); st9.push_jobs.player.tgen=nil; st9.push_turrets=nil
  local n=0
  repeat game.tick=game.tick+1; B2.tick(game.tick); n=n+1 until not st9.push_jobs.player or n>5000
  eq(st9.push_turrets.player.ready,nil,'begun before its memory: not a whole read for it')
  game.tick=game.tick+1800; n=0
  repeat game.tick=game.tick+1; B2.tick(game.tick); n=n+1 until (not st9.push_jobs.player and n>1) or n>5000
  eq(st9.push_turrets.player.ready,true)
  force.players={}; game.forces=nil; ents.nauvis={}
end
-- 7b. The networks stage in steps (operator 18:12: networks.alert_groups 58-60 ms in one tick on world n): the api's
-- cursor stepped NET_SLICE networks a step on ticks of their own; each step a profile part by kind (api.timed).
do
  local st11={board={items={}}}
  local calls,labels,ticks_seen=0,{},{}
  local NS=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st11 end,
    agents=function() return {{index=1,name='astra'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=200,y=10}} end,
    network_cursor=function(f) return {left=3} end,
    network_step=function(cur,max)
      calls=calls+1; eq(max,2); ticks_seen[game.tick]=true
      cur.left=cur.left-1
      if cur.left>0 then return false end
      return true,{{key='power_high|nauvis|7',kind='power_high',surface='nauvis',n=90,names={},by={},at={},center={x=0,y=0},line='electric #7'}}
    end,
    timed=function(label,fn,...) labels[label]=(labels[label] or 0)+1; return fn(...) end}
  force.players={{}}; game.forces={player=force}
  game.tick=game.tick+1; NS.tick(game.tick)
  local n=0
  repeat game.tick=game.tick+1; NS.tick(game.tick); n=n+1 until not st11.push_jobs.player or n>5000
  eq(calls,3,'the networks stage in three steps')
  local distinct=0; for _ in pairs(ticks_seen) do distinct=distinct+1 end
  eq(distinct,3,'each on a tick of its own')
  eq(labels['pushalerts.networks'],3); eq(labels['pushalerts.alerts'],1); eq(labels['pushalerts.merge'],1)
  assert(labels['pushalerts.band'],'the bands timed')
  local keys={}; for _,g in ipairs(st11.push_alerts.player.groups) do keys[g.key]=true end
  assert(keys['power_high|nauvis|7'],'the stepped groups are in the read')
  force.players={}; game.forces=nil
end
-- 8. A claim routes the groups on its own surface only (Sol 07:52: Astra's Nauvis claim #212 labelled Gleba furnaces
-- at (62,22)).
do
  local st10={board={items={{kind='claim',status='claimed',owner='luna',id=9,surface='vulcanus',area={left_top={x=-50,y=-50},right_bottom={x=50,y=50}}}}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st10 end,
    agents=function() return {{index=1,name='astra'},{index=3,name='luna'}} end,
    who=function(p) return p.name end,
    place=function(index) return places[index] end}
  ents.nauvis={}; ents.vulcanus={}
  for i=1,3 do ent('nauvis','stone-furnace','furnace',i*2,2,{status=3}) end
  ent('vulcanus','stone-furnace','furnace',4,2,{status=3})
  game.tick=game.tick+1800
  local by={}
  for _,g in ipairs(R.read(astra,{}).groups) do by[g.surface]=g end
  eq(by.nauvis.to[1],'astra (nearest)','a vulcanus claim does not cover nauvis'); eq(by.vulcanus.to[1],'luna (claim)')
  st10.board.items[1].surface='nauvis'; game.tick=game.tick+1800
  by={}
  for _,g in ipairs(R.read(astra,{}).groups) do by[g.surface]=g end
  eq(by.nauvis.to[1],'luna (claim)'); eq(by.vulcanus.to[1],'luna (nearest)')
  ents.nauvis={}; ents.vulcanus={}
end
-- 9. A turret group is read again when it is about to be shown (Haiku, shift12 15:20: two empty-ammo alerts sent it to
-- guns that were already full): only turrets still empty count; refilled, the group is not shown, in the team block or
-- the read, and when they run dry again it is news. The background job keeps its read until the next one is done.
do
  local st11={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){
    state=function() return st11 end,
    agents=function() return {{index=2,name='sol'}} end,
    who=function(p) return p.name end,
    place=function(index) return {key='nauvis',position={x=300,y=300}} end}
  ents.nauvis={}; ents.vulcanus={}
  local guns={}
  for i=1,3 do guns[i]=ent('nauvis','gun-turret','ammo-turret',300+i*2,300,{unit_number=700+i}) end
  local h={}
  game.tick=game.tick+1800
  local l=R.lines(sol,h); eq(#l,1); eq(l[1],'3 gun-turret out of ammo near (304,300): (302,300), (304,300), (306,300); rearm {alert: "no_ammo|nauvis|4,4"}')
  st11.push_bg=true   -- that read stays the current one
  -- Two refilled since the read: the read counts the one left; one built since is not in this read.
  ent('nauvis','gun-turret','ammo-turret',320,300,{unit_number=799})
  guns[1].rounds=10; guns[2].rounds=10
  game.tick=game.tick+151*60
  local r=R.read(sol,{kind='no_ammo'}).groups
  eq(#r,1); eq(r[1].count,1); eq(r[1].at[1].x,306); eq(r[1].line,'1 gun-turret out of ammo near (306,300); rearm')
  eq(#R.lines(sol,h),0,'fewer than told: not news'); eq(h.push.told[next(h.push.told)],1)
  -- All refilled: nothing shown, and forgotten as told.
  guns[3].rounds=10
  eq(#R.read(sol,{kind='no_ammo'}).groups,0,'the read drops it')
  game.tick=game.tick+151*60
  eq(#R.lines(sol,h),0); eq(next(h.push.told),nil,'refilled: told forgotten')
  -- Dry again (the same read): news again.
  guns[1].rounds=0
  game.tick=game.tick+151*60
  l=R.lines(sol,h); eq(#l,1); eq(l[1],'1 gun-turret out of ammo near (302,300); rearm')
  ents.nauvis={}
end
-- Spoiling fuel (Sol, shift13 16:50: biochambers starved with 20 nutrients loaded, the batch rotting within seconds; on
-- a copy of world n most held nutrients 85-99% spoiled): an out-of-fuel group says how many burners of its names
-- around it burn spoiling fuel, how many within 60 s, and the first to spoil, worked out when shown. Heating towers
-- (type reactor) are read too.
do
  local st={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=50,y=40}} end,
    first_spoil=function(inv) return inv.spoil_tick, inv.item end}
  ents.nauvis={}; ents.vulcanus={}
  local function fuel(ticks) return {burner={inventory=ticks and {spoil_tick=game.tick+ticks, item='nutrients'} or {}}} end
  ent('nauvis','biochamber','assembling-machine',49.5,44.5,{status=3,burner={inventory={}}})
  ent('nauvis','biochamber','assembling-machine',43.5,34.5,fuel(240))
  ent('nauvis','biochamber','assembling-machine',55.5,26.5,fuel(1800))
  ent('nauvis','biochamber','assembling-machine',60.5,54.5,fuel(9000))
  ent('nauvis','heating-tower','reactor',46.5,48.5,{status=3,burner={inventory={}}})
  local r=R.read(sol,{kind='no_fuel'}).groups
  eq(#r,1)
  eq(r[1].line,'2 (1 biochamber, 1 heating-tower) out of fuel near (48,47): biochamber (49.5,44.5), heating-tower (46.5,48.5); refuel {alert: "no_fuel|nauvis|0,0"}; 3 biochamber around it burn spoiling fuel, 2 of them within 60s; '
    ..'the first: nutrients spoils in 4s at (43.5,34.5)')
  -- Heating towers (Gemini, d15 07:54): empty and under 500 C, their own group with the temperature; hotter, not said.
  -- batch27 A4 (Astra board #975): the threshold is the heat network's: with a heat exchanger on it, its working
  -- temperature from the prototype (500 C); heating only, 30 C, by the coldest part and how fast it cools.
  local function exchanger(x,y) return {valid=true,unit_number=math.floor(x*1000+y),name='heat-exchanger',type='boiler',position={x=x,y=y},temperature=480,
    prototype={heat_energy_source_prototype={min_working_temperature=500}}} end
  local t1=ent('nauvis','heating-tower','reactor',146.5,48.5,{status=3,temperature=320,burner={inventory={is_empty=function() return true end},remaining_burning_fuel=0}})
  t1.unit_number=901; t1.heat_neighbours={exchanger(148.5,48.5)}
  local t2=ent('nauvis','heating-tower','reactor',246.5,48.5,{status=3,temperature=640,burner={inventory={is_empty=function() return true end},remaining_burning_fuel=0}})
  t2.unit_number=902; t2.heat_neighbours={exchanger(248.5,48.5)}
  -- heating only at 499 C, its coldest pipe 493 C: not said; cooling fast enough to reach 30 C within 10 min: said
  local pipe={valid=true,unit_number=904,name='heat-pipe',type='heat-pipe',position={x=348.5,y=48.5},temperature=493}
  local t3=ent('nauvis','heating-tower','reactor',346.5,48.5,{status=3,temperature=499,burner={inventory={is_empty=function() return true end},remaining_burning_fuel=0}})
  t3.unit_number=903; t3.heat_neighbours={pipe}
  game.tick=game.tick+600
  eq(R.read(sol,{kind='no_fuel'}).groups[1].line:match('the first: .*$'),'the first: nutrients spoiled at (43.5,34.5)', 'worked out when shown')
  game.tick=game.tick+1801
  local h=R.read(sol,{kind='heat_no_fuel'}).groups
  eq(#h,1)
  eq(h[1].line,'1 heating-tower out of fuel near (146.5,48.5): heating-tower (146.5,48.5): 320 C, fuel slot empty; its heat network feeds 1 heat exchanger, which work at 500 C and more; refuel {alert: "heat_no_fuel|nauvis|2,0"}')
  -- the next read: the pipe cooled 2 C in 30 s (4 C a minute, about 116 min to 30 C): still not said
  pipe.temperature=491; game.tick=game.tick+1801
  eq(#R.read(sol,{kind='heat_no_fuel'}).groups,1)
  -- then 300 C in 30 s: under a minute to 30 C, said with its coldest part
  pipe.temperature=191; game.tick=game.tick+1801
  h=R.read(sol,{kind='heat_no_fuel'}).groups
  eq(#h,2)
  local line=h[1].line:find('346.5',1,true) and h[1].line or h[2].line
  assert(line:find('heating-tower (346.5,48.5): 499 C, fuel slot empty; its heat network (2 parts, no heat exchanger) coldest 191 C at heat-pipe (348.5,48.5), cooling 599.7 C a minute: about 0 min to 30 C; under 30 C a heater warms nothing',1,true),line)
  ents.nauvis={}
end
-- A burner its full burnt-result slot stopped (Sol, shift14 03:54: two agricultural science biochambers read working and
-- made nothing): a burnt_full group whatever the status reads, each with what fills that slot and its fuel slot.
do
  local st={board={items={}}}
  local stuck={}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=50,y=40}} end,
    burnt_stuck=function(e) return stuck[e] end}
  ents.nauvis={}; ents.vulcanus={}
  -- (biochambers burn nutrients: each has a burner; d22 batch110 BT1: only a burner is asked, as burnt.lua reads nil
  -- for an entity with none, so the electric assembler below is never asked)
  local a=ent('nauvis','biochamber','assembling-machine',45.5,72.5,{status=1,burner={}})
  local b=ent('nauvis','biochamber','assembling-machine',68.5,49.5,{status=1,burner={}})
  ent('nauvis','biochamber','assembling-machine',49.5,44.5,{status=1,burner={}})
  local electric=ent('nauvis','assembling-machine-2','assembling-machine',30.5,30.5,{status=0})
  stuck[a]={burnt='spoilage*200',fuel='spoilage*3',foreign='spoilage',burns='nutrients'}
  stuck[b]={burnt='spoilage*200',fuel='',burns='nutrients'}
  stuck[electric]={burnt='never asked',fuel='',burns=''}
  local B=dofile('mod/agent-harness_0.1.0/burnt.lua'){}
  eq(B.stuck(electric),nil,'burnt.lua: no burner, not stuck')
  local r=R.read(sol,{kind='burnt_full'}).groups
  eq(#r,1); eq(r[1].count,2)
  eq(r[1].line,'2 biochamber stopped by a full burnt-result slot near (57,61): biochamber (45.5,72.5): burnt-result slot spoilage*200; fuel slot spoilage*3 '
    ..'(not a fuel it burns: it burns nutrients); biochamber (68.5,49.5): burnt-result slot spoilage*200; fuel slot empty')
  ents.nauvis={}
end
-- A sleep on chosen kinds (Luna, 19:50: low power, starvation in a claim): levels gives the groups of those kinds
-- (and their sub-kinds) addressed to you; starved the assemblers and furnaces lacking ingredients in your own claims.
do
  local st={board={items={{kind='claim',status='claimed',owner='luna',id=5,title='gears',area={left_top={x=0,y=0},right_bottom={x=20,y=20}}},
    {kind='claim',status='claimed',owner='sol',id=6,area={left_top={x=100,y=0},right_bottom={x=120,y=20}}}}}}
  local names={[0]='working',[1]='no_power',[7]='item_ingredient_shortage',[8]='no_ingredients'}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='sol'},{index=3,name='luna'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=50,y=10}} end, status_name=function(e) return names[e.status] end}
  ents.nauvis={}; ents.vulcanus={}
  local lu=agent('luna',nauvis)
  for i=1,3 do ent('nauvis','assembling-machine-2','assembling-machine',4+i*3,10,{status=1,unit_number=20+i}) end
  ent('nauvis','assembling-machine-2','assembling-machine',5.5,15.5,{status=7,unit_number=30})
  ent('nauvis','stone-furnace','furnace',105,5,{status=8,unit_number=31})
  game.tick=game.tick+1800
  local lv=R.levels(lu,{'no_power'}); local key,g=next(lv)
  assert(key and next(lv,key)==nil,'one group'); eq(g.level,3); assert(g.text:find('3 assembling-machine-2',1,true),g.text)
  eq(next(R.levels(lu,{'low_power'})),nil,'other kinds are left out')
  eq(next(R.levels(agent('sol',nauvis),{'no_power'})),nil,'addressed to luna (her claim)')
  local sv=R.starved(lu); eq(sv[30],'assembling-machine-2 (5.5,15.5) in your claim "gears" item ingredient shortage'); eq(sv[31],nil,"sol's claim")
  eq(next(sv,30),nil)
  eq(R.starved(agent('sol',nauvis))[31],'stone-furnace (105,5) in your claim "6" no ingredients')
  ents.nauvis={}
end
-- Spoilage in the input of a machine short of ingredients (Sol, 22:08; Gleba): a group naming each machine.
do
  defines.entity_status.item_ingredient_shortage=7; defines.inventory.assembling_machine_input=22
  local st={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=40,y=10}} end}
  ents.nauvis={}; ents.vulcanus={}
  local function input(stacks)
    local t={}
    for i,s in ipairs(stacks) do t[i]={valid_for_read=true,name=s[1],count=s[2]} end
    t.get_item_count=function(name) local n=0 for _,s in ipairs(stacks) do if s[1]==name then n=n+s[2] end end return n end
    return t
  end
  local recipe={ingredients={{name='yumako-mash',amount=15},{name='jelly',amount=12}}}
  local function chamber(x,status,stacks)
    local inv=input(stacks)
    return ent('nauvis','biochamber','assembling-machine',x,10,{status=status,get_recipe=function() return recipe end,
      get_inventory=function(id) eq(id,22); return inv end})
  end
  chamber(40.5,7,{{'spoilage',50},{'yumako-mash',3}})
  chamber(44.5,7,{{'yumako-mash',3}})
  chamber(48.5,0,{{'spoilage',20}})
  local g=R.read(sol,{kind='input_spoilage'}).groups
  eq(#g,1); eq(g[1].count,1)
  eq(g[1].line,'1 biochamber short of ingredients with spoilage in their input near (40.5,10): biochamber (40.5,10): input holds spoilage 50 in 1 of its 2 slots (its recipe does not take spoilage)')
  ents.nauvis={}
end
-- A boiler's feed chest in someone's claim (Haiku, shift17 10:50): the line names the claim, and that owner hears it.
do
  local st={board={items={{id=31,kind='claim',status='doing',owner='opus',title='fuel',surface='nauvis',area={left_top={x=-30,y=30},right_bottom={x=-20,y=40}}}}}}
  local P=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,agents=function() return {} end,who=function(p) return p.name end}
  local g={kind='feed_chest_low',surface='nauvis',center={x=-27,y=42},chest_at={x=-26.5,y=39.5},n=1,names={},by={},
    line='boiler (-27,42): its feed chest requester-chest (-26.5,39.5) holds no fuel, nothing put into it for 5+ min (feeder burner-inserter (-26.5,40.5))'}
  eq(P.text(g,'nauvis'),g.line.."; the chest is in opus's claim #31")
  eq(#P.claims_over(g,g.chest_at),1); eq(#P.claims_over(g,g.center),0)
  g.chest_at={x=0,y=0}; eq(P.text(g,'nauvis'),g.line)
end
-- A machine off by its own condition (d17 batch18 B2, Grok: the agricultural science biochamber stopped when network
-- bioflux fell under 200): a group with the condition and what its signal reads; a stock cap on its own product is not.
do
  defines.entity_status.disabled_by_control_behavior=55
  defines.wire_connector_id={circuit_red=1,circuit_green=2}
  prototypes={recipe={['agricultural-science-pack']={products={{name='agricultural-science-pack'}}}}}
  local st={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='grok'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=14,y=31}} end,
    condition_text=function(c) return c.first_signal.name..' '..c.comparator..' '..c.constant end,
    negative_note=function(item,n) return ' (network count '..n..': reserved beyond stock)' end}
  ents.nauvis={}; ents.vulcanus={}
  local bioflux=150
  local net={get_item_count=function(n) return n=='bioflux' and bioflux or 900 end}
  local function chamber(x,cond)
    return ent('nauvis','biochamber','assembling-machine',x,31.5,{status=55,last_user=user('grok'),
      get_recipe=function() return {name='agricultural-science-pack'} end,
      get_control_behavior=function() return {connect_to_logistic_network=true,logistic_condition=cond} end,
      surface={find_logistic_network_by_position=function() return net end}})
  end
  chamber(14.5,{first_signal={type='item',name='bioflux'},comparator='>',constant=200,fulfilled=false})
  chamber(20.5,{first_signal={type='item',name='agricultural-science-pack'},comparator='<',constant=500,fulfilled=false})
  local g=R.read(sol,{kind='off_by_condition'}).groups
  eq(#g,1); eq(g[1].count,1)
  eq(g[1].line,'1 biochamber stopped by its own circuit or logistic condition near (14.5,31.5): biochamber (14.5,31.5) (agricultural-science-pack): off by its logistic condition bioflux > 200 (bioflux 150 now)')
  eq(g[1].to[1],'grok (built)')
  -- (d17 batch21 A4, Grok) a network count under 0: said as the game's count, reserved beyond stock
  ents.nauvis={}; bioflux=-2
  chamber(14.5,{first_signal={type='item',name='bioflux'},comparator='>=',constant=0,fulfilled=false})
  local R2=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {board={items={}}} end,
    agents=function() return {{index=2,name='grok'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=14,y=31}} end,
    condition_text=function(c) return c.first_signal.name..' '..c.comparator..' '..c.constant end,
    negative_note=function(item,n) return ' (network count '..n..': reserved beyond stock)' end}
  g=R2.read(sol,{kind='off_by_condition'}).groups
  assert(g[1].line:find('off by its logistic condition bioflux >= 0 (network count -2: reserved beyond stock)',1,true),g[1].line)
  ents.nauvis={}
end
-- (d17 batch22 C1, Haiku) a hand-fed turret under 10 magazines: ammo_low, to its builder and agents within 64 tiles,
-- with the rearm line for exactly those; one an inserter feeds is not.
do
  ents.nauvis={}
  local low=ent('nauvis','gun-turret','ammo-turret',300,300,{rounds=4,last_user=user('haiku'),surface=nauvis,force=force})
  local fed=ent('nauvis','gun-turret','ammo-turret',306,300,{rounds=3,surface=nauvis,force=force})
  local base=low.get_inventory
  low.get_inventory=function(i) local inv=base(i); inv.get_contents=function() return {{name='firearm-magazine',count=4}} end; return inv end
  ent('nauvis','inserter','inserter',308,300,{drop_target=fed,force=force})
  local R3=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {board={items={}}} end,
    agents=function() return {{index=1,name='haiku'},{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function(i) return i==2 and {key='nauvis',position={x=320,y=300}} or {key='nauvis',position={x=0,y=0}} end}
  local g=R3.read(sol,{kind='ammo_low'}).groups
  eq(#g,1); eq(g[1].count,1)
  assert(has({g[1].line},'1 gun-turret hand-fed (no inserter drops into it) under 10 magazines near (300,300): gun-turret (300,300): firearm-magazine 4; rearm {alert: "ammo_low|nauvis|'),g[1].line)
  local to=table.concat(g[1].to,', ')
  assert(to:find('haiku (built)',1,true) and to:find('sol (near)',1,true),to)
  ents.nauvis={}
end
-- (d17 batch23 C1, Opus) an artillery turret with no shell for 5 min: artillery_empty, to its builder and the builder of
-- the inserter feeding it, with that inserter's requester chest (its request, what it holds, its network's shells); one
-- empty under 5 min is not said, and a refilled one drops out when shown.
do
  ents.nauvis={}
  local kept_inv,kept_lmi,kept_lm=defines.inventory,defines.logistic_member_index,defines.logistic_mode
  defines.inventory={turret_ammo=7,artillery_turret_ammo=9,chest=1}
  defines.logistic_member_index={logistic_container=0}
  local shells=0
  local piece=ent('nauvis','artillery-turret','artillery-turret',150.5,-134.5,{unit_number=501,last_user=user('opus'),surface=nauvis,force=force,
    get_inventory=function(i) eq(i,9); return {get_item_count=function() return shells end} end})
  local net={get_item_count=function(n) eq(n,'artillery-shell'); return 0 end}
  local chest=ent('nauvis','requester-chest','logistic-container',147.5,-134.5,{
    get_inventory=function(i) eq(i,1); return {get_item_count=function() return 0 end} end,
    get_logistic_point=function() return {filters={{name='artillery-shell',count=10}},logistic_network=net,targeted_items_deliver={}} end})
  ent('nauvis','inserter','inserter',148.5,-134.5,{drop_target=piece,pickup_target=chest,force=force,last_user=user('sol')})
  local stc={board={items={}}}
  local RA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return stc end,
    agents=function() return {{index=1,name='opus'},{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='nauvis',position={x=0,y=0}} end}
  eq(#RA.read(sol,{kind='artillery_empty'}).groups,0,'empty under 5 min')
  game.tick=game.tick+18000
  local g=RA.read(sol,{kind='artillery_empty'}).groups
  eq(#g,1)
  assert(g[1].line:find('1 artillery-turret with no shell for 5+ min near (150.5,-134.5): artillery-turret (150.5,-134.5): empty for 5 min; '
    ..'inserter (148.5,-134.5) takes from requester-chest (147.5,-134.5) (asks 10 artillery-shell, holds 0); its logistic network holds 0 artillery-shell (robots bringing 0)',1,true),g[1].line)
  local to=table.concat(g[1].to,', ')
  assert(to:find('opus (built)',1,true) and to:find('sol (built)',1,true),to)
  shells=5
  eq(#RA.read(sol,{kind='artillery_empty'}).groups,0,'refilled')
  defines.inventory,defines.logistic_member_index,defines.logistic_mode=kept_inv,kept_lmi,kept_lm
  ents.nauvis={}
end
-- Frozen (d17 frozen, Nick 17:18: "I see some frozen belts that have been frozen a long time on Aquilo"; on world n 70
-- belts and 8 pipes): on a planet whose entities require heating, our frozen entities by 64-tile area; pipes and
-- machines first with what they hold, the belts as one run, how long the oldest has been frozen (first seen frozen), and
-- the nearest heater with its temperature. A planet that does not freeze is not read for it.
do
  local st={board={items={}}}
  local R=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    agents=function() return {{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='aquilo',position={x=-20,y=-10}} end}
  ents.nauvis={}; ents.vulcanus={}; ents.aquilo={}
  local aquilo=surface('aquilo',4)
  aquilo.planet={prototype={entities_require_heating=true}}
  game.surfaces[#game.surfaces+1]=aquilo
  for i=1,3 do ent('aquilo','pipe','pipe',-20.5+i,-5.5,{frozen=true,unit_number=900+i,last_user=user('sol'),fluidbox={{name='ammonia',amount=40}}}) end
  for x=-30,-21 do ent('aquilo','transport-belt','transport-belt',x+0.5,-8.5,{frozen=true,unit_number=1000+x,last_user=user('sol'),get_max_transport_line_index=function() return 2 end,
    get_transport_line=function() return {get_contents=function() return {} end} end}) end
  ent('aquilo','transport-belt','transport-belt',-35.5,-8.5,{frozen=false,unit_number=999})   -- warm: not said
  ent('aquilo','heat-pipe','heat-pipe',-12.5,-5.5,{temperature=12.4})
  ent('nauvis','transport-belt','transport-belt',0.5,0.5,{frozen=true,unit_number=1})       -- Nauvis does not freeze
  local sol_aq={name='sol',force=force,surface=aquilo}
  local g=R.read(sol_aq,{kind='frozen'}).groups
  eq(#g,1)
  eq(g[1].line,'13 frozen near (-23,-8): pipe (-19.5,-5.5) holding ammonia 40; pipe (-18.5,-5.5) holding ammonia 40; pipe (-17.5,-5.5) holding ammonia 40; '
    ..'10 transport-belt from (-29.5,-8.5) to (-20.5,-8.5), empty; frozen at least 0m; nearest heater heat-pipe (-12.5,-5.5) 12 C, 5 tiles from pipe (-17.5,-5.5) (under 30 C: it heats nothing); a heater warms only what touches it (a side or a corner)')
  assert(g[1].to and g[1].to[1]:match('^sol '),'its builder hears it: '..tostring(g[1].to and g[1].to[1]))
  local pushed=R.lines(sol_aq,{})
  local said=false
  for _,l in ipairs(pushed or {}) do if l:find('13 frozen near (-23,-8)',1,true) then said=true end end
  assert(said,'pushed to sol: '..table.concat(pushed or {},' | '))
  -- 25 minutes on, still frozen: how long since first seen
  game.tick=game.tick+25*3600
  eq(R.read(sol_aq,{kind='frozen'}).groups[1].line:match('frozen at least [^;]*'),'frozen at least 25m')
  -- the background read (a stage of its own, FROZEN_SLICE a step) gives the same
  local stb={board={items={}}}
  local BGF=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return stb end,
    agents=function() return {{index=2,name='sol'}} end, who=function(p) return p.name end,
    place=function() return {key='aquilo',position={x=-20,y=-10}} end, network_groups=function() return {} end}
  local players0,forces0=force.players,game.forces
  force.players={{}}; game.forces={player=force}
  local n=0
  repeat game.tick=game.tick+1; finds={}; BGF.tick(game.tick); n=n+1 until (stb.push_jobs and not stb.push_jobs.player and n>1) or n>5000
  local bg
  for _,x in ipairs(BGF.read(sol_aq,{}).groups) do if x.kind=='frozen' then bg=x end end
  assert(bg and bg.line:find('13 frozen near (-23,-8): pipe (-19.5,-5.5) holding ammonia 40;',1,true),tostring(bg and bg.line))
  force.players,game.forces=players0,forces0
  -- thawed: gone, and its first-seen forgotten
  for _,e in ipairs(ents.aquilo) do e.frozen=false end
  game.tick=game.tick+1801
  eq(#R.read(sol_aq,{kind='frozen'}).groups,0)
  eq(next(st.push_frozen.player),nil,'thawed ones forgotten')
  table.remove(game.surfaces); ents.aquilo=nil; ents.nauvis={}
end
-- batch26 B3 (Grok: a biochamber holding eggs or bacteria that stops crafting loses the seed): not working with the
-- seed spoiling within 3 minutes: said, with why; working, or later than 3 minutes: not.
do
  local kept_status,kept_inv=defines.entity_status,defines.inventory
  defines.entity_status={working=0,item_ingredient_shortage=5,no_power=1}
  defines.inventory={crafter_input=2}
  local stacks={{valid_for_read=true,name='pentapod-egg',count=3,spoil_tick=game.tick+7800},{valid_for_read=true,name='nutrients',count=0},{valid_for_read=false}}
  stacks[2].valid_for_read=false
  local inv=setmetatable({get_item_count=function(n) local c=0 for _,x in ipairs(stacks) do if x.valid_for_read and x.name==n then c=c+x.count end end return c end},
    {__index=function(_,i) return stacks[i] end,__len=function() return #stacks end})
  local bio={valid=true,name='biochamber',type='assembling-machine',position={x=10.5,y=20.5},status=5,
    get_recipe=function() return {ingredients={{type='item',name='pentapod-egg',amount=1},{type='item',name='nutrients',amount=30}}} end,
    get_inventory=function(i) assert(i==2); return inv end}
  eq(A.seed_spoiling(bio),'biochamber (10.5,20.5) holds pentapod-egg 3: the first hatches in 2m10s; not crafting: item_ingredient_shortage (nutrients 0 of 30)')
  bio.status=0; eq(A.seed_spoiling(bio),nil)
  bio.status=5; stacks[1].spoil_tick=game.tick+20000; eq(A.seed_spoiling(bio),nil)
  defines.entity_status,defines.inventory=kept_status,kept_inv
end
-- batch27 B5 (Sonnet: coal fell to 3 of 56 drills working with no warning): the patches the ores survey has our drills
-- on, and a mine whose drills half stop within 30 min as a mine_depleting group to their builders, with the nearest
-- untapped patch of the ore.
do
  local st={ores={['player@1']={force='player',surface=1,patches={
    {name='coal',l=0,t=0,r=20,b=20,centre={x=10,y=10},miners=56,amount=50000},
    {name='coal',l=200,t=0,r=230,b=30,centre={x=215,y=15},miners=0,amount=900000},
    {name='crude-oil',l=0,t=50,r=10,b=60,centre={x=5,y=55},miners=2,yield=300}}}}}
  local nauvis={name='nauvis',index=1}
  local kept_surfaces=game.surfaces
  game.surfaces={[1]=nauvis,nauvis=nauvis}
  local drills={}
  for i=1,3 do drills[i]={name='electric-mining-drill',last_user={name='sonnet'}} end
  local horizon=20
  local M5=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,
    mine_forecast=function(s,f,q) return {entities=drills,drills=56,half_min=horizon,line='56 drills (3 working) on coal: 1,200 under them, taken 90/min now; half of them stopped in about 20m, all in about 25m'} end,
    territory=function() return nil end}
  local ms=M5.mine_patches({name='player'})
  eq(#ms,1); eq(ms[1].name,'coal'); eq(ms[1].surface,'nauvis')
  local g=M5.mine_group({name='player'},ms[1])
  eq(g.kind,'mine_depleting'); eq(g.by.sonnet,3)
  eq(g.line,'mine running out near (10,10): 56 drills (3 working) on coal: 1,200 under them, taken 90/min now; half of them stopped in about 20m, all in about 25m; nearest untapped coal (215,15) 205 tiles, about 900000')
  horizon=45
  eq(M5.mine_group({name='player'},ms[1]),nil,'half stop past 30 min: not told')
  game.surfaces=kept_surfaces
end
print('pushalerts: ok')
