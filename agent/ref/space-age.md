- Aboard a platform (no body) every read works (scan, inspect, science, supply, ... with `platform=` or `surface=`), and
  so do tell, chat, say, operator, the board, research, platform calls and waits on `platform_arrived`/`platform_left`,
  and every remote-view call with `platform=` or `surface=` (place_ghosts, deconstruct, configure, circuit_set,
  requests with position, ...; the refusal lists them).
- Calls that act by remote view or on another surface (any call with `platform`, `configure` out of reach, ghosts,
  blueprints, deconstruction, `circuit_set`, `wire`, `requests`, schedules) leave your character's action, queue and
  standing orders running; so does a `configure` its checks refuse. `platforms` and `inspect` of a hub show each
  platform's `speed_kms`, `leg_left_km`, `eta_min` (at the current speed) and `next_stop`; `stops` lists each stop's wait
  conditions with time left and items to go where it waits. A platform flying under 5 km/s is an alert naming the
  thruster input it lacks and the pumps, plants, crushers and chunks behind it (`platforms {platform}`:
  `thrust_inputs`).
- `rotate {platform: NAME, position, direction?}` (or `surface: NAME`) turns a ghost or built belt or inserter there by remote view.
- `queue_submit {lane:"remote",steps:[...]}` runs platform waits, drops, schedules, platform configuration, platform `place_ghosts`/`deconstruct` (wait `{until:"platform_built",platform}` for the foundation) and body-independent reads alongside body work; queue controls accept the same lane, and status shows both.
- `./fh view platform=Sunward --out sunward.png` shows platform foundation and structure footprints; `agriculture {surface:"gleba"}` lists towers, ghosts and recorded tower-loss positions.
- `./fh call requests --args '{"platform":"NAME"}'` shows each hub section; `off: true` means it requests nothing
  (`"section":N,"active":true` switches it on), and each request shows the planet it imports from. A `set` without
  `section` edits the slot of the section that already requests the item (`sections_note` names a shared group or a second section).
  Personal requests: `clear` (or `remove`): `["pumpjack"]` deletes the request and keeps what you hold; a `max` under what you hold is refused without `force: true` (the game trashes the rest).
- `./fh wait --until "platform_arrived Sunward gleba"` wakes when the platform stops at that planet (any stop without
  a planet); it is also a `wait_until` condition, a queue guard and an order's `when`.
  `platform_left Sunward [nauvis]` waits for its next departure (from nauvis, or from any stop): seen stopped there
  during the wait, then gone; one begun in flight waits for the next stop and departure; the team alerts say when a platform stops at or leaves
  your planet. `./fh call freight_audit --args '{"item":"agricultural-science-pack"}'` shows one item across every
  planet and platform: stock, spoil times, silo room, unmet lab and requester demand.
- `./fh call platform --args '{"name":"Kestrel"}'` is the same read as `./fh platform Kestrel` (platforms of that one).
- `./fh platform NAME` also shows `freight` (per stop what was expected down and up, what left the hub, came aboard
  and spoiled, the rockets sent to it, the cargo pods sent down with what each landing pad received and the pods still
  in flight; per leg what spoiled on the way), `spoiling` (when its spoilable items spoil, against the arrival) and
  `engine` (the last 60 and 180 s: mean, lowest and highest speed, thruster fuel and oxidizer used and made, the
  thrusters' tanks at start and end, the pumps' share of time working). A `requests` edit echoes what is stored per item (`stored`) and keeps the import planet when
  `from` is not given.
- `./fh call platform_endurance --args '{"platform":"Wayfarer"}'` (optional `"route":["fulgora","aquilo"]`, default its schedule): each leg's km and minutes at its speed, and each ammunition, repair pack and thruster fluid aboard with its stock, made and used per minute, and the leg it runs out on; hub slots free, power, solar power at the stops. Stopped, the rates come from the last leg (or read `flight use unknown`); on a leg under 10 minutes old, from a window inside the leg; an item made aboard is capped by the ingredients aboard, two levels down and fluids included (`ingredient-limited`), and the cap grows at the rate its ingredients are made aboard now (`more_per_min`); stock counts every place aboard: hub, turrets, belts (an underground pair once), inserter hands and machines' outputs (`by_place`), with what moved between places since the leg began (`since this leg began: hub -300, belts +300`; moves are not use); a line gives the asteroid chunks collected a minute. `ammo_rates` (preflight, `fh platform`) counts the same places.
- `platform_supply {platform}`: the supply chain from collectors to guns, with the first stop named.
- `platform_plan {platform}`: foundation islands, belt loops, head-on belts and side-loads across built entities and ghosts.
- `./fh call networks --args '{"platform":"Starling"}'` gives a platform's electric network line (capacity, draw, solar
  power where it is and its panels' output, accumulators, machines on low power); accumulators are read at the call
  (`acc_mj`, `acc_pct`, `acc_series` every 15 s over 3 min) and `"fresh":true` adds `draw_now_kw`; `power` takes `platform` too, and
  `inspect` on a machine, solar panel or accumulator shows its maximum under `electricity`.
