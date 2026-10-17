- `build {item, position, direction?, recipe?, builds?, all?, check_inserters?, entity?, dry_run?}`: places from your
  inventory; `builds` is a batch of entries. A direction is a compass name or the number `inspect` prints (0, 4, 8,
  12); `recipe` sets an assembler's recipe. `"all": true` builds every entry it can and lists the rest in `failed`
  with why; a batch that fails part way says on the `warning:` line when what it placed closes you in. Errors name the
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
  setting checked as the real call checks it; a refused setting or a blocked entry reads `dry_run_ok: false` and
  `verdict: fails: ...`, and `fh` exits 1. Settings are read as their own call reads them (`settings_corrected`: a
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
- `place_ghosts {entities, ammo?, surface? | platform?, check_inserters?, dry_run?}`: places ghosts, no items needed;
  entries `{name, position, direction?, recipe?}` with entry settings as `build`'s. An entry already standing as asked
  (the same ghost or the built entity) is counted apart: `already_placed`, `already`; only real refusals are `failed`.
  A real call says on the `warning:` line when what it placed closes you in. Turret ghosts request ammo, so the robots
  that build them bring it (`ammo`: a name, `{name, count}` or false; default 10 of what the logistic network there
  holds most of); so do the ghosts of turrets that died. `surface: "vulcanus"` places by remote view.
  Example: `./fh call place_ghosts --args '{"entities":[{"name":"assembling-machine-2","position":{"x":20.5,"y":8.5},"recipe":"iron-gear-wheel"}],"dry_run":true}'`
- `construct {area?, avoid_enemies?, unsafe_goal?, dry_run?}`: builds ghosts from your inventory and mines what is
  marked for deconstruction, tiles too, walking between them. Its walks go round worms and spawners (not areas under
  attack unless `avoid_enemies: true`) and stand no nearer a worm or spawner than its reach + the margin; a ghost
  inside an enemy's reach is left out (`left_out`; `unsafe_goal: true` builds it). It reports `materials` before
  acting (need, held, missing, queued, hand_craftable); `dry_run: true` checks them without acting.
  Example: `./fh call construct --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":40,"y":30}}}' --wait`
- `ghosts {position?, radius?, area?, name?, surface?}`: each ghost nearest first, the item that places it, and whether
  robots can build it (no construction area covers it, its network holds none, no idle robot); `page` for more.
- `deconstruct {area, tiles?, cancel?, dry_run?}`: marks for deconstruction. `tiles: ["landfill"]` marks built landfill
  and removes our landfill tile ghosts there (`tile_ghosts_removed`); `cancel: true` unmarks. It and its dry run count
  robots in flight apart (`flying_robots`: the game does not mark them) and read `heat_loss`: heat-network parts cut
  off from every reactor and heating tower, and on Aquilo freezable pipes and machines that lose their last heater at
  30 C or more.
  Example: `./fh call deconstruct --args '{"area":{"left_top":{"x":180,"y":50},"right_bottom":{"x":200,"y":70}},"tiles":["landfill"]}'`
- `upgrade {area | position, to, from?}` or `{area, map: {"turbo-transport-belt": "transport-belt"}}`: the upgrade
  planner; a ghost changes in place (wires and settings kept), a built one is marked for robots.
  Example: `./fh call upgrade --args '{"area":{"left_top":{"x":0,"y":0},"right_bottom":{"x":30,"y":30}},"map":{"transport-belt":"fast-transport-belt"}}'`
- `paste {position, name?, direction?, mode?, preserve_existing_settings_and_wires?, dry_run?}`: pastes the clipboard,
  or a library entry by `name`, as ghosts; turret ghosts request ammo as `place_ghosts`'s do.
  `preserve_existing_settings_and_wires: true` adds only what is missing. A paste leaves the requests of a hub or
  requester chest it lands on, a hub's construction requests too (`requests_kept`).
  Example: `./fh call paste --args '{"name":"smelter-row","position":{"x":40,"y":12},"dry_run":true}'`
- `placements {name, near?, radius?, limit?, separate?, powered?, surface?}`: up to 10 (`limit` up to 50) positions
  where it fits now, nearest first, by the game's build check, without building (`blocked`: positions something stands
  in). `"separate": true` lists spots that do not overlap each other, `"powered": true` only spots in one of our poles'
  supply areas; without them `overlapping` and `no_supply` count such spots, and count 0 names what is in the way
  (`in_the_way`). With no spot it adds `fewest_to_clear`: up to 3 spots (within 12 tiles) whose blockers are all ours
  and minable, or trees and rocks, with how many to mine first and which (`(47,187): mine 2 first (accumulator 2):
  ...`). `surface` reads another planet; each spot gives `network`. A cargo bay keeps to its 2-tile grid: the position
  offered is where it lands. A refused build of an offshore pump, or of anything onto water, lists the nearest valid
  placements.
  Example: `./fh call placements --args '{"name":"accumulator","near":{"x":-60,"y":95},"radius":16}'`
