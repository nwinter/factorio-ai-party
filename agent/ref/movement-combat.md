- `move_to {position | target | stand_off, reach?, via?, tolerance?, ticks?, avoid_enemies?, ...}`: walks your character
  there on the engine's path, over shallow water, wetland and Fulgora's oil ocean, deep too. Without `ticks` the time
  limit scales with the route's length (`limit`), set again from each path found (its length and the rest of the way).
  With nothing in the way the route is the straight line; `straight_line` in the reply names what the straight line
  crosses (ground the character cannot cross, cliffs, buildings, trees or rocks, with where), and `last.route` gives
  the tiles walked against the straight line, the point farthest off it and what the walk went round (that, enemies'
  reach in `avoided_enemies`, a path off belts).
  - `{"stand_off":{"target":{"x":425,"y":-410},"reach":36}}` walks to the spot within `reach` tiles of the target outside
    every worm's range, spawner's reach and area under attack the map shows plus the `avoid_enemies` margin, the one
    nearest you; with none clear of the margin, at their bare reach (said); with none at all, refused naming them.
    `stand_off` in the reply: where, how far from the target, the nearest reach edge.
  - `{"target":{"position":{"x":-75.5,"y":-86.5}},"reach":"transfer"}` (reach `build` or tiles; a vehicle by
    `{"unit_number":N}`) walks until you are within reach of that entity (`last.reach`; transfer reach to its box,
    build reach to its centre, as `build` measures it); in reach, at once. `{"position":{x,y},"reach":"build"}` does
    the same for a point. `via: [{x,y}, ...]` walks via points in order, each leg pathfound and checked for enemies as
    a single `move_to` (`last.legs`: each leg's outcome).
  - It never ends on a belt or a rail (it steps to the nearest free tile without one, `last.off_belt`). An end that
    would read `arrived` more than the tolerance + 3 tiles from the goal is `stopped_short`, `last.why` saying where,
    how far and after how many legs round enemies.
  - No route: it ends at once `unreachable`, with `last.why` (closed in: the area and what closes it in; boxed in
    among our drills or belts with the area open: it names them, `"squeeze":true` or `"pathfind":false`, and the nearest
    open spot reached straight over the belts; `"unbox":true` walks there in the same call, then on to the goal),
    `last.nearest_reachable` and `last.build_spot`, a spot you reach within build reach of the target
    (`build_spot_note`; in a gap, `build_spot_squeeze` and the `"squeeze":true` call). A position nothing leads to
    (inside a machine, a silo, a landing pad) is walked near: it ends `arrived_near` at that spot (`last.near_walk`;
    `"near":false` ends `unreachable`). `unreachable` and `no_safe_route` name a `staging` spot or via point from
    teammates' walks of the last 30 minutes near you and the goal. A walk of yours through `via` points that arrived
    is kept (per pair of 64-tile areas, start and goal); a walk with none between the same areas that ends
    `unreachable` or `no_safe_route` walks again once through them, and `last.route_memory` says so (or that the
    kept route failed too).
  - A target in a narrow gap no path leads into ends `arrived_near` before it (`last.pocket`); `"squeeze":true` walks
    in (ending short of the gap it says where, `squeezed`). Squeezed in, the walk gets out along the gaps first
    (`last.escaped`); closed in, `last.mine_to_get_out` names everything to mine to open ground (chests, accumulators,
    walls, trees and rocks before poles and machines); with no way to the target, `last.mine_for_a_way` names the
    fewest to mine for one (never a rocket silo, landing pad or platform hub; a goal inside a building: the way to its
    edge). `mine_out: true` marks those, mines them by hand (a timed construct; contents to your inventory) and walks
    again once (`last.mining_out`).
  - Gates: our gate opens as the character comes, and walks route through it (one set across the wall line joins no
    wall and leaves gaps beside it). A walk ending unreachable, blocked or near gives `last.across`: what stands across
    the straight line from where it ended to the goal (48 tiles), each wall with how many, the box it spans and its gates
    (ours, or another force's, which does not open for ours), or `no gate in it` (`last.across_walls`).
  - Mech armor (armor that provides flight): the character takes off when it walks into something and lands when it
    stops where it can stand; flying it crosses water, walls and buildings (only spidertrons and pentapods stop it), and
    walks plan with that (status `flight` says flying or on the ground). A change to armor without flight while it
    flies kills the character in 2.0.77: `equip` refuses it then.
- Enemies: it keeps out of the range of the worms the map shows (+ 4 tiles), 40 tiles of a spawner (+ 4) and 24 tiles
    of an area under attack now (hit in the last 30 s; + 4), and away from enemy units in sight near the way (a
    demolisher's head and every body segment), and groups seen now (and where they head), walking legs around them (`last.avoided_enemies`; a new attack re-plans,
    `last.replanned`; a path crossing only a margin may be walked, `last.passed_within_margin`). A group seen ahead
    mid-walk stops it and walks you away (`last.retreated`); a tour stop or via leg whose straight way passes enemy units
    or a group seen now is not started (`enemies_ahead`, naming them); a rearm tour (a transfer walk with
    `retry_when_clear`) waits there for it to clear, up to `retry_ticks` (default 60 s; `last.ahead_waited`). A walk begun inside a reach goes out the shortest way
    first (`left_reach_first`). A goal inside one is refused, naming each threat (`unsafe_goal: true` goes anyway;
    `unsafe_goal: "moving"` only when every threat moves: units, a group, an attack on ours; also on rearm). No way round:
    `no_safe_route`, with `last.smaller_margins` (the largest smaller margin with a complete engine route, its closest
    nest pass, or why the check failed), `last.via_round`, and for a walk back `last.walked_back` (the way you walked
    out, as via points). When only enemies that move (units, a group, an attack) are in the way, it stands and plans
    again every 5 s, up to 6 times (`last.waited_for_units`); a hit while it stands ends it.
  - `avoid_enemies`: `true` adds 8 tiles; a number (0..32) is a hard margin; `{distance: N}` keeps N tiles from every
    worm and spawner, their reach not counted (a worm whose range is more than N can hit you); `false` checks nothing,
    and `enters_unchecked` names the nests and units the straight legs cross.
  - `stay_in_turret_coverage: true` keeps the route inside our armed turrets' reach (via points it plans;
    `turret_coverage` says the way), through every covered area that joins, up to `max_uncovered` (48) tiles outside
    coverage at each end; farther out, or no covered way: refused, naming where coverage is missing.
  - Trains: a walk stops short of rails that a moving train will cross within 6 s and goes on once it has passed
    (status `train_wait`, `last.train_waits`); on a rail with a train coming over the next track it backs off.
    `rail_crossings`: each place the route crosses rails, with any train whose path crosses there now.
  - `dry_run: true` reads the route without walking: length, each worm and spawner's range and closest pass, `enters`
    (every reach the route enters, and every attack or enemy group within 24 tiles, with where it goes in and out),
    `under_range` (worms whose range is over `{distance: N}`), closed-in goals with what to mine, `closed_in_on_route`
    (pockets every 8 tiles on the straight legs and at via points), `rail_crossings` and, with no way round,
    `via_round`. feed, collect, transfer, rearm and refuel with positions take `dry_run` too.
  Example: `./fh call move_to --args '{"position":{"x":40,"y":5},"via":[{"x":10,"y":30},{"x":30,"y":30}]}' --wait`
  With `--wait` the completion's first line says `walk: arrived at (x,y)` (or `(arrived_near)`) or `walk: not arrived:
  ...`. Exit 0: it arrived; 1: it ended another way; 3: a tell, a mention or an urgent alert ended the wait (or the
  wait's time ran out) while the walk goes on, so `&& next` does not run; `./fh wait` waits for it again.
  `--wait-through-tells` keeps a tell or mention from ending the wait, so the next command of an `&&` chain runs once
  the walk has arrived (exit 3 still comes on urgent news or the wait's time). Example:
  `./fh call move_to --args '{"position":{"x":12,"y":-40}}' --wait-through-tells`
- `retreat_guard {to, health_below?, shield_below?, idle?}`: a standing `retreat` for `move_to`, `shoot`, `kite` and
  `vehicle {drive}` until `{"clear":true}`; a call's own `"retreat":{"to":{"x":260,"y":-60},"health_below":0.5,
  "shield_below":0.2}` wins. Hit under it, the action ends `retreated` and you walk back (guns on auto) or the vehicle
  is driven back (`last.retreated`: why, from, health). Hit with no action running (or mining, on a tour or waiting),
  your character walks away at once, to `to` or 24 tiles from the attacker, and a sleep wakes `damaged` saying where;
  `idle: false` keeps it standing.
  Example: `./fh call retreat_guard --args '{"to":{"x":260,"y":-60},"health_below":0.5}'`
- `kite {position?, radius?, min_distance?, max_distance?, range?, min_health?}`: fights enemy units within `radius`
  (default 32), keeping them 7 to 12 tiles off (`min_distance`, `max_distance`) and shooting structures within `range`
  (14), until below `min_health` (0.4); outcomes `clear`, `low_health`, `out_of_ammo`, `retreated`, `timed_out`.
  `--wait` waits until it ends and reports the outcome, kills and ammo.
  Example: `./fh call kite --args '{"position":{"x":120,"y":-40},"radius":24}' --wait`
- `recover {corpse?, stop_after?, dry_run?}`: walks to your own corpses on your surface, nearest first, and takes
  everything; a corpse keeps what you carried and does not expire. One inside a worm's range is left out (`left_out`).
  `stop_after: 1`: the nearest only (`not_walked` names the rest); `corpse: {x,y}`: that one. `dry_run: true` walks
  nowhere: each corpse's distance, items, whether recover walks to it, its `danger` (worms and spawners whose reach
  comes near it, attacks near it in the last 10 minutes), `killed_by` (what killed you, where), `killer_now` (alive in
  sight and where, out of sight, or gone) and `units_near`. Each corpse names the enemy groups our force sees within 160
  tiles of it (size, kinds, where, how far, moving which way, closing on it; dry run: `groups`); one within
  `group_radius` (default 48) keeps the corpse out unless `ignore_groups: true`. A death of ours that leaves a corpse
  holding items comes in every agent's team block once: who, where, how many items, what killed it, the groups near.
  Example: `./fh call recover --wait`
- `turret_feeds {area | positions, ammo?, count?, chest?, inserter?, dry_run?}`: for each ammo turret there that no
  inserter feeds, a side where an inserter drops into it with a free tile behind (each spot checked as a hand build
  checks it), and a requester chest there asking `count` (default 50) of its ammunition with the inserter, built from
  your inventory by `build` (its walk into reach). Each turret: the chest and inserter spots, `skipped` (fed already,
  no free side, no ammunition named for an empty one), `short` (the chests or inserters you hold ran out) or
  `not_built` (build refused an entry). A feed already there whose inserter has no power says `inserter unpowered`
  (`unpowered` counts them). `ghosts: true` places the chest (its request set on the ghost), the inserter and, when no
  pole of ours covers the inserter, a pole (`pole`, default small-electric-pole, beside it within wire reach of our
  nearest pole) as ghosts for construction robots, by remote view as `place_ghosts`, nothing from your inventory.
  `dry_run: true` plans only. Example:
  `./fh call turret_feeds --args '{"area":{"left_top":{"x":-20,"y":540},"right_bottom":{"x":20,"y":580}},"dry_run":true}'`
- `turrets {surface? | area?, hand_fed_low?, below?}`: every turret by front: its ammo (a flamer's oil with its
  buffer), health, and what feeds it (an inserter and its belt or chest, robots, a pipe, power, or nothing: hand-fed);
  hand-fed and low ones first. `hand_fed_low: true, below: 10`: turrets no inserter feeds under 10 rounds, nearest
  first.
  Example: `./fh call turrets --args '{"hand_fed_low":true,"below":10}'`
- `turret_tally {positions | position | area, name?, seconds?, surface? | platform?}`: up to 64 turrets (ammo, electric,
  fluid, artillery) watched for seconds (5..3600, default 120): each one's kills and damage dealt, as its tooltip shows
  them, at the start and the end and the change, a turret with none said `no change`; `first_change_s`, `last_change_s`
  and `seconds_changing` from a read a second; a turret destroyed or mined during the watch keeps its change to its last
  read (`gone_s`); `groups` sum them by name. The start returns `baseline`; `turret_tally {}` reads it so far or done
  (one watch an agent; a new one replaces it). What the counts take in (`note`): damage after the target's resistances,
  overkill included; a tesla's chain, a rocket's splash, a flamethrower's stream and its fire; trees and rocks hit, a
  tree destroyed is a kill. A kill goes to the turret whose hit destroyed the target; the others that damaged it get
  the damage only. Trees set alight that burn down do not count. A turret mined or rebuilt starts at 0.
  Example: `./fh call turret_tally --args '{"area":{"left_top":{"x":-40,"y":360},"right_bottom":{"x":40,"y":420}},"seconds":300}'`
- `rearm {surface | area | radius | positions | alert, below?, count?, ammo?}`: tops up turrets in one walking tour,
  nearest cluster first, `ticks` set by the tour's length; `below: 5` only those under 5 rounds (in reach and at
  positions too). Without `ammo` each turret gets the type it holds (`ammo_each`); one whose type you hold none of, or
  holding another type than asked, is left out and named. Finding nothing, it names the nearest turret outside.
  On every form (positions walked to as well), a turret whose ammo slots hold another type with no room, or a ghost,
  is skipped and the rest are served: `turrets_skipped` ("2 of 3 turrets skipped: ...", each with what it holds) is on
  the reply's warning line and in `last` after a tour.
  A line per turret: `turret_lines` in reach, `last.turret_lines` after a tour (what each got and holds now; those
  the tour did not reach, named).
  Before it walks (and in `dry_run`), `magazines` gives per ammo type what the stops need to reach `count` against
  what you carry and craft, how many stops that completes in the tour's order, and the turrets left short; a tour
  it cannot finish is refused unless `partial: true` (`partial` then says how many stops get their full count).
  `turrets` (the reply before the walk and the dry run): each stop's turret with the ammunition it holds by name and
  what it gets, and each one left out with the ammunition it wants. The dry run checks the route in straight lines
  for pockets; it does not ask the game's path. A tour's walk that stalls and ends `blocked` names in
  `first_unreached` where it stopped and what stands within 2.5 tiles that the character collides with (and enemy
  units within 6 tiles). A walk (move_to or a tour) that stalls asks for its route again with 0.15 tiles more room
  either side each time, to 0.45 (`stall_pad`), so it keeps out of the narrow gaps of a dense block of our buildings. When a walking feed, rearm or refuel tour ends, `enemy_groups_toward` lists the enemy groups in chunks our force sees
  then that head for the places it served (size, where, tiles from the nearest such place, heading, target).
  `alert: "KEY"`: an out-of-ammo alert lists each turret's position and ends with `rearm {alert: "KEY"}`, a tour over
  exactly those. Refused for enemies, it says per place whether a worm or spawner (it stays) or passing enemies hold
  it; `retry_when_clear: true` waits until no enemy unit is within 48 tiles (30 s when none is there now) and rearms
  again (6 tries); a tour that leaves out turrets for passing enemies goes back to them once it ends, waiting the same
  way (`left_out_retry`). `from: {position, count?}` takes `count` (default 200) of the ammo from that chest first,
  walking to it, then runs the tour with the other arguments once the take ends with ammo taken (`then_rearm`; in
  reach, the tour at once): a resupply in one call. `dry_run:
  true`: the stops, each turret's rounds and what it gets, those wanting ammo you do not carry, and the route.
  Example: `./fh call rearm --args '{"position":{"x":-300,"y":-320},"radius":35,"count":20,"below":10,"partial":true,"retry_when_clear":true,"from":{"position":{"x":-280.5,"y":-300.5},"count":200}}'`
- `artillery {surface?, position?, radius?}`: our artillery with shells, automatic targeting and the spawners and
  worms in range, nearest first; `units_near`: enemy units within 64 tiles of each piece, their range, and how many of
  our turrets reach them. It and the targeting remote's reply give `shells_used` (shots fired, from the production
  statistics) and `fed_by` inserters (a piece one refills keeps its count after a shot). `configure {position,
  auto_targeting: false}` switches targeting off; `use_item {"item":"artillery-targeting-remote","position":{...}}`
  puts a flare there for the pieces in range.
  A flare reaches farther than automatic targeting: `manual_range` is the range times the prototype's
  manual_range_modifier (2.5: 560 tiles with no range research, 728 at +30%), the 32-tile minimum holding too. The
  flare's reply says for each loaded piece in reach whether only its manual range holds it, and when none reaches,
  `nearest_out_of_range`: the loaded piece nearest to reaching it and why (past its manual range, or inside its minimum).
- `shoot {position | auto, gun?, ammo?, ticks?, fire_anyway?}`: fires at the position (`auto: true`: the nearest enemy); the
  position is within 32 tiles of you or the selected gun's range, the larger, in a chunk our force sees now; replies
  `gun {slot, name, range, ammo_slot, ammo, count}` and `no_compatible_ammo` or `out_of_range` when it will not fire,
  `last_combat.why_none` when nothing fired. The selected gun's empty ammo slot is loaded from your main inventory first
  (`loaded`), and again when it runs dry mid-fight (`last_combat.equipped`; `dry` when nothing carried fits it). Area ammunition on foot (explosive rockets: a 6.5-tile blast) at a
  position whose blast reaches our own entities is refused, naming them; `auto` holds fire at such a target
  (`last_combat.held_blast`); `fire_anyway: true` fires anyway. With area ammunition, enemy units within 6 tiles of
  you or an aim point inside the blast round you switch the gun to a slot holding ammunition without an area
  (`last_combat.switched_gun`), or with none hold fire (`held_melee`). In a tank, car or spidertron you drive it fires the vehicle's gun (`gun:
  "tank-cannon"`, or `ammo: "explosive-cannon-shell"`), loading the slot from your inventory, while `vehicle {drive}`
  goes on.
  Example: `./fh call shoot --args '{"position":{"x":294,"y":-135},"gun":"tank-cannon"}'`
- `use_item {item, position?}`: throws a grenade or capsule; `ready_tick` says when the next can go (cooling down, the
  refusal names it).
  Example: `./fh call use_item --args '{"item":"grenade","position":{"x":40.5,"y":-12.5}}'`
- `equip {slot, item, index?}`: without `index`, tries compatible empty gun or ammo slots before slot 1; an `index`
  selects only that slot. A gun already in a slot is selected; an occupied slot swaps when your inventory has room.
  Gun slot N fires only from ammo slot N (`inventory` shows them); `slot: "ammo"` with `index` moves ammo between ammo
  slots.
  Example: `./fh call equip --args '{"slot":"ammo","item":"piercing-rounds-magazine","index":1}'`
- `vehicle {position, enter: true} | {exit: true} | {drive: {x,y}} | {position, go_to: {x,y}}`: gets into a car, tank,
  spidertron, locomotive or wagon, gets out, drives a car or tank (timed), or walks a spidertron; a position with none
  of them is refused, naming `enter: true`. `drive` follows the engine's path for the vehicle around cliffs and water,
  backs off once when stuck, pushes through units
  (`last.rammed`), backs there rear first with `"reverse":true`, and takes `avoid_enemies` as `move_to` does; it keeps
  its turning room clear of our buildings and brakes before any of ours (`last.spared`); with no room near the target
  it stops on open ground short of it (`last.stopped_short`). `"dry_run":true` previews the path and names ours it
  would touch (`last.preview`); `"combat":true` keeps the guns on auto for the drive (`last.shots`, `last.kills`).
  `remote: true, vehicle: N` drives one of our cars or tanks in radar coverage by remote view while your character
  stays put (its guns do not fire that way), or with `go_to` sends a spidertron; `auto_target_without_gunner` and
  `auto_target_with_gunner` set a spidertron's switches.
  Example: `./fh call vehicle --args '{"drive":{"x":-40,"y":-200},"remote":true,"vehicle":311799}' --wait`
- `equipment {vehicle?, operation, item?}`: works a tank's (6x8) or spidertron's (10x6) equipment grid in reach or
  seated (your armor's without `vehicle`); `"operation":"list"` shows it, also by remote view; `inspect` on it too.
  The list counts pieces by name and quality (`name@rare*1`), with rows, shield, battery, free cells and `armor`.
  Example: `./fh call equipment --args '{"vehicle":311799,"operation":"insert","item":"energy-shield-equipment"}'`
- The walking tours (rearm, refuel, feed, collect, transfer `walk`) and `mine` check each place for enemies as
  `move_to` does, at the call too: `left_out` names the stops left out, and a tour whose every stop lies in such a
  reach is refused (`last.danger`, `last.dangers` for those found on the way). An attack that starts at the stop while
  a tour or `recover` walks there holds the walk where it is until it has had no hit for 30 s (`held_short` in status
  and `last`). A stop no path leads to (a turret closed in by solar panels) names the fewest of ours to mine for a way
  (`last.first_unreached`, `last.mine_for_a_way`), as `move_to` does. A walk that falls back to a spot within its
  target's reach (recover, transfer, feed tours) keeps the enemy margin; a tour (transfer, feed, collect, recover)
  that ends on a ground rail walks off the rails first (`last.off_rails`). Attack lines say when the area clears (30 s
  after its last hit).
