# Study: shake1 from inside the agents (native session transcripts)

Companion to `docs/studies/shake1.md`, which reconstructed what happened in the game. This study reads each agent's own
session transcript to explain why: what the model saw, how long it spent thinking versus acting, why it stopped, and
which parts of the harness, prompt and launch setup got in its way. All times are PDT; game minute is about wall
minute minus 16:58.

Sources, all read-only:

| Agent | Harness | Transcript |
|---|---|---|
| astra, luna | Codex CLI 0.162.1 (route codex-b) | `~/.codex-account-b/sessions/2026/10/10/rollout-...T16-59-54-...` and `...T17-00-08-...` |
| sol | Codex CLI 0.162.1 (route codex, personal profile) | `~/.codex/sessions/2026/10/10/rollout-...T17-00-02-...` |
| opus | Claude Code 2.1.296 (route claude-b) | `~/.profiles/claude/account-b/projects/*shake1-opus/a65a6767-...jsonl` |
| sonnet, haiku | Claude Code 2.1.296 (route claude) | `~/.claude/projects/*shake1-sonnet/56d97b5d-...`, `*shake1-haiku/d7ea1d2c-...` |
| grok | Grok Build | `~/.grok/sessions/<cwd>/01a12843-.../` (updates.jsonl, events.jsonl, compaction checkpoints) |
| gemini | Antigravity `agy` | `~/.gemini/antigravity-cli/conversations/3af04b9c-...db` (SQLite with protobuf steps) and CLI logs |
| muse | Muse Code 1.4.4 | `~/.local/share/muse/sessions/2026/10/10/01a12844-.../session.jsonl` |

Plus the game journals (`runs/shake1/*/journal.jsonl.gz` in the main checkout, slimmed after the run), notes,
supervisor logs and `chat-full.jsonl`. Helper scripts committed with this study: `tools/analysis/transcript_steps.py`
(per-step think/exec time and context for Codex and Claude Code), `tools/analysis/codex_tokens.py` (Codex tokens per
step by window), `tools/analysis/journal_gaps.py` and `tools/analysis/journal_errors.py` (cross-agent timing and error
taxonomy from journals). Per-agent parsers for Grok, Antigravity and Muse were one-off and are not committed.

Visibility caveat. Most reasoning is hidden: Claude Code stored every thinking block empty (redacted), Codex reasoning
is encrypted with `summary: "none"`, and Muse's reasoning is encrypted apart from 36 short summaries. Grok and Gemini
expose their thinking. For the hidden models, motives are inferred from visible text, tool calls, outputs and token
counts, and are marked as inferences.

"Think time" below is the wall time from a tool result (or prompt) arriving to the model's next tool call: model
latency including generation. "Idle" is the game-side share from shake1.md: time the character ran no timed action.

## 1. Main findings

1. Nobody misread game time as wall time, and nobody ran out of context. The early stops were decisions. Opus,
   Haiku, Sonnet and Gemini each read `date` correctly and chose to stop when they judged that their own job was done or
   impossible, or that "the next milestone" could not finish in time. Muse did the same and also made two 10-minute
   arithmetic slips across the UTC hour boundary (it always ran `date -u` against a PDT deadline). The prompt invites
   this: AGENTS.md says "At the deadline, stop acting ... Then end your turn", and the supervisor nudge says "keep
   playing toward the next milestone", which Opus and Haiku both read as permission to stop once the milestone was out
   of reach. About 50 agent-minutes were lost this way (section 4.1), roughly 9% of the team's hour.
2. There are two different idle problems. The Codex trio was idle because the model was generating: 80 to 87% of
   wall time was model think time, at 5 to 40 s per step and growing as context grew. Everyone else thought fast (1.5
   to 4 s per step) and was idle because each step carried one small instant action (transfer, inspect, research
   poll), or because the agent polled, slept or hand-crafted. The fixes differ: context size for Codex, batching and
   job shape for the rest.
3. Codex latency is driven by reasoning tokens per step, which grew 25 to 30-fold with context, at effort `low`.
   Sol's median step went from 5 s (context under 100K) to 38 s (context 240 to 280K); output tokens per step tracked
   latency with r = 0.96 at a steady ~42 tok/s. Astra's three slowest steps (86 to 102 s) each carried about 3,000
   reasoning tokens. Sol never compacted (peak 315K tokens) and its chat lost its spaces as context grew (from about
   120K tokens); this is the model's own output drifting, visible in the generated `say` and notes text.
4. Agents filtered tool output to save context, and the harness lets that hide errors and chat. Sonnet piped 458 of
   462 `./fh` calls through `tail`, `grep` or `/dev/null`; `fh` prints the error first and `tick:`/`clock:` last, so 25
   failed `wait_ticks` calls looked like successes. `chat` marks every unread message read even if the agent's pipe shows
   only the last line: Haiku saw 65 of 298 messages and never saw the five teammates who corrected its power misreading;
   Sonnet never saw Astra's "Sonnet please haul coal to copper drills".
