- Circuits: circuit_set {position, platform?, enable | logistic | read | settings | signals | arithmetic | decider |
  selector}; wire {from, to, color: red|green, or none for copper}; inspect reads both back (in reach or by remote
  view, all of a platform).
- `circuit_audit {area}` (up to 128x128) or `{positions}` (1..64), `platform` optional: every red and green network
  those entities are on, by id, each with its signals now (largest first) and which of them are on it with their
  settings: one call instead of an inspect each.
- Decider rows keep AND and OR as given: `"conditions":["signal-A > 0","and iron-plate < 150"]` (a row after the first
  must say and or or), `{signal, comparator, value, compare, first_networks: "red"}`, or the game's own rows
  (`first_signal`, `constant`, `compare_type`); outputs `{signal, copy_input: true}` (the input count) or
  `{signal, constant: 1}`, with `networks`. The read shows `AND iron-plate < 150 [reads red+green]` and
  `signal-B = constant 1 [from red+green]`.
- Circuits: `./fh call circuit_set --args '{"platform":"NAME","position":{"x":-2.5,"y":-4.5},"enable":"ice < 300"}'`
  sets an entity's circuit condition, read switches, settings or combinator, in reach or by remote view (our entities
  in visible chunks, all of a platform); `wire` connects and removes red, green and copper wires the same way; `inspect`
  reads back the conditions, settings, each wire's far end and the signals on each network now. A logistic condition
  reads the network whose logistic area holds the entity's centre (`logistic_reads`; `none`: never met).
  Requester and buffer chests: `read: {contents: true}` or `set_requests: true`, and `enable` (the chest's circuit condition); provider chests send contents whenever wired; no chest has a logistic condition. A roboport: `read: {logistic_network_contents: true}`.
- Logistics: roboports with build, robots into them with transfer; requester and buffer chests' requests with
  requests {position, set}; your own requests with requests (needs logistic robotics).
- `requests` (your own) lists `unfilled` personal requests, each with why (no network where you stand, no logistic robots, none free, none of the item in the network).
- Modules and beacons: transfer {position, item: <module>} puts it in the machine's or beacon's module slots.
- Modules: `configure {position | positions, modules: ["speed-module-2","speed-module-2"], by?}` sets a machine's module
  slots: the modules it already holds that the list names stay in their slots, the rest go into the other slots (past
  the list: empty); `["keep","efficiency-module","empty"]` goes slot by slot and `{"2":"efficiency-module"}` changes
  only slot 2. In reach by hand (old ones to your inventory), else (remote, `surface`, `platform`, or `by: "robots"`) an
  item request robots or the platform hub carry out; on a ghost its requests. `inspect` reads them back (`by_slot`).
- Quality: configure {recipe, quality}; quality on build, transfer and requests.
- `configure {position, storage_filter: "efficiency-module"}` sets a storage chest's filter (robots store no other item
  in it); `configure {position, input_priority, output_priority, filter}` sets a splitter's (left and right facing the
  way items move); `inspect` shows both.
- Turret targeting: `configure {position | positions, platform?, priority_targets: ["big-metallic-asteroid", ...],
  ignore_unprioritised: true}` sets a turret's (or ghost's) priority list as its GUI does; inspect reads it back;
  blueprints keep it.
- `configure {platform | surface, position, recipe}` changes an empty idle machine remotely; a remote refusal never walks the body. Aboard, `configure {position, recipe}` uses the current platform. `belt_route` follows an existing belt chain from `from` to its open end and names blocked connection tiles.
- A belt's `read_contents_mode`: pulse, hold (this tile), entire_belt_hold (the whole belt); inspect's
  `belt_segment` names the physical segment and the whole belt apart, beside what the wires read.
