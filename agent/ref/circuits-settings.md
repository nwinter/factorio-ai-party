- `circuit_set {position, platform? | surface?, enable | logistic | read | settings | signals | on | arithmetic |
  decider | selector | set_requests}`: sets an entity's circuit condition, read switches, settings or combinator, in
  reach or by remote view (our entities in visible chunks, all of a platform); `inspect` reads back the conditions,
  settings, each wire's far end and the signals on each network now. After the call it says `stays disabled` when one
  of the entity's conditions is not met; a circuit condition counts only with a red or green wire on the entity
  (without one the game ignores it, and the line says `condition ignored`). A logistic condition reads the network
  whose logistic area holds the entity's centre (`logistic_reads`; `none`: never met).
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
    the physical segment and the whole belt apart, beside what the wires read.
  - An unknown argument's refusal names the closest valid name and what that entity takes (on `configure` too).
  Example: `./fh call circuit_set --args '{"platform":"Starling","position":{"x":-2.5,"y":-4.5},"enable":"ice < 300"}'`
- `wire {from, to, color?, from_side?, to_side?, disconnect?, platform? | surface?}`: connects and removes red, green
  and copper wires (no `color`: copper), in reach or by remote view as `circuit_set`; `inspect` reads each wire's far
  end. Example: `./fh call wire --args '{"from":{"x":10.5,"y":4.5},"to":{"x":12.5,"y":4.5},"color":"red"}'`
- `circuit_audit {area | positions | platform}`: with `area` (up to 128x128) or `positions` (1..64), `platform`
  optional: every red and green network those entities are on, by id, each with its signals now (largest first) and
  which of them are on it with their settings, in one call. With `platform` alone: whole-belt readers
  (`entire_belt_hold`) on one network whose belts overlap (counted twice); each whole-belt reader whose read is shorter
  than the belt in line through it (the game reads the reader's belt segment), with the belts left out upstream and
  downstream, undergrounds crossed (`short_reads`); and each asteroid collector whose filter the circuit sets: the
  filter it holds and the chunk signals there.
- `configure {position | positions, platform? | surface?, recipe?, quality?, modules?, by?, filters?, filter_mode?,
  use_filters?, spoil_priority?, storage_filter?, input_priority?, output_priority?, filter?, priority_targets?,
  ignore_unprioritised?, auto_targeting?, auto_requests?, send_to_orbit_automatically?}`: a machine's or building's
  settings, as its GUI sets them; `inspect` reads each back.
  - `recipe` (with `quality`): out of reach (or with `platform` or `surface`) by remote view in any visible chunk,
    where it changes an empty idle machine only; a machine holding items or mid-craft is walked into reach first, and
    what it held comes to your inventory (the reply says `moved` and ends with `inv`). A remote refusal never walks the body. Aboard,
    `configure {position, recipe}` uses the platform you are on.
  - `modules: ["speed-module-2","speed-module-2"]` sets a machine's module slots: the modules it already holds that
    the list names stay in their slots, the rest go into the other slots (past the list: empty);
    `["keep","efficiency-module","empty"]` goes slot by slot and `{"2":"efficiency-module"}` changes only slot 2. In
    reach by hand (old ones to your inventory), else (remote, `surface`, `platform`, or `by: "robots"`) an item
    request robots or the platform hub carry out; on a ghost its requests. `inspect` reads them back (`by_slot`).
    `transfer {position, item: <module>}` also puts a module in a machine's or beacon's module slots.
  - Inserters and loaders: `filters`, `filter_mode` (or `mode`), `use_filters` (shown in `scan` rows: `filters:
    whitelist: iron-plate`, `off`, `set by circuit`); `spoil_priority: fresh_first | spoiled_first | none` sets an
    inserter's Spoil priority (built or ghost).
  - `storage_filter: "efficiency-module"` sets a storage chest's filter (robots store no other item in it);
    `input_priority`, `output_priority`, `filter` set a splitter's (left and right facing the way items move).
  - Turrets: `priority_targets: ["big-metallic-asteroid", ...]` with `ignore_unprioritised: true` sets a turret's (or
    ghost's) priority list as its GUI does, on one or `positions`; blueprints keep it. A turret ghost's targeting
    (configure, or `configure` on a `place_ghosts` entry) is checked once it is built: a turret that reads otherwise
    is set to the ghost's, and you are told. Artillery: `auto_targeting: false` switches automatic targeting off.
  - A rocket silo: `auto_requests` and `send_to_orbit_automatically`; with `surface` (a planet) and `position` it acts
    there by remote view where our force sees the chunk.
  Example: `./fh call configure --args '{"position":{"x":23.5,"y":73.5},"recipe":"electronic-circuit"}'`
- `requests {position | platform?, set?, clear?, section?, active?, construction_requests?, force?, surface?}`: a
  requester or buffer chest's requests (`position`), a platform hub's (`platform`), or your own (no position; needs
  logistic robotics). `set` takes a list or a map `{item: min}`; an entry without `max` keeps the slot's max (`"max":
  "inf"` sets none). An edit echoes what is stored per item (`stored`) and keeps the import planet when `from` is not
  given; a `set` without `section` edits the slot of the section that already requests the item (`sections_note`
  names a shared group or a second section). `clear` (or `remove`): `["pumpjack"]` deletes the request and keeps what
  you hold; a personal `max` under what you hold is refused without `force: true` (the game trashes the rest). With
  `surface` (a planet) and `position` it acts there by remote view where our force sees the chunk.
  - A hub: each section, `off: true` when it requests nothing (`"section":N,"active":true` switches it on), and each
    request's import planet; `construction_requests: true` switches the hub's Request missing construction materials
    on.
  - Your own: `unfilled` lists the personal requests not filled, each with why (no network where you stand, no
    logistic robots, none free, none of the item in the network).
  Example: `./fh call requests --args '{"platform":"Starling","construction_requests":true}'`
- Logistics: roboports are placed with `build` and robots put into them with `transfer`; requester and buffer chests'
  requests and your own are set with `requests`.
- Quality: `configure {recipe, quality}`; `quality` on build, transfer and requests.
