-- Run from repository root: lua tests/round1950c.lua
-- Cargo pods still in the air when a platform stops (pods.lua; Grok, shift13: 519 production packs were in the air
-- while the pad and where_is showed none) in where_is and the arrival line; the construction robot read (robots.lua;
-- Astra, shift13: Fulgora's only construction robot stalled 3 times holding removed modules with nowhere to put them).
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
local function has(s, part) assert(type(s) == 'string' and s:find(part, 1, true), tostring(s) .. ' lacks ' .. part) end
local function fails(fn, text) local ok, err = pcall(fn); assert(not ok and tostring(err):find(text, 1, true), tostring(err)) end
defines = {inventory={cargo_unit=2, robot_cargo=1, chest=1},
  robot_order_type={construct=2, pickup=0, deliver=7, repair=1, deconstruct=3, deliver_items=4, upgrade=5, explode_cliff=6, pickup_items=8}}
game = {tick=0, forces={}, surfaces={}}
local st = {}
local function state() return st end

-- 1. pods.lua: a pod on a stopped platform's surface is followed down by reference.
local P = dofile('mod/agent-harness_0.1.0/pods.lua'){state=state}
local function inv(list)
  local o = {list=list}
  o.get_contents = function() return list end
  return o
end
local pad = {valid=true, position={x=52, y=54}, surface={name='nauvis'}}
local nauvis = {name='nauvis', valid=true}
local pods_on_deck = {}
local deck = {name='platform-1', valid=true, find_entities_filtered=function(f) eq(f.type, 'cargo-pod'); return pods_on_deck end}
local function pod(unit, items, dest)
  local cargo = inv(items)
  local p = {valid=true, unit_number=unit, cargo_pod_state='awaiting_launch', surface=deck, position={x=0, y=0}, cargo_pod_destination=dest}
  p.get_inventory = function(i) eq(i, defines.inventory.cargo_unit); return cargo end
  p.cargo = cargo
  return p
end
local sunward = {valid=true, name='Sunward', space_location={name='nauvis'}, surface=deck}
game.forces.player = {name='player', platforms={sunward}}
local a = pod(1, {{name='production-science-pack', count=300, quality='normal'}}, {type=1, station=pad})
local b = pod(2, {{name='production-science-pack', count=219, quality='normal'}, {name='iron-plate', count=10, quality='rare'}}, {type=1, station=pad})
local up = pod(3, {{name='coal', count=50, quality='normal'}}, {type=1, surface=deck})  -- one going up to the platform itself
pods_on_deck = {a, b, up}
P.tick(60)
local flying = P.in_flight('player', 'nauvis')
eq(#flying, 2); eq(flying[1].platform, 'Sunward'); eq(flying[1].state, 'awaiting_launch'); eq(flying[1].pad.x, 52)
eq(flying[2].items['iron-plate@rare'], 10)
-- The same entities go on down on the planet's surface: still followed.
pods_on_deck = {}
a.surface, a.cargo_pod_state = nauvis, 'descending'
b.cargo_pod_state = 'surface_transition'
P.tick(120)
eq(P.line('player', 'nauvis', 'Sunward'), '2 cargo pods from Sunward still in the air: production-science-pack*519 iron-plate@rare*10 (to the landing pad at (52,54); 1 descending, 1 surface_transition)')
eq(P.line('player', 'nauvis', 'Starling'), nil)
eq(P.line('player', 'vulcanus'), nil)
-- Landed (gone): forgotten.
a.valid = false
P.tick(180)
eq(#P.in_flight('player', 'nauvis'), 1)
b.valid = false
P.tick(240)
eq(P.line('player', 'nauvis'), nil)
-- A platform in flight between stops sends none: its surface is not read.
sunward.space_location = nil
pods_on_deck = {pod(4, {{name='coal', count=1, quality='normal'}}, {type=1, station=pad})}
P.tick(300)
eq(#P.in_flight('player', 'nauvis'), 0)
sunward.space_location = {name='nauvis'}
-- Not on a sample tick: nothing read.
P.tick(301)
eq(#P.in_flight('player', 'nauvis'), 0)

-- 2. where_is lists the pods in the air toward the surface asked about.
local S = dofile('mod/agent-harness_0.1.0/stores.lua'){pods=P, agents=function() return {} end, character=function() return nil end}
prototypes = {item={['production-science-pack']={name='production-science-pack'}}}
local c = pod(5, {{name='production-science-pack', count=300, quality='normal'}}, {type=1, station=pad})
pods_on_deck = {c}
P.tick(360)
local surface = {name='nauvis', find_entities_filtered=function() return {} end}
local me = {surface=surface, position={x=0, y=0}, force={name='player'}}
local w = S.where_is(me, {item='production-science-pack'})
eq(w.by_kind.in_flight, 300); eq(#w.in_flight, 1)
eq(w.in_flight[1].platform, 'Sunward'); eq(w.in_flight[1].state, 'awaiting_launch'); eq(w.in_flight[1].lands, 'landing pad (52,54)')
eq(w.note, nil)

-- 3. The arrival line names them (freight.lua event_lines).
local F = dofile('mod/agent-harness_0.1.0/freight.lua'){state=state, spoil=nil, pods=P}
game.tick = 400
F.event({name='Sunward', force={name='player'}}, 'arrived', 'nauvis', 400)
game.tick = 460
local agent = {surface={planet={name='nauvis'}, name='nauvis'}, force={name='player'}}
local lines = F.event_lines(agent, {})
eq(#lines, 1)
eq(lines[1], 'platform Sunward stopped at nauvis, your planet, 1s ago; 1 cargo pod from Sunward still in the air: production-science-pack*300 (to the landing pad at (52,54); 1 awaiting_launch)')
c.valid = false; P.tick(420)
F.event({name='Sunward', force={name='player'}}, 'arrived', 'nauvis', 460)
lines = F.event_lines(agent, {platform_event_seq=1})
eq(lines[1], 'platform Sunward stopped at nauvis, your planet, 0s ago')

-- 4. robots.lua: each robot in the air with what holds it up.
local R = dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return {x=v.x or v[1], y=v.y or v[2]} end}
local function robot(x, y, energy, cargo, queue)
  local r = {valid=true, name='construction-robot', position={x=x, y=y}, energy=energy, prototype={max_energy=3000000}, robot_order_queue=queue or {}}
  local ci = inv(cargo or {})
  r.get_inventory = function(i) eq(i, defines.inventory.robot_cargo); return ci end
  return r
end
local ghost = {valid=true, type='entity-ghost', ghost_name='assembling-machine-2', name='entity-ghost', position={x=10.5, y=3.5}}
local far = {valid=true, type='entity-ghost', ghost_name='stone-furnace', name='entity-ghost', position={x=200, y=0}}
local chest = {valid=true, type='logistic-container', name='passive-provider-chest', position={x=-31.5, y=3.5}}
local mods = robot(5, 5, 2400000, {{name='speed-module', count=2, quality='normal'}})
local builder = robot(1, 1, 1500000, {}, {{type=0, target=chest, target_item={name={name='assembling-machine-2'}, quality={name='normal'}}, target_count=1}, {type=2, target=ghost}})
local stray = robot(150, 0, 2000000, {}, {{type=2, target=far}})
local tired = robot(0, 2, 300000, {})
local resting = robot(0, 3, 400000, {})
local owner = {valid=true, name='roboport', position={x=0, y=0}, unit_number=77}
local cell = {owner=owner, charging_robots={resting}, to_charge_robots={robot(9, 9, 1, {}), tired}, to_charge_robot_count=2, charging_robot_count=1,
  is_in_construction_range=function(pos) return math.abs(pos.x) < 55 and math.abs(pos.y) < 55 end}
local storage_room = {}
local net = {valid=true, network_id=7, construction_robots={mods, builder, stray, tired, resting}, all_construction_robots=12, available_construction_robots=7,
  cells={cell}, storages={},
  find_cell_closest_to=function() return cell end,
  select_drop_point=function(s) return storage_room[s.stack.name] end}
local force = {logistic_networks={nauvis={net}}, find_logistic_network_by_position=function(pos) return math.abs(pos.x) < 100 and net or nil end}
local reader = {surface={name='nauvis'}, position={x=0, y=0}, force=force}
local r = R.read(reader, {})
eq(r.network, 7)
eq(r.summary, 'network 7: 12 construction robots (7 in roboports, 5 in the air, 4 held up); 1 roboport; 0 storage chests')
eq(r.robots[1], 'construction-robot (5,5): energy 80%; holds speed-module*2; no order; nowhere to put speed-module*2: no storage chest in network 7 has room for it (0 storage chests in it)')
eq(r.robots[2], 'construction-robot (1,1): energy 50%; holds nothing; orders: pickup passive-provider-chest at (-31.5,3.5) (item assembling-machine-2); then construct assembling-machine-2 ghost at (10.5,3.5)')
eq(r.robots[3], 'construction-robot (150,0): energy 67%; holds nothing; order: construct stone-furnace ghost at (200,0); its target stone-furnace (200,0) is outside the network\'s construction area')
eq(r.robots[4], 'construction-robot (0,2): energy 10%; holds nothing; no order; waiting to charge at roboport (0,0): 2 of 2 in its queue (1 charging now)')
eq(r.robots[5], 'construction-robot (0,3): energy 13%; holds nothing; no order; charging at roboport (0,0)')
eq(r.charging_queues[1], 'roboport (0,0): 2 waiting, 1 charging')
-- With room for the modules, the robot is taking them there: nothing holds it up.
storage_room['speed-module'] = {owner=chest}
r = R.read(reader, {network=7})
eq(r.robots[1], 'construction-robot (5,5): energy 80%; holds speed-module*2; no order')
-- By position; none there names the nearest network.
r = R.read(reader, {position={x=5, y=5}})
eq(r.network, 7)
fails(function() R.read(reader, {position={x=500, y=0}}) end, 'no logistic network of ours covers (500,0) on nauvis; the nearest: network 7, roboport (0,0), 500 tiles away')
fails(function() R.read(reader, {network=9}) end, 'no logistic network 9 of ours on nauvis')
fails(function() R.read(reader, {network='7'}) end, 'network is a network id')
print('round1950c: ok')
