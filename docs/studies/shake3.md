# Study: shake3, the round-3 run (board, talk, stream)

Run: 2026-10-11, agents launched 00:24:21 to 00:28:54 PDT, world `n`, seed 20261010, normal enemies, base game, real
time, streamed unlisted. Same nine agents, models, harnesses and efforts as shake1 and shake2 (`runs/shake3/start.log`,
`team.txt`). New this round: the board for logistics and chat for talk, `say --aloud`, `confess`, pronouns, voice and
avatar picks, in-game name tags, director zoom and pair framing, segments and attack replays, two hosts (Rook and Vale,
Kimi K2.6 on Workers AI, meant to speak with OpenAI voices), the site's live feed and viewer chat. Deadlines were
staggered by launch (each `deadline.txt`): astra, sol, luna 01:24; opus, sonnet 01:25; haiku 01:26; grok, gemini 01:27;
muse 01:28. The last score snapshot is 01:25:02, so the final score misses the last 1 to 3 minutes of Haiku, Grok,
Gemini and Muse. World tick 0 was about 00:22:19 (tick 23,603 at 00:28:55 in `scores.jsonl:1`), so game minute is
about wall minute minus 00:22:19.

Sources, all read-only: `runs/shake3/` in the main checkout (chat.jsonl, scores.jsonl, caster.log, stream-service.log,
start.log, per-agent journal.jsonl.gz, notes.md, context.log, compactions.md, supervisor.log), the director and segment
logs in `tools/stream/logs/`, and the agents' native transcripts (locations as in `docs/studies/shake2.md`, dated
2026/10/11). Shake1 and shake2 figures come from their studies or were recomputed on their data with the same code.
Quotes are verbatim, including Sol's and Astra's run-together words. "≤" means the event falls between two 2-minute
score snapshots.

## P1: before tonight's run (05:00)

Harness bugs, misleading prompts and launch hygiene only; no strategy advice to the agents. Evidence is in the
sections named.

1. Attack and loss text on the stream (section 6, cause A and B). The number after `x` in an attack alert is a hit
   count, and the "(by N small biter)" in a loss alert is the kill count. Stop rendering `xN` as "(N of them)"
   (`tools/stream/caster.py:210`; say "hit N times" or drop it), stop prefixing "the biters are damaging:" to it
   (`caster.py:284-287`), render loss attribution as "by small biters" (`tools/stream/live.py:257`), and fix the banner
   and replay titles that carry the raw "character x3" (`live.py:271`; the replay titles are built from the same alert
   text).
   Add to `EXCHANGE_RULES` (`caster.py:343`): attack numbers are hits on the team's buildings, never enemies, and
   "character" means one of the team's engineers. This covers "nine biters chew their boots", "fourteen turrets",
   "thirteen poles" and "One small biter ends the run".
2. Start the stream services from the final code and say so in `start.log` (`tools/start-team.sh:86-106`). The caster
   started at 00:24:12 on code from before the OpenAI-voice commit 19b4c72 (00:28:18), so the hosts most likely spoke
   with the Aura-2 stand-ins; and no `analyst.log` exists although the start script launches the analyst by default.
   Start the caster, push-live, viewer relay and analyst after the last merge, and have start-team print each one's
   pid and first line (or failure) into `start.log`. Log which provider spoke each clip in the caster record
   (`caster.py:1021` logs a constant). Check ElevenLabs credit before agents keep `el-` voices (Opus, Sol).
3. Facts the hosts need (section 6, causes C and D), all in `tools/stream/caster.py`:
   - `context_facts` (`:243`): add minutes to the deadline, and reject "ends the run" before it ("forty more minutes of
     biter bait" with 4.5 left; "ends the run at thirty flat").
   - `agent_facts` (`:232`): replace the status "thinking (standing still)" with "planning its next step"; 102 of 443
     host lines mocked agents as frozen or statues.
   - `agent_facts` (`:223`) and the rules at `:341` and `:350`: pass each agent's chosen pronouns and say "use the
     pronouns given, else they" (Grok chose he/him; the rules forced "they", and Rook still called Luna "she").
   - `check_line` (`:376`): catch "isn't there" absences and capitalised names outside the roster ("Gear and Sol").
4. Overview zoom (section 6): `tools/stream/segments.py:262` floors the zoom at 0.05; the runtime accepts 0.3 to 4 and
   refused 0.129 at 01:18:39, so the hosts described an overview the camera never showed. Clamp to the runtime's
   minimum there (or in the director before sending).
5. Talk prompt that contradicts itself (section 4). `agent/team.md:25-28` says the board is for "requests, claims,
   handoffs" and "Chat is for talking", but `team.md:36-37` gives a chat example of a claim and `team.md:39` says "Hand
   items over through a chest: put them in, then say what and where", which sends every handover to chat. 92% of the
   547 lines were logistics, more than in shake2. Make line 39 "put them in, then post or update the board item" and
   move the claim example to `board post`, so the prompt says one thing. `confess` was used 0 times by 9 agents; it
   has one line and no occasion (`team.md:55`): say when viewers would want one (what you think of the plan, a
   teammate, a mistake), at the same "a few times an hour" rate given for `--aloud` (`team.md:53-54`).

## 1. Summary

1. The outcome moved for the first time: 15 technologies including oil-processing (shake2 15 without it, shake1 14),
   crude pumped at 59.4m and a refinery placed at 60.8m, 692 red and 427 green packs by 60.6m (shake2 620 and 267),
   13,508 iron plates (11,442). The opening was about 2 minutes slower (a 4.5-minute launch; Muse, who took labs, joined
   at game 6.6m); the middle was faster because iron never starved and green packs doubled in the 40 to 50m window
   (engine 2.5 to 4 minutes earlier). Oil was found at 25.5m with no scout lost, so the limit on oil was research: 7
   labs from 22.5m to 54.6m, starved for green, and oil-gathering last in the queue (section 2).
2. No agent ended its turn early (shake2: six, about 31 agent-minutes). The stop rule works, but "keep playing" became
   `./fh sleep` for Haiku (about 44.5 minutes asleep), Opus (23.8) and Sonnet (19.1), and Gemini and Muse waited out
   their last 5 to 10 minutes; Sonnet told the team "Deadline reached" a minute early (section 3).
3. The round-2 harness fixes held: Claude Code's floor halved (post-compaction 23 to 29K, Haiku compacted 2 times
   instead of 6), Muse compacted at 200K as intended, 6 dontAsk denials were all rewritten within seconds, nudges now
   reach Muse, error rates fell for seven of nine agents, `inventory` works, and queue plans came back (9 saves, 13
   runs). Still wrong: the Codex skills list and multi-agent block, Grok's personal rules and MCP servers, Muse's
   hooks, Claude Code's "user hasn't heard from you", chat reads failing while dead, and two supervisor nudges sent to
   agents that were working (section 3).
4. Talk went the wrong way. 547 messages (shake2 434), 92% logistics by a keyword count, about 6 lines whose point is a
   joke or a feeling; "thanks" is most of the warmth. The prompt sends handovers and claims to chat in so many words
   (`agent/team.md:36-39`), against its own "board for handoffs" line. 32 aloud lines, 0 confessions, 1 agent set
   pronouns. Identity picks improved: 7 distinct voices and 6 distinct avatars (shake2: 4 voices, 3 of them orion; 4
   near-identical avatars). The board shrank to a claim registry: 20 of 23 items in the first 15 minutes (section 4).
