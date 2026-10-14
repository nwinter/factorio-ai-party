-- Run from repository root: lua tests/dryrun.lua
-- The dry run (dryrun.lua) against a fake surface: what collides and where,
-- tiles needing landfill or foundation (with the holes new foundation would
-- enclose on a platform), power islands by wire reach, and standing spots.
-- Real-engine check (shift world, read only, 2026-10-13): the module run
-- against nauvis and platform-1 named an existing drill, a fast underground
-- belt and a pole in footprints, a pole on water needing landfill 8.5 tiles
-- from the nearest built pole (wire reach 7.5), and on the platform 9 enclosed
-- tiles inside a planned ring and turret ghosts the engine takes over empty
-- space.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s, part) assert(type(s) == 'string' and s:find(part, 1, true), tostring(s)..' lacks '..part) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
defines = {build_check_type={manual=0, manual_ghost=1}, inventory={hub_main=1}}
local function mask(...) local l = {} for _, k in ipairs({...}) do l[k] = true end return {layers=l} end
local BUILDING = mask('object', 'water_tile', 'player', 'item')
prototypes = {tile={
  ['grass-1']={name='grass-1', collision_mask=mask('ground_tile'), items_to_place_this=nil},
  water={name='water', collision_mask=mask('water_tile', 'item', 'player', 'resource')},
  ['out-of-map']={name='out-of-map', collision_mask=mask('ground_tile', 'object', 'out_of_map', 'water_tile')},
  ['empty-space']={name='empty-space', collision_mask=mask('empty_space', 'ground_tile', 'object', 'water_tile', 'item')},
  ['space-platform-foundation']={name='space-platform-foundation', collision_mask=mask('ground_tile'), items_to_place_this={{name='space-platform-foundation', count=1}}},
  landfill={name='landfill', collision_mask=mask('ground_tile'), items_to_place_this={{name='landfill', count=1}}},
}}
local function box(h) return {left_top={x=-h, y=-h}, right_bottom={x=h, y=h}} end
prototypes.entity = {
  ['assembling-machine-1']={name='assembling-machine-1', type='assembling-machine', tile_width=3, tile_height=3, collision_box=box(1.2),
    collision_mask=BUILDING, electric_energy_source_prototype={}, items_to_place_this={{name='assembling-machine-1', count=1}}},
  ['assembling-machine-2']={name='assembling-machine-2', type='assembling-machine', tile_width=3, tile_height=3, collision_box=box(1.2),
    collision_mask=BUILDING, electric_energy_source_prototype={}, items_to_place_this={{name='assembling-machine-2', count=1}}},
  ['small-electric-pole']={name='small-electric-pole', type='electric-pole', tile_width=1, tile_height=1, collision_box=box(0.15),
    collision_mask=BUILDING, items_to_place_this={{name='small-electric-pole', count=1}},
    get_max_wire_distance=function() return 7.5 end, get_supply_area_distance=function() return 2.5 end},
  ['stone-furnace']={name='stone-furnace', type='furnace', tile_width=2, tile_height=2, collision_box=box(0.7), collision_mask=BUILDING,
    items_to_place_this={{name='stone-furnace', count=1}}},
  ['gun-turret']={name='gun-turret', type='ammo-turret', tile_width=2, tile_height=2, collision_box=box(0.7), collision_mask=BUILDING,
    items_to_place_this={{name='gun-turret', count=1}}},
  ['tree-01']={name='tree-01', type='tree', collision_mask=mask('object', 'player')},
  character={name='character', type='character', collision_box=box(0.2), collision_mask=mask('player')},
}
prototypes.item = {
  landfill={name='landfill', place_as_tile_result={result=prototypes.tile.landfill, condition=mask('ground_tile'), tile_condition={'water'}}},
  ['space-platform-foundation']={name='space-platform-foundation', place_as_tile_result={result=prototypes.tile['space-platform-foundation'],
    condition=mask('empty_space'), invert=true}},
}
local placewhy = dofile('mod/agent-harness_0.1.0/placewhy.lua'){}
local force = {name='player', recipes={landfill={enabled=true}, ['space-platform-foundation']={enabled=true}},
  is_chunk_charted=function(_, c) return c.x < 3 end}
