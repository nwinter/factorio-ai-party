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
  ['stone-wall']={name='stone-wall', type='wall', tile_width=1, tile_height=1, collision_box=box(0.49), collision_mask=BUILDING},
  inserter={name='inserter', type='inserter', tile_width=1, tile_height=1, collision_box=box(0.15), collision_mask=BUILDING,
    items_to_place_this={{name='inserter', count=1}}, inserter_pickup_position={0, -1}, inserter_drop_position={0, 1.2}},
  ['wooden-chest']={name='wooden-chest', type='container', tile_width=1, tile_height=1, collision_box=box(0.35), collision_mask=BUILDING,
    items_to_place_this={{name='wooden-chest', count=1}}},
  ['transport-belt']={name='transport-belt', type='transport-belt', tile_width=1, tile_height=1, collision_box=box(0.4),
    collision_mask=mask('object', 'transport_belt', 'water_tile'), items_to_place_this={{name='transport-belt', count=1}}},
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
    if e.type == 'entity-ghost' then e.ghost_prototype = prototypes.entity[e.ghost_name] end
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
      -- A position alone finds what its box holds, as the engine does.
      if ok and f.position and f.radius then ok = dist(e.position, f.position) <= f.radius
      elseif ok and f.position then
        local b = e.bounding_box
        ok = f.position.x >= b.left_top.x and f.position.x <= b.right_bottom.x and f.position.y >= b.left_top.y and f.position.y <= b.right_bottom.y
      end
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
    -- A tile ghost: refused where an entity not marked for deconstruction
    -- meets the tile and its mask meets the tile's (2.0.77: Gleba's slipstack
    -- has ground_tile; landfill is one), unless its prototype is not
    -- protected_from_tile_building (water-cane, fish); refused where a tile
    -- ghost stands already (one a tile).
    if a.name == 'tile-ghost' then
      local tl = prototypes.tile[a.inner_name].collision_mask.layers
      local x, y = math.floor(a.position.x), math.floor(a.position.y)
      for _, e in ipairs(entities) do
        if e.type == 'tile-ghost' then
          if math.floor(e.position.x) == x and math.floor(e.position.y) == y then return false end
        elseif e.type ~= 'entity-ghost' and not (e.marked) and e.prototype and e.prototype.protected_from_tile_building ~= false
          and meets(e.bounding_box, {left_top={x=x, y=y}, right_bottom={x=x+1, y=y+1}}) then
          for k in pairs(e.prototype.collision_mask.layers) do if tl[k] then return false end end
        end
      end
      return true
    end
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
eq(gr[1].status, 'ok'); has(gr[1].why, 'place_ghosts marks tree-01 (-8,6) for removal (construct mines trees and rocks)')
eq(gr[1].footprint, '-9,5..-8,6', 'details: footprints')
eq(gr[2].status, 'after_tiles'); has(gr[2].why, 'placeable once the tiles under it are laid; the game refuses its ghost on the tiles there now, and place_ghosts places entity ghosts before tile ghosts')
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
eq(pl.entities[1].status, 'needs_tiles'); has(pl.entities[1].why, 'stands on 2 empty-space tiles: needs 2 space-platform-foundation first (place_ghosts lays those tile ghosts under it first)')
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

-- A paste takes what its mode takes (review, 22:46): a normal paste is all or nothing and marks nothing, so a tree
-- blocks it; forced marks trees and rocks; superforced our own entities too.
local tree_world = world(planet, {{name='tree-01', type='tree', position={x=5.5, y=0.5}, minable=true, force={name='neutral'}},
  {name='stone-furnace', type='furnace', position={x=12, y=0}, minable=true}, me})
