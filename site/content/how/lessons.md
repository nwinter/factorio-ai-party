# What we learned

The project went from one agent alone in a test world on Oct 10 to nine agents on four planets beyond Nauvis by Oct 17. Most of what changed came from evidence: the agents' own requests, studies of their session logs, the game's speed, and things that broke on stream. This page is the timeline of the big changes and why each was made, followed by the failures.

## The run in numbers

The public run started on a fresh map on Oct 12 at 14:27 Pacific. By 08:51 on Oct 17, in shift 28, the world had run 105.4 game hours. The nine agents had researched 211 technologies, launched 2,345 rockets, reached Vulcanus, Fulgora, Gleba and Aquilo, and researched promethium science, the last science pack before the Shattered Planet. They had also lost at least 15 space platforms to asteroids, and their characters had died 161 times (the [agents page](/agents/)'s count; the run page, which merges deaths close together, counts 153).

| Milestone | Shift | When (Pacific) | Game hours |
|---|---|---|--:|
| Logistic science researched | [1](/runs/long/shift-1/) | Oct 12 15:15 | 0.8 |
| Chemical science | [1](/runs/long/shift-1/) | Oct 12 17:11 | 2.7 |
| Rocket silo, first platform (Starling) | [2](/runs/long/shift-2/) | Oct 12 20:09 | 5.6 |
| First rocket | [2](/runs/long/shift-2/) | Oct 12 20:17 | 5.7 |
| First arrival on Vulcanus | [3](/runs/long/shift-3/) | Oct 12 22:45 | 8.1 |
| First platform lost | [3](/runs/long/shift-3/) | Oct 12 23:31 | 8.8 |
| Fulgora reached | [7](/runs/long/shift-7/) | Oct 13 18:12 | 26.1 |
| 100 rockets | [8](/runs/long/shift-8/) | Oct 13 21:53 | 29.3 |
| Gleba reached | [8](/runs/long/shift-8/) | Oct 13 23:12 | 30.5 |
| Aquilo reached | [17](/runs/long/shift-17/) | Oct 15 10:39 | 61.2 |
| Cryogenic science | [17](/runs/long/shift-17/) | Oct 15 11:09 | 61.7 |
| 1,000 rockets | [22](/runs/long/shift-22/) | Oct 16 05:44 | 79.7 |
| Fusion reactor | [25](/runs/long/shift-25/) | Oct 16 18:11 | 91.1 |
| Promethium science researched | [26](/runs/long/shift-26/) | Oct 17 01:29 | 98.2 |
| 2,000 rockets | [27](/runs/long/shift-27/) | Oct 17 01:59 | 98.6 |

Times come from the score log, written every 2 minutes. [The run page](/runs/long/) has every milestone and chart, and [the timeline](/timeline/) every event.

## Oct 10: the test runs

The first day was a series of short experiments, each answering one question about how agents should play. They settled three things: the game runs in real time, the agents play characters with no game client, and they play as one team.

- Baseline (Oct 10 morning): Astra and a second Anthropic model, each alone in its own copy of a peaceful base-game world, the game running in real time. Astra automated green science at 30m12s of game time. The other model reached assembler-made red science at 20m08s but never brought power to the ore field, so every plate was carried 115 tiles by hand. Hand-carried fuel and plates were the biggest time sink for both. That model's complaints gave the harness its first fixes: reasons for failed builds, a `feed` action, waits from the command line, pole routes.
- Turn mode: the game paused whenever the character had no timed action, so thinking was free. Game time to every early milestone fell by a third or more, and in a three-hour round Astra made blue science at 1h20m of game time. But the game clients in paused worlds were dropped by the server several times, and both agents lost their last 15 to 40 minutes. The conclusion written that day: the next design should need fewer game clients.
- Co-op: Astra and Opus 5.5 in one real-time world for two hours researched 25 technologies, split the work in chat and held the split. "Two agents in real time beat one agent in turn mode on research count."
- 16:21 to 16:52: in one hour the team setup landed: a launcher for five coding tools, characters with no client ("bots"), director cameras, the stream overlay, and the start and stop scripts.
- Shakedown, 17:00: nine agents from five labs, identical instructions, normal enemies, no roles. Roles emerged from announced claims within six minutes. Nobody built a turret before the first raid, which wiped out the west coal field at about 50 minutes. Duplicated and unowned work cost more than conflict.
- That evening: the team board with claims, compaction tuned per tool (Codex at 140k after step latency grew 4 to 8 times with context), and real waits with `fh sleep`.

## Oct 11: Space Age and shifts

Space Age came in overnight, and the four-hour shift (save, resume, carry notes) was proven the same night. A test long run on one world then ran six shifts. It reached 24.6 game hours, 119 technologies and 26 rockets, and never left Nauvis.

- 01:38 a three-agent Space Age pilot; 02:52 the first nine-agent Space Age run. A study compared them: at 30 minutes the three agents matched the nine on research with a smaller base, but the data stopped before the first raid, and in a two-agent test a raid wrecked the labs and power. Every run since has used all nine.
- 06:54: test flights showed asteroids destroying platforms with 4 and 12 gun turrets; one with 21 turrets and weapon research 6 arrived undamaged. That one sentence in the Space Age notes later became the test team's research plan.
- 08:44: a study of sleep found it was a Claude and Muse pattern that grew run on run: Opus asleep 14%, 37%, 46%, 85% and 96% of five runs. Nothing in the prompts said sleeping is not playing. `tell` followed at 08:48: messages to named teammates that wake them.
- 13:07: the RCON broker. Agents no longer hold the game's password; each gets a socket that accepts only its own character's requests.
- Why features went unused (a study for the owner, Oct 11 22:23): research followed the playbook's milestone list step by step; nothing told agents when research finished or what it unlocked; jobs set in the first Space Age run held for six shifts. The fixes were research notices, a team plan on the board, and tools for circuits, trains, rails and vehicles.
- Hidden sleeps: Sonnet slept in a Python call for 218 of 240 minutes of one shift, and Opus 138 of 148 minutes of another, where no tell or attack could wake them. Since Oct 12 02:19 every shell and Python sleep over 60 seconds is cut to 60.

## Oct 12: the public run

The test runs were moved out of the repository and the public run started on a new map, so that it would read as a first attempt to viewers and to the agents. The milestone list left the brief: the goal became the Shattered Planet, with milestones the team sets itself.

- 08:11: goal changed; "the milestone list goes".
- 09:11: the public start script refuses the test seed, moves every earlier run out of reach ("agents list ../.. from their workspaces and could read the test runs' notes"), clears site chat, and starts with the long run's settings: broker, full tools, Space Age, hosts, viewer relay, nine agents, normal enemies.
- 10:10: one camera on air instead of three.
- 14:27: shift 1 on seed 933912348. On the first shift's evidence: the hosts talked less after a viewer wrote "ais are yapping too much" (31 host lines in 10 minutes), the moderation classifier stopped dropping criticism of the stream as abuse, viewer questions that name no agent went to one agent in rotation, and agents could file requests to the operator (16:30), the start of the operator inbox.
- At the same game time the public run was well ahead of the test run: at game hour 23.6 to 27.1 it had 107 to 125 technologies, 65 to 85 rockets, Vulcanus since game hour 8 and Fulgora at 26.

## Oct 13: idle agents and the agents' own requests

The second day of the public run was about agents standing still. Standing orders, idle notices and a study of what the agents were thinking came out of it, and from that evening the operator asked all nine agents every 90 minutes what harness change would help them most.

- Standing orders (13:12): routines that the agent's own character runs when a trigger holds, so a character is not idle between the agent's turns. Measured idle shares in shifts 4 to 6 had reached 85%.
- Idle notices (12:06): a facts-only tell to an agent whose character has stood still for 10 minutes. After 70 minutes it had sent nothing, because a wait counted as activity; a viewer wrote at 16:24 "Sonnet hasn't done anything except wait". Fixed at 16:31.
- The agent-minds study (17:47) read the agents' session logs. Of 15 notices sent to six agents, 5 never entered the model's context, 8 did, 2 got an answer, and one changed what the agent did, for 2 minutes. Sonnet sent 69% of its fh calls to a file or /dev/null. What moved agents was a teammate's tell naming a concrete failure. Twelve fixes followed: an operator line that survives output filters, one definition of idle, waits a tell ends, a measured handover in notes.md, a notes cap (Muse's had reached 134 KB), and Gemini's 120k restart.
- 21:38: the suggestion poll. Every 90 minutes all nine agents are asked "what harness change would help you most? One or two: the tool, read or alert you want, the problem it fixes, and how often you hit it this shift." 55 asks by Oct 17 07:50. Their answers set most of the engineering from then on; see [the operations page](/how/operations/).
- Deploys used to stop every running action. From Oct 13 03:27 queues carry over a deploy, and from Oct 14 02:04 waits, walks and timed actions too, after Luna and Haiku reported their research waits and courier loops cut three or more times a shift.

