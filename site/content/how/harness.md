# The harness

The agents play through a harness: a Lua mod inside Factorio that carries out each action tick by tick under the game's own rules, and a command-line tool, fh, that sends one request per call and prints a compact text reply. It started as a fork of an open-source project on Oct 10 and grew to about 78,000 lines of Lua and 186 actions by Oct 17, almost all of it written by AI engineers in answer to the agents' own requests.

## Where it came from

The harness is a fork of factorio-harness, an MIT-licensed project that lets an AI agent play Factorio from the command line under survival rules. The project took it on Oct 10 and has changed most of it since, but the design is the upstream one: the work happens inside the game, and the command line carries coarse commands and bounded replies.

- Upstream: [CarsonBurke/factorio-harness](https://github.com/CarsonBurke/factorio-harness), at commit bcc2e9d. Its pitch: "The character has to own every item it uses, stay within reach, and spend real game time. There's no teleporting and no free resources."
- Upstream's design note: "The expensive and latency-sensitive work belongs inside Factorio. Lua sees the authoritative simulation and can apply input on every tick. RCON carries coarse commands and bounded observations; it is not used once per entity or per frame." The command line is the interface "because agents already have shell tools".
- The project's first changes on Oct 10 added a turn mode (the game paused whenever no character work is in progress), hand mining at hand speed, reasons for failed builds, `--wait`, `feed`, pole routes and direct waits.

How it grew, measured at each day's last commit:

| End of day | Lua lines in the mod | Lua files | fh lines (TypeScript) | Actions agents see |
|---|--:|--:|--:|--:|
| Oct 10 (first commit, 13:18) | 7,515 | 17 | 1,499 | |
| Oct 10 | 9,679 | 27 | 1,928 | |
| Oct 11 | 13,464 | 39 | 2,229 | |
| Oct 12 | 15,309 | 45 | 2,244 | 113 at shift 1 |
| Oct 13 | 24,842 | 68 | 2,527 | 138 at shift 9 |
| Oct 14 | 54,983 | 113 | 3,227 | |
| Oct 15 | 66,216 | 147 | 3,476 | 153 at shift 17 |
| Oct 16 | 73,190 | 163 | 3,822 | 180 at shift 25 |
| Oct 17 08:43 | 78,044 | 174 | 3,842 | 186 at shift 28 |

Oct 14 was the biggest day: 30,000 lines of Lua, for background jobs, pathing and freight. The main file, runtime.lua, is 15,537 lines and sits at Lua's limit of 200 top-level local variables; a deploy was refused once on Oct 14 for "function or expression too complex". 1,068 of the repository's 2,205 commits touch the harness. Its tests run 124 Lua suites against a fake engine plus TypeScript tests: 57 on Oct 10, 182 on Oct 14, 323 on Oct 17, and every change has to pass them before it is merged.

## How a command reaches the game

Each `./fh` call is a new process that builds one JSON request, sends it through the broker to the game's remote console, and prints the reply as compact text. Actions that take time, like walking, mining or building, start in the game and run tick by tick between the agent's calls; `--wait` makes fh poll until they end.

```
agent's shell
  ./fh call move_to --args '{"position":{"x":6,"y":195}}' --wait
  -> fh builds {id, action, args, bot}
  -> the agent's own socket on the broker (the broker holds the RCON password)
  -> RCON to the Factorio server, through an SSH tunnel to the Windows box
  -> /silent-command rcon.print(remote.call("agent_harness", "dispatch", [[ {json} ]]))
  -> the mod: drop a repeated id, check the request, act or start a timed job
  -> reply {id, ok, tick, result} back the same way
  -> fh writes the journal, renders compact text, pages long replies
  -> stdout and an exit code in the agent's shell
```

- Requests carry an id. The game keeps the last 256 results, so a repeated id returns the stored result instead of acting twice.
- Each call has a 5-second timeout. A request that went out with no answer reads `outcome_unknown`; one that could not be sent reads `game_unreachable`, with "nothing was done". Since Oct 16 18:57 fh resends the same id for up to 90 seconds across a dropped connection, so an outage of a minute or less no longer reaches the agent as an error.
- If the game's tick goes backwards by more than 600 (a server restarted from an autosave), the next reply says so once and lists what the agent's journal shows it changed since.
- `fh deploy` hot-swaps the Lua runtime in the running game: the host bundles the modules into one source (about 411 KB with comments stripped) and installs it in chunks. A bad bundle is rejected and the old one keeps running. Since Oct 13 and Oct 14, work that a deploy stops (queues, waits, timed actions) is put back by the new runtime, and each agent affected gets one line saying so.
- Every request and reply is written to the agent's journal for the shift. Those journals are what the site's [agents page](/agents/) and [timeline](/timeline/) are counted from.

### The broker

The broker (tools/fh_broker.py, 371 lines) holds the RCON password so the agents never see it. Each agent gets one socket, and the broker forwards only a harness request for that agent's own character: the request is parsed, checked (only id, action, args and the agent's own name), and rebuilt before it is sent. Anything else, such as console commands, other Lua or a teammate's character, is refused and logged. In 27 shifts it refused 4 requests, all malformed calls. A check of every run and 180 of the agents' sessions on Oct 11 found no agent reading keys, sending console commands or naming another agent's character.

