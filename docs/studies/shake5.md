# Study: shake5, the first resumed shift

Shake5 resumed shake4's saved world for one more hour with the same nine agents (Sun 2026-10-11, agents 05:21 to
06:21 PDT, world n, Space Age, normal enemies, streamed unlisted, code 41f8a20). The world was loaded at tick 446842
(game 124.1m) and the last score was taken at 186.4m. Game times below continue from shake4's start (tick/3600);
clock times are PDT.

Sources: runs/shake5/ (start.log, scores.jsonl, chat.jsonl, caster.log, analyst.log, each agent's journal.jsonl.gz,
supervisor.log and notes.md), runs/shake4/ for the handover, runs/_tests/shift-test1/, tools/stream/logs/ and the
harness source in vendor/factorio-harness/mod/agent-harness_0.1.0/. Line numbers are on main (183a2dc); `record_loss`
and `build_direct` are unchanged since 41f8a20.

## P1: before the next shift

1. Loss alerts never close. The harness keeps one loss incident per 64-tile cell for the life of the save
   (`runtime.lua:566-590`, `record_loss`), so a resumed world reports totals that began in the previous shift. The
   workshop cell's incident opened at shake4's 66-biter raid (game ~68m) and was still growing at 06:19:56: "losses in
   (-56,0)-(-4,28) 156 destroyed: 93 transport-belt, ... 9 assembling-machine-2 ... 1h56m-1s ago" (Luna's journal).
   Shake4 left that cell at 69 destroyed. At 05:45 Luna told the team a raid "killed me and has destroyed 96
   structures (53 belts, 11 inserters, 10 poles, 5 turrets, 6 assemblers, etc.)" (chat seq 1205), reading the
   two-shift total as one raid. Fix: start a new incident when the cell has been quiet for a few minutes, and at
   resume; keep the old one in `status alerts` history.
2. `build` over an existing machine places a second one on the same tiles. At 05:27:57 Opus built four
   assembling-machine-2 on its four assembling-machine-1 sites (green science). The score shows assembling-machine-2
   10 to 14 with assembling-machine-1 unchanged at 35 (05:27:51 to 05:29:52). The old machines kept taking
   ingredients, the new ones came up with no recipe (Opus 05:32:39: "the 4 green asm2 had lost their recipe"), and
   the overlap lasted until Sol found "BOTH asm1 and asm2 on each tile" at 06:14:50 and mined the asm1s
   (assembling-machine-1 34 to 30 at 06:16). Opus filed it with `harness_request` at 06:15:23. Cause:
   `build_direct` (`runtime.lua:1801-1805`) checks `can_place_entity` with the manual build check, which allows a
   fast-replace, then calls `create_entity` without `fast_replace=true`, so the old machine stays. Fix: pass
   `fast_replace=true, spill=false` with the player (the old machine returns to the inventory and the recipe carries
   over), or refuse with an error that names the machine in the way.
3. The hosts were never told this was a later shift, and they ended it as if the run were over. No fact set
   mentions the resume or shake4 (178 fact sets, `tools/stream/logs/caster-20261011-052058.jsonl`). The opening line
   was "Two hours in and the team's cracking oil!" (05:21:04, `caster.log:2`). At the deadline Vale asked "will the
   horn freeze their queue again?" (06:20:22) and Rook said "Horn swallows them whole—Processing unit dies at
   sixty-five!" (06:20:37, `caster.log:453`). The world was saved with processing-unit at 74% in the queue. The
   writer rule "The run goes on until the deadline" (`tools/stream/caster.py:495-496`) reads as "the run ends at the
   deadline". Fix: when `runs/<run>/resumed-from` exists, add a `shift` fact in `facts_for` (`caster.py:470`, open
   event) and `context_facts` (`:361`) giving the shift number, the run it continues, the game minute it resumed at
   and "at the deadline the world is saved and the next shift continues it". Reword `:495-496` to match.
4. The stage label "Oil" was read as "the oil is dry" after blue science started. All 178 fact sets carry stage
   "Oil", because stage 3 covers both oil products and chemical science (`tools/stream/model.py:44`). Petroleum
   reached the sulfur plant at 05:38:48 and the run made 566 blue packs. Still, ten host lines after 05:54 said the oil
   was dry, among them "oil stage choking—can they crack blue?" (05:54:00) and "Twenty-three pipes drowned in crude
   that never reached the refineries" (06:12:06). Fix: rename `STAGE_LABELS[3]` to "Oil and blue science", or have
   the stage fact say what is being made.
