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
   04:54). Start the shift with `tools/start-team.sh` (the `POG_RESUME` path) from main after the last merge, check
   the code line in `runs/shake5/start.log` (start-team already logs each helper's pid and first line, which held in
   shake4), and watch Grok's first minute.
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
   30-minute rest ran out (`runs/shake4/caster.log:18`, `:350`, `:606`), so Opus's pick `el-george` played as OpenAI
   `fable` in all 13 lines. Top up the key or drop the `el-` voices from `agent/voices.md` while it is empty, so agents
   only pick voices the run can play.
6. The naturalist brief still makes "frozen" lines (section 6): about 30 of 696 lines call a planning agent frozen,
   still or motionless (shake3 102 of 443), 19 of them in naturalist exchanges ("Here sits Grok, still as a heron",
   04:06:25). `tools/stream/caster.py:43` says "A specimen planning its next step is deep in thought"; say instead that
   it is writing its next commands, and that frozen, still, motionless, idle and asleep are wrong for an agent whose
   status is planning (also in the rules at `caster.py:487`).

## 1. Summary

1. Two hours of Space Age reached chemical science research but not a blue pack: 24 technologies, plastics at 88.7m,
   advanced circuits at 96.8m, chemical-science-pack at 108.3m, 1,616 plastic and 211 advanced circuits. The sulfur
   plant at base never got petroleum (the gas line from the oil field 350 tiles north ended about 130 tiles short), so
   no blue pack and no rocket silo (section 2).
2. The first hour ended level with shake3 by game time: 15 technologies, the same green packs and iron, 531 red
   against 692. The opening lost 5 minutes on the first steam engine (13.1m against 8.0m), the middle gained them back
   (logistic science 2 minutes and steel 6 minutes earlier). Oil was found at 52.0m against 25.5m on the same field,
   but research set when crude flowed in both runs: oil-gathering finished at 61.8m (shake3 58.8m) and a pumpjack ran
   within a minute of it (section 2).
3. Defence decided the second hour. Seven raids from 34m on, groups of 66, 45, 70 and 46 from the southeast nests, at
   least 13 deaths (shake3 3). The 66-biter raid at 67.6m cut power to 197 machines and halved the labs, and science
   consumption nearly stopped for 14 minutes; plastics took 26 minutes of research. The last raids took power to zero
   and destroyed the advanced-circuit assemblers (sections 2 and 5).
4. The shake3 fixes held: a 16-second launch, no early stops, summaries without stopping, 2 supervisor nudges and both
   due, chat while dead, stumps and one's own footprint no longer blocking builds, Grok's clean profile, Codex's skills
   block gone, and Gemini's quota intact. New harness gaps: `sleep` refused while dead (19 calls), an item on the ground
   blocking builds with no hint (11), Claude Code ending its turn after compaction (2), and `board_post` rejecting
   `note` (section 3, P1 items 2 to 4).
5. Sleep spread through the run: Muse 77% of two hours asleep, Haiku 63%, Opus 48%, and mentions woke them most of
   the time. Astra and Sol ran words together in a third to a half of their lines after 50m, in whole Codex context
   segments, with no configuration change (section 3).
6. Talk: the board took 2.5 times shake3's traffic (232 calls; 66 posts, 78 updates, in both hours), but chat kept the
   same 547 messages in hour one at 94% logistics. Aloud doubled to 64, Sol made the run's one confession, three agents
   set pronouns (all "they"), and Astra had the best joke: "Next delivery: plastic. Preferably before the biters place
   another order." Two aloud lines announced blue and sulfur production that never ran (section 4).
7. The stream was much better informed: hosts' numbers matched hits and losses, time left was right, no gendered
   pronouns, OpenAI voices all run, the analyst ran 82 cycles without a failure and reached air in 29 exchanges, the
   overview zoom worked, 15 replays aired, and the live feed never failed. The main mistake class was a stale caster
   comparing with shake1 after shake1 had ended; the others are a few merged facts and about 30 "frozen" lines from the
   naturalist brief. ElevenLabs had no credits, and no viewer question arrived (section 6).
