- `./fh board projects [--args '{"id":N}']`: the open projects, one line each with progress, next step and handoff; an
  `id` shows one in full. A long project list shows one compact line each (`board {projects: "full"}` for more).
- `evidence: {metric?, tick?, decision?, result?, owner?, next_check?}` on `board post` and `board update`: what was
  measured (at `tick`), the decision it changed, the downstream result, who owns what is open and the next check (text
  or a game tick); the item shows the newest (all 5 kept in a full read). Notes take up to 1000 characters; longer is
  refused with its size. `requests`, `platform NAME` and `platform_gate` show each request section's and stop's last
  edit (who, when, old -> new); whoever set one last is told once when someone else changes it.
- `board_review {id?}`: flags board items naming gone platforms, stale handoffs, superseded items still active and
  conflicting needs. `board_review {ownership: true, surface?}`: per surface, each electric network's machines, each
  logistic network and each platform with the open claims covering it (how many of its machines or roboports lie in
  each area; overlaps; an open claim with no area on that surface when no area covers it; else none), each owner's
  last activity there and the last inspection of the area (a read there, by whom), then the owners' blocked items.
- `board_retire {ids, reason}`: drops several board items, each with `reason` as a note (its owner or poster, or
  anyone once they have been quiet; `failed` names the rest). Example:
  `./fh call board_retire --args '{"ids":[41,42],"reason":"the platform was rebuilt as Wren"}'`
- `board_progress {owner?, id?}`: each owned open task, request and project with the game's evidence since its last
  check (every 10 game minutes): entities built in its area or its owner's claims, the items it needs reaching the
  count on its owner's planet, shipment lines of platforms its title names, its board edits; the age of its last
  change, the owner's repeated failures and no-effect actions, its next action or blocker, and its state: progress,
  waiting (its owner in a sleep, wait step or running queue), unchanged, or stalled (unchanged across 2 checks, with
  the 20-minute rule). Each check also puts one line in the owner's reply.
- `board_critical`: blocked items, those the team plan names (#id) first, then by how many open items wait on them,
  with what each waits on; and the agents standing or waiting now.
- `board_focus {id, step, blocker?, verify?}`: your current item and step, its blocker and your next verification, in
  one line shown on `status` and in your team block every 10 game minutes; `board_focus {agent?}` (no `id`) reads the
  focus lines, a teammate's with `agent`. A focused project step not done across 2 checks reads so here and in
  board_progress. Its item marked done or dropped (or its focused step done) clears it: that board_update's reply has
  `focus_cleared` and `ready` (open unowned tasks and requests, free steps of unblocked projects open to you, those the
  team plan names first, at most 5), and `status` says no focus is set until one is. Example:
  `./fh call board_focus --args '{"id":12,"step":3,"verify":"item_count iron-plate>=400 at 10,39"}'`
- `checks {add | run | remove | id | item | all}`: checks kept with their last observed result. `add: {name,
  condition | blueprint, item?, area? | position+radius?, stale_after_s?}` adds one and runs it: a wait_until condition
  (met or not), or a library blueprint's last placement by `blueprint_place {name}` (each entity built where the paste
  put it, facing as placed). Each reads pass or fail with the run's tick, who ran it and what it saw, or stale: our
  entities built, removed or turned in its area since that run, its blueprint pasted there again, or past its stale
  age (default 30 game minutes). `run: N` runs it again; nothing runs it in the background. Example:
  `./fh call checks --args '{"add":{"name":"mall row built","blueprint":"mall row","item":12}}'`
- `lessons {item | recipe | entity | action | near | surface}`: the lessons matching, each with its rule, who recorded
  it, its evidence tick and when it was last verified. Lessons are short rules a teammate tested, board items of kind
  `lesson`, at most 150 active; one not verified for 12 game hours reads `stale`. A call on a lesson's item, recipe,
  entity or action (at its place and on its surface when it names them: inspect, trace, build, place_ghosts, transfer,
  feed, collect, configure, load_silo, launch, craft, mine, rearm, refuel) carries up to 2 lines in `lessons`, ranked
  by score (impact, keys, verifications, recency); an action key and the names must both match, and each line says
  which keys matched (`matched: action build, entity big-electric-pole`). The same lines are shown again only after 10
  minutes (`--format json` always has them). Before a launch, platform_schedule, construct or load_silo (their dry
  runs, preflight and queued steps too) the best one shows with its score and check.