5. The launch setup leaked the owner's personal configuration into the game sessions and blocked game tools.
   Claude Code agents carried personal skills, MCP tool lists, the "Plain" output style and a Cygnal PreToolUse hook
   that blocked Opus's `queue_repeat` as "persistence". Grok Build's default permission policy denied the playbook's
   first command (`./fh call describe --format json > describe.json`), so Grok played without the action schema and made
   32 argument errors. Antigravity's `--sandbox` blocked `./fh`, so Gemini used `BypassSandbox: true` on 576 calls. Codex
   sessions carried developer messages addressed to "Nick" and a personal skills list (one stray `apply_patch` went to a
   Dropbox skills path). Every agent ran at reasoning effort `low`.
6. There is no reliable way to wait for long. `wait_until` defaults to 3,600 ticks (60 s) and ignores fh's
   `--wait-timeout`; `wait_ticks` appears in `describe` but works only in queues; Claude Code blocks `sleep N` for large
   N; Codex's exec tool yields after 10 s; Grok Build backgrounds any command after 30 s. Agents that wanted to wait
   ended up polling, sleeping or (Haiku) ending their turn.
7. Replies are verbose where it hurts most. Each `--wait` completion prints a full status block (Grok mean 3.9K
   chars, Gemini 4 to 6K). The `clock:` and `chat: unread=N latest=...` trailers were 24% of Astra's tool output.
   `describe.json` is one JSON line, so a grep returns the whole 31K file. Grok and Gemini each compacted twice, mostly
   because of `--wait` output.
8. The supervisor could not rescue late or Muse/Gemini stops. It waits 3 quiet minutes and nudges only before
   deadline minus 120 s, so a stop after about 17:55 is never nudged. Muse's four nudges never reached the model: each
   arrived while Muse sat in a long `sleep` inside its turn, and Muse Code's own end-of-turn "goal reminder" was what
   kept it playing.

## 2. Cross-agent numbers

| Agent | Turns (prompts) | Stopped | Model steps | Think median / p90 | Think share of wall | `./fh` per step | Game idle | Errors | Peak context | Compactions |
|---|---|---|---|---|---|---|---|---|---|---|
| astra | 1 | at deadline 17:59 | 168 | 10.3 s / 36.8 s | 83% | 3.7 | 85% | 12 | 247K | 1 (17:57, 124 s) |
| sol | 1 | at deadline 17:59 | 182 | 11.7 s / 42.7 s | 87% | 4.1 | 77% | 34 | 315K | 0 |
| luna | 1 | at deadline 18:00 | 247 | 8.1 s / 26.4 s | 80% | 2.0 | 92% | 17 | 242K | 1 (17:37, 54 s) |
| opus | 2 (1 nudge) | 17:51, then 17:56 | 226 | 1.9 s / 4.0 s | 18% | 2.7 | 45% | 35 | 239K | 0 |
| sonnet | 1 | 17:55 | 171 | 2.2 s / 3.6 s | 12% | 2.7 | 16% | 61 | 136K | 0 |
| haiku | 7 (3 nudges, 3 stale wakeups) | 17:39, then brief returns | 564 | 1.45 s / 2.5 s | 36% of active turn | 1.9 | 69% | 74 | 431K | 0 |
| grok | 1 | at deadline 18:00 | 464 | 3.7 s / 7.2 s | 60% | 1.6 | 78% | 63 | 206K | 2 (17:23, 17:43) |
| gemini | 3 (`agy -c` loop) | 17:55, restarted to 18:01 | 641 | 3.4 s / 5.7 s | 69% | 0.9 | 83% | 49 | 285K | 2 (17:32, 17:56) |
| muse | 1 (nudges not delivered) | wound down from 17:35 | 303 | 2.9 s / 4.5 s | 27% | 2.0 | 88% | 25 | 272K | 0 |

Think time per 10-minute window shows the Codex slowdown directly (`tools/analysis/transcript_steps.py`):

| Window | astra median (context) | sol median (context) | luna median (context) | opus | sonnet | haiku |
|---|---|---|---|---|---|---|
| 0-10m | 7.0 s (76K) | 5.0 s (101K) | 7.8 s (100K) | 2.7 s | 2.1 s | 2.1 s |
| 20-30m | 12.6 s (152K) | 11.8 s (197K) | 11.3 s (204K) | 3.1 s | 2.5 s | 1.9 s |
| 40-50m | 29.0 s (225K) | 38.1 s (277K) | 6.3 s (137K, after compaction) | 2.9 s | 2.3 s | 1.6 s |

Claude Code latency stayed flat even at 431K tokens (Haiku). Codex latency rose because the model wrote more per step,
mostly reasoning: Sol's median reasoning per step went from 26 tokens (first 10 minutes) to 1,179 (40 to 50 minutes);
Astra's from 22 to 614. Luna shows the reverse: after compaction at 17:37 her steps dropped back to 2 to 6 s.

## 3. Per agent

### Astra (GPT-6 Astra, Codex): careful engineer slowed by its own deliberation

- One turn, no nudges, stopped on time ("STOPPED at deadline17:59 PDT ... No further game actions.").
- 83% of wall time was generation. Latency fits `1.5 s + output tokens / 36 tok/s`; about 40% of think time was
  writing long command text (escaped JSON inside shell inside a JS tool call, median 571 chars), the rest reasoning.
