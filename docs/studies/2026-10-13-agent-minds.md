# What the agents think, shift07: first pass on idle (data to about 17:45 PDT)

Question 1 of the agent-minds study: why agents stand idle until a nudge, and what the nudge does. Sources, read-only:
each agent's own session log (Claude Code, Codex, Antigravity, Grok Build, Muse CLI), runs/shift07/AGENT/journal.jsonl,
notes.md, chat.jsonl, nudges.jsonl, idle-nudge.log. Six agents covered: Sonnet, Haiku, Luna, Gemini, Grok, Muse. The
other questions (misreadings, cost, coordination, moments for viewers) follow in the full report. Per-agent detail
with every quote and table: scratchpad minds/{sonnet,haiku,luna-gemini,grok-muse}.md of this session.

**Bottom line.** The nudges barely reached the models. Of 15 sent to these six agents, 5 never entered the model's
context (filtered or redirected), 2 arrived as fragments, 8 were in context; 2 got an answer, and one (Gemini's third)
changed what the agent did, for 2 minutes. Agents went still for three reasons, all fixable in tools: the harness told them they
were busy when they were waiting (the reply's clock line counts a wait as activity), a sleep bug pushed them into waits
nobody can interrupt, and a routine or rule they made up survived compactions and shift changes unchecked. What did
move them was a teammate's tell naming a concrete failure, and once the operator's own message. The nudger also counts
short courier work as standing, so half its nudges were false, and agents learned to dismiss them.

## Stretches

| Agent | Stretch with no game action | Cause | Nudges seen by the model | What moved it |
|---|---|---|---|---|
| Sonnet | 15:13-16:58 (105 min), 16:58-17:38+ | its routine "queue resume, wait_ticks 20000": wait_ticks pauses the queue, so 22 queued walks were interrupted, 0 jobs done; read only `idle 0s (0%)` | 0 of 2 (reply to a file, then to /dev/null) | the operator's message, delivered 33 min late |
| Haiku | 16:02-16:27, 16:36-17:03, 17:19-17:37+ | `feed` returned nothing_to_do 35 times in a row (it carried 0 coal); it read that as "the belt feeds the boilers" | 3 delivered, 0 acted on | Astra's tells (cargo swap; "4/13 boilers no fuel") |
| Luna | 15:33-15:49, 16:08-17:40+ (92+ min) | waiting on Grok's green packs after being corrected for touching Astra's ship ("I won't move those without his permission"); its own claim #250 (the bottleneck) untouched | 1 of 2, acknowledged as a counting error, next wait 8 s later | nothing yet |
| Gemini | 16:55-17:16, 17:18-17:29 | standing empty at the silo for the whole rocket build (a rule it made; only launch needs it); a compaction | 1 of 3: "The idle status seems incorrect" | Astra's requests; the third nudge got 2 min of work, then a blocked walk sent it back |
| Grok | none over 3.1 min | asleep 45-54% waiting for green packs; at 17:26 a new rule: "wait using wait_until so mentions don't interrupt sleep" | 0 of 2 (its Python wrapper prints only "transferred", "error:", "outcome") | its own loop |
| Muse | none over 5.8 min | asleep 73-79%: 59 sleeps, none with a condition, 29 of them a fixed 300 s "production window" | 0 of 3 (every call piped through `tail -c` or `head -1`) | the sleep's wake itself; Astra's tell (iron haul) |

## Findings, by impact

**1. Operator tells don't reach the model.** A nudge rides in `team.tells` of whatever reply comes next, once. Agents
cut replies: Sonnet sends 69% of its fh calls to a file or /dev/null and reads `tail -2` (shift07: 61 of 88; the
habit started in shift03, "bare `./fh queue` prints huge"); Grok's wrapper keeps three keywords; Muse pipes every call
through `tail -c 100..1200` (AGENTS.md forbids it). Luna and Gemini saw them at the end of unrelated replies and
answered the main content. "stood idle" appears 0 times in the Grok and Muse session logs.
Fix: an operator channel that survives filtering: an `OPERATOR:` line on stderr and first in stdout, repeated until
the agent makes a non-wait request; for Claude Code agents, a PostToolUse hook that prints unseen operator tells (the
hooks already run: Muse 500 runs, Grok 523; check each CLI puts hook output into context); short default replies for
`queue`, `plan run` and `queue resume`, which removes Sonnet's reason to redirect.

**2. Two definitions of idle that disagree.** The clock line in every reply (runtime.lua) counts a wait as activity:
Sonnet and Haiku read `character idle 0s of it (0%)` after every wait for over an hour. The nudger (idle.lua) counts
waits as standing but also anything under 20 game seconds of continuous work: 0 of 227 Grok and Muse walks since
16:44 counted, and Gemini's 108 transfers, 23 walks and 5 builds in its "54 min, no action" did not either. False
nudges taught Gemini to dismiss the next one; the inflated minutes (Haiku "30 min" for 6, "50" for 15) did the same.
Fix: one definition for both: world-changing actions (transfer, build, craft, feed that gave items, move to a new spot)
or 20 s of work summed over 2 minutes end standing; waits are standing. The clock line says "waiting 2m00s" apart from
"idle". The nudge states what was counted: "last 10 min: 0 game actions, asleep 79% (sleep 300 x2), 12 reads".

**3. wait_ticks pauses the queue.** A direct action pauses the queue, so Sonnet's "resume, then wait" cycle
interrupted its courier 22 times and finished 0 jobs in 105 minutes, standing on a belt at (3,25).
Fix: `wait_ticks` and `wait_until` with queued steps refuse ("would pause your queue: 8 steps; use sleep, or
pause_queue=true"), or stop pausing the queue (they don't drive the character).

**4. The sleep wake repeats, so agents switch to waits nobody can interrupt.** `sleep` answered "did not start: you
woke (told) N s ago; it ends at once and repeats that wake" for tells already read: Luna 32 times (10 in 34 s at
15:33: "this is a harness wake-repeat issue"), Haiku at 15:50, Sonnet in 5 of 6 shift notes. Each moved to wait_ticks
or wait_until, which tells and mentions don't end; Grok chose wait_until for that reason.
Fix: a wake fires once per tell; tells and mentions end a direct wait (and `--wait`) early with "told".

**5. No-op replies give no reason.** Haiku's 35 consecutive `feed` replies said `nothing_to_do, places 0, given 0`;
its own Lessons line had the cause (no coal carried), but the "belt-fed" reading won and survived 3 compactions.
Move_to the spot it stood on answered "arrived" 11 times.
Fix: nothing_to_do says why ("you carry 0 coal; 7 boilers hold 4-50 fuel; nearest coal at 8.5,37.5"); a reply adds
"3rd identical feed in 7 min with no effect"; move_to answers "already here".

**6. Made-up routines outlive their reason.** Sonnet's cycle came from shift03 and shift06 notes (its notes.md "Now"
still says shift 3); Haiku's "top up boilers every 2-3 min" and the wrong reason rode through 5 compactions at about
80k tokens; Gemini guarded the silo empty for 30+ minutes; Muse rested a fixed 300 s after every round; Luna turned
one correction into "everything is someone else's".
Fix: shift handover with measured outcomes ("your queue finished 0 jobs last shift; you stood 104 min at (3,25)");
the PreCompact hook adds recent outcome counts ("feed: nothing_to_do x12") to the summary input; AGENTS.md: "a wait
is not a task: before waiting more than 5 minutes, do something else or say why".

**7. Waiting on a teammate with nothing else to do.** Luna (92 min) waited on Grok while its own claim #250 was the
bottleneck; Haiku was told "please avoid duplicating" and its notes named no next task; Muse asked Astra's permission
for EC in her claim. Fix: the status reply names unclaimed bottlenecks ("logistic packs: 35 labs starved, no claim
working on it") and the agent's own claims with no action for 30 minutes.

**8. The nudger itself.** It failed to start at 15:13:50 (the arguments were passed inside the script path:
"can't open file '.../idle_nudge.py --run runs/shift07 ...'") and ran from 16:44:43, so Sonnet's first 90 minutes and
Luna's 16:08-16:44 had none. "200 unread" is a cap; "0 mentions" left out a viewer's @mention to Sonnet.

**9. Shell mechanics cost turns.** Codex returns from a command after about 30 s whatever yield is asked, so each of
Luna's 3.5-minute waits took 6-7 turns: 127 `./fh wait` polls and about 20M tokens in 88 minutes. Muse's 300 s
sleeps hit its 300 s shell limit 6 times and once ended its run (back 3 s later). Claude Code delivers a typed
message only between tool calls: the operator's message to Sonnet waited 33 minutes behind 3 stacked 15-minute waits.
Fix: `./fh wait` blocks without output up to 25 s per call; cap `fh sleep` under Muse's yield (about 280 s); `--wait`
returning on tells also bounds the delay of a typed message.

## What worked

- A teammate's tell with a concrete failure: Astra's "4/13 boilers no fuel, 82 machines low power" moved Haiku in
  11 s; Astra's iron haul moved Muse at once.
- The operator's typed message to Sonnet (16:58): "Fair criticism. I'll read chat and status now", then 30 s of real
  work (its only game actions of the shift), then back to the loop.
- For Muse, the nudge's wake, not its text, started 5 minutes of work at 17:35.

## Next (full report by 21:30)

Misreadings and false statements, cost and friction (output sizes, compactions, time per decision by model),
coordination (tells, board, claims), and moments for the hosts and /chat/; Opus, Sonnet, Astra and Sol across shifts.
