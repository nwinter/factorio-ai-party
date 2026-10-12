# What the harness lets agents do, feature by feature (branch eng/coverage, COVERAGE.md)

The tools side of "why does the team never use trains, robots, circuits...". The study engineer covers the agents'
side (study/features). Method: every action and argument from the runtime's own `describe` (the source of each agent's
`describe.json`), read against the handlers; each feature tried through the runtime against the fake engine
(`tests/*.lua`, `mod/tests/runtime_test.lua`); the agent prompt files (`agent/PLAYBOOK.md`, `agent/team.md`,
`agent/spaceage.md`) and `vendor/factorio-harness/docs/usage.md` searched for each feature. "Built here" marks what
this branch added.

## Summary

- Most features are reachable today through general actions (`build`, `place_ghosts`, `transfer`, `configure`,
  `requests`, `pipe_route`, `pole_route`, the platform actions). What agents see of them is the problem: the prompts
  name almost none of these features (PLAYBOOK: 0 mentions of trains, roboports, modules, beacons, solar, nuclear or
  turrets; team.md none either), so an agent learns them only from the 107 one-line `describe.json` entries, and
  usage.md said "not supported yet: vehicles, rails, circuit editing".
- Truly missing before this branch: circuit wires and every circuit setting, train stop names and train schedules,
  rails (the rail item could not be built at all), quality on assembler recipes (accepted but a quality-only change was
  reported unchanged). Built here: `wire color=red|green`, `circuit`, `train`, rails in `build`/`construct`,
  `configure quality`.
- Still missing: elevated rails, the selector combinator, storage chest filters. Vehicles are on eng/coverage2,
  waiting for a live check.

## Table

