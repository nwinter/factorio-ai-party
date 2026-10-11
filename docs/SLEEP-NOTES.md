# Sleep tools (branch eng/sleep, SLEEPTOOLS.md)

The tool side of `docs/studies/sleep.md`: waits that end on what agents wait for, and replies that say what a sleep
costs. Tools and descriptions only; nothing tells an agent when to sleep.

## What changed

Runtime (Lua; `fh deploy`, no control.lua change, locals guard green):

- `sleep {seconds, condition}`: the sleep also ends when a `wait_until` condition holds (`woke: condition`, `saw`).
  `researched` without a technology takes the research running now (refused when none runs). A condition met already
  ends the sleep on its first check (`already_met: true`). Mentions, tells, board news, damage and death still wake
  it first. (SLEEPTOOLS item 1)
- `item_count` takes `positions` (1..64 tiles; every inventory of our entities there, summed), in `sleep`, `wait_until`
  and queue steps alike. A direct `wait_until` still pauses the queue, so the chest wait that keeps the queue running
  is `fh sleep --until "item_count ITEM>=N at X,Y ..."`: item 3 is folded into item 1.
- The agent's own queue: a queue running when the sleep starts ends it when it finishes (`queue_done`) or stalls
  (`queue_stalled`, with `queue`: a failed step or a guard that paused it, or a walking step (walk, move_to,
  build_path, kite, collect/feed/rearm/refuel tours) that has not moved the character for 30 s, as Muse's stuck move job
  in shake4). A repeating plan does not end a sleep between cycles (a short cycle would wake it every few seconds).
  Wakes report `queue_steps`, the steps finished during the sleep. (item 2)