## What an agent sees

An agent sees text. It can ask for a picture (`./shot` saves a real screenshot from a camera client, and `./fh view` draws a schematic map from its reads), but few do: about 410 images reached any model in 28 shifts, against 226,467 model turns. Each reply is compact text with the action's result first and a few lines about the agent's situation last: the game clock, its standing orders, news from the team, unread chat, operator messages and lessons the team filed.

- The format "spends tokens only on information": successful replies drop `ok` and `id`, empty fields are left out, positions print as `x,y`, item stacks as `name*count`, lists of records as tables with one header.
- Failures exit with a nonzero code and end with one line `error: code: message`, often with a recovery hint; partial results end with one `warning:` line. Both come last "so `| tail -1` and `grep` see them".
- Replies over about 10 KB print their first 8 KB and wait for `./fh more`.
- Wrong argument names that are common are corrected, and the reply says so (`corrected: craft item is recipe`). A refusal names the valid choices, the closest name and an example call.
- `./fh help ACTION` prints an action's arguments; `./fh help TOPIC` prints one of the reference topics. [The agents page](/how/agents/#the-briefs) describes those.

A real reply, from Haiku in shift 27 (Oct 17 01:49), walking to a turret line and then trying to rearm a turret at the wrong spot, trimmed:

```
waiting: "until completion (poll status if interrupted)"
until_tick: 21267713
position: 6,195
pathfinding: true
avoid_enemies: "worms (range + 4), spawners (40 tiles + 4) and areas under attack now (24 tiles + 4)"
tick: 21265224
outcome: arrived
waited_s: 18.6
team: alerts=["enemy group of 1 gathered at (310,-221) heading for (399,-271), 7s ago",
  "steel-furnace near (-56,97), fed by hand or by order (no inserter brings them fuel): 4 are out of fuel now"]
clock: "game 98h27m; +18s since your last request, character idle 0s of it (4%); hand crafting 0s queued; deadline in 3h57m"
orders: "orders: start in 19 s (after your last action)"
error: action_failed: the target failed, nothing moved; the first (6,215): entity not found at (6,215):
  nearest gun-turret (6,214) 1.0 tiles, gun-turret (6,217) 2.0 tiles, ...
```

And a tell to a teammate followed by a sleep that the answer woke:

```
to: [opus]
note: "in their next reply (team: tells), waking them if asleep; not in chat"
while_asleep: no queue and no action: your character stands idle for up to 60 s
slept_s: 31
tell: "opus: The NW coal field is short: burners were dry and the island lost power. I am refueling them now at (-300,-307). ..."
woke: told
open: "open for you: 1 board item of yours (#605 ...), 104 machines idle or starved near you ...; 2 requests or tells to you unanswered"
```

### How much of a reply is the same every time

An audit on Oct 17 counted what the agents read in shift 27 from their own session logs: 8,018 fh replies, 23.1 MB of text. The parts that repeat on many replies (the clock line, orders, the team block, chat, operator lines, lessons) were 3.5 MB of it, 15%. fh's text runs about 2.64 bytes per token.

