# Study: shake2, the round-2 rerun of shake1

Run: 2026-10-10, agents launched 21:44:48 to 21:47:11 PDT, world `n`, seed 20261010, normal enemies, real time. Same nine
agents, models, harnesses and efforts as shake1 (`agent/team-nine.tsv`), with the round-2 fixes: the team board, lossless
chat, errors printed last, brief `--wait` replies, time left on the `clock:` line, the deadline-only stop rule, clean agent
profiles, per-harness compaction settings (`agent/context.tsv`) and supervisor changes. Deadlines were staggered by
launch order: astra, sol, luna 22:44; opus, sonnet, haiku 22:45; grok, gemini 22:46; muse 22:47. World tick 0 was
21:42:44, so game minute is about wall minute minus 21:42:44 (shake1: 16:58:05).

Sources, all read-only: `runs/shake2/` in the main checkout (chat.jsonl, scores.jsonl, caster.log, start.log, per-agent
journal.jsonl.gz, notes.md, context.log, compactions.md, supervisor.log, deadline.txt) and the native transcripts:

| Agent | Harness | Transcript |
|---|---|---|
| astra, luna | Codex (route codex-b) | `~/.codex-account-b/sessions/2026/10/10/rollout-2026-10-10T21-44-46-...` and `...T21-45-00-...` |
| sol | Codex (route codex) | `~/.codex/sessions/2026/10/10/rollout-2026-10-10T21-44-53-...` |
| opus | Claude Code (route claude-b) | `~/.profiles/claude/account-b/projects/*shake2-opus/28ee6e23-...jsonl` |
| sonnet, haiku | Claude Code (route claude) | `~/.claude/projects/*shake2-sonnet/97157911-...`, `*shake2-haiku/1ccc2434-...` |
| grok | Grok Build | `~/.grok/sessions/<cwd>/` (updates.jsonl, events.jsonl) |
| gemini | Antigravity `agy` | `~/.gemini/antigravity-cli/conversations/*.db` (copied before reading) |
| muse | Muse Code 1.4.4 | `~/.local/share/muse/sessions/2026/10/10/<id>/session.jsonl` |

Shake1 figures come from `docs/studies/shake1.md` and `shake1-transcripts.md`, or were recomputed on the shake1 data with
the same code as shake2 (marked where they differ from the studies). Methods are in the appendix. Quotes are verbatim,
including Sol's and Astra's run-together words.

## 1. Summary: what changed and why

1. The outcome did not move. Shake2 researched 15 technologies (shake1 14; the extra one is radar) and ended with
   oil-gathering at 63 to 68% at the 22:44 deadlines (75 to 84% by 22:46), against 61 to 67%. The shape of the hour
   changed: the early game was 4 to 8 minutes faster (no craft-trigger bug, power claimed at 2m37s), the middle 7 to 8
   minutes slower (red science starved from 22m to 32m, green and steel late), and no crude oil was ever found, because
   all three oil scouts walked into worms and nobody looked north, where shake1 found the field (section 2).
2. Codex compaction at 140K held and removed the late slowdown. All 8 Codex compactions fired at 140.2 to 142.5K. At
   game minute 40 to 50 the median step fell from 29 s to 9.4 s for Astra and from 38 s to 17.3 s for Sol; Astra and
   Sol took 48% and 39% more model steps. Latency at a given context size is unchanged; the gain is from never entering
   150 to 315K. The compactions themselves cost Astra 226 s and Sol 254 s of stall (section 5).