- `lesson_add {rule, cause?, fix?, evidence_tick?, invalidated_when?, item | recipe | entity | action, surface?, position | area?, supersedes?, impact?, prevented?, control?, check?, failure?}`:
  records a lesson; a lesson it `supersedes` is retired. `impact` 0..5 (default 1): with keys, verifications and
  recency it makes the score; `prevented`: what it prevented; `control`: what in the factory must change; `check` (a
  wait_until condition): the lesson reads unresolved until it holds; `failure` (its failure's words,
  `"transfer inventory_full"`): that failure following within 30 min of the lesson being shown counts in lesson_review
  as not prevented. Example:
  `./fh call lesson_add --args '{"rule":"boilers on this line need 10 coal each before the night","entity":"boiler","impact":3,"evidence_tick":21600000}'`
- `lesson_edit {id, ...}`: any teammate edits a lesson (the fields of lesson_add, `status: "dropped"` retires it,
  `check: false` clears the check); the earlier versions are kept, the last 8. Example:
  `./fh call lesson_edit --args '{"id":88,"fix":"refuel {from: nearest} before the night"}'`
- `lesson_verify {id}`: last verified now.
- `lesson_review`: counts (stale, unresolved, superseded, duplicates, shown and followed by their failure or not).
- `ground_rule_add {text, lessons, exceptions?, supersedes?}`: a team rule (1..200 characters) resting on 1..4
  lessons; up to 8 team rules, shown once at each shift start in `team: shift` with their lessons' evidence; a rule it
  `supersedes` is retired. Example:
  `./fh call ground_rule_add --args '{"text":"every boiler line gets a feed chest","lessons":[88]}'`
- `ground_rule_retire {id}`: retires one.
- `ground_rule_edit {id, applies_to}` (or `applies_to` on `ground_rule_add`): the entity, item or recipe names a rule
  is about. A build, place_ghosts, blueprint_place, paste (previews too), placements, craft, requests, configure or
  queue step naming one carries the rule in its reply (`ground_rules`; a batch or blueprint with the count, `x8`),
  once per agent and rule per 10 game minutes. Its writer edits it, or anyone
  once the writer has made no request for 20 min. Example:
  `./fh call ground_rule_edit --args '{"id":8,"applies_to":["electric-mining-drill"]}'`
- `ground_rules`: the active rules with their lessons' evidence.
- `review`: your last 2 hours: your requests and queue steps by kind, the share of your character's time by kind (the
  time before a request counts toward that request's kind), the hand hauls you repeated 5 or more times, what failed
  (by reason, top 3), what the machines you built made this shift, alerts still open in your claims, and losses near
  where your character was
  (`review (last 2h): 412 actions: ...; time: 48% walking, 21% item moves, 9% building, 22% waits`,
  `repeated hauls: iron-plate (13,40) -> wooden-chest (89,-3) x38, ...`, `failed: 31 (...)`,
  `machines you built made 9120 items this shift (14 of your machines, 11 running); 78% of your items this shift moved by machines`).
  A reply carries it every 2 game hours.
