-- Run from repository root: lua tests/loadout.lua
-- What each agent carries, wears and builds (loadout.lua; Nick, 08:55): the operator read `loadout`.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
defines = {inventory={character_main=1, character_guns=2, character_ammo=3, character_armor=4}}
game = {tick=500}
local function st(name, count, q) return {valid_for_read=true, name=name, count=count, quality=q and {name=q} or {name='normal'}} end
local empty = {valid_for_read=false}
local function inv(list, contents)
  local t = {}
  for i, s in ipairs(list) do t[i] = s end
  t.get_contents = function() return contents or {} end
  t.count_empty_stacks = function() local n = 0; for _, s in ipairs(list) do if not s.valid_for_read then n = n + 1 end end; return n end
  return setmetatable(t, {__len=function() return #list end})
end
local grid = {shield=37.4, max_shield=150, available_in_batteries=12.3e6, battery_capacity=40e6, width=10, height=10,
  equipment={{name='energy-shield-equipment', type='energy-shield-equipment'}, {name='energy-shield-equipment', type='energy-shield-equipment'},
    {name='personal-laser-defense-equipment', type='active-defense-equipment'}, {name='battery-mk2-equipment', type='battery-equipment'},
    {name='night-vision-equipment', type='night-vision-equipment'}}}
local suit = st('power-armor-mk2', 1, 'rare'); suit.grid = grid
local inventories = {
  [2]=inv({st('submachine-gun', 1), st('rocket-launcher', 1), empty}),
  [3]=inv({st('piercing-rounds-magazine', 187), st('rocket', 40), empty}),
  [4]=inv({suit}),
}
local main = inv({st('iron-plate', 400), empty, empty, empty}, {{name='iron-plate', quality='normal', count=400},
  {name='copper-cable', quality='normal', count=1200}, {name='stone-furnace', quality='normal', count=12},
  {name='solar-panel', quality='uncommon', count=3}})
local tank_grid = {shield=0, max_shield=0, available_in_batteries=0, battery_capacity=0, width=6, height=8,
  equipment={{name='energy-shield-equipment', type='energy-shield-equipment'}, {name='personal-laser-defense-equipment', type='active-defense-equipment'}}}
local character = {valid=true, health=212.6, max_health=350, surface={name='nauvis'}, selected_gun_index=1,
  vehicle={name='tank', grid=tank_grid}}
local astra = {valid=true, character=character, get_inventory=function(i) return inventories[i] end, get_main_inventory=function() return main end,
  crafting_queue={{recipe='iron-gear-wheel', count=10, prerequisite=true}, {recipe='electronic-circuit', count=20}, {recipe='inserter', count=5}},
  crafting_queue_progress=0.4567}
local dead = {valid=true, character=nil}
local actives = {[1]={kind='construct', built=7, remaining=13, missing={['stone-wall']=40}}, [2]=false}
local L = dofile('mod/agent-harness_0.1.0/loadout.lua'){
  agents=function() return {{index=1, name='astra', display_name='Astra'}, {index=2, name='sol'}, {index=3, name='luna'}} end,
  lookup=function(i) return i == 1 and astra or i == 2 and dead or nil end,
  active=function(i) return actives[i] end}
local r = L.operator.loadout({})
eq(r.tick, 500); eq(#r.agents, 3)
local a = r.agents[1]
eq(a.name, 'astra'); eq(a.display_name, 'Astra'); eq(a.alive, true); eq(a.surface, 'nauvis'); eq(a.vehicle, 'tank')
eq(a.health.now, 213); eq(a.health.max, 350)
-- guns and ammo by slot, the selected gun
eq(a.guns[1].name, 'submachine-gun'); eq(a.guns[2].name, 'rocket-launcher'); eq(a.guns[3], false); eq(a.selected_gun, 1)
eq(a.ammo[1].name, 'piercing-rounds-magazine'); eq(a.ammo[1].count, 187); eq(a.ammo[2].count, 40)
-- armor and its grid: equipment by name (most first), shield and battery charge
eq(a.armor.name, 'power-armor-mk2'); eq(a.armor.quality, 'rare')
eq(a.armor.equipment[1].name, 'energy-shield-equipment'); eq(a.armor.equipment[1].count, 2); eq(#a.armor.equipment, 4)
eq(a.armor.shield.now, 37); eq(a.armor.shield.max, 150); eq(a.armor.battery_mj.now, 12.3); eq(a.armor.battery_mj.max, 40)
eq(a.armor.grid.width, 10)
-- the tank it sits in and its own grid (operator 09:13)
eq(a.vehicle_equipment.grid.width, 6); eq(a.vehicle_equipment.grid.height, 8); eq(#a.vehicle_equipment.equipment, 2)
eq(a.vehicle_equipment.equipment[1].name, 'energy-shield-equipment'); eq(a.vehicle_equipment.shield, nil)
-- the main inventory's largest stacks, free slots
eq(a.items[1].name, 'copper-cable'); eq(a.items[1].count, 1200); eq(a.items[2].name, 'iron-plate'); eq(a.items[4].quality, 'uncommon')
eq(a.item_kinds, 4); eq(a.slots.free, 3); eq(a.slots.total, 4)
-- the hand-craft queue (prerequisites left out) with the head's progress
eq(#a.crafting.queue, 2); eq(a.crafting.queue[1].recipe, 'electronic-circuit'); eq(a.crafting.items, 25); eq(a.crafting.progress, 0.46)
-- the build action: done of total, what is missing
eq(a.building.kind, 'construct'); eq(a.building.done, 7); eq(a.building.total, 20); eq(a.building.missing['stone-wall'], 40)
eq(a.shooting, nil)
-- a dead agent, and one with no player or bot
eq(r.agents[2].alive, false); eq(r.agents[2].guns, nil); eq(r.agents[3].alive, false)
-- names and top
r = L.operator.loadout({names={'astra'}, top=2})
eq(#r.agents, 1); eq(#r.agents[1].items, 2)
assert(not pcall(L.operator.loadout, {top=0})); assert(not pcall(L.operator.loadout, {names='astra'}))
-- a build_path counts its cells; shooting; no queue, no armor
actives[1] = {kind='build_path', total=30, next_index=12}
astra.crafting_queue = {}
inventories[4] = inv({empty})
a = L.operator.loadout({names={'astra'}}).agents[1]
eq(a.building.done, 11); eq(a.building.total, 30); eq(a.crafting, nil); eq(a.armor, nil)
actives[1] = {kind='kite'}
a = L.operator.loadout({names={'astra'}}).agents[1]
eq(a.shooting, true); eq(a.building, nil)
-- an inventory read that throws is that agent's error row, not the whole read's
astra.get_main_inventory = function() error('boom') end
a = L.operator.loadout({}).agents[1]
eq(a.name, 'astra'); eq(a.alive, true)
print('loadout: ok')

-- Research/use reads all carried gear, with force isolation and unknowns for unavailable inventories.
local force={name='player'}; astra.force=force; dead.force=force
inventories[4]=inv({suit})
local reads=0
local contents={}
for i=1,12 do contents[#contents+1]={name='bulk-material-'..i,count=10000} end
contents[#contents+1]={name='power-armor-mk2',count=1,quality='rare'}
contents[#contents+1]={name='piercing-rounds-magazine',count=3,quality='normal'}
astra.get_main_inventory=function() return {get_contents=function() reads=reads+1;return contents end} end
local usage=L.usage(force)
eq(#usage.agents,2);eq(usage.force_unknown,1);eq(reads,1)
a=usage.agents[1];eq(a.armor.name,'power-armor-mk2');eq(a.equipment_known,true)
eq(a.guns_known,true);eq(a.ammo_known,true);eq(a.carried[14].name,'piercing-rounds-magazine')
eq(usage.agents[2].alive,false);eq(usage.agents[2].carried,nil)
dead.force={name='other'};eq(#L.usage(force).agents,1)
local get=astra.get_inventory
astra.get_inventory=function(id) if id==2 then error('inventory unavailable') end; return get(id) end
astra.get_main_inventory=function() error('inventory unavailable') end
a=L.usage(force).agents[1];eq(a.guns_known,false);eq(a.carried,nil);eq(a.ammo_known,true)
local saved=grid.equipment;grid.equipment=nil
setmetatable(grid,{__index=function(_,k) if k=='equipment' then error('grid unavailable') end end})
eq(L.usage(force).agents[1].equipment_known,false)
grid.equipment=saved;setmetatable(grid,nil)
print('loadout usage: ok')
