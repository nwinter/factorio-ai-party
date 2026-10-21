- `./fh progress [--full] [--last N] [--format json]`: the run so far by shift from the recorded data (no game call):
  a line per shift (technologies, SPM, packs and plates a minute, rockets, deaths, loss alerts, machines running, made
  by machines and moved by hand), a run line and the last 3 shifts' trend; `--full` gives each shift's technologies
  and packs; `--last N` only the last N shifts. Example: `./fh progress --last 3`
- `research {technology | research_queue, front?, append?, remove?, move?, to?, target_level?, targets?}` and
  `./fh research`: the research queue: each technology's progress, who queued it, its packs, and when it should finish
  (`done_in`, at the last minute's lab throughput) (or which pack it waits for). A leveled technology
  (mining-productivity-3) may stand in the queue several times, each the next level (`research_queue` and `append`
  keep the repeats; `over_levels` names more than it has levels left). `target_level: {"mining-productivity-3": 8}`
  keeps adding its next level until 8 is researched (at most 16 targets, 100 levels ahead; 0 removes one); `targets:
  true` and the plain read say per target what is researching or queued and the levels left. Example: `./fh call research --args '{"target_level":{"mining-productivity-3":8}}'`
- `research_done` (`./fh research done`): what finished lately, newest first, and what each unlocked (a technology
  with levels: the level done).
- `science {pack?, surface?, compact?, all_surfaces?}`: counts each pack the research needs (or `pack`) over your whole
  surface, the same for everyone wherever they stand: made and used in 10 minutes, the assemblers set to it and their
  states, packs in chests, in landing pads and hubs, on belts, in labs and carried, and the largest holders (landing
  pads included). Spoilable packs add effective research units from freshness and remaining durability, before lab
  bonuses. Its `reach` line says where else each pack sits (inserter hands, robots) and why it does not reach the labs;
  its `chain` line walks the pack's recipe tree down, each step with its makers and made and used per minute,
  following the ingredient most makers lack (`chemical-science-pack: 9 of 14 makers lack advanced-circuit, ...;
  plastic-bar: 4 of 4 working, made 30/min, used 52/min`), and `chain_tree` lists every step down to ores and fluids;
  a mined or pumped step names its drills or pumps, their states (working, output full, no resource left) and what
  they put into. `compact: true`: one line a pack, your surface only, about a fifth of the full reply; its first line
  says so and counts the labs on other planets; `all_surfaces: true` gives the compact read for each planet with labs.
- `supply {item, near?, radius?, surface?, compact?, all_stopped?, split?, requesters?, makers?, consumers?}`: `makers: "all"`: every machine
  making it on the surface, nearest first, 24 a call (`from`), each with status and why, rate (as inspect's: a product
  exempt from productivity, an egg breeder's returned egg, gets none; `net_per_min` when it goes back in), inputs
  against one craft and what it feeds. `consumers: "all"`: every machine whose recipe takes it (status, its take a minute now and at full
  speed) and every requester or buffer chest asking for it (as `requesters` reads them), the largest use first, 24 a
  call (`from`), with the totals. `requesters: true`: who gets
  an item: every requester or buffer chest in a logistic network on the surface asking for it, served now (robots bringing N) first, then
  unmet (and why: no network, none free, no idle robot, none on the way yet), then met, each with its request, what it
  holds and the machines it feeds that use it (working, take a minute); each network's free stock and idle robots;
  then the chests that feed machines using it but ask for none of it (with what they ask). `split: true`: where an item or fluid goes
  now: each group of our machines whose recipe takes it (by recipe and place) with how many work, its take at full
  speed and share, and what feeds it: an item, what its feeding inserters pick from (belts, requester chests by
  network, chests, drills dropping in), then requester chests asking for it that feed none of them; a fluid, the pipe
  segments its input boxes are on, each with the machines making it there (none: tanks, pumps or a pipe between). Otherwise one item or fluid: where it sits (chests by kind,
  belts (`belt_lines`: the 5 belt lines holding the most, with their ends and the tile with the most), machine outputs,
  inserter hands, robots, characters), each logistic network's stock of it (free and reserved, and which requesters the
  reserved stock is for), its robots, every unmet requester with the reason (`inventory full: all 48 slots taken
  (spoilage 494 in 10 slots, ...)` first when its slots are all taken), machines that make and use it by status (the
  worst 3 with positions) and the inserters feeding them. A short machine whose input inserter is off by its circuit
  or logistic condition, or whose requester asks for less than one craft, is named as that first (the condition and
  what the source holds), ahead of plain shortages. `surplus_chest` names the largest unreserved plain, storage
  or provider stock (requester and buffer chests left out); `throughput` names a machine whose inserters carry less than
  its recipe at full speed, each inserter's rate a minute, and how many inserters like its fastest it takes (`trace
  {position}` on a machine gives the same); `full_chests` names chests with every slot used that the makers' output
  waits on (slots used/total, what fills them, the machines waiting); `chests` rows give free slots. A fluid
  (`lubricant`) gives its stock and flow, makers and users. `made_by_spoiling` (an item others spoil into:
  copper-bacteria into copper-ore): how many are held and spoil within 5 min; the production statistics do not count
  spoiling. `as_of` says whether a total is live or reused, and its age. `near` with `radius` (up to 512, default 64)
  limits it to that area; `compact: true`: lines only (flow, where, makers, the stopped makers and users by position,
  the chests holding most), about a fifth of the full reply; `all_stopped: true`: every maker and user not working,
  grouped by cluster with every position. Example: `./fh call supply --args '{"item":"advanced-circuit","near":{"x":0,"y":0},"radius":64}'`
- `bottleneck {item, per_min?, all_stopped?, surface?}` (or `area`, `positions`): follows a shortage down its ingredient
  chain to where it starts, naming each step's makers, their states and what they lack; `fixes` gives, for a starved
  maker, the nearest chest within 64 tiles holding what it lacks and one `transfer` call that carries it there.
  `per_min: 30`: each step's rate for that target, what it makes now, its makers' rate each and the machines the target
  takes; an ingredient is counted net of what its recipe gives back (asteroid crushing). A fluid adds `shares`: each
  recipe's machines and share of the fluid at full speed. `all_stopped: true`: every maker not working, grouped by
  cluster with every position. A maker stopped by its own circuit or logistic condition carries the gate inline (the
  condition and what it reads now), in bottleneck's groups (`gate`, with area or positions) and in supply's and
  bottleneck item's maker lines. Example: `./fh call bottleneck --args '{"item":"processing-unit","per_min":30}'`
  `chain: true` (with item): each link of the recipe chain back from the item, with its makers and their states, made
  and used a minute now, full speed, what the link it feeds asks at its full speed, and logistic stock; `limit` is the
  link the shortage comes down to (followed while a link's makers mostly lack an input), with its numbers and its
  makers' states. Up to 16 links and 24 makers a link read; machines from the census pass (`as_of`).
- `trace {position | item, platform? | surface?, forward?, audit?, upstream?, throughput?, circuit?, all?, near?,
  radius?}`: on a machine or lab, per ingredient it lacks each feeding inserter, what that inserter reads and how much
  is there, and a container within 10 tiles holding it that nothing reads. A belt lane it picks from that is full of
  another item and holds none of the ingredient is followed upstream (256 tiles): the jam, the blocking item, the
  inserter putting it on (what it takes from, its circuit or logistic condition and whether it holds now; else the
  belts feeding the line's start), and the first consumer of the ingredient past it (`blocked`). `competitors`: the
  other takers of it at the feeder's source (inserters on that lane, followed 64 tiles upstream, into another machine
  whose recipe takes it or into a chest; at a chest or machine output the other inserters taking from there), each with
  its machine, recipe, state and what the recipe uses of it a minute at its speed. `forward: true` follows its output inserters
  and belts lane by lane to where they end and what blocks them (on a belt tile, a drill or a chest: from there,
  forward), naming where other items join a lane (`joins transport-belt (12,5) carrying iron-plate on the left lane:
  your iron-ore mixes in`); with `audit: true` it adds `audit`: where the walked lanes lose capacity (a belt
  side-loading both carried lanes onto one, a curve made a side-load by an empty stub behind the turn, a route ending at
  missing tiles with the run going on within 4 tiles, what it carries). `upstream: true` goes the other way: from a
  machine, lab, thruster, hub or belt tile back along what feeds it, naming per ingredient the first place it stops or
  goes elsewhere (a filter, a circuit condition, an inserter taking it onto another belt, a jammed mixed lane, a
  splitter filter, where another item joins); `item` picks one. `item` alone follows every route from its makers to the
  labs (for an ore, from the drills mining it). `throughput: true` on a belt tile reads the line through it (every belt
  feeding it back, on to its end): per lane the mining drills dropping onto it (how many, working, on what) and what
  they put on at full speed against the slowest belt's lane capacity, and what the last 10 tiles hold (a tile near the
  end counts every drill). `circuit: true`: a machine's inserters with their conditions, and the circuit networks on
  their wires followed back through combinators. `surface` reads another surface, `platform` a platform. Out of sight
  it returns dated last-seen memory. It flags a held-item refusal. A refused argument shape names every shape it
  takes; `./fh help trace` gives a call for each mode. Example: `./fh call trace --args '{"position":{"x":-290.5,"y":-312.5},"forward":true,"audit":true}'`
- `labs {surface?, position?, radius?}`: which labs lack which packs, which inserters feeding them are idle and why,
  and the research ETA; `surface` reads that surface.
- Out of sight (no radar or character of ours sees the chunk), `inspect {area}`, `scan` and `observe` (and `./fh view`)
  add `fog`: our buildings and belts we saw there that no longer stand there (`remembered`, with `seen_s_ago` and status
  then), our ghosts there now, and ours destroyed there (`lost`, from the destroyed alerts). `./fh view` draws the
  remembered ones dim, ghosts blue, losses as red outlines. `./fh view --args '{"position":{"x":5,"y":563},"radius":26}' --out
  v.png` draws round that position (radius up to 32); `area` (up to 64x64) is drawn round its centre.
- `requester_rate {position | area, surface?}`: per requester or buffer chest (24 at most) and item: what it asks and holds, what
  the machines its inserters feed use a minute (their recipe at their crafting speed now), the stock the network's
  robots would take it from (the game's pick) and how far, the robot round trip there and back at our robot speed
  (charging not counted), the most deliveries bring a round trip (they come for what is under the request: at most
  the request) and so a minute, and the minutes of use the request covers. `surface`: a chest on that planet, by
  remote view, as inspect.
- `alerts_digest {surface?, since?, limit?}`: enemy and structure alerts in one read: one line per surface and 64-tile
  place, newest first, each incident once: the attacks there (ids, hits, attackers, what was hit), what was lost,
  enemy groups seen gathering heading there. Without `since` it gives what came after your last digest read (the
  first: the last 10 minutes) and moves your mark; `next_since` is the tick to pass as `since`. status's `alerts_new`
  counts the places with news since your mark. What wakes a wait stays its own filters (`--no-urgent`,
  `--urgent-radius N`, `--until "alert near=X,Y radius=R min_size=N"`).
- `losses {surface?, area? | position+radius?, since?, name?}`: each building of ours that died, newest first: where,
  when, the cause (`lightning` for a strike on Fulgora), whether its ghost stands now and whether robots can build it (the covering network, its idle
  robots and the item), and the items a rebuild needs (to carry, held, in the covering networks). A call checks the
  newest 100; older ones are counted by name and marked not checked (`unchecked`).
  Example: `./fh call losses --args '{"surface":"vulcanus","since":120}'`
  `losses {incident, recovery: {checked, result?, check?}}` dates your recovery check on a loss incident (the id in
  status alerts.incidents): its alert lines then say `handled by NAME, checked N ago: ...` (with a `checks` check's
  state when named); a loss after it, joining the incident or within 2 tiles of its box, reopens it, and the lines say
  what was lost and when. `recovery: false` clears it; `{incident}` alone reads its row.
- `fields: [...]` on `inspect`, `status`, `platform` and `platforms`: only those fields of the reply (a row's, or
  `"hub.cargo"` one level down); an unknown name is refused with the names there are.
- `inspect {position | positions | area | position+radius, surface? | platform?, types?, all?, compact?, page?}`:
  reads entities without reach: any entity in sight, or on your surface in a chunk our radars see, by remote view
  (`by: remote view`); out of sight and coverage, the refusal names the nearest radar coverage, and a recorded entity
  returns dated last-seen memory. `inspect {position}` with nothing there lists what stands within 3 tiles (`not_at`
  says so). `positions`: up to 8 entities in one call (`positions_limit` says 8; more is refused; `compact: true`: one line each). What it shows:
  - a machine: its `rate` (crafts and output per minute, net of what goes back in), `output_fill` (and `full`) and
    `output_stop`: where each product stops it, and whether a `full_output` is a full output or a machine short of an
    ingredient holding a few crafts' worth (the game reads it so);
  - a chest: `holds` (and `requests` with their fill); a full chest names the nearest chests with free slots, and a
    requester whose slots are all taken shows `slots_full` and `requests_blocked`; a take from a chest names what
    robots have reserved there;
  - inserters: pickup and drop tiles; a built inserter with no pickup or drop target is flagged (build replies too);
  - a built turret, artillery turret or wagon: `kills` and `damage_dealt`, its tooltip's Kills and Damage dealt, its own
    since it was placed (area rows and compact lines too; `turret_tally` watches them over a window);
  - an inserter waiting for source items: `pickup_wait` (compact: `waits:`): what its pickup holds of what it may take,
    a requester's network stock of it, robots taking from it, and whether the drop target takes it now and what it
    holds (fuel slots and burn rate at full power; the game's arms top fuel up only while it runs low);
  - a captive biter spawner not producing: `starving`: its health, the minutes it has left (it loses 1 HP a second
    while it makes nothing; at 0 a hostile biter-spawner takes its place) and why (fuel slot empty, output full);
  - fluid connection tiles (`fluid_connections[].joins` is where a pipe must go); a ghost shows its fluid ports as
    `ports` does; a heat entity its heat connections and temperature; `inspect.heating` reports freezing, demand,
    adjacent heat buffers and the heat connections there (what is frozen now across a planet: the `frozen` alert,
    `game_alerts {kind: "frozen"}`);
  - a machine, solar panel or accumulator: its maximum under `electricity`; poles and machines their
    `electric_network_id`, wired entities `circuit.wires`;
  - a roboport or logistic chest: its network (the number `stock {network}` and `reservations` take) and, for a
    roboport, its own area and robots, or that no roboport's logistic area covers the chest;
  - an agricultural tower: its `empty_cells` and why; any entity its `damage_history`;
  - a burner whose burnt-result slot is full and that burns nothing reads `burnt_result_full` (in scan, supply,
    bottleneck and the status warning too), with what fills it, whatever the game's status reads.
  `area` (or `position` with `radius`: the square round it) lists every entity of ours there (where inspect reads):
  belts, inserters, poles, chests, machines, ghosts, each with its position and direction, an inserter's pickup and
  drop, and `holds`, `requests`, `recipe`, `status_name` where it has them. It always returns `entities` (64 a page:
  `page`, `pages`, `next`) and `by_name` beside them; robots flying through are only counted (`also`). `types` or
  `name` narrows it. A belt's `holds` is its lanes (`right lane: rocket*4`; an underground's buried part as `... lane
  underground`), or `empty`. `compact: true` gives a line each (with `positions`, up to 32 in one reply): status,
  health, recipe, what it holds, and `spoil:` (each spoilable item's count and spoiled share, the first to spoil or hatch
  and when), `hatch:`, and `circuit:` (its circuit condition with each signal's value on its wires now, its logistic
  condition with what the network holds, whether it is off by them). Example: `./fh call inspect --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":20,"y":10}},"compact":true}'`
- `ports {name, position, direction?, recipe?, mirror?, platform?}`: where each fluid port of an unbuilt machine is and
  the fluid the recipe puts there. More boxes on a side than fluids: the first fluid takes the extra ones (a cryogenic
  plant on lithium: lithium-brine left and middle, ammonia right); `box` is the fluidbox inspect gives once built.
  Example: `./fh call ports --args '{"name":"electromagnetic-plant","position":{"x":0,"y":0},"direction":"north","recipe":"electrolyte"}'`
- `power {position?, radius?, area?, fragile?, by_cause?, platform?, surface?}`: per network `supply_line`: generators'
  nameplate, what the working ones can give, the stopped ones by status (dry steam engines), and `boilers` by state;
  generators with no steam, fuel or plasma in now are named, and headroom is against what can supply now, with
  low-power machines counted beside it (the science line's headroom too). `fragile: true` with `position` (and
  `radius`, default 96) lists the poles of that network whose loss alone would cut machines off from all generation,
  with how many machines and where (wires leaving the radius count as power). `by_cause: true` ranks each network's
  draw by entity name (last 5 s); when roboports draw, it adds the robots flying, charging and waiting, what the flying
  ones draw, their trip lengths and the requesters with the most on the way. `platform` reads a platform's networks;
  `power` is also an observe scope.
- `fuel_budget {surface?, boilers?}`: each fuel made and used per minute, and each group of fuel users (boilers,
  furnaces, burner drills, heating towers, `recipe plastic-bar`, ...) with what it burns per minute and the minutes its
  own fuel lasts, fewest first. `boilers: true`: each boiler group's burn against the fuel in reach and the drills
  supplying it, with the hours left, and each boiler under 5 fuel with its feeding inserters (burner fuel, no power,
  not connected; one taking from a belt: that belt line's length, its head and why it stops there, and its gaps, so a
  broken link reads apart from a shortage), the nearest chest or belt holding the fuel, and one `refuel {positions, fuel, count, from}` call
  (`from: "nearest"` for a chest, the belt's position for a belt).
- `game_alerts {kind?, surface?, compact?}`: the game's alerts and warnings in groups, worst first, after `counts`
  (groups per kind, the most first). `kind` takes several (`["no_storage","no_power"]` or `"no_storage,no_power"`);
  `compact: true` gives `lines`, one a group (`KIND SURFACE: line`), in place of the groups. `claim: 7` (a board
  claim id) or `mine: true` (your open claims): only the groups whose centre lies in it, compact; each such reply
  gives a `cursor`, and `since: CURSOR` (with `mine`, `claim` or `cursor: true`) lists only the groups not in that
  reply, with `new` and `gone_since`. `kind: "no_power"` groups
  connected machines without power by electric network, isolated drill networks included; `kind: "belt_cut"` names
  observed gaps in belts that carried items, and a rebuilt gap clears; a depleted-drill alert includes one remembered
  placement on the same resource (`drill_sites` lists more). `kind: "output_full"`: mining drills waiting for space in a
  chest they drop into (each drill, what it mines, the chest's slots used and what fills it); a backed-up belt is not
  said. `kind: "speaker"`: programmable speakers alerting now (message, icon, since when, who hears it: who built it
  and agents on its surface; the team block tells each once while it is up). `kind: "off_by_condition"`: machines off by their own
  circuit or logistic condition, each with the condition and what its signal reads now (`bioflux > 200 (bioflux 150
  now)`); one whose unmet conditions are all on what its recipe makes (a stock cap) is not listed. A new group is one
  team alert line to its builders and claim owners. `captive_starving`: captive spawners not producing, with the same
  facts as inspect's `starving`, to their builder and their feeders' builders; under 2 minutes left it is
  `captive_urgent`, and `captive_died` names the hostile spawner standing in its place; both show in the team block's
  urgent part and wake a sleep.
- `belt_flow {position, seconds?, platform?}`: the belt line through position (64 tiles back and on, undergrounds
  followed), cut into sections at each merge (a side-load, a splitter), sampled for `seconds` (2..30, default 10) by
  item at each section's last tile and each belt merging in: per lane items a minute that left the tile, by name, and
  `stopped` (`full` with 4 or more on the tile) for a lane whose items did not move; `merges` gives the line before
  each merge and each belt merging in against the line after it; `lane_mix`: each side-load, from which side of the
  line and onto which lane (both its lanes go onto that one), or a splitter or end-on join lane to lane, with what
  each lane carries after it; `limit`: a side-load stopped full while the line after it runs at its cap (the line's
  own items go first), the end backed up (one or both lanes stopped full), or a lane at its cap. The call returns when the sampling ends;
  `belt_flow {}` reads the last result. Example: `./fh call belt_flow --args '{"position":{"x":8.5,"y":20.5},"platform":"Kestrel II"}'`
- `belt_gaps {from, to, via?, surface?}` or `{line}`: remembered belt gaps and ghosts along the line, with observation
  ticks; unrecorded tiles are unknown. A leg that is not straight follows the remembered belt round its corners
  (`followed`). A missing tile in sight names what stands on it (`blocked_by`, `line`). `line: {x,y}` (one belt of a
  line) follows the whole line both ways, in chunks our force sees now, up to 4096 tiles each way: at each end a belt of
  ours facing the same way within 16 tiles on is the line going on, the tiles between a gap, each named empty or with
  what stands on it (`gaps`); `head` and `end` say where and why it stops. A stretch standing only as ghosts carries
  nothing: `ghost_breaks` (and `ghost_line`) give each with its tiles, the items that build it and whether a roboport's
  construction area covers it (the network's count of each item, its idle construction robots).
  Example: `./fh call belt_gaps --args '{"from":{"x":10,"y":5},"to":{"x":40,"y":5}}'`
- `uptime {positions, seconds?}`: up to 64 crafting machines or labs (or `area` {left_top, right_bottom} with an optional
  `recipe`) watched for seconds (10..3600, default 600), a status sample a second, in the background; `uptime {}` reads it
  so far or done: each machine's crafts finished and crafts a minute against its full speed, status shares, the
  ingredients short at the samples that read short (at the recipe's quality), outputs by quality from its output slot,
  totals by recipe (`groups`), `left_out`; rows above 16 machines are left out (`lines` has each). `items` (up to 8, a
  name for every quality or {name, quality}): the surface's production statistics by quality over the watch.
- `pipe_gaps {from, to, via?}` or `{line}`: a pipe line read live: its fluid segments (fluid, amount, extent) and the cuts
  where neighbours do not join or the line stops, each side's fluid named. `scan` rows of our pipes, pipe-to-grounds,
  tanks and pumps give `fluid` (the segment's). `line: {x,y}` (a pipe, pipe-to-ground, tank or pump of ours): the
  network through it, followed through fluid neighbours (pumps too) in chunks our force sees now, up to 1024 entities:
  each fluid segment by the engine's id with its fluid, amount over capacity and box, `empty` (with the fluid it is
  locked to), and the machines it joins with each box's fluid. inspect's rows and compact lines give an entity's
  fluid boxes (`fluid`). Example: `./fh call pipe_gaps --args '{"from":{"x":10,"y":5},"to":{"x":10,"y":40}}'`
- `danger {position?, radius?, surface?}`: a destination before a trip (no position: where you stand): worms and
  spawners on the map round it with their reach, enemy units in sight or radar coverage by name, and those more than
  24 tiles from every spawner in packs (`packs`: count, names, where, how far), apart from those by their nests;
  attacks, losses, groups and deaths there; the nests the straight line from you passes; your health, armor and
  shield; `eggs`: each egg site within the radius that hatches (count, holder, the first hatch time), with the turrets
  of ours in range of it (ready: ammunition, power or fluid; in range without). The egg alerts name the same turrets.
  `quiet_s: 60`: whether the straight way from you to it (24 tiles either side) has had an attack on our structures in
  the last 60 s, and the enemy units seen there now (`quiet: true` when neither). `build`, `rearm` and `transfer` take
  `retry_when_clear: true`: refused for passing enemies (an area under attack), they wait until no unit is within 48
  tiles there, then run again.
  Example: `./fh call danger --args '{"position":{"x":-190,"y":-31}}'`
- `drill_sites {position | area, resource?, drill?, direction?, radius?, limit?, surface?}`: for one depleted drill of
  ours, the nearest visible placements on the same resource, with mining-area amounts and placement checks; `resource`
  gives the name when no earlier mining target was recorded. Any other position, an `area` (up to 48x48: round its
  centre) or `drill` given: the spots for that drill (default electric-mining-drill, `direction` default north) on
  `resource`, else the resource most found there (`any_spot`; `limit` up to 16). Spots where a drill or drill ghost
  already stands are left out and named (`occupied_by`); spots the placement check refuses name what stands there
  (`blocked_by`). Sites are alternatives, not one layout. Example: `./fh call drill_sites --args '{"position":{"x":120.5,"y":-44.5}}'`
- `robot_losses {surface?, minutes?, cancel?, near?}`: our construction and logistic robots killed by enemies in the last
  `minutes` (default 30), by killer: how many, the jobs that sent them (order and target, where), and how many of those
  jobs stand; a killer with a death in the last 5 min is a team alert (`robots_lost`). `cancel: true, near: {x,y}` (a
  killer's position) cancels those jobs as by hand: ghosts, tile ghosts and item request proxies removed,
  deconstruction and upgrade marks cancelled; repairs and deliveries named, not cancelled; a job gone by then (built,
  removed or done) is skipped and named in `ended`.
  Example: `./fh call robot_losses --args '{"cancel":true,"near":{"x":200,"y":40}}'`
- `ingredient_gap {position | positions | area, all?, skip?}`: per crafting machine (16 a call), each ingredient of its
  next craft: needed, held in its input, how many of those spoil within 5 min, usable, short; for a short item the
  places within 64 tiles of the machine that can spare it without going under their own request (a requester or buffer
  only over its request), with how many; donors for the first 8 short items a call (`donors_skipped`); the ground as
  the ground watch last binned it. `area` (up to 128x128) lists the machines short of something (`all: true`: every
  one, those short of nothing as a line); `more` says how many are there, `skip` reads on. `positions` past 16 come
  back in `left`. Example: `./fh call ingredient_gap --args '{"area":{"left_top":{"x":-40,"y":10},"right_bottom":{"x":0,"y":40}}}'`
- `ores {resource?, surface?, min_amount?, limit?, position?, patch?, forecast?}`: `forecast: true` with `patch`: our
  drills' depletion there: each working drill's share of the ore under it (a tile under several shared) at what it
  takes a minute (speed with bonus, mining time, drain), the minutes until half and all of the working ones stop
  (stopped drills counted apart), and the 3
  nearest other patches of the ore (size, a demolisher territory one lies in); half stopping within 30 minutes is
  also a team alert (`mine_depleting`) to their builders. Otherwise the patches on the charted map (one resource, or
  every one), nearest first: amount left (oil: yield), distance from you and from our nearest building, enemy spawners
  and worms within 50 tiles, and how many of our drills are on it. `patch: {x,y}`: only the patch with ore at or within
  8 tiles of it, with `drill_list`: every drill of ours on it, one line each (position, name, status, the ore under its
  mining area), stopped ones first, then the least ore; no scan radius; up to 200 lines.
  Example: `./fh call ores --args '{"resource":"copper-ore","patch":{"x":40,"y":210}}'`
- `stock {item?, items?, network?, surface?, position?, radius?, places?, holders?, limit?, page?, unrequested?}`:
  `quality`: places and reads round a position count that quality; a planet's whole count is of normal quality only
  (with another quality, `surface` alone is refused and the default total is the 128 tiles round you).
  `unrequested: true`: requester and buffer chests in our logistic networks on the surface holding items they do not
  request (`item` for one), the most first, each with what it asks and whether trash unrequested sends them to storage
  (off: they stay there); `items` sums them per item; 512 requester points a call (`page: 2` reads the next, `next`
  says so). `items: [...]`
  (1..32) gives one row each (item, total, line) from the same read with the other arguments. Where an item is, landed
  cargo pods (of any force: kind `pod`) and stacks on the ground in sight (kind `ground`, `on_ground`, not in the total)
  among the places with their positions. With
  `item` and no radius: the whole surface's total (named or yours; a platform is read whole) and the places within 128
  tiles; `radius` (up to 1024) reads that circle only; `covered` says what was read, `as_of` whether a total is live or
  reused (and its age). `places: "all"`: every place on the surface holding it, nearest first, `limit` a page (`page`,
  `next`). `holders: ["provider", "storage"]`: only those kinds of place; each place says its `kind` and what robots
  have `reserved` there, and `reserved_for` where those robots deliver it (`5 to requester-chest (97.5,41.5)`, the 3
  largest). `by_holder` splits the places read: provider and storage chests (robots can take it), requester and buffer
  chests (held for their requests), plain chests, machine outputs, elsewhere; the summary says so when logistic chests
  hold it. With `surface`, `by_network`: each logistic network's hold in providers, storage and other
  holders, and `on_ground`: stacks lying on the ground in chunks our force sees now. A spoilable item adds
  `spoils_within_2_min` beside the total and per place. `network: 96` (the number `networks` and an `inspect` of a
  roboport give): what a logistic network holds, its robots, and `roboports`: the robots each roboport holds, most
  first. Example: `./fh call stock --args '{"item":"iron-plate","places":"all","limit":16}'`
- `reservations {network, item?, surface?}` (read only): what robots have reserved to pick up at each provider and
  storage chest, each requester short or with deliveries on the way (its request, what it holds, what is coming, no
  room when every slot is taken), the robots' orders by item and target, and `flags` (reservations while robots are
  idle, orders to a chest with no room for the item). Example: `./fh call reservations --args '{"network":96,"item":"iron-plate"}'`
- `logistics_audit {network? | position?, surface?, limit?, from?, storage?, backlog?, charging?}` (read only; default: the network where you stand):
  `charging: true`: the network's roboports with the most robots waiting to charge, then charging, each as its own
  GUI shows it (`limit` 1..20, default 5): position, waiting, charging, its charging slots, energy; with the network's
  totals and how many roboports have a queue. The status `robots` line gives a network's total over all its roboports
  with the position of one of them, then the 5 roboports of the planet with the most.
  `backlog: true`: why requests wait: the oldest unfilled first (chest, item, short, how long it has been short, the
  provider the game picks with what robots reserve there) and `held_by`, the first that holds each now (on the way, no
  room, none in the network, no provider, all reserved, no idle robot with what the busy ones do, robots queued with
  every charging slot taken, or not sent yet); `robots`: idle, on orders, holding cargo with no order, charging,
  queued to charge, charging slots. `storage: true` reads its storage room instead (the `no_storage` alert): storage chests, free slots, full and
  filtered ones, robots holding cargo with no order to put it anywhere and their items, each with whether a storage
  chest can take it now. Otherwise:
  every requester of that logistic network, worst first: `full_unrequested` (every slot taken while a short item has
  no room, by items it does not request, spoilage named), `full` (the same by its own items), `spoiled` (spoilage it
  does not request, 4 or fewer slots left), `waiting` (deliveries on the way 5+ min while under its count), `not_sent`
  (short with the item free in providers or storage, nothing on the way), `shortage` (none free in the network). Each
  item with what it holds, what is on the way and for how long, the network's free count and the provider robots would
  take it from (position, distance, count). The summary counts each kind and names the chests holding spoilage with
  room left. `limit`: rows (default 12, up to 48); 256 requesters a call, `next_from` gives `from` for the rest.
  `far` (default 200): each ask short or with a delivery on the way whose pickup the network would pick now lies
  farther off, with that chest and its distance. Characters' requests are left out.
- `construction_robots {network? | position?, sources?, sources_from?, surface?}`: the construction robots of the network you stand in
  (or `network`): each in the air with its charge, cargo, orders and what holds it up (no storage for what it holds,
  target out of the area, waiting to charge, no charge, its target ghost standing over a live entity of ours not marked
  for upgrade or deconstruction); `ghosts_waiting`: each ghost in a held-up robot's queue; `ghosts_blocked`: the ghosts
  in the orders of robots in the air that stand over such an entity, counted per ghost and entity name with the `upgrade` (or
  `deconstruct`) call that marks them.
  `sources: true`: per group of waiting ghosts and item requests, first how many are in transit (construction robots
  with an order on one holding its item, the nearest how far off), then for the rest the chest the network's robots
  would take the item from (the game's pickup choice; what it holds, the network's total) and whether the straight line
  from it passes within a worm's or spawner's reach the map shows. A call reads up to 4 squares of 128 tiles of the
  construction area (fewer once 60 ghosts are read); the first line names `sources_from` for the next squares.
- `shortages {surface?}`: machines stopped short of an ingredient (by recipe and ingredient), no fuel, low or no power,
  labs waiting for packs, and what requester chests lack, in lines.
- `damage_log {position?, radius?, surface?}`: what hit our entities there (alive or destroyed), for hits our force saw:
  what dealt each hit (a fire, projectile or stream) and the game's cause with its position, facing and distance against
  its range, both from the game's event. A fire's cause is the turret whose stream lit the first fire; a hit past its
  range is a fire that spread. Empty ground says if its chunk was never charted, is charted and out of sight
  (with our last sight of it), or is in sight. Example: `./fh call damage_log --args '{"position":{"x":67,"y":-170},"radius":16}'`
- `dependency {item, surface?}`: the item and each ingredient of its recipe there: made and used a minute, stock and
  minutes left, pods coming down and platforms carrying it to a stop there, a rocket's load by weight; missing, short
  or ok each; feasible, sustained and the first unsatisfied. Example: `./fh call dependency --args '{"item":"rocket-fuel","surface":"nauvis"}'`
- The operator's factory digest arrives by `tell` at the deadline minus 2 hours: what changed since the last digest
  (blockers per planet, lessons whose check is not met, items blocked, requests nobody owns), each to the owner of
  the claim or item it concerns, the rest to the team. On operator request the full census: remembered machine and
  fuel counts per planet and sampled belt ends, with observation ages; missing data is unknown.
- Shift and factory-digest `research_use` lines compare researched gear with the gear worn, fitted and carried now,
  show building tiers per planet from the dated census, and researched vehicles against force-wide built counts.
- A full `status` gives `robots`: per planet or platform, all its logistic networks' robots by kind (idle, working,
  charging, waiting to charge) and the networks with the most waiting. Its fuel and power warnings name the surface and
  the first places (`fuel on nauvis: boiler 4/42 no_fuel at (-75,21.5) ...`). `alerts.out_of_sight`: per planet, our
  drills, machines and turrets in chunks our force does not see now (no radar or character of ours sees them),
  by 64-tile area with the nearest radar and its state, and the radars not working. `alerts.outside_coverage`: per
  planet, what lies outside every roboport's construction area (buildings and ghosts, by 64-tile area and name) and the
  requester and buffer chests outside every logistic area. On Fulgora also our buildings outside every lightning
  attractor's protection, by 64-tile area: a point within 10 tiles of each lies outside every attractor's reach (10 +
  range_elongation x (1 + 0.3 x quality level): rod 25, collector 35, ruin attractor 30 at normal), and a strike there
  hits what stands within 10 tiles of it (walls and rails never). And our buildings lightning killed: in the last hour,
  and the last one. The team block carries both once an hour.
- `scan {fields: "inventory"}` on belts gives their items per lane (`L: ... | R: ...`), on a platform too.
- `scan {type: "transport-belt"}` (any belt type) adds `belt_items`: what all the belts found carry by item, before
  `limit` cuts the rows (up to 1024 belts). `item: "rocket"` adds `belt_item`: how many on how many belts, and each
  belt holding it (`positions`, 64; `line` names the first 12). Example:
  `./fh call scan --args '{"platform":"Kestrel III","area":{"left_top":{"x":-64,"y":-64},"right_bottom":{"x":64,"y":64}},"type":"transport-belt","item":"rocket"}'`