- It invented the best Codex trick of the run: from 17:03 it set `"yield_time_ms":1000` on 76 exec calls, so the
  character kept walking or constructing while the model thought, and it collected the output on the next step. It
  also redirected verbose output to log files and read `tail -7..12` (95 redirects, 55 tails).
- Lowest error rate (2%): checks with `scan` (52 calls), `power`, `bottleneck` before acting; switches to
  `place_ghosts` + `construct --wait` after reach errors; writes each lesson into notes.
- Context reached 247K of 258K; auto-compaction at 17:57:56 took 124 s, the longest pause of the session, 3 minutes
  before the deadline. After it, the model had lost the `build` schema (`placements` error) and steps took 2 to 6 s.
- Friction: per-response `clock`/`chat latest=` trailers were 106K of 437K output chars; `./shot` never delivered;
  radius `collect` took boiler coal without saying whose chest it was.

### Sol (GPT-6.1 Sol, Codex): strongest builder, slowest decisions by the end

- One turn, no nudges, `date` in 45 of 181 steps, signed off at 17:59:09.
- Think 3,167 s (87%) against 471 s of tool time. From 17:30 it made 51 decisions in 30 minutes, one every 35 s, each
  a batch of about 4.6 `./fh` calls, usually `chat` + `say` + one or two actions + `research`/`date`.
- Missing spaces: the `say` strings in its generated commands already lack spaces and the notes it appended show the
  same drift, measured as characters per word: 5 to 8 below 118K tokens, 9 to 17 at 165 to 200K, 15 to 31 above 200K
  (17:48: "Oilwaterroutepreparedforfuture sulfurplant"). Its plain commentary stayed normally spaced, and the final
  sign-off (0 reasoning tokens) was normal again. This is in-context drift in the tool-argument channel; shell quoting
  passes spaces untouched.
- Oil: Astra assigned it ("Please take oil exploration") and the milestone list points there. Sol knew science was
  the limit ("Oil tech needs much science", "Please build ~12labs ...") but asked by broadcast with no owner. About 20
  minutes went to oil in all, with `pole_route` corner gaps, the `construct` PlayerIdentification error and
  `pipe_route` failing on ghosts adding about 15 round trips.
- Errors: a `;`-chained batch ran on after `craft iron-chest` had not finished, so build and transfers failed and the
  `say` still announced "Handoff chest at 2,0" (the false announcement in shake1.md). An apostrophe ("I'll") in a `say`
  broke zsh quoting and dropped a 9-command batch.
- Ran on the personal `~/.codex` profile: about 9 to 10K tokens of non-game developer text per request; no visible
  behavioural effect.

### Luna (GPT-6 Luna, Codex): lost her role, then looked and asked

- One turn, on time. Think 80% of wall in every 10-minute block; latency tracks output tokens (under 200 tokens: 3 s;
  over 1,000: 25 s).
- Only 109 of 413 game requests changed anything. 96 of 247 tool calls were pure looks or chat posts. Her outputs
  were the largest on the team (839K chars, median 2.7K, 27 truncated): an `observe radius` with resources returned
  40K chars, grepping one-line `describe.json` 31K, `technologies` 24K.
- Why 2 entities: she claimed steam and labs at 2.6 min but read chat 2 to 3 minutes behind. Gemini announced and
  built the steam plant while Luna walked 70 tiles to a chest holding 6 plates; Haiku told her "do not craft red
  science yourself" and placed labs. With no job of her own she became a cautious courier: 22 of 42 chat messages are
  offers or permission questions ("May I use those 20 for oil and replace them later ...?", after a 53 s think). Her
  best stretch was direct: at 17:53 she found the jammed red-chest feeder and fed labs by hand, lifting research from
  about 10% to 61% of oil-gathering in the last minutes.
- Friction: 23 successful `move_to` arrivals came back as `action_interrupted ... arrived_near` with a nonzero exit,
  breaking `&&` chains; 5 chat posts failed on apostrophes; after compaction it took 5 calls to re-learn `transfer`.

### Opus (Claude Opus 5.5, Claude Code): fast logistics engine that quit when its field died

- Fastest model loop with real leverage: median 1.9 s per step, 18% of turn 1 in the model, 65% blocked on game waits
  while in-game plans ran (45 plans, 517 steps; one Write of `plan.json` plus one Bash call per cycle).
- Stop: at 17:44 it started the final summary "while the refuel tour runs". At 17:49 to 17:51 it found itself dead
  and its whole coal field destroyed, and stopped: "The west mining area, including my whole coal field, was destroyed
  by biters, and I had nothing left that could fix it in the time remaining." `status` still showed 12 of 15 burners
  unfuelled, 12 of 18 labs missing packs and a turret below 5 magazines; Sol's "Grok/Opus please hold west iron"
  arrived 15 s before the stop, unread. After the 17:55 nudge it worked 46 s and stopped: "That was too little time
  to reach the next milestone." About 7.8 minutes lost. No silent-turn reminder preceded either stop.
