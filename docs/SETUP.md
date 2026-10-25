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
| sa | 34210 | 27030 | bots (Space Age smoke tests, `tools/sa_smoke.py`; see `docs/SPACEAGE.md`) |

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

### Context compaction

`tools/launch-agent.sh` runs `tools/context.py setup KIND MODEL DIR`, which applies the per-model compaction point
from `agent/context.tsv` (model, kind, window, compact_at) without touching global CLI config:

- Claude Code (Haiku 80K, Sonnet 200K, Opus 250K): workspace `.claude/settings.json` gets
  `autoCompactWindow = compact_at + 33000` and hooks: `SessionStart`/`compact` prints `notes.md` after a compaction,
  `PostToolUse` warns the agent to update `notes.md` (in the second half of the room above the post-compaction
  context, and at least 20% before the point), `Pre/PostCompact` log. `PostToolUse` (Claude and Muse) also shows,
  once each, the operator's tells fh filed (`OPERATOR: ...`) and the mentions and tells in fh replies' team blocks
  (the journal since its last look) that the tool call's own output did not show (`MENTION: ...`, `TELL: ...`; at
  most 10 and a count; shift08: Sonnet's replies went to /dev/null for 2h20m).
- Codex (140K): workspace `.codex/config.toml` (`model_context_window`, `model_auto_compact_token_limit`); loads
  because run dirs are inside the trusted repo.
- Grok (60%): `GROK_AUTO_COMPACT_THRESHOLD_PERCENT` on the launch command, `--rules`, and the repo's
  `.grok/hooks/context.json` (Grok reads project hooks only from the git root; they act only in run dirs).
- Antigravity (200K): no setting; `.agy-loop.sh` starts a fresh conversation once `context.py agy-tokens` passes it.
- Muse (200K): `muse -c context_compaction.soft_threshold=... -c context_compaction.hard_threshold=...`, fractions
  of its 512K effective window (soft 0.391, hard 0.441); `.muse/hooks.json` re-injects `notes.md` after a compaction.

Launch hygiene and supervision (shake2 and shake3 studies; details in `docs/LAUNCH2-NOTES.md` and
`docs/LAUNCH4-NOTES.md`). The env and flag words are in `tools/profile-flags.sh`:

- Claude Code starts with `--setting-sources project,local` (no user settings: hooks, plugins),
  `--tools Bash,Read,Edit,Write,Grep,Glob`, and no silent-turn reminder or git status
  (`CLAUDE_CODE_SILENT_TURN_REMINDER=0`, `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1`); `tools/permit.py` (a `PreToolUse`
  hook) approves `./fh` loops and other commands built only from game programs and workspace redirects, which dontAsk
  otherwise denies.
- Codex workspaces turn off the skills list and bundled skills (`[skills]`), the multi-agent role block (empty
  `[features.multi_agent_v2]` hint texts), host skill discovery, plugins, apps and browser and computer use.
- Grok gets `--allow` rules for `./fh`, `python3` and workspace edits, the switches for Claude- and Cursor-compat
  skills, rules, hooks, MCP servers and named files, managed MCP, memory, subagents and workflows, and a run-local
  `GROK_HOME` (`tools/grok-home.py`: no home rules, owner hooks or skills; login through an auth-provider command
  that reads the owner's token read-only and has the owner's grok refresh it before a launch when short). Loops cannot
  be approved under dontAsk; `agent/harness-grok.md` points to `python3`.
- Muse gets `-c 'hooks={}'` (none of the owner's hooks; the workspace's still load) and no skill-reminder agent or
  memory tools (`MUSE_EXPERIMENTAL_*`).
- `tools/start-team.sh` starts every pane first and then clears trust prompts for all of them in one pass
  (`tools/clear-prompts.sh`).
- Before a run or shift, `tools/start-team.sh` (and its dry run) prints warnings, never stops:
  - `tools/quota_check.py TEAM MINUTES` reads `ai-usage agent --json` and projects each route's quota windows over
    the run with the burn rates in `agent/quota-burn.tsv`.
  - `tools/code_check.py` warns when main, or a branch active in the last 24 hours, has harness or `tools/stream`
    commits this checkout lacks, or when `dist` is older than `host/*.ts`. The runtime deploy is logged with its
    sha256.
- The agy loop sleeps through a quota error (`tools/agy-quota.py` writes `agy-quota` to `context.log`) and stops
  when the reset falls after the deadline.
