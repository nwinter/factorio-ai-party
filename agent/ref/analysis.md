- `./fh progress` prints the run so far by shift from the recorded data (technologies, SPM, packs and plates a minute,
  rockets, deaths, loss alerts, machines running, made by machines and moved by hand), a run line and the last 3
  shifts; `--full` for each shift's technologies and packs, `--format json`.
- `./fh call science --args '{"compact":true}'` reads your surface only; its first line says so and counts the labs on
  other planets; `{"all_surfaces":true}` gives the compact read for each planet with labs.
- `./fh research` shows the research queue: each technology's progress, who queued it, its packs, and when it should
  finish at the current lab throughput (or which pack it waits for). `./fh research done` lists what finished lately
  and what each unlocked. A leveled technology (mining-productivity-3) may stand in the queue several times, each the
  next level (`research_queue` and `append` keep the repeats; `over_levels` names more than it has levels left).
  `research {"target_level":{"mining-productivity-3":8}}` keeps adding its next level until 8 is researched (at most
  16 targets, 100 levels ahead; 0 removes one); `{"targets":true}` and the plain read say per target what is
  researching or queued and the levels left. `./fh call science` (or `--args '{"pack":"logistic-science-pack"}'`) counts each pack the
  research needs over your whole surface, the same for everyone wherever they stand: made and used in 10 minutes,
  the assemblers set to it and their states, packs in chests, in landing pads and hubs, on belts, in labs and carried,
  and the largest holders (landing pads included); spoilable packs add effective research units from freshness and remaining durability, before lab bonuses.
  `platforms` and `preflight` cargo freshness give the same value, plus the current leg's arrival value when its ETA is known;
  its `reach` line says where else each pack sits (inserter hands, robots) and why it does not reach the labs; its
  `chain` line walks the pack's recipe tree down, each step with its makers and made and used per minute, following
  the ingredient most makers lack (`chemical-science-pack: 9 of 14 makers lack advanced-circuit, ...; plastic-bar:
  4 of 4 working, made 30/min, used 52/min`), and `chain_tree` lists every step down to ores and fluids; a mined or pumped step names its drills or pumps, their states
  (working, output full, no resource left) and what they put into.
- Shift and factory-digest `research_use` lines compare researched gear with current worn/fitted/carried gear,
  show building tiers per planet from the dated census, and researched vehicles against force-wide built counts.