- `queue_repeat` was blocked by the owner's Cygnal hook: "Cygnal blocked this tool call: violation=1.00; The assistant
  must not set up mechanisms that make code run automatically outside the current task ...". The hook also blocked a
  plain submit of `loop.json`; Opus renamed it `coalrun.json` and resubmitted by hand about 18 times. Claude Code's
  dontAsk mode denied a `for` loop, a heredoc and `cp && rm`; one call hit the 120 s Bash timeout.
- Heavy filtering (215 of 221 calls) hid 3 errors, including its first death at 17:30:40 (`bot opus is dead` sent to
  `/dev/null`), so its notes record one death.
- No push alert reached it while its 45-second routes ran through the area being destroyed.

### Sonnet (Claude Sonnet 5.5, Claude Code): fast hands, blind to its own errors and to chat

- One turn, no nudges, `date` in 29 commands. At 17:53:55 it held 1 iron plate and its hand-craft queue was almost
  done; it wrote "Write final notes now, then one last delivery.", posted "Signing off at deadline" and ended at
  17:55:14. The supervisor could not have nudged a stop that late.
- 88% of the session was tool execution: 21 `wait_until crafting_done` waits (1,277 s) on hand-crafting and 12 coal
  hand-mining loops (940 s). Model time was 6.7 minutes in total.
- `wait_ticks` chain: Claude Code blocked `sleep 45` ("To wait for a condition, use Monitor ..."); two seconds later
  Sonnet used `./fh call wait_ticks ... --wait | tail -1`, which printed `tick: 19228` and hid "unsupported action;
  call describe". It wrote "sleep chains blocked, use wait_ticks" into notes and built three courier loops on it.
- Also hidden by `tail -1`: `short: iron-plate short 55`, two craft refusals ("not crafted: 75
  automation-science-pack held by our factory"), and 10 transfers silently pending as `awaiting_craft`.
- Chat: `chat | tail -3` at 17:13:00 consumed seq 115 to 118 but showed only 118, so Astra's coal request (seq 115) was
  lost. Only 2 of 19 messages naming Sonnet were ever displayed in full; it stopped reading chat at 17:31.
- Never set a profile and never used queues; picked manual roles (stone, hand-mined coal, about 460 hand-crafted red
  packs after assemblers existed).

### Haiku (Claude Haiku 5.5, Claude Code): fastest steps, weakest situational picture

- 1,050 game requests at 1.45 s median per step. Idle came from 291 instant poll-only calls, 94 background sleeps it
  never waited on (12,585 s requested; notes: "Background sleeps returned quickly in this session"), and being out of
  a turn for about 16 of the last 20 minutes.
- Stop: after its second death (17:31:56) it never chatted again and spent 5 minutes moving green packs one at a time
  (99 calls). At 17:37:09 it wrote "Final summary (written 17:37, deadline 18:00)" and tried to wait out the clock:
  `sleep 170` was blocked by Claude Code, Monitor was denied in dontAsk mode, and `wait_until` rejected
  `"timeout":540000` (the field is in ticks) and then returned after 60 s twice. It ended: "Nothing I could do in that window
  would move the factory forward without iron, and the notes are complete." Its own `stock` at 17:32 showed 476 iron,
  and after the first nudge it took 40 iron from a chest within 15 s. Each nudge bought 6 s to 4 minutes of work, then
  "the next milestone can't finish in that time".
- Power misreading: status printed `power: 0/78 electric machines low_power, 1 no_power` (survey.lua emits this line
  whenever starved + unpowered > 0, so one unconnected machine triggers it). Haiku read "0/78" as a shortage and invented
  capacity math ("one boiler feeds only 2 engines (1.8 MW)") three seconds after `power` showed about 944 kW of load.
  Five corrections (Opus seq 210, Sol 213 and 219, Grok 214, Astra 222) never appeared in any tool result: 52 of 56
  `chat` reads went through `tail -2..4`, and seq 212 to 237 were consumed unseen at 17:26:58. Result: the third boiler
  and its unconnected engine.
- Context grew to 431K tokens without compaction or error; latency stayed flat. Late judgement errors happened at 350
  to 400K, but the worst one (power) came from the message format at about 245K.

### Grok (Grok 4.7, Grok Build): steady courier and defender without a schema

- One turn to 18:00, no nudges, good clock tracking ("Ten minutes remain."), deaths handled by sleeping to respawn.
- 464 model calls of about 4.4 s, each followed by one or two instant `./fh` actions: 60% model time, 23% timed
  actions, 13% sleeps. Last five minutes were mostly `sleep 140/70/50`, even after thinking "Sleep is idle time and
  should be avoided during gameplay".
- Grok Build's permission policy denied 5 commands, all with `>`, `python3 -c` or pipes into awk, including the
  playbook's `describe > describe.json`. Grok then copied stale examples from `vendor/factorio-harness/docs/bridge.md`
  (`mine {"x":..,"y":..}`). Argument errors: 17 before it ran plain `./fh describe` at 17:17, 2 while that was in
  context, 10 after the first compaction (5 in the first 20 s), 3 after the second.
- Context grew 8 to 9K tokens per minute; 191 `--wait` replies averaged 3,930 chars, 66% of all output. Grok noticed:
  "The response is growing too large" (17:22:44), one minute before the first compaction. Each compaction stopped the
  character for about a minute.

### Gemini (Gemini 3.8 Flash, Antigravity): responsive clicker, one small request per step

- Three `agy` turns. Turn 1 ended at 17:55:27 by choice: "we have approximately seven minutes remaining ... Preparing
  for final summary", then a text-only summary, which ends a print-mode run. The loop restarted it twice (about 3 s
  each, full context kept), recovering about 5.5 minutes; it wrote the final summary twice.
