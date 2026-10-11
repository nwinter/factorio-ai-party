# Study: shake1, nine AI agents sharing one Factorio world

Run: 2026-10-10, 17:00 to 18:00 PDT. World `n`, seed 20261010, normal enemies, real time. Each agent had about 59 minutes; deadlines were staggered by launch order from 17:59 to 18:01. The nine agents had identical instructions apart from name and model, and no roles were assigned.

Sources: `runs/shake1/*/journal.jsonl`, `notes.md` and `supervisor.log` for each agent; `scores.jsonl`, `final-score.json`, `operator-interventions.log` and `start.log`; profiles from `fh call profiles`. The team chat was rebuilt from every agent's `chat` responses and `say` requests: 365 messages, seq 1 to 365 with no gaps. It is saved as `runs/shake1/chat-full.jsonl`. Game time is tick/3600. Quotes are verbatim, and Sol's run-together words are left as written. The world kept running after the deadline, so score snapshots after `final-score.json` (18:02) are ignored.

## 1. Summary and outcome

The team finished milestones 1 to 5 and ran out of time partway through the research path to oil. It researched 14 technologies. Oil-gathering stood at 61 to 67% when the deadline hit (agents report different values), so the team never produced crude, plastics or blue science. Final factory: 18 labs, 16 assemblers, 9 electric and 15 burner drills. Lifetime totals: 572 red packs, 362 green packs, 998 circuits and 12,470 iron plates. Hand-crafted items count toward these only after the 31m harness update.

| Milestone | Game time | Evidence |
|---|---|---|
| Burner mining on iron, copper, stone and coal, with smelting | ~4m25s | Sol's record; snapshot at 4.2m shows 7 burner drills and 6 furnaces |
| Research blocked by the craft-trigger bug | 8m13s to 15m14s | Luna crafted the first lab at 8m13s; operator unlock in chat at 15m14s (`operator-interventions.log` 17:13) |
| Steam power live | 12m42s | Astra connected the engine Gemini built: "POWER LIVE game12m42s!" |
| Automation; electric mining drill | 16m41s; 17m44s | chat, and the 18.2m snapshot |
| Red science from assemblers | ~18m17s | Haiku's assembler at 5.5,0.5, powered by a pole Gemini placed |
| Logistics; logistic-science-pack | ~20m15s; ~23m | snapshots at 20.2m and 24.3m |
| First green packs from assemblers | 23m47s (Grok, chest-fed); 25m51s (Muse line) | chat |
| Steel processing; gun turret | by 26.3m; ~29m | gun turret was put at the front of the queue after the first raid |
| Automation-2; engine; fast inserter; fluid handling | ~36m; 48m55s; ~50m; 54m01s | snapshots and chat |
| Fully automated green chain | 51m52s | Astra: "all4newASM2 GREEN machines WORKING" |
| Oil-gathering | not reached (61 to 67%) | final chat lines and notes |

Iron sets the shape of the run. Output was about 220 plates/min from 14 to 28m. Astra repaired Sol's broken ore belts at about 28m, after which output rose to about 300 to 440/min, with dips. A biter raid wiped out the west coal field and part of the iron mines around 50 to 53m. Iron then fell to about 40/min at 54m and to about 0 by 60m, while burner drills dropped from 45 to 15. Green output peaked at 31/min (52 to 54m) and then collapsed. At the deadline Luna counted "2/18 labs working ... with 16 missing science packs."

## 2. Per agent

### Identities (all set in the first 4.5 game minutes; Sonnet never set one)

| Agent (model, harness) | Name | Glyph | Colour | Motto |
|---|---|---|---|---|
| astra (GPT-6 Astra, Codex) | Astra | AS | #9977ff violet | "Copper, circuits, onward." |
| sol (GPT-6.1 Sol, Codex) | Sol | S | #ffcb45 yellow | "Keep the factory moving" |
| luna (GPT-6 Luna, Codex) | Luna | L | #b58cff lavender | "Power and science from spawn" |
| opus (Claude Opus 5.5, Claude Code) | Opus | O | #d97757 terracotta | "Coal, steam, and steady science" |
| sonnet (Claude Sonnet 5.5, Claude Code) | none set | none | default | none |
| haiku (Claude Haiku 5.5, Claude Code) | Haiku | H | #e07a2f orange | "Iron and steam, one drill at a time." |
| grok (Grok 4.7, Grok Build) | Grok | G | #1a1a1a near-black | "Belts, gears, and the mall." |
| gemini (Gemini 3.8 Flash, Antigravity) | Gemini | ♊ | #4285F4 blue | "Speed, precision, scale." |
| muse (Muse Spark 1.3, Muse Code) | Muse | 🔧 | #7dd3fc sky | "feed the furnaces" |

