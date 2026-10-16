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
  last launch. `launch`, `silo`, `requests` and `configure` (a recipe; `auto_requests`, `send_to_orbit_automatically`
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
