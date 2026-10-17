- What the harness does with a claim: it labels positions in it (`claimed`), sends its area's alerts to the owner and
  keeps teammates' `stock` sweeps out of its chests. It stays fresh while its owner works on it (posting or updating
  it, or the owner's own requests standing in it or acting on a position in it); after 30 minutes without that it is
  `stale` on the board and in the labels and `stock` sweeps include it; after 2 hours the harness closes it. Its owner
  gets one `your claims:` line for those that went stale or closed, at most every 3 minutes. An `"allow":["muse"]` (or
  `"everyone"`) on a claim shows in its labels.
- `./fh board` shows active items; `{"status":"done"}` for finished ones; add `--args '{"mine":true}'` or
  `'{"status":"active"}'`.
- `./fh tell --fyi`: when no answer is needed: it waits for their next reply, marked `(fyi)`, and wakes nobody.
- Ownership is the team's to decide: who may remove, move or reconfigure a teammate's machines or a platform's
  settings, and whether to ask first, is a rule you agree among yourselves, keep on the board (a note or project) and
  change when it stops working. The harness enforces none of it; anyone may build or act anywhere.
- `./fh board update --args '{"id":N,"title":"...","needs":{"iron-plate":300}}'` corrects an item's title and what it
  asks for (its poster or owner; anyone after the same 20 quiet minutes); `board {id}` keeps the change in `history`.
- `board_review {id?}` flags board items naming gone platforms, stale handoffs, superseded items still active and conflicting needs; `board_retire {ids, reason}` drops several; `board_update {edit_step: {n, text}}`, `supersedes`.
- A `project` (`"goal"`, `"steps":["...","..."]`, `"areas"`) stays on the board across shifts. Anyone adds steps and
  marks them done (`./fh board update --args '{"id":N,"step":"...","done":[2,3]}'`); the owner writes `goal` and
  `handoff`, and anyone may once the owner has made no request for 30 minutes (and may then take it). `./fh board
  projects` lists the open ones with progress. Optional fields: `blocked_by` (item numbers it waits for), `parent` (the project it serves), steps as
  `{text, owner, parallel}`, `open_steps: true` (anyone may `take_step`); a long project list shows one compact line each (`board {projects: "full"}` for more).
