# The features the team never uses, and why

Nick asked why the team never uses most of the game: trains, robots, logistic chests, circuits, modules and
beacons, solar and nuclear, walls, better turrets, vehicles, quality, and other planets. This study covers the
agents' side across the long run on world n (shake4 to shake10, one save; shake3, a separate base-game world, for
comparison): what was researched and when, what was built, what the agents said about each feature, how research is
chosen, and whether anyone changes the team's approach. A second engineer audits what the tools can do
(eng/coverage); where the agents' words point at a tool gap, this study says so and leaves the audit to that branch.
shake9 never launched its agents and has no data; shake11 had not started. Times are PDT; game minutes are
tick/3600 from shake4's start. Data only, read-only on the game.

## P1

1. **Loss incidents quarantine the runtime in a long world (fixed on branch fix/loss-incidents, 8f7f1c2).** shake10
   lost 80 minutes, 20:37 to 21:58, to repeated runtime quarantines: 2,664 requests refused (Opus 2,489, Gemini 118,
   Sol 23), nine harness requests, defence and the platform cargo stalled. The three errors the agents quoted
   ("runtime:7985 attempt to compare nil with number", "runtime:7979 arithmetic on field last", "runtime:7998 compare
   number with nil", shake10 notes) are `record_loss` and `losses_since` in `runtime.lua:596-624`: a new incident got
   its `last` tick only after the 64-incident cap compared every incident's `last`. A long world reaches 64 incidents;
   main had the same code. The branch sets the tick first and reads `last` with a fallback, so a save holding the
   broken incident loads; a new case in `mod/tests/runtime_test.lua` reproduces the crash, and all 29 Lua suites pass.
   Merge it before the next shift.
2. **Nothing tells the agents that research finished or what it unlocked.** The mod has no research-finished event
   and no reply lists new recipes; agents learn by polling `research` or from a teammate (section 3). Things on the
   prompt's milestone path are used within minutes; everything else waits hours or forever. A team-block line when a
   technology finishes, naming what it unlocked (recipes, buildings, turrets) and which technologies just became
   researchable, would tell all nine at once; the second half is what reaches features nobody has researched yet
   (railway, circuit network, gates, accumulators).
   File: `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua` (an `on_research_finished` handler) and
   `board.lua` (`M.team`), and one line in `agent/team.md` saying the line exists.
3. **One sentence of the Space Age brief became the research plan.** The brief reports three test flights (4 turrets
   destroyed, 12 destroyed, and "One with 21 turrets and physical projectile damage and weapon shooting speed
   researched to level 6 arrived undamaged", `agent/spaceage.md:40-43`); it does not say whether the turret count or
   the research levels made the difference, or that nothing between was tried. The agents read the third as a
   requirement ("21turrets+damage6 testrequirements", Astra, shake7 14:37; Sol,
   shake10 20:15: "21gunswithdamage6/speed6 testedhealthy"). From Vulcanus discovery (shake8 18:22) to the end of
   shake10, every technology researched was a damage or shooting-speed level (6 of 6 in shake10), and 2,505 space
   science packs were made and never used. State what was and was not tested (21 turrets without the upgrades, and
   fewer turrets with them, were not). File: `agent/spaceage.md`.
4. **The score cannot see most of these features.** `entities` in `scores.jsonl` counts a fixed list of 29 names
   (`tools/pog.py`, `SCORE_LUA`): no turrets, walls, gates, chests, roboports, robots, rails, locomotives, combinators,
   beacons, accumulators or modules. Add them, so the next study, the stream and the site can show what the team
   uses. File: `tools/pog.py`.

## Short answer

- **Most features were never on anyone's mind.** No agent text in any run mentions trains, the circuit network,
  nuclear power, flamethrower turrets, cars or tanks, gates, accumulators, quality as a goal, express belts or
  roboports, and none was ever researched or built. Railway was available from shake5, the circuit network from
  shake4's green science.
- **What was researched follows the prompt.** The research order is the playbook's milestone list and then the Space
  Age brief's milestones, step by step: oil, plastics, blue science, silo, platform, space science, Vulcanus. After
  that came one sentence of the brief (P1 item 3). Research is a goal in itself ("get as far up the tech tree as you
  can", `agent/PLAYBOOK.md:10`); nothing in the prompts or the tools treats using what it unlocks as part of the job.
- **Unlocks off that path are not noticed.** The harness says nothing when a technology lands (P1 item 2). Medium
  poles waited 118 minutes, heavy armour 394, advanced oil 458; logistic robots, roboports, big poles and
  productivity modules were never used.
- **The few proposals to change the approach lost to the current plan.** Sol proposed the logistic system twice
  ("bots/requesterchests wouldend manualcourier bottleneck", shake8 18:28); Opus, who holds the research queue,
  queued it once and replaced it with military research. Construction robots were made only after the operator asked
  (56 in a chest), and no one ever built or named a roboport.
- **Jobs are fixed in shake4's first five minutes and kept for six shifts.** Each shift opens "X back on <same job>".
  There is no team-level plan beyond board claims; `team-tools/` held one courier file in eight hours.
- **Defence stayed hand-fed.** 132 turrets built, 4,204 magazines hand-crafted, 223 `rearm` calls; Haiku's job for
  six shifts was rearming turrets. The one belt-fed line (4 guns behind a wall) came in shake10, about 11 hours in.
- **The tools were rarely the reason.** Two features were blocked by a missing tool in the agents' words: throwing
  grenades (Sol's harness request in shake7; `use_item` landed at 18:27 today, after shake10 started) and platform
  editing (configure, inspect and tile removal on a platform). Everything else was silence or priority.

## 1. Inventory: researched, available, built

Research per run (`scores.jsonl` `research_done`; available = all prerequisites researched, not trigger-only, from
`tools/analyst/kb/space-age-2.0.77/technologies.json`):

| Run | Technologies | Researched in the run | Available, not researched, at the end |
| --- | --- | --- | --- |
| shake3 (base game) | 2 to 15 | up to oil processing | 17, incl. circuit-network, solar-energy, stone-wall, landfill |
| shake4 | 0 to 24 | to chemical science, stone-wall (90.7m), radar, gun-turret | 23, incl. circuit-network, advanced-oil-processing, modules, solar-energy, landfill |
| shake5 | 24 to 29 | advanced-oil-processing, logistics-2, fast-inserter, battery, electric-energy-distribution-1 | 25, incl. railway, automobilism, accumulators, laser, solar-energy |
| shake6 | 29 to 32 | processing-unit, low-density-structure, flammables | 23 |
| shake7 | 32 to 62 | military-2 and the first damage and speed levels, heavy-armor, robotics (292.4m), logistic-robotics, rocket-silo (380.5m), solar-energy (388.5m), modules, space-platform, construction-robotics (408.4m), bulk-inserter, space-science-pack | 30, incl. railway, circuit-network, logistic-system, gate, flamethrower, laser, quality-module, uranium-mining |
| shake8 | 63 to 66 | utility-science-pack, mining-productivity-2, planet-discovery-vulcanus (558.6m) | 27 |
| shake10 | 66 to 72 | physical-projectile-damage 3 to 5, weapon-shooting-speed 3 to 5 (damage-6 researching at the end) | 27: automobilism, circuit-network, accumulators, flamethrower, gate, landfill, laser, logistic-system, military-3, modular-armor, quality-module, railway, uranium-mining, and 14 more |

Pace: 30 technologies in shake7's 234 game minutes, 3 in shake8's 77, 6 in shake10's 199. Space science: 5,665
packs made by shake10's end, 1,352 used; none used after shake8.

What was built, from every successful `build`, `place_ghosts`, `craft`, `transfer` and `configure` request in the
journals (the score's entity counts where it has them):

- Trains, circuit network, combinators, lamps, gates, accumulators, nuclear, cars and tanks, flamethrower and laser
  turrets, beacons, quality, express belts, big poles and substations, landfill: nothing, ever.
- Robots: 5 frames and 4 construction robots hand-crafted (Gemini, shake7 15:52), then an assembler cell making
  them (27 in a chest by 16:27, 56 by the end of shake7, Gemini's notes); 0 roboports, 0 logistic robots, 0 logistic
  chests.
- Modules: 11 speed and 23 efficiency modules hand-crafted (Sol); 4 speed modules put into two processing-unit
  assemblers (shake8 18:22:55, `assembling_machine_modules`), the rest into a chest or rocket cargo for the
  platform; no assembler ever made modules.
- Solar: 19 panels at shake10's end (the score counts every surface, so platforms are included), against 20 steam
  engines on the ground; 0 accumulators.
- Walls: 275 crafted, 64 built, 108 ghosts; shake10 built none directly (58 ghosts, plus Astra's and Sol's queued
  segments).
- Turrets: 319 crafted, 132 built; 4,204 firearm magazines and 102 piercing magazines hand-crafted; 223 `rearm`
  calls.
- Space: 1 silo, 17 rockets, 2 platforms (Solstice for science, Helios for flight), both at Nauvis in every score
  line; `planets` is `["nauvis"]` at the end of every run.
- Machines: 86 steel furnaces, 87 assembling machine 2, 2 electric furnaces, 34 fast inserters, 1,338 yellow belts;
  no assembling machine 3 (production science never researched), no bulk inserter placed.
- Blueprints: 425 requests, all Sol's, all for the space platform.

Caveat: the journals show what agents asked for. Items an assembler made and an inserter moved are invisible unless
an agent touched them (P1 item 4).

## 2. Why each feature went unused

Categories: never mentioned; mentioned but no tool; tried and failed; planned then dropped; deliberately rejected;
used. Counts are mentions in the agents' own text (say, tell, board, notes, harness requests, transcripts' messages
and reasoning; tool output excluded).

**Never mentioned.**
- Trains: 0 mentions in talk; railway's only appearance is a side effect. Sonnet replaced the queue at shake5
  05:40:12 with `["battery","mining-productivity-1","stack-inserter","solar-energy","railway"]`; `stack-inserter` is
  a Gleba technology in Space Age, so the harness added 35 prerequisites and railway sat 17th in `pending` until the
  queue was replaced. A wrong belief about a technology name, carried out by the harness's prerequisite expansion.
- Circuit network and combinators: 0; every "wire" is power wiring ("Radar wired at (17.5,-11.5)", Luna, shake10).
- Nuclear, flamethrower turrets, cars, tanks, gates, accumulators: 0. Laser turrets: one item in a research queue
  (Opus, shake7 15:55). "Evolution" appears in no agent text in any run.
- Roboports: the word never appears in any agent's own text, only in tool output.
- Quality: listed once among options (Astra's priority note, shake7) and passed over; Sol's scripts treat any
  non-normal quality as an error.
- Express belts and beacons: 0; both need production science, never researched.
- Solar for the ground grid: every solar plan is platform power, though power shortages recur from shake5 on (Opus,
  shake10 19:05: "Power: boilers starve, coal trunk x25.5 nearly empty").

**Mentioned but no tool.**
- Grenades: Sol's harness request, shake7 13:10:02: "Military2 unlocksgrenades but describe exposes shoot only (gun
  ammo), no way to throw grenades against large raids/nests. | Add use_item action". Astra: "Toolcheck: no
  grenade/capsule-use action exposed, skipgrenades; turretcreep only." `use_item` (28b5dfa, request #89) arrived after
  shake10's launch; shake11 is the first shift with it.
- Platform editing: "Bot remoteplatform place_ghosts invalid PlayerIdentification" (shake7 15:38), "Platform paste
  returns0 despite empty powered floor" (16:08), "Remote platform tile deconstruction ... no way to remove platform
  floor" (shake8 17:33), "configure platform=Helios rejected unknown argument. Cannot inspect inserter filters on
  platform" (shake10 20:23). Some are answered on main (tile deconstruction, 64bb874); the coverage audit has the rest.

**Tried and failed (and kept going).** Walls: "build 13/17 failed after 12 built: position is out of build reach"
(Haiku, shake5 05:56); "placement blocked by tree-07" then "unknown argument builds for place_ghosts" (Haiku, shake6
07:32). Their own limit was material: "I have only 3 iron, so I cannot craft turrets for the west strip. I hold 44
mags and 49 stone walls" (Haiku, shake6 07:31).

**Planned, then dropped.**
- Logistic system: planned three times. Astra's priority note, shake7 15:10 ("unlocks requester, buffer and
  active-provider chests; it can replace repetitive science and silo couriers"); Opus queued it third at 15:32 and
  replaced the queue with military research at 15:55; Sol to Opus, shake8 17:08 ("Suggest logistic-system
  afterVulcanus ... free couriers fornewplanet") and 18:28 ("bots/requesterchests wouldend manualcourier
  bottleneckPU/steel/floor andlet Solleaveplanet ... Thoughts?"). No reply changed the queue.
- Construction robots: made for the platform ghost bug at the operator's request (Sol, shake7 15:42: "Nick:
  construction robots would help. Orbital building currently fails with Invalid PlayerIdentification"); the step that
  would use them, a roboport or a personal roboport, never came. Luna: "useful for later platform repair, but I'll
  keep my assignment on labs and research" (16:02).
- Other planets: Vulcanus discovery researched (shake8 18:22), Helios designed ("Flightfinal16rockets800fuelPU/LDS,
  31guns600piercing", Sol, 17:16), then raids ("Flightcanwait,keepironoutpostalive", 18:10), then shake10's
  quarantines ("Helios250floorbuilt133remain", Sol's notes).

**A wrong belief about tools.** Sonnet's notes from shake5 to shake10 list "an ammo assembler plus belt to turrets"
under tool changes that would help; it needs no new tool, and Astra built one in shake10 (20:17 to 20:29: "VERIFIED
new4guns ... feedinserterspowered, southwallcomplete11h09").

**Deliberately rejected.** None found. No agent argued against trains, circuits, bots, solar or better turrets; they
were not weighed at all.

**Used.** Advanced oil and cracking (Gemini, from shake7: "Cracking online ... AOP unblocked, 3500+ lube buffer");
steel and electric furnaces, assembling machine 2, fast inserters; light and heavy armour (no equipment, modular
armour never researched); rockets and platforms; blueprints for the platform (Sol); modules in two assemblers and on
the platform (Sol).

## 3. Research: who chooses it, and what happens when it lands

- **Set rarely, by one agent.** 70 research-setting calls in seven runs, about 10 a shift. Opus holds the queue from
  shake4 (11 of 20 calls in shake4, 18 of 19 in shake7); others ask Opus by tell ("Wall research queued with Opus
  approval", Astra, shake4 04:20). In shake10 Opus set none; Sol and Gemini set the same queue 2 s apart after
  agreeing by tell. Opus, the queue's owner, ran with 187 unread chat lines through shake7, so proposals reach it only
  by tell.
- **Chosen by the milestone list.** Opus, shake4 03:20: "Research queue switched to the oil path: automation-2,
  engine, fluid-handling, oil-gathering". Opus, shake8 17:07: "Research queue: Vulcanus discovery, then projectile
  damage/shooting speed 3-5 so the Vulcanus ship survives asteroids." Sol and Gemini, shake10 20:15: damage-6 before
  speed-6.
- **Not announced when it lands.** No research-finished event in the mod; `status` carries `research {name,
  progress}` and `research` reports current, progress and queue; nothing lists what a finished technology unlocked.
  Gemini read `research` 92 times in shake7 and Luna 83 in shake5; most agents under 15 times a shift; Astra, Sol,
  Haiku, Sonnet and Muse almost never. Every research news line in sampled replies came from a teammate: "Concrete
  unlocked4h42; configured our asm2" (Astra's tell, shake7 13:37).
- **Time from a finished technology to first use** of something it unlocks (any agent's craft, build, queue or
  recipe setting):

| Technology | Finished | First use | Gap |
| --- | --- | --- | --- |
| stone-wall, fast-inserter, rocket-silo, solar-energy (platform), speed-module, processing-unit and the rocket parts | shake4 to shake7 | queued before or within 2 min | 0 to 2 min |
| steel-processing | shake4 03:19 | steel plate (Astra) | 34 min |
| advanced-material-processing (steel furnace) | shake4 04:49 | steel furnace (Astra, shake5) | 59 min |
| electric-energy-distribution-1 | shake5 05:27 | medium pole (Sol, shake6) | 118 min |
| robotics | shake7 13:49 | robot frame (Gemini) | 123 min |
| military-2 (piercing rounds) | shake7 13:05 | piercing magazine (Sol) | 173 min |
| heavy-armor | shake7 13:19 | heavy armour (Sol, shake10) | 394 min |
| advanced-oil-processing | shake5 05:51 | recipe set (Gemini, shake7 13:30) | 458 min |
| logistic-robotics, electric-energy-distribution-2, productivity-module | shake7 | never | - |

## 4. Planning and lock-in

- **No team plan.** The board carries claims and requests; no board item is a team plan. `team-tools/` held 0 files
  in shake7, 1 in shake8 (`science_courier_oldlabs.json`), 0 in shake10. Plans exist per job: Sol's `tools/` holds 20
  platform plans and audits; Sol and Astra plan through their own Codex subagents ("Root audited plan is56extra
  foundation AFTERstarter60", Sol, shake7 14:31).
- **Jobs from the first five minutes of shake4 (02:52 to 02:57) held for six shifts:** Opus the science courier, Muse
  copper ("Muse back on copper for the new shift", shake7), Grok power and green ("Back on power and green", shake8),
  Gemini oil and chemistry, Haiku turrets and ammo ("I hold 100 mags for refills", shake6), Astra coal, fuel,
  plastics and steel, Sol circuits and blue science then the platform, Luna iron and couriers, Sonnet stone and iron
  hauling. Resumed shifts start from each agent's own notes, which carry the job forward.
- **Approach changes, proposed and taken up:**
  - Clearing nests instead of rebuilding (Astra, shake7 13:03: "We cannot keep rebuilding 100biter raid damage"):
    taken up; military research jumped the queue and Opus cleared three spawners.
  - The logistic system (Sol, shake8, twice): not taken up.
  - Construction robots (the operator, shake7): built, never deployed.
  - Ground power: no proposal in any run to move off steam.
  - Defence in shake10 (evolution about 0.40 by the brief; the agents never mention evolution): a side job for
    whoever was near. Haiku hand-crafted magazines and placed spare turrets; Sol added five guns with walls ("walls
    preventturretmelee", 19:58); Opus crafted 10 turrets and 400 magazines to turret-creep the south nest (20:00) and died beside it; Astra built the one
    belt-fed line (4 guns, 20:17 to 20:29). Hand feeding in shake10: 26 `rearm` calls, 59 magazine transfers (Haiku
    41), 34 queued ammo plans, 45 magazine crafts. The agents' own verdict: "ammo ran dry (rearm drains everything)"
    (Sonnet's notes); "furnace makes only9mags/min. Please prioritize southern ammo/walls" (Sol, 20:21). Then the
    runtime froze (P1 item 1).

## 5. Summary table

Why-categories: **silent** (never mentioned), **no tool** (agents say a tool is missing), **failed** (tried, error),
**dropped** (planned, then dropped), **path** (researched only as far as the milestone list needs), **used**.
The last column is about the tools and environment only.

| Feature | Available since | Used? | Why not | What in the tools or environment would change it |
| --- | --- | --- | --- | --- |
| Trains | shake5 (158.5m) | no | silent | the research-finished line's "now researchable" part (P1 2) |
| Logistic robots, roboports, logistic chests | shake7 (292-298m) | robots made, never deployed | dropped (research priority), silent on roboports | P1 2; the score counting roboports and chests (P1 4) |
| Requester/buffer chests (logistic-system) | shake7 (434m) | no | dropped | P1 2; proposals to the queue owner arrive by tell only |
| Circuit network, combinators | shake4 (26.6m) | no | silent | P1 2 |
| Modules | shake4 (96.8m); researched shake7 | 4 in machines, rest on the platform | path | P1 2 |
| Beacons, assembler 3, express belts | needs production science | no | path (never researched) | P1 3 (the research plan stops at damage levels) |
| Solar (ground), accumulators | shake4 (28.6m) / shake5 | platform only; 0 accumulators | silent | P1 2; a power report that says how much of the grid is steam (status `reports`) |
| Nuclear | shake7 (uranium-mining) | no | silent | P1 2 |
| Advanced oil, cracking | shake4 (108.8m) | yes, after 458 min | used late | P1 2 |
| Quality | shake7 (392.6m) | no | silent | none needed for now |
| Flamethrower, laser turrets | shake7 / shake5 | no | silent | P1 2 |
| Walls | shake4 (10.5m) | thinly (64 built) | failed (reach, trees) and material | none: the errors already say what to do |
| Gates | shake7 (250.2m) | no | silent | P1 2 |
| Inserter-fed ammo | from the start | 4 guns, shake10 | wrong belief (a "tool change" in Sonnet's notes) | none: it needs no new tool |
| Grenades | shake7 (military-2) | no (made for science) | no tool | `use_item` is on main (28b5dfa); shake11 is the first shift with it |
| Cars, tanks | shake5 (158.5m) | no | silent | P1 2 |
| Armour, equipment | heavy shake7; modular never | light and heavy | path | P1 2 |
| Platforms, rockets | shake7 | yes | used | the platform tool requests in the coverage audit |
| Other planets | shake8 (558.6m) | no | dropped (raids, platform tools, shake10 faults) | P1 1; the platform tool requests |

## Methods

Scripts in the session scratchpad, read-only on `runs/`: research timelines and available sets from `scores.jsonl`
and the Space Age game data in `tools/analyst/kb/`; builds, crafts, ghosts, transfers, blueprints and recipe settings
from every journal (request and response pairs by id); agent text from say, tell, board and harness requests, notes,
chat, `tools/` and `team-tools/`, and the transcripts of all five harnesses (messages, reasoning and commands only, no
tool output); research calls and reads per agent; unlock-to-first-use by matching each technology's unlocked recipes
against later requests. The loss-incident bug was matched by rebuilding the deployed runtime bundle (the deployed
hash, `2d7f0cd970be`, reproduces from 9ca7ada) and reading the incident code, then reproduced in
`mod/tests/runtime_test.lua` on fix/loss-incidents. The bundle line numbers in the agents' errors are 287 lines past
that bundle's `record_loss`, so the runtime running at 20:37 was another build of the same code; the errors' texts
match `runtime.lua:602`, `:608` and `:621` exactly.