| Feature | Actions (args) | Documented? (describe / usage.md / PLAYBOOK) | Works in tests? | Gap |
|---|---|---|---|---|
| Rails | `build {item: rail, entity: straight-rail\|half-diagonal-rail\|curved-rail-a\|curved-rail-b, direction}` (16 directions); `place_ghosts` with rail entity names, then `construct` | describe yes; usage yes (this branch); PLAYBOOK no | yes (built here: `tests/bots.lua`); before: refused ("only ordinary entity placement", the 2.0 rail item has no place_result) | elevated rails, rail ramps; no rail planner path (each piece placed) |
| Train stops | `build`; `train {position, station, limit}` | describe, usage (built here); PLAYBOOK no | yes (built here, `tests/circuits.lua`) | circuit modes of the stop |
| Locomotives, wagons, schedules | `build`; fuel with `refuel`/`transfer`; `train {position, schedule [{station, wait [{type, ticks, compare, condition}]}], current, automatic}`; cargo with `transfer` (cargo_wagon) | describe, usage (built here); PLAYBOOK no | yes (built here; schedule table setter, LuaSchedule fallback) | interrupts; riding a train (vehicles) |
| Roboports, robots | `build`; robots and repair packs with `transfer` (roboport_robot, roboport_material inventories) | describe (transfer inventories); usage no; PLAYBOOK no | transfer paths yes (inventory table), roboport itself not in a test | none for building; robots then work on their own (place_ghosts marks, deconstruct marks) |
| Items on the ground (spills, full landing pads) | `scan`/`observe` `ground_items` summary; `status` `alerts.ground_items` (full cargo landing pad spilling, piles near buildings; also `team.alerts`); `deconstruct {area, items_on_ground}`; `pickup {area \| position, radius, items}` | describe, usage, PLAYBOOK 1 line | yes (`tests/ground.lua`); live check `tools/live_check_ground.py` | cargo bays of a pad not read; item counts from at most 5000 stacks per place; piles found among at most 30000 stacks per surface |
| Requester / buffer chests, requests | `requests {position, set [{item, min, max, quality}], clear, clear_all, section}`; storage chests as chests | describe yes; usage 1 line; PLAYBOOK no | yes for hub requests (`tests/space.lua`), the requester chest shares the code (only the lookup differs) | storage chest filter (`from_buffers` built here) |
| Character logistics, personal roboport | `requests {target: character}`; armour grid with `equipment {operation: insert\|remove, item, position}`; `equip slot=armor` | describe yes; usage no; PLAYBOOK no | requests yes (shared code); `equipment` has no test | none found |
| Circuit wires | `wire {from, to, color: red\|green, from_side, to_side}` | describe, usage (built here) | yes (built here) | before: copper only |
| Circuit conditions (inserters, belts, lamps, pumps, drills, power switches) | `circuit {position, enable: {signal, comparator, value\|signal2} \| false, logistic: {...}}` | describe, usage (built here) | yes (built here, read switches too: `read {hand, contents, resources, send_to_train, ...}`) | selector combinator |
| Combinators | `circuit {signals, on}` (constant), `{arithmetic}`, `{decider}` (one condition, one output) | describe, usage (built here) | yes (built here) | selector combinator; deciders with several conditions/outputs; display panels |
| Modules | `transfer {position, item: <module>}` (no inventory needed: the module kind picks assembling_machine_modules, furnace_modules, lab_modules, mining_drill_modules) | describe (inventory list); usage no; PLAYBOOK no | yes (built here: a probe test) | none |
| Beacons | `build`; modules with `transfer` (beacon_modules) | as modules | yes (probe test) | none |
| Solar, accumulators | `build`; `power` reads networks (production, satisfaction) | describe; usage no | build path generic; `power` tested | none |
| Nuclear (reactor, heat pipes, exchangers, turbines, centrifuges) | `build`; fuel cells with `transfer`/`refuel {fuel: uranium-fuel-cell, types: [reactor]}`; spent cells with `collect`/`transfer` (burnt_result); centrifuge recipes with `configure` | describe (fuel/burnt_result list reactor); usage no; PLAYBOOK no | generic paths tested; no reactor-specific test | none found in the tools |
| Fluid handling | `pipe_route {from, to, pumps, undergrounds, waypoints}`, `build` (pumps, tanks, offshore pumps), `scan fields=fluids`, `inspect` (fluid connections), barrels by recipe | describe yes; usage partly; PLAYBOOK 2 lines | yes (`tests/pipes.lua`, runtime_test) | moving fluid by hand (as in game: not possible either); flushing a tank |
| Quality | `build/transfer/rearm/refuel/collect/requests ... quality`; `configure {recipe, quality}`; quality modules by `transfer` | describe yes; spaceage.md 5 mentions; usage yes | yes (several tests); recipe quality built here | none found |
| Flamethrower / laser turrets | `build`; flamethrower fuel by `pipe_route`; laser by power; gun/artillery ammo by `rearm` | describe (generic); usage no; PLAYBOOK no | rearm tested | none |
| Grenades, capsules | `use_item {item, position}` | describe, usage | yes (`tests/capsules.lua`) | engine projectile names to confirm live |
| Vehicles (car, tank, spidertron, riding a train) | `build`; fuel and ammo with `transfer`/`refuel`; `vehicle {position, enter}`, `{exit}`, `{drive: {x,y}}` (timed), `{position, go_to}` (spidertron) | describe, usage (eng/coverage2) | yes (eng/coverage2, `tests/vehicles.lua`: seats, the guard, drive arrived/blocked, spidertron) | on eng/coverage2 only until its live check; before: every action refused a seated character |
| Space platforms | `platform_create`, `platform_schedule {stops, wait, paused}`, `platforms`, `requests {platform}`, `drop`, `place_ghosts/paste {platform}`, `deconstruct {platform, tiles}` | describe yes; spaceage.md yes; usage partly | yes (`tests/space.lua`, `tests/travel.lua`, `tests/blueprints.lua`) | none found |
| Asteroid collectors, thrusters | `place_ghosts {platform}`; output with `transfer` (asteroid_collector_output); thruster fuel/oxidizer by pipes from chemical plants | describe (inventory); spaceage.md mentions | `tests/space.lua` reads them (platforms detail) | collector filters not tested (configure filters may cover them) |
| Rockets, landing elsewhere | `launch {position, platform, orbit, ride, auto_requests}`, `land`, `drop`, cargo by `transfer` (rocket_silo_rocket) | describe yes; spaceage.md yes; PLAYBOOK 2 lines | `tests/travel.lua` (ride, land), `tests/space.lua` | none found |

## Built on this branch

- `wire {from, to, color: red|green, from_side, to_side, disconnect}` (circuits.lua): circuit wires between entities in
  reach; combinators' input and output sides.
- `circuit {position, enable, logistic, signals, on, arithmetic, decider}` (circuits.lua): what the circuit and
  logistic connection GUI holds, read back from the game; leaves a running queue alone.