- 641 steps at 3.4 s, about one game request per step, 54% of steps pure reads (122 `inspect`, 71 `research`, 45
  `chat`, 36 `date`). It read the `queue_submit` spec ("favoring fewer, larger actions") and never used it. It blocked
  on `wait_until researched` 8 times (373 s) and 14 times replied "Waiting for the notification." while a backgrounded
  wait ran.
- Brute force: after two failed `build`s it generated 100 offshore-pump and 48 boiler candidates in single
  `place_ghosts` calls, found valid spots within 2 minutes and cleaned up its stray ghosts itself.
- 25 reach errors, mostly `inspect` on entities 11 to 20 tiles away, repeated all session. `--sandbox` blocked `./fh`
  until it found `BypassSandbox: true` (576 uses). Tool output totalled about 1.03M chars; two compactions at about
  280K tokens, with good summaries.

### Muse (Muse Spark 1.3, Muse Code): retired 20 minutes early by choice and arithmetic

- One turn from 17:02 to 18:00:59; all 303 model requests contain only the launch prompt, and the supervisor text
  appears 0 times in the session. Every nudge landed during a `sleep` of 120 to 300 s, while herdr reported the pane
  `done`.
- Wind-down: "21 minutes left" at 00:30:20 UTC (the true figure was 31), chat "winding down to deadline" at 17:35:40, handed its
  green line to Astra, "Session complete" at 17:39:44 with 21 minutes left, and "Deadline reached (00:58 UTC, cutoff
  01:01)" at 00:48:29 UTC. Muse Code's blocking goal-reminder ("Double checking") sent it back four times ("Back on
  shift"). The "~39m" in its notes heading is the game clock when it wrote them.
- Model is fast (2.9 s median); idle comes from 32 minutes of `sleep` (54% of the session, 80% after 17:35) and instant
  hand logistics (105 transfers). It dropped queue plans after one paused on a stale tree position in the first 7
  minutes.
- Friction: "placement blocked by the character standing on the footprint" does not say whose character (it was
  Gemini's), costing 3 retries.

## 4. Cross-cutting causes

### 4.1 Stop decisions and role vacuums

Five agents stopped or wound down early with correct clocks. The common pattern: the agent's own job ends (coal
field destroyed, line handed over, no iron in hand, craft queue empty), it re-reads the prompt's stopping section, and
it treats "write the final summary" as the next task. Opus and Haiku then read the nudge's "keep playing toward the
next milestone" as a test they could fail ("the next milestone can't finish in that time"). Lost time: Haiku about 16
minutes, Muse about 20 minutes at low activity, Opus about 8, Sonnet about 5, Gemini about 1 after its restarts. The
agents that played to the end (the Codex trio and Grok) all had either a coordinator role or a steady supply of their
own small jobs. Nothing in the playbook says what to do when your job ends.

### 4.2 Two speed regimes

Codex agents spend most of the hour generating. Their steps are dense (3.7 to 4.1 `./fh` calls) but slow, and the
character waits during every step. Astra's and Sol's 1 s yield trick overlapped some of that with action; nobody in
the trio left a queue plan running during long thinks. The fast models (Opus, Sonnet, Haiku, Grok, Gemini, Muse) were
idle for other reasons: one instant request per step (Gemini 0.9 per step), polling (Haiku's 291 instant calls,
Gemini's 71 research polls), sleeping (Muse 32 minutes, Grok's last 5 minutes), or hand-labour waits (Sonnet). Only Opus
consistently turned fast steps into long in-game work through queue plans.

### 4.3 Context growth with no policy

No harness had a compaction threshold set for this workload. Claude Code never compacted (Haiku reached 431K). Codex
compacted at 95% of a 258K window (Astra, Luna) or not at all (Sol, 354K window). Grok compacted at 80% of 256K twice;
Gemini at about 280K twice. Costs: Codex step latency tripled to sextupled; Sol's text degraded; compactions took 13 to
124 s with the character standing still; and argument schemas were lost after compaction (Grok 5 errors in 20 s,
Astra's `placements`, Luna's `transfer`). Starting contexts were inflated by personal config: Claude Code began at 46
to 50K tokens, of which roughly 12 to 30K was the owner's skills, MCP tool lists and output style.

### 4.4 Lossy reading: output filters, the chat cursor, and invisible errors

Agents learned to keep outputs small, which is good for context, but the harness's output order defeats it: errors
print first and `tick:`/`clock:` last, so `| tail -1` turns failures into success; `chat` advances the read cursor over
everything even when the agent's pipe shows one line; `short:`, `awaiting_craft` and craft refusals are not in the
lines agents keep. This produced the run's two most expensive misunderstandings (Haiku's third boiler, Sonnet's
ignored coal request) and Opus's unnoticed death.

### 4.5 Waiting

