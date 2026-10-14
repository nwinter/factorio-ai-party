-- Run from repository root: lua tests/targets.lua
-- What inserters take from and put into (targets.lua): points from the
-- prototype's vectors turned with the direction (checked on a private 2.0.77
-- server: a long-handed inserter at (1010.5,1000.5) facing north picks up at
-- y 998.5 and drops at y 1002.7; facing east it picks up at x 1022.5 and drops
-- at x 1018.3), what stands on a point (built, planned, ghost, something that
-- takes no items, the ground, empty space), built inserters' engine targets
-- and inserter ghosts.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local T = dofile('mod/agent-harness_0.1.0/targets.lua'){}
local long = {inserter_pickup_position={0, -2}, inserter_drop_position={0, 2.2}}
local function near(a, b, m) assert(math.abs(a-b) < 1e-9, (m or 'mismatch')..': '..a..' ~= '..b) end
local pos = {x=1010.5, y=1000.5}
-- On the engine's 1/256 grid: 2.2 is 2.19921875 (the engine's drop_position read 1002.69921875).
local D = 563/256
for dir, want in pairs({[0]={0, -2, 0, D}, [4]={2, 0, -D, 0}, [8]={0, 2, 0, -D}, [12]={-2, 0, D, 0}}) do
  local pick, drop = T.points(long, pos, dir)
  near(pick.x, pos.x+want[1], 'pickup x '..dir); near(pick.y, pos.y+want[2], 'pickup y '..dir)
  near(drop.x, pos.x+want[3], 'drop x '..dir); near(drop.y, pos.y+want[4], 'drop y '..dir)
end
eq(T.points({}, pos, 0), nil, 'not an inserter')

