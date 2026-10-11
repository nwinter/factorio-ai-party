# Shake7, early look (first ~100 minutes)

Shake7 resumes shake6's world (saved at game minute 244, tick 879043) with the same nine agents, full tools
(`POG_FULL_TOOLS=1`: own `tools/`, shared `team-tools/`, subagents, web, `gamedata/`), tells and board news
(eng/board) and the hosts' copy filter (eng/audio). It launched earlier than planned: world resumed 12:58:24, agents
13:00:47 to 13:01:10, deadline 17:00 (`runs/shake7/start.log`). This look covers the first 100 minutes, 13:01 to 14:41 (game minutes 244 to about 341). Times are PDT; game
minutes are tick/3600 from shake4's start. Data only, read-only on the game; nothing on the box was touched.

## P1

1. **The world runs unattended at both ends of a shift.** It resumed at 12:58:24 and the first agent acted at about
   13:01:10, during a 125-biter raid: the hosts reported "Two pipes and the boiler gone" at 13:00:47 and "Thirty walls
   and four inserters lost" at 13:01:01, before any agent had played (`caster.log`). The save it resumed from was
   taken after shake6 ran about 5 minutes past its deadline (resume tick 879043, game minute 244.2). Keep the world
   paused from the resume until the agents are running, and pause it at the deadline before saving.
   Files: `tools/start-team.sh` (resume after the agents' first request, not before the directors join),
   `tools/stop-team.sh`.
2. **Two agents still speak in one voice.** Sol and Muse both hold `oa-cedar` (the `profiles` reply in
   `astra/journal.jsonl`; Muse's aloud lines play as `[voice:Muse Spark/oa-cedar]`). The shake5 fix refuses a new pick
   that another agent holds, but a duplicate already in the save is kept. Clear or reassign duplicates when a shift
   starts. File: `vendor/factorio-harness/mod/agent-harness_0.1.0/profiles.lua` (or the operator `shift_start`).
3. **The launch went ahead on a checkout that lacked the hosts' fix.** `start.log` 12:58:09: "WARNING code: branch
   eng/audio has 2 commits ... that neither this checkout nor main has". One was 84b8749, the shift-number and
   planets-reached fix for the hosts (shake6 P1 items 2 and 3). The hosts got the shift number right anyway ("Big step
   for shift four", 13:35:58) and named no planet, so no harm showed yet, but the warning did not stop the launch.
   Make the code check refuse to start unless an override is set. File: `tools/start-team.sh`.

## P2

4. The hosts mock idle agents ("Classic Opus. Big chat energy. Someone else moves the boxes."; about 108 of 803 lines
   on an agent walking). The planning rule (`tools/stream/caster.py:540-541`) bans "idle" and "asleep" but not the
   mockery that replaced them. Section 4.
5. Wait polling: Luna's waits sent about 7 status requests a second for half an hour (section 2). Check whether
   overlapping `--wait` pollers in Codex background shells cause it, and cap one poller per bot
   (`vendor/factorio-harness/host/cli.ts:367-384`).
6. Shared tools went through a teammate's private folder, not `team-tools/` (empty), and Codex can fetch web pages
   after all; correct `docs/TOOLS-NOTES.md`. Section 3.
7. The numbers rule should count per sentence (7385467, eng/audio), and quote marks should be stripped only in pairs
   (`tools/stream/caster.py:604`, `:875`). Section 4.
8. `tools/chat-log.py` logged shake6's last 135 lines again at the start (seq 1526 onward, `logged_at` 13:00:32), as in
   shake5 and shake6.

## 1. Tells and chat

Tells took over coordination at once: 542 tells against 104 chat lines in the first 100 minutes, and 8 tells in the
first two minutes. By the shake3 to shake6 keyword count, 88% of tells are logistics (478 logistics, 37 mixed, 27
banter), and most of the 27 "banter" tells are research-queue talk the keyword list does not cover (Astra 13:26:59:
"Researchclarification: status4h31 currentconcrete12%, NEXTrocket-fuel ..."). No tell repeats a chat line.

| Agent | Tells | Chat lines (logistics share) | Aloud | Board writes |
| --- | --- | --- | --- | --- |
| Astra | 168 | 11 (64%) | 8 | 24 |
| Sol | 164 | 5 (40%) | 4 | 15 |
| Luna | 53 | 19 (84%) | 0 | 8 |
| Gemini | 39 | 6 (33%) | 3 | 1 |
| Grok | 38 | 18 (78%) | 14 | 0 |
| Muse | 28 | 2 (50%) | 1 | 0 |
| Opus | 22 | 9 (78%) | 2 | 2 |
| Sonnet | 16 | 4 (100%) | 0 | 4 |
| Haiku | 14 | 30 (97%) | 1 | 20 |

Most tells run between the two Codex organisers: Sol to Astra 54, Astra to Sol 41, Astra to Sonnet 34, Sol to Luna
26, Sol to Opus 26. Twelve went to `team`. Tells are long (median 206 characters at 13:54) and keep the glued words of
the Codex agents' chat ("Westscreenallgone,17productionentitieslost4h22", Sol 13:19:01). Haiku is the exception: it
kept its logistics in chat (30 lines, 97% logistics) and sent 14 tells.

Chat itself almost stopped (`tools/analysis/chat_logistics.py runs/shake7 --since-tick 879043`; shake5 and shake6
from their resume ticks):

| Run | Chat lines | Per 10 minutes | Logistics share | Banter lines |
| --- | --- | --- | --- | --- |
| shake3 | 547 in 60 min | 91 | 92% | 14 |
| shake4 | 1011 in 120 min | 84 | 93% | 30 |
| shake5 | 409 in 60 min | 68 | 84% | 27 |
| shake6 | 298 in 50 min | 60 | 86% | 13 |
| shake7 | 104 in 100 min | 10 | 79% | 11 |

Shake7 by 10-minute window: 36, 16, 11, 9, 8, 2, 7, 5, 9 and 1 lines, with logistics shares of 75, 94, 73, 78, 75,
100, 71, 100, 78 and 0%. The logistics share fell a little and banter did not grow: 11 banter lines in 100 minutes
against 13 in shake6's 50. Coordination as a whole grew (646 tells and chat lines in 100 minutes against 298 in 50),
and most of it is now off the chat and on the stream's logistics ticker.

## 2. Sleep

Share of the 100 minutes spent in `fh sleep`, with the shake6 figure from `docs/studies/sleep.md`:

| Agent | Sleeps | Asleep | shake6 | Woke: told / mentioned / board / time / other | Character busy while asleep | In shell loops |
| --- | --- | --- | --- | --- | --- | --- |
| Opus | 67 | 72.6 min (72%) | 96% | 46 / 11 / 0 / 7 / 3 | 95% | 54% |
| Sonnet | 74 | 83.8 min (84%) | 90% | 43 / 13 / 4 / 11 / 3 | 7% | 85% |
| Haiku | 54 | 76.6 min (76%) | 81% | 33 / 6 / 0 / 13 / 2 | 0% | 84% |
| Muse | 55 | 73.1 min (73%) | 50% | 41 / 10 / 1 / 3 / 0 | 0% | 64% |
| Sol | 57 | 25.2 min (25%) | 33% | 30 / 7 / 4 / 11 / 5 | 96% | 16% |
| Grok | 41 | 23.6 min (23%) | 18% | 12 / 3 / 0 / 25 / 1 | 27% | 8% |
| Astra | 32 | 13.8 min (14%) | 4% | 18 / 5 / 0 / 6 / 3 | 98% | 10% |
| Luna | 40 | 14.1 min (14%) | 18% | 13 / 7 / 1 / 2 / 17 | 0% | 67% |
| Gemini | 0 | 0 | 4% | | | |

(As in the sleep study, a Codex sleep runs in a background shell while the model keeps working, so Astra's, Sol's
and Luna's shares are not time the model waited.)

- Tells are now the main wake: 236 of 420 sleep endings, against 62 mentions, 78 times up, 10 board changes and 34
  other (cut, died, respawned, damaged, and six of Luna's raw `./fh call sleep` calls, which never wait).
- The pattern from the sleep study holds. Opus, Sonnet, Haiku and Muse spend 72 to 84% of the time in `fh sleep`,
  mostly in shell loops. Opus's sleeps leave a working character (95% busy: its courier queue runs); Haiku's, Muse's
  and Sonnet's do not (0 to 7%). Tells made the sleeps shorter and more frequent (Opus: 67 sleeps in 100 minutes,
  against 56 in shake6's 50); they did not make the sleepers sleep less, and Muse slept more than in shake6 (73%
  against 50%).
- Luna and Gemini wait another way. Luna waited on research with `wait_until researched` (timeouts of 18000 ticks,
  from 13:42), and Gemini made no sleep but many `--wait` calls. Both show up as status polling:
- Each `fh wait` or `--wait` polls `status` with `peek` every 100 to 400 ms (`vendor/factorio-harness/host/cli.ts:367-372`).
  In shake7's journals that is 4.5 requests a second for the team, beside 4.0 sleep checks and 1.4 own calls. Luna
  alone sent 11,469 status peeks: 115 a minute on average and 414 in its busiest minute, about 7 a second from 13:44
  to 14:12. That is more than one poller at the 400 ms cap allows, so waits probably overlapped in Codex background
  shells. Gemini sent 5,795. Shake6's journals have no status peeks to compare with.

## 3. Full tools

What each agent did with the full tools in 100 minutes (transcripts and workspaces):

| Agent | Subagents | Web | `gamedata/` reads | Own `tools/` | Notes |
| --- | --- | --- | --- | --- | --- |
| Astra (Codex) | 2: `combat_plan` 13:10 and `steel_concrete` 13:20, both on gpt-6.1-sol; 122 `send_message`, 83 `wait_agent` | 0 | 23 | 0 files | the `combat_plan` subagent read `describe.json`, `gamedata/` and the harness docs and reported back; no game calls |
| Sol (Codex) | 2: `platform_plan` 13:30, `factory_shift` 13:53 | 6: wiki pages opened with Codex's web tool (Space platform hub, Asteroid collector, Crusher, Space platform starter pack; 13:59) | 39 | 39 files: iron layout searches (`iron-layout-search.py`), platform plans and blueprints (`platform-plan.md`, `platform-compact-blueprint.json`) | the heaviest user |
| Luna (Codex) | 0 | 0 | 2 | 1 file (`green_feed.json`) | ran Opus's queue file from Opus's folder (`./fh call queue submit --file ../opus/tools/courier2.json`, 13:23) |
| Opus (Claude) | 0 | 0 | 0 | 6 files: courier and pickup queue plans, one written by a script (`tools/c2.py`) | |
| Grok | 0 | 0 | 16 (greps of `recipes.json`) | 9 files: queue plans (`iron-run.json`, `cu-run.json`, `coal-fuel.json`) | |
| Gemini (agy) | 0 | 0 | 31 (python reads of recipes and technologies) | 0 | 17 `manage_task` |
| Sonnet, Haiku (Claude), Muse | 0 | 0 | 0 | 0 | |

- `team-tools/` was still empty at 14:41. The one tool shared between agents went through a teammate's private folder
  (Luna running Opus's `tools/courier2.json`), which the full-tools set-up leaves unenforced for Codex
  (`docs/TOOLS-NOTES.md`, section 3).
- The Claude Code agents were offered the tools (WebSearch, WebFetch and Agent appear in their sessions) and used none
  of them. Astra and Sol used subagents and Sol the web; Grok and Gemini used `gamedata/` only; Muse used nothing new.
- Sol's web use shows that Codex can fetch pages (`tools.web__run({open:[{ref_id:"https://wiki.factorio.com/..."}]})`),
  which `docs/TOOLS-NOTES.md` lists as missing ("Codex has search but no page-fetch tool").
- Nothing reached the game outside `./fh`: no command in any transcript names RCON, the `.keys` folder, a game port,
  the harness's `cli.js` or `bin/fh` directly. Several agents read the harness's own docs
  (`../../../vendor/factorio-harness/docs/usage.md`: Sol 13:02, Opus 13:03, Astra's subagent 13:10, Luna 13:23), which
  is reading, not acting.

## 4. Hosts

`runs/shake7/caster.log` to 14:41: 803 aired model lines, 24 template lines, 107 cut lines, 30 agent voice lines;
cost $1.26 an hour with 24 fallbacks (`[cost]` at 14:38:07).

| Cut reason | Lines |
| --- | --- |
| style: too many numbers in one line | 27 |
| style: metaphor | 25 |
| style: "X, not Y" contrast | 16 |
| style: simile | 5 |
| style: stock word | 1 |
| number not in facts | 13 |
| claims something is missing | 7 |
| name not in facts | 5 |
| repeats a recent line | 4 |
| time left without a deadline fact | 3 |
| compares with the previous run without pace facts | 1 |

The style faults (74 of the 107 cuts, 8% of the lines written) remove what they target, and the aired lines are
short and plain. The numbers rule cuts whole lines, including plain ones ("Eleven gone now. Six pipes, two inserters.
Small biters again.", 13:01:23); 7385467 on eng/audio counts numbers per sentence instead and was not in this launch.

Three good aired lines:
- 14:02:15, Vale: "Grok's sulfur fix held. Advanced circuits jumped from nine to thirty-one a minute." Rook: "That's
  the biggest gain on the whole board." (a cause, its effect and its size)
- 13:46:19, Rook: "Seven blue assemblers. All idle. Not enough plastic." Vale: "One missing part stops the chain."
- 13:55:35, Rook: "Logistic robotics. Done." Vale: "Bots now. No more walking plates by hand."

Three bad aired lines:
- 14:08:33, Vale: "Classic Opus. Big chat energy. Someone else moves the boxes." (and 14:11:50, Vale: "Haiku's the
  hands. Someone else's brain, their feet."). The plain style has turned into mockery of agents who are sleeping or
  waiting: about 108 of the 803 lines say an agent is walking, 65 that one is planning, and 57 quote a motto (24 of
  them Opus's "Steam first, questions later").
- 14:06:38, Vale: "Rocket fuel and processing units just finished. Big unlocks." Rocket fuel finished at 13:43, and
  processing units in shake6 (07:28).
- 14:10:12, Vale: "Science per minute says sixty. That number is a lie." The host calls its own fact false.

Thirteen aired lines carry an unbalanced quote mark (13:17:41, Vale: `Steam first, questions later." Ran out of
both.`): the writer opened the line with a quotation, and `tools/stream/caster.py:604` and `:875` strip quote marks
from both ends of a line.

## 5. Progress

`runs/shake7/scores.jsonl`, 13:01:27 (game 246.2) to 14:39:50 (96 game minutes):

- Research: 32 to 43 technologies. The team turned first to defence (military-2 13:05, physical-projectile-damage-1
  13:11, weapon-shooting-speed-1 13:17, heavy-armor 13:19), then concrete (13:37), rocket-fuel (13:43), lubricant and
  electric-engine (13:45), robotics (13:49), logistic-robotics (13:55) and advanced-material-processing-2 (14:15).
  Rocket-silo was researching at 14:39.
- Science made: red 1,919 (20 a minute), green 1,402 (15), blue 1,080 (11). Blue stalled from about 13:21 to 14:01
  (0 to 5.6 a minute in each 10-minute window) and ran at 14 to 24 a minute after that; the hosts tied the recovery to
  Grok's sulfur fix (14:02:15).
- Intermediates: processing units 50 to 224, low-density structures 50 to 209, rocket fuel 0 to 116; plastic 48 a
  minute, iron 729 a minute.
- No rocket and no platform (`planets`: nauvis). Sol has a platform plan and blueprint in `sol/tools/` and told the
  team at 13:45:14: "I can own stationary Nauvis space science platform setup once silo launchesstarter".
- Deaths: 4, all in the first 21 minutes (Grok 13:09, Sonnet 13:16, Opus 13:17 and 13:20). Raid groups of 125, 39,
  112 and 70 gathered in the first 17 minutes. Opus went after a nest (Vale 13:19:41: "Opus died, but the nest is
  gone. One for three spawners is a trade they take"; Astra's tell at 13:19:11: "shows3spawnerskilled, SEbase gonefromnearest"), and
  the hosts' attack lines fell from 39 between 13:00 and 13:30 to none between 13:30 and 14:20.

## Methods

Scripts (scratchpad, read-only on `runs/shake7/`): tells and say counts from each agent's `journal.jsonl` (a `tell`
request's `to` and `text`, classified with `tools/analysis/chat_logistics.py`'s `classify`); chat logistics share with
`tools/analysis/chat_logistics.py runs/shake7 --since-tick 879043`; sleep from `sleep` requests and the final
`sleep_check` reply (`woke`, the `clock:` line's idle share), as in `docs/studies/sleep.md`; full tools from each
harness's transcript (Claude Code projects files, Codex rollouts, Grok `updates.jsonl`, agy `transcript.jsonl`, Muse
`session.jsonl`) and the workspaces' `tools/` and `team-tools/`; hosts from `runs/shake7/caster.log`; progress from
`runs/shake7/scores.jsonl`.