8. Team size: by minute 30 the three-agent pilot matched nine agents on research and red packs with a smaller base
   (70% of shake4's iron, 40% of its furnaces). The data stop at 32 minutes, before the first raid and before any
   second-hour work, so they say nothing about two-hour runs (section 7).

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
Gemini went north along x=-40 "to chart new territory" (#443, 49.7m). In both runs the oil-gathering research, not
the find, set when crude flowed (shake4: done at 61.8m, a pumpjack running by 62.6m). Shake4 was 3 minutes behind
shake3 there because its research was: engine and fluid handling came 2 to 3 minutes later.

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
with "8 iron plates" (#97), the engine needed 40 more plates, and Luna found that the boiler "has 0 water, pipe
network is disconnected from pump" (#127, 11.6m) and closed the pipe gap; Opus crafted the engine and placed it
(#141, #146). From 20m on the team caught up (logistic-science-pack 2 minutes and steel 6 minutes before shake3) and
then lost it again at engine and fluid handling.

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

Sources: each workspace's journal.jsonl.gz, supervisor.log, context.log, compactions.md and notes.md; the Codex
rollouts (`~/.codex-account-b/sessions/2026/10/11/` for Astra and Luna, `~/.codex/sessions/2026/10/11/` for Sol), the
Claude Code transcripts for the three `runs-shake4-<agent>` project dirs, Grok's session under `~/.grok/sessions/`,
agy's `brain/.../transcript.jsonl` and `log/cli-20261011_*.log`. "Decisions" are requests other than status reads,
chat peeks and sleep checks.

### Launch and stops

- One-pass launch held: nine agents from 02:52:17 to 02:52:33, all journaling by 02:52:57 (`start.log:13-32`; shake3
  4.5 minutes, five agents waiting out the readiness loop).
- No early stops. Every harness kept one turn to the deadline: Codex turn ends 04:52:05 to 04:52:37, Claude 04:52:06 to
  04:52:25, Grok 04:52:15; last decisions 04:51:16 to 04:52:26 for all nine.
- All nine wrote a final summary into notes.md (Luna's headed "(draft, deadline 04:52 PDT)", `luna/notes.md:69`;
  Sonnet's "(final, 1h53m)") and kept playing after it. The shake3 stop-rule change held.
- Two mid-run turn ends, both Claude Code, 7 to 44 seconds after an auto-compaction: Sonnet (compacted 03:41:32, turn
  end 03:41:39, nudged 03:44:05) and Haiku (04:20:44, 04:21:28, 04:23:50) (P1 item 3).
- Supervisor: 2 nudges in the run, both after a real turn end. Grok's 5 checks were correct skips ("status done: last
  request 0-1s ago, working", `grok/supervisor.log:1-5`), and Muse got none (shake3: 5 while it was building). The
  shake3 misfire did not recur. Gemini's agy loop never had to restart it: one conversation, 02:52:39 to 04:52:08.

### Activity and sleep

| Agent | Decisions (h1 / h2) | `./fh sleep` calls | Asleep, whole run (last 30 min) | Woken by a mention | Gaps >120 s outside sleep |
|---|---|---|---|---|---|
| astra | 994 (547 / 447) | 118 | 33.9 min, 28% (5.8) | 169 of 233 | 8.9 min, compaction stalls |
| sol | 1,233 (568 / 665) | 27 | 9.7, 8% (0) | 40 of 52 | 10.7 min, compaction stalls |
| luna | 2,030 (1,067 / 963) | 81 | 7.7, 6% (2.4) | 30 of 38 | 5.3 min |
| opus | 1,175 (753 / 422) | 104 | 57.0, 48% (23.0) | 196 of 208 | 0 |
| sonnet | 1,310 (716 / 594) | 32 | 16.0, 13% (7.3) | 52 of 64 | 2.5 min, turn end |
| haiku | 1,075 (487 / 588) | 122 | 75.4, 63% (20.5) | 218 of 244 | 2.5 min, turn end |
| grok | 1,816 (864 / 952) | 38 | 15.6, 13% (6.4) | 20 of 76 | 0 |
| gemini | 1,212 (719 / 493) | 4 | 2.1, 2% (2.1) | 6 of 8 | 0 |
| muse | 577 (337 / 240) | 130 | 92.5, 77% (27.7) | 186 of 260 | 0 |

- "Asleep" runs from a sleep's reply to the next decision, capped at the requested length plus 5 seconds. Shake3, one
  hour: Haiku 74%, Opus 40%, Sonnet 32%. Sleep is spread through the run (Haiku slept 20.5 of its 75.4
  minutes in the last 30) in short spells: mentions ended most sleeps, so the `@` traffic in chat sets the sleepers'
  pace.
- Muse works through queues (101 `queue_submit`, 130 sleeps); its sleeps mostly overlap queued work, which the journal
  does not record, so its 77% is not all idle character time.
- Opus's decisions fell from 753 to 422 in the second hour, 32.8 of its 57 asleep minutes there, after the 67.6m raid
  destroyed its science block (`opus/compactions.md:16-17`).
- The harness's per-reply "character idle" share could not be summed: the clock line is on a fraction of replies and
  its windows overlap.

### Errors and denied commands

| Agent | Errors (rate; h1 / h2) | shake3 rate | Largest classes |
|---|---|---|---|
| astra | 23 (2.3%; 2.2 / 2.5) | 1.7% | `board_post` argument shape, reach, visibility, dead (4) |
| sol | 27 (2.2%; 2.8 / 1.7) | 2.3% | placement blocked (6), "Unknown entity name: tree" (2) |
| luna | 98 (4.8%; 5.2 / 4.5) | 3.4% | `inspect` outside the visible area (7), transfer out of reach (7), `board` with `note` (4) |
| opus | 43 (3.7%; 2.9 / 5.0) | 5.4% | dead (6), transfer out of reach (5) |
| sonnet | 54 (4.1%; 4.7 / 3.4) | 7.7% | dead (9 across observe, sleep, wait_until, transfer), `wait` (unsupported) |
| haiku | 64 (6.0%; 4.9 / 6.8) | 6.2% | placement blocked (11), sleep while dead (8), rearm with no magazines (6) |
| grok | 73 (4.0%; 4.4 / 3.7) | 5.7% | transfer out of reach (10), placement blocked (10, 9 of them item-on-ground at one spot) |
| gemini | 71 (5.9%; 5.4 / 6.5) | 7.3% | placement blocked (13), `inspect` outside the visible area (7) |
| muse | 29 (5.0%; 4.5 / 5.8) | 2.6% | dead (9) |

- Rates fell for Opus, Sonnet, Grok, Gemini and Haiku, rose for Luna, Muse and Astra; Sol flat.
- Harness gaps behind the errors: `sleep` refused while dead (19 calls, 7 agents; P1 item 2) and `observe` while dead
  (26 more); item-on-ground in a build footprint (11; P1 item 4); `board_post` rejecting `note` and object `needs`
  (section 4); `observe` name filters wanting exact prototype names ("Unknown entity name: tree", Sol 2, Gemini 1).
- Denials (Claude Code dontAsk): 7 (Opus 4, Sonnet 2, Haiku 1; shake3 6): `for` loops, `python3 - <<'EOF'`
  heredocs, a pipe into `grep -E`, two chained transfers, and one `./fh say` (Haiku 02:53:54). None ended a turn.
  Codex, Grok (549 permission requests, all resolved), Gemini and Muse: none found.

### Compactions and context

| Agent | Setting | Compactions | Before to after | Stall | Notes back |
|---|---|---|---|---|---|
| astra | Codex 140K | 5 (03:15:45 to 04:48:21) | ~139K to a new window | 108 to 141 s, 10.6 min total | re-read 2 to 3 s after, 5 of 5 |
| sol | Codex 140K | 5 (03:18:32 to 04:52:10) | ~139K | 61 to 200 s, 10.1 min | re-read, 5 of 5 |
| luna | Codex 140K | 8 (03:05:24 to 04:45:22) | ~139K | 18 to 45 s, 3.4 min | re-read, 8 of 8 |
| opus | Claude 250K | 1 (04:00:46) | 250.1K to 36.5K | 30 s | hook (5,270 chars) |
| sonnet | Claude 200K | 2 (03:41:32, 04:18:39) | 200K to 22.6K, 26.8K | 26 s, 40 s | hook; turn ended after the first |
| haiku | Claude 80K | 8 (03:07:17 to 04:42:20) | 80K to 24.5K, rising to 31.1K | 18 to 103 s | hook; turn ended after the sixth |
| grok | 154K | 3 (03:21:55, 03:52:12, 04:24:12) | not logged | 57 to 62 s | reinjected 3 s after |
| gemini | agy's own, ~280K | 3 (03:33:18, 04:09:22, 04:48:43) | 275 to 284K to ~19.5K | | agy checkpoint summary |
| muse | 0.391 of 512K | 2 (03:43, 04:14) | not logged | async | reinjected |

- Haiku compacted 8 times in two hours (shake3 2 in one) at the same 80K setting (`agent/context.tsv:9`); its floor
  after compaction rose from 24.5K to 31.1K, so the usable window shrank to about 50K and compactions came every 8 to
  14 minutes in the second hour.
- Codex compactions stalled Astra and Sol about 10 minutes each in two hours (shake3: 4.5 and 4.3 in one), against 3.4
  for Luna at the same setting. Astra's fifth (04:48:21) took 136 seconds of its last 4 minutes.
- Context at the end: Astra 52.9K, Sol 26.2K (just compacted), Luna 89.5K, Opus 122.2K, Sonnet 83.9K, Haiku 47.7K,
  Gemini 62.0K; Grok and Muse log no token counts.
- Gemini's 5-hour quota held: no quota or rate-limit event in the transcript or the agy logs (only routine
  `doRefreshQuota` reloads), and decisions continued to 04:51:22.

### Squashed words in Astra's and Sol's chat

The run-together words (section 4) follow Codex context segments; no configuration changed. Every `turn_context` in
the rollouts has the same model and effort (low), as in shake3 with the same CLI (0.162.1), where nobody squashed.
Astra squashed in whole compaction segments: 0 of 43 lines before 03:15:45, 0 of 38 to 03:41:55, 25 of 33 to 04:04:26,
0 of 49 to 04:28:23, 25 of 33 to 04:48:21, 0 of 5 after; the first squashed line came 3.7 minutes into a segment, at
56K. Sol began at 133K (03:44:46) and stayed squashed through later compactions, re-reading a notes.md that is itself
squashed ("As ofgame1h58", `sol/notes.md:41-42`). Only tool-call arguments are squashed, never the visible assistant
text or reasoning summaries. The likely reading is that the model copies its own style within a context segment; a
compaction clears it or, through notes.md, carries it on.

### Did the shake3 fixes hold

| Fix | Held | Evidence |
|---|---|---|
| Chat while dead | yes | 0 `say`/`chat` failures while dead (shake3 3); `sleep` still fails (P1 item 2) |
| Build over stumps and corpses | yes | 0 stump blocks (shake3 7), 0 biter-corpse blocks; 1 character-corpse among other blockers |
| Step aside from one's own footprint | yes | no build failed with the agent's own character as the only blocker (shake3: Grok alone 9) |
| `collect want` | not exercised | 2 direct calls (Luna), 0 errors |
| Glyph uniqueness | yes | no profile failure; glyphs all distinct (colours are not, section 4) |
| No supervisor nudges to working agents | yes | 2 nudges, both after real turn ends |
| One-pass launch | yes | 16 seconds |
| Clean profiles | mostly | Codex's skills block gone (shake3 5.4K chars on every request); Grok's prompt 5,423 chars with no owner rules, MCP servers, hooks or secret-like strings; Codex's `multi_agent` text remains (Astra 17, Sol 17, Luna 26 occurrences) |
| Per-agent deadlines and draft summaries | yes | all nine summaries, no stop after writing them |

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

The logistics share did not move: hour one has the same 547 messages as shake3 and 94% logistics, after the round-4
prompt sent claims and handovers to the board (`agent/team.md:35-39`, "post or update the board item with what and
where"). The board did take more traffic (below), so chat did not shrink because of it; chat kept the coordination that
the board records, in the form of `@name` requests and status ("@opus I added 29 iron plates to your red-science chest
(-18.5,-34.5)", Luna #693). Per agent: Luna 230 (222 logistics), Astra 201, Sol 148, Haiku 97, Opus 78, Grok 74, Muse
68, Sonnet 64, Gemini 51. Lines whose point is a joke or a feeling are again about half a dozen (best moments below).

Astra and Sol ran words together in 39% and 55% of their lines from 50m on: "Northbankrestartedverified1h05m:
coalleftlane, oreclear, furnacesworking" (Astra #587). By 10-game-minute bin, Astra 0 lines before 50m, then 10 of
16 (50 to 60m), 13 of 14 (60 to 70m), 2 of 20, 0, 0, 11 of 18 (100 to 110m), 11 of 15 (110 to 120m); Sol 1 of 10 (50
to 60m), 10 of 11, 7 of 7, 1 of 14, 11 of 14 (90 to 100m), 7 of 16, 9 of 12. Luna, also on Codex, never did; nobody
did in shake3 (counted as a run of 22 or more letters). The hosts and the TTS receive these lines as written.
Section 3 traces it to Codex context segments.

### Board

232 board calls (shake3 93): 88 reads, 66 posts, 78 updates, plus 1 harness request (Astra). Posts by kind: 24 claims,
19 requests, 18 notes, 5 tasks (10 of the 66 failed and were resent, below). Updates: 21 done, 20 doing, 8 dropped.
Use was not only the opening: 53 posts and 59 updates in hour one, 13 posts and 19 updates in hour two (Astra 8 and 12
of those).

| Agent | reads | posts (h1 / h2) | updates |
|---|---|---|---|
| luna | 57 | 8 / 0 | 19 |
| astra | 7 | 15 / 8 | 25 |
| sol | 7 | 11 / 2 | 19 |
| haiku | 4 | 4 / 3 | 4 |
| opus | 2 | 5 / 0 | 3 |
| grok | 2 | 4 / 0 | 2 |
| gemini | 4 | 2 / 0 | 1 |
| muse | 1 | 3 / 0 | 4 |
| sonnet | 4 | 1 / 0 | 1 |

10 posts failed and were resent within seconds, all on argument shape: 7 with an argument a post does not take, 5 of
them `note` (`unknown argument note for board_post; valid: area, kind, needs, owner, tags, ...`; Grok 02:53:40, Luna
02:53:45, Sol 03:27:50, Astra 03:29:54 and 04:08:20) and Haiku's `status` (03:21:32) and `requested_by` (04:15:57);
and 3 with `needs` as an object instead of a list (`needs is text or an array of 1..16 item names or {...}`, Sol
03:27:54, Astra 03:29:59 and 04:08:23). The prompt offers `"note"` for updates (`agent/team.md:52`), so agents reached
for it on posts too.

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
- Defence was organised in chat again; the board carried only Astra's "Shared power defense wall screen" note
  (04:21:48) and Sol's defence handover chest claim (04:25:56).
- The raid groups came from nests to the southeast ((83,93), (74,78), (50,94), (83,99)) and went for the power plant at
  (28,3) four times. Turrets there were placed or topped up after raids 2 and 3 and lost in raids 4, 6 and 7 (#748;
  Astra #847, "eastturrets gone"; Opus #936, "no turrets are left there").
- The `kite` tool was the agents' discovery of the run: Astra used it in raid 2 and taught it to everyone aloud (#615),
  Sol coached "kite min7/max12" (#932).

## 6. The stream

Sources: `tools/stream/logs/caster-20261011-025203.jsonl` (1,836 rows: 708 host lines, 62 agent voice rows, 1,012
chat decisions), `analyst-20261011-025203.jsonl` (82 cycles), `director-20261011-025159.jsonl` (2,276 camera
commands), `viewers-20261011-025159.jsonl` and `viewer-answers-20261011-025203.jsonl` (both empty), and
`runs/shake4/{caster,analyst,stream-service,push-live,shot-sync}.log`.

### What held from shake3's P1

- Every helper is listed in `start.log` (stream-service, chat-log, shot-sync, caster, push-live, analyst, "up" at
  02:52:11), and the analyst ran. The "plus uncommitted changes" was tracked bytecode, untracked by b085e3c at 02:53.
- Hits are not enemies: attack facts now carry `numbers_mean`, and no host line turned a hit count into a number of
  biters (156 combat lines checked). Numbers that aired match the facts ("Biters chewed forty-nine buildings ... then a
  hundred more!" for 49 then 109 lost, 04:00:50; "Grok saw sixty-six coming", 03:59:31, from Grok's chat).
- No "crashing" and no "research progress is lost". The analyst's correction ("Research progress is always kept")
  was in the facts of 342 of 343 exchanges, and 9 lines said it right ("research holds, progress keeps", Vale
  04:33:53). "Crash" appears only for the crash-site wreck, which the analyst describes as scenery.
- Time left is right in every line checked: "Thirty-one minutes left" at 04:20:44 (true 31.3), "Seventeen" at 04:35:17
  (16.7), "Nine minutes" at 04:42:48 (9.2). Two drafts with a wrong time were rejected before air.
- Pronouns: no he, she, him or her for an agent in 696 aired lines; one "the man" for Sol (Rook 03:59:18, "biters took
  the man, not the motto!").
- Host voices: OpenAI from the first line (Rook verse 354 clips, Vale ballad 341), one Aura-2 clip after an OpenAI
  failure (04:37:42, 47.8 s to synthesise).
- Overview zoom reaches the camera: the overview asks 0.3 and the camera gets 0.45; all 2,276 director commands
  succeeded (shake3: the overview was refused).

### The hosts' lines

708 written (Rook 364, Vale 344), 696 aired, 12 cut for an urgent event or a segment leaving (shake3 443 aired). Writer
Kimi K2.6 665, template 43; write latency median 2.4 s, p90 4.1 s, max 12.0 s; 4 writer timeouts
(`caster.log:276`, `:358`, `:405`, `:440`), each replaced by a template line. `check_line` rejected 93 drafts: a number
not in the facts 30, a name not in the facts 23, "something is missing" 13, "we" 11, previous-run comparison without
pace facts 4, timeouts 4, not English 3 (Chinese characters, 04:36:33), wrong or unsupported time left 4, pronoun not
given 1. Some name rejections were wrong: Grok was rejected at 04:42:22 and 04:42:29 although Grok had spoken aloud at
04:42:03, because that exchange's facts did not carry Grok, and template lines aired instead. Cost over 122 minutes:
writer $0.58, TTS $1.67, classifier $0.006 ($1.11 an hour); the analyst $4.49 API-equivalent.

### Factual mistakes, with causes

| # | Line (PDT, host) | Truth | Cause |
|---|---|---|---|
| 1 | 04:15:48 Rook "they surge four techs ahead of shake1"; 04:17:42 Vale "Five techs up on shake1, eleven thousand iron ahead"; 04:21:05, 04:26:29, 04:34:58 Rook "eight ahead of shake1", 04:35:01 "faster than shake1 ever dared", 04:38:43 Rook "nine ahead of shake1" and Vale "Eighteen thousand more iron plates" | shake1 ended at 60 minutes with 14 technologies; there is no shake1 at game 85 to 108 | the caster started 4m41s before fc29bd8; its pace facts compared with shake1's final sample (P1 item 1) |
| 2 | 02:55:08 Rook "they trail by sixty seconds on the same map!" | shake1 was the base game on the same seed; shake3 was the previous run | `tools/stream/baseline.py:62` calls shake1 "the team's previous run on the same map" |
| 3 | 03:44:06 Rook "five hundred more circuits than shake1 had! Red circuits now"; 03:44:39 Vale "Five hundred red circuits ahead of pace" | the 501 were electronic (green) circuits; advanced circuit research finished at 96.8m | the writer merged a board title ("Sol advanced circuits workshop", a claim) with `electronic circuits_gap: 501 more` |
| 4 | 04:30:52 "Luna idles, sparkless, at the crash site"; 04:31:13 Rook "Luna stares at the crash site fire" | Luna was off camera (Astra and Gemini were on); Luna was at the workshop | `check_line` passes any name found anywhere in the facts (here a board post in `earlier_on_air`) |
| 5 | 04:40:18 Vale "two Sols freeze mid-thought" | Sol and Luna were on camera | writer slip; not caught |
| 6 | 04:41:04 Vale "Grok hand-crafts blue packs"; also 04:41:25 and 04:41:44 | no blue pack was ever made; Grok hand-crafted green packs ("I will hand-craft packs in the meantime", #915; Grok worked the green line all run) | inference: "chemical science pack researched" in the facts plus Grok's unqualified "packs" |
| 7 | 03:15:39 Rook "One engineer down, buildings eaten" | 1 lost: 1 engineer, to worms | over-claim on a loss line |
| 8 | 04:52:39 Rook "Nineteen in the co-op, Vale!"; 04:53:39 Vale "co-op cruised at fifty-five" | "co-op" is the earlier coop1 test, never introduced to viewers | the analyst compares with coop1 from minute 44 without saying what it was |
| 9 | about 30 lines: "Haiku stands frozen, deep in thought" (03:32:20), "Here sits Grok, still as a heron" (04:06:25), "the planning Opus, motionless in crisis" (04:43:21) | the agents were planning | the naturalist brief, `caster.py:43` (P1 item 6); shake3 had 102 of 443 |

Muse's false "Blue science is live" (#934) was not quoted by the hosts; mistake 6 made the same error from Grok's
lines. The hosts closed on "sulfur finally has water" (Vale 04:51:53), which was true, and "Sulfur plant lives" (Rook
04:51:20), which was not: it never had petroleum.

### The analyst

82 cycles from 02:52:13 to 04:53:45, every 90 seconds (gap median 90 s, max 93 s), latency median 11.5 s, no
failures. 569 points (stat 264, explainer 81, storyline 72, comparison 67, prediction 52, judgement 27), 71 dropped by
its own checks, 238 corrections (172 distinct), 106 segment suggestions (production 51, research 39, spotlight 10,
overview 5, recap 1). Its points reached air in 29 exchanges (61 lines; comparisons 16, stats 10, explainers 3). Good
uses: "Science is 12.7 per minute at minute 42. Shake2 had 23.3 and Shake3 had 20.2" became Vale's "Twelve-point-seven
science, Rook. Their forebears doubled that." (03:35:29); a copper-cable bottleneck became Rook's "copper cable chokes
at one-oh-six!" (04:24:08). Misuse: the "co-op" lines (mistake 8). Ignored: the first trigger-technology explainer
(02:52:14) drew "Any bets on who breaks away first?". Its corrections did their job: no lost-research, crash or
wreck-attack claim aired.

### Viewer questions

None arrived: both viewer logs are empty, while both endpoints were up (`analyst.log:1-2`, "answering viewer questions
... one per 150 s at most"). The stream was unlisted; these logs cannot say whether anyone watched.

### Segments, replays, director

- Recaps at 03:13, 03:33, 03:53, 04:23 and 04:47: every 20 minutes except one 30-minute gap, because a recap starts
  only when nothing is playing or queued (`tools/stream/segments.py:202`) and replays kept the queue busy.
- On screen, from the caster's `on_screen_now` facts: research 6, recap 5, overview 2 (plus 04:40:25 in the director
  log), production 2, spotlight 2 (Sonnet 03:21, Astra 04:53). Production ran twice in two hours although the analyst
  suggested it 51 times. The Space Age panel never appears in the facts; nothing went to space.
- Replays: 16 saved, 15 aired, from Sonnet's worm death (03:14) to "28 lost near (-33, 0)" (04:49). Haiku's death clip
  was queued and dropped when Opus died 43 seconds later (`stream-service.log:1806`, `:1866`). Each replay aired from
  about 27 seconds into a 42 to 44 second clip.
- Director: 2,276 commands, all ok (main 924, cam2 672, cam3 680): reframe 718, pair 592, unpair 380, zoom 146; 1,547
  framed two or more agents. Zoom 0.45 to 2.73, median 1.3.
- Captions against cards and the Space Age panel's look need the recording on the box; not checked.

### Voices and synthesis failures

- ElevenLabs had no credits all run (P1 item 5). Agent voices (62 clips: 47 aloud, 15 strategy): Gemini apollo 15,
  Opus el-george played as OpenAI fable 13, Astra athena 11, Grok arcas 8, Luna luna 8, Sol oa-cedar 3, Muse oa-onyx 3,
  Sonnet oa-coral 1 (assigned from its name), Haiku 0. Every pick but Opus's played as chosen.
- The chat classifier labelled 929 of 1,012 chat lines logistics (91.8%, not voiced), 64 aloud, 19 strategy; 83 were
  voiceable, 62 played, 21 skipped for the per-agent gap or cooldown.

### Live feed and frames

- `push-live.log`: 120 one-minute reports from 02:53:03 to 04:53:58, all "0 failed", 6 pushes a minute.
- `shot-sync.log` is 98,782 lines, 98,770 of them "skipped" re-reports of 24 stale screenshots from earlier runs, on
  each of 6,348 passes; 11 agent shots were copied. Nothing in it says a stream frame was skipped, and the noise hides
  real entries. `stream-service.log` has 18 harmless `ConnectionResetError` tracebacks from clients hanging up.

## 7. Team size: the three-agent pilot against nine agents

The pilot (`runs/sapilot`: Astra, Opus and Gemini, Space Age, the same seed, launched 01:38:49 to 01:40:17, 16
snapshots to game 30.3m) against the nine-agent runs at the nearest snapshot:

| Game minute | | sapilot (3) | shake4 (9) | shake3 (9) | shake2 (9) | shake1 (9, base game) |
|---|---|---|---|---|---|---|
| ~10 | red packs / techs | 9 / 3 | 10 / 3 | 10 / 3 | 16 / 3 | 0 / 2 |
| ~20 | red packs / techs / labs | 89 / 6 / 5 | 72 / 6 / 4 | 89 / 6 / 4 | 75 / 7 / 3 | 15 / 6 / 4 |
| ~30 | red / green packs | 247 / 21 | 234 / 25 | 202 / 8 | 148 / 2 | 136 / 34 |
| ~30 | technologies | 9 | 9 | 7 | 8 | 9 |
| ~30 | labs, assemblers | 5, 12 | 6, 19 | 7, 11 | 6, 9 | 5, 12 |
| ~30 | iron plates | 2,685 | 3,797 | 4,278 | 3,511 | 5,069 |
| ~30 | electric drills, furnaces | 3, 17 | 12, 42 | 17, 50 | 17, 31 | 12, 42 |

(Pilot at 30.3m, shake4 30.6m, shake3 30.5m, shake2 30.5m, shake1 30.3m; `scores.jsonl` of each run.)

What the data supports:
- In the first 30 game minutes, three agents matched nine on research and science: the same 9 technologies as shake4,
  13 more red packs, 4 fewer green, and more red than shake2 or shake3. Per agent, the pilot made three times as much.
- Nine agents built more: 41% more iron than the pilot, 2.5 times the furnaces, 4 times the electric drills, 1.6 times
  the assemblers. None of it turned into faster science by minute 30, because research then is bound by labs and
  lab time (5 labs in the pilot, 6 in shake4), and the extra plates went into the base.

What it does not support:
- Anything past minute 32: the pilot ended there. Shake4's second hour (plastics, advanced circuits, chemical science
  researched, 12 labs) has no three-agent counterpart, and neither does the cost of a bigger base: shake4's first
  raid came at 34m, after the pilot's end, and the pilot saw no attack at all. Pollution, and so raids, grows with the
  base, so the comparison would change in the second half hour in a direction these data cannot give.
- A claim that fewer agents are better in general: one pilot, one seed, three particular agents (Astra, Opus
  and Gemini), and no repeat. The pilot also ran on earlier code than shake4.
- A claim about red packs from assemblers: `produced` counts hand-crafted packs too, and the first 20 minutes of every
  run include hand-crafting.

## 8. Recommendations

P1 is at the top. Same rule: harness bugs, misleading prompts and launch hygiene; no strategy advice to the agents.

### P2

7. `board_post` arguments (section 4): 10 posts failed on shape and were resent. Accept `note` on a post, since
   `agent/team.md:52` offers it for updates and agents carry it over, and accept `needs` as an object `{item: count}`
   (`vendor/factorio-harness/mod/agent-harness_0.1.0/board.lua:126`); or show a post with `needs` in
   `agent/team.md:48`.
8. `observe` while dead (section 3): 26 failures. `sleep_check` already answers a dead character
   (`runtime.lua:3650-3654`); have `observe` reply "dead until tick N" the same way.
9. Baseline wording (section 6, mistake 2): `tools/stream/baseline.py:62` "the team's previous run on the same map" for
   shake1 should say the base-game run on the same seed; on Space Age runs, name shake3 or the pilot as the previous
   run if one is used.
10. The analyst's "co-op" comparison (mistake 8): name coop1 for viewers in the analyst's knowledge base (what it was,
    how many players), or leave it out of the comparisons it offers (`tools/stream/analyst.py` and its history).
11. `check_line` names (mistakes 4 and 5, and the wrong Grok rejections): accept every roster name, but count a name as
    supported only if that agent is on camera, in the event, or did something in `earlier_on_air`; reject "two
    <Name>s" (`tools/stream/caster.py`, `check_line`).
12. Haiku's compaction point (section 3): 8 compactions in two hours at 80K, with a floor that rose to 31K, so about
    50K of working room by the end. Either raise `compact_at` for Haiku on two-hour runs (`agent/context.tsv:9`) or find
    what grows the floor (the summary went from 7.7K to 11.4K characters, plus the notes print at session start).
13. Codex compaction stalls (section 3): about 10 minutes each for Astra and Sol in two hours against 3.4 for Luna at
    the same 140K. Their summaries carry 51 to 84K characters of `replacement_history`; look at why before a longer
    shift.
14. Profile colours (section 4): four agents chose oranges. Glyphs are already unique (`profiles.lua:98-107`); refuse
    or warn on a colour too close to another agent's, in the same way, so the stream can tell them apart.

### P3

15. Recap timing: `tools/stream/segments.py:202` waits for an empty queue; let an overdue recap (10 minutes late) go
    next.
16. Replays: when two deaths fall 43 seconds apart, play both or keep the first (`stream-service.log:1806`, `:1866`).
17. `shot-sync.log`: log each stale screenshot once, or clear the camera clients' old shots at launch (98,770 noise
    lines).
18. `observe` name filters: when a name is not a prototype ("tree", "rock-huge"), list the matching ones.
19. Chat logistics (section 4): the share stayed at 91 to 94% after the board took claims and handovers. If less
    logistics in chat is still wanted, the prompt lines that pull coordination into chat are "Answer teammates
    promptly" and the repeating `chat_remaining` (`agent/team.md:29-31`), and every mention wakes a sleeper (section 3);
    this is a reading of the data, and the cause was not measured.

## Appendix: methods

- Game time is `tick / 3600` from `scores.jsonl` (2-minute snapshots); event times come from chat (`tick` and
  `logged_at`) and journals (`at`, UTC, shown here in PDT).
- Chat classes use the shake3 keyword classifier unchanged (coordinates, or two or more item, chest, belt, claim or
  delivery words, make a line logistics). "Squashed" lines contain a run of 22 or more letters; section 3's segment
  counts use a slightly different rule (run-together words of 16 or more letters over 20% of a line).
- Board, confession and profile counts are requests in the nine journals (`board`, `board_post`, `board_update`,
  `confess`, `profile`), paired with their responses for failures.
- Raids come from the `alerts` in each reply's `team:` block, deduplicated across agents; deaths from chat reports and
  "your character died" alerts, so the count is a floor.
- Stream figures come from the caster, analyst and director JSONL logs; host mistakes were checked against the facts
  the writer was given for that exchange, and against chat and scores.
- Sections 3 and 6 draw on two read-only sub-analyses of the transcripts and stream logs; their numbers were
  spot-checked against the logs (caster quotes and times, ElevenLabs errors, `runtime.lua:3660`, `supervise.sh:46`,
  `caster.py:43`).
