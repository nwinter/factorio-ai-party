# Why do the agents sleep?

Nick asked why agents spend so much of a run in `./fh sleep` (shake4: Muse 77% of two hours, Haiku 63%, Opus 48%;
shake3: Haiku 44.5 of 60 minutes). This study reads the agents' own words before their long sleeps (shake3 to
shake6), the journals, and how the harness and prompts present `sleep`. Times are PDT.

## Short answer

1. Heavy sleep is a Claude and Muse pattern, and it grew run on run. Share of the run asleep: Opus 14%, 37%, 46%,
   85%, 96% (shake2 to shake6); Haiku 32%, 69%, 61%, 69%, 81%; Sonnet 25%, 31%, 13%, 46%, 90%; Muse 24%, 11%, 69%,
   62%, 50%. Grok and Gemini sleep 0 to 18% in short spells (30 to 90 s). The Codex agents' journals show up to 40%,
   but their models never waited on a sleep for a minute: the Codex shell returns after a second and leaves the sleep
   running in the background while the model keeps working.
2. The agents are waiting for something specific, and the harness has no wait that ends on it. They wait for their
   own queue plan to finish a round (Opus, Muse), furnaces to refill (Muse, Haiku), an assembler cycle (Grok), the next
   turret rearm (Haiku), a teammate's answer, a raid to pass, or the deadline. `fh sleep` wakes only on a mention, a
   hit on the agent's own body, death or the time asked; it never wakes when the queue ends or stalls, a chest fills,
   research finishes or the base is attacked. So agents guess a length, loop it, and let chat cut it short.
3. `fh sleep` is the only wait that keeps a queue plan running. Any direct timed action, `wait_until` included, pauses
   the queue (`vendor/factorio-harness/mod/tests/runtime_test.lua:686-688`). Opus wrote it down in shake4 and carried
   it in its notes through shake6: "wait_until and any direct action PAUSE the courier queue; use ./fh sleep while
   courier runs." Opus's 96% asleep in shake6 is a working bot: its character was busy 100% of that time.
4. Mentions set the rhythm. 64 to 100% of the Claude agents' sleeps end on a mention, many of them `@everyone`
   broadcasts (8 to 70% of mention wakes), and a woken agent often sleeps again at once (Opus shake6: next request a
   sleep after 77% of wakes). Asleep share is many short sleeps, not a few long ones.
