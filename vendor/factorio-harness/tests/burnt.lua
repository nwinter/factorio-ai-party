-- Run from repository root: lua tests/burnt.lua
-- A burner stopped by its full burnt-result slot (burnt.lua; Sol, shift14 03:54: two agricultural science biochambers
-- read working and made nothing, spoilage*200 in the burnt-result slot and spoilage in the fuel slot). Fake engine
-- shaped as 2.0.77 showed it on a copy of world n's save from then: one fuel slot, one burnt-result slot, spoilage
-- stacks to 200, a biochamber burns nutrients only, energy 0 and nothing burning while the status reads working.
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local ITEMS = {spoilage={stack_size=200, fuel_category='chemical'}, nutrients={stack_size=50, fuel_category='nutrients'},
  ['depleted-uranium-fuel-cell']={stack_size=50}, ['uranium-fuel-cell']={stack_size=50, fuel_category='nuclear'}}
local function stack(name, count, quality)
  if not name then return {valid_for_read=false} end
  return {valid_for_read=true, name=name, count=count, quality={name=quality or 'normal'}, prototype=ITEMS[name]}
end
local function inv(...) local t = {...}; return t end
local function burner(fuel, burnt, remaining, cats)
  return {inventory=fuel, burnt_result_inventory=burnt, remaining_burning_fuel=remaining or 0, fuel_categories=cats or {nutrients=true}}
end
local B = dofile('mod/agent-harness_0.1.0/burnt.lua'){}
-- Sol's chamber: stopped, the spoilage in the fuel slot is not a fuel it burns.
local chamber = {burner=burner(inv(stack('spoilage', 3)), inv(stack('spoilage', 200)))}
local f = B.stuck(chamber)
eq(f.burnt, 'spoilage*200'); eq(f.fuel, 'spoilage*3'); eq(f.foreign, 'spoilage'); eq(f.burns, 'nutrients')
eq(B.line(chamber, nil, 'working'), 'its burnt-result slot is full (spoilage*200); its fuel slot holds spoilage*3, which it does not burn (it burns nutrients): nothing burns, it has no energy (the game\'s status reads working)')
-- Full but still burning: not stopped yet; inspect says when it stops.
local burning = {burner=burner(inv(stack('nutrients', 4)), inv(stack('spoilage', 200)), 1000)}
eq(B.stuck(burning), nil)
eq(B.line(burning), 'its burnt-result slot is full (spoilage*200); its fuel slot holds nutrients*4: it burns nothing more once the fuel burning now runs out')
-- Room left in the slot, no burnt-result slot, no burner: nothing.
eq(B.full({burner=burner(inv(stack('spoilage', 3)), inv(stack('spoilage', 199)))}), nil)
eq(B.full({burner=burner(inv(stack('nutrients', 3)), inv(stack()))}), nil)
eq(B.full({burner=burner(inv(stack('nutrients', 3)), {})}), nil)
eq(B.full({}), nil)
eq(B.line({}), nil)
-- A reactor whose spent cells fill its slot: stopped with fuel it does burn; quality shown.
local reactor = {burner=burner(inv(stack('uranium-fuel-cell', 10)), inv(stack('depleted-uranium-fuel-cell', 50, 'rare')), 0, {nuclear=true})}
f = B.stuck(reactor)
eq(f.foreign, nil); eq(f.burnt, 'depleted-uranium-fuel-cell@rare*50')
eq(B.line(reactor, nil, 'no_fuel'), 'its burnt-result slot is full (depleted-uranium-fuel-cell@rare*50); its fuel slot holds uranium-fuel-cell*10: nothing burns, it has no energy')
-- An entity whose burner read errors (a ghost): nothing.
eq(B.stuck(setmetatable({}, {__index=function() error('not a burner') end})), nil)
print('burnt: ok')
