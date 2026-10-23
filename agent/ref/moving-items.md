- `transfer {position | positions | area, direction?, item | items, count?, inventory?, ...}`: moves items between you
  and any container (chests, logistic chests, car and spider trunks, cargo wagons, landing pads, hubs, machines,
  turrets, roboports). `direction` (`to_entity` gives, `to_player` takes) is inferred when omitted (a give when the
  target holds the item only where it feeds from, its fuel, ammunition or input, and you hold it too; `direction_note`
  says so); `items: {"iron-plate":50,"coal":10}` moves several at one target, each with its row in `entries`.
  `retry_when_clear: true`: refused only for passing enemies (an attack, units or a group seen now), it waits until no
  enemy unit is within 48 tiles (and 30 s when none is there now) and transfers again, at most 6 times (`retry`). A fusion
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
    buffer chests, a chest an inserter takes from) only with `feeding: true`; walking, none in a worm's reach; a chest
    you put that item into by hand in the last 10 minutes neither (named by position it is taken from); each left out
    is named. A walking take from chests holding none of it now is refused before the walk, naming the
    nearest holding it. With `to` (and `to_inventory`) it is a courier straight to that machine, freshest stacks
    first, and takes from a chest feeding `to` itself.
  - `to: "nearest_room"` (with `item`, `count` default all you hold, `radius` up to your reach, `chest` a name or
    names): into our chests in reach with room for it, the nearest first, each filled before the next; `chests` and
    `line` say which took how much and what was not placed.
  - `pick: "first_with_stock" | "most_stock"` with `positions` and `item` or `items` (collect too) takes at one listed
    place holding it now (empty ones `skipped`, not short; none: nothing walked); `to` (`{x,y}` or `{item: {x,y}}`)
    carries it on to that destination in the same call. `dry_run: true` on such a courier gives `courier`, a preview:
    the source and what it holds (robots' reservations), the destination and its room, how many would move; a
    requester or buffer source's own request (`spare`: how many can leave it with its request still filled), the
    destination's request and what robots bring each side now, and when the first stack spoils or hatches. Tour stops end once
    within transfer reach of the entity (a silo, a pad), as `move_to {target}` does.
  - `steps: [{take: [{x,y}, ...], item, count?}, {give: [...], item, split?: "even" | "fill", count?}]` chains takes
    and gives in one walking call, in order (32 chests at most). The first leg that fails or is not reached ends it:
    `last.chain_held`, `last.chain_left`; `on_fail: "return"` walks what it took back to where it came from.
  - `via: [{"x":30,"y":5}]` walks those points first; a walking transfer's `last.route` gives where it started, each
    via point and stop as reached, and the tiles walked.
  - Robots bring items to you: `requests {set: [{item, min}]}` with no position sets your own logistic requests, and
    the logistic robots of the network you stand in bring them to your inventory while you stay in its logistic area
    (Opus, shift35 131h: copper-plate 28 to 500 in about 80 s; advanced-circuit 38 to 304 in 2 min, 3.5 a second).
    The reply's `unfilled` says per item what you hold, what is on the way and why the rest is not coming (no network
    where you stand, no logistic robots, none free in the network). `clear: ["item"]` ends one and keeps what came.
    A sleep or wait that ends early gives `personal_requests`. `./fh wait --until "item_count copper-plate>=500"` waits
    for it. Example: `./fh call requests --args '{"set":[{"item":"steel-plate","min":200},{"item":"concrete","min":500}]}'`
  - Personal requests: what you take over a request's max goes to your trash slots (`trash` says how much; collect and
    pickup too); `up_to: true` stops at the max, `keep_max: true` refuses the take. A courier over a max says how much
    would arrive (`personal_logistics`, the dry run's `arrives`); `personal_logistics: "pause"` switches your requests
    off for the move.
  - Spoilage: `fresh_first: true` (`fresh: true` on a courier) takes the least spoiled stacks first on any take or
    give; `spoiled_first: true` and `min_spoil` (alias `min_spoiled`) or `max_fresh` move only the rotten tail, on a
    courier (`positions` and `to`) too. The reply gives `freshness` (the moved stacks' spread) and `left_less_fresh`
    (what the filter left where it was, e.g. "200 left where they were: less than 50% spoiled (the least spoiled
    20%)"); a timed one in `last`.
  - Other names taken: `entity_position`, `target_position`, `pos` are `position`; `mode: "take"` or `"give"` is the
    direction; `amount`, `quantity` are `count` (the reply's corrected line shows the call as it ran).
  Example: `./fh call transfer --args '{"position":{"x":15.5,"y":59.5},"direction":"to_entity","item":"rocket-fuel","count":50}'`
- `collect {positions | area | radius, item?, count?, chests?, outputs_only?, wait_ticks?, follow?, min_fresh?}`:
  takes machine outputs; chests only when you name their positions or pass `chests: true`. `radius` without `item`
  takes every assembler and furnace output in it (output slots only); with `item` it walks to the outputs and chests
  holding it until `count`. `outputs_only: true` never takes fuel, inputs or burnt results. `min_fresh: 70` takes only
  stacks at least 70% fresh (`left_less_fresh` says what stayed).
  - `pods: true` walks the landed cargo pods on your surface (those `pods` lists, else those within 64 tiles; `area`:
    those there), nearest first, taking what each holds up to your free slots; `to: {x,y}` (a chest) gets what it took
    each time your inventory is full, then it goes back for the rest, and at the end. `last.items` (taken),
    `last.given`, `last.pods_left`, `last.items_left` and `last.pods_line`; the walk and enemy checks are the tours'.
    Example: `./fh call collect --args '{"pods":true,"to":{"x":10.5,"y":170.5}}'`
  - `wait_ticks` at a machine's position stands there and takes each product the tick it appears (`count` stops
    early): `last.took`, `last.made` and `last.inserters_took` (counted) say who got what, `last.why` why it took
    none, and `taken_by_inserters` which inserters take the output and the chest they fill. `follow: true` takes from
    that chest instead of waiting, following the output into chests and walking to one out of reach. `to: {x,y}`
    (another machine, with `item`) gets each take the same tick by hand, into its recipe input when its recipe takes
    the item, else its fuel (`to_inventory` names one); it must be in reach from where the wait stands (else
    `unreached`); `last.gave`, `last.gave_short`. E.g. nutrients into a biochamber's fuel before robots take them:
    `./fh call collect --args '{"positions":[{"x":2.5,"y":0.5}],"wait_ticks":3600,"item":"nutrients","to":{"x":6.5,"y":0.5}}'`
    `give: {item: count}` (one machine in reach) puts those in first by hand (its recipe input, else its fuel; `gave`);
    with `item` and no `count` the wait ends when one craft's yield of it is taken; `take_back: ["nutrients"]` brings
    back at the end what is left of those items in the machine (input and fuel, each stack with its spoilage;
    `last.taken_back`). A breeder cycle in one call: `{"position":{"x":7.5,"y":20.5},"give":{"nutrients":30,"pentapod-egg":1},"item":"pentapod-egg","wait_ticks":1800,"take_back":["nutrients"]}`.
  - `wait_ticks` or `keep_taking`: the call returns when the collect ends, with or without `--wait`, its outcome the
    exit status; `--no-wait` returns at the start (`until_tick`).
  - A haul from several chests into one: a queue plan of a walking collect over the chests, then a walking transfer
    into the chest (each step a timed tour with the tours' enemy checks; the plan stops at a step that fails), e.g.
    `./fh call queue_submit --args '{"steps":[{"action":"collect","args":{"positions":[{"x":-40.5,"y":12.5},{"x":-44.5,"y":12.5}],"item":"tungsten-ore","walk":true}},{"action":"transfer","args":{"position":{"x":10.5,"y":3.5},"item":"tungsten-ore","direction":"to_entity","walk":true}}]}'`;
    from one chest: `pick` with `to` (above) in one call.
  Example: `./fh call collect --args '{"positions":[{"x":10.5,"y":3.5}],"wait_ticks":1800,"count":20}'`
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
  - `from: "nearest"` (or a chest or belt position) collects the fuel on the way, from chests (2048 read) within
    `from_radius` (default 64, up to 128) of each stop, and the logistic network's pickup point; never a belt (taking
    coal off one cuts its flow) or a chest you put the fuel into in the last 10 minutes unless `from` names it; `last.sources` and `fuel_taken` report the takes. `feed_chests: true` fills the chests inserters
    feed boilers from instead.
  - `alert: "KEY"`: an out-of-fuel alert lists each burner's position and ends with `refuel {alert: "KEY"}`, a tour
    over exactly those with the fuel you carry (an alert's centre can lie far from them: it joins touching areas).
    The alert names the nearest fuel its most common burner takes (`nearest fuel: coal 120 in iron-chest (100,-20),
    7 tiles from (96,-26)`: our chests within 64 tiles, else belts within 32) and then ends with `refuel {area:
    [[93,-40],[98,-12]], from: "nearest", fuel: "coal"}` over the burners' box instead.
  - Nothing to do: `nothing` says why, `nearest_outside` names the nearest dry burner outside the area.
  Example: `./fh call refuel --args '{"radius":40,"from":"nearest","count":20}' --wait`
- `pickup {area | position, radius?, items?} | {belt: true, item, count, to?}`: picks up items by hand (timed),
  walking to them. Items on the ground show in `scan` and `observe` (`ground_items`, by item, with `fresh`: the
  stalest stack's freshness %); `scan {type: "item-entity"}` rows and `inspect` of one (or of an area with
  `types: ["item-entity"]`) give each `stack {name, quality, count, fresh}`; `status` `alerts.ground_items`
  names full landing pads that spill and piles near buildings; `deconstruct {area, items_on_ground: true}` marks them
  for construction robots (`entity_types: ["item-entity"]` is the same; with `cancel: true` the reply counts the
  stacks unmarked, the robot orders cancelled and the robots freed). `belt: true` takes items off belt lanes (belts within 1 tile, walking to them; areas on the
  map too); `"to":{x,y}` puts them in that chest at the end of the same walk; `spoiled_first: true` takes the most
  spoiled stacks first, `min_spoiled: N` only stacks at least N% spoiled (`last.picked_spoil`: each stack and its
  spoilage). `last.belt` counts what the belt lines gave up and gives each belt before -> after, `came_in` (what
  upstream moved in meanwhile: a belt fed as fast as you take looks unchanged), and where it went: `kept`, `in_trash`,
  `gone_from_you` (a personal request max sends it to the trash, and robots take it to storage). Three passes that
  remove nothing end it `nothing_removed`.
  Example: `./fh call pickup --args '{"belt":true,"item":"iron-plate","count":200,"position":{"x":90.5,"y":-11.5}}' --wait`
- `mine {position, count?, radius?, name?, tiles?, dry_run?}`: mines one entity or resource tile by hand (timed). Ore
  yields one per cycle (2 s for iron; `last.mined` counts); rocks give stone and coal fast. `count: 200` on ore, coal
  or stone mines 200 units in one call (outcome `mined`), going on to the next tile in reach; a mined-out resource
  tile mines the nearest one of the same resource within `radius` (default 8), one in reach first, named in `instead`.
  A tile of a building's footprint away from its centre is refused, naming the building and its centre (`name` mines
  it). `dry_run: true` says what a position picks (`off_centre`) and reads `heat_loss`: heat-network parts cut off
  from every reactor and heating tower, and on Aquilo freezable pipes and machines that lose their last heater at 30 C
  or more. An entity takes one `position` per call or queue step; `positions` and `area` need `tiles: true`. A pipe,
  pipe-to-ground, tank or pump gives `fluid_split` (dry run too): the parts its segment would split into, per part its
  pipes, what takes from it and what puts into it; one that leaves a part with takers and no source is refused unless
  `cut_fluid: true` (`deconstruct` does the same for what it would mark).
  - `tiles: true` mines a laid tile (landfill, concrete, stone path, artificial soil): the tile under it goes back and
    the item to you; `positions`, `area`, `"walk":true`, `"dry_run":true`; a tile anything stands on is refused,
    naming it. `construct` mines tiles marked for deconstruction too.
  Example: `./fh call mine --args '{"tiles":true,"position":{"x":194,"y":58}}' --wait`
- `rotate {position, direction?, reverse?}`: one 90-degree turn clockwise (`reverse: true` counter-clockwise;
  `direction` a facing to turn to); replies `before` and `after`. `platform: NAME` (or `surface: NAME`) turns a ghost
  or built belt or inserter there by remote view. On your surface past the 32 tiles a call walks (without `walk: true`), it
  turns it by remote view in a chunk our force sees now (`by: "remote view"`).
  Example: `./fh call rotate --args '{"position":{"x":22.5,"y":86.5},"direction":"east"}'`
- `repair {position | positions | area}`: repairs with repair packs, walking to each damaged one, nearest first;
  reports `repaired` and `already_full`. An undamaged entity is ok with `unchanged: "not damaged"`.
  Example: `./fh call repair --args '{"positions":[{"x":12.5,"y":4.5},{"x":15.5,"y":4.5}]}' --wait`
- `inventory`: main, ammo, armor and equipment, trash and cursor in one small reply, guns and ammo per slot (gun slot
  N fires only from ammo slot N); `status {"inventory": true}` adds it as one line. `spoiling`: each spoilable stack
  of your main inventory, soonest first, with its slot, the time left and how spoiled it is; an egg reads `hatches in`
  (`pentapod-egg*2 (slot 3): hatches in 1m02s (93% spoiled)`).
- `craft {recipe, count, check_stock?, spoiling?}` (or `recipes: [...]`): queues hand crafts from your inventory, whatever
  stock the factory holds; `stock` names that stock (holders, nearest, largest, how much within 25 tiles of you). A
  spoilable ingredient: only the crafts that finish before the first stack of it you hold spoils are queued (the hand
  queue ahead, then each craft at your crafting speed; `spoil` says how many), `spoiling: true` queues them all;
  `products_spoil`: how long each spoilable product lasts fresh once it lands.
  `check_stock: true` refuses a craft of 3 s or more that stock within 64 tiles covers, naming the chests. One that queued
  nothing for a recipe says `nothing_queued` with what is short (left out of `started`) and what you carry. Each short
  ingredient names where the team keeps it: up to 3 nearest places within 128 tiles that can spare the shortfall (a
  requester or buffer chest only what it holds over its request, robots' reservations off), else some of it, else
  the logistic networks on your surface holding it and where robots would take it from.
  Example: `./fh call craft --args '{"recipe":"iron-gear-wheel","count":10}'`
- `cancel_craft {recipe | index, count?}`: cancels queued hand crafts, the latest first (`all: true`: every one); the
  ingredients come back.
- `deliver {position | positions, items, surface?}`: fuel or ammunition into a burner or turret by item request, as a
  blueprint's: the construction robots of the network covering it bring it (the row names that network's stock and
  free robots). Modules: `configure`; ingredients: inserters or a requester chest.
  Example: `./fh call deliver --args '{"position":{"x":12.5,"y":-40.5},"items":{"firearm-magazine":20}}'`
- Game rule, ghosts: a ghost is no logistic request. The construction robots of the network covering it take its item
  from active and passive provider, storage and buffer chests there (never from requester chests); with none held it
  waits, and the game shows a missing-materials alert. Items reach a network only by a request (a requester or buffer
  chest, a landing pad's or hub's slots) or by hand. `ghosts` names, per ghost, the item its network holds none of.
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
  entity reach (10) for buildings and laid tiles; queue steps too. When no path leads next to a target (a chest among
  machines), the walk tries up to 6 other spots anywhere within reach of it, nearest you first, leaving out spots in a
  closed pocket (`last.reach_walk`).
- `position` and `positions` are interchangeable in these calls (`corrected` says how it ran). A position on a tile
  corner (whole numbers) picks the one entity of a tile touching it; two touching it are refused by name, and `"name":
  "requester-chest"` (or `unit_number`) picks one. Alert lines give a single entity's own position (`near
  (16.5,23.5)`). `./fh help transfer` shows calls that work; an argument refusal ends with one built from your call
  (`launch`'s with the silos there).
- A burner's fuel slot holds one fuel type: you cannot add coal while wood remains.
