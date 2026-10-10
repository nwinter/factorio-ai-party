# Setup and operations

## Machines

- Windows box `pogwin` (<windows-box-ip>): runs every Factorio process. SSH key `~/.ssh/pog_windows`, user `player`,
  default shell cmd. Run PowerShell scripts there with `tools/winps.sh tools/win/SCRIPT.ps1 -Arg value`.
- Mac: runs the agents (`fh` CLI, Claude Code, Codex) and reaches each world's RCON through an SSH tunnel.

## Layout on the box

```
D:\pog\factorio-2.0.77\        Steam build copy (servers). Runs fine as --start-server; as a client it
                               restarts itself through Steam, so it is not used for clients.
D:\pog\factorio-2.0.77-alpha\  Standalone base-game build from factorio.com (clients). No Space Age data:
                               the Space Age DLC is owned on Steam only.
D:\pog\mods\                   agent-harness mod copied into each new instance
D:\pog\inst\<world>\           server write-data: config, mods, saves, server-settings.json, rcon.pw
D:\pog\inst\<world>-client\    client write-data: config (muted, windowed, low graphics), mods, script-output
```

Nick's own Factorio (`%APPDATA%\Factorio`, Steam install) is never touched.

## Worlds

| World | Game port | RCON port | Player |
|---|---|---|---|
| live | 34197 | 27015 | pog-agent (dev/smoke tests) |
| a | 34201 | 27021 | pog-a |
| b | 34202 | 27022 | pog-b |

Servers and clients start as scheduled tasks in Nick's desktop session (`pog-<world>-server`,
`pog-<world>-client`), so they survive SSH disconnects and clients render on the desktop.

```sh
tools/winps.sh tools/win/new-instance.ps1 -Name a -Save base1 -Peaceful       # fresh map, seed 20261010
scp ~/.config/pog/rcon-a.pw pogwin:D:/pog/inst/a/rcon.pw
tools/winps.sh tools/win/start-server.ps1 -Name a -Save base1 -GamePort 34201 -RconPort 27021
tools/winps.sh tools/win/start-client.ps1 -Name a -GamePort 34201 -PlayerName pog-a
ssh -N -L 27021:127.0.0.1:27021 pogwin &                                      # RCON tunnel
POG_WORLD=a bin/fh doctor                                                     # first call on a fresh save is swallowed; repeat
POG_WORLD=a bin/fh deploy                                                     # always: the save may carry an older runtime
tools/pog.py --world a save && tools/winps.sh tools/win/stop-world.ps1 -Name a
```

## Operator tools (agents never get these)

- `tools/pog.py --world W score|pause|resume|save|quit|rcon CMD`
- `tools/score-loop.sh RUN_DIR SECONDS WORLD...` appends snapshots to `RUN_DIR/scores.jsonl`.

## Agent runs

`tools/new-run.sh RUN_ID WORLD PLAYER MINUTES` makes `runs/RUN_ID/WORLD/` with `AGENTS.md` (from
`agent/PLAYBOOK.md`), a `CLAUDE.md` symlink, `./fh` and `./shot` wrappers bound to the world, `notes.md` and
`deadline.txt`. Launch with `ai-session spawn ... -C runs/RUN_ID/WORLD --prompt-file runs/RUN_ID/prompt.md --start`:

- Codex: `--route codex-b --model gpt-6-astra --thinking low --sandbox workspace-write --network --approval never`
- Claude: `--route claude-b --model fable --thinking low --permission-mode dontAsk`, with an allowlist in the
  workspace's `.claude/settings.json`.

## Co-op worlds and recording

- Several clients per world: `start-client.ps1 -Slot -astra -PlayerName pog-astra` gives each its own folder, task and
  renamed executable (`factorio-astra.exe`) so OBS can capture each window. Player indices follow join order.
- `tools/new-run.sh` co-op env: `POG_WS`, `POG_CLIENT`, `POG_PLAYER_INDEX`, `POG_TEAMMATE`, `POG_TEAMMATE_WS`, `POG_ROLE`.
  `tools/launch-agent.sh` puts a run in its own Herdr tab; `POG_TAB=<tab>` adds the second agent beside the first.
- Chat: agents use `say`/`chat`; unread messages ride on every reply. Plain text sent over RCON
  (`tools/pog.py --world c rcon "message"`) reaches them as `server:`.
- OBS (profile and scene collection `pog`, Quick Sync HEVC to `D:\pog\recordings`, ~2.6 GB/hour): `tools/.venv/bin/python tools/obs.py
  coop-scene|start|stop|status|shot`. Needs `tools/tunnel.sh 4455`. `tools/overlay.py --world c` feeds the text panel.
- Stream overlay and director cameras (many agents): `tools/stream/` and `tools/obs.py stream-scene`; see
  `docs/STREAM-NOTES.md`.
- Watchers: `tools/watch.py --worlds a,b,c runs/RUN...` reports key research, summaries, harness faults and blocked agents.

## Gotchas

- `--wait-timeout` is in milliseconds.
- `fh describe` and `fh doctor` fail with "Invalid bridge response" on the first command to a fresh save
  (Factorio's one-time "commands disable achievements" warning eats it). Repeat the call.
- Screenshots need the graphical client; they land in `D:\pog\inst\<world>-client\script-output\`.
- The server answers harness queries while `game.tick_paused` is set, so a turn-based mode is possible.
- A failed non-read call stops that player's current action. Tools that poll (overlay, watchers) must use read-only
  calls (`status`, `chat` with `peek`) and the world must run the current runtime (`fh deploy`).
- OBS's old "Untitled" profile shows an expired-Twitch-login dialog on start that blocks closing and WebSocket;
  `tools/win/obs-dismiss.ps1` presses OK. `tools/win/desktop-shot.ps1` screenshots the box's desktop.
- NVENC is unavailable in OBS 32 ("outdated_driver": NVIDIA driver 535.98 from 2023); recordings use Intel Quick Sync.
  OBS applies output settings changed over WebSocket only when a profile loads: switch to a temporary profile and back.
- OBS's NDI plugin keeps an output running, which blocks frame-rate/resolution changes (stays 1080p60).
- Video memory: each low-graphics client takes ~1 GB of the RTX 2070's 8 GB; close idle clients during recordings.
