-- platform_digest (batch24 B1, Luna: ~15 reads to diagnose Kestrel II): one read from platforms, platform_supply,
-- platform_endurance and platform_defense, the stopped first. Replies shaped as Kestrel II's in shift31's journals.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
prototypes={item={['firearm-magazine']={type='ammo'},rocket={type='ammo'},['repair-pack']={type='repair-tool'}}}
local pl={name='Kestrel II',surface={}}
local fail_defense=false
local D=require('platdigest'){platform=function(_,name) eq(name,'Kestrel II'); return pl end,reads={
  platforms=function(_,a) eq(a.platform,'Kestrel II'); return {platforms={{name='Kestrel II',state='on_the_path',leg='fulgora->aquilo',leg_left_km=12000,eta_min=6.5,
    next_stop='aquilo',speed_kms=33.3,hub_slots='101 of 139 free',hub_chunks='asteroid chunks take 9 of 139 slots (metallic 5, carbonic 4)'}}} end,
  platform_supply=function() return {first_stop='crusher (3,4) metallic-asteroid-crushing: full_output; in metallic-asteroid-chunk*1, out iron-ore*50',
    stops={'crusher (3,4) metallic-asteroid-crushing: full_output; in metallic-asteroid-chunk*1, out iron-ore*50','gun-turret (-16,-32) empty: fast-inserter (-15.5,-30.5) from fast-transport-belt (-15.5,-29.5)'},
    lines={'first stop: crusher (3,4) ...','5 collectors','collector (-20.5,-38.5): working; holds empty','2 crushers','crusher (3,4) metallic-asteroid-crushing: full_output; in metallic-asteroid-chunk*1, out iron-ore*50',
      'crusher (6,4) carbonic-asteroid-crushing: working; in carbonic-asteroid-chunk*1, out carbon*3','1 fuel and oxidizer maker','chemical-plant (9,4) thruster-fuel: working; in carbon*2, out empty; fluids water 100',
      '2 thrusters: no thruster tank under half','8 guns, 1 empty; the hub holds firearm-magazine*55','ghosts: no entity ghosts'},
    chunks={'metallic-asteroid-chunk: 5 collectors; goes to the hub (over 101 belt tiles)'}} end,
  platform_endurance=function() return {hub_slots='101 of 139 free',chunks_collected={'carbonic-asteroid-chunk 6.2/min','metallic-asteroid-chunk 6.5/min'},
    resources={{name='firearm-magazine',line='firearm-magazine: 1293 now (turrets 941, belts 419, hands 5); made 2.3/min, used 18.2/min'},
      {name='repair-pack',line='repair-pack: 133 now (hub 133)'},{name='thruster-fuel',line='thruster-fuel: 12000 now; runs out in 40 min at the flight rate'}},
    solar='18 solar panels: 1080 kW at full sun; 24 machines on low power, 0 on no power now',low_power=24,no_power=0} end,
  platform_defense=function()
    if fail_defense then error('platdefense.lua:60: platform Kestrel II has no surface yet') end
    return {collectors={{position={x=-20.5,y=-38.5},covered_by=8},{position={x=19.5,y=-38.5},covered_by=0}},
      sides={{side='north',uncovered=0},{side='east',uncovered=12}},
      turrets={{name='gun-turret',ammo='firearm-magazine*10'},{name='gun-turret',ammo='no ammo'},{name='rocket-turret',ammo='rocket*10'}},
      feed={reaches=2162,stranded=30,stranded_groups={'15 on 13 belts in (8.5,18.5)-(8.5,45.5)'}}} end}}
local r=D.read({},{platform='Kestrel II'})
eq(r.lines[1],'stopped or blocked (4): crusher (3,4) metallic-asteroid-crushing: full_output; in metallic-asteroid-chunk*1, out iron-ore*50 | gun-turret (-16,-32) empty: fast-inserter (-15.5,-30.5) from fast-transport-belt (-15.5,-29.5) | collector (19.5,-38.5): no turret reaches its front | east side: 12 edge tiles no turret reaches')
eq(r.route,'state on_the_path; leg fulgora->aquilo, 12000 km left, arrives in about 6.5 min; next stop aquilo; speed 33.3 km/s')
eq(r.hub,'hub slots 101 of 139 free; asteroid chunks take 9 of 139 slots (metallic 5, carbonic 4)')
eq(r.chunks[1],'collected: carbonic-asteroid-chunk 6.2/min, metallic-asteroid-chunk 6.5/min'); eq(#r.chunks,2)
eq(#r.crushers,3); eq(r.crushers[1],'2 crushers'); eq(#r.makers,2); has(r.makers[2],'chemical-plant (9,4) thruster-fuel: working')
eq(r.thrusters,'2 thrusters: no thruster tank under half')
eq(#r.tanks,1); has(r.tanks[1],'runs out in 40 min'); eq(#r.ammo,1); has(r.ammo[1],'used 18.2/min')
eq(r.turrets,'3 turrets, 1 empty; ammunition that can reach a turret 2162, stranded 30 (15 on 13 belts in (8.5,18.5)-(8.5,45.5))')
has(r.power,'24 machines on low power'); eq(r.errors,nil)
-- the lines in order: stopped, route, hub, chunks, crushers, makers, thrusters, tanks, ammo, turrets, power
local order={}
for _,l in ipairs(r.lines) do order[#order+1]=l:match('^(%S+)') end
eq(table.concat(order,','),'stopped,route:,hub,chunks:,chunks:,2,crusher,crusher,1,chemical-plant,2,tank:,ammo:,turrets:,power:')
-- a read that fails is named; the rest stand
fail_defense=true
r=D.read({},{platform='Kestrel II'})
eq(r.errors[1],'platform_defense: platform Kestrel II has no surface yet'); eq(r.turrets,nil); has(r.lines[1],'stopped or blocked (2)')
print('platdigest: ok')
