# Progressive disclosure: the kit grows with each team (d28 batch317)

Status:
- cp1 (design and inventory) was reviewed by the operator d28 14:28.
- cp2 builds it: per-force state, triggers, open-set read, filtered help and describe, the unlock line, the operator
  read, and observe mode. It is off by default: world n is unchanged unless a run sets it.
- Waiting for Nick (choices 5 and 6 below): splitting reference entries, rewriting PLAYBOOK.md and team.md. Alerts
  still fire as before. Their `self` conditions are inventoried, but nothing gates them yet (see "Not built yet").

## What agents get without it, and the goal

Every agent gets the whole kit from tick 0, wherever its team stands:
- 235 actions and 1652 arguments in describe.json (535 KB);
- nine reference topics (328 KB in 262 entries);
- a 20.9 KB core (AGENTS.md) whose index lists every command;
- 238 kinds of alert, wake, reply line and nudge.

The goal (Nick, d28) is a small kit at tick 0 for the simple early game. Tools, arguments and docs then open per team
(force) as its research, buildings, encounters and habits call for them, the way Factorio's tips appear.

The rules stay:
- **Facts only:** an unlock says what opened and what it does, never what to build.
- **Survival-fair:** the same conditions for every team.
- **Per force:** one team's unlocks never reach another. In main the key is the player force; with several teams it
  is the agent's own force.
- **world n keeps its whole kit:** the mode is off unless set.

## Using it

- **A run:** `POG_DISCLOSURE=1 tools/start-team.sh ...` sets the world's mode to filter after the runtime is deployed
  (tools/disclosure/set.py). It then saves the player force's open set to runs/RUN/disclosure-open.json and exports
  POG_DISCLOSURE_OPEN, so tools/brief.py writes each workspace from it.
  - `POG_DISCLOSURE=observe` keeps the state without filtering, and 0 turns it off.
  - Unset leaves the world's mode as its save has it.
  - The mode lives in the save and carries across shifts.
- **By hand:** `python3 tools/disclosure/set.py --world W --mode filter|observe|off [--team] [--stream] [--humans]
  [--refuse|--allow] [--reset] [--open FILE]`. `--read` gives each force's line, its newest unlocks with tick and
  cause, and the next thresholds with the counts so far.
- **Operator calls:**
  - `disclosure_set {mode, refuse?, world?, reset?}`;
  - `disclosure {force?, ids?}`: per force rev, world flags, open counts, met atoms with ticks, the newest 8
    unlocks, next thresholds, and with ids the open names and ids.