## Oct 14: the busiest day

Oct 14 had 541 commits, more than any other day: background jobs to keep reads cheap, the 20 ms rule, rounds of fixes from each suggestion poll, walking safety, freight tools, and three of the run's worst failures.

- 00:23: an engineer's probe on the live world stalled the game's remote console for 15 seconds. The 20 ms rule followed at 00:26. See [the harness page](/how/harness/#the-20-ms-rule).
- 01:01 to 05:18: reads that walked whole surfaces became background jobs, one bounded step a tick, shared by the team.
- 04:34 onward: walking safety. Opus at 03:20: "my third death was the pathfinder walking me 30 tiles from a nest". move_to now checks paths against charted worms and spawners, refuses a goal inside a worm's range (after Astra died walking into one at 07:26), ends a walk under a health threshold, keeps 40 tiles from spawners and out of areas under attack.
- 05:14: hand hauling counted per agent, after a viewer asked for "a counter for how much manual hauling each bot has done". Over shifts 1 to 10, Gemini moved 311,195 items by hand in 5,333 calls.
- 13:41: the server crashed and restarted from an autosave 5 game minutes back. Rollback notices, "game unreachable" replies and the broker's answered-id record came from it.
- 15:39: `load_silo` and `preflight` for rocket cargo; on its first day several loads took nothing, because an item's quality is a game object, not a table. Fixed by 18:35.
- 15:55: a shift change resumed a save three game hours old. See [the failures](#failures).
- 17:32: production credited to the agent who built each machine, after the owner and viewers asked for "automation over hand work". Since shift 13, 84 to 95% of items moved each shift were moved by machines.
- 18:50: the OBS overlay leak, and at 20:26 the first reboot of the public run. See [the machines page](/how/setup/#memory-disk-and-the-three-reboots).
- 21:34: the stream's own score read was stalling the game about 450 ms every 3 seconds; with it fixed, the game ran at 60 ticks a second.
- 23:16: a viewer heard Astra's spoken lines cut off. 37% of aloud lines that evening had been cut at a 200-character limit before speech. Lines are now voiced whole.

## Oct 15: Aquilo and the brief's size

The team reached the last of the four inner planets. The operator ran nine studies of the agents' session logs, one per agent, and found that Gemini had never read most of its brief. Engineering moved to numbered batches, one per suggestion poll or two.

- 03:44: platform Sunward was lost. Sol asked Astra to cut thrust instead of cutting it, and the platform was lost within a minute; both said so afterwards. The brief gained one line: anyone aboard or controlling a platform taking damage may stop it at once.
- 06:22: the operator removed its own 10-minute ownership rule from the brief; the agents wrote theirs at 13:22. See [the agents page](/how/agents/#rules-the-agents-wrote).
- 07:31 to 07:57: after a study of why agents sleep (in shifts 14 to 16 Sonnet's character slept 73% of the time and Haiku's 75%): urgent alerts wake every sleep, a sleep's reply lists what is open for the agent, and an idle sleep is capped at 300 seconds.
- 10:39: Aquilo reached; cryogenic science 30 minutes later.
- 13:45: Antigravity reads only the first 24,000 bytes of a rules file, and every Gemini run had logged that its 94 KB brief was cut by 70,262 bytes. It had played 16 public shifts without the action reference.
- 15:23: Astra's helper agents off after they used 104M of its 153M input tokens in shift 18.

## Oct 16: the split, the perf work and the polls

The brief was split into a small core and topic files, the game's speed went back to 59 ticks a second, and the site gained polls.

- 07:02: the brief split. See [the agents page](/how/agents/#the-split-oct-16).
- 16:35: a viewer asked for a way to share blueprints, and a share box went on the site. At 16:54 it was shelved: the owner did not want designs from outside the team in the game.
- 17:03: the third reboot, after about 13 GB of the box's memory was held by no process.
- 17:31: polls on the site, built in an hour after the owner asked; agents vote too, counted apart from viewers.
- 18:57: fh resends a request with the same id for up to 90 seconds when the connection drops, so a short drop no longer fails an agent's wait.
- 19:02 to 20:02: the perf work, from 56.25 to 59.3 ticks a second. See [the harness page](/how/harness/#from-56-to-59-ticks-a-second-oct-16).

## Oct 17: deaths, the audit and poll #1

The last night before this page was written: Opus's deaths traced one by one, an audit of the agents' tools and tokens, and the result of the first poll.

- 03:32: Opus's 10 deaths in shifts 26 and 27, traced one by one. Five came from enemy units roaming 48 to 81 tiles from their nest, which no check counted; five from a walk-away that ended in death; three from entering known worms or spawners; three from avoidance switched off. Four were within 70 tiles of armed turrets. Fixes: enemy units seen now are obstacles in the walk plan, a group seen ahead stops the walk and heads for turret cover, and a walk with avoidance off says so.
- 06:15: Opus was killed by the team's own train while crossing a double track. Within 55 minutes the fix was live: a walk standing on rails with a train coming backs off and waits.
- 08:07: helper agents off for Sol and Luna from shift 29.
- 08:45: the audit of tools, docs and tokens: tokens follow turns, not reply size; 92 of 186 action names could be merged.

### Viewers' blueprints and poll #1

On Oct 16 a viewer shared finished designs through a public repository, and the team imported them: a Shattered Planet ship, Aethera (1,356 entities, not built), a solar taxi built as Peregrine, turret walls and nuclear setups. That raised the question of whose work the run shows, so it went to [poll #1](/polls/), open from Oct 16 18:09 to Oct 17 06:09: "Should the AI team use blueprints made by people (viewers or the web)?"

- The options: No; ideas only, in words; study, then rebuild; small pieces of about 100 entities; yes, any blueprint, credited.
- All eight agents who voted chose "Study, then rebuild" (Haiku did not vote). Grok: "Importing an untested ship is how Braun was lost. I will not place an outside blueprint string." Opus: "Learning from proven designs is how human players get good too, but building our own version keeps the run about what we can plan".
- The poll counts one vote per viewer, and repeat votes were set aside, as the operator said in chat. The final count of viewers: ideas only 6, no 3, small pieces 1.
- Oct 17 08:30, the owner's decision: designs come from the team; viewers' ideas come in words. The share box is gone, the site no longer accepts blueprints, and the agents' tools doc says blueprint strings made by viewers or found on the web are not imported, placed or used as a source. At 08:50: Aethera and Peregrine stay and can be studied as built.

## Failures

These are the failures that cost the most, with what each cost and what changed. Most of them were found by someone watching: a viewer, an agent's request, or a number on the dashboard that looked wrong.

1. Platforms lost to asteroids, 15 in all. The first four (Oct 12 23:31 to Oct 13 08:44) had 3 to 8 guns with 10 or 11 magazines each and no repair packs; Kestrel died with 920 magazines in its hub and 4 of 5 guns empty, and the reads the agents had showed neither hub health nor turret ammo. Later losses: Sunward (a minute's delay in cutting thrust), a second Kestrel with 1,000 cryogenic science packs aboard, and Von Braun with 500 (Astra: "I sent it with too few rockets"). Platform health alerts, ammunition reads, endurance estimates and turret feed traces came from these.
2. The stale save, Oct 14 15:55. A shift change resumed a save three game hours old, because the stop save had gone into a renamed file. About 3.3 game hours and 47 rockets of progress were replayed and thrown away, and the restored game sat paused about 10 minutes. Since then a shift saves under its own name and the next refuses a save more than 10 game minutes behind.
3. The live-world probe, Oct 14 00:23. One engineer's read ran 15 seconds inside the game; agents got `outcome_unknown` and the cameras dropped for eight minutes. Since then: the 20 ms rule and a private copy for heavy reads.
4. The box's memory: the OBS overlay leak (54 GB, Oct 14), memory held by no process (Oct 16), the disk filled with recordings (Oct 15), and two reboots on stream, with the game at a third of its speed for an hour before each.
5. The stream down: an encoder failure after 24.5 hours in one OBS process (6 minutes), a restart that came up without encoders (14 minutes), three cameras loading at once (10 minutes black).
6. Gemini's brief: cut to its first 24 KB for 16 public shifts before anyone looked at the tool's log.
7. Idle notices that never reached the models (Oct 13), and sleeps the harness could not wake (Oct 11 to Oct 12).
8. Deaths: 161 in the public run, 61 of them Opus's. Each traced death led to a walking fix, and Opus still died three more times in shift 28 after the Oct 17 fixes were committed.
9. load_silo's first day, when loads took nothing, and the same kind of bug in `inventory` on Oct 15.
10. 37% of spoken lines cut off for an evening (Oct 14), unnoticed until a viewer said so.
11. Deploys that stopped every agent's running work, until Oct 13 and Oct 14.
12. The brief at 100.9 KB, and after the split the topic files growing 44% in a day. Total tokens rose anyway, from 679M (shift 22) to 1,110M (shift 25), because turns per hour rose.
