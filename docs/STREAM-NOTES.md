# Stream overlay and director service

`tools/stream/` is the viewer-facing layer for the co-op stream (contract: `docs/BOTS-API.md`, "Overlay / director
service"). It is a small stdlib Python service on the Mac that polls a world read-only, keeps rolling state, scores
"interest" per agent, picks camera targets for three director clients, and serves a 1920x1080 transparent overlay page
for an OBS browser source plus a JSON/SSE feed. It is built for 9 agents and degrades to 12.

## Run it

```sh
python3 tools/stream/serve.py --mock --port 8788                    # synthetic 9-agent session (runs/mock9.json)
python3 tools/stream/serve.py --mock --run tools/stream/runs/mock12.json --port 8788   # 12-agent density test
python3 tools/stream/serve.py --world c --port 8788                 # paused co-op save, read-only (runs/coop1.json)
python3 tools/stream/serve.py --world live --run RUN.json --port 8788   # a bots world once eng/bots lands
ssh -N -o ControlMaster=no -o ControlPath=none -R 8787:127.0.0.1:8788 pogwin   # OBS reaches it as 127.0.0.1:8787
```

Port: the contract uses 8787 on both ends, but on the Mac 8787 is currently held by an unrelated node server
(`~/code/zai`). So the service listens on `--port 8788` and the reverse tunnel maps the box's 8787 to it; the OBS
source URL stays `http://127.0.0.1:8787/`. If 8787 is free, run with the default port and `-R 8787:127.0.0.1:8787`.

Endpoints: `/` overlay page (`/?preview=1` adds a checkerboard and camera placeholders for a desktop browser),
`/state.json` latest snapshot, `/events` SSE (one full snapshot per second), `/director.json` last 60 decisions.

Other flags: `--poll 3` (seconds, 2-5), `--cameras 3,4,5` (director player indices, main first; overrides the run
config), `--no-camera` (decide and log but never call `camera`), `--profiles auto|on|off`, `--mock-speed 4`
(game seconds per wall second), `--mock-start 40` (game minute the replay starts at).

## OBS

```sh
PY=tools/.venv/bin/python        # the venv lives in the main checkout: ~/code/player-of-games/tools/.venv
$PY tools/obs.py stream-scene                       # scene "stream": background, 3 game captures, overlay on top
$PY tools/stream/obs_shot.py out.png [--reload]     # switch to "stream", screenshot, switch back to "co-op"
$PY tools/obs.py reload-overlay                     # refresh the browser source after editing the page
$PY tools/obs.py shot out.png --scene stream        # screenshot without switching (the browser source may be blank)
```

- Captures: `stream cam1..3` capture windows of `factorio-cam1.exe`, `-cam2`, `-cam3` (start the director clients with
  `start-client.ps1 -Slot -cam1 -PlayerName pog-cam1`, etc.). Their rectangles come from
  `tools/stream/static/layout.json`, which the page also reads, so the frames and labels line up: main 1208x680 at
  (24,24), cam2 596x336 at (24,720), cam3 596x336 at (636,720). The right column (x 1256..1896) is overlay only.
- `obs_shot.py` refuses to switch scenes while a recording is active. Browser sources only render while their scene
  is live, which is why it switches.
- The camera player indices in the run config (`cameras`) must match the director clients' player indices (join
  order). Directors are real players, so the harness `camera` function puts them in spectator mode.

## Run config (`tools/stream/runs/*.json`)

```json
{"title": "...", "subtitle": "...",
 "agents": {"astra": {"model": "GPT-6 Astra", "harness": "Codex", "role": "Smelting & science"}, "...": {}},
 "cameras": [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}],
 "landmarks": [{"name": "iron smelting", "x": -62, "y": -18, "r": 22}],
 "director": {"main_dwell": 20}}
```

Model labels, harness and role come only from here, never from agents. Names, colours, glyphs and mottos come from
`profiles`; config `display_name`/`color`/`glyph` are fallbacks (used for world c, whose runtime predates profiles).
Agents that `profiles` reports but the config lacks are shown without a model label. `kind: "player"` plus `player`
index reads a real player (world c); anything else is read as a bot by name. `landmarks` turn positions into place
names; without one the card says e.g. "50 m W" (distance and bearing from spawn).

## What it polls (read-only)

Every poll (default 3 s), over one persistent RCON connection, using the same
`remote.call("agent_harness", "dispatch", json)` that `bin/fh` sends:

- `profiles` (only with the eng/bots runtime, see below), `status` per configured agent, `chat` with `peek: true` and
  a `since` cursor. With `profiles`, status is round-robin (a third of the agents per poll; position, alive and the
  current action come from `profiles` every poll). Without it, every agent's status is read every poll.
- If the world does not answer at startup, the service keeps serving and re-probes every minute.
- `tools/pog.py`'s score Lua (tick, research done/current, production totals), plus `STREAM_LUA` in
  `tools/stream/harness.py`: research progress, the four costliest finished technologies (seeds "recent milestones" on
  start) and the count of electric machines in `low_power`/`no_power` status.
- Every 30 s: per-item production for the last hour in 2-minute buckets (sparklines).

`harness.Harness.dispatch` refuses anything outside `READ_ACTIONS` (`status`, `profiles`, `chat`, `power`, `cameras`)
and refuses `chat` without `peek`. The only non-read call is the operator `camera` remote function, sent through a
guard that prints `{"ok":false,"stub":true}` when the harness lacks it, which is what happens until eng/bots lands.

