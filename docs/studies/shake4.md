# Study: shake4, the first Space Age run (two hours)

Run: 2026-10-11, agents launched 02:52:17 to 02:52:33 PDT (16 seconds; "started: 9 agents" at 02:52:57,
`runs/shake4/start.log:13-32`), world `n`, seed 20261010, normal enemies, Factorio: Space Age, real time, streamed
unlisted, one deadline for all nine agents at 04:52 (`deadline.txt` in each workspace). Same nine agents, models and
harnesses as shake1 to shake3. World tick 0 was about 02:50:28 (tick 9,030 at 02:52:58, `scores.jsonl:1`), so game
minute is about wall minute minus 02:50:28; the agents joined at game 1.8 to 2.1 minutes. The last snapshot is 04:53:21,
game 122.8m (`scores.jsonl:61`).

Shake4's first hour is compared with shake1 to shake3 by game time; its second hour is reported on its own. The
three-agent Space Age pilot (`runs/sapilot`, same seed, Astra, Opus and Gemini, 32 game minutes) is the comparison in
section 7.

Sources, all read-only: `runs/shake4/` in the main checkout (chat.jsonl, scores.jsonl, caster.log, analyst.log,
push-live.log, stream-service.log, shot-sync.log, start.log, per-agent journal.jsonl.gz, notes.md and harness logs),
`tools/stream/logs/` for 02:51 to 04:54, the agents' native transcripts, and `runs/sapilot`, `runs/shake3` and earlier.
Quotes are verbatim, including the run-together words of Astra and Sol. "≤" means the event falls between two 2-minute
score snapshots.

## P1: before the resumed shift (shake5, about 05:50)

Harness bugs, misleading prompts and launch hygiene only; no strategy advice to the agents. Evidence is in the
sections named.

1. Start every stream helper from current main, and know what changed since shake4 (section 6). Shake4's caster
   started at 02:52:03 (`runs/shake4/start.log:6-11`), before fc29bd8 (02:56:44, "no pace comparison past the
   baseline run's end"), so from game 85m to 108m six exchanges told the hosts the team was "4..9 technologies ahead
   of shake1 at the same game time" against shake1's final 14, and lines like "Twenty-two techs deep—eight ahead of
   shake1" (Rook, 04:35:01) aired. On a resumed world (game 123m on) no shake1 comparison should air at all; one that
   does means a stale caster. Main has also moved since shake4's code (33b21be): the harness mod (bot travel,
   `bots.lua`, `runtime.lua`, `waits.lua`) and Grok's run-local home, which shake4 ran without (b940b9f, merged at
   04:54). Have `tools/start-team.sh` (the `POG_RESUME` path) print the code line and each helper's first line into
   `runs/shake5/start.log`, and check Grok's first minute.
2. `sleep` is refused while the character is dead (section 3). 19 `./fh sleep` calls from 7 agents failed with "bot X
   is dead; it respawns at tick N" (Haiku 8, four tries in 6 seconds twice), so agents spun on `observe` instead (26
   more dead failures). `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua:3660` lets only `chat` and `say`
   through for a dead bot; add `sleep` (and `wait_until`), and in `waits.lua` sleep until `dead_until_tick` and wake
   with "respawned". Chat while dead, the shake3 fix, held (0 failures; shake3 3).
3. Claude Code ended its turn right after an auto-compaction twice (Sonnet 03:41:32 to 03:41:39, Haiku 04:20:44 to
   04:21:28), and the supervisor's "last request < 120 s ago, working" skip (`tools/supervise.sh:46`) held the nudge
   for one more 80-second round each time (`sonnet/supervisor.log:2`, `haiku/supervisor.log:2`): about 2.5 minutes
   lost per agent. For kind `claude`, an idle status means the turn has ended; skip the recent-request check there.
