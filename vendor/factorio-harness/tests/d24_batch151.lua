-- Run with lua tests/d24_batch151.lua. d24 batch151 PW1 (Astra #2178: Asterion's 20 rare lasers fought and its flight
-- watch read only the 23 railguns): flight_watch keeps each laser turret apart from the ammo turrets and the railguns:
-- its energy each sample against one shot's (the prototype's attack_parameters.ammo_type.energy_consumption), the
-- samples and runs below it, and its kills and damage dealt over the watch (LuaEntity.kills and damage_dealt); a watch
-- begun before keeps its read.
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
defines={space_platform_state={on_the_path=1},inventory={turret_ammo=1,hub_main=1}}
local KJ=1e3
prototypes={item={['railgun-ammo']={type='ammo'}},entity={
  ['laser-turret']={attack_parameters={ammo_categories={'laser'},ammo_type={energy_consumption=800*KJ}}},
  ['tesla-turret']={attack_parameters={ammo_categories={'tesla'},ammo_type={energy_consumption=1000*KJ}}}}}
local uid=0
local function entity(t)
  uid=uid+1
  t.valid,t.unit_number=true,100+uid
  t.force=t.force or 'ours'
  t.get_inventory=function() return {get_item_count=function() return t.count or 0 end,[1]={valid_for_read=(t.count or 0)>0,name=t.ammo}} end
  return t
end
local rail=entity{name='railgun-turret',type='ammo-turret',position={x=-20,y=-40},count=10,ammo='railgun-ammo',electric_buffer_size=10e6,energy=10e6}
local l1=entity{name='laser-turret',type='electric-turret',quality={name='rare'},position={x=-4,y=-30},electric_buffer_size=801*KJ,energy=801*KJ,kills=15,damage_dealt=2857.6}
local l2=entity{name='laser-turret',type='electric-turret',quality={name='rare'},position={x=4,y=-30},electric_buffer_size=801*KJ,energy=801*KJ,kills=0,damage_dealt=0}
local tesla=entity{name='tesla-turret',type='electric-turret',quality={name='normal'},position={x=0,y=-20},electric_buffer_size=2e6,energy=2e6,kills=0,damage_dealt=0}
local all={rail,l1,l2,tesla}
local surface={name='platform-16',find_entities_filtered=function(f)
  local o={}
  for _,e in ipairs(all) do if e.valid and e.type==f.type then o[#o+1]=e end end
  return o
end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=16,name='Asterion',surface=surface,force=force,state=1,space_connection={from={name='aquilo'},to={name='solar-system-edge'}},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={[16]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function() return pl end,hits=function() return {hits=0,damage=0,entities={},by={}} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end

-- A watch begun before the deploy (no laser list): its read as it was, no laser found at the minute's refind.
local old=F.call(p,{platform='Asterion'})
local ow
for _,w in ipairs(st.flightwatch.list) do if w.id==old.watch.id then ow=w end end
ow.lasers,ow.by_laser=nil,nil
run(1000+3700)
local oread=F.call(p,{id=old.watch.id}).watch
eq(oread.lasers,nil,'an old watch keeps its schema'); eq(#oread.railguns,1); eq(ow.lasers,nil,'no lasers added at the refind')
assert(not oread.line:find('laser'),oread.line)

-- A new watch: the lasers apart, the tesla left out (ammo category tesla), the railgun as before.
game.tick=10000
local r=F.call(p,{platform='Asterion',replace=true})
assert(r.line:find('watching 1 ammo turrets %(1 railguns%), 2 laser turrets and 0 accumulators once a second'),r.line)
-- fights: l1 fires and reads 256.6 kJ at two samples in a row (and once more later), l2 never below a shot
local ph
for _,w in ipairs(st.flightwatch.list) do if w.id==r.watch.id then ph=w.phase end end
local function to_sample(n) local t=game.tick+1; while t%60~=ph do t=t+1 end; run(t-1); n() ; run(t) end
to_sample(function() end)
to_sample(function() l1.energy=256.6*KJ; l1.kills=16; l1.damage_dealt=2932.8 end)
to_sample(function() l1.energy=512.2*KJ end)
to_sample(function() l1.energy=801*KJ; l2.damage_dealt=75.2 end)
to_sample(function() l1.energy=799*KJ; l1.kills=18; l1.damage_dealt=3083.2 end)
to_sample(function() l1.energy=801*KJ end)
local w=F.call(p,{id=r.watch.id}).watch
eq(#w.lasers,2); eq(#w.railguns,1,'railguns as before'); eq(#w.turrets,1,'ammo turrets as before')
local a=w.lasers[1]
eq(a.unit_number,l1.unit_number); eq(a.quality,'rare'); eq(a.shot_energy,800*KJ); eq(a.buffer,801*KJ)
eq(a.least_energy,256600); eq(a.energy_at_start,801000); eq(a.energy_now,801000)
eq(a.below_samples,3); eq(a.below_runs,2); eq(a.longest_below_samples,2); eq(a.longest_below_ticks,120); eq(a.below_now,nil)
eq(a.kills,3); eq(a.damage,225.6); eq(a.kills_start,15); eq(a.kills_end,18)
local b=w.lasers[2]
eq(b.below_samples,0); eq(b.kills,0); eq(b.damage,75.2)
assert(w.laser_lines[1]:find('^rare laser%-turret %(%-4,%-30%) #%d+: energy least 0%.3 MJ %(32%.1%% of a shot%)'),w.laser_lines[1])
assert(w.laser_lines[1]:find('below a shot\'s energy in 3 samples %(180 ticks%) over 2 runs, the longest 2 samples %(120 ticks%) from %+'),w.laser_lines[1])
assert(w.laser_lines[1]:find('3 kills, 225%.6 damage dealt$'),w.laser_lines[1])
assert(w.laser_lines[2]:find('never below a shot\'s energy in a sample; 0 kills, 75%.2 damage dealt'),w.laser_lines[2])
assert(w.line:find('2 laser turrets: 1 read below a shot\'s energy %(0%.8 MJ%) in some sample, the longest run 2 samples %(120 ticks%), laser%-turret %(%-4,%-30%)'),w.line)
assert(w.line:find('3 kills, 301 damage dealt'),w.line)
assert(w.note:find('energy_consumption, 800 kJ'),w.note)
-- a laser destroyed keeps its change up to its last sample; the end's alert carries the lasers
to_sample(function() l2.valid=false end)
pl.state=2; pl.space_location={name='solar-system-edge'}
run(game.tick+61)
local done=F.call(p,{id=r.watch.id}).watch
eq(done.state,'done')
local gone
for _,x in ipairs(done.lasers) do if x.unit_number==l2.unit_number then gone=x end end
assert(gone.gone_tick,'gone'); eq(gone.damage,75.2)
assert(st.flightwatch.events[#st.flightwatch.events].text:find('2 laser turrets: 1 read below'),st.flightwatch.events[#st.flightwatch.events].text)
-- no laser aboard: no lasers block, no laser phrase
all={rail}
pl.state=1; pl.space_location=nil
local r3=F.call(p,{platform='Asterion',replace=true})
assert(not r3.line:find('laser'),r3.line)
local full=F.call(p,{id=r3.watch.id}).watch
eq(full.lasers,nil); assert(not full.line:find('laser turrets'),full.line)
print('d24_batch151 PW1 flight watch lasers: ok')