local tp = {surface=tree_world, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local function paste(mode, name, pos)
  local o, recs, c = dryrun.check(tp, {kind='paste', mode=mode, entities={{index=1, name=name, position=pos}}})
  return recs[1], c, o
end
local r1, c1 = paste('normal', 'assembling-machine-1', {x=5.5, y=0.5})
eq(r1.status, 'blocked'); has(r1.why, 'blocked by tree-01 (5.5,0.5)'); eq(c1.refused_now, 1)
local r2, c2 = paste('forced', 'assembling-machine-1', {x=5.5, y=0.5})
eq(r2.status, 'ok'); has(r2.note, 'the paste marks tree-01 (5.5,0.5) for removal'); eq(c2.refused_now, nil)
local r3 = paste('forced', 'gun-turret', {x=12, y=0})
eq(r3.status, 'blocked', 'forced does not take our own entities'); has(r3.why, 'stone-furnace (12,0)')
local r4 = paste('superforced', 'gun-turret', {x=12, y=0})
eq(r4.status, 'ok'); has(r4.note, 'the paste marks stone-furnace (12,0) for removal')

-- Rails cross rails, and a signal beside a planned rail waits for it (review: signalled rail blueprints read blocked).
prototypes.entity['straight-rail'] = {name='straight-rail', type='straight-rail', tile_width=2, tile_height=2, collision_box=box(0.7),
  collision_mask=mask('object', 'rail', 'water_tile'), items_to_place_this={{name='rail', count=1}}}
prototypes.entity['rail-signal'] = {name='rail-signal', type='rail-signal', tile_width=1, tile_height=1, collision_box=box(0.2),
  collision_mask=mask('object', 'rail', 'water_tile'), items_to_place_this={{name='rail-signal', count=1}}}
local rail_world = world(planet, {me})
local engine = rail_world.can_place_entity
rail_world.can_place_entity = function(a) if a.name == 'rail-signal' then return false end return engine(a) end
local rp = {surface=rail_world, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local ro, rrecs, rc = dryrun.check(rp, {kind='paste', entities={{index=1, name='straight-rail', position={x=4, y=0}},
  {index=2, name='straight-rail', position={x=4, y=0}, direction=4}, {index=3, name='rail-signal', position={x=5.5, y=-1.5}}}})
eq(rrecs[2].status, 'ok', 'a crossing rail is no collision'); eq(rrecs[3].status, 'after_rails'); has(rrecs[3].note, "goes with the plan's rails")
eq(rc.refused_now, nil, 'no all-or-nothing note for a signalled rail paste'); has(ro.summary, "1 with the plan's rails")
local alone = select(2, dryrun.check(rp, {kind='ghosts', entities={{index=1, name='rail-signal', position={x=5.5, y=-1.5}}}}))
eq(alone[1].status, 'blocked', 'without planned rails the game refuses it')

-- Pole ghosts already ordered join too (review: a planned pole 7 tiles from a pole ghost 7 tiles from a built pole),
-- said as a path that waits for them (Astra, shift10: power only once the ghosts stand).
local chain_world = world(planet, {{name='small-electric-pole', type='electric-pole', position={x=-4.5, y=0.5}, electric_network_id=3},
  {name='entity-ghost', type='entity-ghost', ghost_name='small-electric-pole', position={x=2.5, y=0.5}}, me})
local cp = {surface=chain_world, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local co = dryrun.check(cp, {kind='ghosts', entities={{index=1, name='small-electric-pole', position={x=9.5, y=0.5}}}})
eq(co.power.islands, nil)
eq(co.power.connected[1], 'planned pole #1 reaches a built network only through pole ghosts not built yet (small-electric-pole (2.5,0.5)): '
  ..'no wire path to a built pole until they stand; nearest built pole small-electric-pole at (-4.5,0.5) is 14.0 tiles from (9.5,0.5) (wire reach 7.5)')

-- Tile ghosts already ordered count as tiles to come: a furnace on the pond over landfill ghosts is placeable after
-- them, and a platform ring closed by foundation ghosts encloses no hole they already fill.
local pond_world = world(planet, {{name='tile-ghost', type='tile-ghost', ghost_name='landfill', position={x=19.5, y=9.5}},
  {name='tile-ghost', type='tile-ghost', ghost_name='landfill', position={x=20.5, y=9.5}},
  {name='tile-ghost', type='tile-ghost', ghost_name='landfill', position={x=19.5, y=10.5}},
  {name='tile-ghost', type='tile-ghost', ghost_name='landfill', position={x=20.5, y=10.5}}, me})
local pdp = {surface=pond_world, force=force, position={x=15, y=10}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local pr = select(2, dryrun.check(pdp, {kind='paste', entities={{index=1, name='stone-furnace', position={x=20, y=10}}}}))
eq(pr[1].status, 'after_tiles')
local hole_ghosts = {}
for x = 7, 9 do for y = -1, 1 do hole_ghosts[#hole_ghosts+1] = {name='tile-ghost', type='tile-ghost', ghost_name='space-platform-foundation', position={x=x+0.5, y=y+0.5}} end end
local ps2 = world(deck, hole_ghosts, {platform={hub=hub}})
local pl2 = dryrun.check({surface=ps2, force=force, position={x=0, y=0}}, {kind='ghosts', entities={}, tiles=ring})
eq(pl2.tiles.holes, nil, 'the hole is ordered already')
-- A tile ghost past the box the dry run reads (Astra, shift12 12:41: a hole named where a tile ghost stood): a channel
-- of empty space 60 tiles long that the plan closes at its mouth, with a tile ghost 55 tiles in. The flood stops at
-- it: 54 tiles, not 60.
local function channel(x, y)
  if x >= -5 and x <= 60 and y >= -3 and y <= 3 and not (y == 0 and x <= 55) then return 'space-platform-foundation' end
  return 'empty-space'
end
local ps3 = world(channel, {{name='tile-ghost', type='tile-ghost', ghost_name='space-platform-foundation', position={x=50.5, y=0.5}}},
  {platform={hub=hub}})
local pl3 = dryrun.check({surface=ps3, force=force, position={x=0, y=0}}, {kind='ghosts', entities={},
  tiles={{name='space-platform-foundation', position={x=-4.5, y=0.5}}}})
eq(pl3.tiles.holes, 54, 'the ghost 55 tiles in fills its tile')

-- A build batch names the entry it stops at (review: exists, out of reach and late tiles never counted).
local _, _, bc = dryrun.check(p, {kind='build', entities={
  {index=1, name='small-electric-pole', position={x=2.5, y=0.5}, item='small-electric-pole'},
  {index=2, name='assembling-machine-1', position={x=-10.5, y=-6.5}, item='assembling-machine-1'},
  {index=3, name='small-electric-pole', position={x=30.5, y=0.5}, item='small-electric-pole'}}})
eq(bc.fail_first, 2); eq(bc.fail_why, 'target already contains this entity')
local _, _, bc2 = dryrun.check(p, {kind='build', entities={{index=1, name='small-electric-pole', position={x=30.5, y=0.5}, item='small-electric-pole'}}})
eq(bc2.fail_first, 1); has(bc2.fail_why, 'out of reach: 30.5 tiles from you, reach 10')
local _, _, bc3 = dryrun.check(p, {kind='build', entities={}, tiles={{index=1, name='landfill', item='landfill', position={x=0.5, y=5.5}}}})
eq(bc3.fail_first, 1); eq(bc3.fail_why, 'no tile of its brush can be laid there: landfill cannot go on grass-1', 'the first tile says why')

-- Bounded work (review: 2048 entries over water took 9 s in standing spots): every entry out of reach over a lake,
-- no free spot near any, standing gives up after a bounded number of looks.
local function lake(x, y) if x >= 30 then return 'water' end return 'grass-1' end
local lake_world = world(lake, {me})
local lp = {surface=lake_world, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local many = {}
for i = 0, 1023 do many[#many+1] = {index=i+1, name='stone-furnace', position={x=60+2*(i % 32), y=2*math.floor(i/32)}} end
local t0 = os.clock()
local lo2 = dryrun.check(lp, {kind='ghosts', standing=true, entities=many})
local spent = os.clock()-t0
assert(spent < 1.5, string.format('1024 entries over water took %.2f s', spent))
has(lo2.standing.no_spot, 'no free spot within reach of'); assert(lo2.standing.more, 'the rest are counted')

-- Snapping, footprints and runs.
local snapped = dryrun.snap(prototypes.entity['assembling-machine-1'], {x=5, y=0}, 0)
eq(snapped.x, 5.5); eq(snapped.y, 0.5)
local f2 = dryrun.snap(prototypes.entity['stone-furnace'], {x=5.3, y=0.6}, 0)
eq(f2.x, 5); eq(f2.y, 1)
eq(dryrun.runs({7, 1, 2, 3, 9, 10}), '1-3,7,9-10')

-- Each planned inserter's pickup and drop target (targets.lua; Astra's bypass
-- inserter that reached no crusher): one between a chest planned in the same
-- call and a built belt; one facing east with nothing on either point; one
-- between a chest ghost and a built wall, which takes no items.
do
  local targets = dofile('mod/agent-harness_0.1.0/targets.lua'){}
  local api2 = {}
  for k, v in pairs(api) do api2[k] = v end
  api2.targets = targets
  local dr = dofile('mod/agent-harness_0.1.0/dryrun.lua')(api2)
  local site = world(planet, {
    {name='transport-belt', type='transport-belt', position={x=2.5, y=22.5}},
    {name='entity-ghost', type='entity-ghost', ghost_name='wooden-chest', ghost_type='container', position={x=10.5, y=20.5}},
    {name='stone-wall', type='wall', position={x=10.5, y=22.5}},
    {name='small-electric-pole', type='electric-pole', position={x=14.5, y=22.5}},
  })
  local q = {surface=site, force=force, position={x=0, y=20}}
  local r = dr.check(q, {kind='ghosts', entities={
    {index=1, name='wooden-chest', position={x=2.5, y=20.5}},
    {index=2, name='inserter', position={x=2.5, y=21.5}},
    {index=3, name='inserter', position={x=6.5, y=21.5}, direction=4},
    {index=4, name='inserter', position={x=10.5, y=21.5}}}})
  eq(#r.inserters, 3); eq(r.inserters_without_target, 2)
  local a, b, c = r.inserters[1], r.inserters[2], r.inserters[3]
  eq(a.index, 2); eq(a.pickup, 'planned wooden-chest (2.5,20.5)'); eq(a.drop, 'transport-belt (2.5,22.5)'); eq(a.missing, nil)
  eq(b.direction, 'east'); eq(b.pickup, 'none: the ground at (7.5,21.5)'); eq(b.drop, 'none: the ground at (5.5,21.5)')
  eq(b.missing, 'no pickup target, no drop target')
  eq(c.pickup, 'ghost wooden-chest (10.5,20.5)'); eq(c.drop, 'none: stone-wall at (10.5,22.5) takes no items'); eq(c.missing, 'no drop target')
  -- On a platform: a drop point over empty space says so.
  local deck = world(function(x, y) return (x >= 0 and x <= 3) and 'space-platform-foundation' or 'empty-space' end, {}, {platform={name='deck'}})
  local d = dr.check({surface=deck, force=force, position={x=0, y=0}}, {kind='ghosts', entities={{index=1, name='inserter', position={x=3.5, y=0.5}, direction=4}}})
  eq(d.inserters[1].pickup, 'none: empty space at (4.5,0.5)'); eq(d.inserters[1].drop, 'none: the ground at (2.5,0.5)')
  -- Each planned belt: the tile its items move to and what stands there (Grok, shift13: three belts of a batch faced
  -- south, +y, away from the drop belt). A planned belt there, a built one, or nothing.
  local lane = world(planet, {{name='transport-belt', type='transport-belt', position={x=20.5, y=30.5}, direction=12}})
  local b = dr.check({surface=lane, force=force, position={x=20, y=25}}, {kind='build', entities={
    {index=1, name='transport-belt', position={x=20.5, y=27.5}, direction=8},
    {index=2, name='transport-belt', position={x=20.5, y=28.5}, direction=8},
    {index=3, name='transport-belt', position={x=20.5, y=29.5}, direction=8},
    {index=4, name='transport-belt', position={x=24.5, y=27.5}, direction=0}}})
  eq(#b.belts, 4)
  eq(b.belts[1].index, 1); eq(b.belts[1].moves, 'moves items south to (20.5,28.5): planned #2 transport-belt facing south')
  eq(b.belts[3].moves, 'moves items south to (20.5,30.5): transport-belt (20.5,30.5) facing west')
  eq(b.belts[4].moves, 'moves items north to (24.5,26.5): nothing there (no belt takes them there: they stop at its end)')
end
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
-- A signal planned with the rails waits for them (the game takes a signal only beside a rail).
prototypes.entity['rail-signal'] = {name='rail-signal', type='rail-signal', collision_box=box(0.2), collision_mask=mask('object'),
  items_to_place_this={{name='rail-signal', count=1}}}
rs.can_place_entity = function(a) return a.name ~= 'rail-signal' end
local withsig = rdry.check(rp, {kind='ghosts', entities={{index=1, name='straight-rail', position={x=31, y=-21}, direction=0},
  {index=2, name='rail-signal', position={x=32.5, y=-21.5}, direction=8}}})
eq(withsig.summary, '1 placeable, 1 with the plan\'s rails (of 2)')
rs.can_place_entity = function() return true end
-- A build of a curve names the rail item: 3 of them.
local b3 = rdry.check(rp, {kind='build', entities={{index=1, name='curved-rail-a', position={x=1, y=-2}, direction=0, item='rail'}}})
eq(b3.items.rail, 3)
-- The same rail twice is a collision; other pieces at one spot (a crossing) are not.
local twice = rdry.check(rp, {kind='ghosts', entities={{index=1, name='straight-rail', position={x=1, y=-21}, direction=0},
  {index=2, name='straight-rail', position={x=1, y=-21}, direction=8}, {index=3, name='straight-rail', position={x=1, y=-21}, direction=4}}})
eq(twice.entities[1].status, 'blocked'); has(twice.entities[1].why, 'collides with planned #1')
eq(twice.summary, '2 placeable, 1 blocked (of 3)')
-- Closing the character in (Gemini, shift09). Walls and pipes stretch their
-- box toward what they join (2.0.77: 0.289 lone, 0.488 toward a joined
-- neighbour), so pieces for the planned ones join them (joined_pieces).
local function lone(h) return {left_top={x=-h, y=-h}, right_bottom={x=h, y=h}} end
prototypes.entity.pipe = {name='pipe', type='pipe', tile_width=1, tile_height=1, collision_box=lone(0.289), collision_mask=BUILDING,
  items_to_place_this={{name='pipe', count=1}}}
prototypes.entity['pipe-to-ground'] = {name='pipe-to-ground', type='pipe-to-ground', tile_width=1, tile_height=1,
  collision_box={left_top={x=-0.289, y=-0.289}, right_bottom={x=0.289, y=0.2}}, collision_mask=BUILDING}
prototypes.entity.wall = {name='wall', type='wall', tile_width=1, tile_height=1, collision_box=lone(0.289), collision_mask=BUILDING,
  items_to_place_this={{name='wall', count=1}}}
prototypes.entity.gate = {name='gate', type='gate', tile_width=1, tile_height=1, collision_box=lone(0.289), collision_mask=BUILDING}
prototypes.entity.boiler = {name='boiler', type='boiler', tile_width=3, tile_height=2, collision_box={left_top={x=-1.29, y=-0.79}, right_bottom={x=1.29, y=0.79}}, collision_mask=BUILDING}
local function rec(name, x, y, dir)
  local proto = prototypes.entity[name]
  local b = placewhy.box_at(proto.collision_box, {x=x, y=y}, dir or 0)
  return {name=name, proto=proto, pos={x=x, y=y}, dir=dir or 0, box=b}
end
local jw = world(function() return 'grass-1' end, {
  {name='wall', type='wall', position={x=10.5, y=0.5}},
  {name='gate', type='gate', position={x=12.5, y=0.5}, direction=4},
  {name='pipe-to-ground', type='pipe-to-ground', position={x=20.5, y=0.5}, direction=4},
  {name='boiler', type='boiler', position={x=31.5, y=1}, fluidbox=setmetatable({get_pipe_connections=function()
    return {{position={x=29.5+1, y=1.5}, target_position={x=29.5, y=1.5}, connection_type='normal'}} end}, {__len=function() return 1 end})},
})
-- Two planned pipes side by side: each stretches toward the other while both stand.
local p1, p2 = rec('pipe', 0.5, 0.5), rec('pipe', 1.5, 0.5)
local pieces = dryrun.joined_pieces(jw, force, {p1, p2})
eq(#pieces, 2); eq(pieces[1].ids[1] == p1 or pieces[1].ids[1] == p2, true); eq(#pieces[1].ids, 2)
-- A planned wall beside a built wall: its own side, and the built one's toward it.
local w1 = rec('wall', 11.5, 0.5)
pieces = dryrun.joined_pieces(jw, force, {w1})
eq(#pieces, 3, 'west to the built wall (2 pieces), east to the gate in its line (1: the gate opens)')
local west, built_side
for _, piece in ipairs(pieces) do
  if piece[1] > 11 and piece[3] < 11.3 then west = piece end
  if piece[3] < 11 then built_side = piece end
end
eq(west[1], 11.5-0.488); eq(west[3], 11.5-0.289); eq(#west.ids, 1)
eq(built_side[1], 10.5+0.289, 'the built wall stretches east once the planned one stands'); eq(built_side[3], 10.5+0.488)
-- A planned gate makes no pieces of its own (it opens for the character).
eq(#dryrun.joined_pieces(jw, force, {rec('gate', 14.5, 5.5, 4)}), 0)
-- A pipe-to-ground joins on its open side only (its direction, 2.0.77): the built one opens east.
eq(#dryrun.joined_pieces(jw, force, {rec('pipe', 19.5, 0.5)}), 0, 'west of it is its underground side')
eq(#dryrun.joined_pieces(jw, force, {rec('pipe', 21.5, 0.5)}), 2, 'east: the pipe and the pipe-to-ground stretch')
-- A built machine's fluid connection on the tile: the pipe stretches toward it.
pieces = dryrun.joined_pieces(jw, force, {rec('pipe', 29.5, 1.5)})
eq(#pieces, 1); eq(pieces[1][1], 29.5+0.289); eq(pieces[1][3], 29.5+0.488)
-- The dry run: a ring of 16 pipes around the character closes it in; a ring with a gap does not.
local ring_me = {name='character', type='character', position={x=50.5, y=50.5}, prototype=prototypes.entity.character}
local rw = world(function() return 'grass-1' end, {ring_me})
local rapi2 = {}
for k, v in pairs(api) do rapi2[k] = v end
rapi2.pathing = dofile('mod/agent-harness_0.1.0/pathing.lua'){paths=function() return {} end}
local rdr = dofile('mod/agent-harness_0.1.0/dryrun.lua')(rapi2)
local rme = {surface=rw, force=force, position=ring_me.position, character=ring_me, build_distance=10,
  get_main_inventory=function() return {get_item_count=function() return 100 end} end}
local function ring(skip)
  local list = {}
  for x = 48.5, 52.5 do for y = 48.5, 52.5 do
    if (x == 48.5 or x == 52.5 or y == 48.5 or y == 52.5) and not (skip and x == skip.x and y == skip.y) then
      list[#list+1] = {index=#list+1, name='pipe', position={x=x, y=y}, direction=0, item='pipe'}
    end
  end end
  return list
end
local closed = rdr.check(rme, {kind='build', entities=ring()})
has(closed.closes_in, 'placed, these close the character in where it stands (50.5,50.5): without any one of #1 pipe (48.5,48.5)')
has(closed.closes_in, '(of 16 planned entries around it) a gap out stays; the area (49,49)-(52,52) (about 11 tiles)')
eq(rdr.check(rme, {kind='build', entities=ring({x=52.5, y=50.5})}).closes_in, nil, 'one gap left')
-- Built ring with one gap (stretched as built), the last pipe planned: it fills the last gap out.
local built_ring = {ring_me}
for _, e in ipairs(ring({x=52.5, y=50.5})) do built_ring[#built_ring+1] = {name='pipe', type='pipe', position=e.position} end
local bw = world(function() return 'grass-1' end, built_ring)
for _, e in ipairs(built_ring) do if e.type == 'pipe' then e.bounding_box = {left_top={x=e.position.x-0.488, y=e.position.y-0.488}, right_bottom={x=e.position.x+0.488, y=e.position.y+0.488}} end end
rme.surface = bw
local last = rdr.check(rme, {kind='build', entities={{index=1, name='pipe', position={x=52.5, y=50.5}, direction=0, item='pipe'}}})
eq(last.closes_in, 'placed, these close the character in where it stands (50.5,50.5): the last gap out is where #1 pipe (52.5,50.5) goes; the area (49.3,49.3)-(52,51.8) (about 8 tiles) has no gap the character (0.4 tiles wide) fits through; around it: pipe')
-- A far pipe planned while the gap is open: nothing said.
eq(rdr.check(rme, {kind='build', entities={{index=1, name='pipe', position={x=60.5, y=50.5}, direction=0, item='pipe'}}}).closes_in, nil)
-- Closed in already (the last pipe built): said as a fact of where it stands, nothing blamed on the plan.
local lastpipe = {name='pipe', type='pipe', position={x=52.5, y=50.5}}
built_ring[#built_ring+1] = lastpipe
rme.surface = world(function() return 'grass-1' end, built_ring)
for _, e in ipairs(built_ring) do if e.type == 'pipe' then e.bounding_box = {left_top={x=e.position.x-0.488, y=e.position.y-0.488}, right_bottom={x=e.position.x+0.488, y=e.position.y+0.488}} end end
local shut = rdr.check(rme, {kind='build', entities={{index=1, name='pipe', position={x=60.5, y=50.5}, direction=0, item='pipe'}}})
eq(shut.closes_in, nil); has(shut.closed_in, 'the character is closed in already where it stands (50.5,50.5): the area')
-- Logistic chests no roboport covers (Sonnet, shift10) and entrances fed from the side (Sol, shift10).
prototypes.entity['requester-chest'] = {name='requester-chest', type='logistic-container', tile_width=1, tile_height=1, collision_box=box(0.35),
  collision_mask=BUILDING, items_to_place_this={{name='requester-chest', count=1}}}
prototypes.entity.roboport = {name='roboport', type='roboport', tile_width=4, tile_height=4, collision_box=box(1.7), collision_mask=BUILDING,
  logistic_radius=25, items_to_place_this={{name='roboport', count=1}}}
prototypes.entity['underground-belt'] = {name='underground-belt', type='underground-belt', tile_width=1, tile_height=1, collision_box=box(0.4),
  collision_mask=mask('object', 'transport_belt', 'water_tile'), max_underground_distance=5, items_to_place_this={{name='underground-belt', count=1}}}
local capi = {}
for k, v in pairs(api) do capi[k] = v end
capi.targets = dofile('mod/agent-harness_0.1.0/targets.lua'){}
capi.sidefeed = dofile('mod/agent-harness_0.1.0/sidefeed.lua'){try=function(fn) local ok, v = pcall(fn); if ok then return v end end}
capi.coverage = function(_, _, pos, planned)
  for _, r in ipairs(planned or {}) do if math.abs(pos.x-r.x) <= r.r and math.abs(pos.y-r.y) <= r.r then return nil end end
  return 'outside logistic coverage: no roboport of ours within 200 tiles'
end
local cdr = dofile('mod/agent-harness_0.1.0/dryrun.lua')(capi)
local cme = {name='character', type='character', position={x=0.5, y=80.5}, prototype=prototypes.entity.character}
local built_ins = {name='inserter', type='inserter', position={x=1.5, y=90.5}, direction=4, drop_position={x=0.3, y=90.5}}
local cw = world(function() return 'grass-1' end, {cme, built_ins})
local cp = {surface=cw, force=force, position=cme.position, character=cme, build_distance=30,
  get_main_inventory=function() return {get_item_count=function() return 100 end} end}
local function entry(i, name, x, y, dir, t) return {index=i, name=name, position={x=x, y=y}, direction=dir or 0, item=name, ug_type=t} end
local cov = cdr.check(cp, {kind='build', entities={entry(1, 'requester-chest', 5.5, 85.5)}})
eq(cov.outside_logistic_coverage[1], '#1 requester-chest (5.5,85.5): outside logistic coverage: no roboport of ours within 200 tiles')
eq(cdr.check(cp, {kind='build', entities={entry(1, 'roboport', 10, 90), entry(2, 'requester-chest', 5.5, 85.5)}}).outside_logistic_coverage, nil,
  'the roboport planned with it covers it')
-- An entrance flowing north at (6.5,84.5); an inserter east of it dropping west; a belt from the west.
local side = cdr.check(cp, {kind='build', entities={entry(1, 'underground-belt', 6.5, 84.5, 0, 'input'), entry(2, 'inserter', 7.5, 84.5, 4),
  entry(3, 'transport-belt', 5.5, 84.5, 4)}})
eq(side.underground_side_feed[1], '#2 inserter (7.5,84.5) drops onto underground-belt (6.5,84.5), an entrance flowing north, from its east side: only its west (left) lane gets these items; its east (right) lane gets none from it')
eq(side.underground_side_feed[2], '#3 transport-belt (5.5,84.5) side-loads underground-belt (6.5,84.5), an entrance flowing north, from its west side: only the belt\'s north (left) lane goes in; its south (right) lane stops at the entrance')
-- An exit there: nothing. A build's undergrounds without type: the downstream one of a pair is the exit.
eq(cdr.check(cp, {kind='build', entities={entry(1, 'underground-belt', 6.5, 84.5, 0, 'output'), entry(2, 'inserter', 7.5, 84.5, 4)}}).underground_side_feed, nil)
local pair = cdr.check(cp, {kind='build', entities={entry(1, 'underground-belt', 6.5, 84.5, 0), entry(2, 'underground-belt', 6.5, 81.5, 0),
  entry(3, 'inserter', 7.5, 81.5, 4), entry(4, 'inserter', 7.5, 84.5, 4)}})
eq(#pair.underground_side_feed, 1); eq(pair.underground_side_feed[1]:match('^#4 inserter') ~= nil, true, 'only the entrance')
-- A planned entrance beside a built inserter dropping onto its tile.
local beside = cdr.check(cp, {kind='ghosts', entities={entry(1, 'underground-belt', 0.5, 90.5, 0)}})
eq(beside.underground_side_feed[1], 'inserter (1.5,90.5) drops onto underground-belt (0.5,90.5), an entrance flowing north, from its east side: only its west (left) lane gets these items; its east (right) lane gets none from it',
  'a ghost underground without type is an entrance')
-- Tiles blocked by what stands on them (Sol, shift10: a slipstack on Gleba wetland kept landfill from three belt
-- tiles; mined, they went in). A slipstack on water here: its mask has ground_tile, as landfill's does.
prototypes.entity.slipstack = {name='slipstack', type='tree', collision_box={left_top={x=-1.2, y=-1.2}, right_bottom={x=1.2, y=1.2}},
  collision_mask=mask('object', 'player', 'ground_tile', 'is_object')}
prototypes.tile.landfill.collision_mask = mask('ground_tile')
local tree = {name='slipstack', type='tree', position={x=50.06, y=50.06}, minable=true, force={name='neutral'}}
tree.to_be_deconstructed = function() return tree.marked == true end
local wme = {name='character', type='character', position={x=46.5, y=46.5}, prototype=prototypes.entity.character}
local ww = world(function(x, y) return (x >= 48 and x <= 52 and y >= 48 and y <= 52) and 'water' or 'grass-1' end, {wme, tree})
local wp = {surface=ww, force=force, position=wme.position, character=wme, build_distance=30,
  get_main_inventory=function() return {get_item_count=function() return 100 end} end}
local b1 = dryrun.tile_blockers(ww, force, 'landfill', 50, 50)
eq(#b1, 1); eq(b1[1].obstacle, true); eq(b1[1].text, 'slipstack tree at (50.1,50.1): mine it first')
eq(dryrun.tile_blockers(ww, force, 'landfill', 52, 52), nil, 'off the tree: the engine takes it')
-- A hand build: the landfill its belt needs is blocked by the tree.
local hand = dryrun.check(wp, {kind='build', entities={{index=1, name='transport-belt', position={x=50.5, y=50.5}, direction=0, item='transport-belt'}}})
eq(hand.entities[1].status, 'blocked'); has(hand.entities[1].why, 'blocked by slipstack tree at (50.1,50.1): mine it first (where its landfill goes)')
-- place_ghosts marks the tree first: the entry needs tiles, and the note says it marks it.
local gh = dryrun.check(wp, {kind='ghosts', entities={{index=1, name='transport-belt', position={x=50.5, y=50.5}, direction=0}}})
eq(gh.entities[1].status, 'needs_tiles'); has(gh.entities[1].why, 'place_ghosts marks slipstack (50.06,50.06) for removal (construct')
-- Explicit landfill tiles: a hand build's brush is refused naming the tree; place_ghosts marks it.
local brush = dryrun.check(wp, {kind='build', entities={}, tiles={{index=1, name='landfill', item='landfill', position={x=50.5, y=50.5}}}})
eq(brush.tiles.refused_rows[1], '(50.5,50.5) landfill: blocked by slipstack tree at (50.1,50.1): mine it first')
local marks = dryrun.check(wp, {kind='ghosts', entities={}, tiles={{index=1, name='landfill', position={x=50.5, y=50.5}}}})
eq(marks.tiles.refused, nil); eq(marks.tiles.marks, 'place_ghosts marks slipstack (50.1,50.1) for removal first, where its tile ghosts go (construct mines trees and rocks)')
-- Marked already: nothing in the way.
tree.marked = true
eq(dryrun.tile_blockers(ww, force, 'landfill', 50, 50), nil)
tree.marked = nil
-- Sol, shift12 12:55: on Gleba a roboport dry run at (67,44) said the wetland tile at (68.5,45.5) needs landfill, and
-- landfill there kept failing with "no tile was placed (blocked or already there)": a water-cane stood on the tile.
-- 2.0.77 on a private copy of world n: water-cane has ground_tile in its mask, as landfill has, but is not
-- protected_from_tile_building; the tile ghost check takes landfill over it and robots laid it, the cane gone.
-- Slipstack, cuttlepop, hairyclubnub and the stromatolites are protected: they block, marked or not (set_tiles refused
-- landfill under a marked hairyclubnub). Landfill goes on water and wetland only (its tile_condition), not on lava.
;(function()
  local saved = prototypes.item.landfill.place_as_tile_result.tile_condition
  prototypes.item.landfill.place_as_tile_result.tile_condition = {'water', 'wetland-light-dead-skin'}
  prototypes.tile.lava = {name='lava', collision_mask=mask('water_tile', 'lava_tile', 'player', 'item')}
  prototypes.tile['wetland-light-dead-skin'] = {name='wetland-light-dead-skin', collision_mask=mask('water_tile', 'resource', 'floor')}
  prototypes.tile.foundation = {name='foundation', collision_mask=mask('ground_tile'), items_to_place_this={{name='foundation', count=1}}}
  prototypes.item.foundation = {name='foundation', place_as_tile_result={result=prototypes.tile.foundation, condition=mask(),
    tile_condition={'water', 'lava', 'wetland-light-dead-skin'}}}
  prototypes.entity['water-cane'] = {name='water-cane', type='tree', collision_box=box(0.1),
    collision_mask=mask('ground_tile', 'is_object', 'is_lower_object', 'train'), protected_from_tile_building=false}
  prototypes.entity['iron-stromatolite'] = {name='iron-stromatolite', type='simple-entity', collision_box=box(0.5),
    collision_mask=mask('ground_tile', 'is_object', 'is_lower_object', 'player', 'train')}
  local dr = dofile('mod/agent-harness_0.1.0/dryrun.lua')(api)
  local function gleba(x, y)
    if x >= 64 and x <= 65 and y >= 60 and y <= 61 then return 'lava' end
    if x >= 58 and x <= 63 and y >= 58 and y <= 64 then return 'wetland-light-dead-skin' end
    return 'grass-1'
  end
  local cane = {name='water-cane', type='tree', position={x=61.75, y=61.75}, minable=true, force={name='neutral'}}
  local cane2 = {name='water-cane', type='tree', position={x=63.25, y=58.25}, minable=true, force={name='neutral'}}
  local rock = {name='iron-stromatolite', type='simple-entity', position={x=62.5, y=63.5}, minable=true, force={name='neutral'}}
  rock.to_be_deconstructed = function() return rock.marked == true end
  local ghost = {name='tile-ghost', type='tile-ghost', ghost_name='landfill', position={x=63.5, y=58.5}}
  local gme = {name='character', type='character', position={x=57.5, y=57.5}, prototype=prototypes.entity.character}
  local gs = world(gleba, {gme, cane, cane2, rock, ghost})
  local gp = {surface=gs, force=force, position=gme.position, character=gme, build_distance=30,
    get_main_inventory=function() return {get_item_count=function() return 100 end} end}
  -- The cane goes with the tile; the stromatolite blocks it; lava takes no landfill.
  local v = dr.hand_tile(gs, force, 'landfill', 61, 61)
  eq(v.why, nil); eq(#v.removes, 1); eq(v.removes[1], cane)
  eq(dr.tile_blockers(gs, force, 'landfill', 61, 61), nil, 'the ghost check takes it too')
  v = dr.hand_tile(gs, force, 'landfill', 62, 63)
  eq(v.why, 'blocked by iron-stromatolite rock at (62.5,63.5): mine it first'); eq(#v.blockers, 1)
  eq(dr.hand_tile(gs, force, 'landfill', 64, 60).why, 'landfill cannot go on lava (foundation can)')
  eq(dr.hand_tile(gs, force, 'landfill', 58, 58).removes[1], nil, 'a free wetland tile')
  eq(dr.hand_tile(gs, force, 'landfill', 50, 58).why, 'landfill cannot go on grass-1', 'land: no alternatives named')
  -- Marked, the rock still blocks a hand-laid tile; a tile ghost goes over it (construct mines it first).
  rock.marked = true
  eq(dr.hand_tile(gs, force, 'landfill', 62, 63).why, 'blocked by iron-stromatolite rock at (62.5,63.5), marked for deconstruction: mine it first')
  eq(dr.tile_blockers(gs, force, 'landfill', 62, 63), nil)
  -- A tile ghost on the tile fails the engine's check (one ghost a tile): the boxes decide, and the cane goes.
  v = dr.hand_tile(gs, force, 'landfill', 63, 58)
  eq(v.why, nil); eq(v.removes[1], cane2)
  -- Sol's dry run: a 2x2 machine on four wetland tiles, one with the cane, needs 4 landfill, which takes the cane.
  local need = dr.check(gp, {kind='build', entities={{index=1, name='stone-furnace', position={x=61, y=61}, item='stone-furnace'}}})
  eq(need.entities[1].status, 'needs_tiles')
  eq(need.entities[1].why, 'stands on 4 wetland-light-dead-skin tiles: needs 4 landfill first; the landfill removes water-cane (61.8,61.8)')
  eq(need.tiles.removes, 'laid by hand, the tiles remove water-cane (61.8,61.8) (water-cane and fish do not block a tile; a new tile takes them away)')
  -- Its landfill laid by hand, entry by entry: the cane's tile is planned; the rock's (marked) and the lava refused.
  local laid = dr.check(gp, {kind='build', entities={}, tiles={{index=1, name='landfill', item='landfill', position={x=61.5, y=61.5}},
    {index=2, name='landfill', item='landfill', position={x=62.5, y=63.5}}, {index=3, name='landfill', item='landfill', position={x=64.5, y=60.5}}}})
  eq(laid.tiles.planned, 1); eq(laid.tiles.refused, 2)
  eq(laid.tiles.refused_rows[1], '(62.5,63.5) landfill: blocked by iron-stromatolite rock at (62.5,63.5), marked for deconstruction: mine it first')
  eq(laid.tiles.refused_rows[2], '(64.5,60.5) landfill: landfill cannot go on lava (foundation can)')
  has(laid.tiles.removes, 'water-cane (61.8,61.8)')
  -- place_ghosts over the cane: placeable, nothing marked (robots' tiles take the cane).
  local gh = dr.check(gp, {kind='ghosts', entities={}, tiles={{index=1, name='landfill', position={x=61.5, y=61.5}}}})
  eq(gh.tiles.planned, 1); eq(gh.tiles.marks, nil); eq(gh.tiles.refused, nil); eq(gh.tiles.removes, nil)
  -- A roboport whose box holds the cane (their masks meet: is_object): built by hand, the landfill it needs there goes
  -- first and takes the cane, so it needs tiles and is not blocked (on the copy: 15 landfill, then the roboport).
  prototypes.entity['test-port'] = {name='test-port', type='roboport', tile_width=4, tile_height=4, collision_box=box(1.7),
    collision_mask=mask('object', 'water_tile', 'player', 'item', 'is_object'), items_to_place_this={{name='test-port', count=1}}}
  local port = dr.check(gp, {kind='build', entities={{index=1, name='test-port', position={x=61, y=61}, item='test-port'}}})
  eq(port.entities[1].status, 'needs_tiles')
  eq(port.entities[1].why, 'stands on 16 wetland-light-dead-skin tiles: needs 16 landfill first; the landfill removes water-cane (61.8,61.8)')
  -- place_ghosts marks it, as a forced ghost marks trees.
  local gport = dr.check(gp, {kind='ghosts', entities={{index=1, name='test-port', position={x=61, y=61}}}})
  has(gport.entities[1].why, 'place_ghosts marks water-cane (61.75,61.75) for removal')
  prototypes.item.landfill.place_as_tile_result.tile_condition = saved
end)()
-- Astra, shift10 13:23: a roboport at (70,8) and a small pole at (69.5,10.5); the nearest built poles of network 2,
-- (73.5,2.5) and (77.5,14.5), are 8.94 tiles away, past a small pole's wire reach of 7.5. Pole ghosts at (69.5,14.5)
-- and (73.5,14.5) (on world n at 06:31, 4 tiles from the new pole and from (77.5,14.5)) bridged the gap in the dry run,
-- which said "planned pole #2 reaches the built network of small-electric-pole (73.5,2.5)"; built, the roboport's
-- network went no_power after its starting charge until Astra added poles at (67.5,9.5) and (69.5,5.5).
do
  prototypes.entity.roboport.electric_energy_source_prototype = {}
  local function layout(extra)
    local list = {{name='character', type='character', position={x=66.5, y=4.5}},
      {name='small-electric-pole', type='electric-pole', position={x=73.5, y=2.5}, electric_network_id=2},
      {name='small-electric-pole', type='electric-pole', position={x=77.5, y=14.5}, electric_network_id=2}}
    for _, e in ipairs(extra or {}) do list[#list+1] = e end
    return world(function() return 'grass-1' end, list)
  end
  local plan = {kind='build', entities={{index=1, name='roboport', position={x=70, y=8}, direction=0, item='roboport'},
    {index=2, name='small-electric-pole', position={x=69.5, y=10.5}, direction=0, item='small-electric-pole'}}}
  local function run(extra)
    local w = layout(extra)
    local me2 = {name='character', type='character', position={x=66.5, y=4.5}, prototype=prototypes.entity.character}
    return dryrun.check({surface=w, force=force, position=me2.position, character=me2, build_distance=10,
      get_main_inventory=function() return {get_item_count=function() return 10 end} end}, plan).power
  end
  local ghosts = {{name='entity-ghost', type='entity-ghost', ghost_name='small-electric-pole', position={x=69.5, y=14.5}},
    {name='entity-ghost', type='entity-ghost', ghost_name='small-electric-pole', position={x=73.5, y=14.5}}}
  -- With the ghosts: the path waits for them, and the roboport has no power until they stand.
  local pw = run(ghosts)
  eq(#pw.connected, 1); eq(pw.islands, nil)
  eq(pw.connected[1], 'planned pole #2 reaches a built network only through pole ghosts not built yet (small-electric-pole (69.5,14.5), '
    ..'small-electric-pole (73.5,14.5)): no wire path to a built pole until they stand; nearest built pole small-electric-pole at (73.5,2.5) '
    ..'is 8.9 tiles from (69.5,10.5) (wire reach 7.5)')
  eq(pw.unpowered[1].name, 'roboport'); eq(pw.unpowered[1].why, 'the poles over it reach a built network only through pole ghosts not built yet: no power until they stand')
  -- Without them: an island, 8.9 tiles from the nearest built pole.
  pw = run()
  eq(pw.connected, nil)
  eq(pw.islands[1], 'planned pole #2 at (69.5,10.5), powering 1 planned machine: no wire path to a built pole; nearest built pole small-electric-pole at (73.5,2.5) is 8.9 tiles from (69.5,10.5) (wire reach 7.5)')
  -- Astra's fix, poles at (67.5,9.5) and (69.5,5.5): (69.5,5.5) is 5 tiles from (73.5,2.5), so it reaches network 2 now.
  pw = run({{name='small-electric-pole', type='electric-pole', position={x=67.5, y=9.5}, electric_network_id=2},
    {name='small-electric-pole', type='electric-pole', position={x=69.5, y=5.5}, electric_network_id=2}})
  eq(pw.islands, nil); eq(pw.unpowered, nil); eq(pw.connected[1]:match('^planned pole #2 reaches the built network of small%-electric%-pole') ~= nil, true)
end
-- Cliffs under placeable entries (Sol 12:20: a belt_route dry run said 55 placeable, 6 of them over cliffs, with no
-- cliff explosives held): a ghost over a cliff marks it, one explosive each, counted against what is held.
do
  prototypes.entity.cliff = {name='cliff', type='cliff', collision_box={left_top={x=-2, y=-0.5}, right_bottom={x=2, y=0.5}},
    collision_mask=mask('object', 'player', 'cliff'), cliff_explosive_prototype='cliff-explosives'}
  local c1 = {name='cliff', type='cliff', position={x=20, y=20.5}}
  local me2 = {name='character', type='character', position={x=10.5, y=10.5}, prototype=prototypes.entity.character}
  local cw2 = world(function() return 'grass-1' end, {me2, c1})
  local base = cw2.can_place_entity
  -- As the engine: a forced ghost goes over a cliff (it marks it); nothing else does.
  cw2.can_place_entity = function(a) if a.forced then return true end return base(a) end
  local held = {['transport-belt']=100}
  local cp2 = {surface=cw2, force=force, position=me2.position, character=me2, build_distance=30,
    get_main_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end}
  local belts = {}
  for i, x in ipairs({17.5, 18.5, 19.5, 20.5, 21.5, 22.5}) do belts[i] = {index=i, name='transport-belt', position={x=x, y=20.5}, direction=4} end
  local r = dryrun.check(cp2, {kind='ghosts', entities=belts})
  eq(r.summary, '6 placeable (of 6); 4 over cliffs')
  eq(r.items['cliff-explosives'], 1); eq(r.missing['cliff-explosives'], 1)
  -- no construction robots reach it (Sol 15:41 on Gleba): clear it by hand with clear_cliffs, its position given
  eq(r.cliffs, '4 placeable entries stand over 1 cliff: placing marks it, and a marked cliff goes only with one explosive (construction robots bring it): cliff-explosives 1, you hold 0'
    ..'; no construction robots reach it here: clear it by hand first, clear_cliffs {"positions":[{"x":20,"y":20.5}]} (throws the explosives from within their range, walking there)')
  eq(r.cliffs_by_hand[1].x, 20); eq(r.cliffs_by_hand[1].y, 20.5)
  -- a network with construction robots over it: no hand-clearing line
  cw2.find_logistic_network_by_position = function() return {available_construction_robots=5} end
  r = dryrun.check(cp2, {kind='ghosts', entities=belts})
  eq(r.cliffs, '4 placeable entries stand over 1 cliff: placing marks it, and a marked cliff goes only with one explosive (construction robots bring it): cliff-explosives 1, you hold 0')
  eq(r.cliffs_by_hand, nil)
  cw2.find_logistic_network_by_position = nil
  held['cliff-explosives'] = 3
  r = dryrun.check(cp2, {kind='ghosts', entities=belts})
  eq(r.missing, nil); has(r.cliffs, 'cliff-explosives 1, you hold 3')
  -- A hand build is refused there (no forced placement): no cliff count.
  r = dryrun.check(cp2, {kind='build', entities={{index=1, name='transport-belt', position={x=20.5, y=20.5}, direction=4, item='transport-belt'}}})
  eq(r.cliffs, nil); eq(r.entities[1].status, 'blocked')
end
-- Astra, shift13 16:43: a build dry run read a splitter at (-6.5,554) over the belt at (-6.5,554.5) placeable; the build
-- refused it ("already on these tiles, not on the same centre") until the belt was mined. 2.0.77's manual check takes
-- the splitter there (a fast-replace); a hand build replaces one of its group only on its own centre and of its size
-- (runtime.lua build_direct). The dry run says the same; a belt over a belt on its centre is still a replacement.
;(function()
  prototypes.entity['transport-belt'].fast_replaceable_group = 'transport-belt'
  prototypes.entity['fast-transport-belt'] = {name='fast-transport-belt', type='transport-belt', tile_width=1, tile_height=1, collision_box=box(0.4),
    collision_mask=mask('object', 'transport_belt', 'water_tile'), fast_replaceable_group='transport-belt', items_to_place_this={{name='fast-transport-belt', count=1}}}
  prototypes.entity.splitter = {name='splitter', type='splitter', tile_width=2, tile_height=1,
    collision_box={left_top={x=-0.9, y=-0.4}, right_bottom={x=0.9, y=0.4}}, collision_mask=mask('object', 'transport_belt', 'water_tile'),
    fast_replaceable_group='transport-belt', items_to_place_this={{name='splitter', count=1}}}
  local belt = {name='transport-belt', type='transport-belt', position={x=-6.5, y=554.5}, direction=12}
  local bw = world(function() return 'grass-1' end, {belt}, {replaces={['transport-belt']='splitter'}})
  local bp = {surface=bw, force={name='player', recipes={}, is_chunk_charted=function() return true end}, position={x=-11.5, y=555.4}, build_distance=10,
    get_main_inventory=function() return {get_item_count=function() return 9 end} end}
  belt.force = bp.force
  local r = dryrun.check(bp, {kind='build', entities={{index=1, name='splitter', position={x=-6.5, y=554}, direction=12, item='splitter'}}})
  eq(r.entities[1].status, 'blocked')
  eq(r.entities[1].why, 'blocked by transport-belt (-6.5,554.5): on these tiles, not on the same centre; a build replaces one of its kind only on its own centre and of its size: mine it first')
  -- place_ghosts goes over it (robots replace it): no such refusal.
  eq(dryrun.check(bp, {kind='ghosts', entities={{index=1, name='splitter', position={x=-6.5, y=554}, direction=12}}}).entities, nil)
  -- On its centre, of its size: a replacement.
  local bw2 = world(function() return 'grass-1' end, {belt}, {replaces={['transport-belt']='fast-transport-belt'}})
  bp.surface = bw2
  r = dryrun.check(bp, {kind='build', details=true, entities={{index=1, name='fast-transport-belt', position={x=-6.5, y=554.5}, direction=12, item='fast-transport-belt'}}})
  eq(r.entities[1].status, 'ok'); eq(r.entities[1].why, 'replaces transport-belt (-6.5,554.5)')
end)()
-- Sol, shift13 16:50: Gleba's heat power planned by footprints, the joins unknown until built. Each fluid and heat
-- connection of the plan: the tile it joins and what is there. 2.0.77 on a copy of world n: this layout built by script
-- joined as read (the exchanger's water to the pipe, its steam to the turbine; heat tower 62 C, pipe 61, exchanger 59).
;(function()
  local pipes = dofile('mod/agent-harness_0.1.0/pipes.lua'){}
  local ports = dofile('mod/agent-harness_0.1.0/ports.lua'){boxes=pipes.boxes, defined=pipes.defined}
  local api2 = {}
  for k, v in pairs(api) do api2[k] = v end
  api2.fluid_rows = function(e, recipe) return (ports.rows(e, recipe and ports.recipe(e.prototype, recipe) or nil)) end
  api2.fluid_connections = function(o) return pipes.connections(o) end
  local dr = dofile('mod/agent-harness_0.1.0/dryrun.lua')(api2)
  -- Connections as 2.0.77 gives them: a position for each of the four directions (turned), facing turned too.
  local function turn(x, y, d) if d == 4 then return -y, x elseif d == 8 then return -x, -y elseif d == 12 then return y, -x end return x, y end
  local function conn(x, y, dir, flow, kind, reach)
    local positions = {}
    for i, d in ipairs({0, 4, 8, 12}) do local px, py = turn(x, y, d); positions[i] = {x=px, y=py} end
    return {positions=positions, direction=dir, flow_direction=flow or 'input-output', connection_type=kind or 'normal', max_underground_distance=reach}
  end
  local function heat(list) local out = {} for _, c in ipairs(list) do out[#out+1] = {position={x=c[1], y=c[2]}, direction=c[3]} end return {connections=out} end
  local BLD = mask('object', 'water_tile', 'player', 'item')
  prototypes.entity['heating-tower'] = {name='heating-tower', type='reactor', tile_width=3, tile_height=3, collision_box=box(1.4), collision_mask=BLD,
    heat_buffer_prototype=heat({{0, -1, 0}, {1, 0, 4}, {0, 1, 8}, {-1, 0, 12}}), items_to_place_this={{name='heating-tower', count=1}}}
  prototypes.entity['heat-pipe'] = {name='heat-pipe', type='heat-pipe', tile_width=1, tile_height=1, collision_box=box(0.4), collision_mask=BLD,
    heat_buffer_prototype=heat({{0, 0, 0}, {0, 0, 4}, {0, 0, 8}, {0, 0, 12}}), items_to_place_this={{name='heat-pipe', count=1}}}
  prototypes.entity['heat-exchanger'] = {name='heat-exchanger', type='boiler', tile_width=3, tile_height=2,
    collision_box={left_top={x=-1.3, y=-0.8}, right_bottom={x=1.3, y=0.8}}, collision_mask=BLD, heat_buffer_prototype=heat({{0, 0.5, 8}}),
    fluidbox_prototypes={{production_type='input-output', filter={name='water'}, pipe_connections={conn(-1, 0.5, 12), conn(1, 0.5, 4)}},
      {production_type='output', filter={name='steam'}, pipe_connections={conn(0, -0.5, 0, 'output')}}}, items_to_place_this={{name='heat-exchanger', count=1}}}
  prototypes.entity['steam-turbine'] = {name='steam-turbine', type='generator', tile_width=3, tile_height=5,
    collision_box={left_top={x=-1.3, y=-2.3}, right_bottom={x=1.3, y=2.3}}, collision_mask=BLD,
    fluidbox_prototypes={{production_type='input', filter={name='steam'}, pipe_connections={conn(0, -2, 0, 'input'), conn(0, 2, 8, 'input')}}},
    items_to_place_this={{name='steam-turbine', count=1}}}
  prototypes.entity.pipe = {name='pipe', type='pipe', tile_width=1, tile_height=1, collision_box=box(0.3), collision_mask=BLD,
    fluidbox_prototypes={{pipe_connections={conn(0, 0, 0), conn(0, 0, 4), conn(0, 0, 8), conn(0, 0, 12)}}}, items_to_place_this={{name='pipe', count=1}}}
  prototypes.entity['pipe-to-ground'] = {name='pipe-to-ground', type='pipe-to-ground', tile_width=1, tile_height=1, collision_box=box(0.3), collision_mask=BLD,
    fluidbox_prototypes={{pipe_connections={conn(0, 0, 0), conn(0, 0, 8, nil, 'underground', 10)}}}, items_to_place_this={{name='pipe-to-ground', count=1}}}
  -- Heat connections turn with the entity: an exchanger's heat input is on its back.
  local hp = dr.heat_points(prototypes.entity['heat-exchanger'], {x=624, y=600.5}, 4)
  eq(#hp, 1); eq(hp[1].x, 623); eq(hp[1].y, 600); eq(hp[1].dir, 12); eq(hp[1].tx, 622); eq(hp[1].ty, 600)
  hp = dr.heat_points(prototypes.entity['heat-exchanger'], {x=636.5, y=600}, 8)
  eq(hp[1].x, 636); eq(hp[1].y, 599); eq(hp[1].tx, 636); eq(hp[1].ty, 598)
  -- A built pipe east of the planned exchanger's east water point; the rest planned, the turbine first one tile short.
  local built = {name='pipe', type='pipe', position={x=130.5, y=40.5}, direction=0}
  local cw = world(function() return 'grass-1' end, {built})
  local cp = {surface=cw, force={name='player', recipes={}, is_chunk_charted=function() return true end}, position={x=128, y=45}, build_distance=10,
    get_main_inventory=function() return {get_item_count=function() return 9 end} end}
  built.force = cp.force
  local function plan(turbine_y)
    return {kind='build', entities={
      {index=1, name='heating-tower', position={x=128.5, y=43.5}, direction=0, item='heating-tower'},
      {index=2, name='heat-pipe', position={x=128.5, y=41.5}, direction=0, item='heat-pipe'},
      {index=3, name='heat-exchanger', position={x=128.5, y=40}, direction=0, item='heat-exchanger'},
      {index=4, name='steam-turbine', position={x=128.5, y=turbine_y}, direction=0, item='steam-turbine'},
      {index=5, name='pipe', position={x=126.5, y=40.5}, direction=0, item='pipe'}}}
  end
  local function rows(r) local out = {} for _, x in ipairs(r.connections or {}) do out[x.index] = x end return out end
  local c = rows(dr.check(cp, plan(35.5)))
  eq(c[3].fluid[3], 'output steam north at (128.5,38.5): nothing there', 'a tile short: no join')
  eq(c[4].fluid[2], 'input steam south at (128.5,38.5): nothing there')
  local out = dr.check(cp, plan(36.5))
  c = rows(out)
  eq(c[1].heat[1], 'heat north at (128.5,41.5): planned #2 heat-pipe'); eq(c[1].heat[2], 'heat east at (130.5,43.5): nothing there')
  eq(c[3].fluid[1], 'input-output water west at (126.5,40.5): planned #5 pipe')
  eq(c[3].fluid[2], 'input-output water east at (130.5,40.5): pipe (130.5,40.5)', 'the built pipe joins')
  eq(c[3].fluid[3], 'output steam north at (128.5,38.5): planned #4 steam-turbine')
  eq(c[3].heat[1], 'heat south at (128.5,41.5): planned #2 heat-pipe')
  eq(c[4].fluid[1], 'input steam north at (128.5,33.5): nothing there'); eq(c[4].fluid[2], 'input steam south at (128.5,39.5): planned #3 heat-exchanger')
  eq(c[2], nil, 'a heat pipe joining only the plan: no row'); eq(c[5], nil, 'a pipe joining only the plan: no row')
  eq(out.connections_open, 4)   -- the tower's east, south and west, the turbine's north
  -- A pipe-to-ground's underground side faces the turbine: no join.
  c = rows(dr.check(cp, {kind='build', entities={
    {index=1, name='steam-turbine', position={x=160.5, y=40.5}, direction=0, item='steam-turbine'},
    {index=2, name='pipe-to-ground', position={x=160.5, y=43.5}, direction=8, item='pipe-to-ground'}}}))
  eq(c[1].fluid[2], 'input steam south at (160.5,43.5): faces planned #2 pipe-to-ground (no connection back)')
  -- A flipped paste: not read (the game turns a storage tank its own way).
  local fp = plan(36.5); fp.kind = 'paste'; fp.flipped = true
  local fo = dr.check(cp, fp)
  eq(fo.connections, nil); eq(fo.connections_note, 'not read for a flipped paste')
  -- Each planned pipe-to-ground (Sol 18:21: four built reversed, seen only by inspect after building): what its mouth
  -- joins, and whether it pairs and with which. 2.0.77 on a copy of world n: 10 apart pair, 11 apart do not; the first
  -- pipe-to-ground on the line decides (facing the same way, it pairs on beyond and the one behind gets none).
  local function p2g(i, x, y, d) return {index=i, name='pipe-to-ground', position={x=x, y=y}, direction=d, item='pipe-to-ground'} end
  local u = dr.check(cp, {kind='build', entities={p2g(1, 200.5, 40.5, 0), p2g(2, 200.5, 46.5, 8),
    {index=3, name='pipe', position={x=200.5, y=39.5}, direction=0, item='pipe'}, p2g(4, 210.5, 40.5, 0)}})
  c = rows(u)
  eq(c[1].fluid[1], 'mouth north at (200.5,39.5): planned #3 pipe')
  eq(c[1].fluid[2], 'underground south: pairs with planned #2 pipe-to-ground (200.5,46.5), 6 tiles')
  eq(c[2].fluid[1], 'mouth south at (200.5,47.5): nothing there')
  eq(c[2].fluid[2], 'underground north: pairs with planned #1 pipe-to-ground (200.5,40.5), 6 tiles')
  eq(c[3], nil, 'a pipe joining only the plan: no row')
  eq(c[4].fluid[1], 'mouth north at (210.5,39.5): nothing there')
  eq(c[4].fluid[2], 'underground south: unpaired: no pipe-to-ground facing back within 10 tiles')
  eq(u.connections_open, 3)   -- #2's mouth, #4's mouth and its underground end
  c = rows(dr.check(cp, {kind='ghosts', entities={p2g(1, 220.5, 30.5, 0), p2g(2, 220.5, 40.5, 8), p2g(3, 222.5, 30.5, 0), p2g(4, 222.5, 41.5, 8),
    p2g(5, 224.5, 30.5, 0), p2g(6, 224.5, 34.5, 0), p2g(7, 224.5, 38.5, 8)}}))
  eq(c[1].fluid[2], 'underground south: pairs with planned #2 pipe-to-ground (220.5,40.5), 10 tiles')
  eq(c[3].fluid[2], 'underground south: unpaired: no pipe-to-ground facing back within 10 tiles', '11 apart')
  eq(c[4].fluid[2], 'underground north: unpaired: no pipe-to-ground facing back within 10 tiles')
  eq(c[5].fluid[2], 'underground south: unpaired: the first on its line, planned #6 pipe-to-ground (224.5,34.5), faces the same way')
  eq(c[6].fluid[2], 'underground south: pairs with planned #7 pipe-to-ground (224.5,38.5), 4 tiles')
  -- A built one facing back pairs, and the reply says what it pairs with now (the engine's view of it).
  local P = {name='pipe-to-ground', type='pipe-to-ground', position={x=230.5, y=36.5}, direction=0, valid=true, unit_number=71}
  local B = {name='pipe-to-ground', type='pipe-to-ground', position={x=230.5, y=46.5}, direction=8, valid=true, unit_number=72}
  B.fluidbox = setmetatable({get_locked_fluid=function() return nil end, get_pipe_connections=function() return {
    {connection_type='normal', flow_direction='input-output', position={x=230.5, y=46.5}, target_position={x=230.5, y=47.5}},
    {connection_type='underground', flow_direction='input-output', position={x=230.5, y=46.5}, target_position={x=230.5, y=36.5},
      target={object_name='LuaFluidBox', owner=P}}} end}, {__len=function() return 1 end})
  P.force, B.force = cp.force, cp.force
  local dp = {surface=world(function() return 'grass-1' end, {P, B}), force=cp.force, position={x=230, y=42}, build_distance=10,
    get_main_inventory=function() return {get_item_count=function() return 9 end} end}
  c = rows(dr.check(dp, {kind='build', entities={p2g(1, 230.5, 40.5, 0)}}))
  eq(c[1].fluid[2], 'underground south: pairs with pipe-to-ground (230.5,46.5), 6 tiles (it pairs with pipe-to-ground (230.5,36.5) now)')
  c = rows(dr.check(dp, {kind='build', entities={p2g(1, 230.5, 32.5, 0)}}))
  eq(c[1].fluid[2], 'underground south: unpaired: the first on its line, pipe-to-ground (230.5,36.5), faces the same way')
  -- Past 64 rows (256 with details) the rest are only counted.
  local many = {}
  for i = 1, 70 do many[i] = p2g(i, 300.5 + 3 * i, 300.5, 0) end
  local mo = dr.check(cp, {kind='ghosts', entities=many})
  eq(#mo.connections, 64); eq(mo.connections_open, 140)
  eq(mo.connections[64].fluid[2], 'underground south: unpaired: no pipe-to-ground facing back within 10 tiles')
  eq(#dr.check(cp, {kind='ghosts', details=true, entities=many}).connections, 70)
  -- Reversed: the mouth faces away from the pipe it was meant for, the underground side faces it.
  c = rows(dr.check(dp, {kind='build', entities={p2g(1, 236.5, 40.5, 8), {index=2, name='pipe', position={x=236.5, y=39.5}, direction=0, item='pipe'}}}))
  eq(c[1].fluid[1], 'mouth south at (236.5,41.5): nothing there')
  eq(c[1].fluid[2], 'underground north: unpaired: no pipe-to-ground facing back within 10 tiles')
end)()
print('dryrun: ok')
