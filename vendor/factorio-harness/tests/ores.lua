-- Run from repository root: lua tests/ores.lua
-- The ores read (ores.lua) against a fake engine: chunk records, patches
-- merged across cells and chunk borders, fluid fields, the charted map, nests,
-- drills, our nearest building, the caller's distances, the call's budget and
-- the background reads, refresh and newly charted chunks.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local function resource(fluid, normal)
  return {type='resource', infinite_resource=fluid or nil, normal_resource_amount=normal,
    mineable_properties={products={{type=fluid and 'fluid' or 'item', name=fluid and 'crude-oil' or 'ore'}}}}
end
prototypes = {entity={['iron-ore']=resource(), ['copper-ore']=resource(), ['crude-oil']=resource(true, 300000),
  ['lithium-brine']={type='resource', normal_resource_amount=50000, mineable_properties={products={{type='fluid', name='lithium-brine'}}}},
  ['electric-mining-drill']={type='mining-drill', mining_drill_radius=2.49}, ['stone-furnace']={type='furnace'}}}
local storage = {}
local uncharted = {}
local api = {state=function() return storage end,
  integer=function(v, d, lo, hi, n) v = v == nil and d or v; assert(type(v) == 'number' and v >= lo and v <= hi, n..' must be '..lo..'..'..hi); return v end,
  position=function(v) return {x=v.x or v[1], y=v.y or v[2]} end,
  charted=function(force, surface, c) return c.x >= -3 and c.x <= 6 and c.y >= -2 and c.y <= 2 and not uncharted[c.x..','..c.y] end}
local ores = dofile('mod/agent-harness_0.1.0/ores.lua')(api)

-- The fake surface: what an area find returns (anything whose box touches
-- the area, as the engine does), and its generated chunks.
local finds = 0
local res, ents = {}, {}
local function ent(t)
  t.valid = true; t.prototype = prototypes.entity[t.name]; t.half = t.half or 0.4
  t.force = t.force or {name='player'}
  return t