Patterns in the identities:
- Every agent used its model name; nobody invented a persona.
- Most mottos state the role the agent claimed first, so they read as job titles.
- Gemini's motto is a slogan rather than a role.
- Astra and Luna chose two similar purples that are hard to tell apart on stream, and Grok's near-black may be hard to see on the map.

### Activity

"Decisions" means requests other than `status` and `queue_status`. "Idle" is the tick-weighted share of game time the harness clock reported the character as idle, meaning no timed action was running; the factory keeps running regardless. "Chat read" is the share of teammates' messages the agent pulled with `chat`. "Placed" counts entities sent through `build` and `place_ghosts`. It leaves out route tools: Sol also routed 137 poles and 329 pipes.

| Agent | Decisions | Says | Chat reads (coverage) | Idle | Errors (rate) | Placed | Deaths | Stopped early |
|---|---|---|---|---|---|---|---|---|
| astra | 611 | 67 | 95 (66%) | 85% | 12 (2.0%) | 302 | 1 | no, 0 nudges |
| sol | 710 | 81 | 154 (84%) | 77% | 34 (4.8%) | 353 | 0 | no, 0 nudges |
| luna | 413 | 42 | 46 (50%) | 92% | 17 (4.1%) | 2 | 0 | no, 0 nudges |
| opus | 427 (+517 queued steps) | 23 | 25 (50%) | 45% | 35 (8.2%) | 64 | 2 | yes: summary at 17:50, last act 17:55, 1 nudge |
| sonnet | 570 | 17 | 18 (43%) | 16% | 61 (10.7%) | 12 | 1 | yes: "Signing off" at 17:54, last act 17:55 |
| haiku | 1050 | 38 | 57 (50%) | 69% | 74 (7.0%) | 25 | ≥2 (notes say 4) | yes: summary at 17:37, silent in chat after 33m, 3 nudges |
| grok | 667 | 33 | 5 (15%) | 78% | 63 (9.4%) | 39 | 2 | no, 0 nudges |
| gemini | 593 | 28 | 45 (39%) | 83% | 49 (8.3%) | ~18 (+148 trial ghosts) | 0 found | no (own restart loop) |
| muse | 490 | 34 | 26 (57%) | 88% | 25 (5.1%) | 11 | 1 | yes: "winding down" at 37m, last act 17:51, 4 nudges |

### Sol (GPT-6.1): iron lead who became operations lead

Sol posted first, at 2m10: "Sol here. I will expand iron mining/smelting; who is handling power and science?" That question started the role allocation. Sol's work:
- Built 9 burner iron cells, then a 12-furnace belt-fed row with 7 electric drills, which was the team's main iron supply.
- Scouted oil, then built a 51-pole power line and a 327-pipe crude pipeline.
- Built 6 belt-fed labs with automatic red and green feeds.
- Ran power audits and named the missing jobs: "Need packs courier now +belt-fed labs. ... CanLuna handlecourier, Musegreen,Grok/Haiku labs/red?"

Sol received 72 of the 321 times one agent named another in chat, the most on the team. Mistakes:
- Announced a handoff chest before it existed, then corrected it ("Correction: handoff build raced crafting and failed").
- Left an ore-belt disconnection that idled 8 of 12 furnaces until Astra found it.
- Put about 13 minutes (22m52 to 36m05) into oil infrastructure that research didn't reach in time.
- Built a lab bus where both science feeds landed on one lane. Sol diagnosed it at 58m53: "BOTHscienceautofeeds fillR; Lempty."

From about 25m on, Sol's messages stripped out spaces (23 messages). The limit is 500 characters, so length wasn't the cause. Sol's notes are the most complete handoff on the team (19 KB, with coordinates and inventory), and they are self-critical: "Too much time was spent auditing and repairing layouts rather than advancing research."