- An agent whose account is at its limit (a quota window at 99% or more with its reset ahead, from the quota check
  above, saved as `runs/RUN/quota-brief.json`) gets a quota rest until the reset once the agents launch
  (`tools/quota_rest.py --at-limit`: `resting.json` and the runtime's `rest`); it is launched anyway, and its first
  request ends the rest if it can play. By hand: `tools/quota_rest.py RUN AGENT --until "YYYY-MM-DD HH:MM"
  [--reason quota|pace]`, `--done` to end it (d22 batch108 BR1).
- A resumed run starts with every rest of the previous run that has not ended (quota or pace, by hand or by
  `--at-limit`; `--carry PREV_RUN`, which start-team passes): until the same time, whatever ai-usage says. A quota
  rest is not carried only when a fresh reading (under 30 min old, the profile not stale) gives the account room, and
  the start log says so; an account at its limit rests until the later of its reset and the carried rest (d24
  batch172: Muse's rest until Sun 17:00 was lost at shift70's start because ai-usage read Muse stale).
- The agy memory guard (`tools/agy_memguard.py`, d22 09:27: one agy turn grew to 21 GiB and filled the Mac's swap
  because agy loads every untracked file at a fresh session, and `runs/` was not ignored; `.gitignore` has `runs/`
  since then) kills a process under a run's `.agy-loop.sh` whose footprint passes 4 GiB (TERM, then KILL after 5 s).
  It logs to `runs/RUN/agy-memguard.log` and to the workspace's `context.log` (`agy-memguard`). start-team starts it
  when the team has an agy agent, one per Mac (lock `/tmp/pog-agy-memguard.lock`), and stop-team leaves it running.
  `tools/agy_memguard.py --check` says whether one runs.
- No compaction in an agent's last 2 minutes: Claude Code's `PreCompact` hook blocks it, and the agy loop starts no
  fresh conversation; Grok, Codex and Muse have no control for it.
- `tools/supervise.sh` logs how each nudge was delivered (falls back to typing into the pane when
  `herdr agent prompt` fails), notes turns that ended on a refused command and adds a rewrite hint, and skips a
  Grok nudge in the last 3 minutes when its context is near the compaction point.
- `tools/context-probe.sh --profile KIND MODEL [ROUTE]` checks a clean profile headless;
  `tools/smoke-launch.sh [RUN] [MINUTES] [KINDS]` checks the launch live (both outside the sandbox: they need the
  CLIs' own folders, the herdr socket and ai-session's cache).
- `POG_FULL_TOOLS=1` (off by default) gives every harness its own `tools/`, a shared `team-tools/`, a read-only
  `gamedata/` (the prototype dump), subagents and web search and fetch, with a short "Your tools" paragraph in
  AGENTS.md (`tools/full_tools.py`, `agent/full-tools.md`). Probe: `tools/context-probe.sh --full --profile KIND
  MODEL`; smoke: `POG_FULL_TOOLS=1 tools/smoke-launch.sh smoke-ft 6`. Details: `docs/TOOLS-NOTES.md`.
- `POG_BROKER=1` (off by default): the operator's RCON broker (`tools/fh_broker.py`) holds the world password, the run
  has no key, and each agent's `fh` reaches only its own bot through `runs/RUN/.sock/BOT.sock`. Needs the harness
  rebuilt (`cd vendor/factorio-harness && npm run build`: `fh --socket`). Smoke: `POG_BROKER=1 tools/smoke-launch.sh`.
  `tools/stop-team.sh` prints the broker's refusals and, always, the console audit (`tools/console_audit.py`: console
  commands that were not harness requests). Details and what still leaks: `docs/LAUNCH-NOTES.md`, "Fairness".
- Human players: the harness logs what each human does (`fh players`), puts a player's first join in the
  `pog-guest` permission group, and takes the agents' kick, ban and trust votes. `POG_PLAYERS=1` (off by default)
  makes `start-team.sh` run the operator tally (`tools/players.py watch`, results in `runs/RUN/votes.jsonl`);
  `POG_PLAYERS_PROTECT=nick` keeps names from being kicked or banned. `POG_TRUSTED_PLAYERS` (default `nick`)
  are names that join a fresh save in the normal group instead of the guest group. By hand: `tools/players.py --world W
  show|once|trust NAME|guest NAME`. Details and what opening the server would need: `docs/PLAYERS-NOTES.md`.