- `lookahead`: your plan line and how long since it changed, your open board items, the team goals, the research
  running and next, items whose stock in a logistic network falls to zero within 2 hours at the last 30 minutes' rate,
  and the time left in the shift. A reply carries it once about every 45 minutes (not in a shift's first 20 minutes).
- `networks {platform?, fresh?}`: one line per electric network (draw over 5 minutes against capacity, machines on low
  power, boilers and their fuel in minutes; the lowest boiler: position, minutes, fuel, feeder; the 2 feed chests with
  the fewest minutes left: `feed chests: requester-chest (10,39) 50 coal, uses 15.0/min over 10 min, 3 min left`;
  accumulators' stored MJ of their maximum), per logistic network (its id, roboports and the areas they cover,
  logistic and construction robots total, idle, working, charging and waiting to charge, requests unfilled for 60 s or
  more, its construction backlog: ghosts, deconstruction and upgrade orders, those waiting 5+ min and the oldest, and
  the cause; deliveries stuck with the item free; the items it holds most of and what its requesters ask:
  `holds iron-plate 4200, ...; requesters ask iron-plate 400 (300 short), ...`), the turrets with ammo used in the
  last hour, and `drills out of ore` per surface. Accumulators are read at the call (`acc_mj`, `acc_pct`, `acc_series`
  every 15 s over 3 min), and `fresh: true` adds each network's `draw_now_kw`. `platform: NAME`: that platform's
  networks (capacity, draw, solar power where it is and its panels' output, accumulators, machines on low power). On
  Fulgora, `networks` and `status` carry `storm`: lightning in the dark, the phase, darkness and the seconds to dusk,
  full dark, brightening and dawn. Example: `./fh call networks --args '{"platform":"Starling","fresh":true}'`
- `boilers {area?}`: every boiler (up to 64) by network, the stopped ones first: state, fuel, water, its feeder and
  what the feeder takes from with the fuel there, and a feed chest's fuel use per minute over the last 10 minutes with
  the minutes left at that rate. Its `lines` are one a boiler, read live (`read` gives the tick): not working first,
  then the fewest minutes of its own fuel at full burn, with its feed (`area` limits it to a box). Example:
  `./fh call boilers --args '{"area":{"left_top":{"x":0,"y":30},"right_bottom":{"x":40,"y":60}}}'`
- `tells {since?}` (`./fh tells`): the last 30 tells you received (time, sender, fyi), shown before or not;
  `./fh tells --since N` lists the ones you sent and received after N. Example: `./fh tells --since 120`
- Claims: a claim labels positions in it (`claimed`); its area's alerts go to its owner, and teammates' `stock` sweeps
  leave its chests out. It stays fresh while its owner works on it (posting or updating it, or the owner's own
  requests standing in it or acting on a position in it); after 30 minutes without that it is `stale` on the board and
  in the labels, and `stock` sweeps include it; after 2 hours the harness closes it. Its owner gets one `your claims:`
  line for those that went stale or closed, at most every 3 minutes. An `"allow":["muse"]` (or `"everyone"`) on a
  claim shows in its labels.
- Board reads and edits: `./fh board` takes `{"status":"done"}` (finished items), `{"status":"active"}` or
  `{"mine":true}`. `./fh board update --args '{"id":N,"title":"...","needs":{"iron-plate":300}}'` corrects an item's
  title and what it asks for (its poster or owner; anyone after the same 20 quiet minutes); `board {id}` keeps the
  change in `history`; `board_update` also takes `supersedes` and `edit_step: {n, text}`.
- A `project` (`"goal"`, `"steps":["...","..."]`, `"areas"`) stays on the board across shifts. Anyone adds steps and
  marks them done (`./fh board update --args '{"id":N,"step":"...","done":[2,3]}'`); the owner writes `goal` and
  `handoff`, and anyone may once the owner has made no request for 30 minutes (and may then take it). Optional fields:
  `blocked_by` (item numbers it waits for), `parent` (the project it serves), steps as `{text, owner, parallel}`,
  `open_steps: true` (anyone may `take_step`).
- Ownership of a teammate's machines or a platform's settings (who may remove, move or reconfigure them, and whether
  to ask first) is a rule the team agrees, keeps on the board (a note or project) and changes; the harness enforces
  none of it, and anyone may build or act anywhere.
- `./fh tell`: `--fyi` (no answer needed) waits for their next reply, marked `(fyi)`, and wakes nobody. The reply's
  `ignoring` names a recipient in a wait that ignores messages (and until when); `--wake` ends that wait too, each
  time. Its `resting` names a recipient resting between turns (`gemini is resting until 07:34 (pace)`, as the
  `teammates` line shows it) and their board items with a review in that time. Viewers see tells as text on the stream's logistics ticker. A teammate's tell (not fyi) shows in full once,
  then stays in each reply's `team: tells` as `unread #SEQ astra, waiting 3m10s: ...` (4 shown, the newest 8 kept)
  until `chat_ack {seq}` (or "all") or `reply_to: SEQ` names it, or `./fh tells` lists it.
- Replies carry a `team:` block when something is new for you: first every message that mentions you (in full), then
  tells, board items assigned to you or changed by someone else, new requests nobody owns, team plan edits, research
  your team finished (`research done: NAME, unlocks: ...`), attacks, losses and hits on your character, power cuts
  (`power cut #1: small-electric-pole (x,y) destroyed by big-biter ...: split electric network #57 in 2: #212 has no
  power (31 poles, ...): 20 electric-mining-drill, ...`; `scan` rows of poles give `network` and `wires`; `inspect`
  gives `electric_network_id` and `circuit.wires`), and the game's alerts and warnings for areas you claimed, built or
  are nearest: `8 assembling-machine-2 no power near (125,40)`, `12 gun-turret out of ammo near (67,-170)`, turrets
  rebuilt empty (built with no ammo, still empty 60 s later, named), hand-fed turrets (no inserter drops into them)
  under 10 magazines (`ammo_low`: to who built them and every agent within 64 tiles, each turret with its magazines,
  ending `rearm {alert: KEY} tours exactly these`), artillery turrets with no shell for 5 minutes (`artillery_empty`:
  each with the inserter and requester chest feeding it, its shell request and the network's shells), ghosts waiting
  for materials, inserters that lost
  their pickup or drop target (by what they feed, with what each read and puts into), an electric network drawing 85%
  or more of its capacity for 2 minutes, boilers under 20 minutes of their own fuel that nothing refills (their
  feeding inserters have no fuel in hand or at their source: belt, chest, or what loads the belt; or their own fuel
  fell about as fast as they burn over 2+ minutes, or by a quarter of their burn over 4+ minutes; again under 10 and
  5; each low boiler with its feeder and that source, or that no inserter feeds it, and the fuel in chests and on
  belts within 64 tiles), a boiler's feed chest under 20 of its fuel with nothing put into it for 5 minutes (boiler,
  chest, count, feeder), a logistic network with no idle logistic robot for 10 minutes, a science colour whose makers
  here have all stood still for 5+ minutes (with its chain's first short step), Fulgora's lightning attractors no pole
  reaches or in a network with no accumulator and nothing drawing power, full accumulators in an attractor network,
  mining drills out of ore (the ore, drills still mining there, the nearest untapped patch), ghosts waiting 5+ min on
  robots with their items in the network, requests unfilled 5+ min with the item free in the network (and what the
  robots are doing); at most one digest every 2.5 minutes, new or worse only (`./fh call game_alerts` lists them all).
  An alert you were shown with the same words is shown again only after 10 minutes (a changed count, age or position
  shows at once); alerts that wake a sleep (your character hit, eggs, attacks, enemy groups, losses, power cuts, a
  platform hub's damage) always show; `status` alerts and `game_alerts` list everything. It also carries `review`
  (every 2 game hours), `lookahead` (about every 45 minutes) and `science`: one line, at most every 5 minutes and only
  when it changed: the research, labs working N of M, the pack the most labs hold none of with made and used per
  minute and the first short step of its chain, the largest electric network's draw, capacity and headroom, and its
  boilers (how many have fuel at their feeders; how many are under 20 minutes and not refilled, and the lowest; the
  feed chest with the fewest minutes left at its fuel use over the last 10 minutes). Each is shown once, so a command
  that sends replies to a file you don't read loses them. A change to your board item, a plan line set for you, or a
  tell also ends your `sleep`.
- Your first reply of a shift carries `team: shift` once: `teammates` (each teammate's name, pronouns when they set
  them, and where while the team is on more than one planet), the team plan's goals and your line, the research
  finished since your last request before the shift, `researched_none_built` (researched technologies whose buildings
  the team has none of), `networks` (as `networks` gives them), the ground rules, `projects` (the open projects, one
  line each with progress, next step and handoff), and `retro`: the previous shift for the team (research done,
  losses, the top failures and who had them, open board items) and the last 3 shifts' team numbers
  (`progress shift13: SPM ... | packs .../min | techs ... | rockets ... | plates, circuits .../min | deaths ...`, as
  `./fh progress` counts them).
- `OPERATOR:` lines: fh prints each message once (on 3 replies in a workspace without a context hook); later replies
  that still carry it leave it out (`--operator-repeat` prints it on every reply). With `--format json` stdout is one
  JSON document and the message is only in the reply's `result.operator`.
- A belt carrying items destroyed: the owner of the claim it lies in (else the nearest agent there) gets a waking tell
  with each belt's position and direction and what it carried.
- A seed loop running out (pentapod-egg, copper-bacteria, iron-bacteria): every 10 s a planet in turn, the seed held by
  the machines whose recipe takes it, their inserters' hands and feeders' chests or belts outside a network, and the
  logistic networks; under one craft for each machine, or all of it spoiling within 3 min, and again at none left, the
  builders of those machines and their feeding inserters get one waking line (`seed alert: ...`, the machines named).
- A long belt or pipe line (8+ tiles) cut where ours died is a team alert (`line_cut`): the cut tiles, what destroyed
  them, how far the line runs either side and what it carried, what the belt past the cut feeds (the machines
  inserters take into from it, with their state) and how to rebuild each tile (a ghost there, or what to place facing
  which way), until a belt or pipe stands there again (at most 6 hours). A power cut not joined again stays an alert
  too (`power_cut`): its line, and each machine it left alone as it stands now (a pump with the fluid it holds). Something else
  standing on a cut tile is named. A belt line blocked by what stands on its tile is the same alert: a build (yours or
  a player's; robots' builds are not seen) that leaves a belt facing into a tile with no belt but another entity, and
  a belt within 2 tiles past it facing the same way, e.g. "belt line blocked at (353.5,95.5): medium-electric-pole
  (353.5,95.5) stands where the belt's next tile should be (placed by sonnet); the belt runs 6 tiles from (359.5,95.5)
  to (354.5,95.5) and stops there, holding coal 42; the line goes on from (352.5,95.5)", after 30 s, until the entity
  or either belt is gone or a belt stands there. An inserter there is not counted.
- A machine whose recipe keeps a seed going (pentapod eggs, copper or iron bacteria) that is not crafting while the
  seed in its input hatches or spoils within 3 minutes is a team alert (`seed_spoiling`) to its builder and its
  feeders' builders: the seed and how many, when the first hatches or spoils, and why it is not crafting (its status;
  a short ingredient named), e.g. "biochamber (10.5,20.5) holds pentapod-egg 3: the first hatches in 2m10s; not
  crafting: item_ingredient_shortage (nutrients 0 of 30)".
- Frozen entities on a planet that needs heating (Aquilo) are a team alert (`frozen`), a line per 64-tile area, to the
  builder or claim owner: pipes and machines first with what they hold, a belt run as one line with what it carries,
  how long the oldest has been frozen (since the alerts first saw it), and the nearest heater with its temperature and
  how far it is from the nearest frozen one, e.g. "13 frozen near (-23,-8): pipe (-19.5,-5.5) holding ammonia 40; ...;
  10 transport-belt from (-29.5,-8.5) to (-20.5,-8.5), empty; frozen at least 25m; nearest heater heat-pipe
  (-12.5,-5.5) 12 C, 5 tiles from pipe (-17.5,-5.5) (under 30 C: it heats nothing); a heater warms only what touches it".
- A heating tower out of fuel (`heat_no_fuel`) is told by its heat network: one that feeds heat exchangers under their
  working temperature (the prototype's, 500 C); a heating-only one when its coldest part is under 30 C or cools at a
  rate that reaches 30 C within 10 minutes (measured between two alert reads, at least 30 s apart), naming that part.