local function dist(a, b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
-- A world: tiles(x, y) gives a tile name; entities carry position, name, type,
-- force and (for poles) electric_network_id.
local function world(tiles, entities, opts)
  opts = opts or {}
  local s = {platform=opts.platform}
  s.get_tile = function(x, y) local n = tiles(x, y); return {name=n, prototype=prototypes.tile[n]} end
  local function bbox(e)
    local proto = prototypes.entity[e.type == 'entity-ghost' and e.ghost_name or e.name]
    return placewhy.box_at(proto and proto.collision_box or box(0.4), e.position, e.direction or 0)
  end
  for _, e in ipairs(entities) do
    e.valid = true; e.force = e.force or force; e.prototype = e.prototype or prototypes.entity[e.name]
    e.bounding_box = bbox(e)
  end
  local function meets(a, b)
    return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y and b.left_top.y < a.right_bottom.y
  end
  s.find_entities_filtered = function(f)
    local out = {}
    for _, e in ipairs(entities) do
      local ok = true
      if f.area then
        local a = f.area
        local lt, rb = a.left_top or a[1], a.right_bottom or a[2]
        lt = {x=lt.x or lt[1], y=lt.y or lt[2]}; rb = {x=rb.x or rb[1], y=rb.y or rb[2]}
        ok = meets(e.bounding_box, {left_top=lt, right_bottom=rb})
      end
      if ok and f.position then ok = dist(e.position, f.position) <= (f.radius or 0.5) end
      if ok and f.type then
        local types = type(f.type) == 'table' and f.type or {f.type}
        local any = false
        for _, t in ipairs(types) do if e.type == t then any = true end end
        ok = any
      end
      if ok and f.ghost_type then ok = e.type == 'entity-ghost' and prototypes.entity[e.ghost_name].type == f.ghost_type end
      if ok and f.force then ok = e.force == f.force end
      if ok then out[#out+1] = e end
      if f.limit and #out >= f.limit then break end
    end
    return out
  end
  s.count_entities_filtered = function(f) return #s.find_entities_filtered(f) end
  -- The engine's check: entities whose masks meet, and the tiles (a ghost on
  -- a platform goes over empty space, as the shift world's engine allowed).
  s.can_place_entity = function(a)
    local proto = prototypes.entity[a.name]
    local b = placewhy.box_at(proto.collision_box or box(0.4), a.position, a.direction or 0)
    for _, e in ipairs(entities) do
      if e.type ~= 'entity-ghost' and meets(e.bounding_box, b) then
        for k in pairs(proto.collision_mask.layers) do
          if e.prototype.collision_mask.layers[k] and not (opts.replaces and opts.replaces[e.name] == a.name) then return false end
        end
      end
    end
    if a.build_check_type == defines.build_check_type.manual_ghost and s.platform then return true end
    for x = math.floor(b.left_top.x), math.ceil(b.right_bottom.x)-1 do
      for y = math.floor(b.left_top.y), math.ceil(b.right_bottom.y)-1 do
        for k in pairs(prototypes.tile[tiles(x, y)].collision_mask.layers) do
          if proto.collision_mask.layers[k] then return false end
        end
      end
    end
    return true
  end
  return s
end
local api = {placewhy=placewhy,
  charted=function(p, pos) return p.surface.platform ~= nil or p.force.is_chunk_charted(p.surface, {x=math.floor(pos.x/32), y=math.floor(pos.y/32)}) end,
  own_platform=function(p) return p.surface.platform ~= nil end,
  character_owner=function(e) return e.owner end,
  placement_error=function() return 'placement blocked (nothing found in the footprint)' end,
  crafting_count=function(_, item) return item == 'small-electric-pole' and 1 or 0 end}
local dryrun = dofile('mod/agent-harness_0.1.0/dryrun.lua')(api)

-- A planet: grass, a pond at x 18..21, y 8..11, the map's edge past x 60,
-- a built pole at (-4.5,0.5), a tree, a chest, sol's character.
local function planet(x, y)
  if x >= 60 then return 'out-of-map' end
  if x >= 18 and x <= 21 and y >= 8 and y <= 11 then return 'water' end
  return 'grass-1'
end
local me = {name='character', type='character', position={x=0, y=0}}
local stuff = {
  {name='small-electric-pole', type='electric-pole', position={x=-4.5, y=0.5}, electric_network_id=7},
  {name='tree-01', type='tree', position={x=-8, y=6}, minable=true, force={name='neutral'}},
  {name='assembling-machine-1', type='assembling-machine', position={x=-10.5, y=-6.5}},
  {name='character', type='character', position={x=0.5, y=-8.5}, owner='sol'},
  me,
}
local s = world(planet, stuff)
local held = {['assembling-machine-1']=1, ['small-electric-pole']=1}
local p = {surface=s, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end}
local out = dryrun.check(p, {kind='build', entities={
  {index=1, name='assembling-machine-1', position={x=5, y=0}, item='assembling-machine-1'},     -- free: snaps to (5.5,0.5)
  {index=2, name='small-electric-pole', position={x=2.5, y=0.5}, item='small-electric-pole'},  -- 7 tiles from the built pole
  {index=3, name='assembling-machine-1', position={x=6.5, y=1.5}, item='assembling-machine-1'},-- over #1
  {index=4, name='small-electric-pole', position={x=30.5, y=0.5}, item='small-electric-pole'}, -- far: an island, out of reach
  {index=5, name='stone-furnace', position={x=20, y=10}, item='stone-furnace'},                -- on the pond
  {index=6, name='gun-turret', position={x=-8, y=6}, item='gun-turret'},                       -- on the tree
  {index=7, name='stone-furnace', position={x=60, y=0}, item='stone-furnace'},                 -- past the map edge
  {index=8, name='assembling-machine-1', position={x=-10.5, y=-6.5}, item='assembling-machine-1'}, -- built there already
  {index=9, name='gun-turret', position={x=0, y=-8}, item='gun-turret'},                       -- on sol
  {index=10, name='assembling-machine-1', position={x=2.5, y=7.5}, item='assembling-machine-1'}, -- no pole near
  {index=11, name='stone-furnace', position={x=200, y=0}, item='stone-furnace'},               -- uncharted
}})
local rows = {}
for _, r in ipairs(out.entities) do rows[r.index] = r end
eq(rows[1], nil, 'a plain placeable entry gets no row')
eq(rows[3].status, 'blocked'); has(rows[3].why, 'collides with planned #1 assembling-machine-1 at (5.5,0.5)')
eq(rows[4].status, 'ok'); has(rows[4].reach, '30.5 tiles from you, reach 10')
eq(rows[5].status, 'needs_tiles'); has(rows[5].why, 'stands on 4 water tiles: needs 4 landfill first')
eq(rows[6].status, 'blocked'); has(rows[6].why, 'blocked by tree-01 (-8,6)')
eq(rows[7].status, 'blocked'); has(rows[7].why, '(60.5,-0.5) is outside the map')
eq(rows[8].status, 'exists'); has(rows[8].why, 'already built there')
eq(rows[9].status, 'blocked'); has(rows[9].why, "sol's character at (0.5,-8.5)")
eq(rows[11].status, 'blocked'); has(rows[11].why, 'outside the charted area (chunk 6,0)')
has(out.summary, '(of 11)')
eq(out.tiles.needed.landfill, 4); eq(out.tiles.under_entities, 4); eq(#out.tiles.positions, 4)
eq(out.tiles.positions[1].x, 19.5); eq(out.tiles.positions[1].y, 9.5)
-- Power: #2 reaches the built pole (7 tiles, wire 7.5); #4 is an island; #10 has no supply area over it.
eq(out.power.poles, 2)
has(out.power.connected[1], 'planned pole #2 reaches the built network of small-electric-pole (-4.5,0.5)')
has(out.power.islands[1], 'planned pole #4 at (30.5,0.5): no wire path to a built pole; nearest built pole small-electric-pole at (-4.5,0.5) is 35.0 tiles')
eq(#out.power.unpowered, 1); eq(out.power.unpowered[1].index, 10)
has(out.power.unpowered[1].why, "no pole's supply area reaches it; nearest pole small-electric-pole (planned) at (2.5,0.5)")
-- Reach: #4 and the pond furnace are out of reach; a spot reaches them.
eq(out.standing.reach, 10); has(out.standing.from_here, 'of 5 in reach from (0,0)')
assert(out.standing.spots and #out.standing.spots >= 1)
for _, sp in ipairs(out.standing.spots) do
  if sp.reaches:find('#4', 1, true) then assert(dist(sp.at, {x=30.5, y=0.5}) <= 9.5, 'spot reaches #4') end
end
-- Items against the inventory and the hand-craft queue.
eq(out.items['small-electric-pole'], 2); eq(out.items.landfill, 4)
eq(out.missing['assembling-machine-1'], 1, 'two placeable machines, one held'); eq(out.missing['small-electric-pole'], nil, 'one held, one being crafted')
eq(out.missing.landfill, 4); has(out.missing_from, 'hand-craft queue')

-- A build batch: the furnace on the pond, then the landfill under it (entry 2): the order shows.
local late = dryrun.check(p, {kind='build', entities={{index=1, name='stone-furnace', position={x=20, y=10}, item='stone-furnace'}},
  tiles={{index=2, name='landfill', item='landfill', position={x=19.5, y=9.5}}, {index=2, name='landfill', item='landfill', position={x=20.5, y=9.5}},
    {index=2, name='landfill', item='landfill', position={x=19.5, y=10.5}}, {index=2, name='landfill', item='landfill', position={x=20.5, y=10.5}}}})
eq(late.entities[1].status, 'after_tiles'); has(late.entities[1].why, 'entry #2 of this batch lays one of them, after this one')

-- Ghosts: a tree is marked, not a blocker; landfill planned under a furnace
-- on the pond makes it placeable after the tiles; landfill on grass is refused;
-- the engine's yes over a machine (an upgrade) stands.
local s2 = world(planet, stuff, {replaces={['assembling-machine-1']='assembling-machine-2'}})
local p2 = {surface=s2, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local fill = {}
for x = 19, 20 do for y = 9, 10 do fill[#fill+1] = {name='landfill', position={x=x+0.5, y=y+0.5}} end end
fill[#fill+1] = {name='landfill', position={x=0.5, y=5.5}}
local g = dryrun.check(p2, {kind='ghosts', standing=true, details=true, entities={
  {index=1, name='gun-turret', position={x=-8, y=6}},
  {index=2, name='stone-furnace', position={x=20, y=10}},
  {index=3, name='assembling-machine-2', position={x=-10.5, y=-6.5}},
}, tiles=fill})
local gr = {}
for _, r in ipairs(g.entities) do gr[r.index] = r end
eq(gr[1].status, 'ok'); has(gr[1].why, '1 tree/rock there get marked for removal')
eq(gr[1].footprint, '-9,5..-8,6', 'details: footprints')
eq(gr[2].status, 'after_tiles'); has(gr[2].why, 'placeable once the planned tiles under it are laid; the game refuses its ghost on the tiles there now, and place_ghosts places entity ghosts before tile ghosts')
eq(gr[3].status, 'ok'); has(gr[3].why, 'replaces assembling-machine-1 (-10.5,-6.5)')
eq(g.tiles.planned, 4); eq(g.tiles.refused, 1); has(g.tiles.refused_rows[1], '(0.5,5.5) landfill: landfill cannot go on grass-1')
eq(g.standing.reach, 10); eq(g.entities[1].reach, nil, 'ghosts: reach is no problem of the plan')

-- A platform: foundation x,y -5..5, the hub at 0,0. A planned ring of
-- foundation east of it (x 6..10, y -2..2) encloses 9 empty tiles; a tile at
-- (20,20) touches no foundation; a turret off the edge stands on empty space
-- (the engine takes its ghost there) and needs foundation.
local function deck(x, y) return (x >= -5 and x <= 5 and y >= -5 and y <= 5) and 'space-platform-foundation' or 'empty-space' end
local hub = {name='space-platform-hub', type='space-platform-hub', position={x=0, y=0}, valid=true}
local ps = world(deck, {}, {platform={hub=hub}})
ps.platform.hub.get_inventory = function() return {get_item_count=function(n) return n == 'space-platform-foundation' and 10 or 0 end} end
local pp = {surface=ps, force=force, position={x=0, y=0}}
local ring = {}
for x = 6, 10 do for y = -2, 2 do if not (x >= 7 and x <= 9 and y >= -1 and y <= 1) then ring[#ring+1] = {name='space-platform-foundation', position={x=x+0.5, y=y+0.5}} end end end
ring[#ring+1] = {name='space-platform-foundation', position={x=20.5, y=20.5}}
local pl = dryrun.check(pp, {kind='ghosts', entities={{index=1, name='gun-turret', position={x=0, y=-5}}}, tiles=ring})
eq(pl.entities[1].status, 'needs_tiles'); has(pl.entities[1].why, 'stands on 2 empty-space tiles: needs 2 space-platform-foundation first (its ghost goes there now')
eq(pl.tiles.holes, 9); eq(pl.tiles.under_entities, 2); eq(pl.tiles.planned, 17); eq(pl.tiles.needed['space-platform-foundation'], 11)
has(pl.tiles.holes_note, '9 empty tiles would be enclosed')
has(pl.tiles.not_connected, '1 new foundation tile touches no existing foundation')
has(pl.tiles.not_connected, '(20.5,20.5)')
eq(pl.standing, nil, 'the platform builds from its hub: no reach')
eq(pl.items['space-platform-foundation'], 28); eq(pl.missing['space-platform-foundation'], 18); eq(pl.missing_from, 'the hub')
-- A ring wider than the hole limit counts as open space, not a hole.
local wide = {}
for x = 6, 70 do wide[#wide+1] = {name='space-platform-foundation', position={x=x+0.5, y=-1.5}}; wide[#wide+1] = {name='space-platform-foundation', position={x=x+0.5, y=40.5}} end
for y = -1, 40 do wide[#wide+1] = {name='space-platform-foundation', position={x=70.5, y=y+0.5}} end
local open = dryrun.check(pp, {kind='ghosts', entities={}, tiles=wide})
eq(open.tiles.holes, nil, 'a region past the hole limit is open space')

-- Snapping, footprints and runs.
local snapped = dryrun.snap(prototypes.entity['assembling-machine-1'], {x=5, y=0}, 0)
eq(snapped.x, 5.5); eq(snapped.y, 0.5)
local f2 = dryrun.snap(prototypes.entity['stone-furnace'], {x=5.3, y=0.6}, 0)
eq(f2.x, 5); eq(f2.y, 1)
eq(dryrun.runs({7, 1, 2, 3, 9, 10}), '1-3,7,9-10')
eq(dryrun.placeable_on('landfill', 'water'), true); eq(dryrun.placeable_on('landfill', 'grass-1'), false)
eq(dryrun.placeable_on('space-platform-foundation', 'empty-space'), true); eq(dryrun.placeable_on('space-platform-foundation', 'grass-1'), false)

-- Rails (rail_route's dry run): 16 directions, a turned box per piece. Consecutive pieces of a curve meet at their
-- ends without colliding; tiles count only where the turned box reaches; a crossing rail is the game's call; a curve
-- takes 3 rails.
local RAIL_MASK = mask('rail', 'object', 'water_tile', 'item', 'is_lower_object', 'floor')
for _, n in ipairs({'straight-rail', 'half-diagonal-rail', 'curved-rail-a', 'curved-rail-b'}) do
  prototypes.entity[n] = {name=n, type=n, collision_box={left_top={x=-0.7, y=-1}, right_bottom={x=0.7, y=1}}, collision_mask=RAIL_MASK,
    items_to_place_this={{name='rail', count=(n == 'straight-rail' and 1 or n == 'half-diagonal-rail' and 2 or 3)}}}
end
local rails = dofile('mod/agent-harness_0.1.0/rails.lua'){}
local rapi = {}
for k, v in pairs(api) do rapi[k] = v end
rapi.rail_box = function(name, pos, dir) return rails.box(name, pos, dir) end
rapi.rail_overlaps = function(shape, l, t, r, b) return rails.overlaps(shape, l, t, r, b) end
local rdry = dofile('mod/agent-harness_0.1.0/dryrun.lua')(rapi)
-- A pond at x 10..13, y -20..-17; an east-west rail crossing at (1,-9).
local function field(x, y) if x >= 10 and x <= 13 and y >= -20 and y <= -17 then return 'water' end return 'grass-1' end
local crossing = {name='straight-rail', type='straight-rail', position={x=1, y=-9}, direction=4}
local rs = world(field, {crossing})
rs.can_place_entity = function() return true end
local rp = {surface=rs, force=force, position={x=0, y=0}, build_distance=10, character={name='character'},
  get_main_inventory=function() return {get_item_count=function() return 7 end} end}
-- From an end at (1,0) heading north: straight pieces, then curve a and curve b toward north-east (the game's pieces).
local plan, x, y, d, idx = {kind='ghosts', entities={}}, 1, 0, 0, 0
local function lay(i)
  local m = rails.EXT[d][i]
  idx = idx + 1
  plan.entities[#plan.entities+1] = {index=idx, name=m[1], position={x=x+m[3], y=y+m[4]}, direction=m[2]}
  x, y, d = x+m[5], y+m[6], m[7]
end
for _ = 1, 6 do lay(1) end -- straight north to (1,-12), over the crossing at (1,-9)
lay(3) -- curved-rail-a north -> north-north-east
lay(2) -- curved-rail-b north-north-east -> north-east
lay(1); lay(1) -- straight north-east
local out = rdry.check(rp, plan)
eq(out.summary, '10 placeable (of 10)', 'no false collisions between joined pieces or with the crossing')
eq(out.entities, nil)
eq(out.items.rail, 6+3+3+2)
eq(out.tiles, nil, 'the pond is clear of every turned box')
-- A straight piece through the pond needs landfill under it.
local wet = rdry.check(rp, {kind='ghosts', entities={{index=1, name='straight-rail', position={x=11, y=-19}, direction=0}}})
eq(wet.entities[1].status, 'needs_tiles'); has(wet.entities[1].why, 'stands on 4 water tiles: needs 4 landfill first')
-- A diagonal piece whose box around it reaches a pond tile its turned box does not touch.
local diag = rdry.check(rp, {kind='ghosts', entities={{index=1, name='straight-rail', position={x=8, y=-15}, direction=2}}})
eq(diag.summary, '1 placeable (of 1)', 'the corner tile is outside the turned box')
-- A build of a curve names the rail item: 3 of them.
local b3 = rdry.check(rp, {kind='build', entities={{index=1, name='curved-rail-a', position={x=1, y=-2}, direction=0, item='rail'}}})
eq(b3.items.rail, 3)
-- The same rail twice is a collision; other pieces at one spot (a crossing) are not.
local twice = rdry.check(rp, {kind='ghosts', entities={{index=1, name='straight-rail', position={x=1, y=-21}, direction=0},
  {index=2, name='straight-rail', position={x=1, y=-21}, direction=8}, {index=3, name='straight-rail', position={x=1, y=-21}, direction=4}}})
eq(twice.entities[1].status, 'blocked'); has(twice.entities[1].why, 'collides with planned #1')
eq(twice.summary, '2 placeable, 1 blocked (of 3)')
print('dryrun: ok')
