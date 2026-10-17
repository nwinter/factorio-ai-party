- `move_to` never ends on a belt or a rail (it steps to the nearest free tile without one, `last.off_belt`). With no route for
  your character it ends at once as `unreachable`, with `last.why` (closed in: the area and what closes it in; boxed in
  among our drills or belts with the area open: it names them and `"squeeze":true` or `"pathfind":false`) and
  `last.nearest_reachable`, plus `last.build_spot`: a spot you can reach within build reach of the target
  (`build_spot_note`; in a gap, `build_spot_squeeze` and the `"squeeze":true` call). A position nothing leads to (inside a
  machine, a silo, a landing pad) is walked near instead: it ends `arrived_near` at that build spot (`last.near_walk`;
  `"near":false` ends `unreachable` there). `kite --wait` waits until the kite ends and reports its outcome, kills and
  ammo the same way.
- `move_to --args '{"target":{"position":{"x":-75.5,"y":-86.5}},"reach":"transfer"}'` (reach `build` or tiles; a vehicle by
  `{"unit_number":N}`) walks until you are within reach of that entity and arrives there (`last.reach`; build reach is
  to its centre, as `build` measures it); in reach, at once. `{"position":{x,y},"reach":"build"}` does the same for a point.
- `move_to --args '{"position":{"x":40,"y":5},"via":[{"x":10,"y":30},{"x":30,"y":30}]}'` walks the via points in order
  in one call, each leg pathfound and checked for enemies like a single `move_to`; `last.legs` gives each leg's outcome.
  Without `ticks` its time limit scales with the route's length (the reply's `limit` says it).
- `move_to` keeps out of the range of the worms the map shows (+ 4 tiles), 40 tiles of a spawner (+ 4) and 24 tiles of
  an area under attack now (an attack hit in the last 30 s; + 4), walking legs around them (`last.avoided_enemies`;
  a new attack on the way re-plans, `last.replanned`); a goal inside one is refused (`unsafe_goal: true` goes anyway);
  no way round: `no_safe_route`. The walking tours (rearm, refuel, feed, collect, transfer `walk`) and `mine` check
  each place the same way, at the call too: the reply's `left_out` names the stops left out, and a tour whose every
  stop lies in such a reach is refused (`last.danger`, `last.dangers` for those found on the way). Hit with no action running (or mining, on a tour or
  waiting), your character walks away at once, to turret cover or 24 tiles from the attacker, and a sleep wakes
  `damaged` saying where; `retreat_guard {idle: false}` keeps it standing.
- `move_to {avoid_enemies: {distance: N}}` replaces the default margins (a worm's range + 4, a spawner's 40 tiles + 4)
  with N tiles from every worm and spawner, their reach not counted: a worm whose range is more than N can hit you on
  the way. Leaving `avoid_enemies` out keeps the defaults. A walk back refused `no_safe_route` gets `last.walked_back`: the way you walked out, as via points.
- Numeric `move_to {avoid_enemies:N}` keeps a hard margin; `no_safe_route` adds `last.smaller_margins` with the largest smaller integer margin whose engine route was verified, its closest nest pass, or the check's failure/budget reason. The check leaves the character stationary.
- `move_to {position, dry_run: true}` (and feed/collect/transfer/rearm/refuel with positions) reads the route without walking: length, each worm and spawner's range and closest pass, closed-in goals with what to mine; `under_range` names worms whose range is over `avoid_enemies {distance: N}`.
- A target in a narrow gap no path leads into ends the walk `arrived_near` before it (`last.pocket`; `"squeeze":true`
  walks in). Squeezed in, the walk gets out along the gaps first (`last.escaped`); closed in, `last.mine_to_get_out`
  names everything to mine to open ground (chests, accumulators, walls, trees and rocks before poles and machines); not
  closed in but with no way to the target, `last.mine_for_a_way` names the fewest to mine for one (never a rocket
  silo, landing pad or platform hub; for a goal inside a building, the way to its edge). `move_to {mine_out: true}` then marks those blockers, mines them by hand (a timed construct;
  contents to your inventory) and walks again once (`last.mining_out`). `move_to` walks over
  shallow water, wetland and Fulgora's oil ocean, deep too. A
  `build` batch that fails part way, and a real `place_ghosts`, say on the `warning:` line when what they place closes
  you in. A `build` batch with `"all": true` builds every entry it can and lists the rest in `failed` with why.
  `circuit_set` says `stays disabled` there when one of the entity's conditions is not met after the call (a circuit
  condition counts only with a red or green wire on the entity: without one the game ignores it, and the line says
  `condition ignored`);
  `requests` `set` takes a map `{item: min}` too; an entry without `max` keeps the slot's max (`"max": "inf"` sets none).