`profiles` gating: the current runtime treats an unknown action as a failed mutation, and `control.lua` then calls
`stop_player(request.player or 1)`, which would interrupt player 1's action every poll. So `--profiles auto` only
polls `profiles` when the harness exposes the `camera` remote function (same eng/bots delivery). eng/bots must also add
`profiles` (and `cameras` if it is a dispatch action) to `read_only` in `control.lua`, or every failed `profiles` call
stops a player.

## State, interest and the page

- Activity per agent: `acting` (status/profiles `active` is set), `thinking` (no action, but one ended or the agent
  spoke within 90 s), `idle`, `dead` (with a respawn countdown from `dead_until_tick`), `offline` (a player whose
  client is disconnected, as in world c).
- Interest (`model.py`): decays with a 75 s half-life. Bumps: starting an action (weights in `ACTION_WEIGHT`, build >
  mine/craft > walk), sustained action, chat (+2), combat start (+6), death (+5), and +2.5 for the two most recently
  active agents when a technology finishes (the contract's "research completion credit"; the harness does not say who
  fed the labs).
- Alerts: attack (an agent's status `combat` going true, or a base area in status `alerts.attacked` hit within the
  last 30 game seconds, which also raises interest for agents within 60 tiles of it), death, low power (more than 25% of at least 10 electric machines
  starved, not while paused), research complete. Each key is rate-limited and shown for up to 40 s.
- Page (`static/`): agent cards (glyph avatar on the agent's colour, display name, harness tag, model label and role,
  status dot and current action, location, camera badge), research card with progress and latest milestones,
  production sparklines (six series: two or more materials plus the newest science packs), chat with avatars,
  game-time and relative timestamps and age fading, alert toasts over the main camera, and a label on each camera
  frame naming who it shows. Updates are keyed DOM edits, so only changed parts animate.
- Colour fallback: any colour works. Name text is lightened until it has 4.5:1 contrast on the panel; glyph ink is
  black or white, whichever contrasts more with the fill; a fill that disappears into the panel gets a ring; emoji
  glyphs sit on a dark tint of the colour with a ring in it. Invalid colours fall back to a hue hashed from the name.
- Density: up to 7 agents use roomy 100 px cards, 8-9 use 84 px (5 rows of 2), 10-12 use 66 px (7 rows); the
  research card takes the last grid cell and the chat panel gets whatever height is left.

## Director

`director.py`, run once per second over the latest snapshot. Main camera on the highest score (interest plus a small
bonus for time off air, halved when idle). It holds a subject for at least `main_dwell` (20 s; secondaries
`side_dwell` 12 s). After that a challenger needs 1.6x + 2 the current score to cut, or after `max_dwell` (60 s) the
camera rotates to the best agent no camera is showing. Voluntary cuts are at least 4 s apart across cameras. Secondary
cameras take the next best agents. When a free agent is within 40 tiles of a camera's subject, the camera frames both
(midpoint, zoom `60 / (distance + 24)`, clamped 0.3..0.7), keeps that partner until 50 tiles, and re-sends the
midpoint when it moves 6 tiles (at most every 2 s). If a higher camera takes a lower camera's subject, the lower
camera takes the higher camera's previous subject (swap).

Each decision is appended to `tools/stream/logs/director-<start>.jsonl`: time, slot, reason, target agents and zoom,
the exact `camera` body sent, the harness reply, and the top five scores. Tune with:

```sh
python3 tools/stream/simulate.py --minutes 30 [--set main_dwell=25 --set switch_margin=2]   # mock, fake clock
python3 tools/stream/simulate.py --log tools/stream/logs/director-....jsonl                  # stats for a real run
python3 tools/stream/selftest.py      # eng/bots shapes, read-only guard, camera call (no game needed)
```

With the current defaults a 30-minute 9-agent mock gives about one main-camera cut per minute, a median dwell of
about 60 s on every camera, and main-camera time for all nine agents. Combat-heavy agents get the most.

## Verified

- Mock (9 and 12 agents) and world c (paused co-op 1 save; read-only polls only) both render in OBS through the
  reverse tunnel, as screenshotted by `obs_shot.py`. World c shows the real clock (1h59m, paused), construction
  robotics at 89%, 25 technologies, and real production history; both players are offline there.
- `selftest.py` passes.

## What's left

- The `camera` function and `profiles` exist only in the contract so far. Once eng/bots lands: confirm the `profiles`
  reply shape (`{profiles: [...]}` or a bare list; both are accepted), which identity the read should carry (the
  service sends the first configured bot), what `camera` returns, and that directors move as logged. Then start three
  director clients and check the framing zoom numbers on screen.
- Chat on world c is unavailable: the runtime refuses `chat` for disconnected players and there is no connected
  reader. With bots it reads as a bot. `last_said` from `profiles` is ingested but only the chat feed shows it.
- `control.lua` stops `request.player or 1` on a failed non-read call. For bot requests (no `player`) that would hit
  player 1; eng/bots should key this on the bot.
- Base-attack alerts use status `alerts.attacked` (tested against the shape in `threat.lua`, not yet against a real
  attack: world c is peaceful). Losses (`alerts.latest`) are not shown.
- Research credit goes to the most recently active agents, since nothing says who fed the labs.
- Production uses coloured lines, not Factorio item icons (the client has no Space Age data and the icons are not
  served anywhere).
- The 8787 port conflict on the Mac (see above).