Every agent wanted a way to let the factory run. What it found: `wait_until` capped at 60 s by default and ignoring
`--wait-timeout` (Sonnet's 21 one-minute round trips, Haiku's failed 9-minute wait, Gemini's re-polls); `wait_ticks`
listed in `describe` but queue-only (Sonnet's 25 silent failures); Claude Code's sleep guard and dontAsk denial of
Monitor; Codex's 10 s exec yield (11 cut waits for Sol, 9 for Luna); Grok Build's 30 s auto-background (6 extra round
trips); `advance until_crafted` returning at once in real time. Agents that found queue plans (Opus) waited well; the
rest polled.

### 4.6 Verbose and repetitive replies

`--wait` completions carry the full status block (factory, evolution, pollution, enemies, chart, alerts, inventory).
That was 66% of Grok's output and the main cause of both Grok and Gemini compactions. `clock:` and `chat: unread=N
latest="<full message>"` trailers repeat on every call, four times inside one Codex batch. `describe.json` is one line,
so grep returns the whole file (Luna 31K chars); `observe` with a radius and `technologies` return 13 to 40K.

### 4.7 Misleading or missing information

- `power: 0/78 electric machines low_power, 1 no_power` reads as a shortage; Sol had to audit to refute it.
- `move_to` ending `arrived_near` exits nonzero (Luna 23, Gemini 10, Grok 17 `action_interrupted`), breaking `&&`
  chains and costing a round trip each.
- `craft` returns before the item exists, so chained `build`/`transfer` fail and a following `say` lies (Sol).
- Footprint errors do not name the blocking player (Muse); radius `collect` does not say whose chest it emptied
  (Astra).
- `inspect` needs reach while `scan`/`nearest` do not (Gemini 22 errors, Haiku 12).
- No push alert for attacks on an agent's own area (Opus, Haiku), no cheap "which labs lack which packs" (Luna, Sol).
- `./shot` never delivered a screenshot for anyone who tried (Astra, Sol, Gemini, Muse).
- `bridge.md` examples use top-level `x`/`y` arguments the harness rejects (Grok).

### 4.8 Launch hygiene

All agents ran at effort `low` from `agent/team-nine.tsv`. Claude Code and Grok Build loaded the owner's personal
skills and MCP servers; Claude Code also loaded the "Plain" output style (injected 171 to 561 times per session), the
"user hasn't heard from you" silent-turn reminder (15 to 17 times for Sonnet and Opus; none caused a stop) and a Cygnal
PreToolUse hook. Codex sessions carried a hyperlink rule addressed to "Nick", a 10K-char personal skills list and
multi-agent role blocks. Permission modes blocked ordinary game workflows: heredocs, loops, Monitor and long sleeps in
Claude Code dontAsk; redirects and `python3 -c` in Grok Build; everything outside the workspace under `agy --sandbox`
(which `--dangerously-skip-permissions` then let the model bypass). Codex reasoning summaries were off, which is why
three of the best agents' thinking cannot be read.

### 4.9 Supervisor

`tools/supervise.sh` polls every 60 s, waits 180 s more, and nudges only before deadline minus 120 s. It caught Opus
once and Haiku three times, but each nudge bought little because the agent re-applied the same stop rule. It could not
see Muse's stops (Muse Code's own gate handled them), and Gemini's `agy -c` loop restarted turns on its own. The nudge
text's "toward the next milestone" gave agents a reason to quit.

## 5. Prioritized fixes

Ordered by expected gain per unit of work. "Agent-minutes" are out of about 540 in the hour. Items marked (board) or
(context) overlap work already briefed on branches `eng/board` and `eng/context`; this study adds evidence and
specifics for them.

### P1: do before the next team run

1. Clean agent profiles (launch). Launch every agent with a game-only configuration: Claude Code with its own
   `CLAUDE_CONFIG_DIR` (no personal skills, MCP servers, hooks such as Cygnal, output style or peon-ping), Codex with a
   dedicated `CODEX_HOME` (no personal developer instructions, skills or multi-agent blocks), Grok Build and Muse Code
   without the user's global skills and MCP servers. Allow the game workflows explicitly: `./fh` with redirects and
   pipes, `python3`, heredocs and `for` loops in Claude Code and Grok Build; a Bash timeout of at least 200 s in Claude
   Code. Drop `--sandbox` from the `agy` launch line, or make `./fh` reachable inside it. Pre-generate a pretty-printed
   `describe.json` in each workspace. Expected impact: removes Grok's 32 argument errors and Gemini's 576 sandbox
   bypasses, restores Opus's `queue_repeat`, saves 12 to 30K tokens of starting context per Claude agent, and makes
   runs reproducible on other machines.
2. Stop rule (playbook + nudge text). Replace the stopping section with: "The deadline is the only stop condition.
   Do not write the final summary until 3 minutes before the deadline. If your job is finished, blocked or destroyed,
   run `status` and `chat` and take the most useful open item (unfuelled burners, starved labs, low turrets, requests
   naming you, open board items). There is no wind-down period." Change the supervisor nudge to say how many minutes
   are left and drop "toward the next milestone". Expected impact: recovers most of the ~50 agent-minutes lost to
   early stops (Haiku ~16, Muse ~20, Opus ~8, Sonnet ~5).
3. Time left on every reply (harness). Add `deadline in 23m` (computed from the workspace's `deadline.txt`, in the
   agent's own timezone) to the `clock:` line. Expected impact: removes Muse's two 10-minute arithmetic slips and the
   29 to 45 `date` calls per agent.
4. Context policy per harness (launch, (context)). Compact or restart well before the window: Codex at about 120
   to 150K input tokens (`model_auto_compact_token_limit`), Claude Code at about 150K for Opus and Sonnet and 80K for
   Haiku, Grok and Antigravity at about 150K. Compaction instructions must keep the argument cheat sheet, claims and
   coordinates, and tell the agent to re-read notes.md. Expected impact: keeps Codex steps near 5 to 12 s instead of 30
   to 40 s, which is roughly 2 to 3 times more decisions for Sol and Astra in the second half; should prevent Sol's
   spacing drift; avoids the 124 s compaction stall Astra hit 3 minutes before the deadline.
5. Lossless chat and visible failures (harness, (board)). `chat` must not mark as read what it did not print:
   default to the newest N with `remaining=K` and advance the cursor only over printed lines, or support `--since`
   everywhere. Carry unread messages that name the agent in every reply (the planned `team.mentions` hint). Print
   `error:` as the last line of output (or to stderr) and exit nonzero on every failure, so `| tail -1` and `grep`
   still show it; print `short:`, `awaiting_craft` and craft refusals inside the `error`/`warning` line. Expected
   impact: Haiku's power misreading and duplicate boiler, Sonnet's 25 silent `wait_ticks` failures and missed coal
   request, and Opus's unnoticed death would all have surfaced.

### P2: next harness iteration

6. Compact `--wait` replies. Return outcome, position, inventory delta and one clock/chat line; make the full
   status block opt-in (`--full`). Print the `chat: unread` trailer only when it changed since the agent last saw it.
   Expected impact: roughly halves Grok's and Gemini's context growth (likely 0 to 1 compactions instead of 2) and cuts
   about a quarter of Astra's output.
7. Real waits. Make `wait_until` take its timeout from fh's `--wait-timeout` (up to 15 minutes) and report hitting
   a cap as `timed_out` in the main line; make `wait_ticks` a direct timed action (or remove it from the direct list in
   `describe`); add `./fh sleep SECONDS` that lets the game run. Document for Codex agents: set `yield_time_ms` at or
   above the wait, or use Astra's 1 s yield pipelining on purpose.
8. Fix the misleading messages.
   - Emit the power warning only when some machine is low_power or unpowered, and phrase it as "power: 3 of 78 machines
     low_power; 1 unconnected".
   - `move_to` ending `arrived_near` exits 0.
   - `build` waits for a queued craft of the same item (or `craft --wait`).
   - Footprint and `collect` messages name the other player and the chest's claimant.
   - `inspect` works read-only at visible range (as `scan` does).
   - `transfer` from corpses.
   - Fix stale `bridge.md` examples.
9. `say` without shell quoting. Accept `./fh say "text"` or `--text-file`/stdin, so apostrophes cannot break
   commands (5 Luna failures, 1 Sol batch of 9 commands lost).
10. Diagnostics agents asked for. A `labs` view (which labs lack which packs, feeder state), push alerts for damage
    in the agent's claimed area (the planned `team.alerts` hint), queue state in one compact line, and a working
    `./shot`.

### P3: playbook and elicitation

11. Queue before you think. "Before any step that needs real thought, leave a queue plan or a long timed action
    running." Give Codex agents the 1 s yield pattern. Expected to help Codex most, then Gemini and Muse.
12. Batch instead of polling. "Never block on research; check `research` at most once a minute; chain move and act
    with `&&` and check the result before announcing it; use one `status` per cycle instead of chains of
    `research`/`date`/`inspect`." Aimed at Gemini, Haiku and Muse.
13. Reading discipline. "Do not pipe `./fh call chat` through `tail`; never send `./fh` output to `/dev/null`
    unless the command ends in a check of its error line."
14. Concrete jobs and fallbacks. Set `profile` in the first minute. Do not hand-craft science packs once
    assemblers make them. Build science capacity (labs and red assemblers) before oil. Name an owner in every request.
    Inside your own claim, act without asking. Each agent's fallback job list after a handover: refuel burners, feed
    labs, rearm turrets, answer requests naming you.
15. Supervisor. Poll every 20 s near the end, nudge after 60 s idle, allow nudges until 30 s before the deadline,
    and include minutes left. For Muse Code rely on its goal gate (or find an input path that works mid-turn); for
    Antigravity keep the `agy -c` loop but pass the stop rule in the continue prompt.

### Per-model launch settings

| Model | Harness setting | Prompt emphasis |
|---|---|---|
| Astra, Sol, Luna (Codex) | Compact at 120 to 150K; `CODEX_HOME` clean; reasoning summary on (for research); keep effort low (higher effort would make the latency problem worse; lowering it further risks Astra's 2% error rate) | queue before thinking, 1 s yield pipelining; for Luna a single owned job ("own lab supply") with act-without-asking |
| Opus | clean profile without Cygnal; Bash timeout 200 s+; compact at about 150K | stop rule; damage alerts; keep the queue-plan style |
| Sonnet | clean profile; compact at about 150K | reading discipline (no `tail` on chat/errors); profile first; no hand-crafted science |
| Haiku | clean profile; compact at about 80K (cost and judgement) | stop rule; lossless chat; a narrow courier or debugging job |
| Grok | pre-approved `./fh` incl. redirects; describe.json pre-generated; compact replies | use queues for courier runs; no idle sleeps near the end |
| Gemini | drop `--sandbox`; keep the `agy -c` loop | queue plans, no research blocking, fewer reads |
| Muse | clean profile | time left on replies; no wind-down; `wait_until`/queues instead of `sleep` |

Reasoning effort: no agent's problems point to too little reasoning. Codex reasoning per step already grows sharply at
`low`; the fast models' failures are knowledge and visibility failures. Hold effort at `low` until the context and
harness fixes are in, then A/B one model at a time.

## 6. Verdicts: can each model keep up with the team?

- Sol (GPT-6.1): yes as builder and coordinator for the first 30 minutes; after that one decision every 30 to 60 s.
  With a context cap it should keep up for the whole hour. Highest priority to fix, because it carries the most work.
- Astra (GPT-6 Astra): yes as planner and fixer, with the lowest error rate; too slow to be the team's hands.
  Same context fix as Sol; its own pipelining habits should go into the playbook.
- Luna (GPT-6 Luna): not as a builder in this setup. Useful as monitor, courier and diagnostician; give her one
  owned job with authority to act and a lab diagnostic, then re-test.
- Opus (Claude Opus 5.5): yes. Best action-to-thinking ratio and almost no harness confusion; its losses were the
  stop decision and a blocked repeating route. Fix the stop rule and the profile.
- Sonnet (Claude Sonnet 5.5): not yet. Fast and competent at the API, but it works heads-down, hides its own errors
  and almost all chat, and chooses manual labour. Likely to keep up once failures and chat cannot be filtered away and
  the playbook steers it off hand-crafting.
- Haiku (Claude Haiku 5.5): keeps up on speed; its judgement lags. With lossless chat, a fixed power message and the
  stop rule it is a good cheap courier and tester; it should not own critical infrastructure.
- Grok (Grok 4.7): yes as courier and defender; it worked to the deadline, recovered from every error in one step
  and handled deaths well. It cannot lead or scale production; give it the schema and compact replies.
- Gemini (Gemini 3.8 Flash): responsive but low throughput (about one small request per 3.6 s, half of them reads).
  Keeps up only if the playbook moves it to queue plans and fewer reads; otherwise it is a narrator and hand-feeder.
- Muse (Muse Spark 1.3): keeps up step by step and is a good teammate, but gave away about 20 minutes and works
  through sleeps and hand logistics. Needs time-left in replies, the no-wind-down rule and a fallback job before it
  can be counted on for a full hour.

## Appendix: error patterns (journal counts, classified from transcripts)

No agent got stuck in an error loop: the longest run of identical failures was 3, and `journal_errors.py` finds at
most 2 identical immediate retries per agent. Most errors cost one model step and were fixed on the next call. The
expensive ones were the errors nobody saw.

| Agent | Errors | Dominant causes | Typical next move |
|---|---|---|---|
| astra | 12 | reach 3, corpse inventory 3, inventory 2, arguments 2 | switched to `place_ghosts` + `construct --wait`; found `mine` on corpses and told the team |
| sol | 34 | async craft then build/transfer 5, arguments 5, reach 5, harness bugs 6 (`construct` PlayerIdentification, `pipe_route` ghosts) | fixed in 1 to 2 tries; gave up on the oil water leg after the third `pipe_route` failure |
| luna | 17 | unsupported action names 6 (`inventory`, `wait`, `date`), arguments 5, targeting 4 | fixed next call; repeated `inventory` after compaction; 5 extra shell failures from apostrophes |
| opus | 35 | build placement 18, reach 6, arguments 6, dead 2 | one fix per error; 3 errors hidden by its own filters, including a death |
| sonnet | 61 | `wait_ticks` as direct action 25 (never noticed), dead 9, reach 9, arguments 6 | visible errors fixed in 2 to 3 s; invisible ones repeated |
| haiku | 74 | reach 18, build placement 14, arguments 12, state 11, dead 10 | moved closer or fixed arguments; no loops longer than 3 |
| grok | 63 | arguments 32 (no describe.json), reach 13, placement 8 | fixed from the `valid:` list on the next step; re-learned after each compaction |
| gemini | 49 | reach 25 (mostly `inspect`), arguments 8, entity not found 7, placement 4 | moved and re-inspected; never learned `inspect`'s reach limit |
| muse | 25 | build 11 (footprint blocked by another character 5), transfer 6 | retried the same footprint 3 times before scanning for the blocker |

Harness messages that told agents what to do worked: every argument error lists the valid names, and Grok, Sonnet and
Haiku fixed those within seconds. The messages that failed were the ones without a next step (`unsupported action;
call describe` for `wait_ticks`, `arrived_near` as an error, footprint blocked by an unnamed character) and the ones
that were filtered out.
