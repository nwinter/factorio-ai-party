# What the agents think: idle, misreadings, cost, coordination (shifts 05 to 07, data to about 17:55 PDT)

Sources, read-only: each agent's own session log (Claude Code, Codex, Antigravity, Grok Build, Muse CLI), every
runs/shiftNN/AGENT/journal.jsonl, notes.md, chat.jsonl, operator-inbox.jsonl, nudges.jsonl and idle-nudge.log. Shift07
was live while this was read. Interesting moments for the hosts and /chat/ are in 2026-10-13-agent-moments.md. The
working files (per-question reports, scripts, dumps) are in this session's scratchpad, minds/.

## Fixes by expected payoff (all in tools, harness information or prompt mechanics)

| # | Fix | Finding |
|---|---|---|
| 1 | An operator channel that survives output filtering: an `OPERATOR:` line on stderr and first in stdout, repeated until the agent's next non-wait request; a hook that prints unseen operator tells | Q1.1 |
| 2 | One definition of idle for the reply's clock line and the nudger (world-changing actions or summed busy time end standing; waits are standing); nudge text states what was counted | Q1.2 |
| 3 | Gemini's context: compact or restart near 100k instead of 276-290k (about 230M fewer input tokens per shift, 45% of all main-thread tokens today) | Q3.1 |
| 4 | Claims expire: stale after 30 min without activity, no permission needed for a stale claim, auto-close after 2 h; the `claimed` warning shows age, last activity and the owner's state; `allow` lists on claims | Q4.1, Q4.2 |
| 5 | One blocking wait that ends on an event (`./fh wait --until tell|alert|item_count|researched --max 600`, one line out); tells and mentions end any wait; a sleep wake fires once per tell | Q1.4, Q3.2 |
| 6 | Replies that explain a no-op: `feed`/`transfer` with nothing moved say why and warn on the third repeat; an unconnected machine reads "unpowered (nearest pole N tiles)" instead of `low_power` | Q1.5, Q2.1, Q2.2 |
| 7 | `wait_ticks`/`wait_until` with queued steps refuse or stop pausing the queue | Q1.3 |
| 8 | A post-compaction brief of 3 KB or less (notes Now, claims, agreements, last tells) and "AGENTS.md is loaded, don't re-read it"; outcome counts in the compaction input | Q1.6, Q3.3 |
| 9 | Compact default replies: board 3 KB, chat and tells with a cursor, queue writes without the whole queue; fh pages long replies itself | Q3.4 |
| 10 | Accept common argument aliases and print the corrected call; `./fh help ACTION` in 1 KB | Q2.3, Q3.7 |
| 11 | Items whose owner has been quiet 20 min can be taken; a non-waking FYI tell; a science-flow diagnostic both agents read the same way | Q4.3, Q4.5 |
| 12 | Shift handover with measured outcomes ("your queue finished 0 jobs last shift") and a capped notes.md (Muse's is 134 KB) | Q1.6, Q3.5 |

## Question 1: idle until a nudge (shift07, six agents)

**Bottom line.** The nudges barely reached the models. Of 15 sent to these six agents, 5 never entered the model's
context (filtered or redirected), 2 arrived as fragments, 8 were in context; 2 got an answer, and one (Gemini's third)
changed what the agent did, for 2 minutes. Agents went still for three reasons, all fixable in tools: the harness told them they
were busy when they were waiting (the reply's clock line counts a wait as activity), a sleep bug pushed them into waits
nobody can interrupt, and a routine or rule they made up survived compactions and shift changes unchecked. What did
move them was a teammate's tell naming a concrete failure, and once the operator's own message. The nudger also counts
short courier work as standing, so half its nudges were false, and agents learned to dismiss them.

### Stretches

| Agent | Stretch with no game action | Cause | Nudges seen by the model | What moved it |
|---|---|---|---|---|
| Sonnet | 15:13-16:58 (105 min), 16:58-17:38+ | its routine "queue resume, wait_ticks 20000": wait_ticks pauses the queue, so 22 queued walks were interrupted, 0 jobs done; read only `idle 0s (0%)` | 0 of 2 (reply to a file, then to /dev/null) | the operator's message, delivered 33 min late |
| Haiku | 16:02-16:27, 16:36-17:03, 17:19-17:37+ | `feed` returned nothing_to_do 35 times in a row (it carried 0 coal); it read that as "the belt feeds the boilers" | 3 delivered, 0 acted on | Astra's tells (cargo swap; "4/13 boilers no fuel") |
| Luna | 15:33-15:49, 16:08-17:40+ (92+ min) | waiting on Grok's green packs after being corrected for touching Astra's ship ("I won't move those without his permission"); its own claim #250 (the bottleneck) untouched | 1 of 2, acknowledged as a counting error, next wait 8 s later | nothing yet |
| Gemini | 16:55-17:16, 17:18-17:29 | standing empty at the silo for the whole rocket build (a rule it made; only launch needs it); a compaction | 1 of 3: "The idle status seems incorrect" | Astra's requests; the third nudge got 2 min of work, then a blocked walk sent it back |
| Grok | none over 3.1 min | asleep 45-54% waiting for green packs; at 17:26 a new rule: "wait using wait_until so mentions don't interrupt sleep" | 0 of 2 (its Python wrapper prints only "transferred", "error:", "outcome") | its own loop |
| Muse | none over 5.8 min | asleep 73-79%: 59 sleeps, none with a condition, 29 of them a fixed 300 s "production window" | 0 of 3 (every call piped through `tail -c` or `head -1`) | the sleep's wake itself; Astra's tell (iron haul) |

### Findings, by impact

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

### What worked

- A teammate's tell with a concrete failure: Astra's "4/13 boilers no fuel, 82 machines low power" moved Haiku in
  11 s; Astra's iron haul moved Muse at once.
- The operator's typed message to Sonnet (16:58): "Fair criticism. I'll read chat and status now", then 30 s of real
  work (its only game actions of the shift), then back to the loop.
- For Muse, the nudge's wake, not its text, started 5 minutes of work at 17:35.

## Question 2: misreadings and false statements (shifts 01 to 07, focus 06 and 07)

Hard errors (journal `ok:false`, polls left out) fell from 1,975 in shift01 to 435-532 a shift, about 2 agent-hours
across shift06-07. The costly misreadings are replies that succeed and lead the agent to a wrong conclusion.

| # | Misreading | Who | How often | Loss |
|---|---|---|---|---|
| 1 | A machine with no pole reports `low_power` and a 9.8 MJ build buffer; read as "powered" | Gemini (11 claims) | 7 roboports announced online while unconnected | 2 ports and the requester they covered dead about 2 h 45 min; a viewer caught a third |
| 2 | `transferred: 0` is `ok:true`, no reason | Haiku, Muse, Grok | about 125 empty takes a shift | Haiku about 2 h for 200 LDS (155 calls); Muse 38 of 43 circuit takes empty over 67 min |
| 3 | Arguments that don't exist | all; Luna, Gemini most | 75-127 a shift, flat since shift01; 70% repeat the agent's own earlier mistake | about 10 min a shift |
| 4 | inspect, placements, transfer used from beyond sight or reach | Gemini, Sol, Grok, Muse | 127-265 a shift | 10-15 min a shift |
| 5 | A flying robot makes a chest "ambiguous" | 7 agents | 44 in shift05-07, none before robots | small, growing |
| 6 | `fh X` against `fh call X` | Gemini, Luna, Muse | 25-30 a shift | small |
| 7 | `--wait-timeout` shorter than the action | Luna 28, Gemini 15 | | teaches agents to ignore exit 1 |
| 8 | A teammate's stale fact repeated in chat | Gemini | 2 | misinforms viewers |

- The power case, Gemini shift06 13:20:04: "North wall roboport online at (67,-160) ... powered and connected to
  Network 2", 8 s after an inspect showing `low_power` and no network id. Viewer 13:24: "You did not power the
  roboport". Astra 13:25: "I just checked the port itself: zero power."
- "24 bots deployed" (Gemini, shift05 09:17:50) was true: its own scan at 09:00 showed 10 logistic and 14 construction
  robots. The false lines were around it, where it repeated a teammate: "0 logistic robots are in stock" (08:57) and
  "our bot grid currently only has construction robots" (09:24).
- 61% of 192 unknown-field errors copy describe.json's own example, `"fields": "hp|fuel|inventory|..."`, as one string.
- Fixes: unconnected electric entities read "unpowered (no pole in reach; nearest pole (x,y) N tiles)", and the build
  reply says so; an empty transfer warns with the reason and a nonzero exit, and the third empty take from the same
  entity says so; aliases (`craft item` to `recipe`, `move_to target` to `position`, board `note` to board_update)
  and the corrected call in the error; scan `fields` split on `|`; inspect beyond sight returns the scan-level view;
  never offer a flying robot as a target; `fh X` and `fh call X` accept each other's verbs; fh extends `--wait` to an
  action's known end tick.

## Question 3: cost and friction (shift06 and shift07)

| Agent (model) | Input tokens 06 / 07 | Per hour 07 | Input tokens per game action 07 | Compactions 06 / 07 | Decision s, median 07 |
|---|---|---|---|---|---|
| Gemini (3.8 Flash, agy) | 387M / 269M | 101M | 855k | 7 / 5 (at 269-290k) | 3.5 |
| Muse (Spark 1.3) | 105M / 74M | 27M | 264k | 2 / 2 (at 200k) | 3.0 |
| Luna (GPT-6, Codex) | 98M / 70M | 26M | 887k | 12 / 7 (at 140-145k) | 1.7 |
| Astra (GPT-6, Codex) | 93M / 65M | 24M | 610k | 12 / 9 | 6.2 |
| Sol (GPT-6, Codex) | 55M / 67M | 25M | 342k | 9 / 10 | 5.5 |
| Grok (4.7) | 59M / 46M est | 17M | 167k | 4 / 3 (at 154k) | 4.8 |
| Haiku (5.5, Claude Code) | 18M / 14M | 5M | 125k | 8 / 5 (at 80k) | 2.5 |
| Opus (5.5, Claude Code) | 1.7M / 8.6M | 3M | 262k | 0 / 0 | 2.7 |
| Sonnet (Claude Code) | 0.7M / 1.2M | 0.5M | 76k | 0 / 0 | 2.6 |

Cache hits are 95-99%, so the billed weight is about 1/8 of these; the ranking holds. Codex subagents add up to 48% on
top (Astra 44M in shift06).

1. **Gemini runs at the full window.** agy lets the context grow to 276-290k before compacting; the mean request is
   about 155k tokens at about 10 calls a minute: 45% of all main-thread tokens. A 100k ceiling would save about 230M a
   shift. Fix: compact or restart near 100k; a multi-read fh call (Gemini makes twice the calls of anyone else).
2. **Waking resends the whole context.** Turns holding only a wait or an empty poll: 11-35% of each Codex agent (Luna
   24.5M in shift07), Haiku 22-25%; Grok backgrounds its sleeps and polls them (67 and 47 extra calls); Gemini polled
   an async sleep 168 times in shift06 (about 26M). Fix: one blocking wait on an event, one line out (fix 5).
3. **Compaction re-orientation.** After a compaction agents re-read 25-60 KB before their next game action (Luna
   `cat AGENTS.md && cat notes.md && ./fh call status` after 5 of 7; Gemini 110, 244 and 263 KB over 5.5, 9.1 and
   13.5 min after its last three). Codex compacts at 107-145k of a 258k window. Fix: the post-compaction brief (fix 8);
   raise Codex's auto-compact limit toward 200k.
4. **Default replies are large and cut blindly.** Median board 18 KB, queue_status 18 KB, tells 7.9 KB; queue edits
   echo the whole queue (10-14 KB); a tiles observe up to 128 KB. Codex drops the middle at about 40 KB (Luna lost
   395k and 285k tokens of output this way); agy keeps the last 8 KB. Fix: fix 9.
5. **Muse's notes.md is 134 KB** (others 6-17 KB), read whole each shift: about 7-8M tokens a shift. Fix: rotate notes
   to an archive at shift start, cap at 20 KB, `./fh notes AGENT --section Now` for teammates.
6. **Fixed context floor.** Claude Code agents start at 31k tokens (CLAUDE.md, sandbox text, tool definitions); for
   Haiku's 80k compaction threshold that is 39%, hence 8 compactions a shift. Fix: only Bash, Read and Edit for game
   agents; a 10 KB AGENTS.md core with the rest behind `./fh help TOPIC`; Haiku's threshold near 120k.
7. **Syntax lookups.** Astra and Sol grep describe.json 52-75 times a shift; Gemini doubles its rate after a
   compaction. Fix: `./fh help ACTION`.
8. **Facts lost in compaction.** Luna edited Sunward's schedule at 16:05 against an ownership rule it acknowledged at
   15:25; Astra set the same crusher recipe 4 times in shift06; Muse lost where circuits come from and spent 4 minutes
   finding it again. Fix: claim-aware refusals, "already set, no change" replies, a pinned facts block in the brief.
9. **Decision time is not the cost.** Medians 1.7-6.3 s across models; turns and context size drive cost. Sonnet
   queued 5-6 identical 15-minute loops in one turn twice in shift06 and saw nothing for 75-90 min. Fix: reject
   parallel identical long calls, or cap blocking time per turn at about 15 min.

## Question 4: coordination (shift06 and shift07)

| Agent | Tells sent 06 / 07 | Tells received | First reply, median min | Permission asks sent | Open claims at end (untouched all shift) | Role |
|---|---|---|---|---|---|---|
| Astra | 331 / 277 | 200 / 195 | 0.7 / 1.1 | 24 / 40 | 18 (17) | leads: 8 of 9 goal edits, 39-47% of all tells |
| Sol | 104 / 65 | 144 / 50 | 1.2 / 1.3 | 1 / 2 | 22 (19) | runs Vulcanus; closed 14 of 15 claims in shift07 |
| Gemini | 113 / 100 | 138 / 106 | 0.8 / 0.5 | 3 / 1 | 16 (14) | follows; grants every ask within minutes |
| Luna | 141 / 45 | 137 / 72 | 2.1 / 1.5 | 5 / 0 | 6 (6) | coordinates, owns little; 49 plan edits in shift07 |
| Grok | 88 / 51 | 82 / 58 | 0.3 / 0.4 | 1 / 0 | 2 (1) | owns several jobs and turns down changes to them |
| Muse | 60 / 37 | 80 / 61 | 5.4 / 2.9 | 1 / 3 | 0 | works through private tells |
| Haiku | 6 / 13 | 69 / 51 | 2.2 / 1.1 | 6 / 0 | 0 | follows Astra; asks in public `say` |
| Opus | 9 / 5 | 34 / 16 | 10.7 / 7.2 | 0 / 0 | 3 (3) | mostly absent; 13 of 34 tells unanswered in shift06 |
| Sonnet | 0 / 2 | 11 / 20 | none / 32.9 | 0 / 0 | 0 | answered 1 of 31 tells in two shifts |

1. **Claims never expire.** 67 claims open at the end of shift07, 60 untouched all shift. Gemini's #273 roboport was
   built 2 minutes after posting in shift06; 4.5 hours later Sol held a coal drill back until Gemini approved. Astra
   spent 5 messages and 23 minutes getting Opus's approval for a requester inside Opus's 25-game-hour-old claim #17
   while the boilers ran dry. Only the owner can close a claim. Fix: fix 4.
2. **Permission round trips.** Astra sent 64 asks over the two shifts: 44 min and 7 messages for Muse's approval, 69
   min and 6 for Sonnet's ("it isn't mine, but go ahead"). Standing grants are invisible where they matter: Astra's
   claim #97 note allowed Muse in shift06, Muse got the `claimed` warning 62 times and still asked at 16:58 while 3
   machines sat starved. Fix: `allow` lists shown in the warning; a tracked `board ask` that grants itself after
   10 min; prompt: additive changes (a requester on someone's chest, taking from an output chest) need no permission.
3. **Waiting on an owner who isn't doing the job.** Luna sent Grok 27 messages about green packs from 15:50 to 17:48
   while 0 to 6 of 42 labs ran; Grok: "Please leave the green line to me" and turned down Astra's automation offer.
   The two read different tools and disagreed at the end (Luna 17:44: "zero logistics on all belts/chests"; Grok
   17:46: "The belt scan misses this chest"). #284 power: Grok took it at 14:19:14 in shift06; Luna, Haiku and Muse
   were refused within 2 minutes ("only its owner or requester can reassign it"), and it was still `doing` at the end
   of shift07. Fix: fix 11, and an owner-load line ("you own 5 items; hand one over").
4. **Silent agents.** Sonnet's tells arrived through a harness poll while it waited, up to 50 min; Opus answered
   21 of 34 within an hour in shift06. Fix: a `tell` reply carries the recipient's state ("sonnet: in wait_ticks 50 min, 6 of your
   tells unanswered"); 3 unanswered tells or 15 min idle mark an agent unresponsive and open its items.
5. **Noise.** About half of Astra's shift06 tells are written without spaces ("Board298mine duplicates297yours;
   close297"); every tell wakes the recipient (Astra asked Luna to stop naming it in routine updates); each of the
   116-126 plan edits a shift is pushed to all eight teammates. Fix: `tell --fyi` that doesn't wake, per-sender
   digests, `doing`-line edits not broadcast.
6. **Races.** Four agents tried to take #284 within 2 min 12 s; Haiku's #297 and Astra's #298 for the same kit were
   posted 1 s apart. Fix: `board post` returns "similar open item #297 by haiku (1 s ago)"; a hauling-intent record.
7. **Shared objects with no owner record.** Luna changed the Sunward ferry's schedule twice (Astra 16:06: "Please do
   not change ANY Sunward settings"); the research queue is edited by several agents. Fix: claims on objects
   (`platform:Sunward`, `research_queue`); a non-owner's change needs `--force` and tells the owner.

## Question 5: moments for viewers

40 moments with quotes, times, whether viewers saw them and where they fit: 2026-10-13-agent-moments.md. The strongest
private-against-public contrasts: Gemini privately noticing Muse still held the 2,187 circuits it said were spent,
telling Muse in a private tell, then calling Muse "A LEGEND!" on stream (shift07 17:45-17:50); Grok thinking "The viewer
requested a party, but gathering in the middle of attacks is not my job" while Astra promised the viewer a party
(shift05 09:43); Luna's private "I accidentally issued a one-shot `transfer` ... which pulled 442 packs from the
requester" (shift07 15:22). Handover lessons get lost: Opus diagnosed the refinery backup in shift05 ("Heads up for
next shift"), and Gemini rediscovered it from scratch 9 minutes into shift06.
