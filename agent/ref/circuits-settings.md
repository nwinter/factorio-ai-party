- `circuit_set {position, platform? | surface?, enable | logistic | read | settings | signals | on | arithmetic |
  decider | selector | set_requests}`: sets an entity's circuit condition, read switches, settings or combinator, in
  reach or by remote view (our entities in visible chunks, all of a platform); `inspect` reads back the conditions,
  settings, each wire's far end and the signals on each network now. After the call it says `stays disabled` when one
  of the entity's conditions is not met; a circuit condition counts only with a red or green wire on the entity
  (without one the game ignores it, and the line says `condition ignored`). `switch_off: true` sets a condition that
  never holds (`signal-dot < -2147483648`): the entity stops while a wire connects it; `remove_condition: true` takes
  the condition away: it runs whatever its wires read; `enable: false` is refused naming both; `now` says what the
  entity does after either. A logistic condition reads the network
  whose logistic area holds the entity's centre (`logistic_reads`; `none`: never met). The game's network count is what
  the network holds less what deliveries have reserved: under 0 (`network count -2: reserved beyond stock`) a
  condition such as `bioflux >= 0` is false; a wire from a provider or storage chest reads what that chest holds
  (`circuit_gate {source: the chest}`). inspect, supply's gate line and the off_by_condition alert say the same.
  - Decider rows keep AND and OR as given: `"conditions":["signal-A > 0","and iron-plate < 150"]` (a row after the
    first must say and or or), `{signal, comparator, value, compare, first_networks: "red"}`, or the game's own rows
    (`first_signal`, `constant`, `compare_type`); outputs `{signal, copy_input: true}` (the input count) or `{signal,
    constant: 1}`, with `networks`. The read shows `AND iron-plate < 150 [reads red+green]` and `signal-B = constant 1
    [from red+green]`.
  - Requester and buffer chests: `read: {contents: true}` or `set_requests: true`, and `enable` (the chest's circuit
    condition); provider chests send contents whenever wired; no chest has a logistic condition. A roboport: `read:
    {logistic_network_contents: true}`.
  - `settings: {filters, filter_mode}` sets inserter and loader filters as `configure` does. A belt's
    `read_contents_mode`: pulse, hold (this tile), entire_belt_hold (the whole belt); inspect's `belt_segment` names
    the physical segment and the whole belt apart (the whole belt as the harness follows it), beside what the wires
    read now (the game's own signal; a read switched on this tick shows from the next), and the belts on those
    networks that read their contents with each one's mode (this one marked; `belt_readers`) and the other entities
    on them.
  - An unknown argument's refusal names the closest valid name and what that entity takes (on `configure` too).
  - Quality: every signal is `"name"`, `"name@quality"` (`"iron-plate@uncommon"`), `"type:name@quality"` or `{type?,
    name, quality?}`; a `signals` entry `{signal, count, quality?}` and a decider output `{signal, quality?, ...}` take
    `quality` too. Left out it is normal; a quality our force has not unlocked is refused. Reads show `name@quality`.
    A landing pad with circuit `set_requests` requests each item at its signal's quality.
  Example: `./fh call circuit_set --args '{"platform":"Starling","position":{"x":-2.5,"y":-4.5},"enable":"ice < 300"}'`
- `wire {from, to, color?, from_side?, to_side?, disconnect?, platform? | surface?}`: connects and removes red, green
  and copper wires (no `color`: copper), in reach or by remote view as `circuit_set`; `inspect` reads each wire's far
  end. Example: `./fh call wire --args '{"from":{"x":10.5,"y":4.5},"to":{"x":12.5,"y":4.5},"color":"red"}'`
- `circuit_gate {position, all, at?, source?}`: two or more tests on one entity, the game's way: a decider combinator
  from your inventory, placed in your build reach within wire reach of the entity and the source (`at` names the
  tile), its conditions every test of `all` joined by and, output signal-check 1; the source (default: the roboport of
  the entity's logistic network nearest it, set to read its network's items) on a red wire into it; its output on a
  green wire to the entity, enabled when signal-check > 0 (a logistic condition on it is turned off). The steps are
  build, circuit_set and wire calls, in order; one that fails stops it, naming what was done and the calls left. No
  decider held or no tile that fits: refused before anything, with the calls.
  Example: `./fh call circuit_gate --args '{"position":{"x":-17.5,"y":30.5},"all":["bioflux > 200","agricultural-science-pack < 500"]}'`
- `gates {surface? | area?, page?}`: every circuit and logistic condition on our entities there (a surface: those the
  census's last pass found with a control behavior; an area up to 128x128: read now), 128 entities a call: the
  condition, what it reads now (the signal on its wires, the logistic network's count), true or false now, off by it.
  A logistic condition `item > N` (or `>=`, `=`) above what the network can hold (its count and what its storage and
  provider chests could still take of the item) comes first as `CANNOT BE MET:`, then those not met now. A look at
  the chests stops at 256 a network and item and 512 a call; one cut short gives what it saw and is not flagged.
  A logistic condition false now adds `the count:` where the network's count sits: storage, passive and active
  providers and buffers (the network's supply counts); what robots have reserved for pickup at its provider points and
  what its requester chests hold, neither of which the count includes. On world n the steel count of network 243 was
  its provider chests' steel less the reserved pickups, plus its buffers. `bottleneck` gives the same for a link held
  off by a condition (its first gated maker).
  Example: `./fh call gates --args '{"surface":"nauvis"}'`
- `circuit_audit {area | positions | platform, inserter?, surface?}` (`surface` with area or positions: those networks
  on another planet by remote view; entities out of sight now are not read, `out_of_sight` counts them): with `area` (up to 128x128) or `positions` (1..64), `platform`
  optional: every red and green network those entities are on, by id, each with its signals now (largest first) and
  which of them are on it with their settings, in one call. With `platform` alone: whole-belt readers
  (`entire_belt_hold`) on one network whose belts overlap (counted twice); each whole-belt reader whose read is shorter
  than the belt in line through it (the game reads the reader's belt segment), with the belts left out upstream and
  downstream, undergrounds crossed (`short_reads`); and each asteroid collector whose filter the circuit sets: the
  filter it holds and the chunk signals there. `feeders` (and `feeder_rows`): each inserter or loader whose filters the
  circuit sets or which it turns on and off, on the platform or among the entities of `area` or `positions` (the first
  8; `inserter: {x, y}` reads one): its filter mode, what it takes now and its pickup, the signals on its
  networks, the combinators putting out onto them and what their inputs read (3 deep), constant combinators, the hub's
  own read apart, and each belt reader there: its mode, the belts its count covers (whole belt: the game's segment,
  in flow order, from where to where), what it holds now of what the inserter takes, the belts of it past the
  inserter's pickup (it cannot take what they hold), and belts side-loading inside the count (upstream of the pickup
  said).
- `configure {position | positions, platform? | surface?, recipe?, quality?, modules?, by?, filters?, filter_mode?,
  use_filters?, spoil_priority?, hand_size?, storage_filter?, input_priority?, output_priority?, filter?, priority_targets?,
  ignore_unprioritised?, auto_targeting?, auto_requests?, send_to_orbit_automatically?, speaker_alert?, description?, bar?}`: a machine's or building's
  settings, as its GUI sets them; `inspect` reads each back.
  - `item_requests: false` (or `ammo: false` on a built turret): a built entity's item requests removed, every one on
    it, as a deconstruction planner over it and a cancel of that deconstruction do (`removed` per entity).
  - `recipe` (with `quality`): out of reach (or with `platform` or `surface`) by remote view in any visible chunk,
    where it changes an empty idle machine only; a machine holding items or mid-craft is walked into reach first, and
    what it held comes to your inventory (the reply says `moved` and ends with `inv`). A remote refusal never walks the body. Aboard,
    `configure {position, recipe}` uses the platform you are on. A fluid the machine holds that the new recipe takes
    none of: the change is refused naming it. In 2.0.77 a recipe change drops such a fluid (input or output box) and
    keeps one the new recipe takes; a machine's box has no pipe segment to flush. `fluid: "drain"` (or `"keep"`,
    `force: true`) makes the change; the reply's `fluid` and `fluid_flushed` say how much left the machine and anything
    still in it.
  - Set recipe on (`circuit_set_recipe`): the game sets the recipe from the red and green wires and ignores one set by
    hand, so `configure recipe` is refused saying so. It takes `recipe:NAME` above 0 at its quality (the lowest recipe
    order among several), else an item signal picks a recipe making it. After the wires change the recipe, the old
    recipe's items go to the machine's dump slots (`assembling_machine_dump`) and it has no recipe until they are
    empty. inspect's `circuit_recipe` says what the wires give and why it has none.
  - `modules: ["speed-module-2","speed-module-2"]` sets a machine's module slots: the modules it already holds that
    the list names stay in their slots, the rest go into the other slots (past the list: empty);
    `["keep","efficiency-module","empty"]` goes slot by slot and `{"2":"efficiency-module"}` changes only slot 2. In
    reach by hand (old ones to your inventory), else (remote, `surface`, `platform`, or `by: "robots"`) an item
    request robots or the platform hub carry out; on a ghost its requests. `inspect` reads them back (`by_slot`).
    `transfer {position, item: <module>}` also puts a module in a machine's or beacon's module slots.
  - Inserters and loaders: `filters`, `filter_mode` (or `mode`), `use_filters` (shown in `scan` rows: `filters:
    whitelist: iron-plate`, `off`, `set by circuit`); `hand_size: N` sets an inserter's stack size override, as
    its GUI does (1 up to its hand size now; 0 or false for none); `spoil_priority: fresh_first | spoiled_first | none` sets an
    inserter's Spoil priority (built or ghost).
  - `bar: N` sets a chest's, logistic chest's, cargo wagon's or landing pad's red-X bar (N usable slots; `false`: none);
    items past it stay, new ones go only under it. A crafting machine's output has no bar in 2.0.77 and its GUI no
    output limit: with nothing taking from it, it holds one stack. `bar` on one is refused, naming its output inserters,
    the chests they fill and its own logistic condition (`circuit_set logistic`).
  - `storage_filter: "efficiency-module"` sets a storage chest's filter (robots store no other item in it);
    `input_priority`, `output_priority`, `filter` set a splitter's (left and right facing the way items move).
  - Turrets: `priority_targets: ["big-metallic-asteroid", ...]` with `ignore_unprioritised: true` sets a turret's (or
    ghost's) priority list as its GUI does, on one or `positions`; blueprints keep it. A turret ghost's targeting
    (configure, or `configure` on a `place_ghosts` entry) is checked once it is built: a turret that reads otherwise
    is set to the ghost's, and you are told. A railgun's reply adds `line_of_fire` (as platform_defense). Artillery: `auto_targeting: false` switches automatic targeting off.
  - A programmable speaker: `speaker_alert {show_alert?, show_on_map?, message?, icon?, condition?}` sets its GUI's
    alert part (the rest kept; `icon: false` clears it) and its circuit condition (`"rocket-part < 1"`); the reply
    reads them back with whether the condition holds now. It alerts while the condition holds: `game_alerts {kind:
    "speaker"}`, the team block and `fh wait --until "alert speaker"` tell it. `speaker_alert {speaker_sound: {volume?
    (0..1), mode? (local|surface|global), polyphony?, instrument?, note?}}` sets its GUI's sound settings (instrument and
    note by name, `"alarms"`, `"siren"`, or number from 0); the reply's line ends `sound: alarms/alarm-1 at volume 100%,
    local` or `sound: off (volume 0)`.
  - An arithmetic, decider, selector or constant combinator (built or ghost): `description` (up to 500 bytes, newlines
    kept; `""` or `false` clears it) sets the description its GUI shows; `circuit_set` takes it too. `inspect`, `circuit`
    and `circuit_set` replies show it as `description`; blueprints keep it, and a ghost placed from one has it.
  - A rocket silo: `auto_requests` and `send_to_orbit_automatically`; with `surface` (a planet) and `position` it acts
    there by remote view where our force sees the chunk. Switching automatic requests on moves cargo loaded by hand
    into the silo's trash slots, which never launch: `auto_requests: true` is refused while the rocket holds cargo no
    platform stopped above asks this planet for, naming it (`force: true` switches them on anyway); `silo` lists the
    trash slots. A silo's ghost takes both too (a place_ghosts entry's `configure` among them), and the silo built from it keeps them.
  Example: `./fh call configure --args '{"position":{"x":23.5,"y":73.5},"recipe":"electronic-circuit"}'`
- `assembler_batch {position, count, requester?, input?, output?, dry_run?}`: a finite batch of a machine's recipe as one
  queue plan, each step a call whose reply says what it did: the output inserter held (logistic `PRODUCT < -2147483648`, false at any count) and the
  input inserter held; the requester feeding it cleared, then asked for exactly what the batch still needs of each
  ingredient (crafts x amount less what the machine and the requester hold now); waits for it; requests cleared; the
  input on; waits for the products in the machine; the input off again; the output released. The requester and both
  inserters are found round the machine unless given. `surplus` names what is already there over the batch's need
  (the machine would make more with it). The inserters need a logistic network for their logistic condition. A
  requester with trash unrequested on has it switched off before its requests are cleared and staged, and on again
  after the output is released (`trash_unrequested` in the reply; a plan stopped between leaves it off). The recipe's
  quality (`quality`) goes on every item ingredient's request and wait and on the product wait (fluids have none); a
  machine whose modules give quality has its product wait count every quality. `other_quality`: what the requester
  holds of an ingredient at another quality (the machine does not take it).
  Example: `./fh call assembler_batch --args '{"position":{"x":107.5,"y":-94.5},"count":8,"dry_run":true}'`
- `requests {position | platform?, set?, clear?, clear_all?, section?, active?, add_section?, remove_section?, group?,
  trash_unrequested?, construction_requests?, keep?, dry_run?, force?, surface?}` or `{groups: true}`: a
  requester or buffer chest's requests (`position`), a platform hub's (`platform`), or your own (no position; needs
  logistic robotics). `set` takes a list or a map `{item: min}`; an entry is `{item, min, max?, quality?, from?,
  min_payload?}` and any other field is refused (as in every record list: signals, builds, entities, stops); an entry
  without `max` keeps the slot's max (`"max":
  "inf"` sets none). An edit echoes what is stored per item (`stored`) and keeps the import planet when `from` is not
  given. `from: false` (or `""`) drops it; the game stores `nauvis` for a hub request with no import planet, a new
  slot's too, and `stored` says so (16 new slots set with none read back `from nauvis`, platforms at Fulgora among
  them). Such a request keeps its stock only at Nauvis. A `set` without `section` edits the slot of the section that already requests the item (`sections_note`
  names a shared group or a second section). `clear` (or `remove`): `["pumpjack"]` deletes the request and keeps what
  you hold; a personal `max` under what you hold is refused without `force: true` (the game trashes the rest). With
  `surface` (a planet) and `position` it acts there by remote view where our force sees the chunk.
  `trash_unrequested: true` sets the trash-unrequested switch of a requester or buffer chest, a hub or your own
  logistics: robots take to storage what it holds that no request names (spoilage among it); the reply's
  `trash_unrequested` names what the chest holds that goes. A passive provider, active provider or storage chest has no
  such switch: robots take spoilage from it only to a requester or buffer that requests spoilage, and an inserter
  filtered to spoilage moves it into the chest it drops into.
  - A hub: each section with `active: "on"` or `"off"` (`off: true` too when it requests nothing; `"section":N,"active":true`
    switches it on), and each
    request's import planet; `construction_requests: true` switches the hub's Request missing construction materials
    on. A set entry's `min_payload` is the custom minimum payload; an edit that does not name it keeps it, and one
    removed by `clear` or `clear_all` comes back when the item is set again without it (`min payload N kept from the
    request cleared before`); `min_payload: false` clears it. At a stop the hub keeps what its requests importing
    from that planet ask; the rest that the landing pads there ask for (their ask less what they hold) goes down. A
    request from another planet keeps nothing there: Cinder at Nauvis sent all 85 foundation down under `50..inf from
    fulgora`, while Swift at Nauvis kept 501 magazines under `500..2000 from nauvis`. A change of what its requests keep
    gives `sends_down`: per item, what they would keep and kept by planet, and how many go down to which stop's pads
    (where it waits first, then its schedule's) or stay aboard. `keep: ["firearm-magazine"]` keeps
    those requested up to the count held (with the dropped request's import planet and min payload). `dry_run: true`
    changes nothing and replies with the sections, `stored` and `sends_down` the change would make; on a requester,
    a buffer chest or yourself, `robot_dispatch`: the logistic robots' trips for what it would ask beyond what it holds
    (from the chest the network would take each from; how many at once, from where, how far, past which enemies).
  - Sections and groups, as the logistics GUI: `add_section: true` adds a manual section (`set`, `clear`, `active` in
    the call go to it); `remove_section: N` removes one with its requests (alone; a dry run reads it switched off).
    `section: N, group: "name"`: a group that exists replaces the section's requests with the group's (`dropped` names
    what goes); a new name makes the group from the section's requests; `group: false` leaves it keeping a copy. An
    edit in a section of a group changes every member: `group_edit` names each other one, a dry run too. `groups: true`
    lists our groups with their requests and members. There is no setting that stops a hub unloading: at each stop it
    keeps only what its requests from that planet ask, so a reserve kept at every port is one section per port, each
    requesting the item `from` that port.
  - Sections the game writes are `controlled: true` in every row, with `controlled_by`: a hub's construction requests,
    a silo's automatic requests, or the circuit network. The game refuses a write to one; the refusal names the same
    call with `add_section: true`, a new manual section that keeps the requests.
  - Your own: `unfilled` lists the personal requests not filled, each with why (personal logistics off, no slot of
    yours takes the item, no network where you stand, no logistic robots, none free, none of the item in the network).
    A request counts what your main inventory, gun, ammo and armor slots hold.
  Example: `./fh call requests --args '{"platform":"Starling","construction_requests":true}'`
- `character_settings {personal_logistics?, personal_roboport?, movement_bonus?, filters?}`: your character GUI's
  switches (each true or false: personal logistics, the master switch of your requests; the personal roboport; the
  equipment movement bonus) and main inventory slot filters (`filters: [{slot, item, quality?}]`, `item: false`
  clears one; a slot holding an item takes a filter for that item only). An edit changes only what it names and
  replies `changed` ("personal roboport on -> off"). Every reply reads them all, with `networks`: the logistic network
  your requests go to, the construction areas covering you, your personal roboport (robots in your inventory, energy),
  `not_dispatched` (switches off, no free slot) and `unfilled` as `requests` gives it.
  Example: `./fh call character_settings --args '{"personal_roboport":false}'`
- Logistics: roboports are placed with `build` and robots put into them with `transfer`; requester and buffer chests'
  requests and your own are set with `requests`.
- Quality: `configure {recipe, quality}`; `quality` on build, transfer and requests.