`AGENTS.md` ends with `## Compact instructions` (`agent/compact.md`) and `notes.md` starts as a structured skeleton.
Hook events go to `DIR/context.log`, summaries to `DIR/compactions.md`; `tools/context.py report runs/RUN_ID`
summarizes them. Live check per harness (outside the sandbox; all five verified 2026-10-10):
`tools/context-probe.sh [-C CHECKOUT] KIND MODEL [COMPACT_AT]`; offline tests: `python3 tools/test_context.py`.
Details and the evidence behind each setting: `docs/CONTEXT-NOTES.md`.

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
- YouTube (unlisted test stream): OBS `pog` profile streams to `rtmps://a.rtmps.youtube.com:443/live2` (note `rtmps` in the
  host) with the key from `~/.config/pog/youtube.key` (never commit it); Quick Sync H.264 at 6 Mbps. 2-minute test:
  0 dropped frames, no congestion. `tools/obs.py stream-start|stream-status|stream-stop`.
  Since 2026-10-11 the profile is in Advanced output (`tools/obs_profile.py advanced`: 2 s keyframes, which Simple mode
  could not set; YouTube flagged 7.9 s) and outputs 1920x1080 at 12 Mbps on Quick Sync (`obs_profile.py 1080p --encoder
  qsv --bitrate 12000`). NVENC is not available to OBS 32.2.2 on the box ("Encoder ID 'obs_nvenc_h264_tex' not found",
  NVIDIA driver 535.98); a failed start leaves a "Failed to start streaming" dialog that blocks OBS from closing.
  Keep the service on "Custom" (`rtmp_custom`). OBS 32.2.2's built-in "YouTube - RTMPS" service crashed OBS at stream
  start (`YouTubeAppDock::IngestionStarted`, 2026-10-11, no account connected), and the crashed process kept the
  capture pipes and the browser profile locked until it was killed in Task Manager.
  A broadcast that sits at "Preparing stream" while OBS reports frames going out is waiting to be started: Go live in
  the Live Control Room, or turn on auto-start there.

## Shifts (resuming a team world)

One command does the change:

```sh
tools/shift-change.sh shake11 shake12 240 --stream --dry-run   # checks, PREV's switches, the plan; touches nothing
tools/shift-change.sh shake11 shake12 240 --stream             # stop shake11, close its panes, start shake12 resumed
POG_SEED=N tools/public-start.sh RUN VIDEO_ID --dry-run           # the public run's first shift, from scratch: plan only
POG_SEED=N tools/public-start.sh RUN VIDEO_ID                     # old runs to the archive, site run_start, chat cleared, start
```

It refuses, with the reason, when shake11 ran no agents (no notes.md), the quota check has a WARNING, the box or OBS
does not answer, another start-team or shift change is running, shake12 already started, or shake11 is streaming and
neither `--stream` nor `--no-stream` was given; `--ignore quota` (or `notes`, `box`, `obs`, `running`, `stream`)
skips a check. shake12 gets shake11's switches (`POG_BROKER`, `POG_FULL_TOOLS`, `POG_SPACE_AGE`, `POG_YOUTUBE`,
`POG_CASTER_MODEL`, `POG_CASTER_URGENT`, `POG_CASTER_LOW_MODEL`, `POG_CASTER`, `POG_ANALYST`, `POG_PLAYERS`, the viewer relay's current state
and the team file), read from `runs/shake11/switches.env` (start-team writes it), else from its running helpers and
logs (`tools/shift_change.py switches runs/shake11 --explain` shows them and where each came from), plus
`POG_RESUME=shake11` and `POG_NEXT_SHIFT` at shake12's end. Three minutes after the start it prints a health line
(agents with a request, broker sockets, OBS and the stream service, relay on or off, harness Lua errors so far; exit 1
when something is down) and shake11's console audit. The steps by hand:

```sh
POG_STOP_WORLD=1 tools/stop-team.sh shake4 n                  # save, then stop server and directors (game time stops)
POG_RESUME=shake4 POG_SPACE_AGE=1 POG_DRY_RUN=1 tools/start-team.sh shake5 60   # the plan, touches nothing
POG_RESUME=shake4 POG_SPACE_AGE=1 tools/start-team.sh shake5 60 --stream        # same save, bots and notes carry over
python3 tools/resume_check.py runs/shake5 n                    # tick, research, buildings, bots, notes carried over
```

The newest of `saves\shake4.zip` and later autosaves is copied to `saves\shake5.zip`; `POG_SPACE_AGE` must match the
instance's mods. `POG_OBS=0` for test shifts. Details: `docs/HARNESS3-NOTES.md`, round 7.