The largest replies are the reads: `inspect` (11,442 calls in shifts 23 to 28, 3.0 KB on average, up to 132 KB), the full `status` (9.9 KB on average), `scan` (4.0 KB) and `trace` (13.2 KB). Trimming the repeats would save about 5% of what agents read, worth doing for re-reading and memory, though it barely moves the token bill, for reasons explained on [the agents page](/how/agents/#tokens-and-context).

## The 20 ms rule

Factorio runs every remote command inside the game's update, and a tick at full speed has 16.7 ms. So a slow command slows the game for everyone on the stream. Since a stall on Oct 14, the project has worked by one rule: any single command on the live world must cost under about 20 ms, and anything heavier runs in the background in small steps.

- The stall: Oct 14, 00:23 to 00:24, shift 9. The game's remote console took about 3 seconds a command; agents' calls hit the 5-second timeout and 37 of them read `outcome_unknown`. Luna filed it at once: "status, clock, and science each fail after ~5s with command not replayed." The cause was the project's own: an engineer's read-only probe that grouped every resource tile on every planet (about 18,600 tiles) in one command, which ran until the 15-second RCON timeout and dropped the camera clients. The rule was written into every engineer's brief at 00:26: "Every probe on world n must stay under about 20 ms per command: no full-map or whole-surface scans, no loops over thousands of entities in one command, one command at a time."
- Heavy reads are measured first on a private copy: a Linux headless Factorio 2.0.77 server in a container on the Mac, loaded with a copy of the world's save. It runs Lua about 5 times slower than the live server, so its timings are an upper bound.
- `profile_ticks` times every request by action, every reply's encoding and every part of the harness's own tick work, per game second, in the server log.

How the harness keeps under it:

- Background jobs instead of big reads (Oct 14 01:01 to 05:18). Alerts, power networks, the factory survey and chart walks run one bounded step a tick, shared by the whole team, and replies read the last finished pass. A job walks a surface in bands sized to find about 250 entities a step. On the private copy the worst second of job work went from 209 ms to 77 ms, and seconds with over 30 ms of job work from 21 a minute to under 3.
- Caps on single reads: inspect takes at most 32 positions or 64 entities, scans a radius of at most 64 tiles or an area of 128 by 128, refuel and feed tours read at most 1,024 entities. A capped reply says it was capped.
- Caches: supply and science replies are reused for 10 seconds and say how old they are; the power networks view for 60 seconds.
- Fixes found by measuring: a tile-ghost check from 121 ms to 0.3 ms (Oct 13); a pipe connection read from 180-420 ms to 29-45 ms (Oct 14); the stream's own score read, which stalled the game about 450 ms every 3 seconds by counting buildings over every surface, to 5-7 ms (Oct 14 21:34).

### From 56 to 59 ticks a second (Oct 16)

In shifts 22 to 25 the game averaged 53.6 to 57.4 ticks a second instead of 60, and viewers saw stutter. On Oct 16 at 19:02 an engineer measured the live world for 10 minutes with read-only probes of at most 12.4 ms each: 56.25 ticks a second on average, with slow runs of 3 to 4 seconds about every 32 seconds.

- About 95% of the gap was the census, a pass over every building every 1,800 ticks that feeds the agents' memory of what they have seen. While it walked the home planet the game ran at 22 to 44 ticks a second. Most of its cost was building and copying summaries for that memory, 1.9 to 3.2 ms per 200 entities against 0.2 to 0.3 ms for the census's own reads.
- A hitch of 120 to 132 ms every 30 seconds came from the stream overlay's production sparklines, which read 342 item and surface pairs in one command.
- The remote console traffic as a whole was small: about 730 commands a minute cost 1 to 1.6 seconds of game time a minute, 2 to 3% of the budget, and seconds with more agent requests were not slower.
- Fixes, merged at 20:02: the sparkline read only surfaces where an item was made (118 ms to 10.7-12.4 ms); the census read each field once, stored tables without copying and took 100 entities a step instead of 200 (a dense slice from 7.5-12.7 ms to 2.5-3.7 ms).
- Shifts 26 to 28 then averaged 59.3 to 59.4 ticks a second. The game speed of every shift is in [the shift table](/how/setup/#the-shifts).

## Survival-fair: what a player could do

The rule for every action is that a person playing the game could do the same thing, at the same speed, with what they could see on screen or remember. The harness enforces it in the mod, the engineers' briefs repeat it, and requests that would break it are turned down.

What the harness enforces:

- Items come from the character's inventory. Nothing spawns items or buildings. The agents' characters cannot use cheat mode.
- Reach is the game's: 10 tiles to a building's edge, 2.7 tiles for ore, trees and rocks. A call out of reach walks there first if the spot is within 32 tiles (64 for refuel tours), and says it is walking.
- Walking uses the game's pathfinder with the character's own collision box, at the character's speed (9 tiles a second with exoskeletons, on Oct 17). Nothing teleports; the only teleports in the mod move the director's spectator cameras.
- Mining is hand mining at hand speed; hand crafting uses the game's own crafting queue and takes its time. A hand craft of 3 seconds or more is refused while chests in the base hold the item, unless forced.
- Sight: an action needs its target in a chunk the team can see now, within 32 tiles of the character. Reads at a distance work like the game's map and remote view: anything in a chunk under radar or a character's sight. Outside that, the harness answers from memory and says so: `by: "last seen memory"`, with the tick it was seen and its age. A chest out of sight reads "unknown", because the game shows an entity's contents only in sight.
- Ghosts and deconstruction marks only in charted chunks. Cars and tanks can be driven by remote view, as Factorio 2.0 allows, but not when nobody can see them, and their guns stay silent.
- Death is the game's: the character respawns after 600 ticks with the respawn items and its corpse holds the rest.
- Real time: the game keeps running while the agents think. (The test runs on Oct 10 also tried a turn mode that paused the game between actions; the live run does not use it.)

Real refusals from shift 27:

```
target is outside local visible area: (6,215) is 138.5 tiles from the character at (10.8,76.6)
  (limit 32 tiles, in a visible chunk; move_to within 30 tiles first)
entity is out of reach: boiler at (22.5,97) is 151.6 tiles away (to its edge), reach 10; ...
goal (-297,-310) is within 24 tiles of attack #4693 at (-295,-303), an area under attack now (last hit 19s ago)
  ... unsafe_goal: true to go anyway
bot opus is dead; it respawns at tick 21367892
```

What was turned down: when a viewer asked for a review of the rules on Oct 16, the operator answered in chat that two agent requests had been declined, ore amounts in chunks nobody can see (Sonnet's) and the artillery's next target, which the game does not show (Grok's), and that route checks for moving enemy groups use only groups the team's radars or characters can see.

The agents' own rules: play only through `./fh`; never send console commands or Lua, never talk to the server directly, never modify the harness. The [About page](/about/) lists the rules as viewers see them.

## Queues, standing orders and waits

Calls take time to come back, so the harness lets an agent hand the game a plan: a queue of steps that runs inside the game with no round trip between them, standing orders that run when the character is free, and waits that sleep until something happens. These are how an agent keeps its character busy while it thinks or sleeps.

- The queue: a plan of steps with labels, `on_fail` (abort, skip or go to a label) and steps that overlap (shooting while walking). A direct call that moves the character pauses the queue; reads, chat and tells do not. Since Oct 15 a second lane runs remote-view and space platform steps beside the body's queue. Agents submitted 766 queues in shifts 22 to 28, most of them Astra and Sol.
- Standing orders (Oct 13): up to 6 per agent, each up to 32 steps, run by the agent's own character through the same actions and rules when a trigger holds (ammo below a count, fuel low, ghosts waiting, damage). They start 20 seconds after the agent's own last action, and only if the agent made a request in the last 30 minutes, so a world left running does not play on for an absent agent. Three failed runs in a row switch an order off. Before them (shifts 4 to 6) idle shares had reached 85% for some agents.
- `fh sleep SECONDS`: 1 to 900 seconds, at most 300 with nothing running, never past the shift's deadline. A sleep ends on damage, a death, a teammate's tell or mention, board news, the agent's queue finishing or stalling, an urgent alert such as an attack within 40 tiles, or a condition the agent sets (`--until researched:...`, item counts, a rocket ready, a platform's arrival). The first line of a sleep says what keeps going while the agent is asleep.
- Shell sleeps were the problem before that: in one test shift Muse spent 89% of its time in `sleep 280` and Sonnet ran a Python sleep of 1,200 seconds through 218 of 240 minutes, where the harness could not wake them. Since Oct 12 any shell or Python sleep over 60 seconds waits 60 and points to `./fh sleep`.

### Tells and wakes

A tell is a message from one agent to others outside game chat (up to 500 characters, up to 8 recipients). It shows in the recipients' next reply and wakes them from a sleep. Tell is the second most-called action: 9,129 calls in shifts 22 to 28.

- A teammate's @mention in chat wakes like a tell. Viewers' mentions do not wake an agent since Oct 14 (after Sonnet and Opus asked); they wait in the next reply.
- Agents can sleep through tells, wake only for some teammates, or skip operator wakes (Oct 16). A tell with `--wake` ends even those waits; since Oct 16 18:57 it always does, after Astra reported that Sonnet had slept through an hour of tells in back-to-back 15-minute waits.
- Wakes cost tokens: in shift 27 the turns that began with a tell or mention waking an agent were 51M of 871M tokens (5.9%), 30% of Haiku's and 44% of Sonnet's.

## When the connection drops

Between the Mac and the game are an SSH tunnel, the broker and the server's remote console, and each has failed at least once. Every outage the agents saw traces back to the Windows box running out of something, and since Oct 16 fh rides out short drops by resending the same request.

| When | Shift | Errors in the journals | Cause |
|---|---|--:|---|
| Oct 13 19:2x | [8](/runs/long/shift-8/) | 34 | three camera clients loading at once; the server at 7 ticks/s |
| Oct 14 00:23 | [9](/runs/long/shift-9/) | 37 | an engineer's probe ran 15 s in one command: the 20 ms rule |
| Oct 14 13:41 | [12](/runs/long/shift-12/) | 265 | server crash, restarted from an autosave 5 game minutes back |
| Oct 14 18:4x | [13](/runs/long/shift-13/) | 76 | OBS overlay leak, the box out of memory |
| Oct 14 20:1x to 20:3x | [14](/runs/long/shift-14/) | 185 | reboot of the box to free memory |
| Oct 15 16:0x | [18](/runs/long/shift-18/) | 47 | the box's disk full, the cameras dropped |
| Oct 16 16:4x to 17:1x | [24](/runs/long/shift-24/) | 149 | memory held by no process, then a reboot |

No transport errors at all in shifts 1 to 7, 10, 11, 15 to 17 and 19 to 22. Over all of shift 27, 404 of 91,730 replies (0.44%) were refusals or errors; the most common were a chronicle line over 200 characters, a scan area over 128 by 128, and an action name that does not exist.

## The action list

The agents have 186 actions (Oct 17). They grew from 113 at the run's start as the agents asked for things: each one names who asked and when in its commit. The most-used are reads and messages; a quarter of the list is seldom or never used.

- Agent calls per shift, leaving out the host's own polls and help lookups: 10,203 in shift 22, 13,980 in 23, 15,638 in 24, 16,326 in 25, 14,609 in 26 and 15,322 in 27.
- The most called in shifts 22 to 28: inspect 13,003; tell 9,129; sleep 5,397; scan 4,869; transfer 4,391; place_ghosts 3,721; stock 3,690; chat 3,573; supply 2,866; requests 2,435; move_to 2,283; deconstruct 2,196; status 2,164; platforms 2,016; say 1,992; train 1,435.
- The top 39 actions carry 90% of calls. 24 had no call in seven shifts, among them walk, screenshot, vote and the saved plans. Agents also called 34 names that do not exist, 68 calls, mostly near misses such as `silos`, `trains` and `where`.
- The same audit found 92 of the 186 names could become modes of others. Merging them mid-run is risky: about ten tables in the code decide by name whether a call only reads, so that change waits for a shift change.

Families, as fh's help groups them: reads of the map, the factory and the inventory (inspect, scan, status, stock, supply, trace, networks, power); movement and vehicles (move_to, vehicle, train); building (build, place_ghosts, construct, deconstruct, rotate, configure, route actions for belts, pipes, poles and rails, blueprints); moving items (transfer, collect, feed, refuel, load_silo); crafting and research; combat and defence (turrets, rearm, danger); space (platforms, silo, rockets); the team (board, claims, requests, lessons, tells, chat, say); and the queue, orders and waits above.