- The sleep reply's first field, `while_asleep`: `your queue keeps running (move_to running, 3 steps pending); this
  sleep ends when it finishes or stalls`, `your walk keeps going until tick N, then your character stands idle`, or
  `no queue and no action: your character stands idle for up to 300 s`, with `(your queue is paused with N steps
  pending)` when it is. (item 4)
- Study item 5, built: a sleep started within 10 game seconds of the final read of a wake on an event (mentioned,
  told, board, damaged, condition, queue_done, queue_stalled) does not start; it returns at once with that wake,
  `repeat: true` and `while_asleep: this sleep did not start: you woke (mentioned) 4 s ago; ...`. A `for` loop of
  sleeps then runs out within a second of the first wake. Why it cannot busy-loop: at most 3 repeats per wake, every
  wake needs a real event (a mention, a hit, a board change...), none after `elapsed`, `died`, `respawned` or the
  deadline, none for a sleep given its own `--until`, and none in turns mode (game time stands still between requests there). A `while true` loop gets 3 quick
  returns per wake and then sleeps normally. The cost: an agent that reads a wake and deliberately sleeps again within
  10 s gets one instant return that says so.

CLI (`npm run build`; each `fh` call is a new process, so a rebuild applies to the next call):

- `fh sleep SECONDS --until COND`: `researched [TECH]`, `crafting_done`, `item_count ITEM>=N|ITEM<N [at X,Y X,Y ...]`,
  any condition as `NAME key=value ...`, or JSON. Help text lists the wakes.
- Sleeps end at the deadline (`FH_DEADLINE_FILE`, which every agent's `./fh` sets): cut to the time left, reported as
  `woke: deadline`; after the deadline a sleep does not start. (item 5)
- `fh call sleep` (with or without `--wait`, and in `fh run` / `fh stream`) blocks like `fh sleep` instead of starting a
  sleep and returning (Luna, 103 times in shake4-6). (item 6)

Launch and prompts (next shift):

- Claude Code agents: `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS` 1200000 (were 300000 and 960000), in
  `tools/clean-profile.py`, which `tools/launch-agent.sh` runs. A 900 s sleep can take 1135 s of real time
  (seconds x 1.25 + 10). The old 300 s default is what moved Opus's sleeps to the background in shake6. (item 5)
- PLAYBOOK: the sleep line says what the tool does (waits while the game runs anyway; what keeps going; every wake;
  `--until`; the deadline; `fh call sleep` is the same). A fact about the tool: a direct action that drives the
  character pauses a running queue (`queue resume` continues it); reads, `sleep`, `say`, `tell`, the board, `craft`
  and `research` do not. "Which wait fits" no longer names a case for sleep. (item 7)
- Stopping: play until the `clock:` line says the deadline passed, then write the final summary and end the turn (it
  was due in the last three minutes, after which agents slept). `tools/supervise.sh` asks once after the deadline
  when the agent's turn has already ended. The launch prompt ("finish with the final summary it asks for") still
  fits. (item 8)
- `tools/analysis/sleep_share.py runs/RUN [--since ISO]`: per agent asleep share, sleeps, seconds asked, wakes, what
  kept going, character idle share during sleeps, loop share, `--until` use, sleeps that never waited, requests after
  the deadline. On shake6 it gives the study's shares within a point (Opus 97%, Sonnet 91%, Haiku 81%, Muse 50%).

## Decisions to check

- A repeating plan never ends a sleep. Opus's courier is such a plan; it wakes on mentions, a stall (a failed step
  pauses the loop) or the time asked, as before. A `queue_cycle` wake would be easy to add if wanted.
- The stall rule is movement only. A step that does not walk (a long `wait_until` step, mining, building in reach)
  counts as stalled only once it fails and pauses the queue.
- The condition is checked on the CLI's once-a-second polls, not every tick (item_count over 64 chests costs at most
  64 small searches a second per sleeper).
- `--until` on an old runtime fails with `unknown argument condition`. The deadline cut and the blocking
  `fh call sleep` work against either runtime.
- Not built (study items not in SLEEPTOOLS.md): `mention_kind` and a broadcast-free `--wake direct` (6), supervisor and
  stream visibility of sleep (11), standing claim permissions (12), agy's `WaitMsBeforeAsync` (13).

## What to expect next shift, and how to measure it

Run `tools/analysis/sleep_share.py runs/<next run>` (with `--since` for a resumed shift) and compare with shake6 above and
the study's table.

- Fewer long idle sleeps where agents waited on a rate or a research. `--until` count above 0, mostly from the Claude
  agents and Muse. `woke` should show `condition`, `queue_done` and `queue_stalled` instead of `elapsed`.
- `while asleep` splits sleeps into queue / action / idle. Expect the idle share to stay where an agent has nothing
  queued: the tool now says so before the sleep instead of after. Haiku's 100% idle sleeps are the case to watch.
- Loop share falls (repeats show as `repeat` under while asleep); Opus's and Sonnet's 75-94% loops should drop.
- No `never waited` sleeps (Luna's `fh call sleep`).
- No sleep past the deadline (Opus made 308 requests after it in shake6, a backgrounded loop) and fewer requests after
  the deadline overall. Final summaries in `notes.md` should be written after the deadline: check each notes.md's
  modification time against deadline.txt, and that the minutes before the deadline are not asleep.
- Asleep share overall: not a target. It falls only where agents were waiting for something the tools can now wait
  for; Opus's approver role and Haiku's chore timers are dispositions the study found, not tool gaps.

## Verification

- `tests/sleep.lua` (new, through the runtime): while_asleep for idle, a direct walk, a running queue (incl.
  repeating) and a paused queue; queue_done with queue_steps; queue_stalled on a failed step and on a move_to whose
  path never comes back; item_count in the inventory and over chests (also accepted by a wait_until queue step);
  researched with and without a technology; already met; a mention still wins; bad conditions refused.
- `tests/waits.lua`: the repeat (3 times, within 10 s, not after elapsed, not in turns mode, not on a peek).
- `tests/waits.test.ts`: `--until` forms and errors, `fh call sleep` with and without `--wait` blocks, the deadline
  (none after it, cut before it). `tools/test_supervise.py`: the summary request after the deadline.
- `npm test`: 103 pass; the 4 bridge tests fail as before (the sandbox refuses a listening socket). Lua suites, locals
  guard and stream selftests pass.
- Not live: the box runs shake7 until about 17:30 and was off limits, so nothing was deployed.
