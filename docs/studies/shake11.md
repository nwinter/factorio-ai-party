# Shake11, early look (22:54 to about 02:00)

Shake11 resumes shake10's world on world n with the same nine agents, from game minute 810. New in this shift: the
RCON broker (agents hold no password), the viewer relay (viewer lines reach agents through Clef), and, hot-deployed
at about 23:40, research notices in the team block, the team plan (`fh board plan`), circuit, train and rail tools,
and the hosts' round 4. The playbook's tools index and the reworded asteroid test reach agents only from shake12.
Times are PDT; game minutes are tick/3600 from shake4's start. Data only, read-only on the game.

## P1

1. **Research notices never fired in shake11, and cannot until the mod is refreshed.** The notice code reached the
   runtime in the 23:40 hot deploy (the runtime's `describe` lists `board_plan` from 23:45; Luna's `describe.json` was
   rewritten at 23:51), but the game only passes `on_research_finished` to the runtime if the mod's `control.lua`
   forwards it, and that forwarding came with 9246c0f (22:18), after shake11's launch commit 5ce8c32. A hot deploy
   replaces the runtime bundle, not the installed mod's `control.lua`. logistic-system finished at 23:40 and
   worker-robots-speed-1 at 23:52; no reply in any journal carries a "research done" line. The next shift's start
   ("refresh the instance's harness mod", `tools/start-team.sh:65`) installs the new `control.lua`; check the first
   finished technology in shake12 shows up in replies. A deploy check that compares the running mod's forwarded
   events with the bundle's handlers would catch this class of gap (`tools/code_check.py`).
2. **Agents do not know about the team plan.** `fh board plan` works in the runtime from 23:45, but shake11's
   `AGENTS.md` was built from 5ce8c32, which predates the plan's docs (1bca16b): no agent has called `board_plan`.
   The docs reach agents from shake12.
3. **Two agents wait in sleeps the harness cannot see or wake.** Muse waits with a shell `sleep 280` and then reads
   its queue: 46 such sleeps asking 64.6 minutes of its first 72 in shake11, against 5 `fh sleep` calls. Sonnet does
   the same through Python to get past Claude Code's block on chained shell sleeps (`python3 -c "import
   time;time.sleep(1200)"`, up to 20 minutes; 15 calls asking 218 minutes of shake10's 240), each after "Clear the
   mention by reading chat." Neither wakes on a tell, a mention, a board change or an attack, and neither shows in the
   journals, so every journal-based sleep figure so far (the sleep study's, shake10's below) undercounts these two:
   Sonnet's shake10 share reads 1% from the journal. Tool-level options: count shell and Python sleeps in the study
   scripts from the transcripts (as section 3 does), and decide whether the agents' shells should allow a bare
   `sleep` at all (`tools/launch-agent.sh` allows `Bash(sleep:*)` for Claude; `tools/permit.py` lists `sleep`).

## Short answer