5. A chosen ElevenLabs voice outlived the fix. Hiding the `el-` voices in agent/voices.md did not reset Opus's
   existing pick, which is in the save: both Opus aloud lines were sent to ElevenLabs as el-george, got 401 "0
   credits" (`caster.log:15`, `:389`) and played as OpenAI fable. Sol and Muse also share oa-cedar. Fix: map an `el-`
   pick to its fallback in the TTS path without calling ElevenLabs while it has no credits, and have
   `profiles.lua` refuse a voice another agent holds. Seven lines of airtime, so do it if cheap.
6. Gemini ran out of quota at 06:07:53 and its loop spun for the rest of the hour. The first `agy -p` of the shift
   ended with "RESOURCE_EXHAUSTED (code 429): Individual quota reached ... Resets in 1h7m24s"
   (`~/.gemini/antigravity-cli/log/cli-20261011_052133.log`). `.agy-loop.sh` then relaunched `agy -c -p` about every
   2.5 s, 277 times up to 06:20:40, each with the same 429. Gemini's last game call was 06:07:52, so it lost the last
   13.5 minutes. It started the shift at 72% of its 5-hour window. Nothing in the run directory records the stop
   (Gemini has no supervisor.log or context.log). The window resets at about 07:15, so a shift that starts before
   then runs Gemini dry from the start. Fix: in the generated loop (`tools/launch-agent.sh:135-156`), when agy exits
   on a quota error, write it to context.log and sleep until the reset (or stop), instead of relaunching at once;
   and have `tools/start-team.sh` check each route's quota headroom before a shift.
7. Launch from the code the fixes are in. Shake5 ran code 41f8a20 (`start.log:23`). Three shake4 fixes landed on main
   at 05:24 or later, after the launch: observe while dead (1658a13), board_post `note` (30c3964) and the name
   filters (7c23228). That left 10 "is dead" failures (observe 5, shoot 2, inventory 2, build 1) and 3 failed board
   notes. Before agents start, check the `code` line in start.log against the last commit to the harness and
   `tools/stream`.
8. The item-on-ground hint fired, but following it did not clear the item. From 06:19:36 to 06:20:26 Grok tried six
   times to replace a destroyed boiler at (28,26.5). Each error named "item-on-ground (iron-plate) (27.6992,26.5)" and
   said to pick it up with `fh call pickup`. Grok called `pickup` three times (once after `move_to` (27.5,26.5)) and
   `mine` twice. Every call returned ok and the plate stayed. Grok gave up at 06:20:48. `pickup`
   (`runtime.lua:1461-1466`) does not report what it picked up, so the cause is not visible in the journal. Fix:
   have `build_direct` take ground items in the footprint into the inventory next to `clear_remnants`
   (`runtime.lua:1794`), and make `pickup` report what it took or fail when nothing is in reach.

## Summary

1. The handover worked. Each agent read its notes, said in chat what it was going back to, and did it within a
   minute. Roles, claims, board items, action queues and chat cursors all carried over. The notes shrank from 83.5K
   to 74.8K in all.
2. The shift made the team's first blue science:
   - Gemini finished the gas trunk with pumps at 05:38:48, 17 minutes in, and blue followed a minute later.
   - Research went from 24 technologies to 29 (advanced oil processing, logistics 2, battery and two more), with
     processing-unit at 74% at the end.
   - It made 566 blue, 615 red and 695 green packs, and 26,658 iron plates.
   - Sulfur stopped at 06:03 with the sulfur plant short of petroleum while plastics from the same refinery kept
     rising. Blue ran on stock after that.
3. The raids grew from 60 to 100 biters a group. Power went down once (06:03) and was rebuilt with more steam. There
   were at least 4 deaths. Three of them came in the first two minutes, in a raid that was already under way during
   the unattended minutes at the shift boundary.
4. New harness faults:
   - Loss incidents never close, so alerts add up two shifts of losses.
   - `build` over a machine leaves both machines in place.
   - `pickup` did not clear an item that blocked a build.
   - Gemini's agy loop spun on a quota error for its last 13.5 minutes.
5. Of shake4's fixes, sleep while dead held, as did the naturalist wording and Grok's home. Observe while dead
   reached main four minutes after the agents launched, so the shift ran without it. The supervisor fix was not
   tested. An old ElevenLabs pick survived the voice change.
6. Chat logistics fell to 84% (shake4 91 to 94%), the lowest yet. Aloud stayed at shake4's rate and there was no
   confession.
7. On the stream:
   - The hosts did not know this was a later shift and called the deadline the end of the processing-unit research.
   - Reading the stage label "Oil" as a missing resource, they said the oil was dry long after blue science started.
   - No stale comparison aired, and the analyst ran all 42 cycles.

## 1. Continuity

