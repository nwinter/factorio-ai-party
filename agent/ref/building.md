- `build {item, position, direction?, recipe?, builds?, all?, check_inserters?, entity?, dry_run?}`: places from your
  inventory; `builds` is a batch of entries (up to 256; more than 64 are worked in batches of 64 in the same call, one
  reply, `batches` says how many). A direction is a compass name or the number `inspect` prints (0, 4, 8,
  12); `recipe` sets an assembler's recipe; a machine the game placed facing north without its recipe's fluid ports
  is turned the way asked once the recipe is set (`direction_note`; place_ghosts: `directions_turned`). `"all": true` builds every entry it can and lists the rest in `failed` (a batch of mining drills does so unless `all: false`, and `left` names each spot left with what blocked it)
  with why; a batch that fails part way says on the `warning:` line when what it placed closes you in. A railgun
  entry (build, place_ghosts, their dry runs) adds `line_of_fire`: the entities of ours its shots would cross from
  there by the prototypes' arc and line (ghosts apart: hit once built). Errors name the
  blocker (tree, rock, the character, water); trees and rocks go with `place_ghosts` + `construct`, or `mine`.
  Standing on the footprint, the character steps aside first: the reply gives `not_yet`, `still_to_build` and
  `built_so_far` (nothing of that entry built yet); `--wait` or status `last.built` counts it, and a retry with the
  item gone names the entity already standing there. A 1x1 entity (chest, inserter, pole, pipe, wall) given
  whole-number coordinates goes at the centre of that tile (x.5, y.5), as `place_ghosts` places it (`snapped` says
  so); 2x2 entities (gun turrets) stand on whole numbers. It works while the clock is paused. It reports `materials`
  before acting (need, held, missing, queued, hand_craftable; its dry run too). An inserter build says what its sides
  touch: `pickup` and `drop` (`requester-chest (44.5,190.5)`, `none: the ground at (42.5,190.5)`), with `inserter`
  (its direction in words) and `io_warning`; build replies and `inspect` flag a built inserter with no pickup or drop
  target. One that drops onto a belt says `belt_mismatch` when what it puts (a drill's ore, a machine's products, a
  chest's contents) is neither on that belt nor taken by the inserters downstream (120 tiles). Entry settings (a
  single `build`, `builds` entries, `place_ghosts` entries): `configure`, `requests`, `circuit` (the arguments of
  `configure`, `requests`, `circuit_set`, without `position`) and `wires: [{to, color, from_side, to_side}]`. A hand
  build sets each entry's as it is placed, ghosts after every entry is placed, then the wires; the reply's `settings`
  and `settings_line` say what was set or refused (a refused setting leaves the entry placed); each setting goes to the
  ghost or entity of the entry's name at its position. A dry run gives `settings_planned` and `settings_check`, each
  setting checked as the real call checks it; a refused setting, a blocked entry, a recipe the real call refuses
  (`recipes_refused`), a foundation tile the hub never builds (`tiles.unbuilt`), an entry where ours stands already
  (`exists`) or an inserter with no target reads
  `dry_run_ok: false` and `verdict: fails: ...` naming the first of each, and `fh` exits 1. Settings are read as their own call reads them (`settings_corrected`: a
  requests `set` map, ...). An entry's `settings: {...}` is read as those keys (`settings_alias`); a setting key such as
  `modules` at the entry's top level is refused with the shape. `"check_inserters": true` checks every planned
  inserter's pickup, drop, power and filters first and places nothing if one would not work; each row's `line` (and
  the refusal) names both sides: `picks from iron-chest (3.5,5.5), drops into stone-furnace (3,2.5)`. Fast replace
  over a chest of the same group keeps its contents in the new chest; what it cannot hold comes to you
  (`replaced.contents`), and with no room for that nothing moves; any fast replace keeps filters, wires, circuit
  settings, a chest's limit and requests (`replaced.kept`, `not_kept`). Fast replace of one end of an underground pair
  with another tier replaces its other end too when that is ours, in build reach and you hold the item for it
  (`consumed: 2`, `replaced.pair`; a later entry for that end says `already`); else it is refused naming the other end
  and a spot within reach of both. Rails: `{item: "rail", entity: "straight-rail"
  | "curved-rail-a" | "curved-rail-b" | "half-diagonal-rail"}`; stops, locomotives and wagons build as any entity.
  `{item: "rail-ramp", position, direction}` builds a ramp from one held ramp; the centre snaps to the ramp grid, with
  the same collision and reach checks.
  Example: `./fh call build --args '{"item":"transport-belt","direction":"east","builds":[{"position":{"x":10.5,"y":6.5}},{"position":{"x":11.5,"y":6.5}}]}'`