4. An item on the ground blocks `build` with no way out (section 3): 11 failures naming `item-on-ground`, 9 of them
   Grok's at one spot (36.5,-28.3), seven tries in 57 seconds. `placement_error`
   (`runtime.lua:1732`) names trees and rocks with a remedy; give `item-on-ground` one too (pick it up), or have the
   direct build pick items up as it already clears stumps.
5. ElevenLabs has 0 credits (section 6): it answered `401 quota_exceeded` on the first agent clip and each time its
   30-minute rest ran out (`runs/shake4/caster.log:18`, `:350`, `:606`), so Opus's pick `el-george` played as OpenAI `fable` in all 13 lines. Top up the key
   or drop the `el-` voices from `agent/voices.md` while it is empty, so agents only pick voices the run can play.
6. The naturalist brief still makes "frozen" lines (section 6): about 30 of 696 lines call a planning agent frozen,
   still or motionless (shake3 102 of 443), 19 of them in naturalist exchanges ("Here sits Grok, still as a heron",
   04:06:25). `tools/stream/caster.py:43` says "A specimen planning its next step is deep in thought"; say instead that
   it is writing its next commands, and that frozen, still, motionless, idle and asleep are wrong for an agent whose
   status is planning (also in the rules at `caster.py:487`).

## 1. Summary

PENDING

## 2. Progress and pace by milestone

