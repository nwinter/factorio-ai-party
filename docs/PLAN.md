# Player of Games: Factorio

Goal: AI agents play Factorio autonomously and fairly, first to a base-game rocket
launch, then through Space Age, with the real run recorded (and optionally streamed).

## What we know works (as of 2026-10-10)

- GPT-6 Astra beat a standard game with enemies (Mira's run): ~44 h in-game,
  4 d 11 h on the Codex `/goal` clock, ~$4,500 API-equivalent. It designed
  blueprints with scripts, tested them on a disposable headless copy of the save,
  rushed construction robots, and drove the live game with scripted inputs.
- Daniel Vestøl's harness (Space Age 2.1): client-side Lua sandbox for world
  queries, actions sent as InputActions (the multiplayer input stream), MCP tools,
  occasional screenshots. Astra launched rockets and reached a third planet;
  in the same harness Fable 5.1 stalled at power/oil and Luna got nowhere.
  The agent learned to spawn other Codex threads to improve its own harness.
- FLE (research benchmark): plain code-synthesis APIs get agents to basic
  automation but not to complex chains.

Takeaway: the wins came from long-horizon persistence, a testing sandbox, and
letting the model write its own tools on top of honest primitives. Reaction
speed matters less than keeping the LLM out of low-level loops.

## Hardware

- Mac Studio (M1 Ultra, 64 GB): already loaded (load avg 10 to 13, memory
  pressure, ~12 GB free disk). Runs nothing heavy for this project.
- Windows box (<windows-box-ip>, OpenSSH for Windows): game server(s), sandbox,
  graphical client, OBS. Specs TBD.

## Architecture

```
 Brain (LLM sessions, subscription CLIs)
   strategist: Codex/Astra (/goal) or Claude Code (Opus 5.5 / Fable 5.1)
   harness engineer: separate session that fixes/extends skills from failure logs
        │ MCP tools
 Executor (Python, deterministic)
   skills: walk/path, mine, craft trees, place, feed, build-from-blueprint, ...
   planners: ratio calc from dumped prototypes, blueprint compiler, layout check
   reflexes: rules first; Clef / Clef-flash for fuzzy fast triage (~0.4 s)
        │ RCON (JSON in/out)
 Game (Windows box)
   live server + "pog" mod: job queue run per tick, honest actions, event buffer
   sandbox server: clone of live save at high speed for tests and dry runs
   graphical client joined as the agent's player -> OBS recording
```

Time: the live game pauses while the strategist thinks and runs during executor
jobs, so in-game time is the score and wall clock is whatever it costs.

## Reuse (survey 2026-10-10)

No existing project meets the whole bar. Starting points:

- CarsonBurke/factorio-harness (MIT): `fh` CLI (TypeScript) -> RCON -> Lua mod
  running per-tick actions. No teleport or free items; builds through
  `build_from_cursor` with distance checks, real mining state, per-player
  permission checks; blueprints, action queue, space platforms, rocket launch.
  Works the same from Claude Code and Codex. Plan: fork as the base layer.
- linsyking/factorio-mcp (MIT): honest pathfinding/walking/mining/crafting,
  one MCP instance per character, job queue, fog of war. Borrow multi-agent ideas.
- LukaVodopivec/factorio-codex (MIT): two Codex brains steering one character
  through Space Age. Very new; read for Space Age flow.
- khoyga007/Factorio-MCP: borrow "holdout audits" (prove a line runs unattended)
  and its blueprint catalog; its actions are remote, so not its action layer.
- FLE: borrow evaluation method and renderer; its default actions teleport.
- czp3009/factorio-mcp: injects literal keyboard/mouse input on Windows x64, if
  we later want human-equivalent input.

Version: pin stable 2.0.77 (factorio-harness and linsyking target it). 2.1 is
still experimental (2.1.21 as of 2026-10-06).

Replay caveat: replays need the save created in the GUI with "Record replay" on,
and break if mods are added, removed or updated mid-run. During the real run the
Lua mod is frozen; self-improvement happens in the Python layer and in Lua
chunks sent as commands. OBS is the primary recording; the replay is a bonus.

## Fair-play rules (enforced in the mod, audited from logs)

Allowed: walking at character speed, mining/crafting at real speed with real
inventory, placing/inserting/taking within reach, research queue, importing
blueprint strings, robots once researched. Not allowed: creating entities or
items from nothing, teleporting, revealing uncharted map, editing game speed
of the live world. World queries are limited to charted chunks.

## Milestones

1. Infra: server + client on Windows, RCON reachable from the Mac, mod loaded.
2. Primitives, observation (text map + rendered PNG), sandbox clone, tests.
3. Brain loop on a fixed-seed benchmark (red science automated, then green),
   scored by in-game ticks; A/B Astra vs Claude models per role.
4. Self-improvement loop: harness engineer works from failure logs, tests in
   sandbox, hot-reloads skills.
5. Real run: base game, default settings, enemies on, recorded, replay kept.
6. Space Age: access, harness gaps, cost and staged plan in `docs/SPACEAGE.md`.

## Results so far (2026-10-10)

Same seed (20261010), peaceful, base game. Game time to each milestone (agent-logged):

| Milestone | Astra low, realtime | Astra low, turns | Fable 5.1 low, realtime | Fable 5.1 low, turns |
|---|---|---|---|---|
| Burner mining + smelting | 7:49 | 3:52 | 8:25 | 5:50 |
| Steam power | 10:56 | 6:37 | 17:15 | 7:00 |
| Assembler red science into labs | 17:02 | 10:48 | 20:08 | ~13:00 |
| Automation/logistics + electric mining | 23:23 | 16:16 | partial | 17:40 |
| Green science automated | 30:12 | 20:29 | hand-fed | ~28:30 |
| Oil | none found | petroleum 55:45, plastics 50% | none | none |

- Realtime runs: 43 wall minutes. Turn runs: ~90 wall minutes, ~50-56 game minutes.
- Quota: Astra low ~3% of a Codex weekly per 45-90 min; Fable low ~1% of a Claude weekly per 45 min.
- Biggest time sinks for both: hand-carried fuel/plates, scouting for oil, self-inflicted power outages.
- Harness fixes from the runs are logged in `docs/HARNESS-CHANGES.md` (engineer agent, merged, tests passing).
- Round three (3 h each, turn mode, merged harness) started 13:00 in `runs/2026-10-10-turns3h/`.

### Round three and co-op 1 (2026-10-10 afternoon)

- Round three (turn mode, 3 h, merged harness): Astra reached blue science (14 packs) at game 1h20 despite a
  16-minute uncontrolled stretch from a harness crash (construct nil target, fixed); Fable reached 12 technologies and
  was building toward oil. Both lost their last 15-40 minutes to client drops (see below).
- Co-op 1 (Astra + Opus 5.5, real time, 2 h, peaceful): 25 technologies including robotics; blue science consumed by
  game 1h34; 364 blue, 1,731 green, 1,867 red packs; 32k iron plates; 1,302 belts. Clear division of labor (Astra:
  smelting and science; Opus: power, fuel, oil, sulfur) negotiated in game chat; 100+ chat messages. Recorded from
  game 0h35 (Quick Sync; NVENC needs a newer NVIDIA driver); 41-second time-lapse in `D:\pog\recordings`.
- Open problem: graphical clients in the turn-mode worlds were dropped by the server ("You have been dropped from the
  game", heartbeat removal) several times from 15:19, including shortly after reconnects; the real-time co-op clients
  never dropped. `tools/rejoin.sh WORLD` reconnects; `tools/watch.py` now alerts. Next architecture should need fewer
  graphical clients (director cameras, script-driven characters).
- Quota measured: Astra ~2.5% of a Codex weekly per agent-hour; Claude agents ~1% of a Claude weekly per agent-hour.