### Astra (GPT-6 Astra): copper and circuits, then the team's systems fixer

Astra claimed copper at 2m17 and kept it. Astra's work:
- Arbitrated the first role conflict: "Opus and Luna both offered power: suggest Opus coal, Luna power/labs."
- Set the research queue at 8.9m.
- Laid the power backbone and connected the first engine.
- Got circuits running at 16m57.
- Found and fixed Sol's ore belt ("only4/12 belt-fed furnaces working").
- Took over Muse's green line, with Muse's agreement, and built the only fully automated green chain (51m52s).
- Added 6 labs at 56m.

Astra had the lowest error rate on the team (2.0%) and asked permission before entering other agents' claims ("May I repair output belts in your old claim while you scout?"). Mistakes:
- A radius `collect` emptied the boiler chest. Astra owned it: "Sorry, collect radius chooses nearest chest automatically."
- Mixed belt lanes stalled the green header for several minutes.
- Pushed fast inserter ahead of fluid handling at 49.5m.

Astra found and shared the corpse-recovery trick: "Corpse recovery works with MINE ... transfer does NOT support corpse inventory." The notes are dense and accurate.

### Luna (GPT-6 Luna): careful helper with little effect on the factory

Luna claimed "steam power and red science/labs from spawn" and crafted the first lab. Gemini built the steam plant. Luna then worked as a courier, built a stone-brick furnace, and relayed state to others. Luna placed only 2 entities, spent 73% of decisions on looking and talking (148 `observe` calls), and had the highest idle share (92%).

Luna's chat is polite and careful, and sometimes answers messages meant for others: "Astra: I do not claim the north iron row; Sol built it" replied to a message addressed to Sol. Luna also took Gemini's brick request after Sonnet didn't respond. Luna's one mistake was a parallel belt-ghost route over Sol's red-feed route, which she reported and removed. Her notes are well organised, accurate and credit others; their final-state detail ("2/18 labs working") is among the most useful.

### Opus (Claude Opus 5.5): quiet logistics engine

Opus claimed "coal mining + steam power" and in practice ran the team's fuel and power:
- 3 burner coal clusters, about 19 drills ("~600 coal per run", self-reported).
- A burner-inserter coal feed for the boilers.
- Doubled power to 3.6 MW at 25m51.
- 157 steel for oil (own count; chat says 100+).
- 3 turrets, 2 labs, and hand-crafted red packs.

Opus relied on in-game queue plans far more than anyone else (45 submissions, 517 steps; Astra and Sol mostly used queues to clear trees), which is why it shows few decisions and low idle time. Its chat is terse, factual and self-prefixed ("Opus: ..."). It named a teammate only 12 times and never thanked anyone. Mistakes:
- Added copper cells when, by its own later notes, copper sat idle in a glut ("~1400 idle").
- Staged steel in Sol's coal-feeder chest, as Sol had asked, which leaked steel onto the coal belt.
- Left the coal field undefended.

Opus finished its notes 10 minutes early and needed one nudge. The notes are short and sharp: "no one watched `status` losses closely enough to react before the whole field was gone."

### Sonnet (Claude Sonnet 5.5): stone hauler and red-pack crafter

Sonnet supplied stone and 10 furnaces early, hand-mined coal (105 `mine` calls), then hand-crafted red packs: 460 queued and roughly 270 delivered, by its own chat and transfer records. Sonnet also placed 2 turrets after the first raid. It is the only agent that never set a profile.

Sonnet sent the fewest messages (17), always self-prefixed, with no questions and no thanks. It ignored direct asks: "Sonnet please haul coal to copper drills" went unanswered and Luna and Haiku did the job. Sonnet had the highest error rate (10.7%), including 25 calls to the queue-only `wait_ticks` as a direct action. Its last 125 packs went into the red chest, which was blocked at the end. The notes are thin (2.4 KB) and wrong on one point: "my lab craft fired it" (the operator unlocked the tech). Sonnet signed off about 5 minutes before its deadline.

### Haiku (Claude Haiku 5.5): energetic hands-on builder with uneven judgement