- On a platform the hub removes a marked foundation tile only beside empty space (a north, east, south or west
  neighbour), and never one that would join separate empty space; marked from the edge in, a row goes one tile at a
  time. deconstruct's reply says `tiles_go` (in order) and `waiting` with why for every marked tile there;
  `"dry_run":true` marks nothing; `platforms {platform}` shows `tile_removals`. Its `construction_blocked` counts up to 1000 entity and 3000 tile ghosts and says `at least` and how many were counted past that.
- `./fh call cargo --args '{"items":{"thruster":2,"cargo-bay":4}}'` (or a chest, silo or pad `position`) weighs a
  rocket cargo list: each item's weight, the total against a rocket's 1000 kg and 20 cargo slots, the fewest rockets,
  and one split into rockets that keeps each within both. `./fh call silo` (or a `position`) shows a silo's rocket
  parts X/50, what it lacks for the parts left (in the silo and at its feeders), the cargo's kg and slots, and the
  last launch. `silo {position, why: true}` follows the ingredient it is shortest of: its feeder chests (a requester's
  request and its network's stock), then that item's chain on the planet down to the root, with makers not working. `launch`, `silo`, `requests` and `configure` (a recipe; `auto_requests`, `send_to_orbit_automatically`
  on a silo) take `surface` (a planet) and `position` and act there by remote view where our force sees the chunk.
  With automatic requests on, `launch {position, platform}` launches the rocket with what the game loaded so far (they
  stay on); `load_silo` refuses, saying what is aboard.
  `launch` refuses a rocket with no cargo (a launch spends its parts) unless `allow_empty: true`, naming science in
  chests near the silo. A silo's transfer inventories: `assembling_machine_input` (alias `parts`, the rocket-part
  ingredients) and `rocket_silo_rocket` (alias `cargo`, what goes up with the rocket); `inspect` lists them with a call each.