5. The stop rule makes a sleep tail. The deadline is "the only stop condition", the summary is due in the last three
   minutes, "then keep playing", and the turn must not end early (`agent/PLAYBOOK.md:105-113`). Agents with a finished
   job or a written summary sleep out the clock in every family ("Idle until the deadline nears or someone mentions
   me", Haiku; "Waiting for the clock to run out.", Muse; "Standing by for deadline completion", Gemini).
6. The environment hides it. The supervisor cannot see a sleep (the CLI's once-a-second checks look like activity), the
   stream calls a sleeper "between tasks", the hosts may not say "asleep", and Claude Code moves a long sleep loop to the
   background where it outlives the turn and the deadline.
7. Model disposition decides who sleeps idle. Under the same prompt, Haiku sleeps on fixed timers with work it has named
   still open, Sonnet saw "character idle 7m24s of it (97%)" and kept the pattern, and Opus settled into approving
   teammates' requests from inside a sleep loop. Compaction, quota and supervisor nudges are not causes.

## 1. How the environment presents `sleep`

What an agent is told and what the tool does, in the order an agent meets it.

Prompts. Every agent's AGENTS.md (or CLAUDE.md) is built from `agent/PLAYBOOK.md`, `agent/time-realtime.md` and
`agent/team.md`:

- `agent/time-realtime.md:1-3`: "time spent deliberating is time the character stands idle and machines may starve.
  Prefer fewer, larger actions: batched builds, in-game queue plans, and `--wait` on timed actions." Sleep is not named.
- `agent/PLAYBOOK.md:58-63`: "`./fh sleep 120` lets the game run (your queue keeps going) and returns early if you
  are hit or mentioned, but not when a machine starves; your character is idle for the whole sleep." Then "Which wait
  fits: a queue plan for rounds that should keep going while you think ...; `wait_until` for one condition, with a
  timeout of a few minutes (a `researched` wait can hold you for the whole research); `./fh sleep` when only a
  teammate or an attack should wake you." This line has been in every run since shake3 (e2959f5, 00:02).
- `agent/PLAYBOOK.md:40-41`: "Don't poll. Check `research` at most once a minute; let the factory run with
  `wait_until` or a queue plan".
- `agent/team.md:31`: "Answer teammates promptly." `agent/team.md:41`: "When you're waiting on someone, say so, then
  do something else useful."
- `agent/PLAYBOOK.md:105-113` (Stopping): the deadline "is the only stop condition"; "In the last three minutes, add a
  final summary ... then keep playing; a summary written earlier is a draft to finish then. End your turn once the
  `clock:` line says the deadline has passed. When your own job is finished or blocked, `./fh call status`,
  `./fh call chat` and `./fh board` show what is still open."
- The run prompt (`runs/shakeN/prompt.md`): "play Factorio until the deadline in deadline.txt ... and finish with the
  final summary it asks for."
- `fh --help` (`vendor/factorio-harness/host/cli.ts:36`): "fh sleep SECONDS  Let the game run up to 900 s; wakes
  early on damage, death or a mention". The `describe` note (`waits.lua:10`) says the same and adds "current actions
  and queues keep going".

Nothing in the prompts says what share of a run sleeping is reasonable, and nothing says sleeping is not playing. The
PLAYBOOK does say the character is idle for the whole sleep.

The tool (`vendor/factorio-harness/mod/agent-harness_0.1.0/waits.lua`, `host/cli.ts:448-465`):

- `sleep` is passive (`runtime.lua:3562`): it leaves the character's current action and queue running. The other
  waits are not: a direct `wait_until` stops the current action first (`runtime.lua:3556`, "finish(p.index,
  'replaced') else stop(p)") and holds the character for its condition.
- It wakes on four things only (`waits.lua:42-70`): the character is damaged, dies, respawns, or a message mentions the
  agent; else at the time asked. It does not wake when research finishes, a queue plan ends or fails, power drops, a
  machine starves, an attack hits the base (only the agent's own body), a board item changes, or a teammate talks
  without `@name`. A wake reply does carry the base attacks that piled up: Haiku woke on a mention in shake6 with
  "attack near (16,16) by small-biter: steam-engine x10, transport-belt x2 hit 12 times, 84 damage, 0s ago" and "enemy
  group of 90 gathered at (83,99) heading for (28,3)" in the same reply (`runs/shake6/haiku/journal.jsonl.gz`).
- No other wait wakes on a mention. `wait_until` (researched, item_count, crafting_done) and `--wait` ignore chat, so
  an agent told to "answer teammates promptly" that wants to wait for research has one tool that keeps it reachable,
  and that tool cannot wait for the research.
- The cap is 900 s per call (`cli.ts:591`). Agents that want longer chain calls in shell loops (`for i in 1 2 3 4 5;
  do ./fh sleep 280 ...; done`), and a loop keeps sleeping after a wake: each later call starts a new sleep, so the
  first wake is the only one that ends a call early, and a loop piped through `grep` can hide even that.
- The wake reply's `clock:` line reports the cost: "+3m37s since your last request, character idle 3m37s of it
  (100%)" (Haiku, shake6). The agent learns it after the fact, never before.

The supervisor and the stream:

- `tools/supervise.sh:40-64` nudges only when the agent's turn has ended (herdr status idle or done) and its journal
  is quiet for two minutes. A sleeping agent is mid-turn, and the CLI's `sleep_check` polls write a journal request
  every second (`cli.ts:455-459`), so a sleep never looks idle and is never nudged. Ending a turn early is nudged
  ("keep playing until the deadline has passed"); sleeping through the same minutes is not.
- The stream does not know about sleep either. The live model calls an agent with no running action "thinking" for
  90 s after its last action and "idle" after that (`tools/stream/model.py:525-534`); the hosts hear these as
  "planning the next step" and "between tasks" (`tools/stream/caster.py:269`), and are told never to call a planning
  agent "frozen, still, motionless, idle or asleep" (`caster.py:540-541`). Viewers never hear that an agent is asleep.

The other waits, as the agents met them:

- A direct timed action pauses a running queue (`runtime_test.lua:686-688`: a `pickup` during a queued walk leaves
  `queue_status` `paused`), and `wait_until` is a direct timed action. Sonnet's notes: "wait_until during a queue plan
  interrupts and pauses the plan" (`runs/shake6/sonnet/notes.md:57`). Gemini in shake3 could not tell from the
  describe text and chose `sleep` for that reason (01:19:21: "whether `wait_until` will also pause the execution
  queue").
- `wait_until` knows three conditions (researched, item_count, crafting_done). There is no condition for a queue
  finishing (Opus: "wait_until has no queue_empty; use sleep", `runs/shake5/opus/notes.md:45`), and item_count takes
  one position and radius, not a list of chests. Muse tried both forms in shake6 (07:38:30): the list was refused
  ("unknown argument positions for wait_until"), and the area form was interrupted when its queue moved the
  character. Its notes: "wait_until item_count background run failed on move-interrupt; manual sweeps only".
- `./fh call sleep --args '{"seconds":120}' --wait` is accepted and returns at once (the raw `sleep` action only starts
  the sleep; the CLI's `fh sleep` is the part that waits, `cli.ts:451-465`). Luna used that form 103 times in shake4 to
  shake6 and carried on 1 to 3 s later, believing it had waited: "I'm letting the shared iron and science lines run for
  a couple of in-game minutes" (shake5 05:52:43).

Each CLI's shell changes what a sleep costs the model:

- Codex: `exec_command` returns after `yield_time_ms`, and `agent/harness-codex.md:3-6` suggests 1000 ms for long
  actions. Astra and Sol use it for every `fh sleep`, so the sleep runs in the background as a mention catcher while
  the model goes on; no Codex sleep held its model for 60 s in four runs. Codex also plays a shift as one turn.
- Claude Code: a Bash call past its timeout moves to the background, and Claude Code refuses `sleep N` chained before
  another command. Opus shake6 07:30:13: "Command did not complete within its 300s timeout and was moved to the
  background", then "Blocked: sleep 280 followed by: cat ... Do not chain shorter sleeps to work around this block."
  A backgrounded loop keeps sleeping after the turn and after the deadline (Opus's sleep checks ran to 08:17:14 in
  shake6, deadline 08:12).
- Grok Build: its shell refuses loops (`agent/harness-grok.md`), so Grok cannot chain sleeps; it sleeps 30 to 90 s at a
  time.
- agy (Gemini): a command past `WaitMsBeforeAsync` (5 to 10 s) becomes a background task and the turn ends ("Standing
  by"), to be resumed by `.agy-loop.sh`. Gemini sleeps almost only after its final summary.
- Muse Code: Muse sets `yield_time_ms` to match each sleep (up to 330000), so its sleeps block for their full length.

So the design makes `sleep` the one wait that keeps the queue going, keeps the agent reachable and satisfies the stop
rule without a nudge. It is also the cheapest thing an agent can do: one tool call for up to 15 minutes of the run.

## 2. The numbers

Share of the run asleep, from the journals (a sleep runs from the `sleep` request to its last `sleep_check`; window
from the team's first request to the deadline). In brackets: how busy the agent's character was during its sleeps, from
the `clock:` line of each wake reply ("character idle Ys of it"), which counts queue steps, walks and crafts.

| Agent | shake2 | shake3 | shake4 | shake5 | shake6 |
| --- | --- | --- | --- | --- | --- |
| Opus | 14% (0%) | 37% (51%) | 46% (89%) | 85% (86%) | 96% (100%) |
| Sonnet | 25% (10%) | 31% (2%) | 13% (0%) | 46% (10%) | 90% (6%) |
| Haiku | 32% (0%) | 69% (0%) | 61% (0%) | 69% (0%) | 81% (0%) |
| Muse | 24% (0%) | 11% (0%) | 69% (8%) | 62% (0%) | 50% (0%) |
| Astra | 3% | 7% | 36%* | 20%* | 4% |
| Sol | 5% | 3% | 9% | 40%* | 33%* |
| Luna | 5% | 4% | 7% | 9% | 18% |
| Grok | 5% | 4% | 12% | 7% | 18% |
| Gemini | 0% | 13% | 1% | 0% | 4% |

\* Astra's and Sol's sleeps run in a background shell while the model keeps working (section 1); the most any Codex
model spent blocked on sleeps in a run was 5.3 minutes (Luna, shake4). The shake4 study's figures (Muse 77%, Haiku 63%,
Opus 48%) used a different end point for a sleep; the order is the same.

- Lengths asked split by family: Codex, Grok and Gemini 60 s or less almost always; Muse 61 to 180 s (120 to 300 in
  shake6); Haiku 61 to 300; Opus 181 to 300 (61 of 64 in shake5); Sonnet 301 to 600 in shake6 (16 of 21). Nobody
  asked for more than 600 s.
- Agents get far less than they ask: Opus asked 297 minutes in shake4 and slept 55; Muse asked 190 and slept 83.
- Wakes: mentions end 64 to 100% of the Claude agents' sleeps (Opus shake6 50 of 56, Haiku shake4 109 of 130) and 70%
  of Muse's in shake4 (93 of 132). Of those mention wakes, `@everyone` and messages not addressed to the agent make up
  8 to 70% (Sonnet shake3 70%, shake6 61%; Muse shake4 41 of 93).
- After a mention wake: Opus replied to the sender within 5 minutes after 22 of 50 in shake6, and its next request was
  another sleep after 43 of 56 wakes; Sonnet replied after 4 of 21. The Codex agents reply after most (Astra 68 of 83
  in shake4, Sol 42 of 46 in shake5).
- Shell loops hold most long sleeping: the share of asleep time in sleeps started within 5 s of the previous one's end
  is 99 to 100% for Opus in shake5 and shake6, 97% for Sonnet in shake6, 68 to 77% for Haiku. A wake in the middle of a
  loop is read only when the loop ends, and loops piped through `grep -E "mention:|clock"` drop the `woke:` line.
- Phase: sleep rises toward the deadline (Opus shake3 6% in the first 15 minutes, 86% in the last 20; Muse shake4 49%
  to 88%). In the resumed shifts (shake5, shake6), Opus, Sonnet and Haiku were 69 to 93% asleep from the first 15
  minutes.
- Not linked: after a compaction the share asleep is near or below the run average (Haiku shake4 46% vs 61%); supervisor
  nudges were 0 or 1 per agent per run after shake2; no Claude transcript has a quota message; Gemini's shake5 quota
  stop made it absent, not asleep.

## 3. What they were waiting for

Opus, a queue supervisor. From shake4 on a repeating courier queue carried science while Opus slept; it woke on
mentions, checked labs or answered, edited the courier, and slept again (`./fh sleep 300; ./fh call labs | head -2`, 40
of 70 long sleeps in shake4). Shake3, Bash descriptions: "Let ferry run", "Let plan run" (23 of 26 long sleeps).
Shake5 05:21:40: "Courier repeating. Let it run while I sleep." Its wakes are mostly teammates asking to build in its
claim or take from its chests (`agent/team.md:37`, "don't build inside someone else's claim without asking"), and its
replies are mostly yes: 10 of its 13 `say` lines in shake6 start "yes", "approved", "fine by me" or "thanks". It made
no builds in shake6.

Haiku, a chore timer. Haiku labels every Bash call, so its reasons are on record. Shake3: "Let the factory run for
three minutes" and its kin on 39 of 51 long sleeps, tending burner furnace pairs on a loop it wrote into its notes
("Loop: every ~5 min: collect ... feed ... deliver", `runs/shake3/haiku/notes.md:7`). Shake4 to shake6: turret rearm
cycles ("Wait, then rearm perimeter turrets": `./fh sleep 300 && ./fh call rearm ...`, 31 of 85 in shake4), waiting
for materials ("Request iron from Sol and idle for two minutes", shake5 05:50:50), raids ("Wait through the raid and
check warnings", shake6 07:46:45) and the deadline ("Wait out the remaining deadline minutes", shake4 04:49:39). It
slept with named work open: "Two of my drills report no minable resources, and I'll check those later. I'll let the
pairs run again" (shake4 03:17:56). Its character was idle for all of it.

Sonnet, plan then wait. In shake5 and shake6 it ran a saved `haul` plan and slept 600 s
(`./fh plan run haul >/dev/null; ./fh sleep 600; ./fh wait`); the plan finished in seconds. Shake6 08:04:48, a wake
reply: "character idle 7m24s of it (97%) ... deadline in 7m", on a broadcast that "123 biters gathered ... heading for
boilers/steam engines". Next text: "Write the final summary now." At 08:09:19 it wrote "my own contribution this shift
was small."

Muse, a courier. Shake3 (labs, 11% asleep) waited with `wait_until researched`. From shake4 it ran copper by hand and
queue plan, and its sleeps are the waits in that loop: its own queue walking (98 of 132 shake4 sleep commands are
chained to `queue status`) and furnaces refilling (39 of 42 shake5 sleeps are followed by `collect`). Shake4 03:01:46:
"Power and labs are converging without me. Letting plates accumulate, then running the next delivery." Shake4
04:04:56, after a sleep: "Move job is stuck pathfinding." (its queue had stalled during the sleep, and nothing woke
it). During its one building project (a copper belt, shake4 03:42 to 04:02) its share fell to 28 to 46%.

Grok, short waits on a hand-fed line. Shake4 03:46:29: "I'll collect and feed every 45 seconds. The character will
idle during sleep, but the line should keep running." Shake6 08:08:37, in a raid: "I will not walk back in while hits
are still landing on (16, 16)", then `./fh sleep 70`.

Gemini, a deadline filler. Shake6 08:10:30: "Waiting for the final countdown to our shift deadline ... Final shift
summary has been written to notes.md. Standing by for deadline completion."

The Codex agents wait in seconds and say why: teammates' approvals, a research or furnace refill, raids. Astra's and
Sol's reasoning summaries before short sleeps carry headings such as "Needing to conserve tokens" and "Waiting due to
token limits" (Sol shake5 05:29:48); the full reasoning is encrypted, so whether output budget drives them is open.

The agents' own verdicts on the tool, from their final summaries: "sleep wakes on every mention" (Haiku shake3, Sonnet
shake6), "sleep wakes on every @everyone so long waits are choppy" (Opus shake6), "chatty team cuts sleeps to ~10s"
(Muse shake6). Haiku, Sonnet and Muse each asked for a sleep that ignores chat ("sleep that ignores @everyone (wake on
direct @me/hit only)", Muse). None of them cited the PLAYBOOK's sleep line, but its phrase "lets the game run" comes
back as their own reason ("let the factory run", "let the game run").

## 4. Disposition or design

| Question | Answer | Evidence |
| --- | --- | --- |
| Does the tool invite it? | Yes, for queue owners and for anyone waiting on a rate | `sleep` is the only wait that keeps the queue running; no wait ends on a queue finishing, a chest count over several chests, or research while staying reachable (section 1) |
| Do hints suggest it? | Mildly | PLAYBOOK "Which wait fits" names `sleep` for "only a teammate or an attack"; "lets the game run (your queue keeps going)" reads as productive; it also says "your character is idle for the whole sleep". No line sets a share or calls sleep not playing |
| Does the stop rule lead to it? | Yes, at the end of every run | Summary in the last three minutes, "then keep playing", turn may not end; all families sleep out the clock after the summary (Haiku from 17 minutes before the deadline in shake5) |
| Does a finished job lead to it? | Yes | Opus after its courier ran itself; Sonnet after its plan finished; Haiku when it had no iron or magazines |
| Do mentions shape it? | They shorten it and make it frequent | 64 to 100% mention wakes; broadcasts wake everyone |
| Does each CLI shape it? | Strongly | Codex returns in 1 s; Grok cannot loop; agy ends the turn; Claude Code and Muse block for the whole sleep and loops run in the background |
| Compaction? | No | Share after a compaction at or below the run average |
| Quota? | No | No quota messages in Claude transcripts; Gemini's quota made it absent; Codex "token limits" headings are uncertain |
| Supervisor? | Only by not seeing it | A sleep is never nudged; ending a turn is |
| Model disposition? | Yes, within the room the tools leave | Same prompt: Haiku sleeps 61 to 81% idle, Grok 4 to 18% on a similar hand-fed job; Opus chose the approver role; Sonnet saw 97% idle and kept the pattern; Muse slept less when it took a build |

The tools decide whether a wish to wait becomes minutes of a standing character: the Codex shell turns it into
seconds, Claude Code and Muse let it run its full length. The model decides how often it wants to wait and what job it
takes, and the job decides what there is to wait for. The rise from shake2 to shake6 follows the jobs (Opus's courier,
Muse's copper run) and the notes that carry them into the next shift: Opus's "use ./fh sleep while courier runs"
appears in its notes in shake4, shake5 and shake6.

## 5. Changes to the tool environment

These change what the tools do and say, so agents can wait for what they mean and see what a wait costs. None tells
them what to build or when to act.

1. `fh sleep --until CONDITION` (or wait conditions on `sleep`): end the sleep when a `wait_until` condition holds
   (researched, item_count, crafting_done) while keeping the queue running and the mention and damage wakes. This
   removes the forced choice between a wait that ends on the right thing and a wait that keeps the queue going.
   Files: `vendor/factorio-harness/mod/agent-harness_0.1.0/waits.lua`, `conditions.lua`, `host/cli.ts`.
2. Wake on the agent's own queue: `woke: queue_done` when the queue empties and `queue_stalled` when a step fails or
   stops making progress (Muse's stuck pathfinding). File: `waits.lua` (read `scheduler.lua`'s queue state).
3. `wait_until item_count` over a list of entities (`positions`, as `collect` takes), and a queue-friendly mode that
   does not take the character. Files: `conditions.lua`, `runtime.lua:3547-3559`, the describe text.
4. Say what the sleep will cost when it starts: the `sleep` reply names the queue state ("queue running, 4 steps" or
   "no queue: your character stands idle up to 300 s"). The wake reply already reports idle seconds; add the queue
   steps run. File: `waits.lua` (`M.handlers.sleep`, `sleep_check`).
5. A sleep started right after a mention wake that the agent has not answered ends at once and repeats the mention, so
   a shell loop stops on the first wake. File: `waits.lua` (`why`).
6. Mark a broadcast wake as one (`woke: mentioned`, `mention_kind: everyone`), and offer `--wake direct` for a sleep that
   ignores broadcasts. Several agents asked for a chat-free sleep; on its own that would lengthen idle sleeps, so it
   belongs after items 1 and 2. Files: `waits.lua`, `cli.ts`.
7. `./fh call sleep --wait` blocks like `fh sleep`, or is refused with "use ./fh sleep SECONDS" (Luna's 103 sleeps that
   never waited). File: `host/cli.ts`.
8. End every sleep at the deadline from `FH_DEADLINE_FILE`, and give Claude Code agents a Bash timeout above 900 s
   (`BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS` in the settings `tools/launch-agent.sh` writes) so one `fh sleep`
   never goes to the background. Files: `host/cli.ts`, `tools/launch-agent.sh`.
9. PLAYBOOK wording that misleads: "`./fh sleep 120` lets the game run" (the game runs in real time anyway; sleep stops
   the agent, not the game). Describe it as what it is: "`./fh sleep 120` waits up to 120 s while your queue keeps
   going; ...". Also say in "Which wait fits" that a direct action and `wait_until` pause a running queue (true now,
   and learned the hard way by Opus, Sonnet and Gemini). File: `agent/PLAYBOOK.md:58-63`.
10. The end of a shift: the summary rule makes the last minutes a sleep. Let the final summary be written after the
    deadline (the supervisor asks for it then, and the turn ends after it), so "keep playing" runs to the end. Files:
    `agent/PLAYBOOK.md:105-113`, `tools/supervise.sh`.
11. Let the supervisor and the run analysis see sleep: `supervise.sh` and the study scripts should read `sleep` and
    `sleep_check` from the journal and log asleep minutes per agent; the stream model could show "asleep, queue running"
    or "asleep" in place of "between tasks" if Nick wants viewers to know (`tools/stream/model.py:525-534`,
    `tools/stream/caster.py:269`, `:540-541`). This is reporting, not a nudge.
12. A standing permission on a claim (`board update` with `"open":true` or a list of teammates allowed to build or
    take), so a claim owner is not woken to say yes. File: `vendor/factorio-harness/mod/agent-harness_0.1.0/board.lua`,
    `agent/team.md:35-38`.
13. Check agy's `WaitMsBeforeAsync` for long `fh` waits: a sleep past it ends Gemini's turn (not checked here).

## Methods

Journals: `runs/shake{2..6}/<agent>/journal.jsonl.gz` (a `sleep` request with `args.seconds`, the CLI's peek polls
with `scope: sleep_check`, and one final `sleep_check` with `woke`, `slept_s`, `mention` and the `clock:` line).
Transcripts: Claude Code projects files for each run's workspace, Codex rollouts in `~/.codex*/sessions/2026/10/11/`,
Muse `~/.local/share/muse/sessions/2026/10/11/`, Grok `~/.grok/sessions/`, agy
`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`. Notes, `supervisor.log` and
`context.log` per agent. Times are PDT (journals and transcripts are UTC). Mention replies: a `say` to `@sender` within
5 minutes of a mention wake. Shell loops: a sleep starting within 5 s of the previous one's end. The box was not
touched.