Final score at 04:53:21 (game 122.8m): 24 technologies, the last four of them chemical-science-pack, advanced-circuit,
sulfur-processing and plastics, with electric-energy-distribution-1 in progress; 35,298 iron and 12,345 copper plates,
1,440 red and 1,194 green packs, 1,616 plastic bars, 211 advanced circuits, 672 steel; 12 labs, 1 refinery, 2 chemical
plants. No blue pack was made: `produced` never lists chemical-science-pack (`scores.jsonl:61`), and the last chat
lines agree ("No blue packs verified", Astra #1011 at 120.8m; "noverifiedblueproduction", Sol #1009). The rocket silo
was out of reach; on Space Age it needs blue packs (`docs/SPACEAGE.md:138`).

### First hour against shake1 to shake3 (game time)

| Milestone | shake4 game (PDT) | shake3 | shake2 | shake1 | shake4 against shake3 |
|---|---|---|---|---|---|
| electronics, steam-power (trigger techs) | ≤4.5m, 5m47s (Sol #61) | ≤6.6m | ≤6.5m | 4.2m, 6.2m | 1 to 2 min earlier |
| First lab placed (unlocks automation-science-pack) | 9.3m (Opus #105) | 9.2m | by 7m15s | 8m13s | same |
| Steam power live | 13.1m, 03:03:38 (Opus #146, Gemini #147) | 8.0m | 8m18s | 12m42s | 5 min later |
| Automation | ≤16.5m | ≤14.5m | ~11m40s | 16m41s | 2 min later |
| Electric mining drill (its own tech on Space Age, Astra #107) | ≤18.5m | ≤20.5m | 20m14s | 17m44s | 2 min earlier |
| Logistics | ≤20.6m | ≤18.5m | ≤16.5m | ~20m15s | 2 min later |
| Logistic-science-pack | ≤26.6m | 28.9m | 29m59s | ~23m | 2 min earlier |
| Steel processing | ≤28.6m | ≤34.6m | 34m03s | ≤26.3m | 6 min earlier |
| Radar | ≤30.6m | | ≤40.5m | | |
| Gun turret | ≤32.6m | ≤32.5m | ~20m44s | ~29m | same |
| Automation-2 | ≤40.6m | ≤40.6m | ≤40.5m | ~36m | same |
| Engine | ≤50.6m | ≤48.6m | 51m17s | 48m55s | 2 min later |
| Crude oil found | 52.0m, 03:42:32 (Gemini #460, "7 rich oil springs at (-85,-380)") | 25.5m | never | ~(-85,-385) | 26.5 min later |
| Fluid handling | ≤54.6m | 51.8m | ~53m56s | 54m01s | 3 min later |
| Oil-gathering | 61.8m (Luna #550) | 58.8m | not done | not done | 3 min later |
| Crude pumped, oil-processing (trigger) | 62.6m (Luna #558 sees a running pumpjack), ≤62.7m | 59.4m, ≤60.6m | | | 3 min later |
| Refinery | ≤64.7m | 60.8m (unconnected) | | | 4 min later, and connected |

The oil field is the same one in every run of this seed: shake3 found it at (-85,-397) at 25.5m, shake4 at 52.0m after
Gemini went north along x=-40 "to chart new territory" (#443, 49.7m). In shake4 the oil-gathering research, not the
find, set the time crude flowed (oil-gathering done at 61.8m, pumpjack running by 62.6m), so the late find cost about
3 minutes against shake3.

Factory at game 60.7m (`scores.jsonl:30`) against shake3 at 60.6m:

| | shake4 | shake3 |
|---|---|---|
| Technologies | 15 (radar and military in, oil-processing 2 min later) | 15 |
| Labs | 9 (7 from 40.6m to 58.7m) | 11 |
| Assemblers (AM1 + AM2) | 29 + 7 | 13 + 9 |
| Electric drills, furnaces | 21, 55 | 14, 56 |
| Red / green packs (lifetime) | 531 / 431 | 692 / 427 |
| Iron plates | 13,196 | 13,508 |

The first hour ended level with shake3: the same technology count, the same green packs and iron, fewer red packs. The
opening lost 5 minutes on power. The lab stood at 9.3m with 10 red packs and "automation queued, stalled only on power"
(Opus #123, 11.1m) while three agents built one steam plant together: Gemini held the offshore pump, Grok the boiler
with "8 iron plates" (#97), the engine needed 40 more plates, and Luna found the boiler "at 0 water, pipe network
disconnected" (#127, 11.6m) and closed the pipe gap; Opus crafted the engine and placed it (#141, #146). From 20m on the
team caught up (logistic-science-pack 2 minutes and steel 6 minutes before shake3) and then lost it again at engine and
fluid handling.

### Second hour (shake4 only)

| Milestone | Game time (PDT) |
|---|---|
| Chemical plant | ≤68.7m |
| 66-biter raid on the science block and power; research nearly stops | 67.6m to about 83m (section 5) |
| Repair-pack (inserted ahead of plastics) | 84.5m to 85.4m (Astra #742, #749) |
| Plastics | ≤88.7m; first plastic bars by 88.7m, about 50 a minute after |
| Advanced circuit | ≤96.8m; first circuits by 98.8m |
| Sulfur processing | ≤104.8m |
| Chemical-science-pack | 108.3m (Opus #904, "Chemical science pack researched at 1h48m!") |
| Advanced material processing | ≤118.8m |
| Blue pack | none: the sulfur plant at base (21.5,-37.5) got water at 118.5m but never petroleum; Gemini's gas line ended at y=-120, "~130 tiles" short (#1002, 119.1m) |

Rates between snapshots, first and second hour:

| | 0 to 60.7m | 60.7 to 122.8m |
|---|---|---|
| Iron plates a minute | 217 | 356 |
| Red packs a minute | 8.7 | 14.6 |
| Green packs a minute | 7.1 | 12.3 |
| Plastic bars a minute | 0 | 26 (about 50 once running) |

What limited the second hour, in order of cost:
- Plastics took 26 minutes of research (62.7m to 88.7m). Science consumption nearly stopped from 68.7m to 82.7m (red
  consumed 589 to 653 in 14 minutes, against about 13 a minute before): the 66-biter raid at 67.6m cut power "to 197
  machines" (Luna #616), destroyed labs and science assemblers (labs fell from 12 to 6 at 68.7m), and at 80.7m "8 of 10
  labs" still lacked green packs (Sonnet #711) because Grok's green line had jammed on full intermediate outputs
  (#721).
- The oil field is about 350 tiles north of the base (Luna #558, "351 tiles away from me"). Refinery and plastics sat
  at the field; the sulfur plant was placed at base, and its petroleum line was not finished by the deadline.
- Raids grew: groups of 45 at 04:24, 70 at 04:33 and 46 at 04:40 (team alerts), and the last workshop raid "destroyed
  ALL 3 advanced circuit asms" (Sol #1009, 120.7m) and five assembler-2s (Astra #1008).
- Power stayed tight: "Power is saturated (4.5 MW)" at 78.4m (Sonnet #697), and boilers lost water and fuel in the last
  raids (Sol #969, "Opus rebuilt3boilers needfuelURGENT", 113.1m).

## 3. Agents

PENDING

## 4. Talk

### Chat volume and logistics

| | shake4 hour 1 (<61m) | shake4 hour 2 | shake3 | sapilot (3 agents, 32m) |
|---|---|---|---|---|
| Agent messages | 547 | 464 | 547 | 98 |
| Logistics by the shake3 keyword count | 514 (94%) | 423 (91%) | 505 (92%) | 86 (88%) |
| Mixed / no logistics word | 23 / 10 | 21 / 20 | 28 / 14 | 8 / 4 |
| Address someone with `@` | 95% | 94% | 92% | 97% |
| Carry coordinates | 68% | 76% | 65% | 45% |
| Any tone word (thanks, great, sorry, a joke word, `!!`) | 12.6% | 9.9% | 14.4% | 7.1% |
| Aloud | 42 | 22 | 32 | 21 |
| Mean characters | 177 | 186 | 181 | 133 |

The logistics share did not move: hour one has exactly shake3's 547 messages and 94% logistics, after the round-4
prompt sent claims and handovers to the board (`agent/team.md:35-39`, "post or update the board item with what and
where"). The board did take more traffic (below), so chat did not shrink because of it; chat kept the coordination that
the board records, in the form of `@name` requests and status ("@opus I added 29 iron plates to your red-science chest
(-18.5,-34.5)", Luna #693). Per agent: Luna 230 (222 logistics), Astra 201, Sol 148, Haiku 97, Opus 78, Grok 74, Muse
68, Sonnet 64, Gemini 51. Lines whose point is a joke or a feeling are again about half a dozen (best moments below).

Astra and Sol ran words together in a third of their lines from 52m on: "Northbankrestartedverified1h05m: coalleftlane,
oreclear, furnacesworking" (Astra #587). By 10-game-minute bin, Astra 0 lines before 50m, then 10 of 16 (50 to 60m), 13
of 14 (60 to 70m), 2 of 20, 0, 0, 11 of 18 (100 to 110m), 11 of 15 (110 to 120m); Sol 10 of 11 (60 to 70m), 7 of 7, 1
of 14, 11 of 14 (90 to 100m). Luna, also on Codex, never did; nobody did in shake3 (counted as a run of 22 or more
letters). The hosts and the TTS receive these lines as written. Section 3 checks whether it follows their context.

### Board

232 board calls (shake3 93): 88 reads, 66 posts, 78 updates, plus 1 harness request (Astra). Posts by kind: 24 claims,
19 requests, 18 notes, 5 tasks. Updates: 21 done, 20 doing, 8 dropped. Use was not only the opening: 47 posts and 61
updates in hour one, 19 posts and 17 updates in hour two (Astra 12 of the 19).

| Agent | reads | posts (h1 / h2) | updates |
|---|---|---|---|
| luna | 57 | 8 / 0 | 19 |
| astra | 7 | 15 / 8 | 25 |
| sol | 7 | 11 / 2 | 18 |
| haiku | 4 | 4 / 3 | 4 |
| opus | 2 | 5 / 0 | 3 |
| grok | 2 | 4 / 0 | 2 |
| gemini | 4 | 2 / 0 | 1 |
| muse | 1 | 3 / 0 | 4 |
| sonnet | 4 | 1 / 0 | 1 |

11 posts failed and were resent within seconds, all on argument shape: 7 with a `note` field (`unknown argument note
for board_post; valid: area, kind, needs, owner, tags, ...`; Luna 02:53:45, Grok 02:53:40, Sol 03:27:50, Astra 03:29:54
and 04:08:20, Haiku with `status` 03:21:32 and `requested_by` 04:15:57) and 3 with `needs` as an object instead of a
list (`needs is text or an array of 1..16 item names or {...}`, Sol 03:27:54, Astra 03:29:59, 04:08:23). The prompt
offers `"note"` for updates (`agent/team.md:52`), so agents reached for it on posts too.

### Aloud and confessions

64 aloud lines (shake3 32): Gemini 23, Astra 11, Luna 8, Opus 8, Grok 8, Sol 4, Muse 2, Haiku 0, Sonnet 0. Gemini's 23
are mostly logistics read out with coordinates ("Both electric mining drills placed and powered on your iron patch at
(-74.5,-27.5) and (-70.5,-27.5), facing east!", #224). Two aloud lines told viewers something false: Muse #934 at 111.1m
"Blue science is live" and Luna #1007 at 120.4m "sulfur science can finally start", while the sulfur plant had no
petroleum to the end (Astra #1011).

One confession in two hours (shake3 0): Sol at 03:09:10 (game 18.7m), "We spent the first minutes passing the copper
job around like a hot potato. At least the drills stayed put. Now everyone is shopping in the circuit chest, so I am
waiting for electric iron to make the budget less theatrical." The prompt now names an occasion (`agent/team.md:55-56`);
eight agents still never used it.

### Identity

All nine called `profile` in the first 40 seconds (02:52:31 to 02:53:12).

| Agent | Glyph | Colour | Voice picked | Pronouns | Avatar |
|---|---|---|---|---|---|
| astra | ✦ | #9966ff | athena | | engineer, hood, wide visor, star |
| sol | ☀ | #ffb52e | oa-cedar | | engineer, hardhat, goggles, gear |
| luna | ☾ | #70d6ff | luna | | engineer, hood, wide visor, flask |
| opus | ✳ | #d97757 | el-george (played as OpenAI fable, section 6) | they | engineer, hardhat, bolt |
| sonnet | S | #ff8800 | none | | none |
| haiku | 🔶 | #e07a2f | none | they/them | none |
| grok | λ | #1ec8a5 | arcas | they | robot, crest, mono visor, rocket |
| gemini | ♊ | #4285f4 | apollo | | robot, armor, slit visor, circuit |
| muse | ♞ | #44dd88 | oa-onyx | | engineer, hardhat, goggles, gear |

Glyphs are unique; colours are not: Sol, Sonnet, Haiku and Opus are four oranges (#ffb52e, #ff8800, #e07a2f, #d97757).
Sonnet and Haiku again took no voice or avatar. Three agents set pronouns, all "they" (shake3: Grok he/him, nobody
else).

### Best moments for the stream

Game time, wall time, chat seq; "aloud" where spoken.
- 13.1m, 03:03:38, Opus #146 and Gemini #147 (both aloud), "Power is live!" after four minutes of three agents
  assembling one steam plant from parts (#89 to #145).
- 18.7m, 03:09:10, Sol's confession (above).
- 52.0m, 03:42:32, Gemini #460 (aloud): "Crude oil discovered! 7 rich oil springs at (-85,-380) with 850k+ oil, zero
  biters nearby."
- 67.5m to 68.4m, 03:58:00 to 03:58:57, the big raid: Grok #604 (aloud) "A group of 66 biters is walking from the east
  nest toward the science block. I am staying on green packs; someone with turrets should meet them."; Opus #612
  (aloud) "I just died at (21,-36). Boilers were hit."; Astra #615 (aloud) teaching the team the `kite` tool; Grok #617
  "Respawned empty after two deaths."
- 86.8m, 04:17:22, Astra #755 (aloud): "The factory has taken a few bites, but the furnaces are running again. Next
  delivery: plastic. Preferably before the biters place another order." The best joke of the run.
- 108.3m, 04:38:52, Opus #904 (aloud): "Chemical science pack researched at 1h48m!"
- 111.1m to 112.5m, 04:41:37 to 04:43:04, power at zero: Opus #936 (aloud) "I'm too weak to clear them with a pistol",
  Grok #941 (aloud) "Power is at zero. I have sixteen magazines and I am kiting the biters off the boilers", Opus #959
  rebuilding the boilers.
- 119.1m to 120.7m, 04:49:38 to 04:51:20, the sign-offs: Opus #1003 (aloud) "thanks team, especially astra for saving
  the power twice"; Gemini and Sol's under-the-water pipe crossing (#1004 to #1006); Luna #1007 "Nice save, team".

## 5. Combat and defence

Source: the `alerts` in each agent's `team:` block (journals, deduplicated), and chat. No raid touched the first 34
minutes except a worm at a scout.

| Raid | Game time (PDT) | Group | Where | Damage | Response |
|---|---|---|---|---|---|
| worm | 23.6m (03:14) | | (304,-144), east | Sonnet, scouting for oil (#232), killed at (319,-135) | Gemini warned Sonnet (#243) |
| 1 | 34.0m to 35.0m (03:24:16 to 03:25:23) | small biters | west iron and coal (-69,-29) to (-42,-9) | 16 destroyed: 5 poles, 5 furnaces, 3 belts, a burner drill, 2 characters (one Luna, #310) | Astra #309 aloud "Biters in the factory NOW"; gun-turret already researched (#313) |
| 2 | 67.3m to about 72m (03:57:47 to 04:02) | 66, from (83,93) to the science block | power plant, belts, boilers, science block, then a 7-group on Sol's workshop | power cut "to 197 machines" (Luna #616), labs 12 to 6, a boiler, belts, pipes; 6 deaths (Opus #612, Luna #616, Grok twice #617, Sol twice #625 and #641) | Haiku placed 2 turrets west of science at 68.6m (#619); Sonnet crafted 3 (#618) and placed 2 at the power plant (#667); Astra kited; Sonnet rebuilt the trunk by 71.1m (#639) |
| 3 | 76.2m (04:06:41) | 14, to the power plant (28,9) | turrets at (40,9), (33,30) | turret damage | Astra topped up turrets (#681 to #691) |
| 4 | 84.6m (04:15:05) | 28, to the workshop (-28,6) | power and workshop | turret (33,30) destroyed (#748) | repair-pack researched first (#742) |
| 5 | 93.9m (04:24:20) | 45, to the power plant (28,3) | power | | stone walls researched by 90.7m (#776) |
| 6 | 103.1m (04:33:33) | 70, to (28,3) | east turrets, power | "all 33 assemblers and 12 labs are idle" (Luna #849, 104.5m); Haiku and Astra died (#846, #847) | |
| 7 | 109.9m (04:40:19) | 46, to (28,3) | boilers, workshop | "Power is at zero" (Grok #941); 3 boilers rebuilt (Opus #959); the workshop raid "destroyed ALL 3 advanced circuit asms" (Sol #1009) | Astra died (04:40:55); Muse died at 04:49:37 |

- Deaths: at least 13 against shake3's 3, counted from chat reports and `your character died` alerts; 9 of them in
  raids 2, 6 and 7. One scout died to a worm.
- Defence was organised in chat again, not on the board, apart from Astra's "Shared power defense wall screen" note
  (04:21:48) and Sol's defence handover chest claim (04:25:56).
- The raid groups came from nests to the southeast ((83,93), (74,78), (50,94), (83,99)) and went for the power plant at
  (28,3) four times. Turrets there were placed and topped up after each raid and destroyed in the next.
- The `kite` tool was the agents' discovery of the run: Astra used it in raid 2 and taught it to everyone aloud (#615),
  Sol coached "kite min7/max12" (#932).
