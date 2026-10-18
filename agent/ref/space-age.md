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
  each landing pad received and the pods still in flight; per leg what spoiled on the way; a stop where the platform
  arrived and left between two looks a second apart reads `0s`); `landed` (each cargo pod's receipt, the last 8,
  kept after its stop leaves the freight list: what, received by which pad or landed where, when, the pod's number,
  from which stop); `spoiling` (when its
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
- `platform_schedule {platform, stops, current?, keep_leg?, paused?}`, `{platform, next: true}` or `{platform, stop, wait, go?}`: each stop `{station, wait: [...]}`; a wait is `{type,
  ticks?, condition?, compare: "and"|"or"}`. Types: `time` and `inactivity` (`ticks`), `all_requests_satisfied`,
  `any_request_not_satisfied`, `any_request_zero`, and with a `condition`: `item_count` (an item), `fluid_count` (a
  fluid), `circuit` (any signal on the hub's red and green wires: wire a tank or a combinator to the hub;
  `circuit_note` when the hub has no wire). A condition is `"thruster-fuel >= 10000"` or `{signal, comparator, value |
  signal2}`. `stops: []` clears the schedule; `current` is the 1-based stop to head for; `paused` pauses thrust and
  the schedule. With stops it then calls the GUI's go to station for `current` (`sent_to`). If the state still reads
  `no_schedule`, it writes the schedule again record by record, as the GUI does, and sends it again (`rebuilt` says
  what came of it). `state` is read after; `state_note` says when it is `no_schedule`, `no_path` or `paused` (the
  platform goes nowhere). Seen on world n, not found on a copy: 8 of 8 edits whose current stop was the station the
  platform waited at read `no_schedule` (Sol's 4 at Aquilo, Luna's 4 on Spindle at Fulgora), the rebuild too; the
  same stops with the current on the next stop departed at once. `current_note` says so when an edit's current stop
  is the station it waits at. In flight, `leg` gives the leg before the edit and the current stop now (the same
  destination, back the way it came, or new); `keep_leg: true` makes the current stop the stop for the leg's
  destination (refused when the stops hold none). `next: true` alone calls the game's go to station on the stop after
  the current one now, keeping the records and their waits (`sent_to`: from which stop to which, and where it was).
  The call fails (a failed queue step too) when the platform reads `no_schedule`, `no_path`, or paused without
  `paused: true`, after it; the schedule stays as set, and the reply says what the journals showed: every one-stop
  schedule read no_schedule, and so did longer ones whose current is the stop it waits at; with current on another
  stop they left. One stop that is not where the platform is goes as `[where it is, that stop]`, current 2
  (`one_stop` says so; after that stop's waits it goes back): `one_stop: "as given"` writes the one stop alone.
  `stop: 1, wait: [...]` replaces that stop's waits in place, the records, the current stop and the state kept
  (`edited`). An edit that makes it leave now is refused, nothing changed, unless `go: true`: `current` set to another
  stop while it waits, the stop it waits at left with no wait, or new waits there that hold now (time since arrival,
  item_count against the hub, circuit against the hub's wires); `may_leave` names waits it could not read.
  A count wait needs its `condition`. `{item|fluid, count|at_least}` reads as `"NAME >= N"`, and `seconds` reads as
  ticks (`read_as` says so); any other wait field is refused. `schedule` shows each wait's condition. The game's
  `fluid_count` on a platform did not count the storage tanks on world n: Cinder waited over 5 min on `>= 22000` with
  26000 in its tanks (`fluid_count_note`). A `circuit` wait reads the tanks when they are wired to the hub with their
  contents on the wire; `harness: true` on a fluid_count wait has the harness read the tanks' sum every second while it
  waits there and send it on. Its stop's other waits may be only `time` and `item_count` joined by and (the harness
  reads those too). The game's record then holds a circuit wait that never holds. `waits_run` says which way each
  condition runs, and `harness_waits` (also in `platforms {platform}`) gives the harness's conditions now and its last
  send. `wait_until` with `platform` takes `fluid_count` (`fluid, at_least | below`: the storage tanks) and
  `circuit_signal` (`signal, at_least | below`: the hub's wires), the remote lane too.
  Example: `./fh call platform_schedule --args '{"platform":"Sunward","stops":[{"station":"nauvis","wait":[{"type":"time","ticks":216000},{"type":"circuit","condition":"thruster-fuel >= 10000","compare":"and"}]},{"station":"gleba","wait":[{"type":"all_requests_satisfied"}]}]}'`
- `platform_rename {platform, name}`: renames one, listing the queues, orders, plans and board items still naming the
  old name (`still_named`; none changed).
  Example: `./fh call platform_rename --args '{"platform":"Sunward","name":"Kestrel"}'`
- `platform_endurance {platform, route?, forecast?, pessimistic?}`: per leg its km and minutes at its speed; per
  ammunition, repair pack and thruster fluid aboard its stock, made and used per minute and the leg it runs out on;
  hub slots free, power, solar power at the stops, and the asteroid chunks collected a minute; `fuel_outlook`: one line
  of thruster fuel and oxidizer held (thrusters and tanks), made and used a minute over the last minute, and flying
  whether each lasts the rest of the leg at the speed now (a team alert to the platform's people when one runs out
  before the leg ends, once while it lasts). `route`: the locations
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
  `platform_supply {platform, fuel: true}`: the fuel feedstock from the thrusters back, one line a link, indented by
  level: the thrusters' fill, their pipes (through pumps, each with its state) and the fuel and oxidizer makers there;
  each maker's ingredients against one craft, through the inserters dropping into it, belts walked upstream (what they
  hold, the inserters dropping onto them, a start nothing feeds, an underground exit with no entrance or a span over
  empty space), the hub (with none: the machines that unload it there), crushers, ice melters, collectors.
  `first_missing`: the first consumer short of a craft whose way is broken, else the first missing link below it.
- `platform_plan {platform, floor?, page?, ready?, salvage?, support?, floor_check?}`: the platform as planned, built entities and ghosts
  together: foundation islands, belt loops, head-on belts and side-loads. `floor_check: true` plays the hub's
  foundation rules over every foundation tile ghost across ticks (about 150 rule checks a tick; a few thousand tiles
  take seconds) and gives its number; `floor_check: N` reads it: running, or done with `would_build` (the planned tiles
  the hub's rules build in turn once their items come), `never_built`, `by_reason`, the first 12 `unbuilt` with why,
  and `floor_now` (the foundation built now). `floor: true`: the foundation the entity
  ghosts need (footprints, tunnels, holes, links) as `place_ghosts_entries`, 256 a page (`page: N`); a tunnel runs to
  the next underground of its name facing the same way (one crossing it is passed over); `tile_ghosts_held` names tile
  ghosts counted as floor that the hub's foundation rules never build. `ready: {positions, area, tiles}`: one subset's
  missing items, foundation support and settings, and `pockets`: the empty space under each ghost's footprint as the
  hub's rules see it (the 4-neighbour region of empty tiles bounded by foundation, up to 1024 tiles): its tiles, area,
  those without a tile ghost (the hub fills a pocket only when every tile of it holds one) and `pocket_entries` for
  place_ghosts to stamp them; past 1024 tiles, open space. Floor and ready leave out the tiles a collector's rule keeps empty
  (its front): rear support only. `salvage: 60`: foundation tiles to take up from the edge in, as deconstruct areas
  (never one under an underground belt or pipe span, or at its ends, nor one in a hole the tile ghosts would close:
  `restored`), played through the hub's removal rule (`go`, `net_saved`, `waiting`). `support: true` or `{positions,
  area, names}`: the floor those entities (built and ghost) need and no more (footprints, underground belt and pipe
  spans, the fewest tiles joining them to the hub's floor, and every tile of a hole that floor would enclose: the hub
  never builds the last ghost round a hole; a hole built floor alone encloses stays open), played through the hub's
  build rules (`stalls`: kept ghosts it never builds; `net_saved`), and the foundation tile ghosts outside it as `remove_areas`,
  64 a page, each a `deconstruct {platform, area, tiles: ["space-platform-foundation"]}`; `strands` names entity ghosts
  not chosen that stand on a tile that would go. Read only.
  Example: `./fh call platform_plan --args '{"platform":"Meridian","floor":true,"page":1}'`
- `platform_bom {platform | surface, pack?, request?, import_from?, area?, min_payload?, tail?}`: per item, what the ghosts
  still need less hub stock, cargo in flight and what its construction robots carry, what is built and what the hub
  asks. Module and other item requests count, on ghosts and on built machines (`requests`). `pack: true` splits the
  rest into rockets for `load_silo`. `request: true` keeps a hub request section (`platform_bom: NAME`) at what the
  ghosts and machines still need less what the construction robots carry (items taken from the hub for a ghost not
  built yet are asked no second time), lowered as they are built and removed when none is left; each tick a drop in
  what the hub holds of an item it asks for lowers that request by as much at once (the hub spends its stock on ghosts
  before they count as built), and the rewrite every 10 s counts all again; each item keeps its slot from one
  rewrite to the next (one no longer needed is cleared where it stands, a new one takes a free slot). With ghosts
  open, `requests_check` says whether every item they still need has an active hub request, and `unrequested` names
  each one that has none while the hub, pods in flight and robots hold less than the ghosts need (`request: false`
  removes it; `import_from`,
  `area`; `min_payload: {item: N}`; a min_payload set on its slots by `min_payload` or `requests` is taken as its own
  and kept (the line says `adopted`); `tail: true`: an item's minimum payload no more than what is still to come, its
  request less what the hub holds, a slot on the game's default, a full rocket by weight, too; each line says the
  minimum payload the slot has). `surface: "gleba"` with no platform:
  every platform's active hub requests importing from that planet, a line a platform with what it lacks (asks, holds)
  and where it is. Example: `./fh call platform_bom --args '{"platform":"Meridian","pack":true}'`
- `platform_production {platform, item?}`: the platform's own production per item (totals, rates over 1m, 10m, 1h).
  `wait_until {until: "produced", platform, item, at_least}` waits for it.
  Example: `./fh call platform_production --args '{"platform":"Sunward","item":"space-science-pack"}'`
- `platform_defense {platform, feed?, route?}`: each asteroid collector's front and each hull side against turret ranges: the
  turrets that reach it (ammo, fed by an inserter, robots or by hand), NO turret with the nearest, and edge gaps as
  runs. Damage apart from reach, for `route` (`"fulgora->aquilo"` or a connection name; default the schedule's next
  leg): each asteroid that spawns on it with its health and resistances, and per turret and the ammo it holds its
  damage a second after them against its listed damage (the force's bonuses counted), together and the time to kill
  one; under 10% of listed: `reached, little damage`. A big metallic asteroid resists physical 2000 flat, so a
  firearm round does almost nothing to it. A railgun's `line of fire` names the entities of ours its shots cross: it aims within 36 degrees of its facing
  (72 in all), and its ammo's line (1 wide, to 53.6 tiles from its centre) damages ours too; with what it engages. It traces each turret's ammunition back: what can reach it (its inserters, the belts upstream and who loads
  them, the hub) and what stops it; the ammunition that can reach each turret; the ammo stranded on belts no turret's
  way reaches, per group with its belts and the call that recovers it (a belt `pickup` aboard, else `deconstruct` of
  those belts into the hub). A way goes on through inserters moving items from belt to belt (relays, long-handed
  bridges) and counts only inserters not switched off; belts running back into the hub count as reaching when the
  hub feeds a turret (`belts back into the hub`); a belt that ends just past a pickup on a turret's way is listed
  apart (`at belt ends`), not as stranded. Switched-off loaders are named only when nothing else puts items on.
  `feed: true` lists every turret. A team alert names turrets whose feeds ran dry while
  ammunition aboard is stranded. Cover is per asteroid size (small, medium, big, huge): a turret engages what its
  priority list allows (ignore unprioritised targets on: only those listed) and reaches within its range and past its
  minimum range (rocket turret 15 tiles); a size is covered where every kind of it (metallic, carbonic, oxide;
  promethium when a turret lists one) is engaged by a turret reaching it. Each collector line gives `by size`, each
  side its uncovered edge tiles per size, and a line names the turrets engaging only part of the asteroids.
  `circuit_audit {platform}` reads a platform's misleading circuit readings (`./fh help
  circuits-settings`). Example: `./fh call platform_defense --args '{"platform":"Sunward","feed":true}'`
- `platform_digest {platform}`: one read of a platform from `platforms`, `platform_supply`, `platform_endurance` and
  `platform_defense`: first what is stopped or blocked (the supply chain's stops: collectors, crushers, fuel and
  oxidizer makers, thrusters, empty guns; collectors no turret reaches; hull sides with uncovered edge tiles; machines
  on no power), then the route and arrival, hub slots and the chunks in it, chunks collected and where each goes,
  crushers and makers (state, in and out), thrusters, the fuel outlook, tanks and ammunition (stock, made and used, run-out, stranded),
  turrets and power; `errors` names a read that failed. Each of the four reads gives the detail.
- `platform_tiles {platform, positions | area}`: up to 64 tiles at exact coordinates: the tile, marked for removal, a
  tile ghost, what stands on it; for foundation whether the hub takes it away now once marked (`remove {now, why}`: one
  run of empty space beside it, nothing on it, room in the hub), for empty space whether the hub builds foundation
  there now (`build {now, why}`: foundation among the 8 tiles round it, at most one run of empty space beside it, not
  in a thruster's exhaust or over 200 tiles north of the hub). Example:
  `./fh call platform_tiles --args '{"platform":"Kestrel II","area":{"left_top":{"x":-4,"y":8},"right_bottom":{"x":4,"y":16}}}'`
- `platform_rearm {platform, positions?, item?, ammo_below, target_count}`: each named turret (default every ammo turret
  aboard) holding under `ammo_below` of its ammunition (`item`, default what it holds now), counting an item request
  already on the way, gets an item request for the rest up to `target_count`; the hub fills it, as `deliver`'s, no
  body. Rows: `held`, `on_the_way`, `requested`; `hub` (what the hub holds of each item asked), `refills` (requests and
  rounds asked on this platform since). A step of the platform's lane; `queue_repeat` keeps topping up; it works while
  your character is aboard a platform too. Example:
  `./fh call queue_repeat --args '{"lane":"platform:Swiftlet","interval_ticks":600,"steps":[{"action":"platform_rearm","args":{"platform":"Swiftlet","ammo_below":20,"target_count":100}}]}'`
- `platform_gate {platform?}`: a line a platform: at station, moving or stopped, and the current stop's departure
  conditions with what the hub holds against each; a circuit condition with what the hub's wires read of its signals
  (`the hub has no circuit wire` when none: it reads 0).
- `demolishers {surface?, near?}`: each demolisher territory the map draws, nearest first, and each demolisher in
  sight now (name, head, health, and its whole `body`: the line through its segments, length, tiles under it, box,
  which way the head moves and how fast), else where a read last saw it. Any segment in sight counts as in sight.
  Each territory's `state`, from what the team saw: `has a demolisher` (in sight or last seen), `killed` (`its
  small-demolisher was killed at tick T (game 22h37m) by sol; none seen since`), or `not seen` (`no demolisher seen in
  it`).
- `shipment {platform | item}`: per schedule stop its departure conditions, each hub request importing from that
  planet with its state (delivered, in flight, launched, loading, waiting and the native gate holding it), what the
  planet's landing pads ask of the hub, and the last visit's pad receipts and spills, and the platform's last 2 drops
  into a pad there with what the pad showed after (as the drops read's pad line); with `item`, that item over
  every platform. Cargo conflict lines (also in `preflight {platform}`): an item the hub holds that the landing pads
  of two or more coming stops ask, per stop in order (ask, hold, what its requests from that planet keep, what goes
  down there, what is left aboard). At a stop the hub keeps only what its requests from that planet ask (as
  `requests` says). A
  delivery, a spill or a hub_full gate comes once in team.alerts to who launched to the platform and its alert list.
  `shipment {platform, ready: true}`: freight readiness for the planet it stops at (else the stop it flies to): its
  gate (as `platform_gate`), the requests from there not delivered, each silo of ours there (its rocket; automatic
  requests on or off and for which platform it fills; each request of this platform with its flag, the payload a
  rocket waits for, the network's stock and what the rocket holds of it; the circuit and logistic conditions of
  inserters and loaders within 8 tiles with what each reads now), and its landing pads (free slots each; per item the
  hub would send down: count, slots, what the pads can take of it now, `short`). Silos and pads are searched once a
  minute.
- `fleet {platform?, leg?}`: one line a platform: where it is and its current stop with each departure condition against the
  hub (as `platform_gate`), the hub's 6 largest stacks, its requests by state (delivered, in flight, launched, loading,
  waiting) with the ones on their way, what is aboard for which stop's landing pads, the rockets on the way now and
  their cargo, thruster fuel and its 10-minute trend, and `waits on`: the first waiting request at the stop it is at
  with the gate holding it; a hub section that is off with requests in it (`hub section 2 is off: its 1 request
  (rocket-fuel 100 from nauvis) is not made`), as `preflight`'s platform lines and `platforms` (compact too:
  `requests_off_line`) say it. `leg: true` (with `platform`): a courier leg in one read: that line, then each wait of
  yours naming the platform (the action running and each lane's current step) read now (met or not yet, what the hub
  holds), then each rocket on its way: from where, launched when, rising or coming down, and when it arrives at the
  last arrivals' launch-to-arrival time. Example: `./fh call fleet --args '{"platform":"Swiftlet"}'`
- `min_payload {platforms?, set?}`: every hub request that imports from a planet: platform, item, asks, holds, the
  custom minimum payload and a full rocket of it by weight. `set: {item: N}` sets that number for those items on those
  platforms (0 or false clears it), nothing else changed. It runs in the remote lane too. A minimum payload heavier
  than a rocket lifts (1000 kg) is refused here, in `requests` and in `platform_bom`, naming the most that fits.
  Example: `./fh call min_payload --args '{"platforms":"all","set":{"low-density-structure":50}}'`
- `launch {position, platform | orbit, wait_ready?, wait_platform?, min_cargo?, arrived?, allow_empty?, cargo_for?,
  hub_full?, surface?}`: launches the silo's rocket to `platform` in orbit of this planet. A cargo the platform's hub has
  no room for (the slots it takes after topping up part stacks, against the hub's free slots, asteroid chunks named)
  is refused unless `hub_full: true`; load_silo (it launches through this), its dry run (`platform_hub_room`) and
  preflight's platform line say the same. `wait_ready: true` waits for the
  rocket and launches in the tick it is ready (a queue step too; a queued one whose rocket goes records `launched`);
  with `platform` it also waits until the platform is in orbit of the silo's planet (`wait_platform`, the default
  then); a plain tell does not end these waits (one with `wake: true` or an urgent alert does), and a wait that ends
  before the launch ends `not_launched` with `launch_error`. `min_cargo` and `arrived: true` are read in the tick it
  launches. A rocket with no cargo is refused (a launch spends its parts) unless `allow_empty: true`, naming science
  in chests near the silo. A launch to another platform than the one the cargo was loaded for (`load_silo` `platform`)
  is refused unless `cargo_for: "any"`. With the silo's automatic requests on, `launch {position, platform}` launches
  with what the game loaded so far (they stay on). An item only another network on the planet holds (`silo`'s
  `platform_requests` flag `split_networks`, naming the chest robots would take it from in each) goes over by hand:
  `load_silo` with `walk: true`, `from` those chests, `launch: true`, `platform` (and `auto_requests: "pause"` while
  the silo's automatic requests are on); that row's `load_silo` holds those args. A launch step started while the last rocket is still leaving waits
  for the next rocket (it never reports that launch). A launch waiting while its platform leaves is told (`launch:`
  alerts); a rocket in flight holds the platform until its pod lands. The reply leads with `spoiled_percent` by item
  and `went_up`. `./fh queue submit --file plan.json --args '{"dry_run":true}'` shows the silo cargo before each
  queued launch step.
  Example: `./fh call launch --args '{"position":{"x":65.5,"y":14.5},"platform":"Sunward","wait_ready":true}' --wait`
- `silo {position?, surface?, why?}`: a silo's rocket parts X/50, what it lacks for the parts left (in the silo and at
  its feeders), the cargo aboard (items, kg against the lift, `room_kg` left, slots), the last launch, `robots_bringing` (what logistic robots carry or have
  reserved toward it) and `requesting_for`. `rocket_ready` is true only for a built rocket (`built_parts` 50/50);
  `next_parts` counts parts for the rocket after it; `parts_made` and `parts_per_min` (over the last 10 min).
  `platform_requests` flags each request a platform above makes: matched (the planet's network holds it),
  below_min_payload, split_networks (another network holds it), hub_full, filling; each with what the silo's network
  can give now (provider and storage chests, less robots' reservations; requester and buffer chests not counted) and
  `next_launch` (an automatic launch for it goes under `min_payload N` or `full N` by weight); `next_auto_launch` names
  the request the next automatic launch serves. `why: true` (with `position`) follows the ingredient it is shortest of: its feeder chests (a requester's
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
  wait_platform?, rockets?, launch_split?, wait_min?, auto_requests?, fresh_first?, first?, dry_run?}`: loads `items` into the
  rocket of the silo at `position` (without it the reply lists the silos here) from your inventory, then our chests in
  reach, nearest first (any chest kind, logistic chests and a landing pad too), or from `from` (one chest `{x,y}` or
  up to 16, in order); `to_total: true`: each count is the rocket's total. A spoiling item goes least spoiled first
  (`fresh_first: false`: you, then the chests in order). `launch: true` launches in the tick the last count is aboard.
  Before its rocket is there (with `launch`, ready) it waits while the silo makes parts: `ticks` is an idle window
  grown to 3 times the longest interval seen between parts, capped at `gives_up_tick` (`silo_wait`: parts per minute
  and the window); `wait_min: 15` waits through 15 minutes with no new part; `parts_short` and `last.why` name each
  rocket-part ingredient the silo lacks. `walk: true` with `from` (chests anywhere on the silo's surface, a landing
  pad too) walks between them and the silo as many trips as the load takes, in one timed call (outcomes `loaded`,
  `launched`, `short`; `last.trips`, `last.stops`): it loads nothing until the rocket is there,
  takes the freshest stacks first (`last.freshness`) and skips a trip's other sources once you hold what the rocket
  needs; without `from` (or with `chests: false`) it walks to the silo with what you hold. `all_or_nothing: true`
  (with `launch`): the launch goes only with every listed item aboard in full (the rocket read again); a short load
  stays in the silo and the refusal names what is missing (not with `up_to` or `launch_split`). A walking load gives `loaded_items` (what you put
  in), `aboard_before` and `kept` (taken, not loaded, still with you: a teammate's load met the count). When the
  rocket it fills launches by another hand (outcome `rocket_launched`), the tour walks on to the chests it took from,
  latest first, and gives back what it took and did not load (`last.returned`: what, how many, where; `kept`: what did
  not go back; `in_next_rocket`: the list's items in the silo's rocket now).
  `up_to_stock_at_start: true` loads at most what you and the chests held when it began (`stock_at_start`), then ends
  (launches with `launch`). `up_to: true` loads what fits and is held and launches with that (`up_to_short`). A list
  over one rocket is refused unless `launch_split: true` (rockets queued in turn: `split`); `rockets: 3` with `launch`
  queues the same load for 3 rockets. `platform` records whom the cargo is for. `wait_platform: true` (with `launch`
  and `platform`): one timed call that loads nothing until the platform is stopped in orbit here, then loads and
  launches in that tick as one rocket; it ends `launched`, or `failed` when the platform goes elsewhere. With `walk: true`
  and `from` the walk gathers from the chests first, then waits at the silo the same way (a walking load with `launch`
  and `platform` holds at the silo while the platform flies here). With `launch` a walking load that reaches the silo
  before the rocket is ready holds there, in reach, loading nothing until it is; status's active then gives `holding`
  (`at the silo stop (17.5,-13.5), in reach: waiting for the rocket to be ready (rocket parts 29 of 50, 31.1 a minute),
  the last part in about 40s at that rate; held for it: 1000; holding 42s`) and no `stuck_s`. A rocket
  holding what a platform above asks for is launched by the game when it stops, one item type a rocket: the wait then
  ends `launched_by_game` (what went, and what stayed in the silo). A silo with automatic requests on is refused,
  naming what is aboard; `auto_requests: "pause"` (with `launch`) turns them off for this manifest and back on after
  its last launch, and a load that ends short or failed leaves them off (`auto_requests_kept_off`; `configure
  {auto_requests: true}` turns them on); they also stay off while the rocket still holds cargo no platform above asks
  for, which would go to the trash slots (the reply says so); with them on, load_silo and preflight name the platforms' open requests a
  rocket may go to. The game has no priority among a silo's automatic requests. `first: ["space-platform-foundation",
  "asteroid-collector"]` (with `platform`): those items alone, each at what the hub lacks of its requests (or
  `{item: count}`), from what you hold and the chests of the silo's network robots would take from first (or `from`),
  walked, launched to the platform with automatic requests paused (`"pause"`); `first` names the counts and chests,
  `first_skipped` items the hub lacks none of. A dry run pauses nothing. `dry_run: true` (and `preflight`): each item's weight, slots and sources, the rocket's room, the
  split, the hub's free slots, cargo aboard that is not in the list (`foreign_cargo`) and automatic requests that are
  on; nothing loads. The reply gives `freshness` at the top, `loaded` (per item `aboard_before`, `loaded`, `from`,
  `freshness`), `cargo` (everything in the rocket) and `switches` (the silo's automatic requests and send to orbit
  automatically; load_silo never sets them). A queued `load_silo` your own build or transfer interrupts is requeued
  and goes on. A walking load with `launch` that ends with none made and the list's items aboard (time ran out, a
  paused queue, a refused launch) says so in `last.loaded_not_launched` (what, the rocket, why). The same load again with
  `to_total: true` and `launch` loads none of what is aboard again: the list aboard already, it walks nowhere and
  launches as it is when the rocket is ready and the platform here. A load_silo that runs over time returns when it ends, with or without `--wait`, its outcome the exit
  status; `--no-wait` returns at the start (`until_tick`).
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
- `drop {items, platform?, full?, dry_run?, partial?}`: sends one cargo pod (10 slots) of hub items to the planet below
  a stopped platform; `short` says what stays in the hub, and `partial {sent, stayed, why}` when it sent part of the
  list: a queue step with it fails unless `partial: true`. `full: true` sends every pod the list takes (each pod's items
  in `pods`); `dry_run: true` shows the pod split first and the landing pad's room (`pad_room`: free slots, what takes
  the rest; `spill`: what would land on the ground). A drop's landing line gives the container's exact position and
  the other cargo pod containers within 8 tiles with what each holds; one sent to a full landing pad says it landed
  beside it, where, and what each container holds. `scan` lists a cargo pod container with `holds`. A drop into a
  landing pad: the pad's count of the sent items before and when it landed, then for 20 s each fall in it with the
  construction and logistic robots of ours within 8 tiles holding that item (and the first ghost or entity each flies
  to); its landing line comes 20 s after it lands with that line (the drops read: `pad`, `pad_verdict` such as `landed, then
  taken by construction robots`, `pad_now`). The game reserves nothing for the sender: robots may take what lands in a
  pad.
  Example: `./fh call drop --args '{"platform":"Sunward","items":[{"item":"iron-plate","count":200}],"dry_run":true}'`
- `freight_audit {item}`: one item across every planet and platform: stock, spoil times, silo room, unmet lab and
  requester demand.
- `where_is {item, surface?, limit?}`: where an item is on a surface: the total by kind and each place holding it
  (landed cargo pods of any force as kind `pod`, stacks on the ground in sight as kind `ground`),
  nearest first; stacks lying on the ground in chunks our force sees now are `on_ground` (each 32-tile cell a place);
  pods still in the air from our platforms are `in_flight`, also in a platform's arrival alert; inserter hands and
  what our logistic and construction robots carry now (`robot_cargo`, up to 4096 robots read) count in the total. A spoilable item adds
  `spoils_within_2_min` beside the total and per place. Its drops list: the last 4 drops of it into a landing pad on that
  surface, each with what the pad showed after (`landed, then taken by construction robots: drop #N ...`).
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
  `"dry_run":true` marks nothing. `spans_cut` names each underground belt or pipe-to-ground pair whose span (the
  tiles between its ends) holds a tile it marks or one marked already: a span over empty space is cut. A live tile
  deconstruct with `spans_cut` marks nothing and is refused unless `"cut_spans":true`. The hub builds a foundation ghost only with foundation among the 8 tiles round it (a
  corner is enough) and its empty side neighbours in one run (it never splits empty space, even when both sides stay
  open). A dry run on a platform (place_ghosts, build, paste with `dry_run: true`) plays those rules over the new tiles
  and the ghosts ordered: `tiles.unbuilt` names each tile that stays unbuilt and why (a plan its 400 rule checks in
  one tick do not finish counts none unbuilt: `tiles.check` names the check across ticks it started, read with
  `platform_plan {platform, floor_check: N}`); for one with no foundation near,
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
  your surface top `team.alerts`, one line a surface (`eggs hatching on gleba: N within 5 min in H holders; the first:
  ...; by area: ...`), told again only when the set of holders due there changes, and wake `fh sleep` (`woke: eggs`). Full `status` rechecks
  nearby recorded egg sites: enemies visible now, the timer (future or elapsed), and gun range coverage with ammo; a
  timer alone is no live hatch. A site whose holder no longer holds the eggs before their time (moved or used) is
  neither told nor listed.
- `eggs {surface?, limit?}`: every holder of eggs on a surface (default yours) from the egg sweep (every 30 s), the
  first to hatch first: count, item, holder, position, who placed it, spoiled percent (mean and the first stack), the
  first hatch (into what, when), how many within 5 min, and the turrets of ours ready in range (`limit` holders, default
  64); a head line with the eggs due within 5 min by 64-tile area and the sweep's age. Example: `./fh call eggs --args
  '{"surface":"gleba"}'`
