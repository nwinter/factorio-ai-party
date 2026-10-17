- `place_ghosts` entries, `build` `builds` entries and a single `build` take `configure`, `requests`, `circuit` (the
  arguments of `configure`, `requests`, `circuit_set`, without `position`) and `wires: [{to, color, from_side,
  to_side}]`: set after every entry is placed, then the wires; the reply's `settings` and `settings_line` say what was
  set or refused (a refused setting leaves the entry placed); `dry_run` gives `settings_planned`. An entry's
  `settings: {...}` is read as those keys (`settings_alias`); a setting key such as `modules` at the entry's top level is refused with the shape.
  `"check_inserters": true` checks every planned inserter's pickup, drop, power and filters first and places nothing if one would not work;
  each row's `line` (and the refusal) names both sides: `picks from iron-chest (3.5,5.5), drops into stone-furnace (3,2.5)`.
- A `build` over a chest of the same fast-replace group keeps its contents in the new chest; what it cannot hold
  comes to you (`replaced.contents`), and with no room for that nothing moves; any fast replace keeps filters, wires,
  circuit settings, a chest's limit and requests (`replaced.kept`, `not_kept`). Inserter and loader filters show in
  `scan` rows (`filters: whitelist: iron-plate`, `off`, `set by circuit`); `configure {position, filters, filter_mode
  | mode, use_filters}` and `circuit_set {settings: {filters, filter_mode}}` set them. An unknown argument's refusal
  names the closest valid name, and on `configure` and `circuit_set` what that entity takes. `configure {position,
  spoil_priority: fresh_first | spoiled_first | none}` sets an inserter's Spoil priority (built or ghost; `inspect`
  shows it).