- **The team turned to logistics and new defences on its own, before any new tool reached it.** Astra proposed
  the logistic system at 22:59:49 ("requester chests could eliminate long couriers"), Sol agreed at 23:00:12, and by
  01:26 the score counts 5 roboports, 32 requester chests, 5 flamethrower turrets (two from shake10's end), 121 gun
  turrets and 228 stone walls. This continues shake10's last 42 minutes, when a research stall (no utility packs for damage-6) sent the team
  to cheap technologies it had never taken: flamethrower, military-3, circuit-network.
- **Research notices never fired** (P1 item 1), and **no one used the team plan** (P1 item 2): 0 `board_plan` calls.
- **Sleep:** Opus 72%, Sonnet 83%, Grok 64%, Haiku 46% in `fh sleep`; Muse 2% there, but 89% in shell `sleep`
  (P1 item 3). Tells and mentions still end most sleeps.
- **The broker held without friction:** 0 refusals, no agent mentions it; its forwarded counts are written only when
  it stops.
- **The viewer relay had nothing to relay:** no viewer wrote between 22:53 and 01:28.
- **Hosts:** 628 aired lines, 60% of the writer lines by Opus 5.5 after round 4; 4% templates; the planet check cut
  five lines about Vulcanus; no unused-unlock remark aired.

## 1. Research notices

None fired. Five technologies finished in the window, `electric-energy-accumulators` (22:58),
`logistic-system` (23:40), `worker-robots-speed-1` (23:52), `inserter-capacity-bonus-2` (00:16) and
`worker-robots-storage-1` (01:00), 76 to 81 in all, with `physical-projectile-damage-6` researching at 01:26. No
reply in any journal carries a "research done" line, and no agent called `research_done`. The cause is in P1 item 1:
the forwarding of `on_research_finished` lives in the mod's `control.lua`, which the hot deploy does not replace.

The question "did any agent act on an unlock afterwards" therefore has no notice to time from. Without notices, the
agents acted on research they had chosen themselves: the logistic system was proposed, queued and its buildings
built as it went (roboports and logistic robots from 23:02, requester chests from 23:39, as `logistic-system`
finished; the score shows it at 23:40). Accumulators finished at 22:58 and none was built by 01:26.

## 2. The team plan

No one wrote or read it: 0 `board_plan` requests, and no `board` reply carried a plan (there is none to carry).
The runtime has the command from the 23:40 deploy; the agents' `AGENTS.md` does not describe it (P1 item 2), and only
Luna regenerated `describe.json` (23:51), which lists `board_plan`. Coordination ran as before: board posts per job
("Build first science logistics robot network | Sol approved", Astra 23:01) and tells asking each claim owner for a
roboport footprint (Astra to Opus, Gemini, Muse, Grok, 23:02 to 23:17; approvals from Sol, Gemini and Muse by 23:14).

## 3. Sleep

`fh sleep` from the journals, and shell or Python sleeps from the transcripts (asked minutes; a shell sleep runs its full
length). Shake7 and shake10 are whole shifts; shake11 is 22:53 to 01:28 (155 minutes).

| Agent | fh sleep share s7 / s10 / s11 | Shell or Python sleep, asked minutes s7 / s10 / s11 | s11 woke on: told / mentioned / time / other |
| --- | --- | --- | --- |
| Opus | 82% / 46% / 72% | 2 / 5 / 4 | 68 / 63 / 124 / 6 |
| Sonnet | 88% / 1% / 83% | 0 / 218 / 5 | 12 / 48 / 6 / 11 |
| Haiku | 87% / 35% / 46% | 3 / 27 / 5 | 38 / 18 / 30 / 5 |
| Muse | 53% / 28% / 2% | 1 / 104 / 138 | 3 / 2 / 0 / 0 |
| Grok | 34% / 63% / 64% | 0 / 18 / 16 | 40 / 17 / 19 / 9 |
| Sol | 24% / 10% / 27% | 0 / 0 / 0 | 52 / 11 / 10 / 18 |
| Astra | 20% / 18% / 14% | 0 / 0 / 0 | 37 / 7 / 5 / 17 |
| Luna | 9% / 20% / 7% | 0 / 1 / 1 | 11 / 5 / 10 / 5 |
| Gemini | 1% / 1% / 1% | 0 / 4 / 0 | 1 / 0 / 5 / 0 |

(Shake10's Opus figure is low because its runtime refused 2,487 of its requests during the quarantine.)

- The sleep tools merged after shake7 are used: 18 `queue_done`, 15 `queue_stalled` and 10 `condition` wakes in
  shake11. Tells (262) and mentions (171) still end most sleeps.
- Opus sleeps 72% with its character busy only 14% of that time, against 93% in shake7: its courier queue no longer
  runs while it sleeps. Grok's character is busy 100% of its sleeps, Sonnet's 99%.
- Muse and, in shake10, Sonnet wait mostly outside `fh sleep` (P1 item 3). Muse's shell sleeps cover 89% of shake11
  so far; no wake can reach it.

## 4. The broker and the console audit

`runs/shake11/broker.log` has 9 lines, one `listening` event per bot at 22:53:21, and no `refused` or `rcon_error`
event. The forwarded counts are written only in the `stopped` event (`tools/fh_broker.py`, `log(event="stopped",
counts=...)`), so they arrive at 02:53. No agent's text mentions the broker, a socket, a password or RCON, and no
reply carries a broker error. The 18 refusals in the first two minutes (22:53:40 to 22:55:23, all nine agents) are
the runtime's loss-incident fault ("agent-harness/runtime:8746: attempt to compare number with nil"), which stopped
at 22:55:23, consistent with the fix (27640e9, 22:56) being hot-deployed then; none is the broker's.

Console audit at shake10's end (`runs/shake10-stop.out`, tick 2,910,933): 191,435 harness requests and 21,356 other
commands in 41 shapes. Operator 15 shapes (21,296 commands), server 2 (3), deploy 23 shapes (56 commands, including
12 runtime installs over RCON between ticks 1,734,171 and 2,578,784, inside shake8 to shake10's play), moderation
none, UNKNOWN 1: a one-off Lua read counting turrets and walls at tick 2,311,198, which Nick identified as an operator
read. Shake11's audit comes at its stop.

## 5. The viewer relay

Nothing to relay. The viewer logs for the shift (`tools/stream/logs/viewers-20261011-225309.jsonl` and
`viewers-20261011-233024.jsonl`, after the stream service's 23:30 restart) are empty, the viewer answers log is empty,
and `chat.jsonl` has no viewer line. No viewer wrote between 22:53 and 01:28, so the relay, Clef's drops and the
agents' answers are untested in this shift.

## 6. Defence and the unused features

From the score (now counting these buildings) and the journals, 22:53 to 01:28:

| Feature | Built or used | First |
| --- | --- | --- |
| Roboports | 5 at 01:26 (score) | crafted 23:02, first working 23:15 (Astra) |
| Logistic robots, construction robots | crafted and moved into roboports | 23:02, 23:31 (Astra) |
| Passive-provider chests | 24 builds, existing courier chests upgraded in place | 23:08 (Astra: "Upgraded SCIENCE iron ... to passive providers, same positions, contents") |
| Requester chests | 32 at 01:26 (score), 22 builds | 23:39 (Astra), as logistic-system finished (the score shows it at 23:40) |
| Storage chests | queued | 00:35 (Astra) |
| Flamethrower turrets | 5 at 01:26 (score; Astra's two on the south wall date from shake10's last minutes), oil-fed | crafted 22:59 (Sol); "Militaryflamer(14,57.5)S built" 23:03 |
| Gun turrets, walls | 121 turrets, 228 walls (score) | |
| Grenades | queued in Sol's plans | 00:04 |
| Accumulators | researched 22:58, none built | |
| Trains, circuit network, modules, beacons, nuclear | nothing | |

Hand feeding is down: 5 `rearm` calls, 21 magazine transfers (Astra 10, Haiku 8) and 8 magazine crafts in 155
minutes, against 26, 59 and 45 in shake10's four hours. The agents' own explanation for the turn is shake10's research
stall and the iron cost of ammunition ("flamethrower defense to save iron ammo", Astra, shake10 22:17; "a flamethrower
should make the next visit less exciting", Astra, 23:12).

## 7. Hosts

`tools/stream/copy_report.py runs/shake11/caster.log` at 01:26: 628 aired lines, 600 by a writer model and 28
templates (4%), 15 fallbacks, $1.92 an hour. Round 4 went live with the stream service's restart at 23:30: Opus 5.5
(OpenRouter) wrote 362 of the 600 writer lines and Kimi K2.6 238, with Opus taking most beats after 23:40.

- Style: 0% dash pivots, 0% lines ending on "!", 0.8% lines with three or more numbers (13% in shake4 to shake6),
  12.1 words a line. 55 cuts, 25 for style: "X, not Y" 11, metaphor 5, walking filler 3, mocking an agent 3, too many
  numbers 3.
- Facts: 11 cuts for a name not in the facts, 6 for saying the shift is ending early, 5 for a planet not reached (for
  example "And Sol's packing for Vulcanus already."), 3 for numbers not in the facts.
- Unused unlocks: no aired line remarks on research the team has not built on. The hosts did announce finished
  research ("There it is. Electric accumulators, done. Defender's up next.", Rook, 22:56).

## Methods

Scripts in the session scratchpad, read-only on `runs/shake11/` (live): research notices are "research done" lines in
replies; plan writes are `board_plan` requests and reads are `board` replies carrying a plan; features are successful
requests naming each entity, plus the score's entity counts; `fh sleep` from `sleep` requests and their final
`sleep_check`, shell and Python sleeps from each harness's transcript (Claude Code projects files, Codex rollouts,
Grok, agy and Muse sessions); broker events from `broker.log`; host lines from `caster.log` and
`tools/stream/copy_report.py`. The research-notice cause was found by comparing the launch commit's `control.lua`
(5ce8c32) with the commit that added the forwarding (9246c0f). The window ends at 01:28.