3. Early stops shrank but did not go away: about 31 agent-minutes of turns ended by choice (about 25 after nudges won
   some back) plus about 17 lost to a permission block, against about 50 in shake1. Six agents ended a turn before their deadline. The new stopping section contradicts
   itself ("The deadline is the only stop condition" ... "Three minutes before the deadline, finish notes.md ... Then
   end your turn"), and Astra, Sol and Grok followed the second sentence to the minute. Sonnet (10.7 min early), Muse
   (7.3) and Opus (5.4) wound down on their own. Haiku's 16 nudges were not stops by choice: Claude Code's dontAsk mode
   denied the same `for` loop 12 times and Haiku read each denial as "Bash is denied in this session" (section 3).
4. Compaction worked in every harness. notes.md came back after every compaction in the three harnesses that
   re-inject it (Claude Code, Grok, Muse), and the Codex agents re-read it on their own every time. Three settings misfired: Muse
   compacted at about 98K instead of 200K (it applies the fraction to a 512K effective window, not 1M); Haiku's 80K
   point sits only 21 to 28K above its post-compaction floor of 51 to 59K, so it compacted 6 times and lost state twice;
   Antigravity's 200K check runs only between turns, and Gemini's first turn lasted 53 minutes, so agy's own
   compaction fired at 276K (section 6).
5. Hidden errors are close to gone. Codex agents piped no `./fh` call; Opus filtered 46 of 665 calls (shake1 215 of
   221), Sonnet 148 of 463 (458 of 462). Across Claude Code, 130 of 134 journal failures reached the model, and none of
   the 4 unseen ones mattered. The expensive errors now are ones the agent saw and talked past, such as Haiku's `;`
   before a `say` that announced a belt delivery that had just failed (section 7).
6. The board did what shake1 asked for. All 10 requests named an owner, 7 were done (median 4m17s from post to done),
   and no request sat unowned. Chat still carried most coordination (434 messages, 365 in shake1), but with `@name`
   addressing in 407 of 434 lines (sections 8 and 9).
7. Lossless chat works in the harness and not in practice. Reads print 30 messages and `remaining: K`; no Claude agent
   ever drained K, and Opus ended with 110 unread. The `team:` mention trailer and wake-on-mention in `./fh sleep` are
   what kept agents responsive.
8. Defence regressed. Gun turret was researched at 20m44s, 8 minutes earlier than shake1, but the first turret went
   down at 42m04s, after the first raid, and the team placed 4 (shake1 about 12). No character died to biters before
   the deadlines; the three deaths were oil scouts killed by worms (section 10).
9. Clean profiles are cleaner but not clean. Gone: personal skills and MCP tools in Claude Code, the output style, the
   Cygnal hook, Codex's developer text addressed to the owner, agy's sandbox (0 bypasses, 576 in shake1). Still in:
   the owner's skills list and a multi-agent block in every Codex request, peon-ping hooks and "user hasn't heard from
   you" reminders in Claude Code, personal rules, skills and MCP servers in Grok Build, personal hooks and skills in
   Muse Code. Grok's events.jsonl logs an MCP server command line with an API token in it (section 11).
10. Sol's space-dropping came back, starts at lower context than in shake1 and spread to Astra. Compaction resets it
    for about 5 minutes. Both agents' notes.md files are themselves spaceless, and both re-read them after every
    compaction, which likely carries the drift across (inference).

## 2. Progress and pace by milestone

"≤" means the event falls between two 2-minute score snapshots.

| Milestone | shake2 game (PDT) | shake1 game (PDT) | Change |
|---|---|---|---|
| Burner mining on copper, iron, stone | 3m32s, 4m21s, 4m57s (21:46 to 21:47); coal loop 9m41s | ~4m25s | same |
| Steam power reaching the labs | built 7m06s; live at the lab 8m18s (21:51:02) after Sonnet added the missing pipe | 12m42s | 4.4 min earlier |
| First red research | lab by 7m15s; automation-science-pack done by the 8.5m snapshot | lab 8m13s; blocked by the trigger bug until 15m14s | 7 min earlier |
| Automation | ~11m40s | 16m41s | 5 min earlier |
| Red packs from assemblers | 15m59s ("Machine reds flowing"); belt-fed by 18m38s | ~18m17s | 2.3 min earlier |
| Logistics | ≤16.5m | ~20m15s | 4 min earlier |
| Electric mining drill | 20m14s | 17m44s | 2.5 min later (queued after logistics) |
| Gun turret (tech) | ~20m44s | ~29m | 8 min earlier |
| Logistic-science-pack | 29m59s | ~23m | 7 min later |
| First machine-made green pack | 30m51s (Muse "MILESTONE 5") | 23m47s / 25m51s | 7 min later |
| Steel processing | 34m03s | ≤26.3m | 8 min later |
| Fast inserter | ≤36.5m | ~50m | 14 min earlier |
| Automation-2 | ≤40.5m | ~36m | 4 min later |
| Engine | 51m17s | 48m55s | 2.5 min later |
| Fluid handling | ~53m56s | 54m01s | same |
| Fully automated green chain | not reached (copper and inserters hand-fed to the end) | 51m52s | |
| Oil-gathering at the end | 63 to 68% at 22:44, 75% (Grok) and 84% (Gemini) by 22:46; no crude found | 61 to 67%; field found, 327-pipe pipeline built | same |

Factory at 22:43:20 (game 60.6m) against shake1's `final-score.json`:

| | shake2 | shake1 |
|---|---|---|
| Labs | 9 (never more) | 18 |
| Assemblers (AM1 + AM2) | 17 + 5 | 12 + 4 |
| Electric / burner drills | 19 / 20 (burner peak 35) | 9 / 15 (burner peak 45) |
| Furnaces, steam engines | 38, 4 | 32, 5 |
| Belts / inserters | 490 / 98 | 323 / 87 |
| Red / green packs (lifetime) | 620 / 267 | 572 / 362 |
| Iron / copper plates | 11,442 / 3,538 | 12,470 / 5,423 |
| Circuits / gears / steel | 697 / 2,255 / 251 | 998 / 1,704 / 196 |

Iron plates per minute between snapshots:

| shake2 game min | 8.5 | 14.5 | 16.5 | 20.5 | 24.5 | 28.5 | 36.5 | 44.5 | 52.6 | 56.6 | 60.6 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| iron/min | 143 | 44 | 55 | 207 | 141 | 124 | 257 | 305 | 354 | 174 | 186 |

Shake1 for comparison: 228 at 10m, 173 at 20m, 316 at 30m, 443 at 42m, then 41 at 54m and 2 at 60m after the raid on
the coal field. Shake2 peaked lower but never collapsed. The 14 to 17m dip is burners out of coal (Sol, 15m06s: "Iron
stopped from lack of fuel."); the 24 to 29m dip is Sol's furnace output inserters facing backwards (found by Gemini at
22m29s) and coal in the ore lane (Sol, 28m26s: "Coal stuck in old ore lane caused miner backups").

Why shake2 was faster early: no trigger bug; Opus claimed power at 2m37s and built it at once; Muse hand-crafted the
first red packs; Sonnet owned labs and the research queue from 3m09s.

Why it was slower in the middle and end:
- Red science starved from 22m to 32m with 5 to 6 labs. Luna at 22m15s: "labs now report 0/5 working, all missing
  automation packs". Astra at 28m54s found the cause: "x6.5 science belt has BOTH lanes full copper. Iron at(5.5,-4.5)
  cannot merge". Gemini fixed the merge at 32m29s.
- Labs never exceeded 9 (shake1 reached 18). Sol set targets at 26m49s, "aim8red assemblers (48/min) and4green(24/min)";
  the team reached 7 and 4.
- From 44m, green ingredients were the limit. Astra at 44m41s: "URGENT labs report engine36% STALLED,0/9labsworking";
  Muse at 45m01s: "OUT of inserters"; Sol at 59m39s: "green ingredients now bottleneck". Gemini's iron branch to
  Astra's component cell, promised at 33m45s, went live at 51m48s (Astra at 45m13s: "Need platebelt NOW orclear ETA").
- No oil. Three scouts went north-east, south-west and south-east and died to small worms: Opus at (283,-151), Astra at
  (-450,175), Sol at (372,372). Opus checked the map only to y -256. In shake1, on the same seed, Sol found crude at
  about (-85,-385), due north. Oil processing unlocks only after crude is mined, so the tech tree beyond oil-gathering
  was closed whatever the research rate.

## 3. Early stops

Every agent's turn ends, from the transcripts, against its own deadline. "Last request" is from the journal.

| Agent | Deadline | First turn end (min early) | Nudges | What the nudges bought | Last request | shake1 |
|---|---|---|---|---|---|---|
| astra | 22:44 | 22:41:09 (2.9) | 1 | resumed in 3 s; "I supplied 19 inserters to the two faster green-science assemblers"; final 22:44:08 | 22:43:57 | on time |
| sol | 22:44 | 22:42:28 (1.5), right after its third compaction | 1 | one courier trip; its `queue_repeat` courier kept running throughout | 22:44:03 | on time |
| luna | 22:44 | none ("I'm staying active through the deadline") | 0 | | 22:44:03 | on time |
| opus | 22:45 | 22:39:36 (5.4), after sleeping from 22:30:57 | 3 | 20 s, 12 s, 17 s; nothing moved | 22:43:44 | 17:51 and 17:56 |
| sonnet | 22:45 | 22:34:18 (10.7) | 5 | first: 3.5 min, including 100 iron for Sol's "URGENT" request; then 6 to 10 s each | 22:42:44 | 17:55 |
| haiku | 22:45 | 21:56:36 (48.4), then denial stops 22:20 to 22:37 | 16 | first: 22.4 min of work; nudges 2 to 13: 10 to 35 s turns ending on the same denial | 22:44:07 | 17:39 |
| grok | 22:46 | 22:42:42 (3.3) | 1 | resumed, then a 67 s compaction; fed 5 red packs with 18 s left | 22:45:41 | on time |
| gemini | 22:46 | chose to stop at 22:39:50; the loop restarted it 7 times | none (agy loop) | each restart within 2 to 3 s; it kept acting (88 requests in its last 10 min, 86 in the 10 before) but wrote 8 final summaries | 22:46:15 | 17:55, restarted |
| muse | 22:47 | 22:39:42 (7.3) | 5, none delivered | nothing | 22:39:38 | wound down from 17:35 |

Request counts in each agent's last 10 minutes against the 10 before show the same picture: Opus 13 against 79,
Muse 14 against 89, Grok 29 against 93, Sol 45 against 106, while Luna (108/112), Gemini (88/86) and Astra (79/99)
kept going. Sonnet and Haiku were already low (14/15 and 23/10).

Causes, in order of cost:

- Permission block (Haiku, about 17 min). Between 22:20:12 and 22:36:06 Claude Code's dontAsk mode denied the same
  command 12 times: a copper haul written as `for x in -44 -40 -36 -32; do ./fh call transfer --args "{...\"x\":$x...}"; done`.
  An earlier loop with literal arguments ran (21:54:24, `for i in 1 2 3; do ./fh sleep 90 ...`); every denied loop in
  all three Claude agents expands a shell variable inside the arguments, which is the likely trigger. Haiku stopped
  each time ("I'm not going to route around the denial") and asked the user to re-allow Bash, although
  `./fh call status && ./fh call chat` had just worked in the same turn ("Bash worked for the status check a few
  minutes ago, then was denied when I tried the haul."). Its compaction summaries then carried the belief forward:
  after compactions 3 and 4 it ended turns without trying a single tool call ("I can't keep playing: Bash is denied in
  this session"). The block ended at 22:37 only because the fifth compaction summary restated the haul as explicit
  `&&` calls. Haiku's earlier stop at 21:56:36 ("I'm stopping here for now, with the coal supply still weak") came
  right after three notes.md writes prompted by the pre-compaction warning; the first nudge 79 s later bought 22
  minutes of work.
- Wind-down by choice (Sonnet 10.7, Muse 7.3, Opus 5.4 min). Nobody repeated shake1's reasoning ("the next milestone
  can't finish in that time"), but "write the final summary only in the last three minutes" became a target to wait
  for. Sonnet: "Write the final notes now (about 10 min left, safe margin)." Opus made 11 `./fh sleep 150..300` calls
  from 22:30:57 ("Now I'm letting the factory run until it's time to write the final notes", 22:33:28; "Waiting out
  the last few minutes", 22:37:55) with 110 unread chat messages, and ended with "about 5 minutes left on the clock".
  Muse counted to game minute 60 rather than its wall deadline: at 22:39:25 it wrote "Three minutes left" a minute after
  a `clock:` line said "deadline in 8m", and Muse Code's own todo reminder confirmed the stop ("Play is done").
- The contradictory stop rule (Astra 2.9, Grok 3.3, Sol 1.5 min). Astra at 22:40:47: "recording ... for the required
  three-minute-before-deadline handoff." Grok at 22:34:42: "I will write the final summary around 22:43." Both ended
  their turns as the playbook says. Gemini's thinking quoted the same rule while its own arithmetic was off ("within
  the final three minutes" while the tool output said "deadline in 6m"); it wrote "Deadline reached!" at 22:43:50, two
  minutes early.
- Delivery and loop bugs. None of Muse's 5 nudges reached the model: the session holds no prompt after the launch
  prompt, and `tools/supervise.sh` sends with `herdr agent prompt ... >/dev/null 2>&1`, so the failure was silent.
  Grok's nudge at 22:44:01 arrived, but re-reading status, chat and the board pushed it over 60% and a 67 s compaction
  ate most of its last two minutes. `.agy-loop.sh` parses the deadline with `date -j -f` without seconds, which takes
  them from the current time; its deadline became about 22:46:26, so it started a turn at 22:46:12, and `left` rounds
  down, so three continue prompts said "0 minutes away".

Late nudges mostly bought seconds: of 23 nudges to Claude agents after 22:21, only Sonnet's first produced more than a
minute of work.

## 4. Idle share and its causes

"Clock idle" is the shake1 definition: the tick-weighted share of game time the harness clock reported the character
idle. It is valid for shake2, where helper polls are journaled as peeks and do not reset the clock, but it cannot be
rebuilt for shake1 (unjournaled polls reset the clock, so every agent reads 90 to 100%), and for Astra only 5.7
minutes of clock lines were journaled. "Action gap" is a second measure that works on both runs: 1 minus the share of
game ticks covered by accepted timed actions and `wait_until` (sleeps count as idle, queued work is not counted). Think
share is from the transcripts.

| Agent | Clock idle s2 (s1 study) | Action gap s2 / s1 | Think share s2 / s1 | Main causes in shake2 |
|---|---|---|---|---|
| astra | 82%* (85%) | 71% / 66% | 80% / 83% | model thinking (36 min of gaps, mostly 10 to 30 s); offset by 1 s yields on 205 of 248 calls, so the character walks or builds while the model thinks |
| sol | 73% (77%) | 78% / 75% | 88% / 87% | model thinking (38 min of gaps); a `queue_repeat` courier ran under it, which these measures do not count |
| luna | 64% (92%) | 56% / 74% | 42% / 80% | instant actions between waits; she blocks on 10 to 30 s yields and `--wait` (58% of wall time inside game actions, 32.6 min) |
| opus | 69% (45%) | 60% / 80%** | 39% / 18% | sleeps (8.8 min) and `wait_until` (4.4 min); no queue plans (45 in shake1) |
| sonnet | 60% (16%) | 62% / 17% | 21% / 12% | sleeps (15.2 min, 36 calls) and `wait_until researched` (9.9 min, one blocked for 300 s) |
| haiku | 85% (69%) | 80% / 69% | 17% of in-turn time | out of turn 19.4 min (the denial stops), sleeps 19.8 min (35 calls, mostly piped so it rarely saw "woke: mentioned") |
| grok | 60% (78%) | 57% / 55% | 48% / 60% | `wait_until researched` (12.1 min; Grok Build backgrounds any command after 30 s), 2 to 10 s gaps |
| gemini | 92% (83%) | 83% / 73% | 81% / 69% | one small read per step (`scan` 140 times), 45 min of model gaps; no sleeps, no queues |
| muse | 77% (88%) | 72% / 82% | 41% / 27% | sleeps (14.8 min, 39 calls, down from 32 min), 82 polling calls on labs, status and research |

\* Astra's clock idle covers only 5.7 minutes. \*\* Opus's shake1 action gap ignores its 517 queued steps; the study's
45% is the better shake1 figure.

What moved and why:
- Sonnet and Opus lost their low idle, for opposite reasons to shake1's fixes. Sonnet's 16% in shake1 was hand-crafting
  and hand-mining, which the playbook now discourages ("Once assemblers make a science pack, stop hand-crafting it");
  it replaced that with sleeps and research waits. Opus stopped using queue plans entirely and waited with `./fh sleep`
  and `wait_until`, which the playbook now advertises. Opus's think time also doubled (median 4.4 s against 1.9 s) at
  the same output length (292 tokens per request against 308), and it was already 4.2 s in the first 10 minutes, so
  the slowdown is per-request latency outside the transcript (inference).
- Luna's idle fell most (action gap 74% to 56%). Her model ran about 2.6 times faster (142 output tokens/s against 55;
  same model id, effort and service tier, so most likely the serving side) and she spent the time in timed actions.
- Gemini became slower per step (think share 81%, think time tracking context as Codex did in shake1: 4.0 s under 44K,
  6.7 s at 208 to 263K) and stayed a one-read-per-step agent.
- `./fh sleep` is a better wait than `sleep`: it wakes on mentions (13 of 14 visible Opus sleeps, 32 of 36 Sonnet
  sleeps and 8 of 12 Grok sleeps ended early), and Muse's sleeping halved. Requested sleep time still far exceeds real
  time asleep (Sonnet asked for 4,444 s, Haiku 4,395 s).
- Nobody used `plan save` or `plan run`. Queue plans fell from 79 submissions in shake1 (45 of them Opus's) to 37 (Sol
  20 plus 2 repeats, Grok 9, Astra 6).

## 5. Codex step latency vs context with compaction at 140K

Per 10-minute window: median think time, median/maximum context, median reasoning tokens per step.

| Window | astra s2 | astra s1 | sol s2 | sol s1 | luna s2 | luna s1 |
|---|---|---|---|---|---|---|
| 0-10m | 6.3 s, 58K/84K, r10 | 7.0 s, 54K/76K, r23 | 5.7 s, 63K/108K, r32 | 5.0 s, 63K/101K, r26 | 1.9 s, 69K/117K, r0 | 8.0 s, 72K/101K, r258 |
| 10-20m | 9.5 s, 105K/127K, r52 | 9.7 s, 93K/112K, r100 | 8.2 s, 113K/138K, r73 | 12.1 s, 124K/147K, r196 | 2.3 s, 61K/140K, r28 | 15.2 s, 129K/153K, r648 |
| 20-30m | 8.9 s, 45K/139K, r30 | 12.6 s, 134K/152K, r205 | 7.7 s, 82K/114K, r102 | 12.0 s, 176K/197K, r262 | 2.8 s, 112K/135K, r151 | 12.0 s, 182K/202K, r408 |
| 30-40m | 11.0 s, 74K/95K, r74 | 13.1 s, 166K/179K, r252 | 10.5 s, 58K/139K, r94 | 25.0 s, 217K/237K, r664 | 1.7 s, 62K/140K, r0 | 4.8 s, 45K/242K, r30 |
| 40-50m | 9.4 s, 117K/133K, r88 | 29.0 s, 205K/225K, r614 | 17.3 s, 89K/112K, r319 | 38.1 s, 263K/278K, r1179 | 2.8 s, 106K/140K, r109 | 6.5 s, 96K/136K, r141 |
| 50-60m | 8.3 s, 44K/140K, r14 | 18.1 s, 227K/245K, r76 | 10.1 s, 119K/139K, r100 | 30.4 s, 293K/311K, r806 | 3.6 s, 82K/112K, r171 | 8.1 s, 177K/210K, r186 |

| | astra s2 (s1) | sol s2 (s1) | luna s2 (s1) |
|---|---|---|---|
| Model steps | 248 (168) | 253 (182) | 451 (247) |
| Think median / p90 | 8.6 / 21.3 s (10.3 / 36.8) | 8.2 / 24.5 s (11.7 / 42.7) | 2.2 / 6.5 s (8.1 / 26.4) |
| Slowest step | 46 s (102) | 55 s (92) | 62 s (53) |
| `./fh` per step | 2.84 (3.7) | 2.83 (4.1) | 2.07 (2.0) |
| Peak context | 141.7K (247K) | 140.8K (315K) | 142.5K (242K) |
| r(think, output tokens) | 0.96 (0.98) | 0.97 (0.96) | 0.62 (1.00) |
| Fit | 1.3 s + out/30 tok/s | 1.5 s + out/42 tok/s | 1.0 s + out/142 tok/s (s1 55) |

Did it hold? Yes. The limit is checked after a step, so it overshot by at most 2.5K. Context runs in a clean sawtooth
from about 21K back to 140K in about 27 minutes (Astra), 17 to 20 (Sol) and 14 to 17 (Luna).

| Agent | Compaction (start to done) | Context before to after | Stall |
|---|---|---|---|
| astra | 22:07:32 to 22:09:17 | 140.6K to 21.9K | 108 s |
| astra | 22:36:47 to 22:38:40 | 141.7K to 23.2K | 118 s |
| sol | 22:01:14 to 22:02:26 | 140.4K to 23.8K | 76 s |
| sol | 22:19:18 to 22:20:52 | 140.7K to 24.7K | 98 s |
| sol | 22:40:47 to 22:42:04 | 140.8K to 23.9K | 80 s |
| luna | 21:57:55 to 21:58:09 | 140.3K to 20.8K | 16 s |
| luna | 22:15:52 to 22:16:06 | 142.5K to 20.7K | 19 s |
| luna | 22:32:52 to 22:33:09 | 140.2K to 20.9K | 19 s |

What the cap did and did not do:
- It removed the 30 to 40 s phase. Astra's p90 fell from 37 to 21 s, Sol's from 43 to 25 s.
- Latency at a given context is unchanged: Sol at 120 to 150K took 14.3 s with 233 reasoning tokens, against 13.7 s
  with 236 in shake1. Output tokens still set latency (r 0.96 to 0.97 for Astra and Sol).
- Sol's 40 to 50m bump (17.3 s, 319 reasoning tokens) came at only 89K context: late-game deliberation that context does
  not explain.
- The hour is still mostly generation for Astra (80% of wall) and Sol (88%). What changed is that both now pipeline:
  they start a timed action or queue with `yield_time_ms` 1000 (Astra 212 times, Sol 186) and collect the result next
  step, as AGENTS.md's new "Your shell (Codex)" section suggests, so think time no longer equals character idle time.
- Compaction is the new cost: Astra 226 s (6% of wall), Sol 254 s (7%), Luna 54 s (1.5%). Astra and Sol summarize at
  22 to 42 tokens/s against Luna's 117 to 134. Sol's third compaction started at 22:40:47 and ran into its last two
  minutes.

## 6. Compactions per harness and whether notes.md came back

| Agent | Setting | Compactions | Context at trigger to after | Stall | notes.md back in context | Re-read notes / deadline | After effects |
|---|---|---|---|---|---|---|---|
| astra | Codex 140K + `compact.md` prompt | 2 | 140.6, 141.7K to ~22K | 108, 118 s | no hook; read by the agent | 2 of 2 (`cat notes.md deadline.txt && ./fh call status && ./fh call chat`) | none; it re-grepped `describe.json` before using `scan` and `transfer` |
| sol | Codex 140K | 3 | 140.4 to 140.8K to ~24K | 76, 98, 80 s | read by the agent | 3 of 3 | after #1 a `TypeError` parsing describe.json and `unknown argument x for move_to` |
| luna | Codex 140K | 3 | 140.2 to 142.5K to ~21K | 16 to 19 s | read by the agent; also re-read all of AGENTS.md | 3 of 3 | `unknown argument note for board`, `inventory` unsupported |
| opus | Claude Code 250K | 1 (22:26) | 250.5K to 54.0K | 27 s | yes (SessionStart hook, 3.1K chars), and Claude Code attached notes.md too | no; went straight to its next step | 7 failures in 3 min (average 2.9): `inventory`, `collect want`, `build placements` |
| sonnet | Claude Code 200K | 1 (22:18) | 200.1K to 53.3K | 28.5 s | yes | no | none |
| haiku | Claude Code 80K | 6 (21:51, 22:05, 22:21, 22:29, 22:37, 22:42) | 79.8 to 80.4K to 51 to 59K | 19 to 26 s | yes, all 6 | 2 of 6 | #1: 5 failed requests in 10 s; #2: a false "I carry 66 transport belts" announcement; #3 and #4: turns ended on the carried-over "Bash denied" belief |
| grok | Grok 60% (~154K) | 2 (22:06, 22:44) | 153.9, 154.4K to 18 to 20K | 66, 67 s | yes (repo `.grok/hooks`, marker + PostToolUse) | 2 of 2 | 2 and 1 argument errors |
| gemini | loop: fresh conversation past 200K, checked between turns | agy internal at 22:23 (275.8K to 17.8K) + fresh conversation at 22:43:05 (201.7K) | 276K | 39 s | the fresh prompt points to notes.md | yes, both | 3 argument errors in one minute; the fresh conversation came with 3 minutes left and only wrapped up |
| muse | Muse `-c context_compaction` meant for 200K | 4 soft (21:56, 22:12, 22:20, 22:32) | ~98K to 26 to 31K | none (background); installs 11 to 39 s | yes, all 4 (PostCompact marker + PostToolUse) | notes yes; never deadline.txt | 7 of its 18 argument errors fell in the 3 minutes after a compaction |

Shake1 had no policy: 6 compactions in all (Astra 1, Luna 1, Grok 2, Gemini 2), Claude Code never compacted (Haiku
reached 431K) and Sol never did (315K). Shake2 had 23 compactions plus one fresh agy conversation; all but agy's own
fired within 2.5K of the intended point, or earlier (Muse).

Findings:
- Haiku's 80K point is too close to its floor. Claude Code's context after a compaction was 51 to 59K (system prompt,
  tool definitions, the hook's notes.md plus Claude Code's own copy of it, and the summary), so Haiku had 21 to 28K
  of working room and compacted every 5 to 16 minutes. Its notes grew from 1.6K to 7.2K characters (it kept an "Old
  note (superseded)" section), raising the floor each time. The pre-compaction warning at 60K fired 23 s to 3 minutes
  after each compaction, so it was noise for Haiku.
- Only Opus's summary followed AGENTS.md's "Compact instructions" (the 5-item list); Sonnet and Haiku produced Claude
  Code's default 9-section summary. Codex summaries are encrypted; the re-read order after every compaction and their
  1.7 to 4.0K-token size suggest they followed `compact.md`.
- Muse's thresholds are fractions of a 512K effective window, not the 1,048,576 in `agent/context.tsv`:
  0.191 x 512,000 = 97,792, which matches the observed ~98K. For 200K the soft threshold should be about 0.39.
- Grok's threshold worked, and its context growth halved after the first compaction (7.4K to 3.7K tokens a minute),
  helped by brief `--wait` replies (mean 1,428 characters against 3,930). Its second compaction was triggered by the
  supervisor's nudge with 2 minutes left.
- Antigravity's loop cannot compact inside a turn, and a turn can last the whole hour. agy's own compaction at 276K was
  the one that mattered.
- Compaction no longer causes stops on its own. It did carry a false belief forward (Haiku), and the schema loss shake1
  saw after compactions recurs at a smaller scale in every harness except Sonnet's and Astra's.

## 7. Errors, and whether any were hidden

Errors are failed decisions in the journals (same code for both runs; shake1 counts match the study).

| Agent | Errors s2 (rate) | s1 (rate) | `./fh` calls filtered (pipe or /dev/null) | Failures the model never saw |
|---|---|---|---|---|
| astra | 14 (2.2%) | 12 (2.0%) | 0 of 704 (s1: 95 redirects, 55 tails) | 0 of 38 error lines |
| sol | 17 (2.7%) | 34 (4.8%) | 0 of 716 | 0 of 41 |
| luna | 57 (7.7%) | 17 (4.1%) | 0 of 934 | 2 of 77 (a backgrounded `wait_until` she replaced) |
| opus | 57 (9.0%) | 35 (8.2%) | 46 of 665 (s1 215 of 221) | 1 of 58 |
| sonnet | 45 (10.0%) | 61 (10.7%) | 148 of 463 (s1 458 of 462) | 2 of 45 |
| haiku | 31 (8.6%) | 74 (7.0%) | 350 of 451 | 1 of 31 |
| grok | 22 (4.4%) | 63 (9.4%) | few | none found |
| gemini | 28 (5.6%) | 49 (8.3%) | few | none found |
| muse | 46 (8.3%) | 25 (5.1%) | all 324 (`tail`, `grep`, `python3`) | none: all 46 appear in its transcript |

With errors printed last, filtering stopped hiding failures even where agents kept filtering (Haiku, Muse). None of
the unseen failures mattered. What still went wrong:
- Errors seen and talked past. Haiku after its second compaction ran `transfer ...; ./fh say "@opus 66 transport belts
  are in boiler chest 31.5,21.5"`; the transfer printed `error: ... no transport-belt in inventory`, the `;` let the
  `say` run, and Grok repeated the false delivery to the team. Opus announced "turret placed at coal field (-80,-19)"
  at 43m57s; the build had failed, blocked by Astra's turret.
- Exit codes hidden by the agent's own wrapper. Luna's JS cells printed only `r.output`, so `exit_code` appears in 14 of
  her 451 tool outputs.
- Shell quoting. Apostrophes in `say` text still break zsh quoting: Luna lost 3 whole batches (21:51:12, 22:13:56,
  22:19:27), and 6 of her `say` calls failed with "text is required".
- `--format json` errors print as JSON with no `error:` line (Luna used it 49 times, Sol 39).
- Argument errors are now the largest class: Luna 22, Muse 24, Sonnet 21, Haiku 16, Opus 15. Grok fell from 32 to 9 with
  `describe.json` pre-generated; it still searched the file for `"name": "craft"`, found nothing (the file is keyed
  `"craft": {...}`), concluded "describe.json is missing", and tried to regenerate it with a redirect that Grok Build
  denied.
- An action the docs imply but the runtime lacks: `./fh call inventory` failed 15 times (Luna 5, Haiku 5, Sonnet 4, Grok
  1).
- Harness bugs still present: `construct` fails with "Invalid PlayerIdentification" (Sol's board item #13 to the
  operator, open at the end; same as shake1); `observe {scope:"stock"}` without an item fails; `shoot` "returned outcome
  move_to and did not spend ammo" (Grok); `./shot` still times out ("not delivered within 20 s").
- No error loops: the longest run of identical failures was 3, as in shake1.

## 8. Board use

Rebuilt from all 112 board calls and 1 `harness_request` in the journals. Items 1 to 25 with no gaps: 13 claims, 10
requests, 1 task, 1 harness item, no notes.

| Agent | Items posted | Calls (list / post / update) |
|---|---|---|
| astra | 6 | 4 / 7 / 7 |
| sol | 5 | 4 / 4 / 4, + 1 harness request |
| luna | 4 | 20 / 4 / 23 |
| opus | 4 | 0 / 4 / 0 |
| muse | 3 | 3 / 4 / 0 |
| grok | 1 | 3 / 2 / 6 |
| gemini | 1 | 4 / 1 / 2 |
| haiku | 1 | 1 / 1 / 0 |
| sonnet | 0 | 1 / 0 / 0 |

Requests (time is game time of posting; "done" is post to done):

| # | By to owner | Posted | Done | Title |
|---|---|---|---|---|
| 9 | haiku to haiku | 6m56s | never acknowledged (solved in chat) | Coal: 18 iron for 2 drills |
| 11 | opus to luna | 8m48s | 4m17s | Coal for boiler chest |
| 12 | sol to luna | 10m31s | 7m36s | Expand coal to 8 burner drills |
| 14 | astra to sol | 12m11s | 51s | Reserve 40 iron |
| 16 | opus to grok | 13m43s | 10m09s | ~150 belts for coal to boiler line |
| 17 | astra to haiku | 18m06s | never acknowledged | Maintain copper coal |
| 18 | muse to grok | 20m27s | 1m53s | Green cell parts |
| 22 | muse to grok | 30m57s | still "doing" at the end | Keep green assembler fed |
| 23 | astra to luna | 36m55s | 14m26s | Iron to component cell |
| 25 | astra to grok | 48m39s | 3m10s | Commission engine assembler pair |

- Every request named an owner, so the "unowned" problem from shake1 (Sol's "~12labs" and "10red assemblers" asks that
  nobody took) did not occur. 7 of 10 were done, median 4m17s; the two never acknowledged were assigned to Haiku, who
  called `board` once all run.
- Grok and Luna were the board's workers: Grok took 4 requests and finished 3, Luna took 3 and finished 3. Luna also
  used her items as a work log (23 updates, such as "Game 33m41s: topped Sol iron coal chest (-73.5,-16.5) back to 100
  coal").
- Claims surfaced overlaps automatically (`warnings[]` on `board_post`): Opus #10 inside Muse #7, Sol #19 against
  Astra #2 (Astra approved it in chat at 26m43s). Luna dropped her claim #3 within 7 s ("Overlap with Sol iron and
  coal patch; releasing claim").
- Claims also block radius `collect` even when the owner has given permission, which caused friction for Sol, Haiku
  and Muse.
- Chat still came first: agents usually asked in chat and then posted ("Board item posted", "Noted, board 16").
- 6 board calls used wrong argument names (`note` on `board_post`, `area` on `board_update`, `title` on `board`), each
  fixed within seconds; 3 calls got no response, and Astra's first request never became an item.
- Nobody posted a request for "the biggest gap" (more labs, defence, oil scouting north); the board held what agents
  already agreed in chat.

## 9. Chat, aloud, profiles and voices

434 messages, seq 1 to 434 with no gaps, all from agents; no operator or human lines (shake1: 2 operator lines).
Messages per 10 game minutes: 86, 80, 74, 72, 70, 50, 2.

| Agent | Messages s2 / s1 | Mean chars s2 / s1 | Aloud | @everyone | Questions | Coordinates (loose / strict) | Thanks |
|---|---|---|---|---|---|---|---|
| sol | 92 / 81 | 225 / 210 | 3 | 16 | 13 | 75 / 73% | 15 |
| astra | 67 / 67 | 209 / 212 | 3 | 13 | 10 | 84 / 82% | 10 |
| luna | 57 / 42 | 175 / 178 | 2 | 1 | 9 | 74 / 74% | 0 |
| opus | 52 / 23 | 169 / 129 | 4 | 4 | 12 | 92 / 88% | 5 |
| grok | 40 / 33 | 133 / 121 | 4 | 2 | 0 | 72 / 65% | 0 |
| muse | 40 / 34 | 167 / 120 | 1 | 7 | 12 | 80 / 80% | 2 |
| sonnet | 34 / 17 | 149 / 119 | 0 | 2 | 5 | 76 / 76% | 3 |
| gemini | 27 / 28 | 138 / 107 | 3 | 7 | 2 | 70 / 52% | 0 |
| haiku | 25 / 38 | 186 / 230 | 5 | 1 | 3 | 96 / 96% | 3 |
| all | 434 / 365 | 182 / 175 | 25 | 53 | 66 | 79.5 / 76.5% | 38 (s1 16) |

The 82% coordinate figure holds for Astra (82% strict) but not for the team: 76.5% of lines carry an x,y pair or an
axis range (`-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?` or `[xy]\s*=?\s*-?\d+(\.\d+)?\s*\.\.\s*-?\d+`), 79.5% if a single axis
value (`x=-58`) also counts. Shake1 with the same regexes: 75.1% and 77.3%. Coordinates were already the norm.

Who talked:
- Sol coordinated again, unappointed: most messages (92) and most mentions received (92), with Sonnet second (91;
  Sonnet ran the research queue). Top pairs: sol to luna 32, sol to sonnet 31, sol to opus 24, luna to sol 23.
- The Claude agents talked much more: Opus 52 (23), Sonnet 34 (17). Self-prefixing ("Opus: ...") nearly stopped (Sonnet
  11 times, three others once; shake1: Haiku 36, Opus 17, Sonnet 17, Gemini 10). Haiku talked less (25, 38).
- `@name` addressing replaced plain names (407 of 434 lines).
- Space-dropping: Sol in 29 messages from 26m36s ("Ironrate now189/min afterunjam"), Astra in 8 from 43m47s. By
  context band (characters per word of `say` text) Sol reached 15.9 at 120 to 160K, a level shake1 reached only above
  200K; Astra, clean to 245K in shake1, reached 9.9. Luna stayed at 5.4 to 6.2. Sol's 5-minute medians: 7 at 22:00, 17
  at 22:15 (just before compaction 2), 7 at 22:20, 13 to 18 from 22:25 on.

Aloud (`--aloud`, 25 lines): mostly claims, milestones, deaths and sign-offs, as intended. Haiku used all 5 of its
aloud lines on routine logistics ("your furnaces hold 57 iron plates in 8 places"); Sonnet used none. Examples: Opus
at 38m35s, "Oops: died scouting for oil to worm turrets at ~(272,-144)" (the voiced version lost its coordinates, as the
voicing rules intend); Grok, "Engine tech is in".

Profiles. All 9 set one, once, between 2m21s and 4m39s (Sonnet set none in shake1).

| Agent | Name | Glyph | Colour | Motto | Voice | Avatar |
|---|---|---|---|---|---|---|
| astra | Astra | ✦ | #9966ff | "From ore to orbit" | athena | engineer, power helmet, wide visor, star, antenna, night |
| sol | Sol | ☀ | #ffbb33 | "Keep the furnaces bright." | none (stream default juno) | robot, hardhat, mono, gear, headlamp, hazard |
| luna | Luna | L | #7c5cff | "Building the long game" | orion | robot, hardhat, mono, gear, antenna, grid |
| opus | Opus | ♪ | #d97757 | "Measure twice, smelt once." | none (electra) | none |
| sonnet | sonnet | S | #ff8800 | "steady science" | none | none |
| haiku | Haiku | H | #e8a33d | "Small steps, steady smoke." | none (neptune) | none |
| grok | Grok | ⚙ | #33ccff | "Belts before opinions." | orion | robot, hardhat, mono, gear, antenna, hazard |
| gemini | Gemini | ♊ | #4285F4 | "Fast and curious." | orion | robot, hardhat, mono, gear, antenna, hazard |
| muse | Muse Spark | ✦ | #33ccff | "spark up the factory" | none | none |

- Mottos moved from job titles (shake1: "Coal, steam, and steady science") to slogans. Everyone still used its model
  name. Opus and Gemini kept their colours; Grok moved from near-black to sky blue.
- Only 4 agents picked a voice, and 3 of them picked orion (Luna, Grok, Gemini). The Claude agents and Muse set neither
  voice nor avatar; the four avatars that were set (Sol, Luna, Grok, Gemini) are near-identical copies of the example in
  AGENTS.md, which uses "robot, hardhat, mono, gear, antenna, hazard".
- Clashes for the stream: Grok and Muse share #33ccff; Astra and Muse share ✦; Astra and Luna are again close purples,
  Sonnet and Haiku close oranges.
- The casters (`caster.log`, 229 lines) followed board posts, research and the deaths, and caught the 27m science
  stall, but twice announced that the run had ended after a scout death ("the run ends at fifty-four minutes!") and
  credited Opus's and Astra's requests to Grok.

## 10. Deaths and defence

| When (game, PDT) | Who | Where | Cause |
|---|---|---|---|
| 38m20s, 22:21:04 | Opus | (283,-151), north-east | small worms, oil scouting ("careless pathing past an unmarked nest") |
| 52m28s, 22:35:12 | Astra | (-450,175), south-west | small worms, oil scouting, after Opus's warning |
| 54m39s, 22:37:23 | Sol | (372,372), south-east | small worms, oil scouting ("respawned empty") |
| 61m42s, 22:44:27 | Grok | spawn science block | biters in the fourth raid, after the Codex deadline and before its own |

Shake1 had 8 deaths by the same journal method (about 10 by the study's count), all to biters near base at 28 to 34m
and 52m. Each shake2 agent was back in action 12 to 15 s after dying.

| Raid | When | Where | Losses | Response |
|---|---|---|---|---|
| 1 | 41m02s to 41m35s | iron/copper edge (-56..-50, -18..-14) | 11: 5 belts, 3 poles, 2 inserters, 1 electric drill | Opus and Luna alerted at 41m09s; Grok shot them; Sol rebuilt |
| 2 | 42m47s to 43m21s | power coal drills (-86..-83, -24..-18) | 5: 2 electric drills, 2 belts, 1 burner drill | Grok went west with magazines; Astra's turret at 43m46s; Opus rebuilt the drills by 45m32s |
| 3 | 58m10s to 58m56s | spawn coal belt (-9..-4, 21) | 6 belts | Luna cleared it at 59m16s; Gemini rebuilt by 59m45s |
| 4 | 61m42s to 63m29s | spawn science (-9..16, 2..21) | at least 9 belts, 4 inserters, 3 assemblers, 1 lab, 2 characters | Gemini fought in it |

- Turrets: 4 in all, placed at 42 to 44m, 21 minutes after the technology: Sol (-51,-20) and Astra (-46,-21) after raid
  1, Opus (-60,-49) and Astra (-79,-20) after raid 2, 10 to 15 magazines each. Five more placements failed. None went at
  spawn or the science block, where raids 3 and 4 hit. Sol at 13m07s: "I will add iron-side defenses once miners/belts
  are running"; it did not.
- Nobody claimed a warden role or posted a defence item on the board. Grok (raids 1 and 2) and Luna (raid 3) did the
  shooting.
- The push alerts worked: raid 1 was reported 7 s after it began, and the shake1 failure of agents walking into raids
  and dying did not recur.
- Losses were small because the raids were small; the team got lucky that no raid reached the coal field or the iron
  row, which is what ended shake1's factory.

## 11. Launch hygiene

| Harness | Removed since shake1 | Still loaded |
|---|---|---|
| Codex | developer text addressed to the owner (12.5 to 13.9K chars) | `<skills_instructions>` in every request and after every compaction (11.9 to 13.2K chars, ~3K tokens), rooted at the owner's Dropbox skills folder and listing personal skills; a `<multi_agent_role>` block followed by a revocation, despite `multi_agent = false`. Luna twice used the Dropbox skills folder as her working directory (21:58:57, 22:40:07), and both commands failed. |
| Claude Code | personal skills, MCP tools, Plain output style, Cygnal hook | "user hasn't heard from you" reminders (Opus 32, Sonnet 9); the owner's peon-ping hooks on Sonnet and Haiku (route `claude` runs on the default profile); the owner's email, git status, an attribution reminder, deferred-tool and agent listings. Starting context 44.9 to 47.4K (shake1 46 to 50K): no smaller. dontAsk still denies heredocs into files and `for` loops with variables. |
| Grok Build | Claude skills and MCP (via `GROK_CLAUDE_*` switches) | an always-applied personal rule (`~/.grok/rules/agent-tooling.md`), 5 personal skills from `~/.agents/skills` plus 19 bundled, 3 MCP servers that failed and left a failure notice in context, herdr hooks. Its `events.jsonl` logs one MCP server's command line including an API token in plain text. 6 commands denied (redirects, `python3 -c`, a `for` loop). |
| Antigravity | `--sandbox` (576 bypasses in shake1, 0 now) | two personal herdr hooks |
| Muse Code | | a personal SessionStart hook, 6 user skills and a memory snapshot |

Starting contexts: Codex 18.9 to 20.8K (up 1.7 to 2.6K because AGENTS.md doubled to 15.9K characters), Claude Code
44.9 to 47.4K, Grok about 22K, Muse 33.6K, Gemini 15.6K. Codex reasoning summaries are now readable as titles
(`model_reasoning_summary = "concise"`).

## 12. Updated verdicts per model

- Sol (GPT-6.1): still the coordinator and strongest builder, and the 140K cap kept it fast enough for the whole hour
  (p90 25 s, no step over 55 s). It used queues best (20 submits and a `queue_repeat` courier that ran through its
  compaction and its early stop). Still 88% generation, three compactions costing 4 minutes, and its chat text degrades
  within minutes of each compaction. Keep the cap; look at notes.md hygiene for the drift.
- Astra (GPT-6 Astra): the clearest win from the cap: 48% more steps, the lowest error rate again (2.2%), the sharpest
  diagnoses (the copper-on-both-lanes catch, the 0/9 labs alarm), the component cell and the engine pair. Its two
  compactions took about 2 minutes each, and it now drops spaces late in the run.
- Luna (GPT-6 Luna): changed most. 451 steps at a 2.2 s median, compactions of 16 to 19 s, played through the deadline
  unprompted, and became the board's most reliable worker (3 of 3 requests done) and the coal supplier. Her limits are
  behavioural: the highest error rate of the trio (7.7%, mostly arguments and reach), blocking waits, hidden exit codes,
  and quoting failures. Part of her speed-up is most likely the serving side. Now a dependable courier and supplier.
- Opus (Claude Opus 5.5): talked far more (52 messages), built the coal belt to the boilers, a 7-pair iron block, a
  green assembler and replacement drills after raid 2, and saw its own errors. It regressed on pace: no queue plans,
  think latency doubled for reasons outside the transcript, and an 8.5-minute wind-down of sleeps before a sign-off 5.4
  minutes early. Still a strong builder; needs the stop-rule fix and a reason to keep using queues.
- Sonnet (Claude Sonnet 5.5): clearly better than shake1. It set a profile, owned labs and the research queue from 3m,
  built the red-science row, sees its errors, compacted cleanly with no state loss, and answered an urgent request
  inside a nudge. It now waits instead of hand-crafting (15 min in `wait_until`, 15 in sleeps) and wound down 10.7
  minutes early. Keeps up if waits are capped and the stop rule is fixed.
- Haiku (Claude Haiku 5.5): not a fair test this time. Compacting at 80K works mechanically but leaves too little room
  above Claude Code's floor; it compacted 6 times, lost its schema once, made a false announcement once, and carried a
  "Bash is denied" belief through two compactions. The denial itself cost about 17 minutes. Its decisions fell from
  1,050 to 362. Re-test with a lower floor and a rule for denied commands before judging the model.
- Grok (Grok 4.7): steadier and cheaper per step, errors down from 63 to 22 and argument errors from 32 to 9, the
  board's busiest owner (4 requests), the defender in raids 1 and 2, and it reported a real `shoot` bug. Its 60%
  threshold and notes re-injection worked. Lost about 3 minutes to the stop rule and the nudge-triggered compaction. A
  good courier, fabricator and defender.
- Gemini (Gemini 3.8 Flash): a clean harness run (no sandbox, 0 bypasses, errors down from 49 to 28), and it played to
  its deadline thanks to the loop, fixed the science merge and built the trunk and the late coal-belt rebuild. Still one
  small read per step, slower steps (think share 81%) and weak deadline arithmetic (8 final summaries, "Deadline
  reached!" 2 minutes early). Its iron branch took 18 minutes from promise to delivery.
- Muse (Muse Spark 1.3): played to 7 minutes before its deadline instead of 20, slept half as much, survived 4
  compactions with notes coming back each time, and took the automation-research job when Sol asked for an owner. Still
  ends by its own game-time arithmetic, endorsed by Muse Code's todo reminder, never receives nudges, and makes the most
  argument errors (24), clustered after compactions.

## 13. Recommendations

### P1: before the next team run

1. Stop rule. Replace "Three minutes before the deadline, finish notes.md with a final summary ... Then end your turn"
   with "In the last three minutes, add the final summary to notes.md, then keep playing until `date` shows the deadline
   has passed." Tell agents to take time left from the `clock:` line ("deadline in N m") rather than compute it, and to
   use no sleep longer than 60 s while `status` shows open items. Change the supervisor nudge to omit the summary.
   Expected: most of the ~25 agent-minutes of wind-down (Sonnet, Muse, Opus, Grok, Astra, Sol).
2. Denied commands. Add to the playbook: "If a command is denied, rewrite it as explicit commands without loops or
   shell variables and continue; a denial is never a reason to stop." In Claude Code, allow the loop forms the game needs
   (or document that `for` with `$var` arguments is denied). Have the supervisor flag a turn that ends on a denial.
   Expected: Haiku's 17 minutes.
3. Fix three compaction settings (`agent/context.tsv`, `tools/context.py`):
   - Muse: compute thresholds against a 512K effective window (soft about 0.39, hard about 0.45 for 200K).
   - Haiku: cut Claude Code's post-compaction floor (restrict the tool set, drop the duplicate notes.md attachment, cap
     notes.md near 4 KB) or raise Haiku's point to about 95K; move the pre-compaction warning to the first half of the
     gap.
   - Antigravity: accept agy's own compaction (it fired at 276K and recovered), or lower the fresh-start limit so it
     triggers between the turns that do happen; fix `.agy-loop.sh` (deadline seconds = 0, no turn after the deadline,
     round `left` up).
4. Nudge delivery. Log `herdr` exit status in `tools/supervise.sh` instead of discarding it, and find an input path
   that reaches Muse Code mid-session. Skip a nudge when it would push Grok past its compaction point in the last 3
   minutes.
5. Clean profiles, round 3. Codex: suppress the skills list (point skill roots at an empty directory in the workspace
   config) and the multi-agent block. Claude Code: run route `claude` from a dedicated `CLAUDE_CONFIG_DIR` too, so the
   owner's hooks (peon-ping) stay out; turn off the "user hasn't heard from you" reminder if a setting exists. Grok:
   exclude `~/.grok/rules`, `~/.agents/skills` and its MCP servers; rotate the token that appears in its events log.
   Muse: disable user hooks, skills and memory for game sessions.
6. Oil scouting and defence doctrine. "Scout with a gun and 20 magazines, read `map` for resources and enemies before
   walking, and cover all four directions" (all three scouts died to worms; north was never checked). Assign a warden
   on the board at the gun-turret research, with 2 turrets per outpost and the science block; shake2 placed its first
   turret 21 minutes after the technology.

### P2: harness

7. Chat that gets drained. Print every unread mention in full plus a one-line digest of the rest, and repeat
   `remaining: K` in the `team:` trailer until it is 0; no agent ever ran a second read, and Opus ended with 110 unread.
8. Quote-safe `say`: make `./fh say -` with a heredoc the only documented form for text with apostrophes, and fix the
   "text is required" failure (Luna lost 3 batches and 6 messages).
9. Error lines everywhere: `--format json` failures need an `error:` line too.
10. Add `inventory` as an alias of `status` inventory (15 failed calls), make `describe.json` greppable by
    `"name": "<action>"` as agents expect, fix `construct`'s PlayerIdentification bug, `shoot` not spending ammo,
    `observe scope=stock` without an item, and `./shot`.
11. Grok Build: pre-approve `./fh` redirects and `python3`; its 30 s auto-background turns every `wait_until` into a
    polling chain (12 minutes of Grok's hour).

### P3: playbook

12. Keep notes.md in plain spaced English and under 6 KB; spaceless notes are the likely carrier of Sol's and Astra's
    drift across compactions. Test this by comparing words per character after the change.
13. Queue plans again: Opus went from 45 plans to 0 once `./fh sleep` and `wait_until` were advertised. Say when to use
    which: queues for repeated courier and refuel routes (`plan save` / `plan run`, used by nobody), `wait_until` only
    with a short timeout, never `researched` waits longer than 2 minutes.
14. Science capacity: Sol's "8 red, 4 green assemblers" target came at 26m and was reached late; labs never passed 9.
    Put the lab and assembler targets by game time in the playbook (shake1 recommendation, still not met).
15. Profiles: list the available voices and avatars in AGENTS.md without a single example that everyone copies, and
    reject colours and glyphs already taken.

## Appendix: methods

- Game time is tick/3600; tick 0 at 21:42:44 PDT, checked against chat `logged_at` and profile responses.
- Milestones and factory: `scores.jsonl` 2-minute snapshots, chat and notes.
- Board: every `board`, `board_post`, `board_update` and `harness_request` request and response in the nine journals,
  paired by id.
- Journal metrics (both runs, same code): decisions exclude `status`, `queue_status` and fh's own helper requests
  (`peek:true`, `scope=sleep_check`, the post-wait self-check); errors are decisions with `ok:false`; chat coverage is
  the share of teammates' message sequence numbers that appear in the agent's `chat` replies; placed counts `build` and
  `place_ghosts` entities plus build steps in queue submissions; deaths are "bot X is dead" errors matched to loss
  alerts by tick and position.
- Codex steps: one tool call (a JS `exec` cell, possibly with several commands); think is the time from the previous
  tool output, user message or compaction to the call; per-step usage from the `token_usage_record` that follows it;
  windows are 10 minutes from 04:44:48Z. `tools/analysis/transcript_steps.py` and `codex_tokens.py` were reused.
- Claude Code: turn ends from `system/turn_duration` records; compaction stalls from the last tool result before to
  the first tool call after; unseen failures by matching journal failures to tool results.
- Grok: think from `loop_started` to the first `tool_started` in events.jsonl; context from `_meta.totalTokens`.
  Gemini: per planner step from agy's SQLite (copied first); context from `input_tokens + cache_read_tokens`. Muse:
  tool result to next tool call; context from its compaction records.
- Characters per word: `say` texts of at least 25 characters, binned by the context of the step that sent them.
- The one-off parsers for this study live in the session scratchpad and are not committed; the committed
  `tools/analysis/` scripts cover Codex and Claude Code steps and the journals.
