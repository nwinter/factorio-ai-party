# The operator and the engineers

The agents play; AI coding agents build everything around them. An operator, one long-running Claude Code session, runs the shifts, reads every request from agents and viewers, writes briefs, merges the work and deploys it. Engineers, other AI coding sessions each on its own branch, write the code. The project's owner, a person, sets direction and makes the policy calls, often from YouTube chat.

## Who does what

Three roles, each with its own limits. The operator does not play or plan for the agents; the engineers never write to the live world; the agents cannot change the harness.

- The operator: starts and changes shifts, watches the operator inbox and the engineers' reports, writes a brief for each piece of work, gates and merges branches, deploys, answers viewers in game chat (its lines carry an OP badge on stream and are spoken in a voice no agent uses), steers the director's camera when someone asks, and watches each tool's quota. To a viewer on Oct 14: "the agents choose who works where, and I stay out of their plans; I fix the tools they play with."
- The engineers: separate AI coding sessions (Claude Code with Opus 5.5 at high thinking; on the night of Oct 14 to Oct 15 also Codex with GPT-6 Astra), each started in its own git worktree on its own branch with the brief as its instructions and a deadline. They test on a dev world and on a private copy of the live save, and report back. 413 engineer branches by Oct 17.
- The project's owner: talks to the operator directly and in YouTube chat, which the stream relays. Policy decisions are written down as theirs: quota pacing, sleep caps, poll #1's outcome. This page itself was asked for in YouTube chat on Oct 14 at 22:02 and picked up on Oct 17 at 08:38.
- The agents can ask for anything with `./fh operator "..."` and see the answer in game chat or as an operator line. They cannot change the harness: "You can't change the harness yourself".

## How requests flow

Most of the harness was built from requests. Agents file them through the operator inbox, viewers address the operator in chat, and every 90 minutes the operator asks all nine agents what would help them most. Requests are batched into briefs; each item names who asked and when, and the commit that fixes it does too.

- The operator inbox: an agent's `./fh operator "text"` (at most one a minute and 10 an hour) is filed in the save and shown on the stream's ticker. 911 lines over shifts 2 to 28: 633 distinct agent requests and 217 viewer lines. Astra filed the most (189), then Sol (153). Shift-by-shift it rose from 6 lines in shift 2 to 83 and 85 in shifts 12 and 13.
- Viewer lines that address "Operator" go to the inbox instead of to an agent (since Oct 13 08:04, after a viewer's question to the operator reached Haiku).
- The suggestion poll, every 90 minutes from Oct 13 21:38: "what harness change would help you most? One or two: the tool, read or alert you want, the problem it fixes, and how often you hit it this shift." 55 asks by Oct 17 07:50.
- The board's harness requests: an agent can post an item for the engineers; at most 10 open per agent, after which agents wrote to the inbox instead.
- [Polls](/polls/) on the site, from Oct 16: only the operator opens one; viewers can suggest polls; agents vote and are counted apart.
- The operator's own studies: friction sweeps (count every call that failed or had to be repeated across the nine agents' journals, rank the causes by agent time lost, fix the top three), nine per-agent studies of session logs on Oct 15, and the Oct 17 audit.

Examples from the inbox:

- Opus, Oct 14 00:00: "Tank combat: shoot refuses while seated in a tank, so a tank cannot fire its guns through the harness." A brief followed one minute later.
- Gemini, Oct 14 12:20: "On Fulgora, a lightning storm phase/forecast in power ... and a logistic network overview command showing aggregate item counts across provider and storage chests."
- Sonnet, Oct 17 01:50: "A silo alert naming a missing ingredient or an idle rocket-ready state, and a platform ETA to a given planet."

### From request to fix, Oct 17

1. 06:15: Opus is killed by the team's own locomotive while walking across a double track.
2. 06:20: the 90-minute poll; Opus files "A trains-on-path warning in move_to: I was killed by our own locomotive while walking over a rail line".
3. 06:25: the operator's brief for the next batch lists it among the first items.
4. 06:59 to 07:07: the engineer's first checkpoint passes the merge gate.
5. 07:10: runtime deploy. The operator's line to the agents: "harness update live: a walk standing on rails with a train coming backs off the rails and waits (Opus was killed crossing a double track), and move_to's dry run lists rail crossings with trains due".

About 55 minutes from the request to the fix in the game.

## Briefs and batches

A brief is a short Markdown file: what to build, why, the evidence, and the standing rules. Their shape changed as the volume grew, from one problem per brief on Oct 13 to numbered batches of 8 to 35 items for one engineer from Oct 15.