## Bots and director cameras

Many agents share one world as bots (characters without a client); 1-3 director clients show them. Details in
`vendor/factorio-harness/docs/usage.md` and `docs/BOTS-NOTES.md`.

```sh
tools/winps.sh tools/win/start-client.ps1 -Name live -Slot -director -PlayerName pog-director   # keeps the world running (auto_pause)
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","astra"))'
POG_WORLD=live bin/fh --bot astra call status                                                  # FH_BOT=astra in a run's wrapper
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","camera",helpers.table_to_json({player=1,follow="astra",zoom=0.8})))'
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","profile_ticks",600))'   # average in factorio-current.log
```

## Gotchas

- `--wait-timeout` is in milliseconds.
- `fh describe` and `fh doctor` fail with "Invalid bridge response" on the first command to a fresh save
  (Factorio's one-time "commands disable achievements" warning eats it). Repeat the call.
- Screenshots need a graphical client: a player's own, or for a bot the first connected director. `./shot` writes
  `script-output\pog\<ws>\` in that client's folder (`D:\pog\inst\<world>-client<slot>\`), and
  `tools/shot-sync.sh RUN_DIR CLIENT_DIR...` copies it into the workspace (start-team.sh starts it for the cam clients;
  for other runs start it by hand, e.g. `tools/shot-sync.sh runs/RUN a-client b-client`).
- The server answers harness queries while `game.tick_paused` is set, so a turn-based mode is possible.
- A failed non-read call stops that player's current action. Tools that poll (overlay, watchers) must use read-only
  calls (`status`, `chat` with `peek`) and the world must run the current runtime (`fh deploy`).
- OBS's old "Untitled" profile shows an expired-Twitch-login dialog on start that blocks closing and WebSocket;
  `tools/win/obs-dismiss.ps1` presses OK. `tools/win/desktop-shot.ps1` screenshots the box's desktop.
- One OBS process for a day fails: on 2026-10-13 08:29, after 24.5 h, Quick Sync gave MFX_ERR_MEMORY_ALLOC and the
  stream and recording stopped; restarting the outputs did not help, a new OBS did. `tools/obs-restart.sh` (outputs
  off, `tools/win/obs-restart.ps1` closes OBS from Nick's session, forces after 30 s, starts `pog-obs`, answers the
  Safe Mode and Authentication Failure dialogs, then waits for the websocket) runs at every shift change between
  stop-team and start-team, and in start-team for `--stream`. Mid-shift, `tools/obs-recover.sh` retries the outputs
  once and restarts OBS if they do not come up, then runs `tools/obs-steps.sh --stream`. All take `--dry-run`.
- NVENC is unavailable in OBS 32 ("outdated_driver": NVIDIA driver 535.98 from 2023); recordings use Intel Quick Sync.
  OBS applies output settings changed over WebSocket only when a profile loads: switch to a temporary profile and back.
- OBS's NDI plugin keeps an output running, which blocks frame-rate/resolution changes (stays 1080p60).
- Runtime size: `fh deploy` compacts the bundle (about 411 KB in October 2026) and sends bundles over 512 KiB in
  chunks, which needs the server's mod to have the chunked install (`control.lua` from eng/harness2, October 2026).
  A world started before that takes at most 524288 bytes per deploy; restart it with the current mod to go higher.
- After a mid-shift runtime deploy (`POG_WORLD=n bin/fh deploy`), `python3 tools/refresh_workspaces.py runs/RUN` writes
  every workspace's describe.json (one read of the new runtime's describe), ref/ and the core's command index again from
  this checkout; the rest of each AGENTS.md stays. fh help ACTION follows the deploy by itself (its describe is kept per
  bundle id).
- After a `control.lua` change, restarting the server on the same save works, but each client's mod copy must be
  refreshed too (`scp -r .../agent-harness_0.1.0 pogwin:D:/pog/inst/<world>-client<slot>/mods/`), else joining fails
  with `multiplayer.script-mismatch`. Re-running `start-client.ps1` while its task exists printed nothing and did not
  relaunch; `Stop-ScheduledTask`/`Start-ScheduledTask pog-<world>-client<slot>` did.
- A crashed server leaves its scheduled task "Ready" but `start-server.ps1` may not relaunch it; start the task again.
- Video memory: each low-graphics client takes ~1 GB of the RTX 2070's 8 GB; close idle clients during recordings.