- **The host's read:** `disclosure {}`, an action marked never. It gives the caller's force's open action names,
  shut arguments by action, and the open and shut reference entry ids (topic#key) and brief item ids (file#key).
  fh help TOPIC and the brief show everything not shut.
- **Ids:** an entry or brief item is keyed by its own lead: `building#belt_route` for an entry that starts with
  `belt_route`, else its first four words (`moving-items#game-rule-ghosts`).
  - An edit elsewhere in a file keeps every other id.
  - An action, entry or item that the runtime's table does not know yet (added by a later batch) stays open until
    build.py is run again and rules.py gives it a condition. Readers use the shut lists.
- **The inventory:** `python3 tools/disclosure/build.py [DESCRIBE_JSON]`.
  - It writes tools/disclosure/manifest.json and the runtime's table,
    vendor/factorio-harness/mod/agent-harness_0.1.0/disclosure_units.lua, in which each condition's with: atoms
    are expanded.
  - It prints the sizes.
  - `--check` says whether both are current.
- **Threshold replay:** `python3 tools/disclosure/replay.py RUNS SHIFT...` replays journals through the habit counters.

## What an agent sees in filter mode

- **The core:**
  - only open items of PLAYBOOK.md, team.md and compact.md;
  - an index that lists open commands only;
  - one added line: "Your team's tools grow with it: an action, argument or reference entry opens when the team has
    researched, built, met or done what it needs, the same for every team. A reply's `new:` line names what opened;
    describe.json, `./fh help` and `./fh help TOPIC` show what is open now." With refuse=true it adds: "A call to one
    not open yet is refused, naming what opens it."
- **ref/TOPIC.md:** the entries open at launch. `./fh help TOPIC` reads ref/.units/TOPIC.json and the runtime's open
  set, so an entry shows up the moment it opens.
- **describe.json and `./fh help ACTION`:**
  - they show open actions and open arguments only;
  - `locked` names each shut action with its condition;
  - `./fh help belt_route` says `belt_route is not available yet: it opens when your team has placed 10 belts with
    build, or when your team has 40 belts`;
  - fh writes describe.json again after a reply that carried a `new:` line.
- **A call to a shut action or argument:** it runs, undocumented: the default since Nick's answer of d28 15:47
  ("probably ok to run").
  - With `refuse=true` (`set.py --refuse`), it is refused with the same text plus "(the same rule for every team;
    ./fh help lists what is open)". A shut argument then gets: `feed's argument quality is not available yet: it
    opens when your team has researched quality-module`.
  - Either way, the unknown-argument refusal's valid list leaves shut arguments out.
  - The `locked` list in describe, and fh help ACTION's condition, appear only with refuse=true.
  - Operator calls, reader calls, the host's own calls (describe, disclosure, sleep_check, lookahead, bridge_status)
    and actions marked never are not gated.
- **An unlock:** each agent of the force sees one `new` field on its next reply, newest first, then whatever opened
  with it.
  - The first four actions carry what they do: the first clause of their reference entry.
  - It also counts the newly opened arguments and entries, and names the topics.
  - An agent's first reply only sets its cursor.
  - On the copy, after a biter's first attack: `new: "danger (a destination before a trip), alerts_digest (enemy and
    structure alerts in one read: ...), damage_log (what hit our entities there), game_alerts (...), kite, repair,
    retreat_guard, use_item; 44 arguments of open actions (./fh help ACTION) and 10 reference entries; docs: ..."`.

## The vocabulary of conditions

A condition is a list of atoms:
- Its world atoms are a gate, and all must hold.
- Then any one of its other atoms opens the unit.
- A unit with world atoms only is in or out from tick 0.
- An argument also needs its action.

| Atom | Meaning | Detection (cp2) |
|---|---|---|
| `start` | in the kit at tick 0 | none |
| `world:FLAG` | space_age and quality (active mods), enemies (Nauvis not peaceful), team (bots in the force, or `--team`), stream, humans (set by set.py) | read when the open set is built |
| `research:TECH` | the force researched TECH | `on_research_finished` (already forwarded); the sweep reads the technologies too |
| `built:ENTITY` | the force has one of these entities | sweep: `force.get_entity_count` |
| `arrived:PLANET` | a platform of the force at the planet, or a character there | sweep: platforms' `space_location`, characters' surfaces |
| `event:KIND` | first seen by the force (15 kinds) | see below |
| `habit:KIND:N` | the force's agents' calls (11 kinds) | counted in M.dispatch after each agent call: no tick cost |
| `scale:KIND:N` | machines, labs, drills, belts, inserters, turrets, platforms, game hours | sweep: entity counts, platforms, game.tick |
| `with:UNIT` | opens with another unit | expanded into the runtime's table by build.py |
| `self` | an alert's own trigger | not gated yet |
| `never` | not agent-facing | never gated, never listed |

Events:
- **From `on_entity_damaged` and `on_entity_died`** (forwarded already; skipped once all fight atoms are met):
  - enemy_seen, spitters (spitters or medium-or-larger biters), worms, demolishers and pentapods, by the attacker's
    name;
  - attacked: the enemy force hits one of ours;
  - loss: the enemy force destroys a building of ours;
  - died: a character of ours dies;
  - asteroids: anything hits a platform entity of ours.
- **From the sweep:**
  - enemy_seen: an enemy entity within 64 tiles of one of our characters;
  - spoiled: spoilage made on any surface;
  - second_surface: a platform, or a character off Nauvis;
  - resource_depleted and low_power: pushalerts' out_of_ore, low_power and no_power groups.
