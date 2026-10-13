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
    if f.force==force and f.type then
      local out={}
      for _,e in ipairs(ours) do if e.type==f.type then out[#out+1]=e end end
      return out
    end
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
eq(base.line,'area 1 (cluster, 27 tiles E of base centre) around (27,3) (0,0)-(60,6): 74 buildings (61 transport-belt, 11 stone-furnace, 2 gun-turret); '
  ..'turrets in range: 2 gun (23 ammo, 1 low); 43 buildings covered (2 by one turret only), 31 not; largest uncovered part (30,3)-(60,3): 31 buildings '
  ..'(31 transport-belt); nests: (105,2) 45 tiles E polluted')
eq(outpost.buildings,11); eq(outpost.turrets,0)
eq(outpost.line,'area 2 (cluster, 428 tiles SE of base centre) around (300,305) (300,300)-(300,310): 11 buildings (10 pipe, 1 pumpjack); no turret in range')
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

-- Clusters (shift 6: belts and pipes joined the whole base into one 420 by 1,000 tile area): links join cells of a
-- cluster and never two clusters. A cluster of assemblers and a pumpjack outpost 300 tiles east, joined by a
-- pipeline; and a factory 300 tiles wide further east, cut into 128-tile blocks.
for k in pairs(ours) do ours[k]=nil end
storage.defense_cache=nil
local function machine(x,y) return add('assembling-machine-2','assembling-machine',x,y) end
for x=0,18,2 do machine(x,0) end
for x=20,299 do add('pipe','pipe',x,0) end
add('pumpjack','mining-drill',300,0)
for x=1000,1300,8 do machine(x,0) end
-- A flamer in the first cluster with a quarter of its oil, and a dry one.
local function flamer(x,y,amount,direction)
  return add('flamethrower-turret','fluid-turret',x,y,{direction=direction or 8,prototype={turret_range=30,attack_parameters={range=30,min_range=6,turn_range=1/3}},
    fluidbox={[1]={amount=amount},get_capacity=function() return 200 end}})
end
flamer(10,4,50); flamer(12,4,0)
game.tick=2000
r=D.handlers.defense(p,{})
local kinds={}
for _,a in ipairs(r.areas) do kinds[#kinds+1]=a.kind..' '..a.box end
eq(table.concat(kinds,' | '),'line (64,0)-(255,0) | cluster (0,0)-(63,4) | cluster (256,0)-(300,0) | block (1024,0)-(1144,0) | block (1152,0)-(1272,0) '
  ..'| block (1000,0)-(1016,0) | block (1280,0)-(1296,0)')
local first=r.areas[2]
eq(first.flamers.count,2); eq(first.flamers.oil,50); eq(first.flamers.capacity,400); eq(first.flamers.dry,1); eq(first.flamers.low,nil)
assert(first.line:find('turrets in range: 2 flamethrower (oil 13%, 1 dry)',1,true),first.line)
eq(first.ammo,0)
assert(r.areas[4].line:find('^area 4 %(block, %d+ tiles E of base centre%)'),r.areas[4].line)

-- Pollution reach comes from the shared memory when wired (threat.lua): a nest polluted 5 minutes ago still counts.
local reads={}
local D2=dofile('mod/agent-harness_0.1.0/defense.lua'){state=function() return {} end,
  polluted=function(s,pos) reads[#reads+1]=pos; return 0,1000 end,reached=function(last) return last and game.tick-last<=54000 end}
for k in pairs(ours) do ours[k]=nil end
for x=0,20,2 do add('stone-furnace','furnace',x,0) end
game.tick=1000+18000
local nest=D2.handlers.defense(p,{}).nests[1]
eq(nest.pollution_reaches,true); eq(nest.pollution_now,nil); eq(nest.pollution_last,1000); assert(#reads>0)
assert(nest.line:find('pollution reaches it (last there 5m ago)',1,true),nest.line)

-- Flamer arcs: our burnable buildings within the arc (facing, +-60 degrees), from min range to range+3; walls are
-- fire-proof; behind the flamer and too close do not count.
for k in pairs(ours) do ours[k]=nil end
storage.defense_cache=nil
local wall_proto={resistances={fire={percent=1}}}
local f=flamer(0,0,150,8) -- facing south
add('pipe','pipe',0,10); add('pipe','pipe',5,15); add('pipe','pipe',0,32) -- in the arc (32: burning ground past range 30)
add('pipe','pipe',0,-10) -- behind
add('pipe','pipe',0,3) -- under min range
add('pipe','pipe',20,10) -- 63 degrees off south
add('pipe','pipe',0,40) -- beyond range+3
add('stone-wall','wall',2,10,{prototype=wall_proto})
add('gun-turret','ammo-turret',-3,12)
flamer(100,100,0,0) -- facing north, nothing near
local fl=D.handlers.flamers(p,{})
eq(fl.count,2); eq(fl.dry,1); eq(fl.with_buildings_in_arc,1)
local row=fl.flamers[1]
eq(row.at_risk,4); eq(row.facing,'S'); eq(row.kinds,'3 pipe, 1 gun-turret'); eq(row.nearest.name,'pipe'); eq(row.nearest.distance,10)
eq(row.line,'flamethrower-turret (0,0) facing S, oil 75% (150/200): 4 of our burnable buildings in its arc within 33 tiles: 3 pipe, 1 gun-turret '
  ..'(nearest pipe (0,10), 10 tiles)')
eq(fl.flamers[2].line,'flamethrower-turret (100,100) facing N, oil 0% (0/200): none of our burnable buildings in its arc')
print('defense: ok')
