# Shake12, early look, and the night in numbers

Shake12 (02:58 to 06:58 on world n, from game minute 1,047) is the first shift whose agents have the playbook's
tools index (trains, logistics, circuits, modules, nuclear, quality, capsules), the reworded asteroid test, research
notices (with the refreshed `control.lua`), the shift-start block, the team plan (`fh board plan`), station-named
train stops, and the hosts' "previously on" and Sonnet urgent lines. This look covers 02:58 to 05:26. Times are
PDT; game minutes are tick/3600 from shake4's start. Data only, read-only on the game.

## P1

1. **Opus's waiting is again out of reach of any wake.** Opus waits in `python3 -c "import
   time;time.sleep(840)"` while its own courier script (`opus/tools/cycle.py`) drives its character: 19 such sleeps
   asking 138 of the 148 minutes to 05:26, against 2% in `fh sleep`. A tell, a mention or a raid cannot wake it.
   Shake11's P1 item 3 is still open (`tools/launch-agent.sh` allows `Bash(sleep:*)`, `tools/permit.py` lists `sleep`,
   and a Python sleep needs neither); the sleep share in section 4 counts these.
2. **The team's own flamethrowers burn the team's buildings.** Loss lines name a flamethrower turret as a cause in 8
   areas in shake11 and 11 so far in shake12: gun turrets ("1 gun-turret by 1 flamethrower-turret"), radars, belts, a
   character (shake11, (-95,-176)), and the flamethrowers' own oil pipes ((38,84) and (39,85), shake12). The reply
   says it (`by N flamethrower-turret`), among enemy causes; a word that marks our own turret as the cause
   ("friendly fire") would make it stand out. File: `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua`
   (`describe_incident`).
3. **A small harness error hides a useful one.** `observe scope=rates` takes positions as `[x, y]`, but when nothing is
   found its message reads `pos.x`: Gemini got "runtime:5618: attempt to concatenate field 'y' (a nil value)" at 03:57
   instead of "no machine of ours at ...". File: `vendor/factorio-harness/mod/agent-harness_0.1.0/rates.lua:236`
   (format the normalised position).

## Short answer

- **Research notices work.** Both technologies that finished (worker-robots-speed-3 at 03:15, weapon-shooting-speed-6
  at 04:47) reached all nine agents in their next reply. Both unlock bonuses, not buildings, so there was nothing new
  to place. The first grenade thrown with `use_item` (Sol, 04:53) is the one new combat tool used.
- **The team plan is used from the first minute.** Every agent but Sol wrote its line by 03:04 (Sol at 03:05), and all
  nine read it; 43 `board_plan` calls in all.
- **The tools index shows up in a few first uses:** 4 `circuit` and 2 `wire` calls (Astra's coal condition, Sol's
  heavy-oil switch), the first `use_item` grenade, a bulk inserter, 179 `requests` calls for the logistic network.
  No trains, modules, accumulators, fast belts, beacons, nuclear or quality.
- **No one set research in shake12.** The queue left by shake11 ran on (worker-robots-speed-3, weapon-shooting-speed-6,
  then planet-discovery-fulgora, defender, automobilism), slowly: every lab sat idle on utility packs at the start
  ("All 28 labs are idle for lack of utility packs", Opus, 02:59).
- **Sleep:** Opus 93% of the window in Python sleeps, Muse 81% and Grok 82% in `fh sleep`, Sonnet 46%, Haiku 31%.
- **The night:** three shifts since 18:48 (game minutes 570 to 1,188), 66 to 85 technologies, rockets 10 to 25,
  roboports 0 to 11, requester chests 0 to 99, flamethrower turrets 0 to 12; still one planet and both platforms at
  Nauvis; deaths 5, 6 and 13 so far.

## 1. Research notices

| Technology | Finished | Notice first seen | Agents who saw it | Unlocks (as the notice lists them) |
| --- | --- | --- | --- | --- |
| worker-robots-speed-3 | 03:15 | Gemini 03:15:25 | 9 | worker-robot-speed +45% |
| weapon-shooting-speed-6 | 04:47 | Gemini 04:47:42 | 9 | gun-speed |

A notice reads "research done: worker-robots-speed-3, unlocks: worker-robot-speed +45% (0s ago)" in the reply's team
block, so the `control.lua` refresh worked. Neither technology unlocks a recipe or building, so "time from a notice
to first use" has nothing to measure in this window; the first technology that unlocks something buildable will be
the test (planet-discovery-fulgora and defender are next in the queue).

The shift-start block reached all nine agents in their first replies: "researched_none_built": "accumulators
(electric-energy-accumulators); fast belts (logistics-2)". By 05:26 neither had been built.

## 2. The tools index in use

From the journals, 02:58 to 05:26 (successful calls):

| Tool or feature | Calls | Who, first | What |
| --- | --- | --- | --- |
| `board_plan` | 43 | all nine, from 02:58 | plan lines ("Expand logistic fleet and fix yellow-science supply", Astra) and reads |
| `requests` (logistic requests) | 179 | Astra, Gemini, Grok and others | requester chests for the science and silo supply |
| `circuit` | 4 | Astra 03:33; Sol 05:02 to 05:19 | Astra: a logistic condition, coal < 2000; Sol: enable on signal-A > 0, then on heavy-oil > 1000 |
| `wire` | 2 | Sol 05:08, 05:19 | red wires to the switched machine |
| `use_item` | 1 | Sol 04:53 | a grenade at (40,-53) |
| Roboports, requester and provider chests | 6 roboport crafts, 28 requester and 47 provider crafts | Astra from 03:02 | the logistic network grows: 11 roboports, 99 requester chests at 05:26 |
| Flamethrower turrets | 6 crafts | Astra 05:18 | 12 at 05:26 |
| Bulk inserter | 1 | Astra 05:07 | |
| Trains, modules, beacons, accumulators, fast belts, nuclear, quality | 0 | | |

