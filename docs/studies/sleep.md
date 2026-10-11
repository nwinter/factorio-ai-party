# Why do the agents sleep?

Nick asked why agents spend so much of a run in `./fh sleep` (shake4: Muse 77% of two hours, Haiku 63%, Opus 48%;
shake3: Haiku 44.5 of 60 minutes). This study reads the agents' own words before their long sleeps (shake3 to
shake6), the journals, and how the harness and prompts present `sleep`. Times are PDT.

## Short answer

ANSWER

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

So the design makes `sleep` the one wait that keeps the queue going, keeps the agent reachable and satisfies the stop
rule without a nudge. It is also the cheapest thing an agent can do: one tool call for up to 15 minutes of the run.

