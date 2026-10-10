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

## Gotchas

- `--wait-timeout` is in milliseconds.
- `fh describe` and `fh doctor` fail with "Invalid bridge response" on the first command to a fresh save
  (Factorio's one-time "commands disable achievements" warning eats it). Repeat the call.
- Screenshots need the graphical client; they land in `D:\pog\inst\<world>-client\script-output\`.
- The server answers harness queries while `game.tick_paused` is set, so a turn-based mode is possible.