- **From events:** pollution_attack (`on_unit_group_finished_gathering`) and freight (a cargo pod of ours finished
  descending).

Habits, as counted:
- **hand_crafts:** craft calls' counts per recipe.
- **hand_belts and hand_poles:** each belt or pole entry of a build call.
- **hand_feeds:** feed and refuel calls.
- **chest_moves:** transfer calls at one container position.
- **walked:** walk and move_to calls, the straight line from where the character stood.
- **refused:** refusals of the action itself; the unit is that action's dry_run and the like.
- **refused_builds:** refused build, place_ghosts and mine calls.
- **repeat_calls:** calls of one acting action with the same argument names, each within 10 game minutes of the one
  before.
- **sleeps:** sleep, wait_ticks and wait_until calls.
- **board_items:** board_post calls.

The gate's own refusals are not counted.

State: `storage.agent_harness.disclosure = {mode, refuse, world, forces={[name]={met, counts, keys, rev, log, told}}}`.
- Keyed habits keep at most 64 keys a kind.
- The log keeps the last 64 unlocks.
- The open set is cached per force and revision outside storage, and rebuilt after a load.
- A revision grows only when a new atom is met, or when a counter crosses a threshold some unit names.

Conditions per unit kind (atoms counted; a unit may have several):

| | start | world | research | built | arrived | event | habit | scale | with | self | never |
|---|---|---|---|---|---|---|---|---|---|---|---|
| actions (235) | 39 | 17 | 103 | 61 | 4 | 29 | 23 | 34 | 33 | | 5 |
| arguments (1652) | 16 | 13 | 143 | 45 | 18 | 220 | 76 | 5 | 1235 | | 1 |
| doc entries (262) | 5 | 13 | 73 | 60 | 9 | 4 | 2 | 8 | 178 | | |
| brief items (127) | 73 | 46 | 18 | 17 | | 5 | | | 4 | | 2 |
| alerts (238) | 57 | 114 | 1 | 1 | | | | | 31 | 143 | |

## Thresholds (choice 2): the replay of world n's first shifts

`replay.py runs shift01 shift02 shift03` covers 188,717 calls by nine agents. It shows when each habit threshold would
have been met, counted from the team's first call:

| Habit threshold | Met after |
|---|---|
| repeat_calls 5 and 10, refused_builds 2 and 3 | 1 min |
| chest_moves 5 | 4 min |
| sleeps 20 | 5 min |
| board_items 20, hand_feeds 10 | 6 min |
| sleeps 40, hand_feeds 20 | 8 min |
| hand_poles 4 (first value 8: 16 min) | 13 min |
| hand_belts 10 (first value 20, one or two entries a call: 95 min) | 30 min |

The team's own first calls in those shifts:
- pole_route at 8 minutes (8 calls before 13 minutes would have been refused);
- build_path at 8 minutes (6 refused before 30 minutes);
- belt_route at 17 minutes.

The replay's finding:
- Nine agents meet the per-force habit thresholds within minutes, so the queue, wait_until and the board tools open
  almost at once for a big team.
- The belt and pole thresholds were lowered (belts 10 counting every entry, poles 4) so they open close to when the
  team wanted them.
- Research, buildings and events are not in the journals. Those shifts started from a world with most research done.

## Sizes

Each row adds that milestone's conditions to the one before. The core is today's assembled core for a Claude agent
less the closed brief items, with the index cut to open commands. Today's core is 20,931 bytes. The disclosure line
adds about 330 bytes.

| Milestone | Actions | Arguments | describe.json bytes | Doc entries | Doc bytes | Core bytes |
|---|---|---|---|---|---|---|
| tick 0 | 54 | 350 | 95,643 | 56 | 67,917 | 16,768 |
| first hour: power, labs, a few drills and belts | 82 | 591 | 165,545 | 88 | 119,326 | 18,608 |
| mid game: oil, robots, circuits, trains, defense | 188 | 1236 | 281,368 | 181 | 191,682 | 19,978 |
| rocket and first platform | 224 | 1613 | 370,389 | 249 | 320,505 | 20,520 |
| every planet | 228 | 1637 | 374,776 | 260 | 326,323 | 20,567 |
| all (agent-facing) | 230 | 1652 | 375,908 | 262 | 327,590 | 20,931 |

