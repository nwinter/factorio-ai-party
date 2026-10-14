-- Run with lua tests/pushalerts.lua: the game's alerts and key warnings,
-- pushed to the agents they concern (pushalerts.lua). Viewer Enginerd,
-- shift07 15:30: "The agents would be a lot more efficient if they'd react to
-- the alerts in the UI, like reacting to unpowered buildings."
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=0,no_power=1,low_power=2,no_fuel=3},inventory={turret_ammo=7},
  alert_type={entity_destroyed=1,no_material_for_construction=2,turret_out_of_ammo=3,not_enough_repair_packs=4,custom=5}}
storage={board={items={}}}
local force={name='player',players={}}
local ents={nauvis={},vulcanus={},['platform-1']={}}
local function surface(name,platform)
  return {name=name,platform=platform,find_entities_filtered=function(f)
    eq(f.force,force); assert(f.type and f.limit,'by type, bounded')
    local out={}; for _,e in ipairs(ents[name]) do if e.valid then out[#out+1]=e end end; return out end}
end
local nauvis,vulcanus=surface('nauvis'),surface('vulcanus')
game={tick=100000,surfaces={nauvis,vulcanus,surface('platform-1',{name='Sunward'})}}
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
print('pushalerts: ok')