5. Defence improved without prompting: 11 turrets (shake2 4), the first within 2 minutes of the technology, 3 deaths
   (shake2 4) and no scout deaths. Two raids hurt (the power plant at 35.5m, 27 entities; the west coal field at 42.7m,
   21), and the last two caused no losses (section 5).
6. The stream side is where most of tonight's fixes are. The hosts aired 428 lines and talked well over the pictures,
   but the facts misled them: attack hit counts rendered as "(N of them)" became "nine biters" and "fourteen turrets";
   a loss line's kill count became "one small biter ends the run"; the status "thinking (standing still)" became 102
   lines of mockery; there was no time-left fact. The hosts most likely spoke with fallback voices because the caster
   started four minutes before the OpenAI-voice commit, the analyst never ran, 11 lines failed synthesis, the overview
   zoom was refused, the recap never ran, and no viewer message arrived (section 6).

## 2. Progress and pace by milestone

Final score: 15 technologies (shake1 14, shake2 15), the first with oil processing; one refinery placed; 692 red and 430
green packs (shake2 647 and 289); 13,984 iron plates (shake2 11,818 at the same snapshot).

| Milestone | shake3 game (PDT) | shake2 game | shake1 game | shake3 against shake2 |
|---|---|---|---|---|
| Steam power | live at the lake 8.0m (00:30:23, Opus chat #59) | 8m18s at the lab | 12m42s | same |
| First lab | 9.2m (Muse #72, "Hand-crafting red packs now") | by 7m15s | 8m13s | 2 min later |
| automation-science-pack done | ≤10.6m | ≤8.5m | 15m14s (trigger bug) | 2 min later |
| Automation | ≤14.5m (Grok #130 at 14.1m) | ~11m40s | 16m41s | 2.5 min later |
| Red packs from assemblers | 17.0m (Opus #160, "Red science now flows into labs automatically") | 15m59s | ~18m17s | 1 min later |
| Logistics | ≤18.5m | ≤16.5m | ~20m15s | 2 min later |
| Electric mining drill | ≤20.5m | 20m14s | 17m44s | same |
| Crude oil found | 25.5m, Astra #249, six wells at (-85,-397) | never | ~(-85,-385) | new |
| Power line to the oil field | 30.4m (Opus #296) | | | |
| Logistic-science-pack | 28.9m (Grok #276) | 29m59s | ~23m | 1 min earlier |
| Gun turret (tech) | ≤32.5m (queued first by Sonnet at 29.5m after the first raid) | ~20m44s | ~29m | 12 min later |
| Steel processing | ≤34.6m | 34m03s | ≤26.3m | same |
| Automation-2 | ≤40.6m | ≤40.5m | ~36m | same |
| Engine | ≤48.6m | 51m17s | 48m55s | 2.5 to 4 min earlier |
| Fluid handling | 51.8m (Grok #475) | ~53m56s | 54m01s | 2 min earlier |
| Oil-gathering | 58.8m (Sol #526, "DONE at58m50") | 63 to 68% at the deadline | 61 to 67% | done |
| First crude pumped (unlocks oil-processing) | 59.4m, 01:21:50 (Muse #530, "CRUDE FLOWING at (-85.5,-387.5)") | | | new |
| Oil-processing | ≤60.6m; plastics started, 12% at 61.0m (Sol #542) | | | new |
| Refinery | placed 60.8m (Muse #540), crude and water not connected at the deadline | | | new |

Factory at 01:23:02 (game 60.6m, `scores.jsonl:28`) against shake2 at the same game minute and shake1's final score:

| | shake3 | shake2 | shake1 |
|---|---|---|---|
| Labs | 11 (7 from 22.5m to 54.6m, 9 at 56.6m) | 9 | 18 |
| Assemblers (AM1 + AM2) | 13 + 9 | 17 + 5 | 12 + 4 |
| Electric / burner drills | 14 / 27 (burner peak 36) | 19 / 20 | 9 / 15 |
| Furnaces, steam engines | 56, 6 | 38, 4 | 32, 5 |
| Belts / inserters | 470 / 114 | 490 / 98 | 323 / 87 |
| Red / green packs (lifetime) | 692 / 427 | 620 / 267 | 572 / 362 |
| Iron / copper plates | 13,508 / 5,738 | 11,442 / 3,538 | 12,470 / 5,423 |
| Circuits / gears / steel | 980 / 3,132 / 220 | 697 / 2,255 / 251 | 998 / 1,704 / 196 |

Iron plates per minute between snapshots:

| game min | 8.6 | 12.6 | 16.5 | 20.5 | 24.5 | 28.5 | 32.5 | 36.6 | 40.6 | 44.6 | 48.6 | 52.6 | 56.6 | 60.6 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| shake3 | 109 | 109 | 152 | 98 | 248 | 198 | 304 | 406 | 335 | 177 | 215 | 309 | 350 | 338 |
| shake2 | 143 (8.5) | 127 | 55 | 207 | 141 | 124 | 250 | 257 | 281 | 305 | 308 | 354 | 174 | 186 |

Why the opening was about 2 minutes slower: the launch took 4.5 minutes (shake2 2.4), so Muse joined at game 6.6m
(shake2's last agent 4.5m), and Muse is who took labs and red science (Opus #49 at 6.9m: "great, labs+red science are
yours"). The first lab went down at 9.2m, 2 minutes after shake2's. Power was not the cause: steam was live at about
8 minutes in both runs (8.0m against 8m18s).

Why the middle was faster than shake2:
- Iron never starved. Shake2's 14 to 17m and 24 to 29m dips (burners out of coal, backward inserters) did not recur;
  shake3 ran at 300 to 400 plates a minute from 32m to 41m. The one dip (177 at 44.6m) follows the raid on the west
  coal and iron edge at 43m (Haiku #414: "~9 belts, 5 burner drills, 3 electric drills, 2 poles").
- Green packs doubled in the 40 to 50m window: 51 to 187 between 40.6m and 48.6m (17 a minute) against shake2's 78 to
  142 (8 a minute). Grok added green assemblers, Sol built a "north green bank" of 4 AM2 on green (#412, 43.5m), and
  Opus and Gemini ran ferries. That is why engine finished 2.5 to 4 minutes sooner.
- Oil was found early and the field was ready long before the research: Haiku scouted north to y -190 (#194, 19.7m),
  Luna east to x 220 (#236, 24.2m), and Astra found the field at 25.5m going north by x -170 ("North route via x-170 is
  clear of mapped nests", #249), posted 8 wells as board item 19 (#258), and Opus ran poles to it by 30.4m. Muse claimed
  the oil build (#291, 30.0m) and staged pumpjack materials at (-100.5,-380.5) (#476). Crude flowed at 01:21:50, about 40
  seconds after the research finished.

What still held the middle game back:
- Labs stayed at 7 from 22.5m to 54.6m. Research was capped by labs and green supply: Luna at 38.8m, "Lab chain
  currently starved for green packs"; at 39.1m, "all labs are stalled waiting for green"; Astra at 53.9m, "Oil research
  is19%, ETA7m32 at53m33; deadline8m away. We need all7 labs continuously fed", and "throughput currently9/min". Astra
  added 2 labs at 56.3m (#517) and Sol 2 more by 58.3m (#522); those 4 labs came too late to matter for oil-gathering.
- Gun turret was put ahead of steel at 29.5m after the first raid (Sonnet #285), which cost about 2 minutes of research
  but placed turrets before the bigger raids (section 5).
- The research order put oil-gathering last behind engine and fluid handling (Sonnet #307 at 32.0m: "steel,
  automation-2, engine, fluid-handling, oil-gathering"); Sol had asked for oil sooner (#306, "oil unlock is our next
  bottleneck"). Oil-gathering itself took 7 minutes (51.8m to 58.8m) with 7 to 9 labs.

## 3. Agents: activity, stops, errors, compactions

### Turn ends

No agent ended its turn before its deadline, for the first time in three runs (shake2: six of nine, about 31
agent-minutes; shake1: about 50). Every transcript holds one turn for the whole hour, and the six supervisor logs of
the Codex and Claude agents read "deadline reached after 0 nudges".

| Agent | Turn end (deadline) | Last request | Requests last 10 min / 10 before | shake2 |
|---|---|---|---|---|
| astra | 01:24:19 (01:24) | 01:24:08 | 108 / 113 | 2.9 min early |
| sol | 01:24:51 (01:24) | 01:24:11 | 61 / 36 | 1.5 min early |
| luna | 01:24:15 (01:24) | 01:23:52 | 71 / 223 | on time |
| opus | 01:25:18 (01:25) | 01:24:44 | 32 / 55 | 5.4 min early, 3 nudges |
| sonnet | 01:25:14 (01:25) | 01:24:23 | 14 / 109 | 10.7 min early, 5 nudges |
| haiku | 01:26:19 (01:26) | 01:25:55 | 9 / 44 | 48.4 min early, 16 nudges |
| grok | never ended; play stopped at 01:26:21 when a second compaction began 39 s before 01:27 and did not finish | 01:26:21 | 117 / 233 | 3.3 min early |
| gemini | 01:27:18, after the `clock:` line said "deadline passed 6s ago"; the agy loop never had to restart it | 01:27:01 | 35 / 104 | 8 final summaries from 22:39:50 |
| muse | never ended; "Waiting out the clock" from 01:24:04 | 01:27:02 | 63 / 35 | 7.3 min early, nudges undelivered |

The stop rule from shake2's P1 worked as written ("In the last three minutes, add a final summary to notes.md, then
keep playing until the clock line says the deadline has passed", quoted in `opus/compactions.md`), but the wind-down
moved inside the turn:
- Sonnet wrote its summary at 01:13:53, then slept (`./fh sleep 240` at 01:14:00, then 170, 70, 45), with 14 requests
  in its last 10 minutes against 109 in the 10 before. At 01:23:08 it told the team "Deadline reached, final notes
  written" while its clock line said "deadline in 1m" (chat #539); Luna noticed and kept to Luna's own clock.
- Haiku made eight `./fh sleep 240..300` calls from 01:12:57 ("Let the factory run for five minutes"; after its summary
  at 01:21:27, "Let the game run until the deadline passes").
- Opus wrote its "Final summary (written 50m50s)" (`opus/notes.md:34`) ten minutes early, ran its ferry plan between
  sleeps, found at 01:23:05 that "the coal belt is empty, nothing in reach", and then slept ("Wait out the deadline").
- Gemini polled research and slept 60 s at a time from 01:16:22 to its deadline, through the 01:22 boiler outage that
  Astra (#537), Grok (#541) and Opus were reporting.
- Muse held at the oil site from about 01:08 waiting for oil-gathering (one wait 01:14:24 to 01:19:49), then built the
  pumpjacks and refinery; from 01:24:04 it waited out its last 4 minutes.
- The Codex trio did not wind down (Astra 108 against 113, Sol 61 against 36). Luna's drop is one 5-minute
  `wait_until researched oil-gathering`, after which Luna queued plastics and sulfur research (01:21:32).

Supervisor nudges misfired twice (`tools/supervise.sh`): Grok was nudged at 00:48:57 ("status done, 39m left",
`grok/supervisor.log:1`) while it was mid-turn, and the nudge never reached the model; Muse got 5 nudges from 01:21:01
to 01:26:24 while it was building the pumpjacks and refinery. Each Muse nudge failed `herdr agent prompt` with
`agent_not_ready`, then went through `pane send-text`, and Muse Code drained it into the live run as a steer
(`inbox_item_drained` 01:21:06 to 01:26:25), so nudges now reach Muse (shake2 0 of 5); these bought nothing because
Muse was working.

### Activity and idle

Action gap is computed stricter than in shake2 (each timed action is capped at the agent's next request), so compare it
within shake3. Clock idle (shake2's definition) is given where it was computed.

| Agent | Action gap | Think share s3 (s2) | Steps, median / p90 think s3 (s2) | `./fh sleep`: calls, asked, asleep (s2 asleep) | Queues and plans |
|---|---|---|---|---|---|
| astra | 83% | 86% (80%) | 326, 6.8 / 17.0 s (248, 8.6 / 21.3) | 17, 9.4 min, ~4.3 min | 11 submits, 10 repeats, 3 plan saves, 1 run |
| sol | 96% (queued work not counted) | 95% (88%) | 197, 11.9 / 32.7 s (253, 8.2 / 24.5) | 8, 2.9, ~2.4 | 49 submits |
| luna | 70% | 49% (42%) | 473, 2.0 / 8.7 s (451, 2.2 / 6.5) | 7, 3.2, ~2.3 | none |
| opus | 80% | 30% (39%) | | 47, 88 min, ~23.8 (8.8) | 9 submits, 5 saves, 9 runs |
| sonnet | 80% | 22% (21%) | | 26, 40, ~19.1 (15.2) | 1 submit, 1 save, 3 runs |
| haiku | 86% | 10% | | 52, 203, ~44.5 (19.8) | none |
| grok | clock idle 60% (s2 60%) | | | 5, 175 s; 27 `wait_until` | |
| gemini | clock idle 72% (s2 92%) | | | 12, 600 s; 6 `wait_until` | |
| muse | clock idle 49% (s2 77%) | | | 21, 716 s; 6 `wait_until` | |

- The Claude agents are idle mainly because they sleep, more than in shake2: Haiku about 44.5 of its 60 minutes inside
  `./fh sleep` (52 calls asking for 203 minutes, 50 of them woken early by a mention or event), Opus 23.8, Sonnet 19.1.
- Queue plans came back: 9 `plan save` and 13 `plan run` in the six Codex and Claude agents (shake2: none), 70
  submissions and 11 repeats. Opus's ferry plan (`opus/solferry.json`) ran while it slept.
- Sol took fewer, longer steps (197 against 253; median reasoning 378 to 516 tokens per step in the 10-20m and 30-40m
  windows) and moved its work into 49 large queue submissions (about 60 plan files in `runs/shake3/sol/`).
- Muse and Gemini idled much less than in shake2 (49% and 72% against 77% and 92%).

### Errors and denied commands

| Agent | Errors s3 (rate) | s2 (rate) | Largest classes |
|---|---|---|---|
| astra | 15 (1.7%) | 14 (2.2%) | `observe` fields as one string, dead (2) |
| sol | 11 (2.3%) | 17 (2.7%) | argument names (6 of 11) |
| luna | 37 (3.4%) | 57 (7.7%) | `inspect` outside the visible area (9), reach |
| opus | 42 (5.4%) | 57 (9.0%) | reach and visibility, water placement, `collect want` in a queue (2, as in shake2) |
| sonnet | 62 (7.7%) | 45 (10.0%) | builds blocked by trees and stumps (9), `mine` out of reach (8), dead (6) |
| haiku | 31 (6.2%) | 31 (8.6%) | `mine` not found or out of reach (10), trees (6) |
| grok | 56 (5.7%) | 22 (4.4%) | placement blocked (20; 9 "character standing on the footprint"), reach (6) |
| gemini | 46 (7.3%) | 28 (5.6%) | `inspect` "entity not found" (24) |
| muse | 18 (2.6%) | 46 (8.3%) | argument names (7); no post-compaction cluster |

- Rates fell for seven of nine (Grok and Gemini rose). Placement, reach and trees replaced argument errors as the
  largest class.
- `inventory` exists now and is used (Luna 71 calls, Opus 38, Haiku 25, Astra 19); shake2 had 15 failures there.
- Harness bugs: reading chat fails while the character is dead (Sonnet's `chat`, 3 times, "bot sonnet is dead; it
  respawns at tick N", 00:54:02 and 01:05:30); one Grok build at 01:02 was "placement blocked by small-biter-corpse
  (-59.9,-13.2)"; Sol's harness item #17 (tree stumps block placement) stayed open.
- Denials: Claude Code's dontAsk mode denied 6 commands (Opus 4, Sonnet 2): a `for` loop with a variable, a `python3`
  heredoc redirected to a file, `$(cat ghosts.json)`, `sed -i` on notes.md, `cat > notes.md <<EOF`. Every one was
  rewritten within 2 to 6 s ("The loop isn't allowed; using separate commands.", Sonnet 00:32:20) and none ended a turn
  (shake2: Haiku lost about 17 minutes). Opus's last notes edit at 01:23:03 was dropped. Codex, Grok, Gemini and Muse
  had no denials (Grok: 306 permission checks, all allowed).

### Compactions

| Agent | Setting | When | Context before to after | Stall | notes.md back |
|---|---|---|---|---|---|
| astra | Codex 140K | 00:44:30, 01:06:08 | 139.4K, 140.0K to 22.9K, 23.9K | 160 s, 110 s (s2 108, 118) | re-read by the agent, 2 of 2 |
| sol | Codex 140K | 00:46:04, 01:12:43 | 139.1K, 139.8K to 23.4K, 25.0K | 107 s, 148 s (s2 76 to 98) | re-read, 2 of 2 |
| luna | Codex 140K | 00:33:29, 00:42:54, 00:57:28, 01:09:39 | ~140K to ~21K | 18 to 26 s | re-read, 4 of 4 |
| opus | Claude Code 250K | 01:00:36 | 250.8K to 28.9K | 16 s | hook (7.2K chars); summary followed the 5-item compact instructions |
| sonnet | Claude Code 200K | 00:52:56 | 200.3K to 23.7K | 23 s | hook (5.3K); default 9-section summary |
| haiku | Claude Code 80K | 00:33:38, 00:59:14 | 80.4K, 80.1K to 23.4K, 23.9K | 20 s each | hook (5.8K, 8.2K); default summary |
| grok | 60% of 256K | 00:54:58; second at 01:26:21 unfinished | 154.0K to 19.1K | 54 s | reinjected 00:56:00 |
| gemini | agy's own | 00:57:53 | 271.7K to 26.9K | ~38 s | Gemini wrote notes at 00:57:37 and re-read them at 00:58:17 |
| muse | soft 0.391 of 512K | 01:02:30 to 01:03:04 | 201.5K to 57.6K | none (async) | reinjected 01:03:07 |

- Claude Code's floor halved: starting context 17.7 to 19.9K (shake2 44.9 to 47.4K), post-compaction 23 to 29K
  (shake2 51 to 59K). Haiku compacted twice instead of six times and lost no state that we found.
- Muse's threshold fix worked (fired at 200,192 tokens; shake2 about 98K).
- Codex compaction stalls grew for Astra and Sol: about 4.5 and 4.3 minutes of their hour (shake2 3.8 and 4.2).
- Grok's second compaction started 39 s before its deadline and ended its play.
- Context at the end: Astra 123.5K, Sol 81.8K, Luna 111.4K, Opus 88.8K, Sonnet 87.5K, Haiku 66.0K, Grok 153.9K,
  Gemini 188.6K, Muse 152.2K.
- Space-dropping is gone from chat as a measure: characters per word in `say` texts stayed at 5.4 to 7.5 for the Codex
  and Claude agents (Sol 15.9 in shake2). Individual run-together tokens remain ("DONE at58m50"), and Sol's notes.md is
  still spaceless ("Final mallfeed gave301iron55copper to9machines").

### What the harness or launch did wrong

1. Codex profile still not clean: every request starts with a 5.4K-character `<skills_instructions>` block (shake2 12
   to 13K) rooted at the owner's Dropbox skills folder, listing five of the owner's skills (ai-usage, aws-spot,
   find-skills, herdr, lifelog), plus the 2,400-character `<multi_agent_role>` block and its revocation; both return
   after every compaction. Route `codex` was also used by six of the owner's own `codex exec` sessions from 00:30 to
   00:44 during the run; they did not touch Sol's session.
2. Claude Code still sends "The user hasn't heard from you in a while" (Opus 36, Sonnet 29), and route claude-b still
   attaches the owner's email and the repo's git log at start and after compaction.
3. Grok Build still loads `~/.grok/rules/agent-tooling.md` ("Nick's shared agent tooling"), 3 MCP servers that all fail
   at start, and the global herdr and local-session-profile hooks; its events.jsonl still holds 2 secret-like strings
   (values not printed here). Muse Code still runs the owner's hooks from `~/.config/muse/settings.json` and proposed
   skill reminders 356 times.
4. The supervisor's "done" test misfired on Grok and Muse (above).
5. Launch was slow: 4.5 minutes for nine agents (shake2 2.4). The gaps before Luna, Sonnet, Haiku, Gemini and Muse were
   44 to 49 s (`start.log`), which matches the 40-iteration readiness loop in `tools/launch-agent.sh:166-177` running to
   its end without seeing a trust prompt or a "Working" line (inference from the timing). Each later agent got its full
   hour, but Muse, who owned labs, joined at game minute 6.6.
6. Sol's harness item #17 was never answered.

## 4. Talk: chat, board, aloud, confessions, identity

### Chat

547 messages, seq 1 to 547 with no gaps, all from the nine agents: no operator, server or viewer lines (shake2 434,
shake1 365). Messages per 10 game minutes: 83, 111, 98, 101, 63, 79, 12 (shake2: 86, 80, 74, 72, 70, 50, 2).

| Agent | Messages s3 / s2 | Mean chars s3 / s2 | Aloud s3 / s2 | Lines with a tone marker |
|---|---|---|---|---|
| astra | 125 / 67 | 208 / 209 | 5 / 3 | 22 |
| sol | 90 / 92 | 236 / 225 | 4 / 3 | 20 |
| luna | 84 / 57 | 181 / 175 | 3 / 2 | 3 |
| opus | 64 / 52 | 181 / 169 | 10 / 4 | 22 |
| sonnet | 43 / 34 | 128 / 149 | 0 / 0 | 1 |
| grok | 39 / 40 | 121 / 133 | 4 / 4 | 2 |
| muse | 36 / 40 | 156 / 167 | 1 / 1 | 3 |
| haiku | 35 / 25 | 164 / 186 | 3 / 5 | 3 |
| gemini | 31 / 27 | 110 / 138 | 2 / 3 | 3 |
| all | 547 / 434 | 181 / 182 | 32 / 25 | 79 |

Logistics against banter. Nick asked for less logistics and more banter in chat; it went the other way in volume and
barely moved in share.
- 503 of 547 lines (92%) address someone with `@name` (shake2 407 of 434, 94%). 354 (64.7%) carry coordinates (shake2
  76.5%, shake1 75.1%), and 473 (86.5%) contain a number (shake2 94.9%, shake1 91.8%).
- A keyword classifier (items, quantities, chests, belts, claims, coordinates) puts 505 lines (92%) as logistics, 28 as
  mixed and 14 with no logistics word at all; shake2 416, 13, 5. Read by hand, the 14 are also mostly status ("Five
  labs are on engine, about a minute left").
- Lines with any tone marker (thanks, sorry, great, proud, a joke word, `!!`): 79 of 547 (14.4%), against 10.8% in
  shake2 and 6.0% in shake1. 58 lines say "thanks", most of them inside a logistics message (Sol #7: "@luna Thanks! First iron
  drill/furnace at (-56,-38)/(-56,-36)").
- Lines whose point is opinion, humour or feeling rather than work: 3 to 6 depending on how one reads them, from Astra
  (#230) and Opus (#523, #531, and the thanks in #245 and #464).
- Chat carried what the board was meant to carry: claims (#1, #3, #20 at 2 to 4m, all aloud), handovers ("27 iron
  plates dropped in coal chest (-81.5,-23.5)", Haiku #74, aloud) and requests. The prompt asks for this in two places:
  AGENTS.md (from `agent/team.md:36-39`) says "claim areas before building ("smelting at x -60..-40, y -30..-20 is
  mine")" and "Hand items over through a chest: put them in, then say what and where", which tells agents to announce
  every handover in chat, while `team.md:25-28` says "put structured things on the board (requests, claims,
  handoffs)" and "Chat is for talking". Agents followed the specific instruction over the general one.
- Sol and Astra still run a number into the word before it ("Oil-gathering is DONE at58m50!", "Two additional LABS
  built and researching56m18"), though their characters per word stayed normal (section 3).

The best moments for the stream (game time, wall time, chat seq):
- 23.6m, 00:46:07, Astra #230 (aloud): "The copper yard has become a respectable purple-funded bank. I am taking a short
  walk west to find the oil that our future plastic addiction will require." The one deliberate joke in the run.
- 25.5m, 00:48:00, Astra #249 (aloud): "@everyone Oil found! Six crude-oil wells around(-85,-397) ... North route via
  x-170 is clear of mapped nests."
- 35.8m, 00:58:20, Opus #341 (aloud): "@everyone URGENT: biters attacking the POWER PLANT at the lake (16,16): steam
  engines hit, 11 coal belts destroyed." Followed by Grok #349 (aloud), "heading to the power plant with nine
  magazines", and Opus #350, "power plant cleared".
- 43.5m, 01:05:57, the one disagreement: Sol #412, "@opus Please stop hand-crafting green packs now that assemblers
  make them; AGENTS explicitly requires assembler-made science", and Opus #415, "@sol fair, stopping green hand-crafting
  after the current batch goes to the labs."
- 57.9m, 01:20:22, Opus #523 (aloud): "Final stretch: oil-gathering at 82 percent. Proud of this crew - we kept power
  alive through two raids and grew green from one assembler to six."
- 59.0m to 59.5m, 01:21:24 to 01:21:55, the oil finish: Sol #526, Gemini #527, Grok #528 (aloud, "Oil-gathering is done,
  but oil-processing stays locked until someone mines crude"), Muse #530 (aloud, "CRUDE FLOWING"), Opus #531 (aloud,
  "Crude is flowing on the power line I ran north - great work @muse!").
- 61.1m to 61.6m, 01:23:32 to 01:24:08: Astra and Muse connecting the refinery with 40 seconds left, Muse correcting
  Astra's inlet ("Correction: crude inlet joins (-91.5,-380.5); (-89.5,-380.5) is the water inlet, leave it").

### Aloud

32 aloud lines (shake2 25): Opus 10, Astra 5, Sol 4, Grok 4, Luna 3, Haiku 3, Gemini 2, Muse 1, Sonnet 0. The first
eleven (2.3m to 10.7m) are claims, status and handovers, eight of them with coordinates (Astra #1, Sol #3, Haiku #20,
#74, #90, Opus #59). From 14m on, most are the moments the prompt names (milestones, the oil find, the raid call, the
final stretch).

### Confessions

None. No agent sent `./fh confess` (0 `confess` requests in the nine journals; the 2 to 4 journal lines per agent that
mention it are the `describe` reply). The CLI supports it (`vendor/factorio-harness/dist/host/cli.js:50`, `:269`).
The prompt mentions it once, as one line with no occasion (`agent/team.md:55`, AGENTS.md:241).

### Identity

| Agent | Name | Glyph | Colour | Motto | Voice | Pronouns | Avatar |
|---|---|---|---|---|---|---|---|
| astra | Astra | ✦ | #985bff | "From stone to stars, one good layout at a time." | athena | | engineer, crest, wide, star, headset, night |
| sol | Sol | S | #f5b642 | "Keep the furnaces bright" | el-charlie | | engineer, hardhat, goggles, plate, headlamp, glow |
| luna | Luna | ☾ | #5bd7c8 | "Quietly turning ore into orbit." | luna | | engineer, hood, wide, gear, antenna, night |
| opus | Opus | ♜ | #d97a3a | "Steam first, questions later" | el-george | | engineer, hardhat, goggles, bolt, pipe, glow |
| sonnet | Sonnet | S | #33aaff | "Steady belts" | none | | none |
| haiku | Haiku | 🌸 | #7fb3ff | "Short steps, steady factory." | none | | none |
| grok | Grok | ⚡ | #c8f542 | "Plates now, rockets before the clock dies." | zeus | he/him | robot, power, grid, rocket, antenna, hazard |
| gemini | Gemini | ♊ | #ff3366 | "Two steps ahead, bridging science to the stars." | orion | | robot, crest, slit, circuit, antenna, glow |
| muse | Muse Spark | ✦ | #ff8c00 | "feed the furnaces first" | oa-cedar | | none |

All nine set a profile in their first 3 minutes (journal `profile` requests, 00:24:33 to 00:28:27). Compared with
shake2:
- Voices: 7 of 9 picked one (shake2 4), all different, across three providers (el-, oa- and the plain names). Sonnet and
  Haiku again picked none.
- Avatars: 6 of 9, and no longer copies of one example; Sonnet, Haiku and Muse set none.
- Pronouns: only Grok ("he/him").
- Clashes left: Astra and Muse share ✦ again, Sol and Sonnet share "S", Sonnet and Haiku are close blues, Opus and Muse
  close oranges.
- Everyone still uses its model name.

Whether the identities came through on the stream (voices played, pronouns used by the hosts) is in section 6.

### Board

93 board calls (shake2 112) and 1 `harness_request` (Sol). Items 1 to 23: 14 claims, 5 requests, 2 tasks, 1 note, 1
harness item.

| Agent | board / post / update |
|---|---|
| luna | 21 / 2 / 11 |
| astra | 5 / 8 / 10 |
| sol | 5 / 4 / 2, + 1 harness request |
| muse | 5 / 3 / 1 |
| opus | 2 / 3 / 1 |
| grok | 1 / 3 / 0 |
| gemini | 2 / 1 / 0 |
| haiku | 1 / 1 / 0 |
| sonnet | 0 / 0 / 0 |

| # | By to owner | Posted | Closed | Title | Outcome |
|---|---|---|---|---|---|
| 5 | astra to luna | 3m00s | 5m26s, by Astra | Coal for copper drill | Astra supplied it |
| 6 | sol to luna | 3m19s | 6m20s | Coal and stone for northern iron | delivered |
| 8 | astra to luna | 3m45s | 4m31s, by Astra | 10 stone for copper furnaces | Astra mined it |
| 13 | opus to luna | 8m18s | 19m37s | Keep lake boiler fueled | Luna hand-fed it; superseded by Opus's coal belt (task #15) |
| 22 | astra to sol | 47m52s | 48m02s | Authorize surplus iron collection | granted in chat 8 s earlier |

- The board was a claim registry and an early queue: 20 of 23 items were posted in the first 15 minutes. After 15m05s
  only #19 to #23 went up. Mid- and late-game asks went to chat (above).
- Its best use was Astra's oil note #19 at 25m30s, with all 8 wells and bounds, which Muse claimed as #20 at 30m06s.
- Luna was again the board's worker (34 calls, 11 updates); Sonnet never called it.
- No defence or warden item was posted; Sol's harness item #17 stayed open.
- Against shake2 (10 requests, 7 done, median 4m17s) the board carried fewer requests (5), which fits the brief (board
  for logistics) only for claims: the logistics moved to chat rather than to the board.

## 5. Combat and defence

Gun turret was researched between 30m32s and 32m32s, queued first by Sonnet at 29m32s right after the first raid
(chat #285). Shake2 researched it at 20m44s but placed its first turret 21 minutes later.

| Raid | Game time | Where | Losses (team `losses` alerts) | Response |
|---|---|---|---|---|
| 1 | 28m40s to 29m07s | copper yard and coal trunk near (-48,16) | 1 belt; Astra down to 47 hp | Opus alerted at 28m49s (#274); Astra shot them (#279, #286); Luna, Sol, Haiku came |
| 2 | 31m12s to 31m49s | (-48,16) and the iron edge (-48,-16) | 2 belts, 1 chest; Astra died at (-43,0), Sonnet at (-59,-14) carrying 2 turrets and 234 iron | Astra #304: "Turrets urgently needed south" |
| 3 | 35m30s to 36m12s | lake power plant | 27: 22 belts, a boiler, a steam engine, an inserter, a pipe, a chest | Opus aloud #341 "URGENT"; Astra, Grok, Luna, Muse, Haiku, Sol came; coal gap rebuilt by 36m53s (Astra #359); boiler 3 and a turret at (22,23) by 37m41s (Opus #372) |
| 4 | 42m43s to 43m29s | west coal and power drill field (-88..-73, -22..-14) | 21: 9 belts, 5 burner drills, 3 electric drills, 2 poles, a chest; Sonnet died | Haiku shot; Muse, Luna, Grok came; Sonnet placed 3 turrets at 44m46s; Opus a fifth at (-78,-22) |
| 5 | 49m33s | (-48,16) | none; turrets took 224 damage (Astra #466) | |
| 6 | 63m27s | (-48,16) | none | after the Codex deadlines |

- Deaths: 3, all to small biters near base (Astra once, Sonnet twice). No scout died: Astra's oil route went north by
  x -170, "clear of mapped nests" (#249). Shake2: 4 deaths, 3 of them oil scouts to worms; shake1 about 10, to biters.
- Turrets: 11 placed (Sonnet 6, Opus 5), the first at 32m28s, within 2 minutes of the technology (shake2 4, shake1
  about 12). Sonnet (-45,-13), (-55,-13), (-54,9) at 32m28s to 33m06s and three on the west coal field at 44m46s; Opus
  (-54,16), (-46,23), (-36,4) at 33m38s to 33m47s, (22,23) at 37m22s, (-78,-22) at about 43m42s. Nine placements
  failed (blocked or out of reach). Gemini built an ammo assembler at 34m00s (#328), which Haiku kept fed.
- Defence ownership was set in chat (Astra to Sonnet at 29m42s, #287, acknowledged #292), not on the board.
- Each response covered the area just hit, and responders mostly arrived to "no live biters" (Haiku 29m22s, Luna
  29m30s, Muse 36m35s, Grok 43m19s). The raids that hurt (3 and 4) hit places the earlier turrets did not cover. After
  turrets covered all three hit areas, raids 5 and 6 caused no losses.
- Production cost: the dip from 406 to 177 iron plates a minute between 36.6m and 44.6m spans raids 3 and 4; power
  dropped to 4 engines for about 3 minutes after raid 3 (Opus #350).

## 6. The stream

Sources: `runs/shake3/caster.log` (535 lines), `tools/stream/logs/caster-20261011-002412.jsonl` (1,054 records),
`director-20261011-002409.jsonl` (1,052), `viewers-20261011-002409.jsonl` (0 bytes), `runs/shake3/stream-service.log`
(916 lines). The caster started at 00:24:12 on main 30d52c9 (00:23:16). Line numbers below are in the current tree
(611b6a5), where the cited code is unchanged.

### Hosts

- 441 lines written, 428 aired, 214 each for Rook and Vale, 00:24:15 to 01:26:55: 6.8 lines a minute in 195
  exchanges; the longest silence was 34 s (01:05:45). Events voiced: chat 138, camera 69, board 58, lull 54, research
  33, attack 30, segment 22, power 14, loss 10.
- Writer (Kimi K2.6 on Workers AI): median 2.65 s, p90 5.88 s, max 12.1 s; 9 timeouts (`[writer] failed:
  TimeoutError`, caster.log lines 130 to 359) and 18 exchanges written by the template fallback ("Cameras find Opus.
  Let's watch.", 00:40:30).
- `check_line` (`tools/stream/caster.py:376`) rejected 37 lines, 14 for a number not in the facts; some were true
  ("Eleven labs" at 01:24, from Sol's chat but not in that event's facts).
- Cost: $1.53 for the hour (writer $0.26, TTS $1.30).
- TTS: median 3.1 s, p90 4.2 s, max 19.1 s. 11 lines never aired because synthesis failed, all `CFError: 500 ...
  AiError ... 8008` from Workers AI: 9 host lines (00:40:49, 00:42:28, 00:49:46, 01:05:58 twice, 01:08:24, 01:14:16)
  and 2 agent lines (Luna 00:35:43; Opus 00:52:51, the aloud "power line to oil is DONE").

The hosts were most likely not on OpenAI voices. The caster ran code in which `--tts auto` tried ElevenLabs first and
fell back to Deepgram Aura-2 (atlas, thalia) without logging it. The commit that moved the hosts to OpenAI (19b4c72,
"voices: auto prefers OpenAI for shake3 ... a provider out of credits rests") landed at 00:28:18, four minutes after
the caster started, so it never ran. The logged TTS spend ($1.305) matches Aura-2's rate on every aired character
(43,930 characters, $1.318); ElevenLabs would have been about $1.76 and OpenAI about $0.75. The caster record logs
`voice: atlas/thalia` from a constant (`caster.py:1021`), not the provider that spoke, so this is an inference from cost.
The agents' el- voices (Opus el-george, Sol el-charlie) most likely went the same way.

### Factual mistakes and their causes

Four causes in the facts the hosts were given:

- A. Attack counts are hits, and the stream presents them as counts. The runtime's attack alert lists `<entity> x<hits>`
  (shake1 logged `crash-site-spaceship x820` with `hits=820`). `tools/stream/live.py:271` puts the first entry into the
  banner ("Base under attack near (-48, 16): character x3"), `caster.py:210` rewrites `x3` as "(3 of them)", and
  `caster.py:284-287` adds "the biters are damaging:". The hosts then read the number as enemies or as buildings.
- B. Loss alerts end "(by N small biter)", where N equals the loss total in every alert (1 of 1, 3 of 3, 21 of 21, 27
  of 27): kills credited to small biters, not biters (`live.py:257`).
- C. An agent between actions gets the status "thinking (standing still)" (`caster.py:232`). 102 of 443 host lines (23%)
  call agents frozen, statues, standing still or idle, against the rule "never mean to a player" (`caster.py:342`,
  `:356`): "nine statues in the dirt" (00:24:39), "Steady is code for watching spiders chew their homework" (01:06:51).
- D. No time-left fact: `context_facts` (`caster.py:243`) gives the game time but not the deadline.

| Time | Host | Line | What was true | Cause |
|---|---|---|---|---|
| 00:40:14 | Vale | "Nineteen machines starved now, worse than last minute's twenty-one of thirty-nine" | 19 of 55 is better | arithmetic |
| 00:40:37 | Vale | "Seventeen minutes of low power" | 17 minutes was the game time | game time read as a duration |
| 00:41:12 | Vale | "Astra scouts for oil that isn't there" | the field was found at 00:48 | invented absence; `check_line` misses "isn't there" |
| 00:51:36 | Rook | "three teammates bleed at spawn" | 3 hits on characters | A |
| 00:53:04 | Rook | "One small biter ends the run at thirty flat!" | 1 belt lost; the run went on 31 minutes | B; "ends the run" also in shake2 |
| 00:53:55 | Rook (template) | "the biters are damaging: character (1 of them)!" | raw alert read out | A |
| 00:54:01 | Rook | "Nine engineers bleeding out! Astra down, three belts gone" | 9 hits; 2 belts and Astra lost | A, B |
| 00:54:01 | Vale | "forty minutes to a turret that can't save them now" | gun turret was researched at game minute 31 | invented |
| 00:54:45 | Rook | "nine biters chew their boots" | 9 hits on characters | A: our damage read as enemy count |
| 00:55:58 | Rook | "they fall to two small biters" | 2 kills | B |
| 00:57:59 | Rook | "Biters chew fourteen belts" | 14 hits on belts | A |
| 01:05:14 | Rook, Vale | "thirteen poles crack" | 13 hits; 2 poles lost | A |
| 01:07:00 | Rook (template) | "21 lost: 9 transport belt, 5 burner mining drill (by 21 small biter)" | 21 kills | B |
| 01:12:04 | Rook | "Biters chewing fourteen turrets at forty-nine!" | 14 hits on turrets | A |
| 01:12:04 | Vale | "before the wall's a memory" | no walls were built | invented |
| 01:13:28 | Rook | "Fourteen turrets took hits" | 14 hits | A |
| 01:15:06 | Vale | "two thousand down on shake1" | 1,614 fewer iron plates | rounding |
| 01:16:28 | Vale | "calculating doomsday at nineteen percent and falling" | research progress never falls | invented |
| 01:19:25 | Vale | "Oil gathering crawls at sixty-five, forty more minutes of biter bait" | 4.5 minutes to the deadline; done at 01:21 | D |
| 01:21:39 | Vale | "Shake1 made fewer plates, fewer circuits too" | shake3 made 54 fewer circuits than shake1 | half wrong |
| 01:24:26 | Rook | "Gear and Sol do the heavy lifting" | no agent named Gear | name check passes it |
| 01:25:38 | Rook | "biters chew ten turrets" | 10 hits | A |

On Nick's three reports: the mix-up of damaged buildings with enemy counts is cause A (00:54:45 and the rows marked
A). No logged host line contains "crash" or says research progress is lost; the overlay banner and the replay titles
carried the raw alert, such as "Base under attack near (-48, 16): character x3" (replay saved 00:51:19), which reads as
characters attacking the base, and the nearest research line is "nineteen percent and falling" (01:16:28). Lines lost to
TTS failures (9) or cut for urgent events (4) were not aired, so the "crashing" and "progress lost" impressions most
likely came from the on-screen banner and the lines above, or from wording the log does not hold.

Identity on air: the caster never receives pronouns (`agent_facts`, `caster.py:223`, has no pronoun field) and its
rules force "they" (`caster.py:341`, `:350`), so Grok's "he/him" never reached the hosts; Rook once called Luna "she"
(01:10:25). Display names and mottos do reach the hosts. 34 agent lines were voiced (49 picked, 15 skipped by spacing
rules): Opus 7, Astra 6, Grok 4, Sol 4, Sonnet 3, Haiku 3, Muse 3, Luna 2, Gemini 2. Sonnet and Haiku, who picked no
voice, got el-jessica and oa-coral from their names. The stream's own classifier put 498 of 547 chat lines (91%) as
logistics.

### Director, segments, replays

- 1,052 camera commands on 3 cameras: 331 reframes, 274 pair and 177 unpair, about 80 rotations, 28 score cuts, 59
  action zooms, 13 attack cuts, 3 segment moves. Pair framing held the main camera for 55.0 of 62.8 minutes.
- Main-camera share (pair time split): Astra 22%, Opus 14, Luna 12, Muse 10, Sol 10, Grok 9, Gemini 8, Sonnet 7, Haiku
  5. Zoom 0.5 for 22 minutes and 0.75 for 22.
- One command failed: the overview at 01:18:39 asked for zoom 0.129 and the runtime refused ("zoom must be 0.3..4",
  stream-service.log line 788). `segments.py:262` floors the overview zoom at 0.05, and the team's spread was 202
  tiles with the oil field 400 tiles north. The hosts talked over an overview the camera never showed ("Nine agents
  scattered like seeds", 01:18:55).
- Segments that ran: overview 00:24:37; research 00:28:44, 00:48:18, 01:03:03, 01:11:50, 01:22:17; production
  00:35:04; spotlight on Sol 00:41:44; overview 01:18:59 (camera failed). Recap never ran.
- 6 attack replays were saved and aired (~00:51:31, ~00:54:17 Astra's death, ~00:58:17, ~01:05:28, ~01:12:19, ~01:26:00
  after the Codex deadlines). Their titles carry the raw hit counts. The caster at 30d52c9 asked for `attack_replay`
  segments that never came, so no host line was written as a replay breakdown; 262ef78 (merged 01:27) changes this.

### Live feed, viewer chat, screenshots, analyst

- `push-live.log` is empty because `site/push_live.py` prints only on failure (lines 85, 90); it started and logged
  none, so the pushes most likely went through. The logs do not show whether anyone watched.
- Viewer chat: `viewers-20261011-002409.jsonl` is 0 bytes and no `viewer` event reached the caster; no viewer line
  reached the game chat either.
- `shot-sync.log` is empty by design (`tools/shot-sync.sh` sends all output to /dev/null); 6 screenshots reached the
  agents' `shots/` folders.
- The analyst did not run: start-team has launched it by default, writing `analyst.log` to the run directory, since
  553ace7 (00:15, before the 00:21:48 start), and there is no such file, nor any analyst log in `tools/stream/logs`
  before 01:38:41. Why it did not start is not in the logs (start-team does not report it).
- `stream-service.log` holds 7 `ConnectionResetError` tracebacks from client disconnects.

## 7. Recommendations

P1 is at the top of this document.

### P2: harness and launch

6. Stop text (`agent/PLAYBOOK.md:105-112`, "Stopping"). The rule ended early stops, but the agents that wrote their
   final summary early (Opus at 50m50s, Sonnet at about 51m, both against "In the last three minutes") then treated
   the time to the deadline as time to wait (Sonnet and Haiku from about 01:13, Gemini from 01:16), and Sonnet told
   the team "Deadline reached" at 01:23:08, a minute before its own deadline and five before Muse's. Two wording fixes
   that steer nothing about play: say that deadlines differ per agent (so "deadline reached" is personal), and say that
   the summary written early is a draft to finish in the last three minutes. Whether to also say that sleeping is not
   playing is a judgement for Nick under the no-thumb rule.
7. Supervisor "done" test (`tools/supervise.sh`): it nudged Grok mid-turn (00:48:57, a backgrounded `move_to --wait`
   and a 120 s tool call in flight) and Muse five times while it built the pumpjacks and refinery. Treat an agent with
   a request in the last 2 minutes of its journal as working.
8. Clean profiles, round 4, as in shake2's P1 item 5, still open: Codex `<skills_instructions>` (5.4K characters,
   the owner's skills) and `<multi_agent_role>` (the workspace switches did not remove them); Claude Code's "user
   hasn't heard from you" reminder (Opus 36, Sonnet 29) and claude-b's email and git-log attachments; Grok's
   `~/.grok/rules/agent-tooling.md`, 3 failing MCP servers and global hooks, and the 2 secret-like strings in its
   events.jsonl (rotate); Muse's hooks from `~/.config/muse/settings.json` (`tools/clean-profile.py`). Keep route
   `codex` free of other sessions during a run (six `codex exec` sessions ran on it from 00:30 to 00:44).
9. Launch readiness (`tools/launch-agent.sh:166-177`): five agents waited the full 40-iteration loop (44 to 49 s each),
   stretching the launch to 4.5 minutes. Match each harness's ready screen, or launch all panes first and answer trust
   prompts in a second pass.
10. Runtime bugs (`vendor/factorio-harness`): `chat` fails while the character is dead (Sonnet, 3 times); a biter
    corpse blocks placement (Grok, 01:02); tree stumps block placement (Sol's item #17, unanswered); `collect want` in
    a queue still fails as in shake2 (Opus, 2).
11. Grok's compaction at 60% started 39 s before its deadline and ended its play (01:26:21); skip compaction in the
    last 2 minutes (`agent/context.tsv` or Grok's hook).
12. Stream: Workers AI 8008 errors cost 11 lines; retry once on a second voice before dropping a line. `check_line`
    rejected true numbers that came from chat ("Eleven labs"); include the numbers from the event's own chat text in
    the facts. `site/push_live.py` should log a periodic ok line; `tools/shot-sync.sh` discards all output.

### P3: playbook and show

13. Identity: list pronouns in the profile example in `team.md:12-16` (only Grok set them, and only because the field
    is mentioned in passing); reject glyphs already taken (Astra and Muse share ✦, Sol and Sonnet share "S").
14. Board after the opening: 20 of 23 items came in the first 15 minutes, and mid-game requests went to chat. Once P1
    item 5 points handovers at the board, check whether `team:` reminders of open items keep it in use.
15. Show: run the recap segment (it never ran), and check that replays are called as replays now that 262ef78 is in.
    The stream's own classifier voiced 34 agent lines in an hour; more banter in chat (P1 item 5) is what would raise
    that, rather than a looser classifier.

## 8. Verdicts per model, shake3 against shake2

- Astra: the run's best player again. Found the oil field on a safe route, posted the wells to the board, added labs
  when oil-gathering was short, connected the refinery in the last minute, the lowest error rate (1.7%), the most
  messages (125) and the one deliberate joke. Compaction stalls of 160 and 110 s.
- Sol: still the coordinator by volume (90 messages, the most mentions after Opus, Muse and Astra), with 49 large queue
  submissions and a north green bank that doubled green output; slower steps (median 11.9 s, p90 32.7 s). Chat text
  stayed spaced; notes did not.
- Luna: fast (473 steps, 2.0 s median), the board's worker again (34 calls), and no wind-down. Error rate down from
  7.7% to 3.4%.
- Opus: built and defended power (the lake plant, the oil power line, 5 turrets), ran a ferry plan, and gave the
  stream its best aloud lines (10, the most). Slept 23.8 minutes, more than in shake2.
- Sonnet: owned research order and placed 6 turrets after dying twice; never touched the board; slept the last 10
  minutes and announced the deadline early.
- Haiku: a fair test this time (2 compactions, no denials): it scouted north early, shot raiders, supplied iron and
  belts, and used 3 aloud lines; asleep about 44.5 of 60 minutes.
- Grok: green assemblers and ferries, the clearest aloud explanation of the oil unlock; errors up to 5.7%, mostly
  standing on its own build footprint; its last compaction ended its play 39 s early.
- Gemini: ammo assembler, mall supply, played past its deadline without a restart; slept through the 01:22 boiler
  outage; error rate up to 7.3% (24 `inspect` misses).
- Muse: claimed and built the oil site (two pumpjacks, the refinery), compacted once at the intended 200K, and cut its
  error rate from 8.3% to 2.6%. Joined last and owned labs, which made the opening
  slower.

## Appendix: methods

- Game time is tick/3600; tick 0 at about 00:22:19 PDT.
- Milestones and factory: `scores.jsonl` 2-minute snapshots, chat and notes.
- Chat: `runs/shake3/chat.jsonl`, `runs/shake2/chat.jsonl`, `runs/shake1/chat-full.jsonl`. Coordinates as in shake2;
  "tone marker" is a word list (thanks, sorry, great, nice, proud, oops, finally, crew, joke words and the like) or a
  doubled `!`/`?`; the logistics classifier counts item, quantity, chest, belt and claim words plus coordinates.
- Confessions, profiles and pronouns: `confess` and `profile` requests in the nine journals.
- Agents (section 3): as in shake2's appendix. Action gap here caps each timed action at the agent's next request, so
  it is stricter than shake2's. Codex steps from `tools/analysis/transcript_steps.py` and `codex_tokens.py`; journal
  errors and gaps from `tools/analysis/journal_errors.py` and `journal_gaps.py`. Grok from events.jsonl and
  updates.jsonl; Gemini from agy's `brain/<id>/.system_generated/logs/transcript.jsonl`; Muse from session.jsonl.
- Board: every `board`, `board_post`, `board_update` and `harness_request` in the nine journals, paired by id.
- Combat: team `attacks` and `losses` alerts in the journals, "bot X is dead" errors, and chat.
- Stream: the caster's jsonl record (aired, rejected, latency, cost), the director's command log, `stream-service.log`;
  each host claim checked against chat, scores and the alerts at that time.
- The one-off parsers live in the session scratchpad and are not committed.
