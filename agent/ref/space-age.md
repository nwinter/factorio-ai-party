- `platforms {platform?, compact?, eta_to?}`: our platforms, a row each: where it is, `speed_kms`, `leg_left_km`,
  `eta_min` (at the current speed), `next_stop`, hub health, and `stops` (each stop's wait conditions with the time
  left and items to go where it waits; a stop's wait line names a queue step, either lane, or standing order that
  sends the platform on sooner). `departure`: the agents' queue steps and standing orders that send a platform on
  beside its schedule. `freshness` gives spoilable science's effective research units now and, when the leg's ETA is
  known, at arrival, as `science` and `preflight` count them. `inspect` of a hub shows the same speed and ETA fields.
  With `platform`: one platform with its full hub inventory, `thrust_inputs` (a line per thruster input under half
  full: the pumps, plants, crushers and chunks behind it and why they stop; a platform flying under 5 km/s is an alert
  naming them), `tile_removals` and `construction_blocked` (why the hub cannot build now; it counts up to 1000 entity
  and 3000 tile ghosts and says `at least` and how many were counted past that). `compact: true`: a line a platform,
  blockers only when new to you. `eta_to: "vulcanus"`: each platform's ETA to that planet through its schedule, or why
  there is none.
- `./fh platform NAME`: one platform, the same read as `./fh call platform --args '{"name":"Kestrel"}'` (`platforms`
  of that one): hub free slots, cargo, speed, next stop, ETA; `hub_chunks` (hub slots asteroid chunks take);
  `ammo_rates` (per ammo type, made and used over the last leg, with the reserve at arrival; it counts the places
  `platform_endurance` counts); `incoming` rockets; `freight` (per stop: what was expected down and up, what left the
  hub, what came aboard, with what construction robots placed from a rocket's cargo at once as "built at once N" and
  the platform's count before and after, and what spoiled; the rockets sent to it; the cargo pods sent down with what
  each landing pad received and the pods still in flight; per leg what spoiled on the way); `spoiling` (when its
  spoilable items spoil, against the arrival); `engine` (the last 60 and 180 s: mean, lowest and highest speed,
  thruster fuel and oxidizer used and made, the thrusters' tanks at start and end, the pumps' share of time working).
- `platform_arrived {platform, location?}` and `platform_left {platform, location?}`: wait conditions, in `./fh wait
  --until`, `./fh sleep --until`, `wait_until`, queue steps and guards, and a standing order's `when`.
  `platform_arrived` holds while the platform is stopped at `location` (a planet; without one, at any stop).
  `platform_left` waits for its next departure from `location` (without one, from any stop): seen stopped there during
  the wait, then gone; one begun in flight waits for the next stop and its departure. With no `timeout` (queued or
  direct) either wait goes on past its default 60 s while the ETA is known: to the ETA plus a quarter and 10 s, at
  most 54000 ticks (`extended` says so). The team alerts say when a platform stops at or leaves your planet.
  Example: `./fh wait --until "platform_arrived Sunward gleba" --max 600`
- `platform_create {name?, planet?}`: creates a platform over `planet` (default yours); as in the platform GUI it
  waits for its starter pack, which a silo holding it in its rocket cargo launches on its own.