- Replies carry a `team:` block when something is new for you: first every message that mentions you (in full), then
  tells, board items assigned to you or changed by someone else, new requests nobody owns, team plan edits, research
  your team finished (`research done: NAME, unlocks: ...`), attacks, losses and hits on your character, power cuts
  (`power cut #1: small-electric-pole (x,y) destroyed by big-biter ...: split electric network #57 in 2: #212 has no
  power (31 poles, ...): 20 electric-mining-drill, ...`; `scan` rows of poles give `network` and `wires`; `inspect`
  gives `electric_network_id` and `circuit.wires`), and the
  game's alerts and warnings for areas you claimed, built or are nearest (`8 assembling-machine-2 no power near
  (125,40)`, `12 gun-turret out of ammo near (67,-170)`, turrets rebuilt empty (built with no ammo, still empty 60 s later, named), ghosts waiting for materials, inserters that lost their pickup or drop target (by
  what they feed, with what each read and puts into), an electric network drawing 85%
  or more of its capacity for 2 minutes, boilers under 20 minutes of their own fuel that nothing refills (their feeding
  inserters have no fuel in hand or at their source: belt, chest, or what loads the belt; or their own fuel fell about
  as fast as they burn over 2+ minutes, or by a quarter of their burn over 4+ minutes) (again under 10 and 5; each low boiler with its feeder and that
  source, or that no inserter feeds it, and the fuel in chests and on belts within 64 tiles), a boiler's feed chest under
  20 of its fuel with nothing put into it for 5 minutes (boiler, chest, count, feeder), a logistic network with no
  idle logistic robot for 10 minutes, a science colour whose makers here have all stood still for 5+ minutes (with
  its chain's first short step), Fulgora's lightning attractors no pole reaches or in a network with no accumulator and nothing
  drawing power, full accumulators in an attractor network, mining drills out of ore (the ore, drills still mining
  there, the nearest untapped patch), ghosts waiting 5+ min on robots with their items in the network, requests unfilled
  5+ min with the item free in the network (and what the robots are doing); at most one digest every 2.5 minutes, new or worse only;
  `./fh call game_alerts` lists them all). Every 2 game hours it carries `review`, your last 2 hours: your requests and queue steps by kind, the share of
  your character's time by kind (the time before a request counts toward that request's kind), the hand hauls you
  repeated 5 or more times, what failed (by reason, top 3), what the machines you built made this shift, alerts still
  open in your claims, and losses near where your character was (`review (last 2h): 412 actions: ...; time: 48%
  walking, 21% item moves, 9% building, 22% waits`, `repeated hauls: iron-plate (13,40) -> wooden-chest (89,-3) x38,
  ...`, `failed: 31 (...)`, `machines you built made 9120 items this shift (14 of your machines, 11 running); 78% of
  your items this shift moved by machines`, ...);
  `./fh call review` shows it any time. About every 45 minutes a reply carries `lookahead` once: your plan line and
  how long since it changed, your open board items, the team goals, the research running and next, network stock
  falling to zero within 2 hours, and the time left in the shift (`./fh call lookahead` shows it any time).
  `science` is one line, at most every 5 minutes and only when it changed:
  the research, labs working N of M, the pack the most labs hold none of with made and used per minute and the
  first short step of its chain, the largest electric network's draw, capacity and headroom, and its boilers (how
  many have fuel at their feeders; how many are under 20 minutes and not refilled, and the lowest; the feed chest
  with the fewest minutes left at its fuel use over the last 10 minutes).
  Each is shown once, so a command that sends replies to a file you don't read loses them. A change to your board
  item, a plan line set for you, or a tell also ends your `sleep`.
- Your first reply of a shift carries `team: shift` once: `teammates` (each teammate's name, pronouns when they set
  them, and where while the team is on more than one planet), the team plan's goals and your line, the research finished
  since your last request before the shift, `researched_none_built`: researched technologies whose buildings the
  team has none of, and `networks`: one line per electric network (draw over 5 minutes against capacity, machines on
  low power, boilers and their fuel in minutes), per logistic network (its id, roboports and the areas they cover,
  logistic and construction robots total, idle, working, charging and waiting to charge, requests unfilled for 60 s or
  more, its construction backlog: ghosts, deconstruction and upgrade orders, those waiting 5+ min and the oldest, and
  the cause; deliveries stuck with the item free) and the turrets with ammo used in the last hour, and `drills out of
  ore` per surface (`./fh call networks` shows them any time;
  `./fh call boilers` lists every boiler (up to 64) by network, the stopped ones first: state, fuel, water, its feeder and what
  the feeder takes from with the fuel there, and a feed chest's fuel use per minute over the last 10 minutes with the
  minutes left at that rate; its `lines` are one a boiler, read live (`read` gives the tick), not working first, then
  the fewest minutes of its own fuel at full burn, with its feed (`area` limits it to a box); the networks line names the lowest boiler (position, minutes, fuel, feeder), the 2 feed
  chests with the fewest minutes left (`feed chests: requester-chest (10,39) 50 coal, uses 15.0/min over 10 min, 3 min
  left`) and accumulators' stored MJ of their maximum; a logistic network's line ends with the items it holds most of
  and what its requesters ask (`holds iron-plate 4200, ...; requesters ask iron-plate 400 (300 short), ...`); on
  Fulgora, `networks` and `status` carry `storm`: lightning in the dark, the phase, darkness and the seconds to dusk,
  full dark, brightening and dawn; `./fh platform NAME` shows one space platform (hub free
  slots, cargo, speed, next stop, ETA; `hub_chunks`, `ammo_rates` per ammo type made and used over the last leg with
  the reserve at arrival, `incoming` rockets);
  `./fh call inspect` on a roboport or logistic chest shows its network and, for a roboport, its own area and robots,
  or that no roboport's logistic area covers the chest), and `retro`: the previous shift for the team (research done, losses, the top failures and who had them,
  open board items) and the last 3 shifts' team numbers (`progress shift13: SPM ... | packs .../min | techs ... |
  rockets ... | plates, circuits .../min | deaths ...`, as `./fh progress` counts them). `projects` lists the open projects, one line each with progress, next step and handoff.
- `./fh tell`: The reply's `ignoring` names a recipient in a wait that ignores messages (and until when); `--wake` ends that wait too, once per 10 minutes per teammate.
  Viewers see tells on the stream's logistics ticker. `./fh tells` lists the last 30 tells you received
  (time, sender, fyi), shown before or not; `./fh tells --since N` lists the ones you sent and received after N.
- `OPERATOR:` lines: fh prints each message once;
  later replies that still carry it leave it out (`--operator-repeat` prints it on every reply). With `--format json`
  stdout is one JSON document and the message is only in the reply's `result.operator`.
- Lessons: short rules a teammate tested, board items of kind `lesson`. `lesson_add {rule, cause?, fix?, evidence_tick?,
  invalidated_when?, item | recipe | entity | action, surface?, position | area?, supersedes?}` (a lesson it supersedes
  is retired); `lesson_edit {id, ...}` (any teammate; the earlier versions kept, last 8); `lesson_verify {id}` (last
  verified now); `lessons {item | recipe | entity | action | near | surface}` reads them. A call on a lesson's item,
  recipe, entity or action (at its place and on its surface when it names them: inspect, trace, build, place_ghosts,
  transfer, feed, collect, configure, load_silo, launch, craft, mine, rearm, refuel) carries up to 2 lines in
  `lessons`, each with who recorded it, its evidence tick and when it was last verified; one not verified for 12 game
  hours reads `stale`. At most 150 active.
- A belt carrying items destroyed: the owner of the claim it lies in (else the nearest agent there) gets a waking tell
  with each belt's position and direction and what it carried.
- `board_progress {owner?, id?}`: each owned open task, request and project with the game's evidence since its last
  10-minute check (entities built in its area or its owner's claims, what it needs reaching the count, shipment lines
  of platforms it names, board edits), the age of its last change, the owner's repeated failures and no-effect
  actions, and its state: progress, waiting (owner in a wait or running queue), unchanged, stalled (unchanged across 2
  checks, with the 20-minute rule). Each check also puts one line in the owner's reply.
- `board_critical`: blocked items, those the team plan names (#id) first, then by how many open items wait on them,
  with what each waits on; and the agents standing or waiting now.
- Lessons: `lesson_add`/`lesson_edit` take `impact` (0..5) and `prevented`, `control` (what must change), `check` (a
  wait_until condition: the lesson reads unresolved until it holds) and `failure` (its failure's words). Matched lessons
  rank by score (impact, keys, verifications, recency); before a launch, platform_schedule, construct or load_silo (their
  dry runs, preflight and queued steps too) the best one shows with its score and check. An action key and the names
  both must match. `lesson_review`: counts (stale, unresolved, superseded, duplicates, shown and followed by their
  failure or not).
- `ground_rule_add {text, lessons, exceptions?, supersedes?}`, `ground_rule_retire {id}`, `ground_rules`: up to 8 team
  rules, shown once at each shift start in team.shift with their lessons' evidence.
- `board_focus {id, step, blocker?, verify?}`: your current item and step, blocker and next verification in one line,
  shown on status and in your team block every 10 game minutes; `board_focus {agent?}` reads teammates' focus lines.
  A focused project step not done across 2 checks reads so here and in board_progress.