Haiku went from iron cells to "coal runner" to building the red-science block: 2 red assemblers, a green assembler, and feeding labs. Haiku was the best early debugger:
- Published the burner drop-tile rule.
- Ran a controlled test of the lab trigger: "If the trigger fires, it confirms the hand-craft path is the problem."

Haiku had the most decisions (1050) and the longest messages (mean 230 characters). Mistakes:
- Placed two inserters backwards, pulling packs out of the labs for about 3 to 4 minutes. Haiku found and fixed this itself.
- Misread "0/78 low_power" as a power shortage. Haiku kept to that reading after three corrections ("No power problem", Sol at 27m09) and built a third boiler whose engine was never connected.
- Never spoke in chat after its second death at about 33m.
- Wrote its final summary at 17:37 and needed three nudges.

Haiku's notes contain good tool lessons. Some claims conflict with the record: corpses "were empty", although three teammates recovered theirs by mining them; and the trigger bug cost "about 2 minutes", when it was about 7.

### Grok (Grok 4.7): terse, steady builder and defender

Grok claimed a mall that it never built and 3 south iron cells. It then built a red assembler (20m30), two chest-fed green assemblers, and the most defence work: turrets, rearming, and a turret at -10,8 after the late south raid. Grok read chat only 5 times and otherwise relied on the "latest" line attached to each reply. When asked directly it answered cleanly, as in the boundary deal with Sol: "Sol: yes, drills centered x=-65 y=-44/-40 with footprints only x -66..-64 are fine."

Grok asked no questions in chat, and 32 of its 63 errors were wrong argument names or values. It died twice and worked until the deadline. Its notes are accurate and specific.

### Gemini (Gemini 3.8 Flash): steam builder and cheerleader

Gemini built the steam plant. It placed the offshore pump and boiler by submitting 100 and 48 position/direction variants in single `place_ghosts` calls. Gemini also:
- Supplied assemblers and inserters to Haiku through the hub chest.
- Built 3 of the 5 assemblers at Muse's green site.
- Stocked the oil cache with steel and bricks.
- Placed a turret.
- Announced research progress, using 71 `research` polls ("Engine researched at 48m55s!").

Its tone is upbeat ("Steam plant is UP and RUNNING ... Steam 200/200!"). It gave way readily: "Got it Muse, green science is yours!" Gemini also re-enabled, without asking, the circuit output inserter Astra had removed on purpose to save iron. Astra may have been planning to restore it by then. Its notes are polished but give Gemini credit for things others did, such as the second engine Sol built, and they declare milestone 5 at 23m50 from a hand-fed assembler.

### Muse (Muse Spark 1.3): friendly helper who quit early

Muse built iron cells and a public plate chest, claimed and started the green line ("MILESTONE: green science automated", 25m51, which was premature: the line starved for gears minutes later), placed a turret, and ran many courier trips. It handed over cleanly: "Astra: yes, take over my green machines + convert as needed." Its messages are short and warm ("Go oil team!").

Muse began "winding down to deadline" at 37m (about 17:35, with its deadline at 18:01), said "Clocking out" at 45m, and needed 4 nudges. The heading of its notes says "session ended game ~39m". It is unclear from the files whether this was a misread clock.

## 3. Team dynamics

**Roles came from announcing claims.** Within 6 minutes every agent had posted a role and coordinates, and the rest accepted them. Overlaps were settled by suggestion or by one side deferring:
- Astra split power between Luna and Opus.
- Gemini deferred to Muse on green science.
- Grok and Sol negotiated a tile-level boundary (seq 80 to 84).

Nobody proposed a leader. Sol and Astra became the coordinators in practice. Sol named the gaps and audited the factory, while Astra arbitrated and was the main hand on the research queue. Only those two ever ordered the queue (Astra at 8.9m, 22m and 49.5m; Sol at 28.6m and 46.9m).

**Handoffs mostly worked.** The spawn chest at 2.5,0.5 was named in 26 messages by all nine agents and became the team hub. Other caches (copper -38.5,-9.5, iron -47.5,-60.5, oil -52.5,-44.5, lab inputs -1.5,-8.5 and -1.5,-4.5) were announced with contents. The failures came from shared-chest hazards:
- Radius `collect` took teammates' stock (Astra and Muse both report this).
- Steel staged in a coal feeder fouled Sol's smelter belt.
- Muse: "every chest I stocked got drained within minutes."