- `train {position, station, limit}` for stops (the live check found `name` taken by the entity-name filter); `train {position, schedule, current, automatic}` for trains (trains.lua).
- Rails: `build {item: rail, entity}` places a rail planner's rails directly; construct builds rail ghosts; the
  direction names include 2.0's in-between ones.
- `configure {recipe, quality}`: documented, and a quality-only change is made instead of reported unchanged.
- `circuit {read: {...}}`: the read switches (inserter hand, belt contents, drill resources, train stop send/read).
- `requests {position, from_buffers}`: a requester chest's "request from buffer chests" switch.
- Tests: `tests/circuits.lua` (new), rails in `tests/bots.lua`, module and beacon insertion in
  `mod/tests/runtime_test.lua`.

All runtime-only (no control.lua change, no new top-level locals: runtime.lua stays at the guard's 3 free slots).

## Verified only by fakes: check live

The engine APIs used here could not be run on the Mac:
- Wires: `get_wire_connector(defines.wire_connector_id.circuit_red|combinator_input_red|...)`, `connect_to`,
  `can_wire_reach`.
- Conditions: `get_or_create_control_behavior()` then `circuit_enable_disable`/`circuit_condition`,
  `connect_to_logistic_network`/`logistic_condition`.
- Constant combinator: `sections_count`/`get_section`/`add_section`, `section.filters`.
- Arithmetic and decider `parameters` in 2.0's shapes.
- Trains: `backer_name`, `trains_limit`, `train.schedule` (or `get_schedule()`), `manual_mode`.
- Rails: `LuaItemPrototype.rails` and `create_entity{name=curved-rail-a, direction=1}`.

Checked against the 2.0 API docs (lua-api.factorio.com, 2026-10-11):
- `LuaTrain.schedule` is read/write (a simplified schedule), `manual_mode` too.
- `LuaItemPrototype.rails` exists for rail planners only, and the code reads it under pcall.
- `circuit_enable_disable`, `circuit_condition`, `connect_to_logistic_network` and `logistic_condition` (the generic
  on/off behaviour) and `circuit_read_hand_contents` (inserters) are read/write.
- The constant combinator has `enabled`, `sections_count`, `get_section` and `add_section`; its section filters use
  the same shape as the logistic requests, which already work live.
- The decider's parameters are `conditions`/`outputs`; the field names inside them are not confirmed.

A live check on world `live`:
1. Wire an inserter to a chest with `wire color=red`.
2. Set `circuit enable={signal: iron-plate, comparator: "<", value: 10}` and watch the inserter stop at 10.
3. Set a constant combinator's signals, read them back with `inspect` in the GUI, wire it to a lamp with
   `enable={signal: signal-A, comparator: ">", value: 0}`.
4. Lay 10 straight rails and 2 curves with `build`, place a stop named with `train`, a locomotive with fuel, and set
   a two-stop schedule with `automatic=true`.

## Not built, with a note each

- Vehicles: `player()`/`actor()` refuse every action while the character is in a vehicle. Entering, leaving and driving
  need a separate small action set (enter/exit; spidertron `autopilot_destination`; a timed drive for cars), plus a
  decision on which actions a seated character may take. A change to that guard is wide: worth its own branch and a
  live test.
- The selector combinator: the same `circuit` action can take it once its 2.0 parameters are confirmed live.
- Storage chest filters: a `configure` path (`storage_filter`).
- Prompts: the features above are absent from PLAYBOOK and team.md. A short tool index per feature in the PLAYBOOK
  (which action does what, no advice) is the cheapest way for agents to find them; I did not edit the prompts here
  (the study branch covers the agents' side). Text ready to paste is below.

### Tool index for the PLAYBOOK (tools only)

```
- Trains: rails with build {item: rail, entity: straight-rail|curved-rail-a|curved-rail-b|half-diagonal-rail};
  stops, locomotives, wagons with build; train {position: stop, station, limit}; train {position: locomotive, schedule,
  automatic}.
- Logistics: roboports with build, robots into them with transfer; requester and buffer chests' requests with
  requests {position, set}; your own requests with requests (needs logistic robotics).
- Circuits: wire {from, to, color: red|green}; circuit {position, enable | logistic | signals | arithmetic | decider}.
- Modules and beacons: transfer {position, item: <module>} puts it in the machine's or beacon's module slots.
- Nuclear: build the reactor and heat pipes; transfer or refuel with uranium-fuel-cell.
- Quality: configure {recipe, quality}; quality on build, transfer and requests.
```