-- A surface: entities with boxes; a position finds what its box holds.
local function box(e, h) e.box = {e.position.x-h, e.position.y-h, e.position.x+h, e.position.y+h}; e.valid = true; return e end
local ents = {
  box({name='iron-chest', type='container', position={x=0.5, y=0.5}}, 0.35),
  box({name='entity-ghost', type='entity-ghost', ghost_name='transport-belt', ghost_type='transport-belt', position={x=0.5, y=0.5}}, 0.4),
  box({name='entity-ghost', type='entity-ghost', ghost_name='wooden-chest', ghost_type='container', position={x=4.5, y=0.5}}, 0.35),
  box({name='stone-wall', type='wall', position={x=6.5, y=0.5}}, 0.49),
  box({name='small-biter', type='unit', position={x=8.5, y=0.5}}, 0.3),
  box({name='item-on-ground', type='item-entity', position={x=8.5, y=0.6}}, 0.2),
  box({name='iron-chest', type='container', position={x=15.5, y=0.5}}, 0.35),
  box({name='iron-chest', type='container', position={x=15.5, y=2.5}}, 0.35),
}
local surface = {}
function surface.find_entities_filtered(f)
  local out = {}
  for _, e in ipairs(ents) do
    local b = e.box
    if f.position.x >= b[1] and f.position.x <= b[3] and f.position.y >= b[2] and f.position.y <= b[4] and (not f.type or e.type == f.type) then out[#out+1] = e end
  end
  return out
end
function surface.get_tile(x, y) return {name=x >= 20 and 'empty-space' or 'grass-1'} end
eq(T.at(surface, {x=0.5, y=0.7}), 'iron-chest (0.5,0.5)', 'a built target before a ghost on it')
eq(T.at(surface, {x=4.5, y=0.7}), 'ghost wooden-chest (4.5,0.5)')
local planned = function(p) if p.x > 4 and p.x < 5 then return {name='steel-chest', position={x=4.5, y=0.5}, type='container'} end end
eq(T.at(surface, {x=4.5, y=0.7}, planned), 'planned steel-chest (4.5,0.5)', 'the plan before a ghost it replaces')
local none, why = T.at(surface, {x=6.5, y=0.7})
eq(none, nil); eq(why, 'stone-wall at (6.5,0.5) takes no items')
none, why = T.at(surface, {x=8.5, y=0.7})
eq(why, 'the ground at (8.5,0.5)', 'a biter and an item on the ground are neither')
none, why = T.at(surface, {x=21.5, y=0.7})
eq(why, 'empty space at (21.5,0.5)')
none, why = T.at(surface, {x=2.5, y=0.5}, function() return {name='small-electric-pole', position={x=2.5, y=0.5}, type='electric-pole'} end)
eq(why, 'planned small-electric-pole at (2.5,0.5) takes no items')

-- A planned inserter at (0.5,1.5) facing north: chest north of it, nothing south.
local ins = {inserter_pickup_position={0, -1}, inserter_drop_position={0, 1.2}}
local t = T.plan(surface, ins, {x=0.5, y=1.5}, 0)
eq(t.pickup, 'iron-chest (0.5,0.5)'); eq(t.drop, 'none: the ground at (0.5,2.5)'); eq(t.missing, 'no drop target')
-- North of the chest facing north it drops into it and picks up from the ground;
-- facing south it takes from the chest and drops north onto the ground.
t = T.plan(surface, ins, {x=0.5, y=-0.5}, 0)
eq(t.pickup, 'none: the ground at (0.5,-1.5)'); eq(t.drop, 'iron-chest (0.5,0.5)'); eq(t.missing, 'no pickup target')
t = T.plan(surface, ins, {x=0.5, y=-0.5}, 8)
eq(t.pickup, 'iron-chest (0.5,0.5)'); eq(t.drop, 'none: the ground at (0.5,-1.5)'); eq(t.missing, 'no drop target')

-- Built inserters: the engine's targets.
eq(T.missing({valid=true, type='inserter', pickup_target={}, drop_target={}}), nil)
eq(T.missing({valid=true, type='inserter', pickup_target={}}), 'no drop target')
eq(T.missing({valid=true, type='inserter'}), 'no pickup target, no drop target')
eq(T.missing({valid=true, type='container'}), nil, 'only inserters')

-- Inserter ghosts: the rows of those missing a target, and the count past the rows.
local function ghost(x, dir) return {valid=true, type='entity-ghost', ghost_type='inserter', ghost_name='inserter', ghost_prototype=ins,
  position={x=x, y=1.5}, direction=dir or 0, surface=surface} end
local rows, more = T.check({ghost(15.5), ghost(10.5), ghost(12.5), ghost(0.5, 8)}, 1)
eq(#rows, 1); eq(more, 3, 'three of four lack a target'); eq(rows[1].position.x, 10.5); eq(rows[1].missing, 'no pickup target, no drop target')
eq(T.check({}, 4), nil)
-- A just-built long-handed inserter beside a stone furnace (Astra, shift10 13:44: the reply said "the ground" at its
-- drop; inspect a moment later showed the furnace). The furnace at (30,130): its box on the engine's grid runs from
-- x 29.30078125; the inserter at (31.5,130.5) facing east drops at x 29.30078125, on that edge, where the engine
-- targets the furnace. The unrounded point, 29.3, lies outside it.
do
  local furnace = {name='stone-furnace', type='furnace', position={x=30, y=130}, valid=true,
    box={29.30078125, 129.30078125, 30.69921875, 130.69921875}}
  local fs = {find_entities_filtered=function(f)
    local b = furnace.box
    if f.position.x >= b[1] and f.position.x <= b[3] and f.position.y >= b[2] and f.position.y <= b[4] then return {furnace} end
    return {}
  end, get_tile=function() return {name='grass-1'} end}
  local t = T.plan(fs, long, {x=31.5, y=130.5}, 4)
  eq(t.drop, 'stone-furnace (30,130)'); eq(t.missing, 'no pickup target', 'the furnace takes its items; nothing at its pickup')
  eq(fs.find_entities_filtered{position={x=31.5-2.2, y=130.5}}[1], nil, 'the unrounded point misses the box')
end
print('targets: ok')