**Agents asked permission inside others' claims.** Examples include Opus's copper cells in Astra's patch, Sol's second steam engine, Astra's repair of Sol's belts, Astra's iron bus, Muse's green handover, Sol's red tap and the extra lab rows. Every request was granted. The one objection, Grok's at seq 80, ended in a renegotiated boundary. There was no hostile conflict.

**Duplicated and unowned work cost more than conflict did:**
- Five agents hand-crafted labs to trip the broken trigger, Grok three times. Sonnet crafted one at 15.1m, after Sol had written "No extra lab attempts needed; 3+ confirmed bug."
- Four separate green efforts (Muse/Gemini, Grok, Haiku, Astra). Only Astra's was fully automated.
- Haiku's unneeded third boiler.
- Luna's ghost route over Sol's.
- Requests not addressed to anyone were not picked up. Sol asked Haiku and Grok to "expand toward10red assemblers" at 20m; the team never had more than 3. Sol asked for "~12labs" at 23m55; nobody built them until Sol did at 38m. "Opus/Gemini canbuild5morelabs" (30m) got no reply.

**Response to the operator.** When automation-science-pack was unlocked (15m14s), Haiku, Sonnet and Opus began hand-crafting red packs within 30 seconds, and Sol and Astra thanked the operator. The agents had also found the bug themselves: Astra flagged it to `server:` at 10m21, and Opus, Grok and Luna confirmed it. The hot deploy at 30m51 drew only a reply from Gemini ("Noted and standing by"). Nobody showed visible disruption; Opus resumed its queue.

**Response to raids**

| When | Where (from loss reports) | Losses | Response |
|---|---|---|---|
| ~28m | spawn science and steam, x 2..33, y 0..11 | 2 characters, lab, assembler, poles | Haiku reported it with coordinates; Sol pulled gun turret to the front of the queue (done ~29m); 5 turrets placed by Gemini, Sonnet and Opus by 30.5m. Fast and well coordinated. |
| ~32-34m | west copper, circuits, green and iron, x -64..-21 | ~6 characters, 22 belts, 5 furnaces, 4 poles | Gemini's "ALERT"; Sol named turret spots; Haiku, Opus, Astra, Grok and Muse placed 6 turrets by 37.5m. Many agents walked into the biters and died. |
| ~50-53m | west coal field and iron, x -89..-65, y -54..-18 | 27 burner drills, 15 belts, 13 chests, 7 furnaces | Grok went west and died. Opus reported it after the fact ("biters destroyed the whole coal field"). Nobody rebuilt; Sol fell back on plate buffers and Astra collected 260 stranded iron. |
| ~54m (late south raid) | south of spawn, x -13..-1, y 6..14 | assembler, inserters, belts, pole | Grok placed a turret at -10,8. Astra repaired the green output belts at 60m, freeing ~33 packs. |

No turrets were ever placed at the coal field or the north smelters. Sol had planned a refinery turret, but a tree blocked it.

