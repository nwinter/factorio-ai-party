-- Run from repository root: lua tests/conflicts.lua
-- What a planned build takes away (conflicts.lua; Sonnet, shift14 21:20: rich sulfuric acid wells under pipes, poles and
-- tanks). Fake engine shaped as 2.0.77 showed it on a copy of world n: a pipe's fluid box carries its segment's id, a
-- machine's none (it joins segments at its ports, passes nothing through); get_connections gives the joined boxes;
-- poles join by copper wires. There, taking two pipes and a chemical plant off a well split a heavy-oil segment in two
-- (726 -> 726 and 2000) and taking one pole split network 518 into three (549, 550, 518), as the read said.
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(list, text)
  for _, line in ipairs(list or {}) do if line:find(text, 1, true) then return line end end
  error('no line with: '..text..'\n'..table.concat(list or {}, '\n'))
end
defines = {wire_connector_id={pole_copper=5}}
local force = {name='player'}
local neutral = {name='neutral'}
local units = 0
local all = {}
local function box(pos, h) return {left_top={x=pos.x-h, y=pos.y-h}, right_bottom={x=pos.x+h, y=pos.y+h}} end
local OBJECT = {layers={object=true}}
local function ent(name, type_, x, y, o)
  units = units + 1
  local e = {valid=true, name=name, type=type_, position={x=x, y=y}, force=o and o.force or force, unit_number=units,
    bounding_box=box({x=x, y=y}, o and o.half or 0.4),
    prototype={name=name, collision_mask=o and o.mask or OBJECT, electric_energy_source_prototype=o and o.electric or nil,
      get_supply_area_distance=function() return o and o.supply or 0 end}}
  if o and o.amount then e.amount = o.amount; e.prototype.normal_resource_amount = 300000; e.prototype.infinite_resource = true end
  all[#all+1] = e
  return e
end
-- Fluid: boxes {seg, fluid, amount}; links added both ways per box.
local function fluid(e, boxes)
  local fb = {links={}}
  for i, b in ipairs(boxes) do fb[i] = b.fluid and {name=b.fluid, amount=b.amount or 0} or nil; fb.links[i] = {} end
  local mt = {__len=function() return #boxes end}
  fb.get_fluid_segment_id = function(i) return boxes[i].seg end
  fb.get_connections = function(i) return fb.links[i] end
  e.fluidbox = setmetatable(fb, mt)
  return e
end
local function link(a, i, b, j) table.insert(a.fluidbox.links[i], {owner=b}); table.insert(b.fluidbox.links[j], {owner=a}) end
local function wire(a, b)
  a.wires = a.wires or {}; b.wires = b.wires or {}
  table.insert(a.wires, b); table.insert(b.wires, a)
end
local function pole(x, y)
  local p = ent('medium-electric-pole', 'electric-pole', x, y, {supply=3.5, half=0.15})
  p.get_wire_connector = function()
    local list = {}
    for _, o in ipairs(p.wires or {}) do list[#list+1] = {target={owner=o}} end
    return {connections=list}
  end
  return p
end
local function overlaps(b, a)
  local lt, rb = a.left_top or a[1], a.right_bottom or a[2]
  local l, t, r, bt = lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
  return b.left_top.x < r and b.right_bottom.x > l and b.left_top.y < bt and b.right_bottom.y > t
end
local surface = {name='vulcanus'}
surface.find_entities_filtered = function(f)
  local out = {}
  for _, e in ipairs(all) do
    local ok = e.valid
    if ok and f.type then
      if type(f.type) == 'table' then local m = false; for _, t in ipairs(f.type) do if t == e.type then m = true end end; ok = m else ok = e.type == f.type end
    end
    if ok and f.force then ok = e.force == f.force end
    if ok and f.area then ok = overlaps(e.bounding_box, f.area) end
    if ok and f.position and f.radius then ok = ((e.position.x-f.position.x)^2 + (e.position.y-f.position.y)^2)^0.5 <= f.radius end
    if ok then out[#out+1] = e end
  end
  return out
end
local C = dofile('mod/agent-harness_0.1.0/conflicts.lua'){}
local proto = {name='pumpjack', collision_mask=OBJECT, mining_drill_radius=0.49, electric_energy_source_prototype={}}
local function target(x, y) return {proto=proto, pos={x=x, y=y}, dir=0, box=box({x=x, y=y}, 1.2)} end
local p = {surface=surface, force=force}

-- A well at (0.5,0.5) under a pipe B of a heavy-oil line A - B - C - D, a machine M at A's end, a tree, a cliff, a
-- ghost, a character (no blocker) and another force's chest.
local well = ent('sulfuric-acid-geyser', 'resource', 0.5, 0.5, {amount=993000, mask={layers={resource=true}}})
local A = fluid(ent('pipe', 'pipe', -2.5, 0.5), {{seg=7, fluid='heavy-oil', amount=50}})
local B = fluid(ent('pipe', 'pipe', -0.5, 0.5), {{seg=7, fluid='heavy-oil', amount=50}})
local Cc = fluid(ent('pipe', 'pipe', 1.5, 3.5), {{seg=7, fluid='heavy-oil', amount=50}})
local D = fluid(ent('pipe', 'pipe', 2.5, 3.5), {{seg=7, fluid='heavy-oil', amount=50}})
local M = fluid(ent('chemical-plant', 'assembling-machine', -5.5, 0.5, {half=1.4}), {{seg=nil, fluid='heavy-oil', amount=10}})
link(A, 1, B, 1); link(B, 1, Cc, 1); link(Cc, 1, D, 1); link(M, 1, A, 1)
ent('tree-01', 'tree', 1.5, -0.5, {force=neutral})
ent('cliff-gleba', 'cliff', 0.5, 1.5, {force=neutral, half=0.3})
local ghost = ent('entity-ghost', 'entity-ghost', -0.5, -0.5); ghost.ghost_name = 'inserter'; ghost.ghost_prototype = {collision_mask=OBJECT}
ent('character', 'character', 0.2, 0.2)
ent('iron-chest', 'container', 1.5, 1.5, {force={name='enemy-base'}})
local r = C.read(p, {}, target(0.5, 0.5))
eq(r.line, '5 in the way: cliff*1 force enemy-base*1 ghost*1 ours*1 tree or rock*1')
eq(r.remove[1].name, 'pipe'); eq(r.remove[1].kind, 'ours')
eq(r.resource, 'sulfuric-acid-geyser (0.5,0.5): 331% yield')
has(r.fluid, 'pipe (-0.5,0.5) (heavy-oil segment, 50 in these): taking them away splits it into 2: [chemical-plant (-5.5,0.5); 1 pipe] and [no machine; 2 pipes]')
eq(r.power, nil); eq(r.unpowered_after, nil)
eq(r.supplied_by, 'no pole\'s supply area reaches it')
-- A ring: A - E - C beside A - B - C: taking B away splits nothing.
local E = fluid(ent('pipe', 'pipe', -2.5, 5.5), {{seg=7, fluid='heavy-oil', amount=50}})
link(A, 1, E, 1); link(E, 1, Cc, 1)
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, ': the 2 entities joining them stay joined through other pipes')
-- A machine passes no fluid between its ports (2.0.77: a chemical plant's two pipes on one box read two segments):
-- M joins A and F, and still A and F part once B goes.
E.valid = false
local F = fluid(ent('pipe', 'pipe', -6.5, 3.5), {{seg=7, fluid='heavy-oil', amount=50}})
link(M, 1, F, 1); link(F, 1, D, 1)
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, 'splits it into 2: [chemical-plant (-5.5,0.5); 1 pipe] and [chemical-plant (-5.5,0.5); 3 pipes]')
-- A machine whose port joins the removed pipe and another pipe of the segment stays joined through that one; with no
-- other, it is cut off on its own.
local M2 = fluid(ent('assembling-machine-3', 'assembling-machine', 0.5, -4.5, {half=1.4}), {{seg=nil, fluid='heavy-oil', amount=5}})
link(M2, 1, B, 1); link(M2, 1, F, 1)
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, 'splits it into 2: [chemical-plant (-5.5,0.5); 1 pipe] and [chemical-plant (-5.5,0.5), assembling-machine-3 (0.5,-4.5); 3 pipes]')
F.valid = false
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, 'splits it into 3: [chemical-plant (-5.5,0.5); 1 pipe] and [no machine; 2 pipes] and [assembling-machine-3 (0.5,-4.5); 0 pipes]')
M2.valid = false
-- Two pipes of the segment in the way, side by side (Sonnet's wells had four): neither starts a walk for the other.
local B2 = fluid(ent('pipe', 'pipe', 0.5, 1.5), {{seg=7, fluid='heavy-oil', amount=50}})
link(B, 1, B2, 1)
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, 'pipe (-0.5,0.5), pipe (0.5,1.5) (heavy-oil segment, 100 in these): taking them away splits it into 2: [chemical-plant (-5.5,0.5); 1 pipe] and [no machine; 2 pipes]')
B2.valid = false
-- A long side: once the split is decided the last walk goes on 300 steps more, then stops.
local prev = D
for i = 1, 400 do
  local q = fluid(ent('pipe', 'pipe', 2.5 + i, 3.5), {{seg=7, fluid='heavy-oil', amount=1}})
  link(prev, 1, q, 1); prev = q
end
r = C.read(p, {}, target(0.5, 0.5))
has(r.fluid, 'and [no machine; at least ')
has(r.fluid, ' pipes (not walked to its end)]')
for _, e in ipairs(all) do if e.position.y == 3.5 and e.position.x > 3 then e.valid = false end end
-- Something whose collision mask misses the pumpjack's (a rail's layers) is not in its way.
ent('straight-rail', 'straight-rail', 0.5, -0.5, {mask={layers={rail=true}}})
r = C.read(p, {}, target(0.5, 0.5))
for _, row in ipairs(r.remove) do assert(row.name ~= 'straight-rail', 'a rail is not in a pumpjack\'s way') end
-- A machine in the way: its ports join segments; it splits none.
for _, e in ipairs(all) do if e.type ~= 'resource' then e.valid = false end end
local plant = fluid(ent('chemical-plant', 'assembling-machine', 0.5, 0.5, {half=1.4}), {{seg=nil, fluid='steam', amount=20}, {seg=nil}})
local P1 = fluid(ent('pipe', 'pipe', 2.5, 0.5), {{seg=9, fluid='steam', amount=100}})
link(plant, 1, P1, 1)
r = C.read(p, {}, target(0.5, 0.5))
eq(r.fluid[1], 'chemical-plant (0.5,0.5) is a machine (its fluid boxes are no part of a segment): its ports join pipe (2.5,0.5) (steam); taking it away splits no segment')
plant.valid = false; P1.valid = false