- `cargo {incoming: true}` lists our platforms headed for your planet with their ETA and hub cargo; `cargo {items, silo, to_platform?}` adds when that list can go up (rockets, parts, the platform's arrival).
- `./fh call load_silo --args '{"items":{"agricultural-science-pack":1000},"launch":true,"platform":"Sunward","position":{"x":65.5,"y":14.5},"to_total":true}' --wait`
  loads the list into the rocket from your inventory and our chests in reach (any chest kind, logistic chests and a
  landing pad too, nearest first; `from` for given chests) and launches
  in the same tick once every count is aboard; before the rocket is ready it waits for it. `./fh call preflight` (silo
  `position` optional: all visible indexed silos nearest first; optional `items`, `platform`, `surface`) shows cargo,
  arrival/ETA, requests less hub and rocket, and (with `platform`) incoming rockets, `ammo_rates`, `hub_chunks`; no platform lists those stopped/headed here. `launch` takes `min_cargo` and `arrived: true`,
  read in the tick it launches; `fh queue submit --file plan.json --args '{"dry_run":true}'` queues nothing and shows
  the silo cargo before each launch step. `load_silo` with `"walk": true` and `from` (chests anywhere on the silo's
  surface) walks between them and the silo as many trips as the load takes, in one timed call (outcomes `loaded`,
  `launched`, `short`; `last.trips`, `last.stops`; `--wait` follows it); at the silo it waits for a rocket (with `launch`, a ready one)
  before it loads anything. `"up_to": true` loads what fits and what is held, and launches with what is aboard (short rows in `up_to_short`). A silo's `rocket_ready` is true only for a built
  rocket (`built_parts` 50/50); `next_parts` counts parts for the rocket after it. A `load_silo` waiting for its rocket
  waits while the silo makes parts (`ticks`: initial idle window, grown to 3 times the longest observed interval to
  a part increase, capped at `gives_up_tick`); `silo_wait` reports the observed parts/minute and idle window.
  A spoiling item goes in fresh first (the least
  spoiled stacks of you and the chests; `"fresh_first": false` for the old order).
- `platform_supply` adds `chunks` (each chunk type: collectors, then crushers whose recipe takes it and the hub) and
  `chunk_flags` (a GUI filter keeping a chunk from its crusher, a crusher stopped full over a full hub).
  `platform_endurance` adds `departure` (each ammunition over the route: used, aboard, made, short or spare, a rocket's
  lift), `solar` with low and no power counts, and flying, each line's last 60 s. `platforms {compact: true}`: a line a
  platform, blockers only when new to you. Platform loss alerts list each lost entity: rebuilt, a ghost there, or none.
- A `load_silo` with launch over one rocket's lift is split into rockets queued in turn (`split`). `platforms` gives
  `departure`: agents' queue steps and orders that send a platform on beside its schedule. `platform_endurance` lines
  add `phases` (moving, still in space, stopped) and `flight` (the route and its last leg at the moving rate).
  `platform_plan {platform, floor: true}` lists the foundation ghosts need (footprints, tunnels, holes, links) with
  `place_ghosts_entries`; `paste {preserve_existing_settings_and_wires: true}` adds only what is missing.
- `platform_rename {platform, name}` renames one, listing queues, orders, plans and board items still naming the old
  name. `platform_plan {platform, salvage: 60}` lists foundation tiles to take up from the edge in, as deconstruct areas.
  `load_silo {rockets: 3, launch: true, ...}` queues the load for 3 rockets. With automatic requests on, load_silo and
  preflight name the platforms' open requests a rocket may go to. A launch waiting while its platform leaves is told
  (`launch:` alerts); a rocket in flight holds the platform until its pod lands.
- `load_silo {walk: true}` without `from` walks to the silo with what you hold; a walking load takes the freshest
  stacks first (`last.freshness`). `wait_min: 15` keeps a load waiting through 15 minutes with no new part;
  `parts_short` (and `last.why`) names each rocket-part ingredient the silo lacks. The reply's `switches` gives the
  silo's automatic requests and send to orbit automatically; load_silo never sets them.
- `preflight {position,items,from}` reads source chest stock and shorts; `manifest` checks combined kg/slots including existing cargo. `from` is one chest position or up to 16; nothing moves.
- `launch {position, wait_ready: true}` waits for the rocket and launches when it is ready (a queue step too); a tell does not end that wait (one with `wake: true` or an urgent alert does), and a wait that ends before the rocket is ready ends `not_launched` with `launch_error`; a queued `load_silo` your own build or transfer interrupts is requeued and goes on.
- A drop's landing line gives the container's exact position and the other cargo pod containers within 8 tiles with
  what each holds; `scan` lists a cargo pod container with `holds`.
- `drop` sends one cargo pod (10 slots); `short` says what stays in the hub. `"full":true` sends every pod the list
  takes (each pod's items in `pods`), and `"dry_run":true` shows the pod split first and the landing pad's room
  (`pad_room`: free slots, what takes the rest, `spill`: what would land on the ground).
- A hub's trash (what is over a request's max) stays aboard in flight; at a stop the game sends it down in cargo pods, to
  the landing pad or, on a planet with none, as a cargo-pod container near (0,0) (`where_is` lists it). Pods still in
  the air from our platforms are `where_is`'s `in_flight` and in a platform's arrival alert.
- Gleba: `inspect` on an agricultural tower shows its `tower` state, seeds, output, which cells have soil for which
  seeds, and its plants with time to harvest; `transfer`, `feed` and `collect` work on its seeds and harvest.
- Spoilage: `inspect`, `supply` and `stock` give the first stack to spoil and when; pentapod eggs say when they hatch
  into enemies (`hatch_warning`, `hatch`); `output_spoil` is what a machine's next products start at; `freshness`
  gives each item's spread (least and most spoiled, the share by count, the counts under 25/50/75%, how many spoil
  within 10/30/60 min) in `inspect`, `supply` and every `platforms` row (the hub; `drop` dry_run for the items to drop,
  `launch` for the rocket's cargo), and the moved batch's in `transfer`, `collect` and `load_silo` (a
  science pack: how many a unit the running research takes, and its units left). Eggs of ours
  hatching within 5 minutes on your surface top `team.alerts` (`eggs hatching: ...`) and wake `fh sleep` (`woke: eggs`).
- Full `status` rechecks nearby recorded egg sites: enemies visible now, future/elapsed timer, and gun range coverage with ammo. An old timer alone is not a live hatch.
- `./fh call min_payload` reads every hub request that imports from a planet: platform, item, asks, holds, the custom
  minimum payload and a full rocket of it by weight; `{"platforms":"all","set":{"low-density-structure":50}}` sets that
  number for those items on those platforms (0 or false clears it), nothing else changed.
- `platform_endurance {"route":["gleba","aquilo","gleba"],"forecast":true,"pessimistic":{"speed":0.8,"dwell_s":300}}`:
  per leg, the asteroids its connection spawns by kind against the legs flown lately, the shots one of each takes of
  each ammunition aboard (`none hurt`: the ammunition cannot), and the use scaled from the legs flown, made meanwhile
  and left at each arrival.
- `load_silo` with a walk gives `loaded_items` (what you put in), `aboard_before` and `kept` (taken, not loaded, still
  with you: a teammate's load met the count); `cargo` is everything in the rocket.
- `launch {position, platform, wait_platform: true}` waits until the platform is in orbit of the silo's planet (and,
  with `wait_ready`, the rocket is ready), then launches; a plain tell does not end it.
- `./fh call platform_bom --args '{"platform":"Meridian","pack":true}'`: per item, what the ghosts still need less hub
  stock and cargo in flight, what is built and what the hub asks; `pack` splits the rest into rockets for `load_silo`.
- `load_silo {..., launch: true, auto_requests: "pause"}` loads a silo whose automatic requests are on. They go off for
  this manifest and come back on after its last launch, or when the load ends without one.
- `platform_production {platform}`: the platform's own production per item (totals, rates over 1m, 10m, 1h);
  `wait_until {until: produced, platform, item, at_least}`. `platform_plan {platform, ready: {positions, area, tiles}}`:
  one subset's missing items, foundation support and settings. A launch to another platform than the cargo was loaded
  for (load_silo `platform`) is refused (`cargo_for: "any"`); `launch {wait_ready, platform}` waits for the platform too.
- `platforms {eta_to: "vulcanus"}`: each platform's ETA to that planet through its schedule, or why none.
  `platform_plan {platform, floor: true, page: N}`: the floor entries 256 a page for place_ghosts. Silo alerts:
  `silo_short.<item>` (parts stalled 2 min) and `silo_ready_idle` (a rocket ready 3 min, not launched).
- `platform_defense {platform}`: each asteroid collector's front and each hull side against turret ranges: the turrets
  that reach it (ammo, fed by an inserter, robots or by hand), NO turret with the nearest, and edge gaps as runs.
- `platform_bom {platform, request: true}` keeps a hub request section (`platform_bom: NAME`) at what the ghosts still
  need, lowered as they are built and removed when none is left (`request: false` removes it; `import_from`, `area`;
  `min_payload: {item: N}`; a min_payload set on its slots is kept).
- `silo` rows' `platform_requests` flag each request: matched (the planet's network holds it), below_min_payload,
  split_networks (another network holds it), hub_full, filling. A launch reply leads with `spoiled_percent` by item
  and `went_up` (load_silo's `last` too).
- `platform_endurance {route}` while flying reads the route from the current leg; a route starting behind the ship is
  refused. A stop's wait line names a queue step (either lane) or order that will send the platform on sooner.
- A launch step started while the last rocket is still leaving waits for the next rocket (never reports that launch).
- `platform_defense` also traces each turret's ammunition back (`feed`): what can reach it (its inserters, the belts
  upstream and who loads them, the hub) and what stops it, with the ammo stranded on belts no turret's way reaches;
  `feed: true` lists every turret. platform_endurance and preflight count only ammunition that can reach a turret.
  A team alert names turrets whose feeds ran dry while ammunition aboard is stranded.
