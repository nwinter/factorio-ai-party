- `transfer {position | positions | area, direction?, item | items, count?, inventory?, ...}`: moves items between you
  and any container (chests, logistic chests, car and spider trunks, cargo wagons, landing pads, hubs, machines,
  turrets, roboports). `direction` (`to_entity` gives, `to_player` takes) is inferred when omitted (a give when the
  target holds the item only where it feeds from, its fuel, ammunition or input, and you hold it too; `direction_note`
  says so); `items: {"iron-plate":50,"coal":10}` moves several at one target, each with its row in `entries`. A fusion
  reactor's fuel cells go in and out as any burner's; a roboport's robots come out with `{position, direction:
  "to_player", item: "logistic-robot", count}`, as its GUI does. A transfer from a belt is refused naming `pickup
  {belt: true}`.
  - `to_player: "haiku"` hands items to a teammate within your reach: dropped at its feet as loot its character picks
    up (`players` gives teammates' positions).
  - Two places in one call: `{position, to, item, from_inventory, to_inventory}` takes at `position` and gives at
    `to`, each end its own inventory (a machine's `assembling_machine_output` into another's
    `assembling_machine_input`); a take not reached ends `unreached`, nothing given. `{from: {x,y}, to: {x,y}, item,
    count}` too, `inventory` going with the place that has it (a silo's cargo at `to`).
  - `from: "nearest"` (with `item`; `radius` up to 256 to walk; `walk: true` alone looks 32 tiles) takes from the
    nearest of our chests holding it now and says which; a `count` it lacks comes from the next ones (up to 16), and
    one holding it all, no farther, goes alone (chests holding less than the count ahead of it: `skipped_small`). A
    spoilable item comes from the freshest chests first, then the nearest. Chests that feed something (requester and
    buffer chests, a chest an inserter takes from) only with `feeding: true`; walking, none in a worm's reach; each
    left out is named. A walking take from chests holding none of it now is refused before the walk, naming the
    nearest holding it. With `to` (and `to_inventory`) it is a courier straight to that machine, freshest stacks
    first, and takes from a chest feeding `to` itself.
  - `pick: "first_with_stock" | "most_stock"` with `positions` and `item` or `items` (collect too) takes at one listed
    place holding it now (empty ones `skipped`, not short; none: nothing walked); `to` (`{x,y}` or `{item: {x,y}}`)
    carries it on to that destination in the same call. `dry_run: true` on such a courier gives `courier`: the source
    and what it holds (robots' reservations), the destination and its room, how many would move. Tour stops end once
    within transfer reach of the entity (a silo, a pad), as `move_to {target}` does.
  - `via: [{"x":30,"y":5}]` walks those points first; a walking transfer's `last.route` gives where it started, each
    via point and stop as reached, and the tiles walked.
  - Personal requests: what you take over a request's max goes to your trash slots (`trash` says how much; collect and
    pickup too); `up_to: true` stops at the max, `keep_max: true` refuses the take. A courier over a max says how much
    would arrive (`personal_logistics`, the dry run's `arrives`); `personal_logistics: "pause"` switches your requests
    off for the move.
  - Spoilage: `fresh_first: true` (`fresh: true` on a courier) takes the least spoiled stacks first on any take or
    give; `spoiled_first: true` and `min_spoil` (alias `min_spoiled`) or `max_fresh` move only the rotten tail. The
    reply gives `freshness` (the moved stacks' spread).
  - Other names taken: `entity_position`, `target_position`, `pos` are `position`; `mode: "take"` or `"give"` is the
    direction; `amount`, `quantity` are `count` (the reply's corrected line shows the call as it ran).
  Example: `./fh call transfer --args '{"position":{"x":15.5,"y":59.5},"direction":"to_entity","item":"rocket-fuel","count":50}'`
- `collect {positions | area | radius, item?, count?, chests?, outputs_only?, wait_ticks?, follow?, min_fresh?}`:
  takes machine outputs; chests only when you name their positions or pass `chests: true`. `radius` without `item`
  takes every assembler and furnace output in it (output slots only); with `item` it walks to the outputs and chests
  holding it until `count`. `outputs_only: true` never takes fuel, inputs or burnt results. `min_fresh: 70` takes only
  stacks at least 70% fresh (`left_less_fresh` says what stayed).
  - `wait_ticks` at a machine's position stands there and takes each product the tick it appears (`count` stops
    early): `last.took`, `last.made` and `last.inserters_took` (counted) say who got what, `last.why` why it took
    none, and `taken_by_inserters` which inserters take the output and the chest they fill. `follow: true` takes from
    that chest instead of waiting, following the output into chests and walking to one out of reach.
  Example: `./fh call collect --args '{"positions":[{"x":10.5,"y":3.5}],"wait_ticks":1800,"count":20}' --wait`
- `feed {positions | area | radius, item | items?, recipe?, crafts?, fuel?, count?, keep?}`: tops up every machine in
  reach (or in `radius`, a walking tour; `position` its centre) from your inventory: an assembler or furnace its
  recipe's ingredients, a lab its science packs, a burner fuel when its fuel slots are empty or with `fuel` (`true` or
  a fuel name). A furnace with no recipe yet takes the `item`/`items` it smelts; `recipe: NAME, crafts: N` loads each
  machine on that recipe for N crafts; `keep` holds back a reserve. Each named machine gets a row (`gave` or `got`,
  and its `fuel`).
  - `area` over 64 machines feeds them as one walking tour; `out_of_reach` is the initial count, `last.visited` the
    stops reached; what you carry and fuel slots holding another fuel limit what it delivers.
  - It skips a burner whose fuel slots all hold another fuel (`other_fuel`; no warning under `up_to`). Giving nothing,
    it says why: a turret (`rearm` loads them), a chest (`transfer` puts items in), burners at or over the count,
    another fuel in every slot.
  - `up_to: true`: a tour that runs out (`out_of_items`) exits 0 from `--wait` and `./fh wait`, with moved and the
    stops left. `clear_spoilage: true` takes spoiled recipe waste and burnt results out first, walking too
    (`entities.cleared`: taken and left).
  Example: `./fh call feed --args '{"radius":20,"item":"coal","count":10}' --wait`
- `refuel {radius | area | positions | alert, fuel?, count?, from?, from_radius?, feed_chests?}`: tops up burners
  below `count` (default 10) with `fuel` (default coal) in one walking tour with move_to's enemy checks. Without
  `types` it reads burners only (boilers, furnaces, drills, reactors, burner generators and inserters), so a
  base-sized `area` is not refused for its belts. `legs` lists the stops, `last.route` the walk.
  - `from: "nearest"` (or a chest position) collects the fuel on the way, from chests and belts read apart (2048
    chests and 1024 belts) within `from_radius` (default 64, up to 128) of each stop, and the logistic network's
    pickup point; `last.sources` and `fuel_taken` report the takes. `feed_chests: true` fills the chests inserters
    feed boilers from instead.
  - `alert: "KEY"`: an out-of-fuel alert lists each burner's position and ends with `refuel {alert: "KEY"}`, a tour
    over exactly those with the fuel you carry (an alert's centre can lie far from them: it joins touching areas).
    The alert names the nearest fuel its most common burner takes (`nearest fuel: coal 120 in iron-chest (100,-20),
    7 tiles from (96,-26)`: our chests within 64 tiles, else belts within 32) and then ends with `refuel {area:
    [[93,-40],[98,-12]], from: "nearest", fuel: "coal"}` over the burners' box instead.
  - Nothing to do: `nothing` says why, `nearest_outside` names the nearest dry burner outside the area.
  Example: `./fh call refuel --args '{"radius":40,"from":"nearest","count":20}' --wait`
- `pickup {area | position, radius?, items?} | {belt: true, item, count, to?}`: picks up items by hand (timed),
  walking to them. Items on the ground show in `scan` and `observe` (`ground_items`); `status` `alerts.ground_items`
  names full landing pads that spill and piles near buildings; `deconstruct {area, items_on_ground: true}` marks them
  for construction robots. `belt: true` takes items off belt lanes (belts within 1 tile, walking to them; areas on the
  map too); `"to":{x,y}` puts them in that chest at the end of the same walk; `spoiled_first: true` takes the most
  spoiled stacks first, `min_spoiled: N` only stacks at least N% spoiled (`last.picked_spoil`: each stack and its
  spoilage).
  Example: `./fh call pickup --args '{"belt":true,"item":"iron-plate","count":200,"position":{"x":90.5,"y":-11.5}}' --wait`
- `mine {position, count?, radius?, name?, tiles?, dry_run?}`: mines one entity or resource tile by hand (timed). Ore
  yields one per cycle (2 s for iron; `last.mined` counts); rocks give stone and coal fast. `count: 200` on ore, coal
  or stone mines 200 units in one call (outcome `mined`), going on to the next tile in reach; a mined-out resource
  tile mines the nearest one of the same resource within `radius` (default 8), one in reach first, named in `instead`.
  A tile of a building's footprint away from its centre is refused, naming the building and its centre (`name` mines
  it). `dry_run: true` says what a position picks (`off_centre`) and reads `heat_loss`: heat-network parts cut off
  from every reactor and heating tower, and on Aquilo freezable pipes and machines that lose their last heater at 30 C
  or more. An entity takes one `position` per call or queue step; `positions` and `area` need `tiles: true`.
  - `tiles: true` mines a laid tile (landfill, concrete, stone path, artificial soil): the tile under it goes back and
    the item to you; `positions`, `area`, `"walk":true`, `"dry_run":true`; a tile anything stands on is refused,
    naming it. `construct` mines tiles marked for deconstruction too.
  Example: `./fh call mine --args '{"tiles":true,"position":{"x":194,"y":58}}' --wait`
- `rotate {position, direction?, reverse?}`: one 90-degree turn clockwise (`reverse: true` counter-clockwise;
  `direction` a facing to turn to); replies `before` and `after`. `platform: NAME` (or `surface: NAME`) turns a ghost
  or built belt or inserter there by remote view.
  Example: `./fh call rotate --args '{"position":{"x":22.5,"y":86.5},"direction":"east"}'`
- `repair {position | positions | area}`: repairs with repair packs, walking to each damaged one, nearest first;
  reports `repaired` and `already_full`. An undamaged entity is ok with `unchanged: "not damaged"`.
  Example: `./fh call repair --args '{"positions":[{"x":12.5,"y":4.5},{"x":15.5,"y":4.5}]}' --wait`
- `inventory`: main, ammo, armor and equipment, trash and cursor in one small reply, guns and ammo per slot (gun slot
  N fires only from ammo slot N); `status {"inventory": true}` adds it as one line.
- `craft {recipe, count}` (or `recipes: [...]`): queues hand crafts. A craft of 3 s or more that stock within 25 tiles
  covers is refused unless `force: true` (`check_stock: true`: within 64), naming the stocking chests. One that queued
  nothing for a recipe says `nothing_queued` with what is short (left out of `started`) and what you carry.
  Example: `./fh call craft --args '{"recipe":"iron-gear-wheel","count":10}'`
- `cancel_craft {recipe | index, count?}`: cancels queued hand crafts, the latest first (`all: true`: every one); the
  ingredients come back.
- `deliver {position | positions, items, surface?}`: fuel or ammunition into a burner or turret by item request, as a
  blueprint's: the construction robots of the network covering it bring it (the row names that network's stock and
  free robots). Modules: `configure`; ingredients: inserters or a requester chest.
  Example: `./fh call deliver --args '{"position":{"x":12.5,"y":-40.5},"items":{"firearm-magazine":20}}'`
- Item moves (`transfer`, `collect`, `feed`, `pickup`, `rearm`, `refuel`, `mine`, `craft`, `cancel_craft`, a
  `configure` recipe change) say `moved` and end with `inv` (free slots, what you hold of the items moved); a move
  over time says `timed`, and `last.moved`/`last.inv` when it ends; queue and standing-order history entries carry
  both. A give the target could not take all of, or a courier that delivered less than it took, ends with a `short`
  warning naming what fills the target's slots. Several targets end with a `tally` line; every target failing fails
  with the first reason (a tour: outcome `failed`, `last.first_error`). `rearm`, `refuel` and `collect` name a target
  already holding enough or holding none.
- Couriers: `"up_to": true` in `transfer`, `collect` or `feed` moves what there is and reports `moved` and `short`
  instead of failing (a queue step with it, or with `"on_short": "skip"`, goes on when short). `"walk": true` (feed
  and collect with `positions`) walks into reach of targets out of reach first (one call; `legs` lists the route; a
  position that resolves to nothing is named in `skipped`, the rest go on). `area {left_top, right_bottom}` takes
  every machine (or chest) inside it.
- Walking into reach: out of reach within 32 tiles (64 for `transfer`, `collect`, `feed`, `rearm` and `refuel`), those
  calls and `mine`, `build`, `rotate` and `configure` (modules by hand, a recipe change on a stocked machine) walk
  into reach first, the reply's `walking` line saying so; past that the refusal says the distance, your reach and a
  spot in reach, and names the call with `"walk": true` (any distance); `"walk": false` refuses. Reach is to an
  entity's edge (`build`: to the position). Mining uses resource reach (2.7 tiles) for ore, trees, plants and rocks,
  entity reach (10) for buildings and laid tiles; queue steps too.
- `position` and `positions` are interchangeable in these calls (`corrected` says how it ran). A position on a tile
  corner (whole numbers) picks the one entity of a tile touching it; two touching it are refused by name, and `"name":
  "requester-chest"` (or `unit_number`) picks one. Alert lines give a single entity's own position (`near
  (16.5,23.5)`). `./fh help transfer` shows calls that work; an argument refusal ends with one built from your call
  (`launch`'s with the silos there).
- A burner's fuel slot holds one fuel type: you cannot add coal while wood remains.