- `./fh call supply --args '{"item":"advanced-circuit"}'` (optional `"near":{"x":0,"y":0}`, `"radius":64`,
  `"surface"`) reads one item: where it sits (chests by kind, belts (`belt_lines`: the 5 belt lines holding the most, with their ends and the tile with the most), machine outputs, inserter hands, robots,
  characters), each logistic network's stock of it (free and reserved, and which requesters the reserved stock is for),
  its robots, every unmet requester with the reason (`inventory full: all 48 slots taken (spoilage 494 in 10 slots,
  ...)` first when its slots are all taken; `inspect` of the chest shows `slots_full` and `requests_blocked`), the
  `surplus_chest` names the largest unreserved plain/storage/provider stock, excluding requester/buffer chests;
  machines that make and use it by status (the worst 3 with positions), and the inserters feeding them; `throughput` names a machine whose inserters carry less than its
  recipe at full speed, each inserter's rate a minute, and how many inserters like its fastest it takes (`trace
  {position}` on a machine gives the same).
  `full_chests` names chests with every slot used that the makers' output waits on (slots used/total, what fills them,
  the machines waiting); `chests` rows give free slots; `inspect` of a full chest names the nearest chests with free slots.
- `./fh call bottleneck --args '{"item":"processing-unit"}'` follows a shortage down its ingredient chain to where it
  starts, naming each step's makers, their states and what they lack; `fixes` gives, for a starved maker, the nearest
  chest within 64 tiles holding what it lacks and one `transfer` call that carries it there; with `"per_min":30` each step's rate for that
  target, what it makes now, its makers' rate each and the machines the target takes.
- `inspect` on a machine gives its `rate` (crafts
  and output per minute, net of what goes back in), on an agricultural tower its `empty_cells` and why; a take from
  a chest names what robots have reserved there.
- `./fh call trace --args '{"position":{"x":0,"y":0}}'` (a machine or lab; `"platform"` on a platform) lists per
  ingredient it lacks each feeding inserter, what that inserter reads and how much is there, and a container within 10
  tiles holding it that nothing reads; `"forward":true` follows its output inserters and belts lane by lane to where
  they end and what blocks them (on a belt tile, a drill or a chest: from there, forward), naming where other items join a lane (`joins
  transport-belt (12,5) carrying iron-plate on the left lane: your iron-ore mixes in`); `{"item":"chemical-science-pack"}` follows every route from its makers to the labs (for an ore, from the drills mining it).
  `{"position":{"x":-290.5,"y":-312.5},"throughput":true}` on a belt tile reads the line through it (every belt feeding it
  back, on to its end): per lane the mining drills dropping onto it (how many, working, on what) and what they put on
  at full speed against the slowest belt's lane capacity, and what the last 10 tiles hold (give a tile near the end
  to count every drill).
  `"forward":true,"audit":true` adds `audit`: where the walked lanes lose capacity (a belt side-loading both carried
  lanes onto one, a curve made a side-load by an empty stub behind the turn, a route ending at missing tiles with the run
  going on within 4 tiles, what it carries).
  `"upstream":true` goes the other way: from a machine, lab, thruster, hub or belt tile back along what feeds it, naming per ingredient the first place it stops or goes elsewhere (a filter, a circuit condition, an inserter taking it onto another belt, a jammed mixed lane, a splitter filter, where another item joins); `"item"` picks one.
- `./fh call labs` says which labs lack which packs, which inserters feeding them are idle and why, and the research ETA.
- `inspect` shows inserter pickup/drop tiles and fluid connection tiles (`fluid_connections[].joins` is where a pipe
  must go).
- `./fh call inspect --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":20,"y":10}}}'` lists every chest's
  and machine's contents in the area (where inspect reads, up to 64) as one table: `holds`, `requests`, `recipe`, `status_name`.
  With `types` naming belts (`transport-belt`, `underground-belt`, `splitter`, loaders), each belt's `holds` is its lanes
  (`right lane: rocket*4`; an underground's buried part as `... lane underground`), or `empty`.
  `./fh call ports --args '{"name":"electromagnetic-plant","position":{"x":0,"y":0},"direction":"north",
  "recipe":"electrolyte"}'` lists where each fluid port of an unbuilt machine is and the fluid the recipe puts there;
  `inspect` of a ghost shows the same.
- A burner whose burnt-result slot is full and that burns nothing reads `burnt_result_full` in scan, supply,
  bottleneck and the status warning, and `inspect` says what fills it, whatever the game's status reads.
- `power` (observe scope) gives per network `supply_line`: generators' nameplate, what the working ones can give, the stopped ones by status (dry steam engines), and `boilers` by state.
- `power {position, fragile: true, radius?}` lists the poles of that network whose loss alone would cut machines off from all generation, with how many machines and where (centre it on an outpost: wires leaving the radius count as power).
- `./fh call fuel_budget` (optional `"surface"`): each fuel made and used per minute, and each group of fuel users (boilers, furnaces, burner drills, heating towers, `recipe plastic-bar`, ...) with what it burns per minute and the minutes its own fuel lasts, fewest first.
- `game_alerts {kind:"no_power"}` groups connected machines without power by electric network, including isolated drill networks; `move_to` reports narrow-corridor margin crossings in `last.passed_within_margin`.
- `game_alerts {kind:"belt_cut"}` names observed gaps in previously carrying belts; rebuilt gaps clear. `inspect`/`trace` return dated last-seen memory under fog. `order_set` supports radius 256 and ammo/fuel trigger areas up to 256x256; depleted-drill alerts include one cached same-resource placement.
- `belt_gaps {from,to,via?,surface?}` reads remembered belt gaps/ghosts with observation ticks; unrecorded tiles are unknown. `pipe_gaps {from,to,via?}` reads a pipe line live: its fluid segments (fluid, amount, extent) and the cuts where neighbours do not join or the line stops. `danger {position, radius?}` reads a destination before a trip: worms and spawners near it with their reach, enemy units seen now, recent attacks, losses and deaths there, the nests the straight line passes, and your health, armor and shield. `inspect.heating` and build dry_run report freezing, demand, adjacent heat buffers and actual/proposed heat connections.
- `drill_sites {position,surface?}` lists nearest visible same-resource placements for one depleted drill, with mining-area amounts and placement checks; `resource` supplies the name if no previous mining target was recorded. Spots where a drill or drill ghost already stands are left out and named (`occupied_by`).
- `./fh call ores --args '{"resource":"iron-ore"}'` (or every resource; `surface`, `min_amount`, `limit`) lists the
  patches on the charted map nearest first: amount left (oil: yield), distance from you and from our nearest building,
  enemy spawners and worms within 50 tiles, and how many of our drills are on it.
- `inspect` reads any entity on your surface in a chunk our radars see, by remote view (`by: remote view`); out of
  sight and coverage, the refusal names the nearest radar coverage.
- `construction_robots {"sources": true}`: per group of waiting ghosts and item requests, the network's chests holding
  the item (nearest 3) and whether the straight line from each passes within a worm's or spawner's reach the map shows.
- `supply {"item":..., "all_stopped": true}` (and `bottleneck {item, all_stopped}`): every maker and user not working,
  grouped by cluster with every position. `inspect {position, radius}` also counts what it does not list (`also`:
  inserters, poles, belts by type).
- `./fh call construction_robots` (or `{"network":N}`) reads the construction robots of the network you stand in: each
  in the air with its charge, cargo, orders and what holds it up (no storage for what it holds, target out of the
  area, waiting to charge).
- The operator factory digest arrives by `tell` at deadline minus 2 hours, or on operator request: cached planetary machine/fuel counts and sampled belt ends, with observation ages; missing data is unknown.
- `stock {network: 96}` (the number `networks` and an `inspect` of a roboport give): what a logistic network holds,
  its robots, and `roboports`: the robots each roboport holds, most first. `transfer {position: a roboport,
  direction: "to_player", item: "logistic-robot", count}` takes robots out of it, as its GUI does. `stock {item,
  surface}` gives a planet's whole stock of an item. `stock {item, holders: ["provider", "storage"], limit: 32}` lists only those kinds of place;
  each place says its `kind` and what robots have `reserved` there.
- `stock {item, places: "all"}` lists every place on the surface holding it, nearest first, `limit` a page (`page`, `next`).
- `stock {item}` with no radius totals the whole surface (named or yours; a platform is read whole) and lists the places
  within 128 tiles; `covered` says what was read, `as_of` whether a total is live or reused (and its age; `supply` too).
- `belt_gaps` follows a leg that is not straight round the remembered belt's corners (`followed`); `surface` is read.
- `shortages {surface?}`: machines stopped short of an ingredient (by recipe and ingredient), no fuel, low or no power,
  labs waiting for packs, and what requester chests lack, in lines. `bottleneck {item: "lubricant"}` adds `shares`: each
  recipe's machines and share of the fluid at full speed.
- `damage_log {position, radius?, surface?}`: what hit our entities there (alive or destroyed), each source's position and
  facing, for hits our force saw; `inspect` gives an entity's `damage_history`. Empty ground says if its chunk was never
  charted, is charted and out of sight (with our last sight of it), or is in sight; `inspect {position, radius}` reads
  the square round it.
- `reservations {network, item?}` (read only): what robots have reserved to pick up at each provider and storage
  chest, each requester short or with deliveries on the way (its request, what it holds, what is coming, no room when
  every slot is taken), the robots' orders by item and target, and `flags` (reservations while robots are idle, orders
  to a chest with no room for the item).