- `nearest_water {position?, radius?}`: the nearest pumpable tile in charted ground (up to 256 tiles) with
  offshore-pump spots there.
- `conflicts {name, position}` (a read): what building there takes away: everything in the way, the fluid segments that
  split and the poles cut off.
  Example: `./fh call conflicts --args '{"name":"pumpjack","position":{"x":-4.5,"y":101.5}}'`
- `build_path {points}`: lays belts along the points and mines the trees and rocks in its way by hand as it goes
  (`last.cleared`, `cleared_names`).
  Example: `./fh call build_path --args '{"points":[{"x":0.5,"y":0.5},{"x":20.5,"y":0.5}]}' --wait`
- `grid {position?, radius?}`: one character per tile; `,` is `walkable water` (shallow water, wetland, Fulgora's oil
  ocean, deep too), `~` water a character cannot cross; `map` tells them apart the same way.
- `pole_route {from, to}`: from a powered pole, lays pole ghosts along a line and reports how many poles you are
  `short`. On water and Gleba wetland it shifts a pole up to 2 tiles to dry ground, else lays a landfill tile ghost
  under it (`tiles_under`, `tiles_note`).
  Example: `./fh call pole_route --args '{"from":{"x":10.5,"y":10.5},"to":{"x":80.5,"y":10.5}}'`
- `belt_route {from, to, via?, return?, landfill?, cliffs?, avoid_nests?, avoid_enemies?, replan?}`: lays a belt line as ghosts
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
  Example: `./fh call belt_route --args '{"from":{"x":0,"y":0},"to":{"x":600,"y":40},"return":true}'`
- `rail_route {from, to, signals?}`: lays 2.0 rails (16 headings; straight, half-diagonal and two curve pieces, a curve
  3 rails) around water, cliffs and buildings as ghosts and builds those in reach (`"signals": 30` adds one-way
  signals). Rail ramp dry runs list every physical collision in `collisions`, rotated cliffs and deconstruction marks
  still present included; a failed `place_ghosts` names the same footprint list.
  Example: `./fh call rail_route --args '{"from":{"x":0,"y":0},"to":{"x":0,"y":-200}}'`
- `train_stop {position, name}`: puts a stop on the side of a straight rail that serves trains heading one way.
  Example: `./fh call train_stop --args '{"position":{"x":40,"y":-20},"name":"iron-pickup"}'`
- `train {position, station?, limit?, schedule?, automatic?, path_to?}` or `{stops: true, surface?}`: on a stop, its
  `station` and `limit`; on a locomotive, its `schedule` and `automatic`; `train {position}` reads a train's state and
  why it waits. A train in `no_path` reads `rail_break` (`path_to: "STOP"` for any stop): the rails followed from the
  train, whole, reaching the stop only facing away, or broken: where the rails from each side end, the gap, rail
  ghosts. `stops: true` lists every train stop of ours on a surface: name, position, rail, limit and the trains
  heading there.
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
- `blueprint_list {name?}`: the library's entries (author, size, counts, last used); `name` gives one in full.
- `blueprint_place {name, position, direction?, platform?, dry_run?}`: pastes a library entry, as `paste`; a platform's
  layout goes on another platform with `platform: "Swift"`.
  Example: `./fh call blueprint_place --args '{"name":"smelter-row","position":{"x":90,"y":0},"dry_run":true}'`
- `blueprint_rename {name, new_name}`: its author any time, anyone after 24 game hours unused.
  Example: `./fh call blueprint_rename --args '{"name":"smelter-row","new_name":"smelter-row-v2"}'`
- `blueprint_delete {name}`: who may, as `blueprint_rename`.
- Dry runs (`"dry_run": true` on `build`, `place_ghosts`, `paste`) place nothing and report the plan: per entity
  whether it fits or what blocks it and where, blocked entities first and all of them in `blocked` (up to 200) apart
  from those needing tiles; the tiles an entry needs (landfill, foundation, shallow oil, water, and on a platform the
  empty tiles new foundation would enclose), with the entities in its way; poles' wire reach and pole groups left
  unconnected; standing spots that reach every placement; what each planned inserter picks up from and drops into
  (`missing: no drop target`); `connections`: each planned boiler's, turbine's, reactor's, pump's or pipe's fluid and
  heat connection points and what joins each (`planned #5 pipe`, `nothing there`), a pump port's tile, and for each
  pipe-to-ground what its mouth joins and whether it pairs, with which (`inspect` of a heat entity shows its heat
  connections and temperature). `closes_in` names the entry that fills the last gap out when the plan would close you
  in where you stand; a build reply says `closed_in` after it. `build` dry runs name off-character `pockets`, their
  area and planned boundary tiles (a bounded 24-32-tile window); `pockets_checked` says when a larger plan was not
  checked. Dry runs and build replies name logistic chests no roboport covers (`outside_logistic_coverage`) and
  inserters or belts feeding an underground entrance from the side, with the lane that gets nothing
  (`underground_side_feed`). Each cliff the placement marks is listed (`cliffs_under`). A place_ghosts dry run over
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
  `demolisher_territory`, dry runs too.