**Patterns by model family**
- **Codex (Astra, Sol, Luna)** sent 52% of agent messages, with long messages (means of 178 to 212 characters; only Haiku's were longer), and 68% of agent-to-agent name mentions. They used the most "please" and "may I". All three worked to the exact deadline with no nudges. They clustered: Astra and Sol mentioned each other 38 times. They were also the slowest actors: idle 77 to 92%, with calls fired in bursts (median 0.2 s apart) followed by long pauses.
- **Claude (Opus, Sonnet, Haiku)** self-prefixed 73 of 78 messages ("Opus: ..."), picked supply roles (coal, stone, coal runner), and rarely talked to each other (6 of their 50 mentions). Opus and Sonnet replied to the person who addressed them by name about 1 time in 9 (rough heuristic). They had the lowest idle shares (16 to 69%), and all three stopped before the deadline. Haiku's verbosity is the outlier.
- **Others:** Grok was terse and action-first. Gemini was enthusiastic and ran a narration loop. Muse was concise and friendly but left early.

## 4. What limited the team

1. **Science throughput, not raw materials.** Labs stood at 5 to 6 until 38m and reached 18 only at 56m. Packs moved by courier for most of the run, and agents reported lab starvation repeatedly (seq 166, 172, 217, 311, 356, 359). The final lab bus put both packs on one lane, leaving 87 red packs stuck in the red chest.
2. **Iron, made worse by hand logistics.** Every assembler builder reported running short of iron, while copper sat unused (Opus: "~1400 idle"). Burner drills peaked at 45 and were fuelled by hand all game. Opus: "Everything was fueled by hand: no belts carried coal to boilers or burners."
3. **Defence.** Nobody placed a turret before the first raid, even though Luna noted pollution reaching nests at about 16m. About 10 characters died. The undefended 50m raid cut iron from ~400/min to ~0 just as oil-gathering began.
4. **Fragmentation and unowned requests.** There were four green lines and three red assemblers against a stated need for ten, and broadcast asks were left undone (section 3).
5. **Harness friction:**
   - The craft-trigger bug cost about 7 minutes. Agents' own estimates ranged from "about 2 minutes" (Haiku) to "~12 min" (Sonnet).
   - `construct` failed with "Invalid PlayerIdentification".
   - `pole_route` skipped corners, and `pipe_route` choked on its own ghosts.
   - `move_to` reports `arrived_near` as an error.
   - `./shot` timed out, so nobody could check layouts visually.
   - "0/78 low_power" was easy to misread.
   - Corpses could only be recovered with `mine`.
   - Radius `collect` raided neighbours' chests.
6. **Attention.**
   - Codex agents' characters stood idle most of the time.
   - Chat backlogs reached 57 unread messages (Haiku) and 48 (Sonnet); Grok barely read chat.
   - Haiku, Muse, Opus and Sonnet ended their turns 5 to 25 minutes early, and supervisor nudges won back only part of that time.

## 5. Recommendations

**Playbook (AGENTS.md)**
- Pick a coordinator by 3m who owns the research queue and a shared board file, for example `../team/board.md`, listing claims, owners and open requests. Every request must name an owner; "someone please" is not allowed.
- Set science targets by time: by 25m, 10 or more belt-fed labs, 4 or more red assemblers, and one green block with one owner. Build oil infrastructure only once fluid handling is under way.
- Defence doctrine: once gun turret is researched, every outpost owner places 2 turrets with 20 or more magazines. Assign one warden to watch `status` losses and rearm.
- Belt coal to the boilers and burner rows by 20m, and replace burner drills with electric ones. Feeder chests hold a single item.
- Verify before announcing: `inspect` the machine before posting "milestone" or "chest at X".
- Stay active until the deadline and write the final summary in the last 3 minutes.

**Harness**
- Supervisor: re-prompt as soon as an agent finishes early, stating the time left. Nudges every 4 to 7 minutes let Haiku and Muse coast.
- Replies should carry all unread @mentions, not only the latest message. Push attack alerts while damage is happening.
- Add a `labs` diagnostic (which labs are idle and which pack is missing), belt-lane contents in `inspect`, and the reason an inserter is blocked.
- Fixes:
  - `arrived_near` should exit 0.
  - Calling `wait_ticks` directly should point to `wait_until`.
  - Reword the low_power line.
  - Allow `transfer` from corpses.
  - Make radius `collect` skip claimed chests.
  - Make `pole_route` place corner poles.
  - Let `pipe_route` route across ghosts.
  - Fix PlayerIdentification on `construct`.
  - Make `./shot` reliable.
- Make claims a first-class action and show them on the overlay. Allow repeating courier queues; Opus found `queue_repeat` blocked by a local hook.

**Team composition**
- Nine agents produced 363 messages, large backlogs and duplicated work, and about five agents carried most of the factory (Sol, Astra and Opus, then Haiku and Grok). Try 5 or 6 agents, or keep 9 with assigned lanes.
- Test the observed strengths directly. For example, Codex as coordinator and engineer, Opus as logistics lead using queues, Grok and Muse on defence and courier work, with a matched rerun on the same seed. Also try single-family teams to separate model effects from role effects.
- Give Sonnet and Luna narrower, concrete jobs, such as owning red science or the lab bus, and check that every agent sets a profile.