- A dry run lists blocked entities first and all of them in `blocked` (up to 200), apart from those needing tiles.
- `"dry_run":true` on `place_ghosts`, `paste` or `build` places nothing and reports the plan: per entity whether it
  fits or what blocks it and where, the tiles it needs first (landfill, foundation, and on a platform the empty tiles
  new foundation would enclose), power poles' wire reach and pole groups left unconnected, and standing spots that
  reach every placement, and what each planned inserter picks up from and drops into (`missing: no drop target`);
  `inspect` and build replies flag a built inserter with no pickup or drop target. `connections` gives each planned
  boiler's, turbine's, reactor's, pump's or pipe's fluid and heat connection points and what joins each (`planned #5
  pipe`, `nothing there`), and for each pipe-to-ground what its mouth joins and whether it pairs, with which;
  `inspect` of a heat entity shows its heat connections and temperature. `closes_in` names the entry that fills the
  last gap out when the plan would close you in where you stand; a build reply says `closed_in` after it.
  `build` dry runs also name off-character `pockets`, their area and planned boundary tiles (a bounded 24–32-tile
  window); `pockets_checked` says when a larger plan was not checked.
  Dry runs and build replies also name logistic chests no roboport covers (`outside_logistic_coverage`) and inserters
  or belts feeding an underground entrance from the side, with the lane that gets nothing (`underground_side_feed`).
  Rail ramp dry runs list every physical collision in `collisions`, including rotated cliffs and deconstruction
  marks that are still present; failed `place_ghosts` replies name the same complete footprint list.
  Dry runs list each cliff the placement marks (`cliffs_under`). `conflicts {name, position}` (a read) says what
  building there takes away: everything in the way, the fluid segments that split and the poles cut off.
- Build and place_ghosts dry runs name the tiles an entry needs (shallow oil, water) together with the entities in its way; a platform ghost refused over empty space says when foundation tile ghosts under it are not built yet.
- `build`/`construct` report pre-action `materials` (need, held, missing, queued, hand_craftable). Build's existing `dry_run` includes them; `construct {dry_run:true}` checks ghost materials without acting.
- `build`, `place_ghosts` and `placements` take a direction as the number inspect prints (0, 4, 8, 12) or a compass
  name. `map` and `grid` tell `walkable water` (`,` on the grid: shallow water, wetland, Fulgora's oil ocean, deep too)
  from water a character cannot cross (`~`).
- `build` and `place_ghosts` entries take `recipe` for assemblers.
- `./fh call placements --args '{"name":"accumulator","near":{"x":-60,"y":95},"radius":16}'` lists up to 10 (`limit`
  up to 50) positions where it fits now, nearest first, by the game's build check (`blocked`: positions something
  stands in); `"separate":true` lists spots that do not overlap each other, `"powered":true` only spots in one of our
  poles' supply areas; without them `overlapping` and `no_supply` count such spots, and count 0 names what is in the way
  (`in_the_way`). `build_path` mines the trees and rocks in its way by hand as it goes (`last.cleared`, `cleared_names`).
- `nearest_water {position?, radius?}`: the nearest pumpable tile in charted ground (up to 256 tiles) with offshore-pump spots there.
- Placement: a refused build of an offshore pump, or of anything onto water, lists the nearest valid placements;
  placements {name, near, radius, limit} lists where it fits now, nearest first, without building.
- `build` errors name the blocker (tree, rock, the character, water). Trees and rocks: `place_ghosts` + `construct`
  clears them, or `mine` them. `build` works while the clock is paused.
- Turret ghosts from `place_ghosts` and `paste` request ammo, so the robots that build them bring it (`ammo`: a name,
  `{name, count}` or false; default 10 of what the logistic network there holds most of); so do the ghosts of turrets that died.
- Hand `build` applies each entry’s settings as placed; `inspect`/`trace` flag held-item refusal, and platform build dry runs report unwired pump enable conditions. Queue transfer steps accept `min_moved:1`; full `status` has cached boiler/feeder fuel, and feed-tour failures retain smaller-margin route facts.
- Water and Gleba wetland: `pole_route` shifts a pole up to 2 tiles to dry ground, else lays a landfill tile ghost under
  it (`tiles_under`, `tiles_note`); `place_ghosts` lays the landfill ghost under an entity ghost there; `construct`
  builds the landfill first, and a build refused there names the tile.
- Landfill on Gleba wetland goes in only where no slipstack, cuttlepop, hairyclubnub or stromatolite stands (marked or
  not, for a tile laid by hand): a dry run and a failed build name them (`blocked by slipstack tree at (x,y): mine it
  first`); `place_ghosts` marks them for removal first (`tile_obstacles_marked`) and `construct` mines them before it
  lays the landfill. Water-cane and fish do not block a tile: the new tile takes them away (`removed`). Landfill goes on
  water and wetland only (`landfill cannot go on oil-ocean-deep (foundation can; not researched)`).
- `deconstruct --args '{"area":...,"tiles":["landfill"]}'` also removes our landfill tile ghosts there
  (`tile_ghosts_removed`), and marks built landfill.
- `./fh call mine --args '{"tiles":true,"position":{"x":194,"y":58}}' --wait` mines a laid tile (landfill, concrete,
  stone path, artificial soil) by hand: the tile under it goes back and the item to you; `positions`, `area`, `"walk":true`,
  `"dry_run":true`; a tile anything stands on is refused, naming it. `construct` mines tiles marked for deconstruction too.
  Entity `mine` takes one `position` per call or queue step; its `positions`/`area` require `tiles: true`.
  `mine {position, count: 200}` on ore, coal or stone mines 200 units in one call (outcome `mined`), going on to the next tile in reach.
- `mine {position, dry_run: true}` and `deconstruct` (dry run and live) read `heat_loss`: heat-network parts cut off from every reactor and heating tower, and on Aquilo freezable pipes and machines that lose their last heater at 30 C or more.
- `upgrade {area | position, to, from?}` or `{map: {"turbo-transport-belt": "transport-belt"}}`: the upgrade planner; a
  ghost changes in place (wires and settings kept), a built one is marked for robots. A place_ghosts dry run over another
  ghost now says blocked, as the call is. `placements {surface}` works from another planet; each spot gives `network`.
- `deconstruct {area, cancel: true}` unmarks; pump dry runs show each port's tile and what is there; supply rows show stock robots have reserved.
- `clear_cliffs {"positions":[{"x":82,"y":38.5}]}` throws cliff explosives you hold at those cliffs, walking into their 10-tile
  range (`use_item {"item":"cliff-explosives","position":...}` too); `last.destroyed` names the cliffs gone, `last.left` the rest.
- `./fh call belt_route --args '{"from":{"x":0,"y":0},"to":{"x":600,"y":40},"return":true}'` lays a belt line as ghosts (via points, legs up to
  1000 tiles, over trees and wild plants it marks, water only with `"landfill":true`; `return` adds the line back beside it,
  crossing under it where its side is blocked). Belts, undergrounds and splitters say where items go in `belt` (inspect,
  observe rows, build replies; `last_belt` for a batch): `moves items south to (-22.5,-28.5); fed from (-22.5,-30.5)`.
  `belt_route {avoid_enemies: N}` keeps belts, underground spans and returns outside charted enemy reach plus N tiles (0..32; true=8; omitted/false disables); endpoints inside are refused.
  `belt_route` goes round cliffs (an underground passes under one; `cliffs: true` passes over and marks them), names what its
  ghosts mark for mining (`to_mine`: trees, rocks, cliffs with positions), and extends an existing chain from a belt
  end followed up to 4096 tiles (`existing_count`).
- `pole_route` with `from` (a powered pole) and `to` lays pole ghosts along a line and reports how many poles you are
  `short`; craft those, then `construct --wait`.
- `heat_budget {position, add_pipes?}` reads a heat network's mean temperature, heat capacity and heat above 30 C, and with add_pipes the mean after that many new cold heat pipes join.
- Nuclear: build the reactor and heat pipes; transfer or refuel with uranium-fuel-cell.
- `outpost {position, radius}` (or `area`) queues one tour for an outpost: construct its ghosts, rearm its turrets, wire its poles cut off from power; `dry_run: true` shows the plan and what you lack.
- The team blueprint library, kept in the save across shifts: `blueprint_save {name, area | positions, description,
  anchor}` stores what the team built; `blueprint_list` lists entries (author, size, counts, last used);
  `blueprint_place {name, position, direction, dry_run}` pastes one; `blueprint_rename` and `blueprint_delete {name}`:
  its author any time, anyone after 24 game hours unused.
- `blueprint_save {name, area, platform: "Starling"}` and `blueprint_capture` take `platform=NAME` like `paste` and `blueprint_place`: save a platform's layout from anywhere, then `blueprint_place {name, platform: "Swift"}`.
- Trains: rails with build {item: rail, entity: straight-rail|curved-rail-a|curved-rail-b|half-diagonal-rail};
  stops, locomotives and wagons with build; train {position: stop, station, limit}; train {position: locomotive,
  schedule, automatic}.
- `train {stops: true, surface?}` lists every train stop of ours on a surface: name, position, rail, limit and the trains heading there.
- `./fh call rail_route --args '{"from":{"x":0,"y":0},"to":{"x":0,"y":-200}}'` lays 2.0 rails (16 headings; straight,
  half-diagonal and two curve pieces, a curve 3 rails) around water, cliffs and buildings as ghosts and builds those in
  reach (`"signals":30` adds one-way signals); `train_stop {position, name}` puts a stop on the side of a straight rail
  that serves trains heading one way; `train {position}` reads a train's state and why it waits.
- `build {item: "rail-ramp", position, direction}` and `construct` on a ramp ghost build it by hand from one held ramp;
  the centre snaps to the ramp grid, with the same collision and reach checks.
- A `build` of an inserter says what its sides touch: `pickup` and `drop` (`requester-chest (44.5,190.5)`, `none: the
  ground at (42.5,190.5)`), with `inserter` (its direction in words) and `io_warning`.
- `placements` that finds no spot adds `fewest_to_clear`: up to 3 spots (within 12 tiles) whose blockers are all ours
  and minable, or trees and rocks, with how many to mine first and which (`(47,187): mine 2 first (accumulator 2): ...`).
- `build` where you stand on the footprint steps aside first: the reply gives `not_yet`, `still_to_build` and
  `built_so_far` (nothing of that entry is built yet); `--wait` or status `last.built` counts it. A retry with the item
  gone names the entity already standing there.