- `platform_schedule {platform, stops, current?, paused?}`: each stop `{station, wait: [...]}`; a wait is `{type,
  ticks?, condition?, compare: "and"|"or"}`. Types: `time` and `inactivity` (`ticks`), `all_requests_satisfied`,
  `any_request_not_satisfied`, `any_request_zero`, and with a `condition`: `item_count` (an item), `fluid_count` (a
  fluid), `circuit` (any signal on the hub's red and green wires: wire a tank or a combinator to the hub;
  `circuit_note` when the hub has no wire). A condition is `"thruster-fuel >= 10000"` or `{signal, comparator, value |
  signal2}`. `stops: []` clears the schedule; `current` is the 1-based stop to head for; `paused` pauses thrust and
  the schedule. `wait_until` with `platform` takes `fluid_count` (`fluid, at_least | below`: the storage tanks) and
  `circuit_signal` (`signal, at_least | below`: the hub's wires), the remote lane too.
  Example: `./fh call platform_schedule --args '{"platform":"Sunward","stops":[{"station":"nauvis","wait":[{"type":"time","ticks":216000},{"type":"circuit","condition":"thruster-fuel >= 10000","compare":"and"}]},{"station":"gleba","wait":[{"type":"all_requests_satisfied"}]}]}'`
- `platform_rename {platform, name}`: renames one, listing the queues, orders, plans and board items still naming the
  old name (`still_named`; none changed).
  Example: `./fh call platform_rename --args '{"platform":"Sunward","name":"Kestrel"}'`
- `platform_endurance {platform, route?, forecast?, pessimistic?}`: per leg its km and minutes at its speed; per
  ammunition, repair pack and thruster fluid aboard its stock, made and used per minute and the leg it runs out on;
  hub slots free, power, solar power at the stops, and the asteroid chunks collected a minute. `route`: the locations
  in order (default its schedule round to the current stop again), read from the current leg while flying; one
  starting behind the ship is refused. Rates come from the last leg when stopped (else `flight use unknown`), from a
  window inside the leg on one under 10 minutes old. Stock counts every place aboard: hub, turrets, belts (an
  underground pair once), inserter hands and machines' outputs (`by_place`), with what moved between places since the
  leg began (`since this leg began: hub -300, belts +300`; moves are not use); only ammunition that can reach a turret
  counts. An item made aboard is capped by the ingredients aboard, two levels down, fluids included
  (`ingredient-limited`), and the cap grows at the rate its ingredients are made aboard now (`more_per_min`). Rows add
  `phases` (moving, still in space, stopped) and `flight` (the route and its last leg at the moving rate); `departure`
  (each ammunition over the route: used, aboard, made, short or spare, a rocket's lift of it); `solar` with low and no
  power counts; flying, each line's last 60 s. `forecast: true` adds per leg the asteroids its connection spawns by
  kind against the legs flown lately, the shots one of each takes of each ammunition aboard (`none hurt`: the
  ammunition cannot), and the use scaled from the legs flown, made meanwhile and left at each arrival; `pessimistic:
  {speed, dwell_s}` slows the legs and adds time at each stop.
  Example: `./fh call platform_endurance --args '{"platform":"Wayfarer","route":["gleba","aquilo","gleba"],"forecast":true,"pessimistic":{"speed":0.8,"dwell_s":300}}'`
- `platform_supply {platform}`: the supply chain from collectors to guns (collectors, crushers, thruster fuel and
  oxidizer makers, thrusters, guns), with the first stop named (`first_stop`); `chunks`: each chunk type with its
  collectors, then the crushers whose recipe takes it and the hub; `chunk_flags`: a GUI filter keeping a chunk from
  its crusher, a crusher stopped full over a full hub.
- `platform_plan {platform, floor?, page?, ready?, salvage?}`: the platform as planned, built entities and ghosts
  together: foundation islands, belt loops, head-on belts and side-loads. `floor: true`: the foundation the entity
  ghosts need (footprints, tunnels, holes, links) as `place_ghosts_entries`, 256 a page (`page: N`); a tunnel runs to
  the next underground of its name facing the same way (one crossing it is passed over); `tile_ghosts_held` names tile
  ghosts counted as floor that the hub's foundation rules never build. `ready: {positions, area, tiles}`: one subset's
  missing items, foundation support and settings. Floor and ready leave out the tiles a collector's rule keeps empty
  (its front): rear support only. `salvage: 60`: foundation tiles to take up from the edge in, as deconstruct areas
  (never one under an underground belt or pipe span, or at its ends).
  Example: `./fh call platform_plan --args '{"platform":"Meridian","floor":true,"page":1}'`
- `platform_bom {platform | surface, pack?, request?, import_from?, area?, min_payload?, tail?}`: per item, what the ghosts
  still need less hub stock, cargo in flight and what its construction robots carry, what is built and what the hub
  asks. Module and other item requests count, on ghosts and on built machines (`requests`). `pack: true` splits the
  rest into rockets for `load_silo`. `request: true` keeps a hub request section (`platform_bom: NAME`) at what the
  ghosts and machines still need less what the construction robots carry (items taken from the hub for a ghost not
  built yet are asked no second time), lowered as they are built and removed when none is left (`request: false`
  removes it; `import_from`,
  `area`; `min_payload: {item: N}`; a min_payload set on its slots by `min_payload` or `requests` is taken as its own
  and kept (the line says `adopted`); `tail: true`: an item's minimum payload no more than what is still to come, its
  request less what the hub holds). `surface: "gleba"` with no platform:
  every platform's active hub requests importing from that planet, a line a platform with what it lacks (asks, holds)
  and where it is. Example: `./fh call platform_bom --args '{"platform":"Meridian","pack":true}'`
- `platform_production {platform, item?}`: the platform's own production per item (totals, rates over 1m, 10m, 1h).
  `wait_until {until: "produced", platform, item, at_least}` waits for it.
  Example: `./fh call platform_production --args '{"platform":"Sunward","item":"space-science-pack"}'`
- `platform_defense {platform, feed?}`: each asteroid collector's front and each hull side against turret ranges: the
  turrets that reach it (ammo, fed by an inserter, robots or by hand), NO turret with the nearest, and edge gaps as
  runs. It traces each turret's ammunition back: what can reach it (its inserters, the belts upstream and who loads
  them, the hub) and what stops it; the ammunition that can reach each turret; the ammo stranded on belts no turret's
  way reaches, per group with its belts and the call that recovers it (a belt `pickup` aboard, else `deconstruct` of
  those belts into the hub). `feed: true` lists every turret. A team alert names turrets whose feeds ran dry while
  ammunition aboard is stranded. `circuit_audit {platform}` reads a platform's misleading circuit readings (`./fh help
  circuits-settings`). Example: `./fh call platform_defense --args '{"platform":"Sunward","feed":true}'`
- `platform_gate {platform?}`: a line a platform: at station, moving or stopped, and the current stop's departure
  conditions with what the hub holds against each.
- `demolishers {surface?, near?}`: each demolisher territory the map draws, nearest first, and each demolisher in
  sight now (name, head, health), else where a read last saw it. Each territory's `state`, from what the team saw:
  `has a demolisher` (in sight or last seen), `killed` (`its small-demolisher was killed at tick T (game 22h37m) by
  sol; none seen since`), or `not seen` (`no demolisher seen in it`).
- `shipment {platform | item}`: per schedule stop its departure conditions, each hub request importing from that
  planet with its state (delivered, in flight, launched, loading, waiting and the native gate holding it), what the
  planet's landing pads ask of the hub, and the last visit's pad receipts and spills; with `item`, that item over
  every platform. Cargo conflict lines (also in `preflight {platform}`): an item the hub holds that the landing pads
  of two or more coming stops ask, per stop in order (ask, hold, what goes down there, what is left aboard). A
  delivery, a spill or a hub_full gate comes once in team.alerts to who launched to the platform and its alert list.
- `fleet {platform?}`: one line a platform: where it is and its current stop with each departure condition against the
  hub (as `platform_gate`), the hub's 6 largest stacks, its requests by state (delivered, in flight, launched, loading,
  waiting) with the ones on their way, what is aboard for which stop's landing pads, the rockets on the way now and
  their cargo, thruster fuel and its 10-minute trend, and `waits on`: the first waiting request at the stop it is at
  with the gate holding it; a hub section that is off with requests in it (`hub section 2 is off: its 1 request
  (rocket-fuel 100 from nauvis) is not made`), as `preflight`'s platform lines and `platforms` (compact too:
  `requests_off_line`) say it. Example: `./fh call fleet --args '{"platform":"Swiftlet"}'`
- `min_payload {platforms?, set?}`: every hub request that imports from a planet: platform, item, asks, holds, the
  custom minimum payload and a full rocket of it by weight. `set: {item: N}` sets that number for those items on those
  platforms (0 or false clears it), nothing else changed. It runs in the remote lane too.
  Example: `./fh call min_payload --args '{"platforms":"all","set":{"low-density-structure":50}}'`
- `launch {position, platform | orbit, wait_ready?, wait_platform?, min_cargo?, arrived?, allow_empty?, cargo_for?,
  surface?}`: launches the silo's rocket to `platform` in orbit of this planet. `wait_ready: true` waits for the
  rocket and launches in the tick it is ready (a queue step too; a queued one whose rocket goes records `launched`);
  with `platform` it also waits until the platform is in orbit of the silo's planet (`wait_platform`, the default
  then); a plain tell does not end these waits (one with `wake: true` or an urgent alert does), and a wait that ends
  before the launch ends `not_launched` with `launch_error`. `min_cargo` and `arrived: true` are read in the tick it
  launches. A rocket with no cargo is refused (a launch spends its parts) unless `allow_empty: true`, naming science
  in chests near the silo. A launch to another platform than the one the cargo was loaded for (`load_silo` `platform`)
  is refused unless `cargo_for: "any"`. With the silo's automatic requests on, `launch {position, platform}` launches
  with what the game loaded so far (they stay on). A launch step started while the last rocket is still leaving waits
  for the next rocket (it never reports that launch). A launch waiting while its platform leaves is told (`launch:`
  alerts); a rocket in flight holds the platform until its pod lands. The reply leads with `spoiled_percent` by item
  and `went_up`. `./fh queue submit --file plan.json --args '{"dry_run":true}'` shows the silo cargo before each
  queued launch step.
  Example: `./fh call launch --args '{"position":{"x":65.5,"y":14.5},"platform":"Sunward","wait_ready":true}' --wait`
- `silo {position?, surface?, why?}`: a silo's rocket parts X/50, what it lacks for the parts left (in the silo and at
  its feeders), the cargo's kg and slots, the last launch, `robots_bringing` (what logistic robots carry or have
  reserved toward it) and `requesting_for`. `rocket_ready` is true only for a built rocket (`built_parts` 50/50);
  `next_parts` counts parts for the rocket after it. `platform_requests` flags each request a platform above makes:
  matched (the planet's network holds it), below_min_payload, split_networks (another network holds it), hub_full,
  filling. `why: true` (with `position`) follows the ingredient it is shortest of: its feeder chests (a requester's
  request and its network's stock), then that item's chain on the planet down to the root, with makers not working.
  `launch`, `silo`, `requests` and `configure` (a recipe; `auto_requests`, `send_to_orbit_automatically` on a silo)
  take `surface` (a planet) and `position` and act there by remote view where our force sees the chunk. A silo's
  transfer inventories: `assembling_machine_input` (alias `parts`, the rocket-part ingredients) and
  `rocket_silo_rocket` (alias `cargo`, what goes up with the rocket); `inspect` lists them with a call each. Silo
  alerts: `silo_short.<item>` (parts stalled 2 min) and `silo_ready_idle` (a rocket ready 3 min, not launched).
  Example: `./fh call silo --args '{"position":{"x":65.5,"y":14.5},"why":true}'`
- `cargo {items | position, silo?, to_platform?, incoming?}`: weighs a rocket cargo list (or a chest, silo or pad at
  `position`): each item's weight, the total against a rocket's 1000 kg and 20 cargo slots, the fewest rockets, and
  one split into rockets that keeps each within both. With `silo` (and `to_platform`) it adds when that list can go up
  (rockets, parts, the platform's arrival). `incoming: true` lists our platforms headed for your planet with their ETA
  and hub cargo. Example: `./fh call cargo --args '{"items":{"thruster":2,"cargo-bay":4}}'`
- `load_silo {position, items, to_total?, from?, walk?, up_to?, up_to_stock_at_start?, launch?, platform?,
  wait_platform?, rockets?, launch_split?, wait_min?, auto_requests?, fresh_first?, dry_run?}`: loads `items` into the
  rocket of the silo at `position` (without it the reply lists the silos here) from your inventory, then our chests in
  reach, nearest first (any chest kind, logistic chests and a landing pad too), or from `from` (one chest `{x,y}` or
  up to 16, in order); `to_total: true`: each count is the rocket's total. A spoiling item goes least spoiled first
  (`fresh_first: false`: you, then the chests in order). `launch: true` launches in the tick the last count is aboard.
  Before its rocket is there (with `launch`, ready) it waits while the silo makes parts: `ticks` is an idle window
  grown to 3 times the longest interval seen between parts, capped at `gives_up_tick` (`silo_wait`: parts per minute
  and the window); `wait_min: 15` waits through 15 minutes with no new part; `parts_short` and `last.why` name each
  rocket-part ingredient the silo lacks. `walk: true` with `from` (chests anywhere on the silo's surface, a landing
  pad too) walks between them and the silo as many trips as the load takes, in one timed call (outcomes `loaded`,
  `launched`, `short`; `last.trips`, `last.stops`; `--wait` follows it): it loads nothing until the rocket is there,
  takes the freshest stacks first (`last.freshness`) and skips a trip's other sources once you hold what the rocket
  needs; without `from` it walks to the silo with what you hold. A walking load gives `loaded_items` (what you put
  in), `aboard_before` and `kept` (taken, not loaded, still with you: a teammate's load met the count). When the
  rocket it fills launches by another hand (outcome `rocket_launched`), the tour walks on to the chests it took from,
  latest first, and gives back what it took and did not load (`last.returned`: what, how many, where; `kept`: what did
  not go back; `in_next_rocket`: the list's items in the silo's rocket now).
  `up_to_stock_at_start: true` loads at most what you and the chests held when it began (`stock_at_start`), then ends
  (launches with `launch`). `up_to: true` loads what fits and is held and launches with that (`up_to_short`). A list
  over one rocket is refused unless `launch_split: true` (rockets queued in turn: `split`); `rockets: 3` with `launch`
  queues the same load for 3 rockets. `platform` records whom the cargo is for. `wait_platform: true` (with `launch`
  and `platform`): one timed call that loads nothing until the platform is stopped in orbit here, then loads and
  launches in that tick as one rocket; it ends `launched`, or `failed` when the platform goes elsewhere. A rocket
  holding what a platform above asks for is launched by the game when it stops, one item type a rocket: the wait then
  ends `launched_by_game` (what went, and what stayed in the silo). A silo with automatic requests on is refused,
  naming what is aboard; `auto_requests: "pause"` (with `launch`) turns them off for this manifest and back on after
  its last launch, and a load that ends short or failed leaves them off (`auto_requests_kept_off`; `configure
  {auto_requests: true}` turns them on); with them on, load_silo and preflight name the platforms' open requests a
  rocket may go to. `dry_run: true` (and `preflight`): each item's weight, slots and sources, the rocket's room, the
  split, the hub's free slots, cargo aboard that is not in the list (`foreign_cargo`) and automatic requests that are
  on; nothing loads. The reply gives `freshness` at the top, `loaded` (per item `aboard_before`, `loaded`, `from`,
  `freshness`), `cargo` (everything in the rocket) and `switches` (the silo's automatic requests and send to orbit
  automatically; load_silo never sets them). A queued `load_silo` your own build or transfer interrupts is requeued
  and goes on.
  Example: `./fh call load_silo --args '{"position":{"x":65.5,"y":14.5},"items":{"agricultural-science-pack":1000},"launch":true,"platform":"Sunward","to_total":true}' --wait`
- `silo_stage {position, items, from, launch?, platform?, to_total?, auto_requests?, dry_run?}`: one queue plan for a
  mixed load: reads the silo and the chests now, then takes what the rocket still needs (after what you carry) at each
  chest in `from` (1..16, in that order; also the ingredients its crafts need), hand-crafts each item still missing
  that you can craft (`craft` with `force`, then `wait_until crafting_done`), and runs `load_silo` with `walk`.
  `missing` (in no chest given, not hand-craftable) and `raw_short` (ingredients for the crafts nowhere given) are said;
  `dry_run: true` gives the plan and its steps, nothing queued. Example: `./fh call silo_stage --args
  '{"position":{"x":65.5,"y":14.5},"items":{"pipe":40,"arithmetic-combinator":2},"from":[{"x":10.5,"y":10.5},{"x":12.5,"y":10.5}],"launch":true,"platform":"Swiftlet"}'`
- `preflight {position?, items?, from?, platform?, surface?}`: a silo's cargo (without `position`: all visible indexed
  silos, nearest first), arrival and ETA, and the requests less hub and rocket; with `platform`, incoming rockets,
  `ammo_rates`, `hub_chunks` and cargo conflict lines (as `shipment`); without, the platforms stopped at or headed for
  your planet. With `items` and `from` (one chest position or up to 16) it reads the source chests' stock and shorts,
  and `manifest` checks the combined kg and slots with the cargo aboard; nothing moves. Ammunition counts only when it
  can reach a turret.
  Example: `./fh call preflight --args '{"position":{"x":65.5,"y":14.5},"platform":"Sunward","items":{"agricultural-science-pack":1000}}'`
- `land`: from a platform stopped at a planet, drops you to it in a cargo pod (the core's Space Age part says where
  you land and with what).
- `drop {items, platform?, full?, dry_run?}`: sends one cargo pod (10 slots) of hub items to the planet below a
  stopped platform; `short` says what stays in the hub. `full: true` sends every pod the list takes (each pod's items
  in `pods`); `dry_run: true` shows the pod split first and the landing pad's room (`pad_room`: free slots, what takes
  the rest; `spill`: what would land on the ground). A drop's landing line gives the container's exact position and
  the other cargo pod containers within 8 tiles with what each holds; one sent to a full landing pad says it landed
  beside it, where, and what each container holds. `scan` lists a cargo pod container with `holds`.
  Example: `./fh call drop --args '{"platform":"Sunward","items":[{"item":"iron-plate","count":200}],"dry_run":true}'`
- `freight_audit {item}`: one item across every planet and platform: stock, spoil times, silo room, unmet lab and
  requester demand.
- `where_is {item, surface?, limit?}`: where an item is on a surface: the total by kind and each place holding it,
  nearest first; stacks lying on the ground in chunks our force sees now are `on_ground` (each 32-tile cell a place);
  pods still in the air from our platforms are `in_flight`, also in a platform's arrival alert. A spoilable item adds
  `spoils_within_2_min` beside the total and per place.
- `agriculture {surface?}`: agricultural towers, ghosts and recorded tower-loss positions.
- Aboard a platform (no body) every read works (scan, inspect, science, supply, ... with `platform=` or `surface=`),
  and so do tell, chat, say, operator, the board, research, platform calls, waits on `platform_arrived` and
  `platform_left`, queue plans of the steps the remote lane allows, and every remote-view call with `platform=` or
  `surface=` (place_ghosts, deconstruct, configure, circuit_set, requests with position, ...; the refusal lists them).
  Calls that act by remote view or on another surface (any call with `platform`, `configure` out of reach, ghosts,
  blueprints, deconstruction, `circuit_set`, `wire`, `requests`, schedules) leave your character's action, queue and
  standing orders running; so does a `configure` its checks refuse. Aboard, `observe` gives `player.body: "none"`.
  `./fh view platform=Sunward --out sunward.png` draws a platform's foundation and structure footprints.
- Hub requests: `requests {platform}` reads and sets a hub's sections (`./fh help circuits-settings`).
- Platform foundation: the hub removes a marked foundation tile only beside empty space (a north, east, south or west
  neighbour), and never one that would join separate empty space; marked from the edge in, a row goes one tile at a
  time. `deconstruct`'s reply says `tiles_go` (in order) and `waiting` with why for every marked tile there;
  `"dry_run":true` marks nothing. The hub builds a foundation ghost only with foundation among the 8 tiles round it (a
  corner is enough) and its empty side neighbours in one run (it never splits empty space, even when both sides stay
  open). A dry run on a platform (place_ghosts, build, paste with `dry_run: true`) plays those rules over the new tiles
  and the ghosts ordered: `tiles.unbuilt` names each tile that stays unbuilt and why; for one with no foundation near,
  `tiles.connect` lists the fewest tiles that join it to the built floor (a chain touching by sides or corners,
  `connect_line`); `holes` lists the enclosed tiles that need foundation (beside a new tile with only enclosed regions
  round it, the largest may stay empty: `holes_other`).
- A hub's trash (what is over a request's max) stays aboard in flight; at a stop the game sends it down in cargo pods,
  to the landing pad or, on a planet with none, as a cargo-pod container near (0,0) (`where_is` lists it). A `drop` to
  a planet with no pad lands the same way, near its `near` spot.
- `pods {surface?, position?}`: the landed cargo pods (cargo-pod-containers) on a planet: how many, what they hold by
  item, the nearest (to `position`, default you), each one's position and holding (`at`), the landing pads and their
  free slots; `coverage` says how far the sweep that finds them looks (1024 tiles round (0,0)) and when it last went
  over that planet. The status (`landed_pods`) and, once an hour, your team block say them too, e.g. "Vulcanus: 104
  landed cargo pods hold 10,059 items (iron-plate 3283, ...); nearest (3.5,5.5), 7 tiles; landing pad (12,176) 80 of
  80 slots free". `collect {pods: true}` empties them. Example: `./fh call pods --args '{"surface":"vulcanus"}'`
- Platform loss alerts list each lost entity: rebuilt, a ghost there, or none.
- Gleba: `inspect` on an agricultural tower shows its `tower` state, seeds, output, which cells have soil for which
  seeds, and its plants with time to harvest; `transfer`, `feed` and `collect` work on its seeds and harvest.
- Spoilage: `inspect`, `supply` and `stock` give the first stack to spoil and when; pentapod eggs say when they hatch
  into enemies (`hatch_warning`, `hatch`); `output_spoil` is what a machine's next products start at; `freshness`
  gives each item's spread (least and most spoiled, the share by count, the counts under 25/50/75%, how many spoil
  within 10/30/60 min) in `inspect`, `supply` and every `platforms` row (the hub; `drop` dry_run for the items to
  drop, `launch` for the rocket's cargo), and the moved batch's in `transfer`, `collect` and `load_silo` (a science
  pack: how many a unit the running research takes, and its units left). Eggs of ours hatching within 5 minutes on
  your surface top `team.alerts` (`eggs hatching: ...`) and wake `fh sleep` (`woke: eggs`). Full `status` rechecks
  nearby recorded egg sites: enemies visible now, the timer (future or elapsed), and gun range coverage with ammo; a
  timer alone is no live hatch. A site whose holder no longer holds the eggs before their time (moved or used) is
  neither told nor listed.