- `place_ghosts {entities, ammo?, surface? | platform?, check_inserters?, clear_obstacles?, dry_run?}`: places ghosts, no items needed
  (`clear_obstacles: true`, on `build` too: trees and rocks in the footprints marked, those in reach mined by hand,
  the call run again once they are gone; dry runs list them in `trees_rocks`)
  (a requester or buffer chest, or a machine on electricity, is watched: once robots build it in no logistic network,
  or with no pole or no power, your team block says so at once);
  entries `{name, position, direction?, recipe?, quality?}` with entry settings as `build`'s; `quality` is the entity's
  (a quality our force has unlocked; robots bring that quality's item), a recipe's quality is `configure {recipe, quality}`.
  Where the same entity stands at another quality (built or a ghost) the entry is refused naming `upgrade {position, quality}`. An entry already standing as asked
  (the same ghost or the built entity) is counted apart: `already_placed`, `already`; only real refusals are `failed`.
  A real call says on the `warning:` line when what it placed closes you in. Turret ghosts request ammo, so the robots
  that build them bring it (`ammo`: a name, `{name, count}` or false; default 10 of what the logistic network there
  holds most of; `ammo_note` says what the default added); so do the ghosts of turrets that died. `configure
  {position, ammo}` on a turret ghost changes its ammo request in place (false clears it; its module requests stay).
  `surface: "vulcanus"` places by remote view. On a platform an entity with tile rules (a thruster, an asteroid
  collector) goes over foundation tile ghosts as over foundation; over empty space where a rule wants ground the
  foundation tile ghosts under it are placed first (`tiles_laid`), as the game's forced placement lays them. A rule's
  tiles in chunks the platform has not generated yet (a thruster keeps 90 tiles behind it empty) are refused until they
  are; the reply asks for them: call again in a few seconds.
  Example: `./fh call place_ghosts --args '{"entities":[{"name":"assembling-machine-2","position":{"x":20.5,"y":8.5},"recipe":"iron-gear-wheel"}],"dry_run":true}'`
- `belt_upgrade {position, to?, tiles?, dry_run?}`: the belt line through position traced both ways (up to `tiles`,
  default 256; undergrounds to their pair), each tile replaced by hand with the faster one at its own position and
  direction (an underground's input or output kept, a splitter on its centre), by `build` from your inventory with
  `all`. `to`: fast-, express- or turbo-transport-belt (that tier's undergrounds and splitters with it); default each
  one's next upgrade. `rows` and `needs` say what goes where; `left`: tiles already at the target. A replaced belt's
  items go to your inventory. Example: `./fh call belt_upgrade --args '{"position":{"x":12.5,"y":-40.5},"to":"fast-transport-belt","dry_run":true}'`
- `construct {area?, avoid_enemies?, unsafe_goal?, dry_run?}`: builds ghosts from your inventory and mines what is
  marked for deconstruction, tiles too, walking between them. Its walks go round worms and spawners (not areas under
  attack unless `avoid_enemies: true`) and stand no nearer a worm or spawner than its reach + the margin; a ghost
  inside an enemy's reach is left out (`left_out`; `unsafe_goal: true` builds it). It reports `materials` before
  acting (need, held, missing, queued, hand_craftable, over every ghost in the area) and a `line`: the ghosts it builds
  by name, those you hold too few for (skipped unless crafted in time; the rest are built) and those left out. Its
  result's `line`: built N of the ghosts it took up, skipped with the count short, left out, failed. `dry_run: true`
  checks the materials without acting.
  Example: `./fh call construct --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":40,"y":30}}}' --wait`
- `rebuild {area | position+radius, all?, from?, dry_run?}`: one queued plan for the ghosts there robots will not build:
  takes the items you do not carry (from `from`, else chests of ours within 96 tiles of you), hand-crafts what none
  holds, then `construct {area, outside_robots: true}` per box of up to 256x256. `all: true`: every ghost.
  Example: `./fh call rebuild --args '{"area":[[64,-256],[256,-192]],"dry_run":true}'`
- `ghosts {position?, radius?, area?, name?, surface?}`: each ghost nearest first, the item that places it, and whether
  robots can build it (in transit: a robot with an order on it carries the item, how far off; no construction area
  covers it; its network holds none and no robot carries one; no idle robot); `page` for more. On a space platform the
  hub builds from its inventory, with no roboport: each ghost says what holds it (no foundation under it, a foundation
  ghost built first, foundation where its tile rules need empty space, the hub's count of its item and whether a hub
  request asks for it). The floor is the game's: an asteroid collector needs foundation under its two rear rows and
  empty space under its front row (`over_empty_space`), a thruster empty space behind it; a ghost the game's placement
  check takes is not named as held by its floor; place_ghosts' robot preview
  says the same, and construction_robots there names this read. `contested`: more of
  our ghosts in its network want its item than the network holds (16 or fewer): each, its claim and distance.
  `robot`: the robot in the air with an order on it (its place in that robot's queue, its charge, cargo and what holds
  it up), or `no robot has an order on it`; the summary adds how many of the network's robots in the air are held up
  and by what. A ghost over a live entity of ours whose collision meets it, not marked for upgrade or deconstruction,
  reads `blocked: our live small-electric-pole (x,y) stands on its spot, not marked for upgrade (robots do not build it
  until it is)` (the nearest 512 entity ghosts checked); `blocked` counts them per ghost and entity name with the call
  that marks them (`upgrade {area, from, to}` for one of its kind, same fast-replace group and size, else
  `deconstruct {area, entity_names}`).
- Who placed it: `inspect` gives `placed` for an entity or ghost: who placed it or its ghost, when, and through which
  request (`belt_route, a call`; `place_ghosts, queue step 12 "walls"`; `paste, standing order "rebuild"`), from the
  harness's record of the last 8192 ghost placements and hand builds; else `unknown` and why. `last_user` is the game's
  Last user (a player's); a bot's ghost and what robots build from it have none. Area rows, compact lines and `ghosts`
  rows say it in short.
- `deconstruct {area, tiles?, cancel?, dry_run?}`: marks for deconstruction. `tiles: ["landfill"]` marks built landfill
  and removes our landfill tile ghosts there (`tile_ghosts_removed`); `cancel: true` unmarks. It and its dry run count
  robots in flight apart (`flying_robots`: the game does not mark them) and read `heat_loss`: heat-network parts cut
  off from every reactor and heating tower, and on Aquilo freezable pipes and machines that lose their last heater at
  30 C or more. The dry run's `robot_dispatch`: the robots' trips (one an entity, one a robot load of what it holds),
  how many at once, from which roboports, the longest and mean trip, trips over 200 tiles, and legs passing within
  reach of a worm or spawner the map shows. `contested` (dry run and live): an item the marked entities free that more
  of our ghosts in that network want than it holds (16 or fewer), each ghost with its claim and distance.
  Example: `./fh call deconstruct --args '{"area":{"left_top":{"x":180,"y":50},"right_bottom":{"x":200,"y":70}},"tiles":["landfill"]}'`
- `upgrade {area | position, to, from?, quality?}` or `{area, map: {"turbo-transport-belt": "transport-belt"}}`: the upgrade
  planner; a ghost changes in place (wires and settings kept), a built one is marked for robots (their replacement
  keeps recipe, modules and circuit settings). `quality` is the target quality (unlocked ones); with it `to` may be
  left out (the same entity at that quality); without it each keeps its own quality.
  Example: `./fh call upgrade --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":30,"y":30}},"map":{"transport-belt":"fast-transport-belt"}}'`
- `paste {position, name?, direction?, mode?, preserve_existing_settings_and_wires?, dry_run?}`: pastes the clipboard,
  or a library entry by `name`, as ghosts; turret ghosts request ammo as `place_ghosts`'s do.
  `preserve_existing_settings_and_wires: true` adds only what is missing. A paste leaves the requests of a hub or
  requester chest it lands on, a hub's construction requests too (`requests_kept`).
  Example: `./fh call paste --args '{"name":"smelter-row","position":{"x":40,"y":12},"dry_run":true}'`
- `placements {name, near?, radius?, limit?, separate?, powered?, surface?, resource?, fluids?, recipe?}`: up to 10 (`limit` up to 50) positions
  where it fits now, nearest first, by the game's build check, without building (`blocked`: positions something stands
  in). `"separate": true` lists spots that do not overlap each other, `"powered": true` only spots in one of our poles'
  supply areas; without them `overlapping` and `no_supply` count such spots, and count 0 names what is in the way
  (`in_the_way`). `fluids: ["light-oil", "water"]` (with `recipe`: its ports' fluids) keeps only spots whose ports touch
  built segments of each and join none of another fluid (`ports` and `line` per spot; `mixes`, `rejected`,
  `fluids_line`). With no spot it adds `fewest_to_clear`: up to 3 spots (within 12 tiles) whose blockers are all ours
  and minable, or trees and rocks, with how many to mine first and which (`(47,187): mine 2 first (accumulator 2):
  ...`). `surface` reads another planet; each spot gives `network`. A cargo bay keeps to its 2-tile grid: the position
  offered is where it lands. A refused build of an offshore pump, or of anything onto water, lists the nearest valid
  placements. `resource` (a name, or true) with a drill or pumpjack: its spots on that resource within `radius` (1..32,
  default 16): a pumpjack every well, free with the directions it fits, taken by our drill, or blocked; a drill each
  tile centre whose mining area holds the ore, the most ore first, the free ones none overlapping, a spot with an
  entity of ours in its footprint taken (`ours already`, though the game's placement check passes there). Each blocked spot
  says why (the build refusal's text: what stands there, a tile and the foundation it needs, a cliff), and
  `blocked_by` counts them by kind.
  Example: `./fh call placements --args '{"name":"accumulator","near":{"x":-60,"y":95},"radius":16}'`
  Example: `./fh call placements --args '{"name":"pumpjack","resource":"crude-oil","near":{"x":-7,"y":100}}'`
- `nearest_water {position?, radius?}`: the nearest pumpable tile in charted ground (up to 256 tiles) with
  offshore-pump spots there.
- `conflicts {name, position, direction?}` (a read): what building there takes away: everything in the way, the fluid
  segments that split and the poles cut off; and the footprint tiles it cannot stand on (`tiles`, `tiles_line`: water,
  oil ocean, lava, space, per tile kind with the tile item that makes them buildable, and when that item is not
  researched).
  Example: `./fh call conflicts --args '{"name":"pumpjack","position":{"x":-4.5,"y":101.5}}'`
- `build_path {points}`: lays belts along the points and mines the trees and rocks in its way by hand as it goes
  (`last.cleared`, `cleared_names`).
  Example: `./fh call build_path --args '{"points":[{"x":0.5,"y":0.5},{"x":20.5,"y":0.5}]}' --wait`
- `grid {position?, radius?}`: one character per tile; `,` is `walkable water` (shallow water, wetland, Fulgora's oil
  ocean, deep too), `~` water a character cannot cross; `map` tells them apart the same way.
  `map`, `grid` and `observe` take `surface` (another planet by remote view, with `position`, grid `area` too) within
  what our force has charted there; `observe {tile_runs: true, tile_names?}` gives charted tiles as runs along x.
- `pole_route {from, to, surface?}`: from a powered pole, lays pole ghosts along a line and reports how many poles you are
  `short`. `surface` (pole_route and belt_route, dry runs too): on another planet by remote view, in charted chunks;
  that planet's construction robots build them. On water and Gleba wetland it shifts a pole up to 2 tiles to dry ground, else lays a landfill tile ghost
  under it (`tiles_under`, `tiles_note`).
  Example: `./fh call pole_route --args '{"from":{"x":10.5,"y":10.5},"to":{"x":80.5,"y":10.5}}'`
- `belt_route {from, to, via?, return?, landfill?, cliffs?, avoid_nests?, avoid_enemies?, replan?, surface?}`: lays a belt line as ghosts
  (legs up to 1000 tiles), over trees and wild plants it marks, water only with `"landfill": true`; `return` adds the
  line back beside it, crossing under it where its side is blocked. It goes round cliffs (an underground passes under
  one; `cliffs: true` passes over and marks them) and names what its ghosts mark for mining (`to_mine`: trees, rocks,
  cliffs with positions). A `from` on an existing chain follows it to its open end, up to 4096 tiles
  (`existing_count`), and names blocked connection tiles. A re-run of one of your last 4 lines (same from, via, to,
  belt, return) keeps what stands and places the missing tiles as ghosts (`repair`, `kept`, `differs`: standing belts
  facing otherwise); `replan: true` plans a new line. A via point on the from chain is passed (`via_passed`); one on
  another standing line of ours makes the route feed that line's head and go on from its open end (`joined`). A line through a worm's range or a spawner's 40 tiles is
  refused (dry run: `nests_on_route`); `avoid_nests: true` routes round them, `false` lays it anyway. `avoid_enemies:
  N` keeps belts, underground spans and returns outside charted enemy reach plus N tiles (0..32; true=8;
  omitted/false disables); endpoints inside are refused. Belts, undergrounds and splitters say where items go in
  `belt` (inspect, observe rows, build replies; `last_belt` for a batch): `moves items south to (-22.5,-28.5); fed
  from (-22.5,-30.5)`; at a line's end it names what stands on the tile it stops at: `(no belt takes them there:
  they stop at its end; medium-electric-pole (353.5,95.5) stands there)`.
  On a platform (`platform`): foundation only, no underground under empty space; `eject: true` (or an inserter name) ends
  it where that inserter, near `to`, picks from the last belt and drops off the hull (`eject` says where).
  Example: `./fh call belt_route --args '{"from":{"x":0,"y":0},"to":{"x":600,"y":40},"return":true}'`
- `rail_route {from, to, signals?}`: lays 2.0 rails (16 headings; straight, half-diagonal and two curve pieces, a curve
  3 rails) around water, cliffs and buildings as ghosts and builds those in reach (`"signals": 30` adds one-way
  signals). Rail ramp dry runs list every physical collision in `collisions`, rotated cliffs and deconstruction marks
  still present included; a failed `place_ghosts` names the same footprint list.
  `"level": "elevated"`: a ramp up at `from`, elevated rails over water, oil ocean and buildings, a ramp down at `to`,
  rail supports on joints between; `unsupported` names spans with no support spot and why; `research` says what is researched.
  A long one is laid over several calls: each reply's `capped.next_call` holds the arguments of the next.
  Example: `./fh call rail_route --args '{"from":{"x":0,"y":0},"to":{"x":0,"y":-200}}'`
- `train_stop {position, name}`: puts a stop on the side of a straight rail that serves trains heading one way.
  Example: `./fh call train_stop --args '{"position":{"x":40,"y":-20},"name":"iron-pickup"}'`
- `train {position | train_id, station?, limit?, schedule?, automatic?, path_to?}` or `{stops: true, surface?}` or
  `{all: true, surface?}` (every train of ours there in one read: id, state, the schedule's current stop, front,
  speed, cargo and fluids summed; at most 100): on a stop, its
  `station` and `limit`; on a locomotive, its `schedule` and `automatic`; `train {position}` reads a train's state and
  why it waits. A train in `no_path` reads `rail_break` (`path_to: "STOP"` for any stop): the rails followed from the
  train, whole, reaching the stop only facing away, or broken: where the rails from each side end, the gap, rail
  ghosts. `stops: true` lists every train stop of ours on a surface: name, position, rail, limit and the trains
  heading there (`train 15 heading there`). `train_id: 15` reads that train wherever it is, moving or not; a train
  read gives its `id` and `front` (name, position, surface). `wagons` (a train read; inspect of a cargo wagon:
  `wagon_slots`): each cargo wagon's slots used per item with the count, free slots, slot filters and the red-X limit,
  and `full: nothing else loads into it` when no slot is free. `wagon_slots: {wagon?, filters?, bar?}` sets a cargo
  wagon's slot filters and red-X bar as its GUI (in reach or by remote view): `wagon` its carriage number from the
  front (default the wagon at position), `filters: {"1": "low-density-structure", "2": {"name": ..., "quality": ...},
  "3": false}` (other slots kept), `bar` usable slots 0..40 or false; a filter on a slot holding another item is
  refused; the reply's `wagon_slots` reads back `slot_filters` and `bar`.
  Example: `./fh call train --args '{"position":{"x":40,"y":-30},"path_to":"iron-pickup"}'`
- `clear_cliffs {positions}`: throws cliff explosives you hold at those cliffs, walking into their 10-tile range
  (`use_item {"item":"cliff-explosives","position":...}` too); `last.destroyed` names the cliffs gone, `last.left` the
  rest.
  Example: `./fh call clear_cliffs --args '{"positions":[{"x":82,"y":38.5}]}' --wait`
- `heat_budget {position, add_pipes?}`: a heat network's mean temperature, heat capacity and heat above 30 C, and with
  `add_pipes` the mean after that many new cold heat pipes join.
  Example: `./fh call heat_budget --args '{"position":{"x":12.5,"y":40.5},"add_pipes":20}'`
- `outpost {position, radius | area, dry_run?}`: queues one tour for an outpost: construct its ghosts, rearm its
  turrets, wire its poles cut off from power; `dry_run: true` shows the plan and what you lack.
  Example: `./fh call outpost --args '{"position":{"x":300,"y":-120},"radius":40,"dry_run":true}'`
- `blueprint_save {name, area | positions, description?, anchor?, tiles?, surface? | platform?}`: stores what the team
  built in the team blueprint library, kept in the save across shifts. Entity ghosts are saved at their positions (tile
  ghosts with `tiles: true`), counted in `ghosts`; `surface` (a planet) or `platform` captures there from anywhere.
  Example: `./fh call blueprint_save --args '{"name":"smelter-row","area":{"left_top":{"x":30,"y":0},"right_bottom":{"x":60,"y":20}}}'`
- `blueprint_capture {area, surface? | platform?}`: captures an area into the clipboard; `surface` or `platform` as
  `blueprint_save`.
  Example: `./fh call blueprint_capture --args '{"area":{"left_top":{"x":30,"y":0},"right_bottom":{"x":60,"y":20}}}'`
- `blueprint_list {name?, limit?, from?}`: the library's entries by name, 64 a page (author, size, counts, last used,
  `size_kb` of its string); `name` gives one in full. `library_size`: entries and KB of strings of its 256 and 8 MB.
- `./fh blueprint export --args '{"name":"smelter-row"}'` writes an entry's string to `blueprints/smelter-row.txt` in
  your workspace (`--out FILE`: there), with its author, description and anchor in the reply.
  `./fh blueprint import --file blueprints/smelter-row.txt --args '{"name":"smelter-row-2","anchor":{"x":0,"y":0}}'`
  puts a string into the library under `name`, you its author (`description` and `anchor` optional; the same name
  replaces an entry as `blueprint_save` does).
- `blueprint_place {name, position, direction?, platform?, dry_run?}`: pastes a library entry, as `paste`; a platform's
  layout goes on another platform with `platform: "Swift"`.
  Example: `./fh call blueprint_place --args '{"name":"smelter-row","position":{"x":90,"y":0},"dry_run":true}'`
- `blueprint_rename {name, new_name}`: its author any time, anyone after 24 game hours unused.
  Example: `./fh call blueprint_rename --args '{"name":"smelter-row","new_name":"smelter-row-v2"}'`
- `blueprint_delete {name}`: who may, as `blueprint_rename`.
- `blueprint_retire {name, reason, replaced_by}` marks an entry retired, `replaced_by` another entry of the library;
  `{name, clear: true}` clears it. Who may, as `blueprint_rename`. Its description stays as written; `blueprint_list`,
  an export, and a paste or dry run of it say `retired by X: reason; replaced by NAME`.
  Example: `./fh call blueprint_retire --args '{"name":"smelter-row","reason":"jams","replaced_by":"smelter-row-v2"}'`
- Dry runs (`"dry_run": true` on `build`, `place_ghosts`, `paste`) place nothing and report the plan: per entity
  whether it fits or what blocks it and where, blocked entities first and all of them in `blocked` (up to 200) apart
  from those needing tiles; the tiles an entry needs (landfill, foundation, shallow oil, water, and on a platform the
  empty tiles new foundation would enclose), with the entities in its way; poles' wire reach and pole groups left
  unconnected; standing spots that reach every placement; what each planned inserter picks up from and drops into
  (`missing: no drop target`); `connections`: each planned boiler's, turbine's, reactor's, pump's or pipe's fluid and
  heat connection points and what joins each (`planned #5 pipe`, `nothing there`), a pump port's tile, and for each
  pipe-to-ground what its mouth joins and whether it pairs, with which (`inspect` of a heat entity shows its heat
  connections and temperature). `fluid_segments`: the built fluid segments each group of planned fluid boxes joins
  (segment id, fluid and amount, at which entity; `2 segments into one`); `fluid_mix`: a group that would hold two
  fluids (built segments, a planned machine's recipe fluid, the resource under a planned pumpjack, the tile under an
  offshore pump); `fluid_cuts`: a planned entry on a built fluid entity's centre and the joins it would no longer
  make (a pump keeps its input and output as two segments). `place_ghosts` and `build` refuse a plan with a
  `fluid_mix` unless `mix_fluids: true`. `robot_dispatch` (place_ghosts, paste, blueprint_place): the construction
  robots' trips to the ghosts, as the network would pick them: how many at once, from which roboports, the longest
  and mean trip, trips over 200 tiles, legs passing within reach of a worm or spawner the map shows (each with its
  read's age and whether its chunk is in sight now); ghosts whose covering network holds none of their item, and
  ghosts outside every construction area with the nearest roboport and how far outside its area. `closes_in` names the entry that fills the last gap out when the plan would close you
  in where you stand; a build reply says `closed_in` after it. `build` dry runs name off-character `pockets`, their
  area and planned boundary tiles (a bounded 24-32-tile window); `pockets_checked` says when a larger plan was not
  checked. Dry runs and build replies name logistic chests no roboport covers (`outside_logistic_coverage`) and
  inserters or belts feeding an underground entrance from the side, with the lane that gets nothing
  (`underground_side_feed`). build and place_ghosts replies also name what they put down that no pole's supply area
  covers (`no_power_coverage`; built: the nearest pole) and what lies outside every roboport's construction area
  (`outside_construction_area`). Each cliff the placement marks is listed (`cliffs_under`). A place_ghosts dry run over
  another ghost says blocked, as the call does. On a platform a planned pump's enable condition with no circuit wire is
  named (`pump_circuits`), and a ghost refused over empty space says when foundation tile ghosts under it are not
  built yet.
- Water and Gleba wetland: `place_ghosts` lays a landfill tile ghost under an entity ghost there, `pole_route` as above,
  and `construct` builds the landfill first; a build refused there names the tile. Landfill on Gleba wetland goes in
  only where no slipstack, cuttlepop, hairyclubnub or stromatolite stands (marked or not, for a tile laid by hand): a
  dry run and a failed build name them (`blocked by slipstack tree at (x,y): mine it first`); `place_ghosts` marks
  them for removal first (`tile_obstacles_marked`) and `construct` mines them before it lays the landfill. Water-cane
  and fish do not block a tile: the new tile takes them away (`removed`). Landfill goes on water and wetland only
  (`landfill cannot go on oil-ocean-deep (foundation can; not researched)`). Foundation is refused in front of an
  asteroid collector, saying so: its collection area is kept empty space.
- Nuclear: build the reactor and heat pipes; transfer or refuel with uranium-fuel-cell.
- On Vulcanus a build, ghost placement, paste or route inside a demolisher territory (as the map draws it) carries
  `demolisher_territory`, dry runs too, with the territory's state as `demolishers` gives it (its demolisher seen,
  killed at T by X, or none seen in it).