-- Power: a pole in the way wired to two poles: one leads to a group with a drill and no power source, the other to two
-- poles with a solar panel; both are cut off from each other.
local X = pole(0.5, -0.5)
local L1 = pole(-6.5, -0.5)
local drill = ent('electric-mining-drill', 'mining-drill', -8.5, -0.5, {electric={}, half=1.4})
local R1 = pole(6.5, -0.5)
local R2 = pole(12.5, -0.5)
local solar = ent('solar-panel', 'solar-panel', 14.5, -0.5, {electric={}, half=1.4})
wire(X, L1); wire(X, R1); wire(R1, R2)
local ins = ent('inserter', 'inserter', 2.5, -3.5, {electric={}, half=0.15})
r = C.read(p, {}, target(0.5, 0.5))
eq(r.power[1], 'medium-electric-pole (0.5,-0.5) (network nil): its wires to medium-electric-pole (-6.5,-0.5), medium-electric-pole (6.5,-0.5) go')
has(r.power, 'cut off: 1 pole (medium-electric-pole (-6.5,-0.5)) with 1 machine in their supply areas (electric-mining-drill*1); no generator, solar panel or accumulator among them')
has(r.power, 'cut off: 2 poles (medium-electric-pole (6.5,-0.5), medium-electric-pole (12.5,-0.5)) with 1 machine in their supply areas (solar-panel*1); 1 of them make or store power')
eq(r.unpowered_after[1], 'inserter (2.5,-3.5)')
eq(r.supplied_by, 'no pole\'s supply area reaches it once these are gone')
-- Two poles in the way wired to each other: neither names the other among the wires that go.
local X2 = pole(1.5, 1.5)
wire(X, X2)
r = C.read(p, {}, target(0.5, 0.5))
eq(r.power[1], 'medium-electric-pole (0.5,-0.5) (network nil): its wires to medium-electric-pole (-6.5,-0.5), medium-electric-pole (6.5,-0.5) go')
eq(r.power[2], 'medium-electric-pole (1.5,1.5) (network nil): no wire to a pole left')
X2.valid = false
-- A second wire path between the two sides: they stay joined; a pole beside the well supplies it.
wire(L1, R2)
local near = pole(2.5, -1.5)
r = C.read(p, {}, target(0.5, 0.5))
has(r.power, 'the 2 poles it joined stay joined through other wires')
eq(r.supplied_by, 'medium-electric-pole (2.5,-1.5)')
eq(r.unpowered_after, nil, 'the inserter is in the pole beside the well\'s area too')
-- Nothing in the way.
for _, e in ipairs(all) do if e.type ~= 'resource' then e.valid = false end end
r = C.read(p, {}, target(0.5, 0.5))
eq(r.line, 'nothing stands in its way'); eq(#r.remove, 0)
print('conflicts: ok')