In the agents' words: Sol to Astra and Luna at 03:23, "I have 250 piercing and 30 grenades; checking south defense
now"; the grenade followed at 04:53. No agent text mentions trains, rails, modules, accumulators, fast belts or the
shift-start block's list.

Hand feeding of turrets: 23 `rearm` calls (Sonnet 15), 39 magazine transfers and 13 magazine crafts in 148 minutes,
more than shake11's 5, 21 and 8 in 155 (deaths and raids were up too).

## 3. Research choices

Research-setting calls (`research` with a technology or queue):

| Shift | Calls | What was put first |
| --- | --- | --- |
| shake10 | 7 | damage and shooting-speed 5 to 6 (20:15); then research-speed-4, military-3 (22:18), flamethrower (22:24), circuit-network, accumulators, defender, automobilism (22:45) |
| shake11 | 11 | logistic-system (23:00), worker-robots-speed-1 to 3, inserter-capacity-bonus-2, planet-discovery-fulgora, worker-robots-storage-1 |
| shake12 | 0 | none: shake11's queue ran on |

So the choices broadened in shake10's last hour and in shake11 (logistics, robots, inserters, a planet discovery),
then stopped: in shake12 no agent touched the queue, and the binding limit was utility science, not the choice
("Yellow still PU limited", Astra, 03:04; "weapon shooting speed6 next20%, needs ~1600 yellow/red/green/blue/military",
Sol, 03:05).

## 4. Sleep

`fh sleep` from the journals plus shell and Python sleeps from the transcripts (asked minutes), 02:58 to 05:26 (148
minutes), with shake11's figures (22:53 to 01:28):

| Agent | fh sleep s12 (s11) | Shell or Python sleep, asked min s12 (s11) | Asleep in all, about | Character busy while asleep |
| --- | --- | --- | --- | --- |
| Opus | 2% (72%) | 138 (4) | 95% | 97% (its own `tools/cycle.py` courier) |
| Grok | 82% (64%) | 7 (16) | 87% | 100% |
| Muse | 81% (2%) | 19 (138) | 94% | 98% |
| Sonnet | 46% (83%) | 6 (5) | 50% | 0% |
| Luna | 34% (7%) | 5 (1) | 37% | 4% |
| Haiku | 31% (46%) | 0 (5) | 31% | 0% |
| Gemini | 19% (1%) | 2 (0) | 20% | 0% |
| Astra | 11% (14%) | 0 (0) | 11% | 49% |
| Sol | 8% (27%) | 0 (0) | 8% | 98% |

("Asleep in all" adds the two and caps at 100%; a shell sleep can overlap an `fh sleep` only in a background loop,
which none of these used.)

- Muse moved back from shell sleeps (shake11) to `fh sleep`; Opus moved the other way, with a script doing its work.
- Tells end most `fh sleep` calls (191 of 400 wakes), then time (69) and mentions (80); the queue wakes fire 18 times.

## 5. The night in numbers

Per shift from the score's first and last unpaused lines (shake12 to 05:26):

| | shake10 | shake11 | shake12 (to 05:26) |
| --- | --- | --- | --- |
| Wall time | 18:48 to 22:49 | 22:54 to 02:53 | 02:59 to 05:26 |
| Game time (minutes from shake4) | 570 to 808 | 811 to 1,043 | 1,047 to 1,188 |
| Technologies | 66 to 76 | 76 to 83 | 83 to 85 |
| Researched | damage 3 to 5, speed 3 to 5, research-speed-4, military-3, flamethrower, circuit-network | accumulators, logistic-system, robot speed 1 and 2, robot storage 1, inserter capacity 2, damage 6 | robot speed 3, shooting speed 6 |
| Science packs used a minute | 39.6 | 31.7 | 34.4 |
| Rockets launched (total) | 10 to 18 | 18 to 22 | 22 to 25 |
| Platforms | Solstice, Helios, both at Nauvis | the same | the same |
| Planets | Nauvis | Nauvis | Nauvis |
| Roboports | not counted | 6 | 11 |
| Requester chests | not counted | 49 | 99 |
| Gun / flamethrower turrets | not counted | 136 / 9 | 141 / 12 |
| Stone walls | not counted | 230 | 229 |
| Steam engines / solar panels / accumulators | 20 / 19 / not counted | 30 / 18 / 0 | 38 / 18 / 0 |
| Assembling machine 2 / labs | 90 / 28 | 102 / 28 | 108 / 27 |
| Transport belts (yellow; no fast belts) | 1,435 | 2,166 | 2,796 |
| Trains, beacons, nuclear | 0 | 0 | 0 |
| Deaths (agents) | 5 | 6 | 13 |
| Buildings lost (largest count per area) | 695 in 41 areas | 692 in 67 areas | 315 in 60 areas |

"Not counted": the score's entity list grew during shake11 (`entities_counted`); shake10's last line counts only the
older names.

## Methods

Scripts in the session scratchpad, read-only on `runs/`: research notices are "research done" lines in replies and
first use is the first successful request naming an unlocked item; tool use is every request whose action is new or
names a feature's entity; research choices are `research` requests with a technology or queue; `fh sleep` from
`sleep` requests and their final `sleep_check`, shell and Python sleeps from each harness's transcript (Claude Code
projects files, Codex rollouts, Grok, agy and Muse sessions); the night table from each run's `scores.jsonl` (first and
last unpaused line), deaths as distinct respawn ticks in the replies, losses as the largest count per area in the
replies' "losses in ..." lines.
