- Circuits: circuit_set {position, platform?, enable | logistic | read | settings | signals | arithmetic | decider |
  selector}; wire {from, to, color: red|green, or none for copper}; inspect reads both back (in reach or by remote
  view, all of a platform).
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
