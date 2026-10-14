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

-- Pole ghosts already ordered join too (review: a planned pole 7 tiles from a pole ghost 7 tiles from a built pole).
local chain_world = world(planet, {{name='small-electric-pole', type='electric-pole', position={x=-4.5, y=0.5}, electric_network_id=3},
  {name='entity-ghost', type='entity-ghost', ghost_name='small-electric-pole', position={x=2.5, y=0.5}}, me})
local cp = {surface=chain_world, force=force, position={x=0, y=0}, build_distance=10, character=me,
  get_main_inventory=function() return {get_item_count=function() return 0 end} end}
local co = dryrun.check(cp, {kind='ghosts', entities={{index=1, name='small-electric-pole', position={x=9.5, y=0.5}}}})
eq(co.power.islands, nil); has(co.power.connected[1], 'planned pole #1 reaches the built network of')

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

-- A build batch names the entry it stops at (review: exists, out of reach and late tiles never counted).
local _, _, bc = dryrun.check(p, {kind='build', entities={
  {index=1, name='small-electric-pole', position={x=2.5, y=0.5}, item='small-electric-pole'},
  {index=2, name='assembling-machine-1', position={x=-10.5, y=-6.5}, item='assembling-machine-1'},
  {index=3, name='small-electric-pole', position={x=30.5, y=0.5}, item='small-electric-pole'}}})
eq(bc.fail_first, 2); eq(bc.fail_why, 'target already contains this entity')
local _, _, bc2 = dryrun.check(p, {kind='build', entities={{index=1, name='small-electric-pole', position={x=30.5, y=0.5}, item='small-electric-pole'}}})
eq(bc2.fail_first, 1); has(bc2.fail_why, 'out of reach: 30.5 tiles from you, reach 10')
local _, _, bc3 = dryrun.check(p, {kind='build', entities={}, tiles={{index=1, name='landfill', item='landfill', position={x=0.5, y=5.5}}}})
eq(bc3.fail_first, 1); eq(bc3.fail_why, 'no tile of its brush can be laid there')

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
end
eq(dryrun.placeable_on('landfill', 'water'), true); eq(dryrun.placeable_on('landfill', 'grass-1'), false)
eq(dryrun.placeable_on('space-platform-foundation', 'empty-space'), true); eq(dryrun.placeable_on('space-platform-foundation', 'grass-1'), false)
print('dryrun: ok')
