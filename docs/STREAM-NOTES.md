# Stream overlay and director service

`tools/stream/` is the viewer-facing layer for the co-op stream (contract: `docs/BOTS-API.md`, "Overlay / director
service"). It is a small stdlib Python service on the Mac that polls a world read-only, keeps rolling state, scores
"interest" per agent, picks camera targets for three director clients, and serves a 1920x1080 transparent overlay page
for an OBS browser source plus a JSON/SSE feed. It is built for 9 agents and degrades to 12.

![9-agent mock in the OBS "stream" scene with the Factorio UI kit, pixel avatars, team board, science-per-minute production and the larger chat (director clients not running, so the camera areas are empty)](stream-overlay-fx9.png)

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
- Every 30 s: per-item production for the last hour in 2-minute buckets, for every item in `model.STAGE_ITEMS`
  plus the science packs (about 35 names; the Lua skips items the game does not know or never made, so a fresh map
  costs little).

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
  last 30 game seconds, which also raises interest for agents within 60 tiles of it), losses (status `alerts.latest`
  lines, the runtime's `describe_incident` text, when the newest hit is under 2 minutes old: "7 lost near (12, -40):
  4 stone wall, 3 gun turret (by 5 small biter)"), death, low power (more than 25% of at least 10 electric machines
  starved, not while paused), research complete. Each key is rate-limited and shown for up to 40 s.
- Look: eng/art's `factorio-ui.css` (docs/ART-NOTES.md) is loaded before `overlay.css`, which uses its `--fx-*`
  tokens: grey beveled panels, cream headings with the ridged title filler, deep inset wells for chat and production,
  alert strips with a coloured left edge, corner brackets on the camera frames (agent colour, red during an attack).
  The body gets `fx-overlay` only (not `fx-root`, whose box-sizing reset would shift the layout). No `color-mix()`:
  OBS's browser is Chrome 103. Font: Titillium Web from Google Fonts, falling back to Segoe UI offline.
- Avatars: `avatar.js` draws each agent's pixel avatar from its `profiles` row (`avatar` parts; unset parts come from
  the name, so every agent has one before choosing). Cards 48-64 px, chat 32, board and camera labels 24. Without
  `avatar.js` the old glyph circle is the fallback; the server/operator keep a gear glyph.
- Page (`static/`): agent cards in three lines (name, harness tag and camera badge; model, then the motto in italics
  or a quiet "profile not set"; status dot, current action and location), research card, production widget, chat,
  alert toasts over the main camera, and a label on each camera naming who it shows. Updates are keyed DOM edits.
- Production widget: a headline of science packs made per minute (all colours summed from flows or score deltas),
  with a 1-hour trend, one chip per pack colour with its rate, and the stage the factory has reached (Raw resources,
  Automation, Steel & logistics, Oil, Advanced, Rocket: the furthest stage any item or pack has been made in). Below
  it four item cells, each with eng/art's 32 px pixel icon (`items.js`, `PogItems.svg`; the pack chips use the 16 px
  pack icons), label and colour from `PogItems`, rate, and a sparkline in the item colour. `model.production()` ranks the items made in the last few minutes:
  weight 3 for the current stage, 2 for one stage back, 1 for two, 0.5 older (iron and copper plates at least 2),
  times `1 + log10(1 + rate)`. With more than four, the top two stay and the other two cells page through the rest
  every 10 s. With five or more pack colours the trend and stage label give way to the chips.
- Chat: the largest panel, in three lanes.
  - Talk (the deep well, 18 px text up to three lines, last ten): lines eng/audio's classifier heuristic
    (`caster.heuristic_kind`) calls banter, strategy or emotion, lines an agent marked `aloud` (🔊), and confessionals.
  - Viewers (below it, only while a viewer message is under 5 minutes old): see Viewer chat.
  - Ticker (two 19 px lines at the bottom): coordination (coordinates, counts, "on it") and server lines.
  - `model.chat_lane()` labels every line talk / log / viewer. Relayed viewer lines in the game chat (`viewer: true`)
    are left to the viewers lane. The snapshot's `chat` keeps the last 12 talk and the last 8 other lines, so a burst
    of logistics cannot push conversation off the page.
