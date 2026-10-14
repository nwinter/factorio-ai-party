-- Run from repository root: lua tests/beltflow.lua
-- Where a belt moves items (beltflow.lua; Grok, shift11: a belt facing south read as feeding the tile at lower y).
-- The connections are shaped as 2.0.77 gave them on a private copy of world n: belt_neighbours inputs and outputs
-- (set in the tick a belt is built), belt_shape 'left' on a belt turning from south to east, both underground ends
-- facing the way items go, and an underground ghost's belt_to_ground_type.
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
local B = dofile('mod/agent-harness_0.1.0/beltflow.lua'){}
local N, E, S, W = 0, 4, 8, 12

local all = {}
local surface = {find_entities_filtered = function(f)
  local out = {}
  for _, e in ipairs(all) do
    local p = e.position
    if p.x >= f.area[1][1] and p.x <= f.area[2][1] and p.y >= f.area[1][2] and p.y <= f.area[2][2] then out[#out + 1] = e end
  end
  return out
end}
local function entity(name, type, x, y, d, extra)
  local e = {valid = true, name = name, type = type, position = {x = x, y = y}, direction = d, surface = surface,
    force = 'player', belt_neighbours = {inputs = {}, outputs = {}}}
  for k, v in pairs(extra or {}) do e[k] = v end
  all[#all + 1] = e
  return e
end
local function belt(x, y, d, shape) return entity('transport-belt', 'transport-belt', x, y, d, {belt_shape = shape or 'straight'}) end
local function under(x, y, d, kind) return entity('underground-belt', 'underground-belt', x, y, d, {belt_to_ground_type = kind}) end
local function splitter(x, y, d) return entity('splitter', 'splitter', x, y, d) end
local function ghost(name, type, x, y, d, extra)
  local g = entity('entity-ghost', 'entity-ghost', x, y, d, extra)
  g.ghost_name, g.ghost_type, g.belt_neighbours = name, type, nil
  return g
end
local function link(from, to)
  table.insert(from.belt_neighbours.outputs, to)
  table.insert(to.belt_neighbours.inputs, from)
end

-- 1. Grok's belt: south is +y.
local a, b, c = belt(-22.5, -30.5, S), belt(-22.5, -29.5, S), belt(-22.5, -28.5, S)
link(a, b); link(b, c)
eq(B.line(b), 'moves items south to (-22.5,-28.5); fed from (-22.5,-30.5)')
eq(B.line(a), 'moves items south to (-22.5,-29.5); no belt feeds it')
eq(B.line(c), 'moves items south to (-22.5,-27.5) (no belt takes them there: they stop at its end); fed from (-22.5,-29.5)')

-- 2. A curve (south, then east): fed from its side.
local s1, curve, e1 = belt(1000.5, 1021.5, S), belt(1000.5, 1022.5, E, 'left'), belt(1001.5, 1022.5, E)
link(s1, curve); link(curve, e1)
eq(B.line(curve), 'moves items east to (1001.5,1022.5); fed from (1000.5,1021.5)')

-- 3. Side-loading: a straight belt fed from behind and from a side; the side belt goes onto its side.
local side, straight = belt(1002.5, 1021.5, S), belt(1002.5, 1022.5, E)
link(side, straight); link(e1, straight)
eq(B.line(straight), 'moves items east to (1003.5,1022.5) (no belt takes them there: they stop at its end); fed from (1001.5,1022.5); side-loaded from (1002.5,1021.5)')
eq(B.line(side), 'moves items south to (1002.5,1022.5) (onto the side of transport-belt facing east); no belt feeds it')

-- 4. An underground pair: the entrance moves items under to its exit, the exit is fed from it.
local feed, ui, uo, after = belt(1005.5, 1019.5, S), under(1005.5, 1020.5, S, 'input'), under(1005.5, 1024.5, S, 'output'), belt(1005.5, 1025.5, S)
ui.neighbours, uo.neighbours = uo, ui
link(feed, ui); link(uo, after)
eq(B.line(ui), 'moves items south underground to (1005.5,1024.5); fed from (1005.5,1019.5)')
eq(B.line(uo), 'moves items south to (1005.5,1025.5); fed underground from (1005.5,1020.5)')
ui.neighbours, uo.neighbours = nil, nil
eq(B.line(ui), 'moves items south underground (no exit end paired); fed from (1005.5,1019.5)')
eq(B.line(uo), 'moves items south to (1005.5,1025.5); no entrance end paired')

-- 5. A splitter: two lanes, west one first; one lane's output taken, one lane fed.
local into, sp, out = belt(1008.5, 1020.5, S), splitter(1009, 1021.5, S), belt(1009.5, 1022.5, S)
link(into, sp); link(sp, out)
eq(B.line(sp), 'moves items south to (1008.5,1022.5) and (1009.5,1022.5) (no belt takes them at (1008.5,1022.5)); fed from (1008.5,1020.5)')
eq(B.line(out), 'moves items south to (1009.5,1023.5) (no belt takes them there: they stop at its end); fed from (1009.5,1021.5)', 'from its lane')
-- A splitter behind a splitter feeds both lanes; one ahead takes both.
local up, mid, down = splitter(1020, 1020.5, S), splitter(1020, 1021.5, S), splitter(1020, 1022.5, S)
link(up, mid); link(mid, down)
eq(B.line(mid), 'moves items south to (1019.5,1022.5) and (1020.5,1022.5); fed from (1019.5,1020.5) and (1020.5,1020.5)')
eq(B.line(splitter(1030.5, 1030, W)):match('^moves items west to %(1029.5,1029.5%) and %(1029.5,1030.5%)') ~= nil, true)

-- 6. Ghosts read what stands around them: behind (straight), a lone side (a curve), head-on in front (none).
all = {}
local real = belt(10.5, 3.5, S)
local g = ghost('transport-belt', 'transport-belt', 10.5, 4.5, S)
eq(B.line(g), 'moves items south to (10.5,5.5); fed from (10.5,3.5)')
real.position = {x = 9.5, y = 4.5}; real.direction = E
eq(B.line(g), 'moves items south to (10.5,5.5); fed from (9.5,4.5)', 'a lone side input: a curve')
ghost('transport-belt', 'transport-belt', 10.5, 3.5, S)
eq(B.line(g), 'moves items south to (10.5,5.5); fed from (10.5,3.5); side-loaded from (9.5,4.5)')
all = {g}
belt(10.5, 5.5, N)
eq(B.line(g), 'moves items south to (10.5,5.5); no belt feeds it', 'a belt ahead facing back meets it head-on')
local gi = ghost('underground-belt', 'underground-belt', 12.5, 4.5, S, {belt_to_ground_type = 'input'})
local go = ghost('underground-belt', 'underground-belt', 12.5, 8.5, S, {belt_to_ground_type = 'output'})
belt(12.5, 3.5, S)
eq(B.line(gi), 'moves items south underground; fed from (12.5,3.5)')
eq(B.line(go), 'moves items south to (12.5,9.5); fed underground')

-- 7. The last belt of a list; anything else gives nil.
local chest = entity('iron-chest', 'container', 0.5, 0.5, N)
eq(B.last({gi, go, chest}), 'underground-belt (12.5,8.5): moves items south to (12.5,9.5); fed underground')
eq(B.last({chest}), nil)
eq(B.line(chest), nil)
eq(B.line(belt(0.5, 0.5, 2)), nil, 'a direction belts do not take')
print('beltflow: ok')