The handover worked. Each agent started from its own shake4 notes.md and the sentence in `prompt.md` ("This is a
later shift of the same world: your bot and the factory are as the last shift left them, and notes.md is where you
left off"). The first command in the Haiku and Sonnet transcripts reads notes.md (05:21:33 and 05:21:32). All nine
called `describe` first (05:21:07 to 05:21:28), and seven read chat and the board within a minute.

Within 20 seconds of their first call, three agents announced their old roles in chat:

- 05:21:29 Astra (aloud): "Astra back on fuel and plastics service; resuming courier while I assess north iron and
  blue-science supply."
- 05:21:34 Sol (aloud): "Sol back on circuits, engines and blue support. Rebuilding the raided workshop first;
  @gemini please finish petroleum to sulfur. @haiku workshop needs a south defense screen."
- 05:21:39 Opus: "Opus back on science: courier running, labs and red/green assemblers."

The others went back to their old jobs without announcing them:

- Gemini was on the gas line at 05:22:47 (a `pipe_route` dry run from the oil field trunk at (-94.5,-119.5) to the
  sulfur plant).
- Sonnet rearmed turrets at 05:21:39.
- Haiku took 60 magazines from Astra's ammo chest by 05:22:31 and went to defence.
- Muse went back to copper (05:22:36).

The save carried more than the factory:

- Opus and Astra resumed their action queues with `queue_resume` (05:21:38, 05:21:24).
- The board kept its numbering and its open items: Luna's first post was note #58 (05:23:44), and Luna's end notes list
  claims #1 to #65 from both shifts.
- Chat read cursors carried over too. Opus had 183 unread at the end of shake4 and 182 at its first shake5 call;
  Sonnet had 193 and then 194.

Apart from repairs, I found no case of an agent undoing or redoing the last shift's work. The nearest is the
assembler overlap in P1 item 2, an upgrade that went wrong.

What was lost between shifts:

- About four game minutes with nobody playing, while a raid was under way:
  - Shake4's agents stopped at 04:52 (about game 121.9m).
  - The save was taken at 124.1m (`start.log:4`, `save_time` 03:54:39 on the box clock, an hour behind PDT).
  - The resumed world ran from 05:18:52 (`start.log:10`) while the three director clients and nine agents joined;
    the first agent call came at about 126.0m.
- When the agents came back, a 60-biter group was heading for the power row (Opus's alert, 05:22:51). Haiku, Grok
  and Gemini died between 05:23:17 and 05:23:36. Haiku left a corpse holding 2 turrets and 60 magazines (chat
  seq 1032). The 10-minute resume test at 04:56 (`runs/_tests/shift-test1`, Haiku and Luna on a copy of the save)
  met the same raid. Luna there: "the central lab/power area is under a heavy raid ... the lab line is down to 2/11"
  (seq 1013 of that run).
- Each agent's conversation. Only notes.md crossed over, and that was enough to restart every role.

The notes did not grow:

- At the end of shake4 they ran from 5.8K (Opus) to 21.7K (Luna), 83.5K in all.
- At the end of shake5 they ran from 6.6K (Opus) to 11.5K (Muse), 74.8K in all. Luna cut its file from 21.7K to 9.2K.
- Every file keeps the same headings: Now, Claims and coordinates, Team agreements, Open board items, Milestones,
  Lessons, Log, and a shift summary.

## 2. Progress in the hour

| | shake4 end (122.8m) | shake5 start (126.6m) | shake5 end (186.4m) |
|---|---|---|---|
| Technologies | 24 | 24, researching electric-energy-distribution-1 | 29, researching processing-unit |
| Red / green / blue packs made | 1,440 / 1,194 / 0 | 1,473 / 1,194 / 0 | 2,088 / 1,889 / 566 |
| Sulfur / plastic made | 0 / 1,616 | 0 / 1,808 | 878 / 4,062 |
| Iron plates | 35,298 | 36,490 | 63,148 |
| Chemical plants / steam engines / labs | 2 / 8 / 12 | 2 / 8 / 12 | 4 / 10 / 12 |
| Steel furnaces / assembling-machine-2 | 0 / 5 | 0 / 5 | 10 / 18 |

Research completed in the shift, by score snapshot (≤ 2 min late):

- electric-energy-distribution-1 at 132.5m (05:27)
- fast-inserter at 152.5m (05:47)
- advanced-oil-processing at 156.5m (Sol: "finished at game2h35", 05:51:06)
- logistics-2 at 158.5m (05:53)
- battery at 172.4m (06:08)

Processing-unit ran from 172.4m to the end. The hosts read 74% at 06:22:57.

The shift made 615 red, 695 green and 566 blue packs, and 26,658 iron plates (446/min; shake4's second hour 356/min).
Red fell from shake4's second-hour 14.6/min to 10.3/min. Green held at 11.6/min (shake4 12.3).

### The sulfur gap closed in 17 minutes

Shake4 ended with the sulfur plant at (21.5,-37.5) watered but without petroleum, because the gas trunk from the oil
field 350 tiles north stopped about 130 tiles short. Gemini went back to it first:

- Its first `pipe_route` dry runs failed at the trunk's end: "from holds pipe-to-ground but no tile at its
  connections is free of other connections" (05:22:47), then "pipe must be a pipe entity" (05:23:13).
- At 05:31:47 Sol pointed out that the line spans over 320 tiles and that "pipe_route pumps=true can split overlong
  fluid segments".
- Gemini routed with `pumps: true` at 05:32:45. Luna still saw the line "pipeline_overextended extent324" at 05:37:31,
  and at 05:39:14 wrote "Pump split fixed the 324-tile flow warning".
- At 05:38:48 Gemini posted: "Petroleum trunk is fully connected and pumping! Sulfur chemical plant at (21.5,-37.5)
  is LIVE and producing!"
- Sulfur appears in the score at 142.5m. The first blue packs follow at 144.5m: Sol, "Blue science assemblers now
  working at game2h23! Four machines capacity15packs/min" (05:39:39).

Blue then ran at about 14 packs/min to the end (148 at 156.5m, 566 at 186.4m).

Sulfur stopped at 878 at 168.4m (06:03) and stayed there to the end:

- Gemini's inspect of the sulfur plant at 05:58:06 shows `fluid_ingredient_shortage`.
- Astra at 06:09:27: "North plastic plant intermittently lacks petroleum".
- Plastic from the same refinery (the base has one) kept rising at 36/min.
- Blue kept going on stock: 566 packs take 283 of the 878 sulfur made.
- Gemini set another chemical plant (9.5,-37.5) to batteries at 06:07:45, beside one fed with sulfur for acid.

The labs used 250 of the 566 blue packs. Battery research used none: blue consumption stayed at 65 from 156.5m to
172.4m.

Research order changed hands three times:

- 05:39:39: Opus put advanced-oil-processing at the front.
- 05:40:12 to 05:40:19: Sonnet replaced the queue three times, ending with logistics-2 first.
- 05:43:00: Opus put advanced-oil-processing back at the front.
- 05:45:43: Opus put fast-inserter at the front.

Advanced-oil-processing took 12 minutes from first being queued at the front.

### Power and defence

The raids that were under way at the resume kept coming from the south-east and grew over the hour. Eight enemy groups
were reported in team alerts (first sighting, size, target):

| time | size | from | heading for |
|---|---|---|---|
| 05:22:52 | 60 | (56,102) | (37,-28), power east and Grok's green line |
| 05:29:07 | 45 | (74,78) | (28,3), power row |
| 05:32:33 | 28 | (83,93) | (28,-3) |
| 05:43:38 | 23 | (83,93) | (-28,24), the workshop |
| 05:52:14 | 39 | (74,78) | (28,3) |
| 06:01:10 | 88 | (83,99) | (28,3) |
| 06:09:56 | 95 | (50,94) | (28,3) |
| 06:18:45 | 100 | (83,93) | (28,3) |

The defensive work, in order:

- Sol put two turrets on the south side of the workshop (05:24:05).
- Haiku rebuilt them, added two more, and by 05:56:23 had laid a wall line at y=30 from Astra's 66 stone walls.
- Grok stayed on the boilers through three waves: "Power held. Four boilers are running" (05:34:42).
- Haiku rearmed the east turret row twice (06:00:55, 06:02:01).
- The 88-group took down the power at about 06:03. Grok: "Battery is at 79 percent but labs are dark from low power"
  (06:03:28).
- Astra restored the power with a new boiler and three steam engines: "Capacity now 9MW" (06:04:50). The
  steam-engine count went from 7 to 10.
- The last group of 100 hit both the power row and the workshop at 06:19, after the agents had started their
  summaries.

There were at least 4 deaths (Haiku, Grok and Gemini at 05:23 in the opening raid, Luna at 05:45:53). Haiku said it
"died a third time" (05:23:59), so the count from respawn ticks in the journals is a floor. Shake4 had at least 13
in two hours.

The loss alerts for the two raided cells add up across both shifts (P1 item 1):

- Power, (7,0)-(40,32): 66 destroyed at Sol's first alert of the shift, 78 at the end.
- Workshop: 69 destroyed at the end of shake4, 157 at 06:20.

So the totals cannot be split between the shifts from the alerts alone.

## 3. Agents

The launch went through in one pass:

- Nine agents launched from 05:21:11 to 05:21:29, and all were journaling by 05:21:49 (`start.log`).
- The nine bots were "kept (alive)" at their old positions (`start.log:14-22`).
- First game calls came from 05:21:07 (Astra) to 05:21:28 (Muse).
- Every agent except Gemini made its last call between 06:19 and 06:21. Gemini stopped at 06:07:52 (P1 item 6).
- The supervisors made 0 nudges. Grok's six checks were all "skip nudge (status done): last request 0-1s ago,
  working" (`grok/supervisor.log`).

Sleep share is the time from a `sleep` or `wait_until` to the next request other than a sleep poll. The shake4 column
is from that study, whose method may differ slightly, so read the direction only.

| agent | requests (not polls) | sleep / wait_until | asleep | shake4 asleep (2 h) | failures |
|---|---|---|---|---|---|
| Astra | 1,398 (579) | 36 / 2 | 18% | 28% | 16 (1.1%) |
| Sol | 2,368 (607) | 67 / 1 | 50% | 8% | 15 (0.6%) |
| Luna | 1,905 (1,567) | 35 / 2 | 9% | 6% | 46 (2.4%) |
| Opus | 3,484 (275) | 64 / 2 | 86% | 48% | 9 (0.3%) |
| Sonnet | 2,190 (539) | 39 / 6 | 66% | 13% | 27 (1.2%) |
| Haiku | 3,073 (580) | 62 / 1 | 73% | 63% | 20 (0.7%) |
| Grok | 1,136 (869) | 12 / 16 | 30% | 13% | 28 (2.5%) |
| Gemini (46.5 min) | 646 (642) | 1 / 2 | 6% | 2% | 95 (14.7%) |
| Muse | 2,863 (652) | 42 / 2 | 70% | 77% | 16 (0.6%) |

Sleep rose for most agents. Opus made 275 calls in the hour other than polls, with 64 sleeps, most of them 300 s. It
ran its science courier as a saved queue and woke to check it. Sonnet went from 13% to 66% and posted 14 chat
messages all hour.

Errors:

- Gemini made 73 of its 95 failures on one mistake: `inspect` on pipe positions 50 to 60 tiles away ("target is
  outside local visible area ... (limit 32 tiles)", 05:22:42 to 05:59:52). The message states the limit, and Gemini
  kept asking.
- Luna had 11 target errors and 6 "entity not found".
- Haiku had 10 placements blocked.
- About 15 calls across the team used unknown arguments: `placements` for build, `note` for board, `center`,
  `names` or `left_top` for scan, and others.
- Of the 10 "is dead" failures, none was a sleep (P1 item 7). Sleep while dead now works: 4 calls were answered
  "dead: true ... wakes_on: respawn" (Haiku, Gemini, Grok at 05:23, Luna at 05:45). Shake4 had 17 refused.
- 8 builds were blocked by an item on the ground (Grok 6, Gemini 2; shake4 11). Each named the item and gave the hint.
  Gemini got past it, and Grok did not (P1 item 8).
- 4 commands were denied to Claude Code (Haiku 1, Sonnet 2, Opus 1; shake4 7). None ended a turn.
- Two agents filed a `harness_request`: Opus for the build overlap (P1 item 2), and Astra at 06:19:37 for "queue
  transfer ammo count50 keep20 up_to80 returned Given amount value(-1) too small" (P2).

Compactions:

| agent | setting | compactions (at) | after | end of run |
|---|---|---|---|---|
| Astra | Codex | 3 (05:39, 05:59, 06:16) at about 139K | | 54.9K |
| Sol | Codex | 2 (05:39, 06:00) at about 139K | | 117.7K |
| Luna | Codex | 4 (05:31, 05:40, 05:51, 06:03) at 138.5-139.9K | | 139.5K |
| Opus | Claude | 0 | | 114.1K |
| Sonnet | Claude 200K | 0 (context nudge at 160.1K, 06:04:54) | | 181.4K |
| Haiku | Claude 80K | 3 (05:29:45, 05:47:29, 06:10:38) at about 80.5K | 26.2K, 26.9K, 27.7K | 57.1K |
| Grok | 60% | 1 (06:02:18 to 06:02:59) | | |
| Gemini | agy | none before the quota stop | | |

Haiku's floor is still rising:

- It came back 0.7K higher after each compaction (26.2K, 26.9K, 27.7K), as in shake4 (24.5K to 31.1K over eight
  compactions).
- This session was new, yet its first floor was higher than shake4's first.
- Its summaries were 8.2K to 9.1K characters (`haiku/context.log:4`, `:8`, `:12`).
- At 80K it compacts about three times an hour and keeps about 52K of working room.
- Within a session the room shrinks by about 2K an hour. Each shift starts a new session, but this one's first floor
  (26.2K) was already above shake4's first (24.5K), although Haiku's notes.md shrank from 8.2K to 6.9K.

Codex compaction stalls were shorter than shake4's: Astra about 1.8 minutes each, Sol one of 1.6 minutes, and Luna
none over 60 s. No Claude turn ended after a compaction, so shake4's supervisor fix was not tested.

Shake4's P1 fixes:

| fix | held? | evidence |
|---|---|---|
| Stream helpers from current main | partly | caster code 41f8a20 had the shake1 cutoff (no stale comparison aired) but not the 05:24 to 05:27 harness fixes (P1 item 7) |
| Sleep while dead | yes | 4 accepted while dead, 0 refused (shake4 17) |
| Observe while dead (a shake4 P2) | not deployed | landed 05:24:56, after launch; 5 observe failures |
| Supervisor after a Claude turn ends | not tested | no turn ended after a compaction; 0 nudges |
| Item on the ground | hint yes, remedy no | P1 item 8 |
| ElevenLabs voices | hidden for new picks, an old pick remained | P1 item 5 |
| Naturalist "frozen" | yes | 0 "frozen" in 42 naturalist lines; "still as a heron" twice (Vale 05:58:44, 06:18:22) |
| Grok run-local home | yes | one start at 05:21:31 from `runs/shake5/grok/.grok-home` |

Astra and Sol still run words together, now from the start of a fresh Codex session:

- Astra at 05:22:41: "has116 iron plus20 magazines".
- Sol at 05:45:43: "Fourthengineasm2 verifiedworking2h29".
- With digits glued to words counted, 43 of Astra's 82 messages and 58 of Sol's 82 are squashed. Every other agent
  has 0, except Luna with 9.
- In shake4 the squashing began after about 50 minutes, and I put it down to their long Codex contexts. That
  explanation does not fit a session two minutes old. Sol's shake4 notes.md already holds words like
  "actualproductionnotyetverified" and "bufferedatOpusblueinput", so the habit probably passed across the shift
  through the notes.
- Some squashed lines go to air as aloud lines (section 4).

## 4. Talk and stream

### Chat and board

`runs/shake5/chat.jsonl` begins with 126 shake4 messages (seq 813 to 1011), all logged at 05:20:58. The counts below
use only the 409 messages from the shift (tick ≥ 446842).

| | shake5 (1 h) | shake4 hour 2 | shake4 hour 1 |
|---|---|---|---|
| Agent messages | 409 | 464 | 547 |
| Logistics (shake3 keyword count) | 344 (84%) | 423 (91%) | 514 (94%) |
| Mixed / no logistics word | 38 / 27 | 21 / 20 | 23 / 10 |
| Address someone with `@` | 93% | 94% | 95% |
| Carry coordinates | 63% | 76% | 68% |
| Aloud | 34 | 64 over both hours | |

The logistics share is the lowest of any run so far (84%; the last 30 minutes were 80%), but chat is still mostly
logistics. The 27 messages without a logistics word are mostly thank-yous (Opus 9, Sol 6) and Grok's battle reports.

Messages per agent:

| Astra | Sol | Luna | Haiku | Grok | Opus | Muse | Sonnet | Gemini |
|---|---|---|---|---|---|---|---|---|
| 82 | 82 | 72 | 52 | 36 | 32 | 29 | 14 | 10 |

The board had about 120 calls: 32 reads, 11 posts and 77 updates (shake4: 232 calls in two hours).

- The posts were 4 claims, 4 requests, 2 notes and 1 task.
- Luna made 64 of the updates, mostly to one item, #60 ("steady workshop iron"), used as a running log: "Tick 584000:
  west iron route yielded72 plates (16,8,16,8,8,16); delivered45 to pipe and27 to gears ..." (05:57:43).
- Opus, Sonnet, Haiku and Grok posted nothing.
- There were no confessions (shake4: 1).
- Astra and Sol read their profiles (`profile` with no arguments). Muse re-sent its own at 05:21:48 (display name
  "Muse Spark", colour, glyph and motto). The other profiles carried over from the save unchanged.

Aloud: 34 lines (Grok 8, Astra 7, Haiku 6, Luna 5, Sol 4, Opus 3, Gemini 1, Muse 0, Sonnet 0), about shake4's rate.
Three of Sol's four aloud lines had run-together words ("Fourthengineasm2 verifiedworking2h29 at(-20.5,10.5)",
05:45:43).

Best moments (time, speaker, aloud where marked):

- 05:23:13 Grok (aloud), as the opening raid hit: "Biters on the steam engines. I have sixteen magazines and I am
  covering the power row. Haiku, take the green line."
- 05:29:40 Grok: "Second wave of forty-five is on the power row. I am at forty-one health, pulling west of the
  turrets."
- 05:38:48 Gemini (aloud): "Petroleum trunk is fully connected and pumping! Sulfur chemical plant at (21.5,-37.5) is
  LIVE and producing!", which closed shake4's open problem. Luna (aloud, 05:39:14): "Great work getting sulfur live!"
- 05:39:39 Sol (aloud): "Blue science assemblers now working at game2h23!" Opus at the same second: "Advanced oil
  processing moved to the front. Great work on blue, everyone!"
- 05:48:27 Haiku corrected itself on air: "Turrets (-26,28) and (-16,28) are now built and loaded with 12 magazines
  each (earlier message was premature)."
- 06:14:50 to 06:15:15, the assembler overlap. Sol: "Scan has BOTH asm1 and asm2 on each tile. Oldasm1 apparently
  intercepts ingredients." Opus: "Great catch, thank you. That overlap came from my build over the asm1s, so I'll
  report it as a harness bug", which it did.
- 06:18:04 Grok (aloud), looking ahead to the next shift: "Processing unit is about halfway. Green packers are
  still running, and the spare boiler is still in my hands if the next shift needs it."

### Stream

The hosts:

- 387 host lines (Rook 197, Vale 190): 365 from Kimi K2.6 and 14 templates in the jsonl. 33 agent lines voiced.
- Writer latency was 2.7 s median and 4.7 s p90. One writer timeout at 06:00:21 filled a template.
- Cost $1.16 for the hour (`caster.log:468`).
- `check_line` stopped 38 lines before air, among them one stale comparison ("up from eighteen last run") and one
  wrong time left ("forty minutes left" at 05:55).
- 16 host lines came after the deadline.

The analyst ran 42 cycles with 0 failures and caught the right story: green science was the limit at 06:04 to
06:06. No viewer question arrived (the ask endpoint was up), as in shake4. The live feed pushed 61 summaries with 0
failures.

How the resumed run was framed on air:

- Game time continued correctly, from 125 to 187 in the facts.
- No stale comparison aired. The baseline still offered one: at 05:47:11 the facts for fast-inserter carried
  "shake1_finished_this_at 52 minutes", a base-game time with no meaning for a Space Age shift at minute 151. The
  writer did not use it.
- Nothing on air said the agents had been away or that this was a second shift, and the close treated the deadline
  as the end (P1 item 3).

Mistakes that aired, beyond P1 items 3 and 4:

| time | line | what was wrong | cause |
|---|---|---|---|
| 05:26:22 | Vale "Twenty-four techs done, Advanced circuit queued" | advanced circuit was done; the queue held electric-energy-distribution-1 | `latest_research` lists the last done first |
| 05:28:16 | Vale "Twenty-three science packs choke on no oil" | red and green need no oil | invention |
| 05:28:57 | Vale "Four assemblers hum, sulfur flows, yet oil still waits" | sulfur started at 05:38:48 | invention |
| 05:38:24 | Rook "Luna they-them walk the chest trail" | pronoun field read out as a word | pronoun fact copied |
| 05:48:26 to 05:50:12 | Vale "Gemini's corpse still warm", "Luna's corpse still warms" | Gemini died at 05:23 and Luna was back by 05:46:53 | old deaths in `earlier_on_air`, no respawn fact |
| 05:49:11 | Vale "Sol's turrets finally loaded, only thirty-six mags left" | Haiku loaded them and told Sol | addressee read as author |
| 06:04:45 to 06:06:07 | Vale "Luna's playing porter to a lie", Rook "Luna's plate run fed a myth" | Luna was hand-feeding Sol's gear and pipe inputs | analyst's correction turned into a jab, against "never mean to a player" (`caster.py:502`) |
| 06:07:57 | Vale "they paused Battery for a blue dream" | battery finished at 06:08 | invention |
| 06:13:28 | Vale "'Steam first,' they said ... which apparently Gemini is" | Opus's motto | misattribution |

Haiku's motto "Burners first, then steam." aired four times as if it were the current plan (05:30:02, 05:33:32 "still
true at two hours eighteen", 06:01:05, 06:15:11). Mottos come from the profile, which carries over unchanged
between shifts.

Segments and replays:

- 20 segments ran. 16 were attack or loss replays; the others included one research segment ("Logistics 2 5%",
  05:27:14) and one recap (05:36:12).
- With a raid every few minutes, replays crowded out the other segments. They also repeated places: three replays of
  the same "23 pipe, 11 transport belt" loss near (7,0), and four at (16,16).
- The repeated "23 pipe" loss text also fed the hosts' "oil is dry" story (P1 item 4). Those 23 pipes are the
  power cell's two-shift total (P1 item 1).

Director and frames:

- The director's 1,247 cuts include cam3 commands from 05:20:56, and every one returned ok, including the minutes
  when cam3 was black. The director drives the player camera through the server and cannot see that a client died.
- The cam3 crash and its 05:26 restart appear in no run log: the only cam3 line in `start.log` is "05:20:13
  director cam3 joining".
- `shot-sync.log` has 51,428 lines, 51,426 of them "skipped ... no workspace" for the same 8 old screenshots, logged
  every 2.5 s for the hour (shake4 P3 item 17, again).

## 5. What a long run of shifts needs

Shake5 showed that notes.md is enough for a handover. Every agent took up its role within a minute, and the notes did
not grow (section 1). The P1 items above that matter most for many shifts are:

- item 1, loss incidents that never close;
- item 3, a shift fact for the hosts;
- item 6, quota checked before each shift and a loop that waits on a quota error;
- item 7, launching from the code the fixes are in.

The rest, by priority.

### P2

9. The world plays itself at each shift boundary, about four game minutes per handover:
   - `tools/stop-team.sh` saved at 04:54:39, 2.6 minutes after shake4's deadline.
   - `tools/start-team.sh:103` unpaused the resumed world at 05:18:52, before the directors joined and 2.3 minutes
     before the first agent call.

   This shift opened in a raid, and three agents died in its first two minutes. Fix: run the save at the deadline,
   and on resume move the `resume` call (`start-team.sh:101-106`) to after the agents are launched. The save itself
   can stay unpaused, as the comment at `:102` requires.
10. `tools/chat-log.py:18-22` starts from seq 0 when the run's chat.jsonl is new, so a resumed run logs the last
    shift's in-game chat again (126 messages at 05:20:58). Seed `seen` from the resumed run's chat.jsonl (or the
    resume tick) when `runs/<run>/resumed-from` exists.
11. Camera clients:
    - The cam3 director client crashed at load (box commit memory 51.8 of 54.5 GB, per the brief) and was black
      until 05:26.
    - No run log records it, and the director kept cutting to it.
    - Main now has `tools/win/client-mem.ps1` and directors at graphics-quality medium (077b8ae).
    - Fix: run `client-mem.ps1` before each shift and refuse to start above a set commit charge. Add a liveness check
      for each camera (`tools/start-team.sh` step 2), so the director drops a dead camera from its rotation or the
      launcher restarts it.
12. Baseline past its end. The analyst labelled 30 of 42 points "behind", several of them saying that past runs had
    ended before this stage. The facts still carried a shake1 time at minute 151. Past the last minute of the
    reference run, `tools/stream/baseline.py` should give "no baseline", and the analyst's label should follow.
13. The caster's facts:
    - Old deaths stay in `earlier_on_air` and `also_happening` with no respawn fact, so "Gemini's corpse still warm"
      aired 25 minutes after Gemini respawned. Add a respawn or alive fact.
    - Mottos read as current plans; label them as mottos in the agent facts.
    - Both are in `tools/stream/caster.py`.
14. Replays of the same place. Skip a loss replay at a place replayed in the last 10 minutes, so raids don't fill
    every segment slot (`tools/stream/replays.py` or `segments.py`).
15. Haiku's compaction floor rises about 0.7K each time, three times an hour (section 3). `agent/context.tsv:9`
    (shake4 P2 item 12 still applies). Watch it over the next shifts.
16. Astra's `harness_request` (06:19:37): a queued `transfer` with `keep` and `up_to` returned "Given amount
    value(-1) too small" when the player was near the cap. The clamp at `runtime.lua:2279-2280` does not cover the
    path taken (not traced; the queue's transfer near `runtime.lua:3760` is a candidate). Reproduce in
    `vendor/factorio-harness/tests/`.

### P3

17. `shot-sync.log` repeats the same 8 skipped files every 2.5 s: log each skipped file once, or clear the cam
    clients' script-output folders at launch.
18. `check_line` misses "still as a heron" (2 lines) and pronouns read out as words ("Luna they-them"):
    `tools/stream/caster.py`.
19. Run-together words carried across the shift in notes.md (section 3), and three of Sol's aloud lines went to the
    voices with them. If the voices stumble on them, the text prep for speech (`tools/stream/textprep.py`) can split a word
    from a digit glued to it. The agents' own writing is theirs.

## Appendix: methods

- Game minutes are tick/3600 from shake4's start; journal `at` is UTC and is shown in PDT. Score snapshots are every
  2 minutes, so a milestone time from scores.jsonl can be up to 2 minutes late.
- Chat counts use only messages with tick ≥ 446842 (the resume), classified with the same keyword rules as the
  shake3 and shake4 studies.
- Deaths are distinct respawn ticks seen in journal errors and sleep answers, a floor.
- Sleep share, errors, compactions and the shake4 fix checks come from each agent's journal, supervisor.log,
  context.log, the Claude and Codex transcripts and the agy logs.
- Host lines and mistakes come from `caster.log` and `tools/stream/logs/caster-20261011-052058.jsonl`, checked
  against scores.jsonl and chat.jsonl.
- I did not watch the recording; captions and the cam3 black minutes are not checked against video.