- platform_plan's floor and ready leave out the tiles a collector's rule keeps empty (its front): rear support only.
- `load_silo {launch: true, platform, wait_platform: true}` loads a ready rocket now and launches when the platform
  is stopped in orbit here (`staged` says so).
- `load_silo {walk: true, from, up_to_stock_at_start: true}` loads at most what you and the chests held when it began
  (`stock_at_start` says what), then ends (launches with launch) instead of touring on for a trickle.
- `load_silo {dry_run: true}`: each item's weight, slots and sources, the rocket's room, the split and the platform
  hub's free slots. A list over one rocket is refused unless `launch_split: true`.
- `platform_defense` lists the ammunition that can reach each turret, and per stranded belt group its belts and the
  call that recovers it (a belt pickup aboard, else `deconstruct` of those belts into the hub).
- `circuit_audit {platform}`: whole-belt readers (`entire_belt_hold`) on one network whose belts overlap (counted
  twice), and each asteroid collector whose filter the circuit sets: the filter it holds and the chunk signals there.
- `load_silo {position, from: [..], walk: true}` takes from the sources in order (chests, a landing pad, anywhere on
  the surface) and skips a trip's other sources once you hold what the rocket needs. `position` is the silo's (always
  needed; without it the reply lists the silos here); `from` is one chest `{x,y}` or a list of them.
- `platform_gate {platform?}`: a line a platform: at station, moving or stopped, and the current stop's departure
  conditions with what the hub holds against each.
- `silo` gives `robots_bringing` (what logistic robots carry or have reserved toward it) and `requesting_for`.
