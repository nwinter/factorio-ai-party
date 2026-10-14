-- Run from repository root: lua tests/inputs.lua
-- A crafting machine's input against its recipe (inputs.lua; Grok, shift11: an electromagnetic plant on
-- electronic-circuit read item_ingredient_shortage 12 times while it held 135 iron plates and no copper cable).
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
defines = {inventory = {assembling_machine_input = 2, furnace_source = 2}}
prototypes = {recipe = {}}
local I = dofile('mod/agent-harness_0.1.0/inputs.lua'){}

local circuit = {name = 'electronic-circuit', ingredients = {{type = 'item', name = 'iron-plate', amount = 1},
  {type = 'item', name = 'copper-cable', amount = 3}}}
local inserters = {}
local surface = {find_entities_filtered = function(f)
  eq(f.type, 'inserter')
  local out = {}
  for _, e in ipairs(inserters) do
    if e.position.x >= f.area[1][1] and e.position.x <= f.area[2][1] and e.position.y >= f.area[1][2] and e.position.y <= f.area[2][2] then
      out[#out + 1] = e
    end
  end
  return out
end}
local force = {name = 'player'}
local function plant(input, recipe, fluids)
  return {valid = true, name = 'electromagnetic-plant', type = 'assembling-machine', position = {x = 23, y = 73},
    surface = surface, force = force, bounding_box = {left_top = {x = 21, y = 71}, right_bottom = {x = 25, y = 75}},
    get_recipe = function() return recipe or circuit end, get_fluid_contents = function() return fluids or {} end,
    get_inventory = function(i) eq(i, 2); return {get_item_count = function(name) return input[name] or 0 end} end}
end
local function belt(x, y, items)
  return {valid = true, name = 'transport-belt', type = 'transport-belt', position = {x = x, y = y},
    get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(i) return {get_item_count = function(name) return i == 1 and (items[name] or 0) or 0 end} end}
end
local function chest(x, y, items)
  return {valid = true, name = 'iron-chest', type = 'container', position = {x = x, y = y},
    get_item_count = function(name) return items[name] or 0 end}
end
local function inserter(x, y, drop, pickup, extra)
  local e = {valid = true, name = 'fast-inserter', type = 'inserter', position = {x = x, y = y}, drop_target = drop, pickup_target = pickup}
  for k, v in pairs(extra or {}) do e[k] = v end
  inserters[#inserters + 1] = e
  return e
end

-- 1. Grok's plant: 135 iron plates, no copper cable; its feeders, the one whose source holds cable first.
local em = plant({['iron-plate'] = 135})
inserter(20.5, 72.5, em, belt(19.5, 72.5, {['iron-plate'] = 12}))
inserter(20.5, 73.5, em, chest(19.5, 73.5, {['copper-cable'] = 40}))
inserter(25.5, 72.5, em, belt(26.5, 72.5, {['copper-cable'] = 7}), {use_filters = true, inserter_filter_mode = 'whitelist',
  filter_slot_count = 5, get_filter = function(i) return i == 1 and {name = 'iron-plate', quality = 'normal'} or nil end})
inserter(25.5, 74.5, {}, chest(26.5, 74.5, {}))  -- drops into something else
local r = I.check(em, 'item_ingredient_shortage')
eq(r.input_imbalance, 'iron-plate 135 in input, copper-cable 0: item_ingredient_shortage on copper-cable')
eq(#r.feeders, 3, 'the three that drop into it')
eq(r.feeders[1], 'fast-inserter (20.5,73.5) from iron-chest (19.5,73.5): copper-cable 40 there')
eq(r.feeders[2], 'fast-inserter (20.5,72.5) from transport-belt (19.5,72.5): copper-cable 0 there')
eq(r.feeders[3], 'fast-inserter (25.5,72.5) from transport-belt (26.5,72.5): its filter keeps copper-cable out', 'its belt holds cable')

-- 2. No feeder's source holds it: said first.
inserters[2].pickup_target = chest(19.5, 73.5, {['iron-plate'] = 3})
r = I.check(em, 'item_ingredient_shortage')
eq(r.feeders[1], 'no copper-cable for its 3 feeders: none at their sources, or a filter keeps it out')

-- 3. Short of a craft (1 of 3) is short too.
r = I.check(plant({['iron-plate'] = 60, ['copper-cable'] = 1}), 'item_ingredient_shortage')
eq(r.input_imbalance, 'iron-plate 60 in input, copper-cable 1 (a craft takes 3): item_ingredient_shortage on copper-cable')

-- 4. Nothing stacked (an empty or starved machine), or everything there: nothing to flag.
eq(I.check(plant({['iron-plate'] = 3}), 'item_ingredient_shortage'), nil, 'iron for 3 crafts only: no imbalance')
eq(I.check(plant({}), 'item_ingredient_shortage'), nil)
eq(I.check(plant({['iron-plate'] = 50, ['copper-cable'] = 9}), 'working'), nil)

-- 5. A fluid ingredient missing: it comes through pipes.
local acid = {name = 'battery', ingredients = {{type = 'item', name = 'iron-plate', amount = 1}, {type = 'item', name = 'copper-plate', amount = 1},
  {type = 'fluid', name = 'sulfuric-acid', amount = 20}}}
r = I.check(plant({['iron-plate'] = 40, ['copper-plate'] = 40}, acid, {}), 'fluid_ingredient_shortage')
eq(r.input_imbalance, 'iron-plate 40, copper-plate 40 in input, sulfuric-acid 0: fluid_ingredient_shortage on sulfuric-acid')
eq(r.feeders[1], 'sulfuric-acid comes through its pipes (inspect fluid_connections)')

-- 6. No inserter drops into it.
inserters = {}
r = I.check(em, 'item_ingredient_shortage')
eq(r.feeders[1], 'no inserter drops into it')

-- An inserter with no drop target yet (built this tick) whose drop point is on the plant counts.
inserters = {}
inserter(22.5, 70.5, nil, chest(22.5, 69.5, {['copper-cable'] = 5}), {drop_position = {x = 22.5, y = 71.7}})
inserter(26.5, 70.5, nil, chest(26.5, 69.5, {['copper-cable'] = 5}), {drop_position = {x = 26.5, y = 71.7}})
r = I.check(em, 'item_ingredient_shortage')
eq(#r.feeders, 1, 'the one whose drop point is on the plant')
eq(r.feeders[1], 'fast-inserter (22.5,70.5) from iron-chest (22.5,69.5): copper-cable 5 there')
-- Another status (no power) is named apart from the missing ingredient.
inserters = {}
eq(I.check(plant({['iron-plate'] = 135}), 'no_power').input_imbalance, 'iron-plate 135 in input, copper-cable 0 (status no_power)')
-- 7. Not a crafting machine, or no recipe: nothing.
eq(I.check({type = 'container'}), nil)
local idle = plant({['iron-plate'] = 100}); idle.get_recipe = function() return nil end
eq(I.check(idle), nil)
print('inputs: ok')
