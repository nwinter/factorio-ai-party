-- Run with lua tests/d22_batch98.lua. d22 batch98 BH1 (Astra #1900): flight_watch reads, each sample, the platform's
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path   -- (d24 batch152) modules require qflow
-- accumulators together and each railgun's energy (least, at the start, now, runs below a shot's energy: its full
-- buffer), and counts each railgun's hits, shots that hit (ticks), damage and kills from the damage and death events.
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
defines={space_platform_state={on_the_path=1},inventory={turret_ammo=1,hub_main=1}}
prototypes={item={['railgun-ammo']={type='ammo'},['firearm-magazine']={type='ammo'}}}
local uid=0
local function entity(t)
  uid=uid+1
  t.valid,t.unit_number=true,100+uid
  t.force=t.force or 'ours'
  t.get_inventory=function() return {get_item_count=function() return t.count or 0 end,[1]={valid_for_read=(t.count or 0)>0,name=t.ammo}} end
  return t
end
local MJ=1e6
local r1=entity{name='railgun-turret',type='ammo-turret',position={x=-20,y=-40},count=10,ammo='railgun-ammo',electric_buffer_size=10*MJ,energy=10*MJ}
local r2=entity{name='railgun-turret',type='ammo-turret',position={x=20,y=-40},count=10,ammo='railgun-ammo',electric_buffer_size=10*MJ,energy=10*MJ}
local gun=entity{name='gun-turret',type='ammo-turret',position={x=0,y=-30},count=50,ammo='firearm-magazine'}
local a1=entity{name='accumulator',type='accumulator',position={x=0,y=0},electric_buffer_size=5*MJ,energy=5*MJ}
local a2=entity{name='accumulator',type='accumulator',position={x=2,y=0},electric_buffer_size=5*MJ,energy=5*MJ}
local all={r1,r2,gun,a1,a2}
local surface={name='platform-16',find_entities_filtered=function(f)
  local o={}
  for _,e in ipairs(all) do if e.valid and e.type==f.type then o[#o+1]=e end end
  return o
end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=16,name='Asterion',surface=surface,force=force,state=1,space_connection={from={name='aquilo'},to={name='gleba'}},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={[16]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function() return pl end,hits=function() return {hits=0,damage=0,entities={},by={}} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local asteroid={valid=true,force='enemy',name='huge-metallic-asteroid'}
local function hit(t,cause,damage) F.on_damaged({tick=t,cause=cause,entity=asteroid,final_damage_amount=damage}) end

local r=F.call(p,{platform='Asterion'})
assert(r.line:find('watching 3 ammo turrets %(2 railguns%) and 2 accumulators once a second'),r.line)
eq(r.watch.sample_ticks,60); eq(r.watch.accumulators.count,2); eq(r.watch.accumulators.at_start,1)
eq(st.flightwatch.powered[r1.unit_number],true,'railguns indexed for the events'); eq(st.flightwatch.powered[gun.unit_number],nil,'a gun turret is not')

-- r1 fires at 1100: one shot hits three asteroids on its line in one tick, and kills one; empty, it recharges 10 MW
-- (10 MJ a second): below a shot's energy in the samples at 1131 and 1191 (samples fall on tick % 60 == 51). r2 never fires.
run(1099)
game.tick=1100
r1.energy=0; a1.energy,a2.energy=2*MJ,3*MJ
hit(1100,r1,2000); hit(1100,r1,2000); hit(1100,r1,1500)
F.on_died({tick=1100,cause=r1,entity=asteroid})
-- the gun turret's hits and a hit by r1 on something of our own force do not count
hit(1100,gun,50)
F.on_damaged({tick=1100,cause=r1,entity={valid=true,force='ours'},final_damage_amount=10})
run(1131)   -- sample at 1131: r1 at 0, accumulators 50%
r1.energy=6*MJ; a1.energy,a2.energy=4*MJ,4*MJ
run(1191)   -- sample at 1191: r1 at 6 MJ, still below; accumulators 80%
r1.energy=10*MJ; a1.energy,a2.energy=5*MJ,5*MJ
run(1251)   -- full again
-- a second shot at 1260 that hits once
game.tick=1260; r1.energy=0; hit(1260,r1,2000)
run(1311)   -- sampled below again (one sample, a run of 60 ticks)
r1.energy=10*MJ
run(1371)

local w=F.call(p,{id=r.watch.id}).watch
eq(w.sample_ticks,60)
eq(w.accumulators.least_fraction,0.5); eq(w.accumulators.least_tick,1131); eq(w.accumulators.now,1)
eq(#w.railguns,2)
local g=w.railguns[1]
eq(g.unit_number,r1.unit_number,'the longest run below first')
eq(g.shot_energy,10*MJ); eq(g.least_energy,0); eq(g.least_tick,1131); eq(g.energy_at_start,10*MJ); eq(g.energy_now,10*MJ)
eq(g.below_samples,3); eq(g.below_runs,2); eq(g.longest_below_ticks,120,'1131 and 1191: 60 + 60 ticks'); eq(g.longest_below_from_tick,1131)
eq(g.below_ticks,180)
eq(g.hits,4); eq(g.shots_hit,2,'two ticks it hit something'); eq(g.damage,7500); eq(g.kills,1)
local g2=w.railguns[2]
eq(g2.below_samples,0); eq(g2.hits,0); eq(g2.least_energy,10*MJ)
assert(w.railgun_lines[1]:find('energy least 0 MJ %(0%% of a shot%) at %+'),w.railgun_lines[1])
assert(w.railgun_lines[1]:find('below a shot\'s energy in 3 samples %(180 ticks%) over 2 runs, the longest 120 ticks'),w.railgun_lines[1])
assert(w.railgun_lines[1]:find('4 hits %(2 shots that hit%), 7500 damage, 1 kills'),w.railgun_lines[1])
assert(w.railgun_lines[2]:find('never below a shot\'s energy in a sample'),w.railgun_lines[2])
assert(w.line:find('one every 60 ticks'),w.line)
assert(w.line:find('accumulators %(2%): least 50%% at %+'),w.line)
assert(w.line:find('2 powered turrets %(railguns%): 1 read below a shot\'s energy %(its full buffer%) in some sample, the longest run 2s %(120 ticks%), railgun%-turret %(%-20,%-40%)'),w.line)
assert(w.line:find('4 hits %(2 shots that hit%), 7500 damage, 1 kills'),w.line)
assert(w.note:find('no energy_per_shot'),w.note)

-- the end: the setter's alert carries the power phrase, and the event index empties
pl.state=2; pl.space_location={name='gleba'}
run(1431)
local done=F.call(p,{id=r.watch.id}).watch
eq(done.state,'done')
eq(st.flightwatch.powered,nil,'no railgun watched now')
assert(st.flightwatch.events[#st.flightwatch.events].text:find('2 powered turrets %(railguns%)'),st.flightwatch.events[#st.flightwatch.events].text)
-- events after the end count nothing
hit(1500,r1,999)
eq(F.call(p,{id=r.watch.id}).watch.railguns[1].hits,4)
-- a platform with no accumulator and no railgun: no power phrase, no railguns block
all={gun}
pl.state=1; pl.space_location=nil
local r2w=F.call(p,{platform='Asterion',replace=true})
eq(r2w.watch.accumulators,nil); assert(not r2w.watch.line:find('accumulators'),r2w.watch.line)
local full=F.call(p,{id=r2w.watch.id}).watch
eq(full.railguns,nil); eq(full.sample_ticks,60)
print('d22_batch98 BH1 flight watch power: ok')
