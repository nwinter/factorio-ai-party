-- Run with lua tests/pushalerts.lua: the game's alerts and key warnings,
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path  -- (walk.lua)
-- pushed to the agents they concern (pushalerts.lua). Viewer Enginerd,
-- shift07 15:30: "The agents would be a lot more efficient if they'd react to
-- the alerts in the UI, like reacting to unpowered buildings."
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
ent('vulcanus','flamethrower-turret','fluid-turret',10,10,{fluidbox={{amount=0}}})
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
eq(#l,1); eq(l[1],'12 gun-turret out of ammo near (67,-170); rearm')
l=A.lines(luna,hl)
eq(#l,3,table.concat(l,' | '))
assert(has(l,'8 assembling-machine-2 no power near (125,40) on nauvis; fh call power'),table.concat(l,' | '))
assert(has(l,'2 assembling-machine-2 not connected to power (no pole reaches them) near (132,44) on nauvis'))
assert(has(l,'1 flamethrower-turret out of flamer oil near (10,10); fh call flamers'),'the nearest on Vulcanus')
l=A.lines(astra,ha)
eq(#l,2,table.concat(l,' | '))
assert(has(l,'5 stone-furnace out of fuel near (6,2); refuel'))
assert(has(l,'2 (1 entity-ghost, 1 transport-belt) ghosts waiting for materials (no robot can bring them) near (-41,11)'),table.concat(l,' | '))
assert(not has(l,'Sunward') and not has(l,'entity_destroyed'))

-- 2. One digest per 150 s, and nothing repeated until it changes.
for i=13,16 do turrets[i]=ent('nauvis','gun-turret','ammo-turret',60+i,-170) end
game.tick=game.tick+60*60
eq(#A.lines(sol,hs),0,'within 150 s')
game.tick=game.tick+91*60
l=A.lines(sol,hs); eq(#l,1); eq(l[1],'16 gun-turret out of ammo near (69,-170) (was 12); rearm')
game.tick=game.tick+151*60
eq(#A.lines(sol,hs),0,'unchanged: not told again')
eq(#A.lines(luna,hl),0); eq(#A.lines(astra,ha),0)
-- Rearmed, then empty again: news again.
for _,t in ipairs(turrets) do t.rounds=20 end
game.tick=game.tick+151*60
eq(#A.lines(sol,hs),0); eq(next(hs.push.told),nil,'gone: forgotten')
for i=1,4 do turrets[i].rounds=0 end
game.tick=game.tick+151*60
l=A.lines(sol,hs); eq(l[1],'4 gun-turret out of ammo near (63,-170); rearm')

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
local function run(n) for _=1,n do game.tick=game.tick+1; finds={}; C.tick(game.tick); assert(#finds<=1,'at most one find a tick') end end
run(1); eq(#finds,0,'the job starts'); assert(st5.push_jobs.player)
local stages=#st5.push_jobs.player.stages
eq(stages,2+3,'each of 2 planets, then alerts, networks, merge')
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
  eq(g['lost_source.boiler'].line,'1 inserter feeding boiler lost its pickup target near (61,15): burner-inserter (60.5,14.5) read wooden-chest (41.5,13.5), puts into boiler (60,16.5)')
  eq(g['lost_source.boiler'].lost[1],'burner-inserter (60.5,14.5) read wooden-chest (41.5,13.5), puts into boiler (60,16.5)')
  eq(#D.read(astra,{kind='lost_source'}).groups,3,'kind lost_source: every fed kind')
  local told=D.lines(astra,ha6)
  assert(has(told,'1 inserter feeding furnace lost its pickup target near (45,15): inserter (44.5,14.5) read wooden-chest (41.5,13.5), puts into stone-furnace (44,16)'),table.concat(told,' | '))
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
  eq(g['lost_target.furnace'].line,'1 inserter feeding furnace lost its drop target near (45,15): inserter (44.5,14.5) put into stone-furnace (44,16), reads iron-chest (41.5,13.5)')
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
  eq(g.rebuilt_empty.line,'2 gun-turret rebuilt empty near (212,10): no ammo since built, 60+ s: gun-turret (210,10) requests 10 firearm-magazine; gun-turret (214,10) no ammo request; rearm')
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
print('pushalerts: ok')