- A walk stops short of rails that a moving train will cross within 6 s and goes on once it has passed (status
  `train_wait`, then `last.train_waits`).
- `"retreat":{"to":{"x":260,"y":-60},"health_below":0.5,"shield_below":0.2}` on `move_to`, `shoot`, `kite` or `vehicle {drive}`:
  hit under it, the action ends `retreated` and you walk back (guns on auto) or the vehicle is driven back at once
  (`last.retreated`: why, from, health). `./fh call retreat_guard --args '{"to":{"x":260,"y":-60},"health_below":0.5}'`
  sets it for every one of them until `{"clear":true}`.
- `./fh call recover --wait` walks to your own corpses on your surface, nearest first, and takes everything from each; a
  corpse keeps what you carried when you died and does not expire. One inside a worm's range is left out (`left_out`).
  `recover {"dry_run": true}` walks nowhere: each corpse's distance, items, whether recover walks to it, and its
  `danger` (worms and spawners whose reach comes near it, attacks near it in the last 10 minutes), `killed_by` (what
  killed you, where), `killer_now` (alive in sight and where, out of sight, or no longer alive) and `units_near`.
- move_to's enemy check counts enemy units in sight near the way and groups seen now (where they head too); a group seen
  ahead mid-walk stops the walk and walks you away (`last.retreated`). With `avoid_enemies: false` the reply's
  `enters_unchecked` names the nests and units the straight legs cross.
- `move_to {position, stay_in_turret_coverage: true}` keeps the route inside our armed turrets' reach (via points it
  plans; `turret_coverage` says the way); a start or goal outside it, or no covered way, is refused with where it ends.
  `recover {"stop_after": 1}` walks to the nearest corpse only (`not_walked` names the rest); `{"corpse": {"x":..,"y":..}}`
  to that one. `use_item` gives `ready_tick` (when the next capsule can go); cooling down, the refusal names it.
- Grenades and capsules: use_item {item, position}.
- Gun slot N fires only from ammo slot N: `inventory` shows guns and ammo per slot; `equip {slot: "ammo", item, index}` moves ammo between ammo slots.
- `equip {slot,item,index?}` tries compatible empty gun/ammo slots before slot 1 when index is omitted; an explicit index selects only that slot. A gun already in a slot is selected; an occupied slot swaps when your inventory has room.
  `shoot` replies with `gun {slot, name, range, ammo_slot, ammo, count}` and `no_compatible_ammo` or `out_of_range` when it will not fire; `last_combat.why_none` when nothing fired.
- `./fh call turrets` (optional `"surface"` or `"area"`) lists every turret by front: its ammo (a flamer's oil with
  its buffer), health, and what feeds it (an inserter and its belt or chest, robots, a pipe, power, or nothing:
  hand-fed); the hand-fed and low ones first.
- `./fh call rearm --args '{"surface":true,"below":5}'` (or `"area"`, `"radius"` round you or round `"position"`) tops
  up every turret under 5 rounds in one walking tour, nearest cluster first, its `ticks` set by the tour's length;
  `below` works in reach and at positions too. refuel, feed and rearm that find nothing name the nearest one outside.
  Without `ammo`, each turret gets the type it holds (`ammo_each`); one whose type you hold none of, or that holds
  another type than the one asked, is left out and named. `turrets {hand_fed_low: true, below: 10}` lists the turrets
  no inserter feeds under 10 rounds, nearest first.
- Artillery: `./fh call artillery` lists our artillery with shells, automatic targeting and the spawners and worms in range, nearest first; `configure {position, auto_targeting: false}` switches automatic targeting; `use_item {"item":"artillery-targeting-remote","position":{...}}` puts a flare there for the pieces in range.
- `artillery` rows add `units_near`: enemy units within 64 tiles of each piece, their range, and how many of our turrets reach them.
- `artillery` and the remote's reply give `shells_used` (shots fired, from the production statistics) and each piece's
  `fed_by` inserters: a piece an inserter refills keeps its count after a shot.