end
local function ore(name, x, y, amount, half) res[#res+1] = ent{name=name, type='resource', position={x=x+0.5, y=y+0.5}, amount=amount, half=half} end
local function touches(e, area)
  return e.position.x+e.half > area[1][1] and e.position.x-e.half < area[2][1] and e.position.y+e.half > area[1][2] and e.position.y-e.half < area[2][2]
end
local surface = {name='nauvis', index=1}
function surface.find_entities_filtered(f)
  finds = finds+1
  local out = {}
  local types
  if type(f.type) == 'table' then types = {}; for _, t in ipairs(f.type) do types[t] = true end end
  local force = type(f.force) == 'table' and f.force.name or f.force
  for _, e in ipairs(f.type == 'resource' and res or ents) do
    if touches(e, f.area) and (not force or e.force.name == force) and (not types or types[e.type]) then out[#out+1] = e end
  end
  return out
end
function surface.count_entities_filtered(f) finds = finds-1; return #surface.find_entities_filtered(f) end
local generated = {}
for cx = -3, 6 do for cy = -2, 2 do generated[#generated+1] = {x=cx, y=cy} end end
function surface.get_chunks()
  local i = 0
  return function() i = i+1; local c = generated[i]; if c then return {x=c.x, y=c.y, area={left_top={x=c.x*32, y=c.y*32}, right_bottom={x=c.x*32+32, y=c.y*32+32}}} end end
end
local force = {name='player'}
game = {tick=1000, surfaces={[1]=surface}, forces={player=force}}

-- Iron A: a 4x4 block at (0..3, 0..3) and a strip three tiles east (7..8),
-- joined (cells touch); its east part runs over the chunk border at x=32.
for x = 0, 3 do for y = 0, 3 do ore('iron-ore', x, y, 100) end end
for x = 7, 8 do ore('iron-ore', x, 1, 50) end
for x = 28, 35 do ore('iron-ore', x, 10, 10) end
for x = 9, 27, 3 do ore('iron-ore', x, 6, 1) end
-- Iron B: 9 tiles apart from anything (cells do not touch): its own patch.
for x = 60, 61 do for y = 0, 1 do ore('iron-ore', x, y, 1000) end end
-- Copper on an uncharted chunk is not on the map.
uncharted['5,0'] = true
ore('copper-ore', 170, 5, 500)
-- Copper C at a chunk's west edge with an uncharted chunk beyond: chart_edge.
ore('copper-ore', 192, 40, 300)
uncharted['5,1'] = true
-- Oil: wells 20 tiles apart in touching 16-cells are one field; a well's box
-- reaches over the chunk border (x=-33 is chunk -2, its box touches chunk -1).
ore('crude-oil', -40, -40, 300000, 1.4); ore('crude-oil', -20, -40, 150000, 1.4); ore('crude-oil', -33, -40, 30000, 1.4)

-- A chunk's record: ore cells, and a well over the border read once.
local rec, units = ores.read_chunk(surface, force, 0, 0)
eq(#rec.cells, 9, 'cells of chunk 0,0'); eq(rec.buildings, nil); eq(units, 3+16+2+4+7, 'three finds and the tiles read')
local west = ores.read_chunk(surface, force, -1, -2)
local wells = 0
for _, c in ipairs(west.cells) do wells = wells+c.n end
eq(wells, 1, 'the well at x=-20 only; the one at -33 belongs to chunk -2')

-- Nests, drills, buildings.
ents[#ents+1] = ent{name='biter-spawner', type='unit-spawner', position={x=64.5, y=45}, force={name='enemy'}, half=2}   -- 43 tiles south of B
ents[#ents+1] = ent{name='small-worm-turret', type='turret', position={x=70, y=-20}, force={name='enemy'}}            -- 21.5 from B
ents[#ents+1] = ent{name='small-biter', type='unit', position={x=66, y=-5}, force={name='enemy'}}                     -- a unit: no nest
ents[#ents+1] = ent{name='biter-spawner', type='unit-spawner', position={x=64.5, y=60}, force={name='enemy'}, half=2}   -- 58: out of range
ents[#ents+1] = ent{name='biter-spawner', type='unit-spawner', position={x=180, y=10}, force={name='enemy'}, half=2}    -- uncharted chunk
ents[#ents+1] = ent{name='electric-mining-drill', type='mining-drill', position={x=1.5, y=1.5}, mining_target=res[1], half=1.4}
ents[#ents+1] = ent{name='electric-mining-drill', type='mining-drill', position={x=59, y=3}, half=1.4}   -- no target: its area covers B
ents[#ents+1] = ent{name='car', type='car', position={x=-35, y=-40}}                                     -- not a building
ents[#ents+1] = ent{name='stone-furnace', type='furnace', position={x=-60, y=-40}, half=0.9}

-- The first call reads the charted chunks nearest the caller within the
-- call's budget and queues the rest; the harness tick reads them.
ores.CALL_BUDGET, ores.TICK_BUDGET = 20, 30
local me = {surface=surface, force=force, position={x=0, y=0}}
local first = ores.handlers.ores(me, {})
assert(first.survey:find('^reading the charted map: %d+ chunks? read so far, nearest first'), first.survey)
eq(storage.ores_busy, true, 'the rest goes to the harness tick')
eq(first.patches[1].resource, 'iron-ore'); eq(first.patches[1].distance, 0)
ores.tick(); ores.tick()
local during = ores.handlers.ores(me, {})
eq(#during.patches, #first.patches, 'no rebuild within a second while a pass is under way')
local ticks = 0
while storage.ores_busy and ticks < 100 do ores.tick(); ticks = ticks+1 end
eq(storage.ores_busy, nil); assert(ticks > 1 and ticks < 20, ticks)
local spent = finds
ores.tick()
eq(finds, spent, 'nothing a tick once the queue is empty')

local out = ores.handlers.ores(me, {})
eq(out.survey, '48 charted chunks read; the last pass began 0 s ago', 'every charted chunk (50 generated, 2 uncharted)')
eq(out.count, 4, 'patches on the map'); eq(out.from.x, 0)
local rows = {}
for _, r in ipairs(out.patches) do rows[#rows+1] = r.resource..'@'..r.distance end
eq(table.concat(rows, ' '), 'iron-ore@0 crude-oil@43 iron-ore@60 copper-ore@196', 'nearest first, distance to the nearest tile')
local a, oil, b, c = out.patches[1], out.patches[2], out.patches[3], out.patches[4]
eq(a.tiles, 33); eq(a.amount, 16*100+2*50+8*10+7*1); eq(a.miners, 1, 'a drill mining it'); eq(a.box, '(0,0)-(36,11)', 'over the chunk border')
eq(a.direction, nil, 'standing on it'); eq(a.from_building, 0); eq(a.building, 'electric-mining-drill 1.5,1.5')
eq(oil.wells, 3); eq(oil.yield, '160%'); eq(oil.tiles, nil); eq(oil.direction, 'NW')
eq(oil.from_building, 20, 'the furnace 20 tiles west of the west well; the car is no building')
eq(b.amount, 4000); eq(b.miners, 1, 'an idle drill over it'); eq(b.spawners, 1); eq(b.worms, 1, 'the worm; the biter is no nest'); eq(b.direction, 'E')
eq(b.nearest_nest, 'small-worm-turret 70,-20 22 tiles'); eq(b.chart_edge, nil)
eq(c.chart_edge, true, 'ore on the edge of the charted map'); eq(c.spawners, nil, 'a spawner on an uncharted chunk is not on the map')
eq(out.resources, 'copper-ore 1 (300), crude-oil 1 (yield 160%), iron-ore 2 (5787)')

-- A dense chunk is read a band of rows at a time over several slices and
-- comes out the same as read whole.
local whole = ores.read_chunk(surface, force, 0, 0)
ores.DENSE, ores.BAND = 10, 8
local partial, u1 = ores.read_chunk(surface, force, 0, 0, 8)
eq(partial.by ~= nil, true, 'cells by key kept while the chunk is read')
local u = u1
for from = 8, 24, 8 do u = u+ores.read_band(surface, partial, 0, 0, from, from+8) end
eq(partial.by, nil)
local function sum(rec) local n, a = 0, 0; for _, c in ipairs(rec.cells) do n = n+c.n; a = a+c.amount end; return n..'/'..a end
eq(sum(partial), sum(whole), 'banded = whole'); eq(#partial.cells, #whole.cells)
storage.ores, storage.ores_busy = nil, nil
ores.handlers.ores(me, {})
local slices = 0
while storage.ores_busy do ores.tick(); slices = slices+1 end
local banded = ores.handlers.ores(me, {})
eq(banded.patches[1].amount, out.patches[1].amount); eq(banded.count, out.count); eq(banded.resources, out.resources)
ores.DENSE, ores.BAND = 256, 8

-- Later calls in the window read nothing; distances are the caller's own.
local before = finds
local again = ores.handlers.ores({surface=surface, force=force, position={x=100, y=0}}, {resource='iron-ore'})
eq(finds, before, 'no reads'); eq(#again.patches, 2); eq(again.patches[1].tiles, 4, 'from (100,0) B is nearer'); eq(again.patches[1].distance, 38)

-- A call REFRESH_TICKS after a pass began starts the next: ore mined
-- meanwhile and newly charted chunks show once it is read.
uncharted['5,0'] = nil
res[1].amount = 40
game.tick = 1000+ores.REFRESH_TICKS-1
local stale = ores.handlers.ores(me, {})
eq(stale.patches[1].amount, 1787, 'not read again yet'); eq(storage.ores_busy, nil); eq(stale.count, 4)
game.tick = 1000+ores.REFRESH_TICKS
local fresh = ores.handlers.ores(me, {})
eq(fresh.survey, '48 charted chunks read; being read again since 0 s ago (a few chunks a tick)')
eq(fresh.patches[1].amount, 1787, 'the old pass until chunks are read again')
while storage.ores_busy do ores.tick() end
game.tick = game.tick+120
fresh = ores.handlers.ores(me, {})
eq(fresh.patches[1].amount, 1727, 'read again'); eq(fresh.survey, '49 charted chunks read; the last pass began 2 s ago')
eq(fresh.count, 5, 'the copper on the newly charted chunk')

-- Filters: min_amount (a fluid's yield %), limit and more, several resources.
local big = ores.handlers.ores(me, {min_amount=1000})
rows = {}
for _, r in ipairs(big.patches) do rows[#rows+1] = r.resource..':'..(r.amount or r.yield) end
eq(table.concat(rows, ' '), 'iron-ore:1727 iron-ore:4000', 'the oil field yields 160%, under 1000')
local one = ores.handlers.ores(me, {limit=1, resource={'iron-ore', 'crude-oil'}})
eq(#one.patches, 1); eq(one.count, 3); eq(one.more, '+2 more: limit raises the count')

-- Another surface (remote view): no distance from the caller; ours first.
local remote = setmetatable({__remote='nauvis'}, {__index={surface=surface, force=force, position={x=0, y=0}}})
local far = ores.handlers.ores(remote, {})
eq(far.from, nil); eq(far.patches[1].distance, nil)
rows = {}
for _, r in ipairs(far.patches) do rows[#rows+1] = r.resource..'~'..r.from_building end
eq(table.concat(rows, ' '), 'iron-ore~0 iron-ore~1 crude-oil~20 copper-ore~111 copper-ore~138', 'nearest our buildings first')
eq(ores.handlers.ores(remote, {position={x=-30, y=-40}, resource='crude-oil'}).patches[1].distance, 2)

-- A background read that fails ends its pass; the next call says so and begins another.
game.tick = game.tick+ores.REFRESH_TICKS
ores.handlers.ores(me, {})
local find = surface.find_entities_filtered
surface.find_entities_filtered = function() error('engine says no') end
ores.tick()
surface.find_entities_filtered = find
eq(storage.ores_busy, nil, 'the failed pass ends')
local after = ores.handlers.ores(me, {})
assert(after.survey_error and after.survey_error:find('engine says no', 1, true), tostring(after.survey_error))
while storage.ores_busy do ores.tick() end
eq(ores.handlers.ores(me, {}).survey_error, nil)

-- A fluid that runs out (lithium brine): wells and the amount left, no yield.
local brine = ores.build({{cells={{name='lithium-brine', cx=0, cy=0, n=2, amount=90000, sx=3, sy=3, l=1, t=1, r=3, b=2}}}})
eq(brine[1].fluid, true); eq(brine[1].yield, nil); eq(brine[1].amount, 90000)

-- Refusals and a platform.
local ok, err = pcall(ores.handlers.ores, me, {resource='iron-plate'})
assert(not ok and tostring(err):find('iron-plate is not a resource; resources: copper-ore, crude-oil, iron-ore, lithium-brine', 1, true), err)
ok, err = pcall(ores.handlers.ores, me, {min_amount='lots'})
assert(not ok and tostring(err):find('min_amount is a number', 1, true), err)
local deck = ores.handlers.ores({surface={name='platform-1', index=9, platform={name='Sunward'}}, force=force, position={x=0, y=0}}, {})
eq(deck.count, 0); assert(deck.note:find('no resource tiles', 1, true))
print('ores: ok')