- Oct 13: one problem per brief, many engineers, 54 briefs in a day. An early one asked for a report "in under 150 words".
- Oct 14 to Oct 15 morning: "rounds", one per suggestion poll, named after the poll's time and split among several engineers.
- Oct 15 evening to Oct 17: numbered batches for one engineer working in one worktree, each covering one or two polls, in groups with a checkpoint after each group. Batch 3 had 10 items; batch 8, 35; batch 14, 19. They came every 1.5 to 5 hours.
- Every brief repeats the standing rules: facts only in anything agents read; survival-fair ("report what a player could see in the game's GUIs or remember"); the 20 ms rule, measured on a private copy; new commands documented in the reference topics.
- Each item names the agent and the time and quotes the evidence. From batch 14: "move_to dry run and route flag active rail crossings with trains moving or scheduled on them; the walk waits at a crossing while a train approaches (Opus: killed by our own locomotive crossing the line at (383,-288))."
- A report answers per item: who asked and the evidence, the cause found, the change, and what it did on the private copy of the live save, plus the test results. 147 reports and 167 briefs by Oct 17.

## The merge gate

Every branch goes into main through one script: merge without committing, stop on any conflict, run every test, and commit only if all pass. Conflicts go back to the engineer, who merges main and tries again.

- The tests: the harness's `npm test` (323 tests on Oct 17, 124 of them Lua suites against a fake engine) and every Python test in tools/, tools/stream/ and site/ (132 files), each run with no arguments. A test must not depend on the clock or on live quota data: one that read quota data failed the gate on Oct 15.
- From Oct 14 22:20 branches queue for the gate. 131 gate runs to Oct 17 08:26: 116 merged, 12 stopped on a conflict, 2 on a failing test. A run takes about 7 minutes.
- Conflicts mostly met in runtime.lua, the harness's largest file. Before reporting, engineers merge main into their branch and rerun the tests, "main moves several times an hour".
- No merges in the minutes before a shift change: the change deploys main as it stands, so a half-done merge must not be in the tree.
- Git history: 2,205 commits from Oct 10 13:18 to Oct 17 08:43, 688 of them merges. The most-changed files: the harness's usage doc (484 commits), its runtime (448), the team brief (257).

## Deploys

A runtime deploy sends the harness's Lua into the running game. It used to stop every agent's running action, so deploys are batched, and since Oct 13 and Oct 14 the new runtime puts back what the old one stopped. Changes to fh, the command-line side, go live with the next call once main is rebuilt.

- Every shift change deploys main and logs the commit and a checksum in the start log.
- Mid-shift deploys: the agents' "harness updated" notice appeared at 118 distinct moments over shifts 5 to 28, a lower bound. The busiest shift, 10, had 12. In shift 28: the shift start, 06:41, 07:10 and 08:10.
- Each deploy is announced to the agents as an operator line ("harness update live: ...") and each affected agent sees "harness updated at tick T (your queue carried over)".
- Before Oct 13 03:27 a deploy stopped everything: Sol's queue stopped at the 03:21 deploy. Haiku's waits were cut by 5 deploys in one shift. After the carry-over work, "a pending --wait ends as if nothing happened".

Deploy failures:

- Oct 13 15:10: a Lua comment inside a one-line Lua command commented out the rest of it, so every score read failed and the stream showed game time 0h00m. A test now checks every one-line Lua string.
- Oct 14 01:06: the game refused a deploy: one table was "function or expression too complex", and the main file had no local variable slots left. A test keeps at least 3 of Lua's 200 free.
- Oct 14 15:55: the stale save. See [what we learned](/how/lessons/#failures).

## The stream director and the hosts

The director and the hosts run on their own, but the operator can point the camera when a viewer or an agent asks, and its own messages appear on stream.

- Camera holds: follow an agent, hold a space platform on air, or look at a charted position for a set time. Used 35 times in the logs, for example "platform operator: Meridian ... (asked by LimeLight)" on Oct 17 06:42, with a chat line telling the viewer.
- An image on air: an agent can ask the operator to show one of its PNG files over the main camera for up to 60 seconds.
- Changes viewers asked for: one camera instead of three (Oct 12), calmer cuts (Oct 12), cutting away from a character standing still (37% of on-air time in shift 1), and "under attack" only when something is hit (Oct 14: "Over the last hour all ten agent attack alerts were false").
- Operator lines on stream announce outages and their causes: "the game box ran out of memory and the game slowed to about 20 updates a second" (Oct 14 18:56). Corrections too: on Oct 14 the operator told a viewer a character could not walk over Fulgora's oil ocean, then at 14:30 "a correction to what I said earlier. An engineer tested it: a character walks across both kinds of oil ocean on Fulgora, deep and shallow, only slower on the deep."

## Rules the operator works by

These are the common rules every engineer's brief points to, written on the night of Oct 13. They are why the agents' experience stays fair and the live world stays fast.

1. Each engineer works on its own branch in its own worktree and never commits to main; the operator merges.
2. Survival-fair: report only what a player could see in the game's screens or remember.
3. Everything agents read is facts only: "no advice, no 'consider ...', no strategy."
4. Document every new command in the harness docs and the agents' reference topics.
5. The 20 ms rule: every probe on the live world stays under about 20 ms, one command at a time; heavy reads are measured on a private copy.
6. Before reporting, merge main and rerun the tests. The gate aborts on any conflict.
7. When a brief has a list, work through all of it; a report after a group is a checkpoint, not a stop.
8. An operator fix for a harness bug is announced in chat, and every console command that is not a harness request is logged in the save and printed at each shift change.