## Costs (measured on the iMac copy)

- The sweep runs at tick % 600 == 41. Each run reads one of four parts in turn: research, buildings, scale counts, then
  places and events. It reads only atoms not met yet.
  - On a fresh Space Age map with two bots: 0.05-0.16 ms a sweep (all four parts in one sweep: 0.28-0.39 ms).
  - On world n's save (78.04 M ticks, 22 platforms, 27 surfaces) in observe mode: 0.18 ms over five sweeps in 50 s,
    against an average tick of 2.8 ms.
- The pieces:
  - 30 technology reads: 0.04 ms;
  - 35 entity counts: 0.09 ms;
  - a counter increment: 28 ns;
  - an open-set lookup: 86 ns per 1000.
- On world n's save, observe opens 203 of 230 actions at its first sweeps (rev 54). The rest wait on habits.

## Demo: a fresh Space Age map on the iMac copy, two bots (astra, sol), filter mode

Astra's workspace was briefed from the tick-0 set:
- describe.json had 60 actions: 54 open plus 6 marked never;
- the building topic held build, deconstruct and nearest_water.

| Step | What the team did (the operator's RCON for the world's side) | Open actions | Opened, in the force's log |
|---|---|---|---|
| start | | 54 | |
| | building by hand on the uncharted map: three refused placements, then `builds` refused by the gate | 58 | build's dry_run arguments (refused), drill_sites (2 refused placements), conflicts, grid, placements (3) |
| | a powered radar placed | 59 | sight (built:radar) |
| | 20 one-second sleeps | 61 | sleep_check, wait_until |
| | a lab and 12 assemblers placed | 68 | labs, science (built:lab); assembler_batch, fuel_budget, rates, stock, supply (scale:machines:10) |
| | railway and construction-robotics researched | 104 | rail_route, train, train_stop; the ghost, blueprint, order and robot tools (33) |
| | a small biter at the lab | 112 | alerts_digest, damage_log, game_alerts, kite, repair, retreat_guard, use_item (attacked); danger (enemy_seen) |

What astra saw at each step:
- Each step's next reply carried its `new` line.
- `./fh help building` grew to 21 entries.
- describe.json was rewritten with 118 actions.
- `platform_create` was refused naming space-platform.

A fresh headless copy cannot chart without a joined client, so builds on it are refused as out of sight. The demo used
calls that need no sight.

## Not built yet

- **Alerts by `self`:** the 238 kinds have conditions (alerts.json, manifest). The runtime still sends every alert
  as before. Gating them at their 30-odd sources, with a first-firing unlock line, is a later step.
- **Choices 5 and 6:** splitting reference entries, and rewriting PLAYBOOK.md and team.md, wait for Nick.
- **Per force:** main keys on the player force. mt276 A's `M.agent_force` and `M.team_forces` replace the `forces`
  and `is_team` helpers in runtime.lua's wiring when it lands.
- **Workspaces:** the repo two levels up is still readable. The PLAYBOOK pointer to docs/usage.md is marked never, so
  filter mode drops it from the core.

## Open choices

Settled by the operator d28 14:28:
- 2: thresholds start at these first values, replayed against early journals;
- 3: habits are counted per force;
- 4: research counts at finish;
- 7: team and stream tools are open at tick 0 in team and streamed runs.

Nick, d28 15:47:
1. **A call to a unit not yet open:** "probably ok to run". The default is refuse=false: the call runs,
   undocumented. `set.py --refuse` keeps the other setting (cp3).
5. **Large reference entries split into simple and advanced parts:** yes (cp4).
6. **PLAYBOOK.md and team.md rewritten into a small core plus topic entries:** yes (cp4).
Facts-only rules are unchanged for the rewritten text.