- Vehicles: vehicle {position, enter: true} gets into a car, tank, spidertron, locomotive or wagon; vehicle {exit:
  true}; vehicle {drive: {x,y}} drives a car or tank (timed); vehicle {position, go_to: {x,y}} walks a spidertron.
- In a tank, car or spidertron you drive, `shoot` fires its gun: `--args '{"position":{"x":294,"y":-135},"gun":"tank-cannon"}'`
  (or `"ammo":"explosive-cannon-shell"`, `"auto":true`), loading the slot from your inventory; `vehicle {drive}` goes on meanwhile.
  `vehicle {"drive":{...},"combat":true}` keeps the guns on auto for the whole drive (`last.shots`, `last.kills`).
- `vehicle {drive}` follows the engine's path for the vehicle around cliffs and water, backs off once when stuck, pushes
  through units (`last.rammed`), backs there rear first with `"reverse":true`, and takes `avoid_enemies` as `move_to` does.
  It keeps its turning room clear of our buildings and brakes before any of ours (`last.spared`). With no room near the
  target it stops on open ground short of it (`last.stopped_short`). `"dry_run":true` previews the path and names ours
  it would touch (`last.preview`).
- `vehicle {"drive":{"x":-40,"y":-200},"remote":true,"vehicle":311799}` drives one of our cars or tanks in radar coverage by
  remote view while your character stays put; its guns do not fire that way.
- `equipment {"vehicle":311799,"operation":"insert","item":"energy-shield-equipment"}` works a tank's (6x8) or spidertron's
  (10x6) equipment grid in reach or seated; `"operation":"list"` shows it, also by remote view; `inspect` on it too.

- A `move_to` dry run lists `closed_in_on_route` (pockets every 8 tiles on the straight legs and at via points) and, with
  no way round, `via_round`; a walk ending `no_safe_route` gives `last.via_round`. `vehicle {remote: true, vehicle,
  go_to}` sends a spidertron by remote view; `auto_target_without_gunner` and `auto_target_with_gunner` set its switches.
- A move_to that would end `arrived` more than its tolerance + 3 tiles from the goal ends `stopped_short` instead,
  `last.why` saying where it stopped, how far and after how many legs round enemies.
- A move_to dry run's `enters` names every worm and spawner whose reach the planned route enters, and every attack or
  enemy group within 24 tiles of it, with where it goes in and out. A walk begun inside a reach goes out the shortest
  way first (`left_reach_first`). Attack lines say when the area clears (30 s after its last hit).
- Out-of-fuel and out-of-ammo alerts list each entity's position and end with `refuel {alert: "KEY"}` /
  `rearm {alert: "KEY"}`: a tour over exactly those (an alert's centre can lie far from them: it joins touching areas).
- A rearm refused for enemies says per place whether a worm or spawner (it stays) or passing enemies hold it;
  `rearm {..., retry_when_clear: true}` waits until no enemy unit is within 48 tiles and rearms again (6 tries).
- stay_in_turret_coverage walks up to `max_uncovered` (48) tiles outside coverage at each end (said in
  `turret_coverage`) and through every covered area that joins; a refusal names where coverage is missing.
- Rail crossings: move_to and its dry run give `rail_crossings` (each place the route crosses rails, with any train
  whose path crosses there now). On a rail with a train coming over the next track, a walk backs off the rails.
- A walk refused `unreachable` or `no_safe_route` names a `staging` spot or via point from teammates' walks of the last
  30 minutes near you and the goal.
- `rearm {radius|area|surface, dry_run: true}`: the stops it would walk, each turret's rounds and what it gets, those
  wanting ammo you do not carry, and the route.
- A walk that falls back to a spot within its target's reach (recover, transfer, feed tours) keeps the enemy margin;
  `construct` stands no nearer a worm or spawner than its reach + the margin (refused ghosts name it).
- A squeeze walk that ends short of its gap trail says where it ended (`squeezed`).
- `recover {corpse, dry_run: true}` reads that corpse only.
- A tour (transfer, feed, collect, recover walks) that ends on a ground rail walks off the rails first (`last.off_rails`).