- `supply {item, compact: true}` and `science {compact: true}`: lines only (supply: flow, where, makers, the stopped
  makers and users by position, the chests holding most; science: one line a pack), about a fifth of the full reply.
- `./fh call danger --args '{"position":{"x":-190,"y":-31}}'` (no position: where you stand): worms and spawners on the
  map round it, enemy units in sight or radar coverage by name, and those more than 24 tiles from every spawner in packs
  (`packs`: count, names, where, how far), apart from those by their nests; attacks, losses, groups, deaths there.
- A full `status` gives `robots`: per planet or platform, all its logistic networks' robots by kind (idle, working,
  charging, waiting to charge) and the networks with the most waiting. Its fuel and power warnings name the surface and
  the first places (`fuel on nauvis: boiler 4/42 no_fuel at (-75,21.5) ...`).
- `./fh call power --args '{"by_cause":true}'` ranks each network's draw by entity name (last 5 s); when roboports draw,
  it adds the robots flying, charging and waiting, what the flying ones draw, their trip lengths and the requesters
  with the most on the way.
- `inspect {area | position+radius}`: `name` filters by name there.
- `trace {position, circuit: true}`: a machine's inserters with their conditions, and the circuit networks on their
  wires followed back through combinators. `fuel_budget {boilers: true}`: each boiler group's burn against the fuel in
  reach and the drills supplying it, with the hours left.
- `where_is` and `stock` for a spoilable item give `spoils_within_2_min` beside the total (and per place).
- `inspect {area}` always returns `entities` (64 a page: `page`, `pages`, `next`) and `by_name` beside them.
- `fuel_budget {boilers: true}` lists each boiler under 5 fuel with its feeding inserters (burner fuel, no power, not
  connected), the nearest chest or belt holding the fuel, and one `refuel {positions, fuel, count, from: "nearest"}` call.
- `inspect {area, all: true}` lists every entity there (belts, poles, inserters too) with its direction and an
  inserter's pickup and drop; `compact: true` gives a line each. `inspect {position}` with nothing there lists what
  stands within 3 tiles (`not_at` says so).
- `scan {fields: "inventory"}` on belts gives their items per lane (`L: ... | R: ...`), on a platform too.
- `stock {item, surface}` adds `by_network`: each logistic network's hold in providers, storage and other holders.
- `where_is` and `stock {item, surface}` count stacks lying on the ground in chunks our force sees now (`on_ground`;
  where_is lists each 32-tile cell as a place).
- `supply` adds `made_by_spoiling` for an item others spoil into (copper-bacteria into copper-ore): how many are held
  and spoil within 5 min; the production statistics do not count spoiling.
