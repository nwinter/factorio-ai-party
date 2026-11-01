-- Run from the harness root: lua tests/batch400.lua.
-- A configure positions batch closes one flight interval; all sampled observations survive.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1}}
prototypes={item={['railgun-ammo']={type='ammo'},['repair-pack']={type='repair-tool'}},
  entity={['electric-turret']={attack_parameters={ammo_categories={'laser'},ammo_type={energy_consumption=800000}}}}}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local surface={index=9,name='platform-1'}
local entities={}
local function entity(n,kind)
  local e={valid=true,unit_number=n,name=kind=='ammo-turret' and 'railgun-turret' or kind,type=kind,
    surface=surface,force=force,position={x=n,y=0},bounding_box={left_top={x=n-1,y=-1},right_bottom={x=n+1,y=1}},
    electric_buffer_size=1e7,energy=1e7,count=10,quality={name='normal'},kills=0,damage_dealt=0,
    prototype={attack_parameters={ammo_category='laser',ammo_type={category='laser',energy_consumption=800000}}}}
  e.get_inventory=function() return {get_item_count=function() return e.count end,[1]={valid_for_read=e.count>0,name='railgun-ammo'}} end
  entities[#entities+1]=e
  return e
end
-- Beyond both normal row limits (24 ammo turrets, 64 powered turrets).
for i=1,65 do entity(i,'ammo-turret') end
for i=66,130 do entity(i,'electric-turret') end
local acc=entity(131,'accumulator')
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(entities) do
    if (f.position and e.position.x==(f.position.x or f.position[1])) or (not f.position and f.type==e.type) then out[#out+1]=e end
  end
  return out
end
local pl={valid=true,index=1,name='Asterion',surface=surface,force=force,state=1,
  space_connection={from={name='aquilo'},to={name='solar-system-edge'}},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={pl}
game={tick=1000,forces={player=force}}
local p={name='astra',index=1,force=force}
local st,damage,held={},0,1000
local function damage_kinds()
  local out={}
  for i=1,7 do out['turret-'..i]=damage/7 end
  return out
end
local X
local F=require('flightwatch'){state=function() return st end,platform=function() return pl end,
  hits=function() return {hits=damage>0 and 2 or 0,damage=damage,entities=damage_kinds(),by={asteroid=damage}} end,
  fuel_held=function() return {['thruster-fuel']={held=held,in_tanks=held/2},['thruster-oxidizer']={held=held*2}} end,
  mixed_view=function(w) return X.view(w) end}
X=require('mixed'){state=function() return st end,flight_rebase=F.rebase}
local function run(to)
  while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end
end
local positions={{1,0},{2,0},{3,0},{4,0}}
local function batch() eq(X.at(surface,positions,'configure priority_targets by astra'),4) end
F.call(p,{platform='Asterion'})
local w=st.flightwatch.list[1]
local limit=w.until_tick
entities[1].count,entities[1].energy,acc.energy=0,0,5e6
entities[66].energy=0
run(34405)
damage,held=2317.4,400
local before=F.call(p,{id=w.id}).watch
eq(#before.turrets,24); eq(#before.railguns,64)
batch()
eq(#w.mixed.parts,1,'four edits on one tick keep one nonzero interval')
local part=w.mixed.parts[1]
eq(part.from_tick,1000); eq(part.to_tick,34405); eq(w.start,34405); eq(w.until_tick,limit)
eq(#w.mixed.edits,4)
eq(part.damage.damage,2317.4); eq(part.damage.hits,2)
eq(#part.damage.entities,7,'all damage categories, beyond the usual five')
eq(part.turrets[1].empty_ticks,before.turrets[1].empty_ticks)
eq(part.turrets[1].longest_empty_ticks,before.turrets[1].longest_empty_ticks)
eq(part.railguns[1].below_ticks,before.railguns[1].below_ticks)
eq(part.accumulators.least_fraction,0.5)
eq(part.fuel.start['thruster-fuel'].held,1000); eq(part.fuel['end']['thruster-fuel'].held,400)
eq(#part.turrets,65); eq(#part.lines,65); eq(#part.railguns,65); eq(#part.railgun_lines,65)
eq(#part.lasers,65); eq(#part.laser_lines,65)
eq(part.lasers[1].below_ticks,before.lasers[1].below_ticks)
eq(part.mixed,nil,'no recursive history in a snapshot')
eq(part.turrets_more,nil); eq(part.railguns_more,nil); eq(part.lasers_more,nil)
eq(part.ammunition.from_tick,1000); eq(part.repair_packs_used,0)
assert(part.foundation)
-- Later samples and splits do not mutate the closed interval.
entities[1].count,entities[1].energy,acc.energy=20,1e7,1e7
damage,held=2400,300
run(34408); batch()
eq(#w.mixed.parts,2); eq(w.mixed.parts[2].from_tick,34405); eq(w.mixed.parts[2].to_tick,34408)
eq(w.mixed.parts[1],part); eq(part.damage.damage,2317.4); eq(part.fuel['end']['thruster-fuel'].held,400)
run(34411); batch()
eq(#w.mixed.parts,3); eq(w.mixed.parts[1],part)
-- At the cap, same-tick edits keep all three real intervals.
eq(X.edit(entities[5],'configure priority_targets by astra'),1)
eq(#w.mixed.parts,3); eq(w.mixed.parts[1],part)
run(34414); batch()
eq(#w.mixed.parts,3); eq(w.mixed.parts[1].from_tick,34405)
eq(w.mixed.parts[3].from_tick,34411); eq(w.mixed.parts_dropped,1)
local read=F.call(p,{id=w.id}).watch.mixed
eq(read.parts_limit,3); eq(read.parts_dropped,1)
assert(read.line:find('oldest',1,true))
for _,v in ipairs(read.parts) do assert(v.to_tick>v.from_tick); eq(v.mixed,nil) end
run(34540)
eq(part.turrets[1].now,0); eq(part.railguns[1].energy_now,0)
eq(part.lasers[1].energy_now,0); eq(part.accumulators.now,0.5)
eq(part.damage.damage,2317.4); eq(part.fuel['end']['thruster-fuel'].held,400)
-- A loaded watch can still contain zero-duration parts written by older runtime code.
w.mixed.parts[2]={from_tick=game.tick,to_tick=game.tick}
eq(X.edit(entities[6],'configure priority_targets by astra'),1)
eq(#w.mixed.parts,3); eq(w.mixed.parts_dropped,1,'legacy empty part removed without dropping a real interval')
for _,v in ipairs(w.mixed.parts) do assert(v.to_tick>v.from_tick) end
-- Editing on the watch's initial tick also creates no zero-duration part.
game.tick=40000
F.call(p,{platform='Asterion',replace=true})
local fresh=st.flightwatch.list[#st.flightwatch.list]
batch(); eq(#fresh.mixed.parts,0)
run(40003); batch(); eq(#fresh.mixed.parts,1); eq(fresh.mixed.parts[1].from_tick,40000)
print('batch400 flight mixed boundaries, full observations, real-segment cap: ok')
