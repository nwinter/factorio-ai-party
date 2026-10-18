-- Run from repository root: lua tests/ports.lua
-- Fluid ports before building (ports.lua): which ports a recipe opens and the
-- fluid at each, from the prototype's fluid boxes as the shift world's engine
-- joins them (2026-10-13, read only: 280 machines' engine connections matched
-- this module's rows, every recipe and direction built there).
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local function conn(flow, dir, positions)
  local ps = {}
  for i, p in ipairs(positions) do ps[i] = {x=p[1], y=p[2]} end
  return {flow_direction=flow, direction=dir, connection_type='normal', positions=ps}
end
-- As the 2.0.77 prototypes read: input boxes face north, output boxes south.
prototypes = {entity={
  ['chemical-plant']={name='chemical-plant', type='assembling-machine', crafting_categories={chemistry=true}, fluidbox_prototypes={
    {production_type='input', pipe_connections={conn('input', 0, {{-1,-1},{1,-1},{1,1},{-1,1}})}},
    {production_type='input', pipe_connections={conn('input', 0, {{1,-1},{1,1},{-1,1},{-1,-1}})}},
    {production_type='output', pipe_connections={conn('output', 8, {{-1,1},{-1,-1},{1,-1},{1,1}})}},
    {production_type='output', pipe_connections={conn('output', 8, {{1,1},{-1,1},{-1,-1},{1,-1}})}}}},
  ['oil-refinery']={name='oil-refinery', type='assembling-machine', crafting_categories={['oil-processing']=true}, fluidbox_prototypes={
    {production_type='input', pipe_connections={conn('input', 8, {{-1,2},{-2,-1},{1,-2},{2,1}})}},
    {production_type='input', pipe_connections={conn('input', 8, {{1,2},{-2,1},{-1,-2},{2,-1}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{-2,-2},{2,-2},{2,2},{-2,2}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{0,-2},{2,0},{0,2},{-2,0}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{2,-2},{2,2},{-2,2},{-2,-2}})}}}},
  ['cryogenic-plant']={name='cryogenic-plant', type='assembling-machine', crafting_categories={['chemistry-or-cryogenics']=true}, fluidbox_prototypes={
    {production_type='input', pipe_connections={conn('input', 8, {{-2,2},{-2,-2},{2,-2},{2,2}})}},
    {production_type='input', pipe_connections={conn('input', 8, {{0,2},{-2,0},{0,-2},{2,0}})}},
    {production_type='input', pipe_connections={conn('input', 8, {{2,2},{-2,2},{-2,-2},{2,-2}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{-2,-2},{2,-2},{2,2},{-2,2}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{0,-2},{2,0},{0,2},{-2,0}})}},
    {production_type='output', pipe_connections={conn('output', 0, {{2,-2},{2,2},{-2,2},{-2,-2}})}}}},
  ['electromagnetic-plant']={name='electromagnetic-plant', type='assembling-machine', crafting_categories={electromagnetics=true}, fluidbox_prototypes={
    {production_type='input', pipe_connections={conn('input-output', 12, {{-1.5,0.5},{-0.5,-1.5},{1.5,-0.5},{0.5,1.5}})}},
    {production_type='input', pipe_connections={conn('input-output', 4, {{1.5,-0.5},{0.5,1.5},{-1.5,0.5},{-0.5,-1.5}})}},
    {production_type='output', pipe_connections={conn('input-output', 8, {{0.5,1.5},{-1.5,0.5},{-0.5,-1.5},{1.5,-0.5}})}},
    {production_type='output', pipe_connections={conn('input-output', 0, {{-0.5,-1.5},{1.5,-0.5},{0.5,1.5},{-1.5,0.5}})}}}},
  boiler={name='boiler', type='boiler', fluidbox_prototypes={
    {production_type='input-output', filter={name='water'}, pipe_connections={conn('input-output', 12, {{-1,0.5},{-0.5,-1},{1,-0.5},{0.5,1}}), conn('input-output', 4, {{1,0.5},{-0.5,1},{-1,-0.5},{0.5,-1}})}},
    {production_type='output', filter={name='steam'}, pipe_connections={conn('output', 0, {{0,-0.5},{0.5,0},{0,0.5},{-0.5,0}})}}}},
}}
local function fluid(name, extra) local f = {type='fluid', name=name}; for k, v in pairs(extra or {}) do f[k] = v end; return f end
prototypes.recipe = {
  lubricant={name='lubricant', category='chemistry', ingredients={fluid('heavy-oil')}, products={fluid('lubricant')}},
  sulfur={name='sulfur', category='chemistry', ingredients={fluid('water'), fluid('petroleum-gas')}, products={{type='item', name='sulfur'}}},
  ['heavy-oil-cracking']={name='heavy-oil-cracking', category='chemistry', ingredients={fluid('water'), fluid('heavy-oil')}, products={fluid('light-oil')}},
  ['plastic-bar']={name='plastic-bar', category='chemistry', ingredients={fluid('petroleum-gas'), {type='item', name='coal'}}, products={{type='item', name='plastic-bar'}}},
  ['basic-oil-processing']={name='basic-oil-processing', category='oil-processing', ingredients={fluid('crude-oil', {fluidbox_index=2})},
    products={fluid('petroleum-gas', {fluidbox_index=3})}},
  ['simple-coal-liquefaction']={name='simple-coal-liquefaction', category='oil-processing', ingredients={fluid('sulfuric-acid')}, products={fluid('heavy-oil')}},
  ['fluoroketone']={name='fluoroketone', category='chemistry-or-cryogenics', ingredients={fluid('fluorine'), fluid('ammonia')}, products={fluid('fluoroketone-hot')}},
  lithium={name='lithium', category='chemistry-or-cryogenics', ingredients={{type='item', name='holmium-plate'}, fluid('lithium-brine'), fluid('ammonia')}, products={{type='item', name='lithium'}}},
  supercapacitor={name='supercapacitor', category='electromagnetics', ingredients={fluid('electrolyte')}, products={{type='item', name='supercapacitor'}}},
  electrolyte={name='electrolyte', category='electromagnetics', ingredients={fluid('heavy-oil'), fluid('holmium-solution')}, products={fluid('electrolyte')}},
}
local pipes = dofile('mod/agent-harness_0.1.0/pipes.lua'){position=function(v) return v end, directions={north=0, east=4, south=8, west=12},
  chunk_of=function(p) return {x=math.floor(p.x/32), y=math.floor(p.y/32)} end}
local ports = dofile('mod/agent-harness_0.1.0/ports.lua'){boxes=pipes.boxes, defined=pipes.defined}
local function view(name, pos, dir, recipe, mirror)
  local rows, closed = ports.rows({prototype=prototypes.entity[name], position=pos, direction=dir, mirroring=mirror},
    recipe and ports.recipe(prototypes.entity[name], recipe))
  local by = {}
  for _, r in ipairs(rows) do by[#by+1] = string.format('%g,%g>%g,%g %s %s %s', r.at.x, r.at.y, r.joins.x, r.joins.y, r.direction, r.flow, r.fluid) end
  table.sort(by)
  return table.concat(by, ' | '), closed
end
-- One fluid a side takes every port of that side (the shift world's chemical plant on lubricant).
local text, closed = view('chemical-plant', {x=10.5, y=0.5}, 0, 'lubricant')
eq(text, '11.5,-0.5>11.5,-1.5 north input heavy-oil | 11.5,1.5>11.5,2.5 south output lubricant | 9.5,-0.5>9.5,-1.5 north input heavy-oil | 9.5,1.5>9.5,2.5 south output lubricant')
eq(#closed, 0)
-- Two fluids, one port each; no fluid out: the output ports are closed.
text, closed = view('chemical-plant', {x=10.5, y=0.5}, 0, 'sulfur')
eq(text, '11.5,-0.5>11.5,-1.5 north input petroleum-gas | 9.5,-0.5>9.5,-1.5 north input water')
eq(#closed, 2); eq(closed[1], 'output 9.5,2.5')
-- Turned east: the inputs face east, the outputs west.
text = view('chemical-plant', {x=0.5, y=0.5}, 4, 'heavy-oil-cracking')
eq(text, '-0.5,-0.5>-1.5,-0.5 west output light-oil | -0.5,1.5>-1.5,1.5 west output light-oil | 1.5,-0.5>2.5,-0.5 east input water | 1.5,1.5>2.5,1.5 east input heavy-oil')
-- fluidbox_index: the box named, and no other (basic oil processing).
text, closed = view('oil-refinery', {x=0, y=0}, 0, 'basic-oil-processing')
eq(text, '1.5,2.5>1.5,3.5 south input crude-oil | 2.5,-1.5>2.5,-2.5 north output petroleum-gas')
eq(#closed, 3)
-- One output fluid: all three outputs (simple coal liquefaction on Vulcanus).
text = view('oil-refinery', {x=0, y=0}, 0, 'simple-coal-liquefaction')
eq(select(2, text:gsub('heavy%-oil', '')), 3); eq(select(2, text:gsub('sulfuric%-acid', '')), 2)
-- The electromagnetic plant facing west on supercapacitor: electrolyte at both inputs (the shift world's plant).
text, closed = view('electromagnetic-plant', {x=0, y=0}, 12, 'supercapacitor')
eq(text, '-0.5,-1.5>-0.5,-2.5 north input electrolyte | 0.5,1.5>0.5,2.5 south input electrolyte')
eq(#closed, 2)
-- ...and on electrolyte: heavy oil and holmium solution apart, electrolyte out at both outputs.
text = view('electromagnetic-plant', {x=0, y=0}, 0, 'electrolyte')
eq(text, '-0.5,-1.5>-0.5,-2.5 north output electrolyte | -1.5,0.5>-2.5,0.5 west input heavy-oil | 0.5,1.5>0.5,2.5 south output electrolyte | 1.5,-0.5>2.5,-0.5 east input holmium-solution')
-- A cryogenic plant: two fluids, three input boxes: the first fluid takes the left and middle boxes as one engine
-- fluidbox (d17 batch30 A1, world n: the plant at (-85.5,-19.5) on Aquilo, north, on lithium: fluidbox 1 lithium-brine
-- at -87.5,-17.5 and -85.5,-17.5, fluidbox 2 ammonia at -83.5,-17.5; no fluid product, so no output boxes).
local rows, shut = ports.rows({prototype=prototypes.entity['cryogenic-plant'], position={x=-85.5, y=-19.5}, direction=0},
  ports.recipe(prototypes.entity['cryogenic-plant'], 'lithium'))
eq(#rows, 3); eq(#shut, 3)
table.sort(rows, function(a, b) return a.at.x < b.at.x end)
eq(rows[1].at.x, -87.5); eq(rows[1].at.y, -17.5); eq(rows[1].joins.y, -16.5); eq(rows[1].fluid, 'lithium-brine'); eq(rows[1].box, 1)
eq(rows[2].at.x, -85.5); eq(rows[2].fluid, 'lithium-brine'); eq(rows[2].box, 1)
eq(rows[3].at.x, -83.5); eq(rows[3].fluid, 'ammonia'); eq(rows[3].box, 2)
for _, r in ipairs(rows) do eq(r.direction, 'south'); eq(r.flow, 'input') end
-- fluoroketone: fluorine on the left and middle, ammonia on the right, the hot fluoroketone out of all three outputs
text = view('cryogenic-plant', {x=0.5, y=0.5}, 0, 'fluoroketone')
eq(text, '-1.5,-1.5>-1.5,-2.5 north output fluoroketone-hot | -1.5,2.5>-1.5,3.5 south input fluorine | 0.5,-1.5>0.5,-2.5 north output fluoroketone-hot'
  ..' | 0.5,2.5>0.5,3.5 south input fluorine | 2.5,-1.5>2.5,-2.5 north output fluoroketone-hot | 2.5,2.5>2.5,3.5 south input ammonia')
rows = ports.rows({prototype=prototypes.entity['cryogenic-plant'], position={x=0.5, y=0.5}, direction=0}, ports.recipe(prototypes.entity['cryogenic-plant'], 'fluoroketone'))
local boxes = {}
for _, r in ipairs(rows) do boxes[r.fluid] = boxes[r.fluid] or {}; boxes[r.fluid][r.box] = true end
assert(boxes['fluorine'][1] and boxes['ammonia'][2] and boxes['fluoroketone-hot'][3] and not boxes['fluoroketone-hot'][4], 'engine box numbers')
-- Mirrored: the H flip of a north-facing chemical plant swaps its two input ports.
text = view('chemical-plant', {x=0.5, y=0.5}, 0, 'sulfur', true)
eq(text, '-0.5,-0.5>-0.5,-1.5 north input petroleum-gas | 1.5,-0.5>1.5,-1.5 north input water')
-- Without a recipe a machine shows every port; a boiler its own filters.
text = view('chemical-plant', {x=0.5, y=0.5}, 0, nil)
eq(select(2, text:gsub('north input', '')), 2); eq(select(2, text:gsub('south output', '')), 2)
text = view('boiler', {x=0, y=0.5}, 0, nil)
assert(text:find('west input%-output water') and text:find('east input%-output water') and text:find('north output steam'), text)
-- A recipe the machine cannot make, and an unknown one.
local ok, err = pcall(ports.recipe, prototypes.entity['chemical-plant'], 'supercapacitor')
assert(not ok and err:find('chemical-plant cannot make supercapacitor (category electromagnetics; it makes chemistry)', 1, true), err)
ok, err = pcall(ports.recipe, prototypes.entity['chemical-plant'], 'nope')
assert(not ok and tostring(err):find('unknown recipe nope', 1, true), err)
print('ports: ok')
