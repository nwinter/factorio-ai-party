-- Run from repository root: lua tests/defense.lua
-- The defense read: built-up areas, turret cover and ammo, uncovered parts, nests near our buildings.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,artillery_turret_ammo=2}}
local storage={}
local force={name='player',is_chunk_charted=function(_,c) return c.x<20 end}
local ours,enemies,scans={},{},0
local function add(name,type,x,y,extra)
  local e={valid=true,name=name,type=type,position={x=x,y=y},prototype={turret_range=18}}
  for k,v in pairs(extra or {}) do e[k]=v end
  ours[#ours+1]=e; return e
end
local function turret(x,y,count)
  return add('gun-turret','ammo-turret',x,y,{get_inventory=function() return {get_item_count=function() return count end} end})
end
-- Main base: 11 furnaces in a row and a belt running east to x=60; two turrets at the west end.
for x=0,20,2 do add('stone-furnace','furnace',x,0) end
for x=0,60 do add('transport-belt','transport-belt',x,3) end
turret(10,6,20); turret(12,6,3)
-- Not buildings: a character and a ghost.
add('character','character',5,5); add('entity-ghost','entity-ghost',6,6)
-- An outpost far away with a short pipeline and no turret.
add('pumpjack','mining-drill',300,300)
for y=301,310 do add('pipe','pipe',300,y) end
-- Nests: one near the base that pollution reaches, one beyond 256 tiles, one on an uncharted chunk.
enemies={{valid=true,type='unit-spawner',position={x=100,y=0}},{valid=true,type='unit-spawner',position={x=110,y=4}},
  {valid=true,type='turret',position={x=105,y=-2}},{valid=true,type='unit-spawner',position={x=-400,y=-400}},
  {valid=true,type='unit-spawner',position={x=700,y=310}}}
local surface={index=1,get_pollution=function(pos) return pos.x>=100 and pos.y<50 and 12 or 0 end,
  find_entities_filtered=function(f)
    scans=scans+1
    if f.force==force then return ours end
    assert(f.force=='enemy' and f.area)
    return enemies
  end}
game={tick=100}
local p={index=1,force=force,surface=surface}
local D=dofile('mod/agent-harness_0.1.0/defense.lua'){state=function() return storage end}
local r=D.handlers.defense(p,{})
eq(#r.areas,2)
local base,outpost=r.areas[1],r.areas[2]
eq(base.buildings,74); eq(base.turrets,2); eq(base.ammo,23); eq(base.low,1); eq(base.empty,nil)
eq(base.turret_list[1].ammo,3,'lowest ammo first')
-- Covered: within 18 tiles of a turret centre (furnaces all, belts x 0..29).
eq(base.covered,43); eq(base.uncovered,31)
eq(base.uncovered_parts[1].box,'(30,3)-(60,3)'); eq(base.uncovered_parts[1].kinds,'31 transport-belt')
-- Belts at x 28 and 29 are within range of the east turret only.
eq(base.line,'area 1 around (27,3) (0,0)-(60,6): 74 buildings (61 transport-belt, 11 stone-furnace, 2 gun-turret); 2 turrets in range (23 ammo, 1 low); '
  ..'43 buildings covered (2 by one turret only), 31 not; largest uncovered part (30,3)-(60,3): 31 buildings (31 transport-belt)')
eq(outpost.buildings,11); eq(outpost.turrets,0); eq(outpost.line,'area 2 around (300,305) (300,300)-(300,310): 11 buildings (10 pipe, 1 pumpjack); no turret in range')
eq(r.areas_without_turrets[1],2)
-- Nests: the charted one within 256 tiles, with worms, distance and bearing from the nearest building, and pollution.
eq(#r.nests,1)
local n=r.nests[1]
eq(n.spawners,2); eq(n.worms,1); eq(n.position.x,105); eq(n.pollution_reaches,true); eq(n.area,1)
eq(n.line,'nest (105,2) 2 spawners, 1 worm: 45 tiles E of transport-belt at (60,3) (area 1); pollution reaches it')
-- Cached for 10 s: a second read does not rescan.
local before=scans
game.tick=600; D.handlers.defense(p,{}); eq(scans,before)
game.tick=700; eq(D.handlers.defense(p,{}).as_of,nil); assert(scans>before)
-- limit caps the areas listed in full; the rest are summed.
local one=D.handlers.defense(p,{limit=1})
eq(#one.areas,1); eq(one.more,'+1 smaller areas with 11 buildings (1 with no turret in range): limit raises the count')
print('defense: ok')
