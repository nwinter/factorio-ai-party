# Shake6: a short check

Shake6 was the second resumed shift: shake5's save, the same nine agents, Sun 2026-10-11 07:22 to 08:12 PDT, from
game minute 187.5 (tick 675041). It ran code 574b897 (`start.log:15`, `:44`). Game minutes below are tick/3600 from
shake4's start; times are PDT. Sources: `runs/shake6/` (start.log, scores.jsonl, chat.jsonl, caster.log,
stream-service.log, each agent's journal.jsonl.gz). This check was written in 20 minutes, so some items are marked
unchecked.

## P1 before the next shift

1. **The world ran about 5 minutes past the deadline.** The deadline was 08:12 (`start.log`, "deadline 2026-10-11
   08:12 PDT"), game minute about 238.6. The score loop shows the world unpaused and advancing after it: 240.1 at
   08:13:05, 242.1 at 08:15:06, 244.1 at 08:17:06, all `"paused": false` (`scores.jsonl`, last three lines). The save
   is at 244, so the next shift inherits about 5.5 game minutes that no agent played, during a raid on the boiler row
   (the hosts at 08:13:02 and 08:13:42: "Four boilers down, four engines gone", "seventy lost walls"). Opus's
   supervisor logged "08:12:19 deadline reached after 0 nudges" (`opus/supervisor.log`), but Opus's own last call was
   at 08:15:14 and its sleep checks ran to 08:17:14, so its session was still running; the others' last own calls
   were 08:10:44 to 08:12:11. File: `tools/stop-team.sh` (pause the world first, then save, then stop agents
   and helpers); the shake5 study's P2 item 9 asked for the same thing at the start of a shift.
2. **The hosts number the shifts wrongly.** The shift fact landed (Rook at 07:22:13: "Shift three picks up a world
   already three hours deep"), but by the end the hosts mixed "shift three", "shift four" and "shift five", and once
   named the run: "Shake five gets low density at ninety" (07:57:36), "Shift four's furnace, shift five's flame"
   (08:01:42), "Shift five inherits smoke and debt" (08:02:47), "shift three's lullaby for shift five" (08:03:27). The
   fact gives a shift number and a run name side by side, and the writer adds them. File: `tools/stream/caster.py`
   (the shift fact: give the next shift's number outright, "the next shift is shift four", and drop the run name
   from it).
3. **Vale's first line had two errors.** At 07:22:20: "three hours in and still oil stage, thirty science packs a
   minute won't rebuild Vulcanus." The world is on Nauvis and never had a Vulcanus base. The "oil stage" was the old
   label; seven minutes later Vale said "oil and blue stage" (07:29:19), so the new label (92ccf95) did reach the
   facts. Vulcanus is named in the hosts' Space Age description (`tools/stream/caster.py:58-63`, `SHOW_SPACE`, "the planets
   Vulcanus (metallurgic science), Fulgora ... follow"), and nothing in the facts says no planet but Nauvis has been
   reached. File: `tools/stream/caster.py` (a fact naming the planets reached, Nauvis only, and the rule that other
   planets are future milestones).

## The shake5 P1 fixes

| shake5 P1 | Held? | Evidence |
| --- | --- | --- |
| 1. Loss incidents close | Yes at the resume; not checked during the run | `start.log`: `shift_start {"ok":true,"tick":675042,"incidents_closed":6}`. Loss lines in the caster were smaller (Vale 08:13:42 "seventy lost walls"); I did not read the incident rows. |
| 2. Build over a machine refused | Not exercised as in shake5 | No build over a same-group machine in the journals. Opus told Sol at the start "Set the recipe again after placing; fast-replace dropped mine last time" (chat seq 1389, a shake5 message, see below). Astra's one build failure: "target already contains this entity; use rotate explicitly or an underground crossing" (`astra/journal.jsonl.gz`), a different check. |
| 8. Ground items taken by build and `pickup` | Not exercised | No agent called `pickup` in shake6. Grok's spare boiler at (28,26.5), the shake5 ground-item site, failed again on "placement blocked by steam-engine (31.5,26.5)" and on pipes (`grok/journal.jsonl.gz`), a placement clash. Sol and Astra still asked at about 07:36 for that boiler "if groundiron picked" (seq 1530, 1532). |
| 5. Unique voices | Yes for the agents who spoke aloud | Aloud voices in `caster.log`: Astra athena (4), Sol oa-cedar (4), Grok arcas (2), Luna luna (1), Gemini apollo (1). No two agents share one. |
| 5. el- picks on their stand-in | Probably yes | No ElevenLabs or "credits" line in `caster.log` or `stream-service.log`. Opus, the shake5 el- pick, spoke no aloud line, so this is not tested on that agent. |
| 3. Shift fact | Landed, numbering wrong | See P1 item 2. |
| 4. Stage label | Yes | "oil and blue stage" (Vale 07:29:19); Vale's 07:22:20 "still oil stage" is the one miss. |
| 6. agy quota handling | Not exercised | Gemini acted from 07:22:33 to 08:12:08 (570 actions); the quota check showed 0% of the 5-hour window used (`start.log`). |
| 7. Start-team quota and code checks | Yes | `start.log`: a quota line per route, all "ok"; "code ok: main 574b897 has main's and recent branches' harness and stream commits, and the built host is newer than its sources". |

## Continuity and progress

All nine bots were alive where they had stood (`start.log` "bot ... kept"), and every journal has actions from
07:22:14 to 07:22:34. The roles carried over: Grok on the south boiler, Astra on power, Gemini on the refineries
(chat and Gemini's 08:09:19 aloud summary). I did not read the notes or first turns.

`chat.jsonl` starts with shake5 messages (seq 1368 at tick 631273, before the resume tick) logged again at 07:22:05:
the shake5 study's P2 item 10 (`tools/chat-log.py` starts from 0) is still open. Of the 433 lines, 135 (seq 1223 to
1420) are shake5's; 298 are shake6's, by sender Sol 68, Astra 60, Luna 60, Grok 35, Muse 23, Haiku 23, Opus 13,
Gemini 13, Sonnet 3.

| | first score (190.1m, 07:22:55) | last score (244.1m, 08:17:06) |
| --- | --- | --- |
| Technologies | 29 | 32 (+ processing-unit 07:28, low-density-structure 08:03, flammables 08:07); researching rocket-fuel |
| Blue packs made | 618 | 1,350 |
| Red / green made | 2,121 / 1,905 | 2,568 / 2,627 |
| Sulfur | 878 | 1,692 (sulfur started again) |
| Advanced circuits | 1,264 | 2,688 |
| Plastic | 4,198 | 6,242 |
| Processing units / LDS | 0 / 0 | 50 / 50 |
| Iron plates | 64,816 | 90,866 |
| Rockets | 0 | 0 (no rocket silo technology) |

Power was short for the whole shift: Sol at about 07:36 "Grid drawing 8.06MW with new machines partly idle" (seq 1530),
Astra "Only 5 boilers for up to 9 engines" (seq 1532), and the hosts read 336 machines short of power at 07:44:54.
Deaths: Grok at 07:37 and 08:04:58, Sol at 08:05:39 (caster death lines; Grok's journal 08:04:51 "bot grok is dead;
it respawns at tick 835111"). Biters reached the boiler row from 08:04.

## New breaks and host mistakes

Harness errors were few: 107 failed calls of 3,752 the agents made themselves (Grok 35, mostly "entity is out of reach"; Gemini 22; Luna 20).
Unknown-argument errors suggest a field list in the help is unclear: `field status|recipe|inventory|output` was sent
by Sol and Gemini with `|` and `,` separators (`unknown field ...`), and `collect` got `items` and `position` (Sol,
Grok). These are P3.

Opus and Sonnet barely played. Leaving out the harness's own `observe` calls with `scope: sleep_check` (one a
second while a bot sleeps), Opus made 72 calls in 50 minutes, 56 of them `sleep` and 13 `say`, plus one `research`
and one `queue_resume`; Sonnet made 78 (21 `sleep`, 12 `plan_run`, 25 `observe`). The others made 286 (Haiku) to 875
(Grok). Opus's sleep checks number 3,311 and run to 08:17:14. I did not read their transcripts, so I cannot say
whether they were waiting on queued plans, on chat, or had nothing to do; this is the first thing to read for the
next study (P2). The raw counts in the journals mislead unless sleep checks are left out; the analysis scripts and
any activity figure on the stream should drop them.

Host mistakes beyond P1 items 2 and 3: "packs at forty-three per tick" (Vale 08:04:31, a per-minute figure); "Dream
passes to shift four, Rook out" spoken by Rook (08:11:36); and lines after the deadline at 08:12:25 to 08:13:42
calling the world saved while it ran. The filter rejected 7 lines for numbers or names not in the facts (for example
08:06:26 "world saved at 233").

## Director memory and the picture

Unchecked. `start.log` and `stream-service.log` have no client-memory lines (no match for `mem`, `memory`), and OBS
skipped frames are not in any log in `runs/shake6/`. The three directors joined at 07:19:59, 07:20:40 and 07:21:21.
To check it, read the box's OBS log for the 07:22 to 08:12 window and add a client-mem line to the stream-service log
(`tools/stream/`).