- Confessionals (eng/board `confess`, audience.lua): read with the operator `confessions` read (`operator: true`,
  no player; a failure stops nobody), every poll from a cursor, only once `describe` lists `confessions` (on an
  older runtime the request would count as player 1's unknown action and stop it). They show in the talk lane with a
  "to camera" tag, italic cream text and the agent's colour edge.
- Captions (audio.js, eng/audio's voice player): each caption shows the speaker's portrait. Hosts come from
  `casters.js` (eng/art) via the clip's `who` key, with their role; agents use their own avatar, looked up in the
  latest snapshot (`window.pogState`). The edge and name are in the speaker's colour, lightened to 4.5:1 on the grey
  frame (Luna's near-black becomes grey).
- Night lift (`nightlift.py`): `STREAM_LUA` reads `LuaSurface.darkness` (0 by day, about 0.85 at midnight; world n
  at dusk read 0.24). A "night lift" colour correction filter on `stream cam1..3` (created if missing) ramps gamma
  up to 0.6, brightness 0.03, contrast 0.12 and saturation 0.15 as darkness goes from 0.2 to 0.75, at most 0.04 of
  the lift per second, and is sent only when it moves 0.03. The game is not touched. On by default with `--world`
  (`--no-night`; `"night": {...}` in the run config to tune; `night` in the snapshot shows darkness, lift and the
  values sent).
- Colour fallback: any colour works. Name text is lightened until it has 4.5:1 contrast on the grey panel; glyph ink
  is black or white; a fill that disappears into the panel gets a ring. Invalid colours fall back to a hue hashed from
  the name (avatar.js has its own palette fallback for the pixel art).
- Layout of the right column (1032 px): one-line 46 px header, cards, board (156 px, when present), production
  (92 px), chat (the rest). Cards: up to 7 agents 84 px, 8-9 agents 70 px (5 rows of 2), 10-12 agents 60 px (7 rows).
  Chat at 9 agents is about 316 px with the board (was 220) and 482 px without; at 12 agents with the board, 242 px.

## Team board (docs/BOARD-API.md, "Overlay")

- Polling: `board_events {since_seq}` every poll, `board {limit: 60}` plus `board {kind: "claim"}` every 15 s. Both
  only after the read-only `describe` lists `board` and `board_events` (re-checked every 5 minutes, since a runtime
  can be installed mid-run): on an older runtime the unknown action fails and the failed call stops the reading bot.
  `status` and `board` are sent with `peek: true`, which makes eng/board leave the reading agent's `team` hint cursors
  alone; a runtime that rejects the argument (main today) gets plain reads, logged once.
- Event shape (eng/board `board.lua`): `{seq, tick, by, id, change, title, kind, owner, requested_by, status, text}`,
  `change` = posted | taken | assigned | released | note | a status. The model keeps an item cache from events
  between `board` reads (a read always wins), drops notes and operator bookkeeping, and bumps interest a little for the
  agent who posted, took or finished something.
- Panel (between the cards and production, 156 px): open unowned requests (amber when any), items in progress, active
  claims; the last three events ("Luna posted REQUEST Piercing ammo...", "Grok took ...", "Gemini finished ...",
  "is blocked on" in red) with the agent's avatar and age; one "Harness v4 · plan_save / plan_run macros" line for 10
  minutes after a `harness` item is done (merged with the operator's `server: harness vN: ...` chat line when both
  arrive within 3 minutes); and up to three active claims with avatars. Without a board runtime the panel is hidden
  and chat takes its height.

## Viewer chat (docs/VIEWERS-NOTES.md)

`--viewers-youtube TARGET`, `--viewers-site`, `--viewers-replay JSONL` start `tools/stream/viewers.py` inside the
service; the snapshot then carries `viewers` (filtered messages, oldest first) and `viewers_status`. Without these
options `viewers` is an empty list and `viewers_status` null. The page draws the last two messages under five minutes
old in a blue lane in the chat panel: a YT or SITE tag, the name (yellow for YouTube staff), the text on one line,
and "to the agents" on messages flagged as orders. Viewer names and text are set as text, never HTML.

## Segments (shots the casters or the director start)

`segments.py`; API agreed with eng/audio, whose casters request them (docs/AUDIO-NOTES.md "Segments").

- `GET /segments` -> `{types: [{type, title, params, seconds: [min, max], available, why?}], busy, next_ok}`.
- `POST /segment {type, params, seconds, by, reason}` -> `200 {id, state: "queued", eta, seconds, title, facts}`,
  `409 {error: busy | declined | unavailable, retry_after}`, or `400 {error: bad type | bad params}`.
- The snapshot carries `segment: {id, type, state: starting | live | ended, started, ends, title, facts, by, reason,
  cut?}` or null. starting is 2.5 s (fade in; the caster writes its lines), then live until `ends`, then ended for 5 s.
- `facts` are every name and number the page shows, computed once at accept time; the page draws a segment from its
  facts only, so the hosts (held to the facts by the caster's fact check) and the screen agree.

| type | seconds | on screen | camera |
|---|---|---|---|
| production | 20-45 | panel over the main camera: SPM, pack rates, up to 6 items with icons, now vs 10 min ago, biggest gain and drop | unchanged |
| research | 15-30 | panel: current technology, progress bar, done count, latest four | unchanged |
| spotlight `{agent}` | 20-45 | lower-third card: model, motto, current action and location, latest chat line, claims | main follows the agent (zoom 0.9) |
| overview | 15-30 | card: agents in the world, spread, areas | main on the agents' centre, zoom 0.2 or wider to fit |
| recap `{minutes}` | 20-40 | panel: SPM, research finished, board items done, attacks, deaths in the window | unchanged |
| attack_replay | 15-40 | the OBS "replay" scene (see Replays); available while a fresh clip waits | program scene switch |
| space | 15-30 | panel: planets reached, rockets, platforms (where or route, speed), space-age science made, who is off Nauvis; available once the Space panel shows | unchanged |
| space_moment `{moment}` | 12-25 | a Space Age moment (below): full panel, or a lower card for a landing with an agent | a landing follows the agent (zoom 0.9) |

Rules (the director has the last word): one segment start per 180 s whoever asks (`spacing`). When the director
cuts the main camera to a fight, death, base attack or loss, a running segment ends at once (`cut: "attack"`) and
requests are declined for 20 s after that cut (`declined`). Alerts the director lets pass (a fight inside its 45 s
attack spacing, or `attack_cut: false`) neither end nor block segments, so a busy stretch does not wipe them out. After 6 quiet minutes (`lull_after`) the director starts
the next of production, spotlight, research, overview, recap itself (`by: "director"`). Tune with `"segments": {...}`
in the run config. Checked: selftest (states, spacing, spotlight hold, cut, lull), and all five types requested over
HTTP on the mock and rendered in jsdom on both pages. Not yet seen in OBS.

Captions and cards: voice captions (audio.js `#voice`) grow up from the main camera's bottom edge. overlay.js measures
the caption stack into the CSS variable `--voice-clear`; a full panel always leaves a caption band under it (124 px
landscape, 130 px portrait, more if a caption is taller) and a lower card (spotlight, overview, the replay's "coming
up" card) rises above a caption while one shows. Fixes the pilot's 01:41 shot, where Rook's caption covered the
replay card.

## Space Age

Data (read-only): `score` (tools/pog.py) gives rockets launched, `planets` (surfaces with our entities) and
`platforms` (name, location or "in transit"). Once a platform exists, live.py sends a `peek` `platforms` read per
platform (at most 4, every 15 s) for its state, `at` (a location or "from->to N%"), speed and pause. `status` gives
each agent's `surface` and `platform`. Bots all live on Nauvis until eng/spaceage's bot travel lands; nothing here
changes when it does, as long as `status` reports the bot's surface.

On the page:
- Agent cards: a planet chip (Nauvis green, Vulcanus orange, Fulgora violet, Gleba lime, Aquilo ice, platforms grey)
  once the Space panel is active; off Nauvis, the card's location is the planet or platform.
- Space panel, above chat, hidden until there is something: a rocket, a platform, space-age science, a second planet
  or an agent away. One head row (planets, science pack totals, else rockets), then up to three platform rows (name,
  where or route with a progress bar, km/s or "paused"). Chat gives up the height.
- Science: the five planet packs and promethium count toward SPM and get chips and colours.
- Moments, each once (what is already true when the service starts is recorded silently): first rocket, first
  platform, a platform's first arrival at each planet other than Nauvis ("orbit"), the first landing on each planet
  (an agent's body there, else "first foothold" when the score lists our entities). Each raises a 🚀 alert and the
  director starts a `space_moment` segment within 150 s (segment spacing waived; still declined right after an
  attack cut). Casters can request `space` or `space_moment {moment: id}` (ids in `snapshot.space.moments`).
- Speed is `LuaSpacePlatform.speed` x 60 shown as km/s, assuming the API gives km per tick. Not yet checked against
  the game's own readout.

Mock: `serve.py --mock --run tools/stream/runs/mock-sa3.json` (three agents) plays a rocket at 20 s, the platform
"Orbital One" at 40 s, its flight to Vulcanus from 70 to 130 s, a paused "Shuttle" at 100 s and Opus landing on
Vulcanus at 150 s (`"mock_space_speed"` scales it). Checked in jsdom on both pages and in the selftest; not yet seen
with a real platform, since the pilot had none by 02:00.

## Unused cameras

With fewer agents than cameras (or when the director pairs two agents on one), cam2 or cam3 would show an empty or
stale capture. After 4 s with no agent and no attack on it, the overlay covers the hole with an opaque "desk" card:
the analyst's headline, pace (ahead / on pace / behind) and up to three open storylines from `snapshot.analyst`,
else research (current technology, progress, latest three). A Space line is added when the Space panel is active.
It fades out as soon as the director uses the slot again.

## Replays

`replays.py`, operator go-ahead in REPLAYS.md (2026-10-11): the director may switch the program scene for replays
and segments as long as it always returns to "stream"; the replay buffer (45 s, recording encoder) stays enabled.

- When: the director's attack cuts drive it. After a cut to a fight or base attack, the buffer is saved 17 s later
  (just before the 20 s attack hold ends) and the last 15 s are replayed: the fight as main followed it. A death
  replays only if main showed that agent in the 10 s before (else the buffer holds nothing of it): saved 5 s after,
  shown from 11 s before to 4 s after. At most one replay per 120 s; a clip not on air within 120 s is dropped.
- How: the clip becomes an `attack_replay` segment (it skips the 180 s segment spacing, still waits for a free slot
  and for 20 s after the last attack cut), so the casters see it and talk over it. On "starting" the banner page is
  reloaded; on "live" the clip is loaded into the "replay clip" media source, seeked to the start of the window, and
  the program switches to "replay"; when the segment ends or is cut by a new fight the program goes back to
  "stream". A watchdog switches back whenever "replay" is on air with nothing playing.
- The "replay" scene (created on first connect if missing; an existing one is left alone): "replay clip"
  (ffmpeg_source, muted, since the clip's audio has the earlier voices in it), "replay banner" (browser source on
  `http://127.0.0.1:8787/replay`: REPLAY tag, what happened, a time bar, red frame) and the live "stream overlay"
  input off-canvas (x 4000) so the casters' voices keep playing during the replay.
- OBS access: `obsws.py`, a stdlib obs-websocket v5 client (serve.py stays dependency-free), on `--obs
  127.0.0.1:4455` (the SSH tunnel) with the password in `~/.config/pog/obs.pw`, as `tools/obs.py` uses. Replays are on
  by default with `--world` and off with `--mock` (`--replays` / `--no-replays`; `"replays": false` or tuning in the
  run config). `GET /replays.json`: connection, buffer state, pending / clip / playing, last replay, and encoder
  health every 30 s (CPU, fps, render time, render and output frames skipped since the last read, which outputs
  are active).
- Checked on the box (00:00-00:06, nothing live): scene created, buffer started, a test clip saved
  (`D:/pog/recordings/Replay_...mkv`, 41 s) and played from 26.3 s for 15 s in "replay", then back to "stream"; two
  more from the mock's deaths. With only the buffer running: 0 output frames skipped, 14 render frames skipped
  around the scene switch, CPU 9%. The banner did not show on the box (tunnel down, see What's left); in jsdom it
  renders the live segment ("Luna died", "21 s ago", time bar).

## Vertical (9:16) page

YouTube's phone views crop a 16:9 stream to its middle (x 656..1264 of 1920), which on this layout is the right
half of the main camera and none of the panels. `http://HOST:PORT/portrait` (`static/portrait.html`) is a
1080x1920 version of the overlay for a 9:16 canvas: the same elements and `overlay.js`, restyled by `portrait.css`,
with camera holes from `static/layout-portrait.json`:

| y (px) | what |
|---|---|
| 24-100 | title and clock |
| 112-693 | main camera, full width, 16:9 (1032x581): the director feed scaled, not cropped |
| 709-995 | cam2 and cam3 side by side (508x286 each) |
| 1009-1329 | agents, 3x3 (avatar, name, model, current action; no mottos, harness or location) |
| 1341-1417 | science per minute, pack chips, stage |
| 1429-1896 | chat, 27 px text |

Text is about 1.6x the landscape sizes, since a phone shows the canvas about 2.5-3x smaller. The board panel, the
research card and the item cells are left to the landscape page. Alerts sit over the main camera as on landscape.
Checked in jsdom against shake2's live state (cards, avatars, science strip, chat, the portrait layout file); not
yet looked at in OBS.

Getting it to viewers. This session could not reach the web or the OBS websocket (both refused by the permission
mode), so the following is from what was known before October 2026 and needs checking against YouTube's and OBS's
current docs before relying on it:

- YouTube shows a 9:16 live stream full screen on phones (and can surface it in the Shorts feed). One stream is
  one aspect ratio, so a horizontal and a vertical audience means either two live streams (two stream keys, one
  channel) or YouTube's own dual-format support, if it now takes both from one encoder. Check that first: if it
  exists, it decides the OBS side.
- OBS side, cheapest first: (1) the free Aitum Vertical plugin adds a second 9:16 canvas with its own scenes and
  its own stream output (its own key), sharing the sources already in OBS; (2) native multiple canvases; (3) a
  second OBS instance with its own profile (most CPU/GPU, two configs to keep in sync). Checked on the box
  (2026-10-11, read-only over obs-websocket): OBS 32.2.2, obs-websocket 5.7.4. `GetCanvasList` exists and lists one
  canvas, "Main" (1920x1080, 60 fps); the websocket has no request to create a canvas, so a 9:16 canvas has to come
  from a plugin (Aitum Vertical builds on these canvases) or OBS's own UI if this version exposes one.
- Proposed: Aitum Vertical (or a native canvas) with one vertical scene: a browser source on
  `http://127.0.0.1:8787/portrait` at 1080x1920, plus the three director window captures scaled into the holes above
  (main 1032x581 at 24,112; cam2 508x286 at 24,709; cam3 508x286 at 548,709). Cost: a second 1080x1920 encode on
  the same Quick Sync encoder (check headroom with `/replays.json` stats, below) and a second YouTube live event. No
  change to the existing `pog` profile output.
  Installing the plugin, adding the scene and the second stream are operator steps: the rules for this branch
  exclude output settings and starting streams.

## Director

`director.py`, run once per second over the latest snapshot. Main camera on the highest score (interest plus a small
bonus for time off air, halved when idle). It holds a subject for at least `main_dwell` (20 s; secondaries
`side_dwell` 12 s). After that a challenger needs 1.6x + 2 the current score to cut, or after `max_dwell` (60 s) the
camera rotates to the best agent no camera is showing. Voluntary cuts are at least 4 s apart across cameras. Secondary
cameras take the next best agents. When a free agent is within 40 tiles of a camera's subject, the camera frames both
(midpoint, zoom `60 / (distance + 24)`, at least 0.3 and at most the activity zoom), keeps that partner until 50 tiles, and re-sends the
midpoint when it moves 6 tiles (at most every 2 s). If a higher camera takes a lower camera's subject, the lower
camera takes the higher camera's previous subject (swap).

Zoom follows what the subject is doing (Factorio zoom, 1 = normal play view): fighting (`combat`, or a shoot / attack /
kite action) 1.05, building 0.95, mining / crafting / loading 0.85, idle 0.75, walking 0.5. A new activity must last
`zoom_settle` (5 s) before the zoom follows, so a short walk between two builds stays close and only long walks
widen; while an agent is thinking between actions the last zoom is kept; changes under 0.1 are ignored and zoom
changes are at most one per 5 s per camera. Zoom changes are smooth `camera` calls and do not count as cuts. A
30-minute 9-agent mock: about 1.2 cuts and 0.6-0.9 zoom changes per camera per minute.

Combat: a fresh (under 8 s old) attack or loss alert cuts the main camera at once, ignoring the dwell: to the agent
in the fight (its status `combat` went true), else to the nearest agent within 50 tiles of the attacked area (zoom
1.05, following), else to the area itself (`camera` with `position`, zoom 0.8). It holds 20 s (`attack_hold`), at most
one such cut per 45 s (`attack_spacing`). A death cuts to where the agent fell (zoom 1.1, 12 s), even inside the
spacing. The camera label shows the alert text with ⚔ or 💀 on a red edge. Status has no health field, so "taking
damage" is the `combat` flag plus base areas in `alerts.attacked`. `attack_cut: false` in the run config's `director`
turns all of it off.

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
- `selftest.py` passes, including board gating on `describe`, the eng/board event shape (from `board.lua` at
  eng/board 77a670c), loss-line parsing, changelog merging, attack cuts and the `peek` fallback.
- Board, mottos and alerts (2026-10-10, eng/stream2): the page was run in jsdom against `/state.json` from the 9-agent
  mock (board stats, three events with avatars, claims, "profile not set" on Sonnet, power/attack/loss banners, the
  attack label on the main camera) and from world n, read-only with `--no-camera` (the real mottos, Sonnet "profile
  not set", board panel hidden because n's runtime has no board).
- Art kit, avatars, chat, production, zoom and combat cuts (2026-10-10, after merging main with eng/board, eng/art
  and eng/audio): `selftest.py` covers activity zoom (a 2 s walk keeps the build zoom, a 7 s one widens), the death
  cut inside the attack spacing, the SPM headline and the stage ranking, and that no Lua sent through `one_line()`
  carries a `--` comment (one did, and broke the flows query on world n until fixed). jsdom against the 9-agent mock
  and world n (read-only, `--no-camera`): a pixel avatar on every card and chat line, the science row, four item cells,
  and with injected late-game data five pack chips (313/min) and the item cells paging every 10 s. The mock director
  cut main to "Luna died" at zoom 1.1. The flows query ran on world n (30 buckets per item, all zero: n is finished).
- OBS screenshot (the operator, from the 9-agent mock through the reverse tunnel; the image at the top): avatars
  sharp, Titillium Web loaded, the science row fits, chat large. That shot predates the item icons.
- Item icons: jsdom against the same mock shows an icon in each of the four production cells and in every pack chip
  (two packs in the mock, five with injected late-game data).

## What's left

- A screenshot with the item icons (same commands: `serve.py --mock --run tools/stream/runs/mock9.json --port 8788`,
  the tunnel, `obs_shot.py docs/stream-overlay-fx9.png --reload`), and a check at 1280x720 (`--size 1280x720`).
- piercing-rounds-magazine, stone-wall, flying-robot-frame and satellite are in the widget's item list but not yet
  drawn in items.js; until eng/art adds them they show as items.js's tinted crate with a proper label.
- World n's runtime still rejects `peek` on `status`; the merged eng/board runtime accepts it on any request, so
  worlds running the current runtime get peek reads.
- The board has only been checked against the shapes in eng/board's code, not a running world with it.
- Replays: the banner over a real replay has not been seen. On the box the clip played, but the reverse tunnel
  (8787 on the box -> the Mac) was down, so the banner page could not load. Check it with the tunnel up during
  shake3.
- Encoder load: one 30 s sample during shake3 (00:28, `/replays.json` from the operator's service) with the stream,
  the recording and the replay buffer all active: 0 output and 0 render frames skipped of 1824, 60 fps, CPU 10.7%,
  render 0.78 ms. One sample; keep an eye on `skipped_since_last` over a whole run.
- Night lift: tested against a fake OBS only (shake3 was live); check it on the box at night and tune `gamma`.
  Merging main broke its darkness read (main's all-surfaces loop in `STREAM_LUA` left `s` a nil global, so the whole
  extras read, research progress included, failed on world n); fixed in 8f7844f, and the selftest now compiles the
  overlay's Lua with `luac` and refuses stray globals. Darkness is Nauvis's; a camera on another planet is not lifted
  by that planet's night yet.
- Captions vs cards, the desk card and the Space panel: checked in jsdom, not yet in OBS (the pilot was live).
  Layout heights are by arithmetic: a 6-row production panel needs about 490 px of the 500 now left under a full
  panel's caption band.
- Vertical: see docs/VERTICAL-PROPOSAL.md.
- Zoom levels are guesses from the director client at 1080p; tune `zoom_*` in the run config's `director` after
  seeing real fights and builds on the camera feeds.

- The `camera` function and `profiles` exist only in the contract so far. Once eng/bots lands: confirm the `profiles`
  reply shape (`{profiles: [...]}` or a bare list; both are accepted), which identity the read should carry (the
  service sends the first configured bot), what `camera` returns, and that directors move as logged. Then start three
  director clients and check the framing zoom numbers on screen.
- Chat on world c is unavailable: the runtime refuses `chat` for disconnected players and there is no connected
  reader. With bots it reads as a bot. `last_said` from `profiles` is ingested but only the chat feed shows it.
- `control.lua` stops `request.player or 1` on a failed non-read call. For bot requests (no `player`) that would hit
  player 1; eng/bots should key this on the bot.
- Base-attack alerts use status `alerts.attacked` (tested against the shape in `threat.lua`, not yet against a real
  attack: world c is peaceful). Loss banners parse `alerts.latest` text, which is not a structured field.
- Research credit goes to the most recently active agents, since nothing says who fed the labs.
- `score` totals cover only `tools/pog.py`'s item list; other items get rates from flows (30 s
  refresh).
- The 8787 port conflict on the Mac (see above).
