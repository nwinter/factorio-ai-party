# Progressive disclosure: the kit grows with each team (design, d28 batch317 cp1)

Status: design and inventory only. Nothing in the harness, the brief or `./fh` behaves differently yet. The build
(cp2 onward) waits for the operator's and Nick's review of the open choices at the end.

## What agents get today, and the goal

Every agent gets the whole kit from tick 0, wherever its team stands:
- 235 actions and 1652 arguments in describe.json (535 KB);
- nine reference topics (328 KB in 262 entries);
- a 20.9 KB core (AGENTS.md) whose index lists every command;
- 238 kinds of alert, wake, reply line and nudge.

The brief only knows whether the world runs Space Age.

The goal (Nick, d28) is a small kit at tick 0 for the simple early game. Tools, arguments and docs then unlock per
team (force) as its research, buildings, encounters and habits call for them, the way Factorio's tips appear.

The rules stay:
- **Facts only:** an unlock says what became available and what it does, never what to build.
- **Survival-fair:** the same conditions for every team.
- **Per force:** one team's unlocks never reach another.
- **world n keeps its whole kit:** the mechanism is off unless a run turns it on (see "World n").

## The inventory

`python3 tools/disclosure/build.py [DESCRIBE_JSON]` writes `tools/disclosure/manifest.json` and prints the summary. It
reads `tools/disclosure/rules.py` (the conditions), describe.json, agent/ref/*.md, the brief's files and
`tools/disclosure/alerts.json` (the alert kinds, each with its source line). `python3 tools/test_disclosure.py` checks
the rules and the manifest.

| Unit kind | Count | What one unit is |
|---|---|---|
| action | 235 | an action of describe.json |
| argument | 1652 | one argument of one action; 421 marked advanced (a condition of their own) |
| doc | 262 | one top-level entry of a topic file (agent/ref/TOPIC.md) |
| index | 9 | a topic's line in the core's index (open when any of its entries is) |
| brief | 127 | a bullet or paragraph of PLAYBOOK.md, team.md, coop.md, compact.md, full-tools.md, harness-KIND.md, spaceage.md, ref/index.md |
| alert | 238 | an alert, wake reason, reply line, refusal hint or nudge kind |

How each kind gets its condition:
- An action's condition is in `rules.ACTIONS`.
- An argument's comes from `rules.ARGS_OF[action]`, else from `rules.ARGS` by name (quality, surface, platform,
  avoid_enemies, the spoilage arguments, dry_run, the circuit and logistic arguments...). Otherwise it comes with its
  action. An argument is never open before its action.
- A doc entry follows `rules.DOCS` by its lead text, else the actions it names, else its topic.
- A brief item takes its file's default, then `rules.BRIEF_ITEMS` by its text.
- An alert follows `rules.ALERTS` by id, else `self`, gated by its game feature (`rules.ALERT_GATES`).

## The vocabulary of conditions

A condition is a list of atoms:
- Its world atoms are a gate, and all must hold.
- Then any one of its other atoms opens the unit.
- A unit with world atoms only is in or out from tick 0.

| Atom | Meaning | Why it is in the vocabulary | Detection and cost |
|---|---|---|---|
| `start` | in the kit at tick 0 | the early game: walk, mine, craft, place, look, research, talk | none |
| `world:FLAG` | space_age, quality, enemies, team (more than one agent in the force), stream, humans | fixed for the run: a peaceful solo world never needs `tell`, `shoot` or the stream tools | read once at launch |
| `research:TECH` | the force researched TECH | the game's own gate: a tool for trains is no use before rails exist | `on_research_finished` (forwarded today); at load, `force.technologies` (32 reads 0.03-0.04 ms) |
| `built:ENTITY` | the force has one of these entities | first car, first train, first roboport, first lab, first platform hub | `force.get_entity_count`: 40 names 0.017-0.029 ms |
| `arrived:PLANET` | a character or platform of the force at the planet | planet tools (demolishers, agriculture, heating) | platforms' `space_location` and characters' surfaces: 0.013-0.025 ms for 22 platforms |
| `event:KIND` | first seen by the force (17 kinds: enemy seen, spitters, worms, attacked, loss, pollution attack, died, demolishers, pentapods, asteroids, spoiled, low power, starved, second surface, hub full, freight, resource depleted) | Factorio's tips: shown when the situation first arises | where the harness already records it per force (threat.lua, losses, powercut, platform hits, pushalerts' out_of_ore); spoilage from item statistics (every surface 0.032-0.044 ms) |
| `habit:KIND:N` | the force's agents did KIND N times (11 kinds: hand crafts of one item, hand belts, hand poles, hand feeds, chest moves, tiles walked, refusals of an action, refused placements, repeated calls, sleeps, board items) | a tool that makes a repeated hand job cheaper: 20 belts placed by hand open `belt_route` | counted in the dispatch the harness already runs for the call: 28 ns an increment; no tick cost |
| `scale:KIND:N` | the force's size or age reached N (machines, labs, drills, belts, inserters, turrets, platforms, agents on a surface, game hours, shifts) | reads that pay off only past a size: `bottleneck` and `trace` at 20 machines | the same slow sweep as `built:` |
| `with:UNIT` | opens with another unit | queue_status with queue_submit; a doc entry with its actions | resolved when the set is built, never stored |
| `self` | an alert's own trigger | the first exhausted patch brings the exhausted-patch alert, with its unlock line | the alert's own code |
| `never` | not agent-facing | attach, detach, advance, cameras, screenshot; the PLAYBOOK pointer to docs/usage.md; world n's own paragraph | none |

The thresholds (20 belts, 10 machines, ...) are first values. "Open choices" says how to calibrate them.

Conditions per unit kind (atoms counted; a unit may have several):

| | start | world | research | built | arrived | event | habit | scale | with | self | never |
|---|---|---|---|---|---|---|---|---|---|---|---|
| actions (235) | 39 | 17 | 101 | 60 | 4 | 34 | 23 | 34 | 33 | | 5 |
| arguments (1652) | 16 | 13 | 143 | 45 | 18 | 220 | 76 | 5 | 1235 | | 1 |
| doc entries (262) | 5 | 13 | 73 | 60 | 9 | 4 | 2 | 8 | 178 | | |
| brief items (127) | 73 | 46 | 18 | 17 | | 5 | | | 4 | | 2 |
| alerts (238) | 57 | 114 | 1 | 1 | | | | | 31 | 143 | |

## The tick-0 set

In world n's settings (Space Age, Quality, enemies on, a team, streamed), 54 actions are open at tick 0:

- look: observe, status, clock, inspect, scan, nearest, map, ores, inventory, recipes, craftable, technologies,
  research_options, describe;
- move, mine, craft, place: walk, move_to, mine, craft, cancel_craft, build, rotate, pickup, collect, transfer, feed,
  refuel, deconstruct, nearest_water, configure;
- research and pace: research, research_next, sleep, wait_ticks, stop;
- talk: say, chat, chat_ack, operator, harness_request, and with world:team tell, tells, board, board_plan,
  board_post, board_update, mention_counts;
- shoot (world:enemies);
- the stream's profile, profiles, confess, confessions, chronicle, vote, votes (world:stream).

A peaceful solo base-game world opens 39 at tick 0. The first tips open from habits and size:
- 3 drills or 2 refused placements: drill_sites;
- 20 belts placed by hand or 40 belts: belt_route;
- 8 poles by hand: pole_route;
- 5 moves between the same chests: deliver and stock;
- 20 sleeps: wait_until;
- 5 repeated calls or a game hour: the queue.

## Sizes

Each row adds that milestone's conditions to the one before. The core is today's assembled core for a Claude agent
less the closed brief items, with the index cut to open commands. Today's core is 20,931 bytes.

| Milestone | Actions | Arguments | describe.json bytes | Doc entries | Doc bytes | Core bytes |
|---|---|---|---|---|---|---|
| tick 0 | 54 | 350 | 95,643 | 56 | 67,917 | 16,768 |
| first hour: power, labs, a few drills and belts | 83 | 596 | 165,868 | 89 | 119,748 | 18,619 |
| mid game: oil, robots, circuits, trains, defense | 188 | 1236 | 281,368 | 181 | 191,682 | 19,978 |
| rocket and first platform | 224 | 1613 | 370,389 | 249 | 320,505 | 20,520 |
| every planet | 228 | 1637 | 374,776 | 260 | 326,323 | 20,567 |
| all (agent-facing) | 230 | 1652 | 375,908 | 262 | 327,590 | 20,931 |

- The large saving at tick 0 is in describe.json (25% of the arguments' text at tick 0) and the reference (21%).
- The core shrinks 20% at tick 0. Most of it is the PLAYBOOK's and team.md's tick-0 text: how fh, pace, memory,
  stopping and the board work. Making it smaller needs those items rewritten, not only filtered (open choice 6).

## Mechanism (cp2 onward)

**State**:
- `storage.disclosure[force_name]` keeps:
  - `met`: the met atoms, at most a few hundred strings, each with its tick;
  - `counts`: the habit and scale counters, one per kind and item, capped at the kind's highest threshold, at most
    64 keys a kind;
  - `rev`: a revision that grows with each new atom.
- The open set is computed from `met` and the manifest's conditions. That happens when a reader asks (brief, help,
  describe, an unlock line), never per tick.
- The manifest goes into the runtime as a compact table built from manifest.json: unit id, kind, world gate, atoms.
  That is about 2,500 rows, held once (not per force).
- It is saved with the game and carried across shifts.
- On a world that loads with the mechanism newly on, `met` starts from what the force already has: its researched
  technologies, entity counts and surfaces. A team resumed mid-run therefore starts with what its state calls for.

**Triggers** (no per-tick scan; costs measured on the iMac copy with world n's save of d28 13:20, 22 platforms,
27 surfaces):
- Research: `on_research_finished` adds `research:TECH` for the event's force.
- The slow sweep, one force a step, every 600 ticks per force, reads only atoms not yet met:
  - `get_entity_count` for the built and scale names (40 names: 0.017-0.029 ms);
  - platforms' locations and characters' surfaces (0.013-0.025 ms);
  - spoilage in the item statistics (0.032-0.044 ms).

  A full sweep of one force is 0.10-0.14 ms on the iMac. world n's Lua runs about 2.5x slower, so under 0.4 ms
  there, and it shrinks as atoms are met.
- Events: at the places the harness already records them per force, each adds its atom once:
  - threat.lua's attacked areas, nest news and attack groups;
  - loss incidents, power cuts and platform hits;
  - pushalerts' out_of_ore.

  `on_resource_depleted` is not needed: pushalerts already finds exhausted patches. A new forwarded event would be a
  control.lua change, which a hot reload does not carry.
- Habits: dispatch_request counts after the handler returns: the action, its refusal, the item for hand crafts, the
  container pair for transfers. One increment costs 28 ns.
- The per-call check: is the action open, and are its arguments? One table lookup each, 86 ns per 1,000 lookups.

**How an unlock reaches the team**:
- **Shift start:** tools/brief.py builds the core, ref/ and describe.json from the force's open set. It reads that
  set with an operator read `disclosure {force}`. The core's index lists only open commands; ref/ holds only open
  entries.
- **`./fh help`, `./fh help ACTION` and describe:**
  - they show the open set: describe takes the reader's force, and its cache key becomes bundle plus `rev`;
  - describe.json in the workspace is rewritten when `rev` grows, as it is after a harness update now.
- **Mid-shift:**
  - an unlock reaches each agent of that force once, in the next reply's team block:
    `new: belt_route: lays a belt from one point to another in one call; docs: ./fh help building`;
  - the text is the unit's index scope or the first sentence of its doc entry, so it says what the tool does;
  - several unlocks at once share one line with the names;
  - an alert that opens by `self` carries the same line the first time it fires.
- **A call to a unit that is not open yet:** see open choice 1. The proposal is to refuse it with a facts-only line
  naming the condition. For an action: `belt_route is not available yet: it opens when your team has placed 20 belts
  by hand or has 40 belts`. For an argument, the valid list names the open arguments, and the refused one gets the
  same kind of line.
- **The operator's view:** `disclosure {force}` gives the open count per kind, the newest unlocks with their ticks,
  and the next thresholds. The stream can show "kit: 83 of 230 tools" per team.

**World n**:
- The mechanism is off unless the run sets it (`POG_DISCLOSURE=1` at launch, stored in the save's settings). Off
  means everything is open, as today, and no state is kept.
- Not every unlock is already met on world n (habits, for one), so "on but all met" would not be the same as today.
- Proposed for cp2: an observe mode on world n that computes `met` but filters nothing. It shows when each unit would
  have opened in a real run.

## Leaks and edges

Agents can reach the whole kit outside the mechanism:
- the PLAYBOOK's pointer to docs/usage.md (marked `never`);
- the public repository and this repo's docs folder, two levels up from a workspace;
- teammates' notes.md;
- `gamedata/`, which is game data and stays open.

A disclosure run would drop the usage.md pointer and keep workspaces from reading the repo, as the rules already ask
("never modify the harness"; reading is not forbidden today). Lessons and ground rules are written by agents. Their
tools open at the second shift or after a loss or death, but what agents write in them is theirs.

## Open choices for Nick

1. **A call to a unit not yet open:**
   - (a) Refuse it, naming its condition. This is the proposal: the same for every team, and no silent difference
     between an agent that guessed a name and one that did not. A condition is a fact; it can point a team at a
     technology, which is information the game's tech tree gives anyway.
   - (b) Allow it, undocumented. Then guessed names (from earlier shifts, notes or the web) get the full kit unevenly.
2. **Thresholds:** the habit and scale numbers are first values. cp2 can replay world n's early-shift journals through
   the vocabulary and show when each unit would have opened, then set the numbers against that.
3. **Habits per force or per agent:**
   - per force (proposed): one agent's 20 hand belts open belt_route for the team. That is survival-fair, since the
     whole team gets a tool any member's work called for;
   - per agent: the kit would differ inside a team.
4. **Research at finish (proposed) or at start:** opening a tool at finish keeps the tool and the game's ability
   together.
5. **Docs granularity:** a doc entry opens whole with its action. The transfer entry is 6.6 KB at tick 0, with its
   advanced arguments described in it. Splitting entries into simple and advanced sentences would make the tick-0
   reference smaller (68 KB now), at the cost of restructuring the topic files.
6. **The core's own text:** 16.8 KB stays at tick 0 because PLAYBOOK.md and team.md are tick-0 prose. Rewriting them
   into a smaller core plus topic entries is a separate change.
7. **Stream and team tools at tick 0 in streamed and team runs** (proposed: yes, they are about talking, not the
   game).
