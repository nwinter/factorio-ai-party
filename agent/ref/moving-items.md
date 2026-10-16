- `transfer {position, direction, items:{"iron-plate":50,"coal":10}, walk?}` moves multiple items at one target, with per-item `entries`; `trace {surface, position}` and `labs {surface, position?, radius?}` read that surface; `supply {item:"lubricant"}` reads fluid stock/flow and makers/users.
- Courier calls: `"up_to": true` in `transfer`, `collect` or `feed` moves what there is and reports `moved` and `short`
  instead of failing (a queue step with it, or with `"on_short": "skip"`, goes on when short); `transfer {"walk":
  true}` (and `feed` or `collect {positions, "walk": true}`) walks into reach of targets out of reach first, then transfers (one
  call; `legs` lists the route); `transfer {item, "from": "nearest"}` (`radius` up to 256 to walk) takes from the nearest chest
  holding the item and says which, a `count` it lacks from the next ones (one holding it all goes alone); chests that
  feed something (requester and buffer chests, a chest an inserter takes from) only with `"feeding": true`, and walking
  (`"walk": true` looks 32 tiles) none in a worm's reach, each named when left out; `transfer
  {from: {x,y}, to: {x,y}, item, count}` takes at one place and gives at the other in one call (`inventory` goes with
  the place that has it, a silo's cargo at `to`); a walking take from chests holding none of it now is refused before
  the walk, naming the nearest holding it; `transfer`/`collect {positions,
  item | items, pick: "first_with_stock" | "most_stock"}` takes at one listed place that holds the item now (empty
  ones are `skipped`, not short; none: nothing walked), and `to` (`{x,y}` or `{item: {x,y}}`) carries it on to that
  item's destination in the same call; `./fh call inventory` shows main,
  ammo, armor and equipment, trash and cursor in one small reply (`status {"inventory": true}`: one line); `feed`
  skips a burner whose fuel slots all hold another fuel (`other_fuel`), with no warning under `up_to`; `feed {"recipe": NAME,
  "crafts": N, "positions": [...]}` loads each machine set to that recipe for N crafts; `feed` takes `item` or `items`;
  `inspect {"positions": [...]}` inspects up to 32 entities in one call (`"compact": true`: one line each); `collect {"radius": N}` without `item` takes
  every assembler and furnace output in the radius (output slots only). `position` and `positions` are interchangeable
  in these calls (`corrected` says how it ran). A repeating queue (`queue_repeat`, optional `name`) puts a `queue:`
  line in the team block when a round's short steps differ from the round before; steps with `up_to: true` or
  `"on_short": "skip"` are left out of it. `queue_repeat` takes `times` (rounds) and `for_ticks` (no round starts
  after that); the loop then ends with one `queue:` line (`done after N rounds: ...`) and `loop_done` in `queue_status`;
  its `orders` says which standing orders may run between its rounds (triggered ones by default). `transfer` is `{position, direction: "to_entity"|"to_player", item, count,
  inventory?}` on any container (`./fh help transfer` shows calls that work; an argument refusal ends with one built
  from your call, `launch`'s with the silos there); out of reach, it says the distance, your
  reach and a spot in reach. `inspect` of a chest shows `holds` (and `requests` with their fill); a `transfer` or
  `collect` over several targets ends with a `tally` line; one where every target failed fails with the first reason
  (a tour: outcome `failed`, `last.first_error`). Item moves (`transfer`, `collect`, `feed`, `pickup`,
  `rearm`, `refuel`, `mine`, `craft`, `cancel_craft`, a `configure` recipe change) say `moved` and end with `inv` (free
  slots, what you hold of the items moved); a move over time says `timed`, and `last.moved`/`last.inv` when it ends;
  a give the target could not take all of (full), or a courier that delivered less than it took, ends with a `short`
  warning naming what fills the target's slots and what you still carry;
  queue and standing-order history entries carry both. `feed`, `collect` and `transfer` take `area {left_top,
  right_bottom}` for every machine (or chest) inside it; `inspect` of a machine shows `output_fill` (and `full`) and `output_stop`: where each product stops it, and whether a `full_output` is a full output or a machine short of an ingredient holding a few crafts' worth (the game reads it so).
  `feed` gives a burner fuel when its fuel slots are empty, or with `fuel` (`true` or a fuel name); a furnace with no
  recipe yet takes the `item`/`items` it smelts; each named machine gets a row (`gave` or `got`, and its `fuel`).
- Out of reach within 32 tiles, `transfer`, `collect`, `feed`, `rearm`, `refuel`, `mine`, `build`, `rotate` and
  `configure` (modules by hand, a recipe change on a stocked machine) walk into reach first and then act, the reply's
  `walking` line saying so; past 32 tiles the refusal names the same call with `"walk": true`; `"walk": false` refuses.
  The destination is checked for enemies again when the call starts; a new worm in a previously clear area is included.
- Mining walks use resource reach (2.7 tiles) for ore, trees, plants and rocks; buildings and laid tiles use entity reach (10). Queue steps use the same reaches.
- Reach is measured to an entity's edge. `rotate` is one
  90-degree turn clockwise (`reverse` counter-clockwise, `direction` a facing to turn to) and replies `before`/`after`.
  `mine` at a mined-out resource tile mines the nearest tile of the same resource within `radius` (default 8), one in
  reach first, and names it in `instead`. `fh research` times (`done_in`) use the last minute's lab throughput.
  `repair` on an undamaged entity is ok with `unchanged: "not damaged"`; `repair` takes `positions` or `area` and
  reports `repaired` and `already_full`.
- Items on the ground: scan and observe sum them up by item (ground_items); status alerts.ground_items names full
  landing pads that spill and piles near buildings; deconstruct {area, items_on_ground: true} marks them for
  construction robots; pickup {area | position, radius, items} picks them up by hand (timed).
- `./fh call pickup --args '{"belt":true,"item":"iron-plate","count":200,"position":{"x":90.5,"y":-11.5}}' --wait` takes
  items off belt lanes by hand (from belts within 1 tile, walking to them; areas on the map too; `"to":{x,y}` puts them in that chest at the end of the same walk).
- `feed` tops up every machine in reach (or `"radius":20` to walk a line) with its recipe ingredients, lab science
  packs and burner fuel; `keep` holds back a reserve. Use it instead of one `transfer` per machine.
- `collect` takes machine outputs only; it leaves chests alone unless you name their positions or pass `chests:true`.
- `collect {position, item, count, wait_ticks}` says which inserters take the machine's output and the chest they fill (`taken_by_inserters`); `follow: true` takes from that chest instead of waiting.
- `collect {"position":{"x":10.5,"y":3.5},"wait_ticks":1800}` stands at that machine and takes each product the tick it
  appears (`"count"` stops early); `last.took`, `last.made` and `last.inserters_took` (counted) say who got what, and
  `last.why` why it took none. A tell or board line shown in a sleep reply that your next sleep followed within 5 s
  comes again in `team.missed_while_asleep`. `place_ghosts` and `scan` take `"surface": "vulcanus"` (remote view).
- `feed {clear_spoilage:true}` clears spoiled recipe waste and burnt results before top-ups, also walking; `entities.cleared` reports taken/left. `collect {outputs_only:true}` reads/takes machine outputs only, never fuel.
- `refuel {area|radius,from:"nearest"|chest_position,fuel,count}` collects fuel from observed chests/belts and tops up burners in one enemy-checked tour; `--wait` waits through it, `last.sources`/`fuel_taken` report takes.
- `feed` takes `position` with `radius` (its centre); `feed {area}` over 64 machines walks one tour; `refuel {from: "nearest", from_radius: 128}` looks farther for fuel. `refuel {radius, from: "nearest", feed_chests: true}` fills the chests that inserters feed boilers from.
- What you take over a personal request's max goes to your trash slots: `transfer`, `collect` and `pickup` say how much
  (`trash`); `"up_to": true` stops at the max, `"keep_max": true` refuses the take. A paste leaves the requests of a hub
  or requester chest it lands on (`requests_kept`), a hub's construction requests too.
  `./fh call requests --args '{"platform":"Starling","construction_requests":true}'` switches the hub's Request missing
  construction materials on.
- Hand-mining ore yields one ore per cycle (2 s for iron); `last.mined` counts it. Rocks give stone and coal fast.
- A burner's fuel slot holds one fuel type: you cannot add coal while wood remains.
