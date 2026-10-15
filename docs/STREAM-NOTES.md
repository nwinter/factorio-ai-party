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

Token use per agent (`tools/stream/tokens.py`, operator 08:55, from Nick): a thread of its own (`TokenFeed`, started
by serve.py beside the run's stream.json; `"tokens": false` in the run config turns it off) reads the agents' CLI
session logs once a minute, never the game. A session belongs to an agent by its workspace, `runs/RUN/AGENT`: Claude
Code's project folders (opus on its own Claude profile), Codex rollouts whose `session_meta` cwd is the workspace
(forked subagents too), the workspace's own Grok home log, agy conversations whose opening names the run, Muse sessions
with the workspace as cwd. The homes come from `ai-session routes`. Each file is read on from where the last read
stopped, 4 MB at a time with a pause between chunks: a whole shift reads in about a second (shift10: 39 files,
140 MB, 0.8 s), and each later poll costs about 10 ms. The poller hands the latest result to the model, which keeps
it without the per-minute context series. It feeds the "tokens" card and each agent card's figure (`23.8M tok` after
the harness label; in portrait at the right end of the name line). The same module counts ended shifts for the site.

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
  Automation, Steel & logistics, Oil & blue science, Advanced, Rocket: the furthest stage any item or pack has been made in). Below
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
  values sent). On the box (2026-10-11 02:18, no run live): the filters already existed on all three captures (made by
  the operator's service during a run) at neutral. `python3 tools/stream/nightlift.py --darkness 0.85 --hold 40`
  ramped them to full lift and back to neutral. A read-only screenshot of "stream" at full lift showed the pilot's
  daylit base visibly brighter, mid-tones up and whites not clipped; it has not been seen on a game at real night.
  Afterwards the filters, the program scene ("stream") and the outputs matched the state found.
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
options `viewers` is an empty list and `viewers_status` null. The page puts messages under five minutes old (the last
four) into the main chat feed in time order with the agents' lines, so they scroll away like the rest (shake7: in a
lane of their own, Nick's line stayed up): a YT or SITE badge where agents have an avatar, the name in blue (yellow
for YouTube staff), a "viewer" tag, and "to the agents" on messages flagged as orders. Viewer names and text are set
as text, never HTML.

The pin box (`#chat-pins`, on both pages) sits above the feed. It holds a new viewer line for 25 s. It also holds an
agent's answer to a viewer, with the viewer's question above it, for 25 s from the answer. There are at most two pins,
newest first, and newer tells can't push them out. A pinned line leaves the feed while it is pinned and returns to it
afterwards. Shift01 16:09 is why: Astra's "Yes, Craig, ..." scrolled away under tells within seconds. An answer names
the viewer by the same rule the hosts use (`caster.viewer_short_names`): "@craigNZ830", or "Craig", within 10 minutes
of the viewer's line. The question is the one the agent saw in game chat: that viewer's relayed lines before the
answer, the one sharing the most words with it, else the most recent. Shift01 16:32 is why: both pins showed
Joonazan's latest line under answers to two earlier questions. Two answers to one question share its pin. A line's age
is the greater of wall time and game time, because serve.py stamps the chat it reads at a restart with the restart
time. The logic is `chatfeed.js` `viewerPins`, tested in `test_viewer_pins.py`.

The operator's own lines (game chat from `server`, model lane "operator", not "harness vN:" changelog lines) appear in
the feed with a gold OP badge and the label "Operator". They are pinned for 25 s. caster.py voices each one at once in
`voices.OPERATOR_VOICE` (Aura-2 "saturn", held back from the agents), with a caption labelled Operator and an OP badge
(audio.js). The agents' pacing does not apply, and the hosts may react afterwards. Tested in `test_operator_lines.py`.

Tells (the team's main channel since the board: shake7 had ~540 tells to ~100 chat lines) are in the same feed as
direct lines: "Sol → Astra" over the words in full, indented, a size smaller, on a teal edge. A burst from one agent
to the same recipients, each within 45 s of the last, folds into one line with the latest words and "+N"
(`static/chatfeed.js`). The two-line ticker under the chat is gone (Nick: "I can barely see any of it"); the
logistics chat and server lines it also carried are no longer shown. Same on the portrait page. The model gives tells
their own lane ("tell", the last 24 kept beside 12 conversation lines); the page also reads tells from a service that
still files them under "log", so a reload is enough.

Research complete: when the score shows a technology finished, the main camera gets an 8 s lower third on its lower
right (segment cards take the lower left), "Research complete · X · Unlocks A, B, C +N more", on both pages. The
unlocks come from research.lua's board event (`text` "unlocks: ..."), kept per technology whichever arrives first; an
old event replayed from the board's history at start makes no card. The research alert banner gives way to it on the
page (the alert stays in the state for the casters). `model.research_news`, `static/segview.js researchCard`,
`test_research_card.py`.

## Shake7 notes (2026-10-11): what changed for the 17:00 shift

- One event stream per page. A browser keeps 6 connections per host and an open event stream holds one for good; in
  shake7 the overlay, portrait and audio-test pages each held `/events` and `/audio-events`, all 6 were taken and the
  voice clips never downloaded, so the hosts were silent. Now `/events?audio=1` carries the clips as `audio` events
  and overlay.js and audio.js share one EventSource (`window.pogEvents`); the replay banner keeps its plain
  `/events`. Overlay, audio-test, portrait and replay on one host hold 4, leaving 2 for clips
  (`tools/stream/test_connections.py`, which also checks a clip downloads with all four open). `/audio-events` stays
  for pages loaded before the change. Pages pick this up when OBS reloads them (`tools/obs.py reload-overlay`).
- Analysis segments are a small card (540 px) in the main camera's lower left, never the whole camera; production,
  research, recap and Space run 10 to 20 s. Production only runs when a line moved 25% in 10 minutes (or started),
  and shows the top three movers; a recap only when its window has research, board items done, attacks or deaths (a
  due recap with nothing in it is skipped and its 20-minute clock restarts, so it never holds the queue).
- Science, team board and Space take turns in one 124 px slot, 18 s each (portrait: science and Space), so chat keeps
  its room.
- A Space platform counts once its hub exists: the score read carries `hub`, and a record waiting for its starter
  pack (the New platform button) is not a platform. Shake7 announced "First space platform: Solstice" on that record.
- Checked: selftest, test_connections.py and jsdom renders of both pages from the mock (one event stream, viewer
  lines in order and escaped, the production card, the widget rotation). Not looked at in OBS.

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
| tokens | 10-16 | lower card "Tokens this shift": every agent with tokens counted, most first: tokens (input, cached ones included, plus output), the share read from cache, turns (model calls) and tokens per game action, and the team's total (`tokens.py` TokenFeed). The director starts it every 30 min (`tokens_every`), the first 15 min after the service starts (between the hauling cards), at a free slot, not within 60 s of a fight cut; unavailable while nothing is counted | unchanged |
| hauling | 10-16 | lower card "Hand hauling this shift": the top 5 agents by items moved by hand, items and calls (harness `hauling`, read every 5 min by live.py into `runs/RUN/hauling.jsonl`; this shift = last read less the first). The director starts it every 30 min (`hauling_every`) at a free slot, not within 60 s of a fight cut; unavailable while nothing is counted | unchanged |

Rules (the director has the last word): one segment start per 180 s whoever asks (`spacing`). When the director
cuts the main camera to a fight, death, base attack or loss, a running segment ends at once (`cut: "attack"`) and
requests are declined for 20 s after that cut (`declined`). Alerts the director lets pass (a fight inside its 45 s
attack spacing, or `attack_cut: false`) neither end nor block segments, so a busy stretch does not wipe them out. After 6 quiet minutes (`lull_after`) the director starts
the next of production, spotlight, research, overview, recap itself (`by: "director"`). A recap is also due every 20
minutes (`recap_every`, from the service start or the last recap): the director starts it at the first free slot
that the spacing allows, covering the minutes since the last one (5 to 30). Shake3 never got one: the hosts'
research requests kept resetting the 6-minute lull clock, so the rotation reached overview at 01:18 and the run ended
before recap's turn. Ten minutes past due (`recap_late`) it goes next: right after the running segment, spacing
waived, 20 s after an attack cut, and every other request (replays and space moments included) gets `busy` ("an
overdue recap goes next") until it starts. In shake4 replays kept taking the free slot and one gap was 30 minutes.
Tune with `"segments": {...}`
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
  or an agent away. One head row (planets, science pack totals, else rockets). Then a two-line card per platform
  (`model.platform_card`, eng/platformwidget; Nick: "kinda basic"), two on the 1080p frame and three on the vertical
  page, with platforms under fire first:
  - Line 1: the name; where it is, or its route with a bar and %; km/s, "paused" or "drifting back" (paused on a
    route); who is aboard, and who works on it from the ground ("Sol (remote)").
  - Line 2: chips for the hub health (bar and %), guns armed of all, ammo in the turrets and in the hub, repair packs,
    asteroid hits a minute, and up to three cargo items.
  A chip turns red when it is bad: no gun armed, no ammo, or no repair packs on a damaged platform. A platform lost in
  the last two minutes shows struck through with LOST, its cause and where it was. While a platform is under fire or
  just lost (`space.hot`), the panel holds its turn in the widget rotation. The data comes from the `platforms`
  read's `defense`, `repair_packs`, `damaged_count` and `hub_items` (text, parsed in model.py), the status alerts'
  `platform_hits` (hits a minute over the last 5 minutes), the agents' `platform` and the remote-work feed.
- Science: the five planet packs and promethium count toward SPM and get chips and colours.
- Moments, each once (what is already true when the service starts is recorded silently): first rocket, first
  platform, a platform's first arrival at each planet other than Nauvis ("orbit"), the first landing on each planet
  (an agent's body there, else "first foothold" when the score lists our entities). Each raises a 🚀 alert and the
  director starts a `space_moment` segment within 150 s (segment spacing waived; still declined right after an
  attack cut). Casters can request `space` or `space_moment {moment: id}` (ids in `snapshot.space.moments`).
  Every other arrival after a trip, home included, is an alert with where it came from and who is aboard, and no
  segment ("Sunward is back at Nauvis"). Only firsts are 🚀 headlines: a platform's first arrival at a planet, or
  the run's first there. Where a platform is when the service first sees it counts as visited, and so does the
  planet it left if it is first seen mid-trip. Later arrivals, such as a ferry's round trips, are 🛰️ `arrival`
  events at caster priority 6, below battles and losses, so they never pull the hosts off a fight.
  `runs/RUN/space-memory.json` keeps where each platform has been and the planets reached, so a restart does not
  fire a false first: neither an arrival headline nor the one-time "X reaches Vulcanus" moment. A platform with no
  memory, first seen mid-trip to a planet the team has reached, is taken for a ferry: its arrival is an ordinary
  one. A platform headed somewhere new still gets the moment.
- Direction: space.lua's route "nauvis->vulcanus N%" names the space connection's fixed ends, whichever way it is
  flown (shift06 14:09: Sunward from Vulcanus to Nauvis showed as "leaving Nauvis for Vulcanus"). model.py
  `_orient_platforms` works out where a platform is headed from the schedule's current stop (pog.py score `to`),
  then the distance moving (not while paused, since a paused platform drifts back), the way it was going, and the
  planet it left. It turns the route and progress round for every label, the widget and the hosts. live.py lets the
  score's location (read every round) stand over a platform detail read that is up to 15 s old.
- Speed is `LuaSpacePlatform.speed` x 60 shown as km/s, assuming the API gives km per tick. Not yet checked against
  the game's own readout.

Mock: `serve.py --mock --run tools/stream/runs/mock-sa3.json` (three agents) plays a rocket at 20 s, the platform
"Orbital One" at 40 s, its flight to Vulcanus from 70 to 130 s, a "Shuttle" paused on its route (drifting, guns
empty, hit by asteroids) from 100 s and lost at 240 s, the third agent aboard Orbital One from 90 to 200 s, and Opus
landing on Vulcanus at 150 s (`"mock_space_speed"` scales it). Checked in jsdom on both pages and in the selftest; not yet seen
with a real platform, since the pilot had none by 02:00.

## Following the work, and platform shots

Cameras follow bodies, but in Space Age the agents stand on Nauvis while they build a platform remotely
(place_ghosts / paste / blueprint_place / deconstruct / cancel_deconstruction with `platform=NAME`, built by the hub),
so until now no camera ever showed a platform.

Where the service learns an action's target: each agent's fh journal (tools/new-run.sh `--journal`,
`runs/RUN/AGENT/journal.jsonl`, beside the run's `stream.json`) holds every request with its arguments. `work.py`
tails those files from their end when the service starts (no replay of the past), reads only new bytes each poll (at
most 1 MB per file), and keeps the five actions above. Profiles' `active` gives only the action kind, and the game
records nothing about who placed a ghost, so the journal is the one cheap source. `./shot` is not in it: the shot
script calls fh without the journal and always centres on the character.

- Away: `live.py observe_work` keeps a request that lands on a platform the body is not aboard, or 48 tiles or more
  (`AWAY_TILES`) from the body on its own surface (position, area centre, or the centre of the ghosts placed). Near the
  body the camera following it already shows the work.
- `model.py` labels it "Sol building on Solstice (from the ground)" or "Astra pasting a blueprint at (300, 40) (from
  afar)", one item per agent and job for 20 s, kept 60 s in the snapshot (`work`), and bumps the agent's interest.
- Director: the last secondary camera (cam3; cam2 with two) cuts to the newest item under 20 s old (`work_fresh`), holds
  15 s (`work_hold`), at most once every 45 s (`work_spacing`), never over an attack or segment shot. A platform item
  shows the whole platform: a fixed view on the platform's surface, centred on its entities' bounds, at the zoom that
  fits them (`model.platform_shot`, ~60x34 tiles at zoom 1, 0.3..2, sent as is). A far item shows its position at zoom
  0.9 (scaled like other secondary views). The agent counts as on air, so no other camera follows its body meanwhile.
  The camera label reads "Sol · building on Solstice (from the ground)". `work_cut: false` in the run config's
  `director` turns it off.
- Platform views: one read-only Lua call (`harness.py PLATFORM_LUA`, every 15 s with the platform detail) gives each
  platform's surface name (the `platforms` read has none, and the camera takes surfaces), its hub and the bounds of our
  entities there. A platform waiting for its starter pack has no surface and is skipped.
- Segments: "space" puts a platform on the main camera (one asked for with `params.platform`, else one between planets,
  else the first with a view); "space_moment" shows the platform for first-platform and orbit moments (a landing still
  follows the agent). Both pass the surface and the fitting zoom through `Segments.camera()` to the director.
- Director clients on a platform surface: cameras.lua teleports the spectating director to the target's surface
  (`p.teleport(target, surface)`, the same path a camera following a bot aboard a platform already takes), so a client
  that is not on the platform renders it. Not yet seen on stream.

Check live after the shift change (stream service restarted from this branch):

```sh
grep -E "work: |segment: Space" runs/RUN/stream-service.log | tail     # the director's work cuts and platform shots
grep -h '"surface": "platform' tools/stream/logs/director-*.jsonl | tail -3   # camera calls naming a platform surface
curl -s 127.0.0.1:8788/state.json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["work"]); print([p.get("view") for p in s["space"]["platforms"]])'
```

A platform shot on cam3 should show the platform with space around it; an empty or black view means the client did not
render that surface.

### Platform shots with one camera on air (2026-10-12, eng/platformcam)

Nick: "Do we have the camera look at the space platform sometimes?" Before this, only segments did (shift02 20:16
"First space platform: Starling", zoomed 1.55 on the platform surface, so the client renders platforms). Sol, for the
viewer awoo3391: "occasional platform camera view and continuous view during departure". `onecam.py` now has three
platform shots. Each one is a standby framed on the platform with `model.platform_shot`, then a cut, and the story
comes back afterwards:

- A visit about every `platform_every` (720 s; first after `platform_first`, 420 s) for `platform_hold` (20 s). It
  shows the platform shown longest ago. The rules are the same as the base map's: never during an urgent or segment
  shot, a replay, a trio, an inset or a reported fight, and not within `map_gap` of a cut.
- A departure: a platform seen still that starts travelling. It holds `depart_hold` (60 s). An urgent shot may cut
  in; the camera goes back to the platform for what is left of the departure. A departure the camera could not show
  within `depart_late` (30 s) is dropped. A platform already travelling when the service starts is no departure.
- An agent's platform action. The trigger is snapshot `work` with `platform=`. `work.py` now also counts inspect,
  configure, launch, drop, platform_schedule and requests when they carry `platform=`. The shot takes the camera if
  the agent is on air, or if the agent scores `work_ratio` of the agent on air (after onair_dwell, and with no fight
  and no big action on air). It holds `work_hold` (25 s), and more while requests keep coming, up to `work_max`
  (90 s). Then it goes back to the agent's character. The same agent and platform are not shown again within
  `work_gap` (180 s). shift02 20:16 to 21:29: Astra sent 138 such requests to Starling.

Labels:

| Shot | Label | Icon |
|---|---|---|
| Visit | "Starling · in orbit of Nauvis" (or "travelling to Vulcanus (42%) · 72 km/s") | 🛰️ |
| Departure | "Starling · leaving Nauvis for Vulcanus" | 🚀 |
| Agent work | "Astra · working on Starling" | none |

A hurt hub adds "· hub 62%". `PLATFORM_LUA` now reads the hub's health. The hosts get `onair.platform`
({name, why, label, agent?}), and the caster's facts carry `on_screen_platform`. GPU: no extra client. One of the
three clients renders a small surface for 20 to 60 s.

Mock check (`tools/stream/runs/mock-sa3.json` with `director: {platform_first: 15, map_every: 0}`,
`mock_space_speed: 1`): the departure went on air at 70 s and was cut by a turret loss. It came back after the loss
and gave way to the "reaches Vulcanus" segment. A visit followed. The page label read "🛰️ Shuttle · in orbit of
Nauvis · paused" (jsdom; no screenshot from this sandbox). Tests: `test_platformcam.py`.

Live: `grep "platform \(visit\|departure\|work\)" runs/RUN/stream-service.log`.

### Attention: where an agent is looking (2026-10-13, eng/attention)

Nick, 12:00: "It would be interesting to follow its attention." In the shift05-06 journals, about 10% of the actions
that name a map position were more than 15 tiles from the character. By agent: Sol 28%, Astra 20%, Luna 18%. Most of
them were inspect, then transfer and configure, then remote place_ghosts and deconstruct.

- `attention.py` turns a journal request into an attention point. It reads a position, an area, a list of positions,
  entities, builds or tiles, and `platform=`. Each point has a kind: looking (observe, inspect, placements), building
  (ghosts, paste, deconstruct, build, construct, repair), configuring (configure, requests, circuit, rotate, schedule)
  or moving items (transfer, collect, drop, launch). It also has a verb and what is handled ("taking steel plate").
  A scan with only a radius, move_to and reads give no point.
- `work.py` now hands every request that has a place to live.py (`take_attention`); the work items stay as they were.
  `model.py` keeps each agent's latest point and puts it on its snapshot row as `agents[].attention`: {kind, text,
  position, extent, surface, platform, age_s, dist, far}. The point lasts two minutes. Its text reads like "taking
  steel plate 40 m east", "inspecting at the oil field" (a run landmark), "configuring on Sunward" or "nearby".
- `onecam.py` uses it when the agent on air looks or works somewhere the on-air frame does not show. That means a
  fresh point (`attn_fresh`, 15 s) outside the frame, or on a platform the agent is not aboard. The last standby then
  shows that spot as the inset, labelled "🏗️ Sol · placing ghosts 40 m north", and the program does not cut. The
  inset holds `attn_hold` (15 s), and up to `attn_max` (45 s) while the agent keeps at that spot (`attn_same`,
  12 tiles). It moves to a new spot at most every `attn_move` (8 s) and ends when the story on air changes.
- No attention inset in the first `attn_min` (20 s) of a story, within `attn_gap` (45 s) of the last one, in a fight,
  a trio or a replay, or while an urgent, segment or held shot is on. An alert inset takes its client.
- The hosts get `onair.attention`. The site's live map draws a line in the agent's colour from each dot to its point
  (dashed when near, solid when far; the tooltip gives the text and its age). push_live sends the trimmed point.
- Tuning: `director: {attention: false}` turns the inset off. The `attn_*` keys are in `ONECAM`.

Mock check (`mock9-seg.json`, mock attention every 4 to 12 s per agent, 40% of points 25 to 60 tiles away): Gemini on
air got the inset 20 s after the cut, labelled "🏗️ Gemini · placing stone wall ghosts at copper smelting" (jsdom),
with no cut. The site map drew 9 lines, 6 of them far. Tests: `test_attention.py`, which uses recorded journal lines.

Live: `grep "attention:" runs/RUN/stream-service.log`.

### Key battles, incoming groups and threat scores (2026-10-13, eng/follow, eng/incoming)

Nick, 12:54: "is there a good way to ensure we don't miss entirety of key battles"; 13:40: "both still were just the
after-battle carnage ... Can we follow biter attacks as they approach a base?"; 13:45: "Shouldn't the attack group
size/threshold be dynamic".

- Operator follow: `POST /follow {agent, seconds <= 1800, label?, by}`, `DELETE /follow`; kept in
  runs/RUN/director-follow.json. The camera stays on that agent; other agents' urgent events become insets.
- Threat scores (`threats.py`): an enemy group or a fight scores on its size against the run's last 30 (percentile,
  squared), a unit tier above the usual mix (double the first 3 times), and what it is aimed at (near an agent, an
  outpost outside the base map's core, a new direction). A fight also scores for an agent in it and how long it has
  gone on. A budget of `threat_budget` (4) followed groups and battle holds per hour goes to the highest scores. The
  bar falls to `threat_floor` (1.5) when candidates are rare and rises when they are frequent; a spent budget passes
  nothing. The history is kept in runs/RUN/threat-history.json; each score and decision is in the director log
  (`"threat": {...}`) and the service log (`threat group|battle KEY: take|skip (why; parts)`).
- Incoming (`harness attack_groups_live`, an operator read polled every ~2 s while groups exist): a group that passes
  is followed with a wide fixed view that pans with it, labelled "⚠️ Incoming · 37 biters and spitters heading for the
  oil field", at most every `incoming_spacing` (600 s) and never over an urgent, segment or replay shot. At contact
  (the group attacking, within `incoming_contact` tiles of our nearest building, or a fight there) the battle hold
  takes over at the same place with no cut, so the start is live. `director: {incoming: false}` turns it off.
- Battles: a fight that passes the bar (or a followed group's contact) holds the camera: its agent while alive in the
  area, then a fixed view, chosen once (no back-and-forth); until 20 s with no attack or combat and 45 s with no loss.
  A fight reported again after 45 s quiet is a new fight (model.py); shift06 13:2x kept old first times, so every
  attack on Astra was a "long fight".
- Replays of a battle: one window from 3 s before its first sign, aired only if on-air footage starts within 4 s of
  that sign and covers 70% of the window, and the program did not show 90% of it live; footage counts from 2 s after
  a cut. Aftermath only: no replay.

Live: `grep -E "threat|BATTLE|battle over|incoming" runs/RUN/stream-service.log`.

### Big enemies coming, slow motion, a follow until its battle (2026-10-13, eng/slowmo)

Nick, 14:44: "The demolisher approaching should be good in a PIP camera" and "imagine a slow-mo instant replay";
14:47: the camera stayed on Sol after the fight; 14:50: insets of "empty fields".

- `big_enemies_live` (harness, operator read): demolishers on the planets with speed, closing, ETA and our nearest
  building and character within 500 tiles. While one closes (ETA under `enemy_eta`, 180 s) and the program is on
  what it threatens (the agent on air or followed near the target, or the battle there), the inset follows it,
  panning, "⚠️ Small demolisher · 120 tiles from Sol's gun turrets"; gone at contact (`enemy_contact`, 20 tiles),
  when it turns away (`enemy_away`, 10 s), or when the program moves on. A camera client, not an HTML map: the
  standby that takes insets is free while a follow or battle holds the camera on air.
- Slow motion: a big-enemy battle (tier 4+, demolishers, nests) or one with a sudden big loss (40% of its pieces in
  5 s) gets its densest 5 s of losses, from 3 s before to 5 s after, at `slow_speed` (45%) with "Replay · slow motion"
  on the banner, even if the program showed it live; on-air footage of the battle must cover 70% of the window; one
  replay per `spacing`. The whole clip is slowed: changing `speed_percent` mid-play restarts an OBS media source.
- `POST /follow {agent, until_battle: true, seconds}`: the follow ends 15 s after the battle with that agent (or
  around it) is over; `seconds` is the longest wait. Replays wait while a follow is on, so the slow motion airs then.
- Battles end sooner: 15 s with no attack or combat and 25 s with no loss (were 20/45; Sol's 14:19:30 kill took
  ~5 s and the hold ran 52 s). A fight in the area within `battle_resume` (45 s) resumes the same battle (12:58's
  waves came 35 s apart), and replays judge a battle 15 s after it ends, so a resumed one stays one.
- Loss insets: a few cheap pieces or friendly fire get an inset only if their threat score passes the floor (the
  13:37-13:54 insets were 1-3 pipes burned by our flamers); deaths, an agent under attack and real raids keep theirs.

### The hosts know the story (2026-10-13, eng/hostcontext)

Viewer Joonazan, 16:38: "why is Rook always out of the loop? Commentary without understanding context is really
weak." Rook's 14 lines from 16:20 to 16:38 held 8 attack calls, mostly hits where nothing was lost, and lines that
joined unrelated facts. `tools/stream/hoststory.py` in caster.py:

- An attack is a host beat only when it matters:
  - a loss in a fight within 64 tiles in the last 2 minutes;
  - a key battle on air (its own fight, or a battle held on an incoming group);
  - a threat score at the director's floor (1.5), using threats.py's fight score on the run's
    `threat-history.json`, so an agent fighting a minute, rarer or bigger enemies, or a long fight count.

  Until then it waits; one that comes to matter speaks then, with `why_it_matters`. A fight that ends quietly is a
  quiet hit, which another beat may mention in a word (`quiet_hits`, last 5 minutes). Losses and deaths speak as
  before.
- Every host prompt carries `story`, a memo rebuilt by rules every 3 minutes and kept in
  `runs/RUN/host-memo.json`:
  - the team plan's goals;
  - the last 5 headlines with clock times (headlines, space firsts, deaths, losses of 8+);
  - each agent's plan line and last spoken line (15 minutes);
  - research now;
  - the analyst's open storylines (what is stuck) and its headline.

  The booth guide says to know the story, not to tell it: a piece only when it explains this beat.
- Replay: `python3 tools/stream/hostguide_replay.py --story [--writer or:MODEL]` replays shift07 16:20-16:38. It
  shows each aired line, whether an attack is still a beat (on the director's logged threat parts; the log has no
  positions, so a loss counts as near), and the memo; with a writer, the lines with and without it. Offline: 4 of
  the 8 attack beats stay (losses, the 16:30 battle), 4 go (the two "Astra again" calls and the two "nothing lost"
  turret hits).

### Spoken-line cues (2026-10-13, eng/saylook)

Nick, 14:11: "I'd loved to have seen the space platform while that was narrated." `fh say "..." --aloud --look
platform:Sunward` (or `agent:NAME`, `X,Y[@SURFACE]`, `X1,Y1,X2,Y2[@SURFACE]`) keeps a look on the chat line; without
one, a line naming one of our platforms, or with one "(x, y)", gets an inferred look. When the line starts playing (the
page's start report, snapshot `voiced`), onecam cuts to the look for the line plus `cue_after` (4 s) if nothing more
interesting is on, labelled "Sol · Sunward · in orbit of Vulcanus", then goes back to the story. Under an urgent shot,
a battle, a follow, an incoming group, a segment or an agent fighting on air, the look goes in the inset; during a
replay or a trio it is dropped. One cue per agent per `cue_agent_gap` (180 s), cues `cue_gap` (45 s) apart;
`director: {cues: false}` turns them off. Live: `grep "cue " runs/RUN/stream-service.log`.

### Loadout strips: guns, armor, building, what they carry (2026-10-14, eng/loadout)

Nick, 08:55: "Especially when they are in combat, I'd like to see their guns/ammo. This can't be shown all the time,
but maybe we can find good heuristics." live.py reads the harness's operator `loadout` every 4 s once `describe`
lists it (a failed read waits 30 s). tools/stream/loadout.py keeps the rows and picks one mode per agent:

- `combat`: shooting (shoot or kite), health lower than 10 s before, in a vehicle, a fight within 48 tiles reported
  in the last 30 s (snapshot `fights`), or the stream's own combat flag. The strip shows the gun in hand with its
  ammo count large, the other guns small, shield and health bars, and armor equipment.
- `building`: a build action running (build x of y) or the hand-craft queue busy (the head with its progress bar, the
  next few).
- `carrying`: otherwise, for 12 s every 3 min, offset per agent so they do not all show at once. The largest 6 stacks
  and armor equipment.
- otherwise nothing.

Snapshot: each agent row has `loadout` (`{mode, ...}` or null) and the top level `loadouts` (every agent's full row,
for push_live.py and the site). overlay.js `renderLoadouts` draws one strip inside the main camera's frame (top left,
below any alert banners, and below the camera label outside onecam; hidden while a segment card is up) and one along
the inset's top (smaller), for the first agent each camera shows. Chat comes first (viewer Enginerd, 10:59: "The
combat info box often overlays the chat messages"): the strips keep off the captions' band at the main camera's
bottom, captions (`#voice`) stack above them (z-index 6 against 2), and a strip whose box still meets a caption on
screen or the chat panel steps aside (`.lo-yield`, overlay.js `loadoutClear`, run on each render and whenever the
captions change). Icons come from items.js, with a coloured swatch for items it does not draw. CSS: `.loadout.lo-main`
and `.loadout.lo-inset`. It goes live with a serve.py restart (the overlay reloads on its static version).

The site's agents page has a "Now" block per card (guns and ammo, armor and equipment, shield, health, vehicle,
largest stacks, free slots, crafting, building), filled by site.js from the live API every 30 s and hidden when no
shift is on. push_live.py publishes `agents[].loadout`.

### An agent resting between turns (2026-10-14, eng/pacing)

Since 17:01 Gemini plays short turns with long sleeps to pace its weekly quota (tools/agy-quota.py pace(), Nick's even
pacing until Sunday 12:51). Before the agy loop sleeps (a pacing sleep or a quota reset), agy-quota.py writes
runs/RUN/gemini/resting.json `{since, until, reason: pace|quota, sleep_s, used, resets}`; the next turn begins with
`agy-quota.py --woke`, which moves it to resting-last.json and gives that turn its first line ("You rested 75 min to
pace your weekly quota (it resets Sun 12:51); the game went on meanwhile: check what changed (./fh call status, chat,
board) before acting.").

- tools/stream/pacing.py reads it. live.py puts it on the agent row; model.py's card says "resting until 18:17 · pacing
  its weekly quota" (activity `resting`: a blue dot, not idle or offline; "waiting until ... for its quota to reset"
  for a quota sleep), the hosts get it once per rest (an alert of kind `rest`, an info line for them), and the
  director leaves the agent out of its picks. The site's card shows the same state and text.
- tools/supervise.sh types no nudge into the sleeping loop (logs "skip nudges: resting until 18:17" once a rest), and
  tools/idle_nudge.py sends no tell ("resting until ..." as its reason).
- Tests: tools/test_quota.py (the state file, the wake line, the loop's next prompt), tools/test_supervise.py,
  tools/stream/test_pacing.py.

### Each battle fact on its planet (2026-10-14, eng/planetmix)

Viewer Joonazan, 13:38: "There are no biters on Gleba. There are also other announcements that sound like they are
mixing planets." In 11:10-14:10, 11 host lines put a fight on the wrong planet or joined two planets' facts (the list is
in report-planetmix.md): Sol's guard read as an attack on Gleba (10, eng/attackflag), Nauvis's turrets joined to it (3:
the battle tally and a folded "also happening" covered every planet), biters or spitters "on Gleba" (5), and the
analyst's "the team is on Nauvis, where there are no stomper nests" (1: its status is one planet's, unlabelled).

- live.py: an attacked area off Nauvis says its planet ("Base under attack on Gleba near (176, 48): gun turret").
- model.py: alerts carry `surface` (an agent's attack, fight and death: the agent's; an area or a loss: its own).
- caster.py: events keep it; a battle fact (attack, loss, death, fight) gets `planet` and `enemies_there` (none while
  Nauvis is the only planet in play); the battle tally is kept per surface (take_tally); a beat folds only urgent events
  of its own surface; the show notes say each battle fact's planet is the one to say, never joined with another
  planet's, and who attacks where (Nauvis biters, spitters, worms; Gleba pentapods, no biters; Vulcanus demolishers;
  Fulgora none); attack numbers count hits by enemies, not biters. check_line (wrong_enemy) refuses an enemy named
  where it does not live ("biters do not live on Gleba") and a planet a battle fact does not give; saying an enemy is
  absent ("Fulgora has no biters") passes.
- The analyst: its status block and `game_status` say which planet they cover; `game_status {agent}` reads another
  planet as an agent there; `game_agents` lists who is where; the agents in its prompt carry their planet; its rule
  names each planet's attackers.
- Tests: tools/stream/test_planetmix.py; caster_selftest's numbers_mean check says enemies.

### Under attack only when hit (2026-10-14, eng/attackflag)

Viewer Joonazan, 13:36: "I'm pretty sure biters are not hitting anyone on Gleba. What's going on with all the
incorrect attack reports?" Any running shoot made the agent "under attack": Sol's standing order "guard" (shoot auto
by the egg breeders on Gleba, nothing in range) gave 7 insets and fight records between 12:52 and 13:41, Astra's
`move_to combat` walks on Nauvis 3 more; none of them had a hit on a character.

- The runtime's status `combat` now says what the shoot does (target in range, `fired_tick`, `kills_10s`) and status
  `hurt` the last hit by another force on the character or its vehicle (usage.md). live.py passes both on.
- model.py `combat_state`: `hurt` (a hit in the last 15 game seconds): "Sol is under attack by a small biter", the
  attack alert (the director's urgent rules, the hosts' attack event), fight `attack:sol`; `fighting` (a target in
  range, a shot in the last 10 s, a kill): "Sol is fighting a small wriggler pentapod", a fight `fight:sol` of kind
  `fight` and an alert of kind `fight` (a toast, an info event for the hosts, no urgent cut), the card "fighting";
  `guard` (a shoot with nothing to shoot at): nothing, the card "on guard", the action `guard` (no fight kind for the
  director, weight 0.3). A runtime without the new fields: a shoot at a position fights, an auto shoot guards; the
  mock's `combat: true` is a hit. Snapshot agents carry `combat_state` and `combat_info`.
- Incoming groups: "aimed at an agent" counts only agents on the group's surface (Sol on Gleba at (46, 51) counted
  for any Nauvis group heading near that spot, inside the base). A demolisher's label matches its owner by position on its own surface.
- The last hour (12:43-13:43) replayed: 10 agent "under attack" insets, 0 remain; 26 area hits (turrets, belts) and
  8 losses stay; all 41 attacked areas the team's status replies listed were on Nauvis. The hour before: 3 agent
  insets, 1 remains (Astra in the 12:10 tank fight). Tests: tools/stream/test_attackflag.py,
  vendor/factorio-harness/tests/attackflag.lua.

### Pollution and spore clouds (2026-10-14, eng/spores)

Viewer Joonazan, 13:00: "can you show a shot of Gleba's spore cloud?"

- Data: the harness's background chart sweep (threat.lua, about once a game minute on each surface an agent is on)
  already reads every charted chunk's pollution, spores on Gleba; it keeps the polluted ones (`{cx, cy, amount}`, up
  to 6000 a surface) with the surface's pollutant and its map colour. The operator read `clouds {surface?}` hands
  them over with the nests the cloud reached (the `pollution_reached_nest` news). live.py reads it every 60 s once
  `describe` lists it; model.py carries snapshot `clouds`: per surface with a cloud `{surface, label ("Spores on
  Gleba"), pollutant, color {r, g, b, a, css}, cells [[cx, cy, amount]], chunks, max, total, tick, reached [{x, y}],
  age_s}` (tools/stream/clouds.py). The colours are the game's: pollution dark red, spores olive (world n's
  `prototypes.airborne_pollutant`).
- Cloud shot (onecam.py): a map camera on that surface framed on every polluted chunk and the nests it reached
  (clouds.shot, the zoom rounded down to what director.apply sends), labelled "Spores on Gleba", for `cloud_hold`
  (20 s). The operator calls it:

      curl -X POST localhost:8788/cloud -d '{"surface": "gleba", "seconds": 30, "by": "nick"}'

  (no surface: the spores, else the biggest cloud; seconds 5..120). It waits out a segment, a key battle or a followed
  group (up to `cloud_late`, 10 min); an operator follow refuses it (409, DELETE /follow first). A surface with no
  cloud read yet: 400 with the clouds there are. On its own the director shows a cloud when it reaches nests it had not
  reached before (the reached nests at the service's start are old news), at most every `cloud_every` (30 min), with
  the base map's guards (no fight, no held shot, inset, trio or segment, `map_gap` after a cut).
- A cloud shot is no base map: snapshot `onair.map` stays None (mapframes.py takes terrain frames only of the base
  map, and the hosts' "here's the whole base" stays for it); `onair.cloud` is `{surface, label, why}` and the hosts
  get `on_screen_cloud` (label, chunks, max per chunk, nests reached).
- Overlay: every map shot's camera row carries `map_view {position, surface, zoom (the one sent), size}`;
  overlay.js `renderCloud` draws that surface's cells on a canvas in the hole (1 tile = hole height / 1080 x 32 x zoom
  px, the client's centre crop) in the game's hue, alpha 0.45 to 0.85 by log(amount) against the cloud's max, under a
  dark diagonal hatch, with the cloud's outer edge drawn dark (5 px) and in the hue at full strength (2 px: olive to
  yellow, dark red to red), the reached nests ringed. The first on-air shot (13:59) had the plain olive cells, lost on
  Gleba's yellow-green ground. The key is in the camera's label (in onecam the bar along the bottom: "Spores on Gleba
  [swatch] up to 29.2 spores per chunk · 32 chunks · 1 nest reached"; a key of its own overlapped the bar).
  The base map gets Nauvis's pollution the same way. Factorio's own map pollution layer (the camera player's map view
  settings) stays as it was; not checked on the camera clients whether it is on.
- Site: push_live.py publishes `clouds` (the 6000 most polluted cells over all surfaces); mapview.js has a
  Pollution (Spores) layer drawn under the buildings, the chunk's amount on hover or tap ("Spores 14.7 in chunk
  (-7, -5), tiles -224..-193, -160..-129"), a key, and a surface switch (Nauvis | Spores on Gleba) when another surface
  has a cloud: that view has only the cloud, the nests it reached and the agents there, the others listed in the
  corner.
- Mock: MockSource.cloud_rows (Nauvis around the demo base, growing and reaching a nest; Gleba with one reached nest),
  also in site/live/state.example.json for `?demo`. Tests: tools/stream/test_clouds.py, site/test_live.py (map),
  vendor/factorio-harness/tests/threat.lua.

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
  (just before the 20 s attack hold ends) and the last 15 s are replayed: the fight as main followed it. Deaths and
  losses: see "On air at the moment" below. At most one replay per 120 s; a clip not on air within 120 s is dropped.
  Deaths close together each get a clip (up to two waiting behind the first) and air one after the other: both
  replays play, rather than keeping only the first, because each death is its own story and two 15 s clips fit well
  inside the 120 s age limit. In shake4 Haiku's clip was queued, Opus died 43 s later, that attack cut emptied the
  segment queue and Opus's clip replaced Haiku's, so Haiku's death never aired. Now the cut still empties the queue
  (the live death comes first), the first clip is offered again 20 s later, and the second follows it.
  `/replays.json` lists the waiting ones under `waiting`.
- On air at the moment (task-replaycheck, after shift09 00:40-00:44). Sol died fighting pentapods on Gleba with the
  main camera on him from 00:38:56. Three clips were saved for that one death: the death, the loss of his character,
  and the same loss re-reported 90 s later. Two of them aired. The loss clip started at the urgent cut to the spot
  4 s after he died (the longest stretch of footage of the spot: all aftermath). Viewer awoo3391: "the one we just
  saw didnt actually capture the death at all". The rules now (`replays.py` module doc, `test_replay_check.py`):
  - The moment: a loss's game tick (the incident's `last_tick`, carried by live.py and model.py's `loss_ticks`),
    mapped to wall time through the snapshots' `(tick_t, tick)` samples. Without a tick, the alert less 2 s. A
    death takes the tick of the loss of its character where the agent last stood, else the alert less 1 s.
  - On air: the dead agent (followed, or its character inside the frame) or the loss's spot inside the main view's
    frame for at least 3 s of the 15 s before the moment. The timeline is the camera rows sampled every tick
    (`frames`: main, the inset while up, trio tiles, each with its frame). The first 2 s after a cut do not count.
    Otherwise there is no replay, logged `skipped death: not on air at the time (0 s of the 15 s before it)`, with
    the seconds only an inset or a small tile showed it. The urgent cut is unchanged.
  - Only the main view counts, as before (shift01 15:44: inset-only footage aired as the agent on air doing
    something else). The replay is the whole program, so an inset-only moment would air as a 408x230 corner.
  - The clip: 8 s before the moment to 3 s after, saved 1 s after its end, aired after the fight is quiet. It is
    seeked from the save time (`saved_t`); the file name's box time is never read.
  - One replay per moment:
    - a loss key (the incident) gets one clip, and a re-report with the same tick is no new moment;
    - a later moment of the same incident replaces the waiting clip only if it was on air longer, and never after
      one aired;
    - a death and the loss of that agent's character (only characters lost, within 40 tiles and 20 s) are one
      moment, and the death's clip airs whichever is judged first.
  - Sol's fight did have the camera. From the director log:
    - 00:38:08: "Sol is under attack" went to the inset.
    - 00:38:56: main cut to Sol through ordinary rotation ("astra still 30 s; sol moving").
    - 00:39:23: zoom for shooting.
    - Main stayed on him until 00:40:39, when the director saw him dead ("sol unavailable"); his character's loss
      was first seen at 00:40:38.
    - The battle scorer never promoted the fight: score 1.5 = agent 1.0 + duration 0.5 against a bar of 2.74. The
      alert text "Sol is under attack" names no enemy (no tier), and nothing was lost before the death.
    - The stream gets no character health (status gives the `combat` flag only), so "health falling" cannot weigh
      in without a harness status field.

    So the death was on air, the first clip (00:40:29-00:40:45) held it, and the clip that failed was the second
    one. No director change was made for this.
- Which clip airs (`Segments.replay_gate`, after shake12 aired three replays within 41 s at 04:04, often of one
  pipe or one belt, and two research completions got no card because the replay scene was on air):
  - at least 90 s between replays going on air (`replay_spacing`), whatever they show;
  - the same loss line airs once in 5 minutes (live.py re-reports a loss; shake12 aired several twice ~90 s apart);
  - one cheap building lost (pipe, pipe to ground, belt, underground belt, pole, inserter; `CHEAP`) airs only when
    no segment has started for 180 s (`cheap_quiet`) and no fight cut for 60 s. With another clip waiting behind
    it, replays.py drops it and offers the next;
  - a routine replay (anything but a death, or a loss that took a character) is refused while the research card is
    up (the 30 s `research_news`) or a fresh Space Age moment waits, and one queued or on air when a technology
    finishes or a moment appears is cut (`cut: "research"` / `"space_moment"`), so the card shows and the moment
    starts. A death replay airs over both.
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

Getting it to viewers (researched 2026-10-11; full steps in docs/VERTICAL-PROPOSAL.md): YouTube's Dual stream takes
our own vertical feed on a second stream key as part of the same broadcast (one URL, one chat), set up in the Live
Control Room before going live. On the box, the Aitum Vertical plugin (1.6.6) adds a 1080x1920 canvas with its own
output; `tools/win/install-aitum-vertical.ps1` installs it, and `tools/vertical.py scene` builds "stream vertical" in
that canvas: the three director captures (shared with "stream") in the holes above and a muted browser source on
`http://127.0.0.1:8787/portrait` on top. `vertical.py settings` (OBS closed; the plugin's
config.json over scp) sets the plugin's encoder, output and key from `~/.config/pog/youtube-vertical.key`, and "start
and stop with main", so `obs.py stream-start` starts both feeds. Installed and the scene built on the box
(2026-10-11); the output settings and a look at the scene are next.

## One camera on air (default since 2026-10-12)

A viewer said three cameras at once made it hard to concentrate on any one thing; the operator asked for one story
at a time. `serve.py` runs `onecam.py` (`--cams onecam`, the default; `--cams 3cam` or `"camera_mode": "3cam"` in the
run config brings back the director below).

- Picture: one client on air fills the left column (layout.json `main`, 1208x1032). All three captures sit there in
  OBS, centre-cropped from 1920x1080 to that shape (`cuts.crop_for`: 328 px off each side, no upscaling); `cuts.py`
  brings the one on air to the front and changes nothing else, so a cut is instant. The other two clients stand by:
  the next subject is framed on one of them first (a jump, off air), and the cut comes once it is there (`ready_s`,
  1.5 s). The crop shows about two thirds of the client's width, so fight zooms are scaled by `view_frac`.
- Dwell: the subject on air holds at least `onair_dwell` (90 s). After that a challenger needs 1.6x + 2 its score, or
  after `onair_max` (240 s) the camera rotates to the best other agent. It follows one agent, never a pair. A 60-minute
  mock (`simulate.py --cams onecam`, combat-heavy): 0.8 cuts a minute counting the urgent shots and the cuts back.
- Urgent cuts, inside the dwell: an agent's death; a real base loss (more than three pipes, belts, poles, inserters,
  walls or chests, or any turret, machine or engineer: `minor_loss`), at most one per `loss_recut` (180 s); a segment
  shot (Space Age launches and landings, spotlight, overview). After the urgent shot the story it interrupted comes
  back for at least `resume_min` (30 s). Replays are their own program scene (replays.py).
- Inset: a minor loss, or a real one inside `loss_recut`, outside the on-air frame (the client's view at its zoom,
  after the crop; until shift01 "over 60 tiles from the subject") shows in a 408x230 inset in the on-air view's top
  right for 20 s (`inset_hold`): the third client, moved there and on top by cuts.py. An attack with nothing lost yet
  is only a toast; inside the on-air frame, the label says it.
- Standing still and the look-ahead (a viewer on shift01: "should move on air to next moving player if they stand
  still too much"; Nick: use the actions the agents dispatch). shift01 14:30-16:16 (`still_report.py`, director logs
  plus the agents' journals): 37% of on-air time showed a character that had not moved or visibly acted for 20+ s,
  81 stretches, median 40 s, p90 77 s, longest 259 s. Now: a subject on air 30+ s (`still_min`) whose character has
  been still 25 s (`still_cut`) gives way to an agent moving or acting now (at least half its score); the one cut
  away from is not the pick again for 60 s (`still_block`). Thinking with a still character scores like idle;
  walking, building, mining, fighting x1.25; crafting, waits and reads x0.75. Each agent's `plan` (live.py: the
  status `active` record it already polls; the runtime now adds the action's bounds, set once when it starts, and a
  move_to's destination): a big visible action (a construct of 4+ ghosts, a path of 8+ pieces, a fight, a rocket or
  platform action) x1.6, the standby framed to fit its bounds, on air held while it runs (up to 300 s, `plan_hold`)
  with the zoom fitted, and once it ends 8 s still (`plan_after`) is enough to cut away. The same shift replayed
  through model.py and onecam.py: still share 31% before, 12% after (longest 123 s to 76 s); cuts 45 to 85 in 106
  minutes, 55 of them for standing still and 18 picked with a big action ahead.
- Calmer (operator 16:56: live from 16:19 a cut about every 30 s; a viewer at 16:45: "dont move 'on air' away
  from agents under attack"): a stand-still or look-ahead cut needs 60 s on air (`still_min`) and 30 s still
  (`still_cut`), 20 s after a big action (`plan_after`); `attack_hold` 30 s. A fight shot holds while its fight goes
  on (an attack still reported, or a loss entry with new losses: its `last` is a re-report) until 15 s quiet
  (`fight_quiet`, at most `fight_hold_max` 180 s); the agent on air shooting or under attack gets no cut away but an
  urgent one, no trio, and scores x2.5 as a pick (`fight_boost`). The base map waits 30 s after any cut (`map_gap`)
  and while any fight is reported. shift01 14:30-16:57 replayed (still_report.py; no alerts or basemap in the
  journals, so no attack or map cuts): rules off 26 cuts an hour, still share 33%; the settings live from 16:19 50 an
  hour, 16%; the new defaults 37 an hour (one every ~97 s), 21%. At 16:44 the loss shot near (-85, -110) went back
  to Grok after 20 s while the losses grew from 4 to 31 pipes; it now stays until 15 s after the last loss, and the
  base map 2 s after a cut would have waited for the fight to end.
- Base map (a viewer on shift01: "kind wish there was a map in one of them at times to see the overall base
  layout"): about every 10 minutes (`map_every`, first after 5) the program shows Factorio's own map of the whole base
  for 15 s (`map_hold`), labelled "Base map", then the story it interrupted. A standby client is framed first: the
  camera call with `map: true` puts it in the remote controller (`set_controller{type=remote, position, surface,
  chart_mode_cutoff=2}`), where any zoom under the cutoff renders the chart (as after pressing M: map colours,
  nests, ore, markers) rather than the world, which is far cheaper than a zoomed-out world render. Framing (mapcam.py)
  from the snapshot's basemap: every group of building cells, the core and its outposts; belts and pipes alone are
  no group, so shift01's 500-tile pipeline does not stretch the frame, the pumpjacks at its end do. Zoom fits the hole
  after the crop (1920 px at zoom z show 1920 / (32 z) tiles), 0.02 to 0.5. Never during an urgent or segment shot,
  a replay, an inset or a trio; a check-in trio shows the map in one small tile instead. Off air the client is
  released or given its next subject, and cameras.lua makes it a spectator again (`exit_remote_view`); the 5 s
  recheck leaves a map camera in the remote controller. The hosts: `onair.map` ("on air" or "tile") and the caster's
  `on_screen_map`. replays.py gets no frame from a map shot. Off: `"map_every": 0` in the run config's `director`.
  The map shot turns the camera player's alerts off (`disable_alert` per alert type: their markers, big yellow
  triangles, covered the base on stream and in the site's terrain frames) and the next camera call or release turns
  back on the ones it turned off. tools/stream/mapframes.py saves a georeferenced frame of it for the site's maps.
- Surface balance (viewer awoo3391, 2026-10-13 19:34: "the camera feed needs a real priority system"; 8 of 9
  agents on Nauvis, so rotation by agent showed Nauvis): onecam counts on-air seconds per surface over the last 30
  min (`surface_window`). A surface other than Nauvis with an agent on it is due `surface_share` (25%) of the air,
  plus up to `surface_new_share` (25%) while the planet is new to the run, fading over `surface_new_hours` (3 h) from
  the first time an agent was seen there; the other surfaces together at most `surface_total` (75%). An agent on a
  surface under its share scores up to x2.5 (1 + `surface_bonus` 1.5), by how far under; Nauvis agents x(1 -
  `nauvis_penalty`) (0.85) while another surface is under. Shares count over at least `surface_floor` (300 s), and
  nothing applies before `surface_warmup` (180 s) of air history. Only the story choice uses scores: urgent shots,
  battles, follows, incoming groups, segments and the dwell rules come first. A cut the balance helped says so
  (`gemini 2.1 beats astra 1.0 (surface fulgora 4% of 30%: x2.3)`), and the director log's entries carry `surface`
  (shares, targets, factors). Off: `"surface_bonus": 0` in the run config's `director`.
- A new planet's floor (viewer awoo3391, 23:46: "why arent we watching gleba right now"; Sol landed on Gleba at
  ~23:20 and after a 5-min operator follow `astra 33.48 beats sol 3.603` took the camera back, since a factor of at
  most 2.5 cannot lift 3.6 over 33): while a planet is new (novelty above 0) and its 30-min share is under
  `surface_new_floor` (0.5) of its target, the story goes to its best-scoring agent whatever the scores, once the
  dwell rules allow (`new planet gleba 3% of 38%` in the cut); a story already there stays among that planet's
  agents, a resume after an urgent shot gives way to it, and no trio starts while the story is elsewhere. Urgent
  shots, battles, follows and incoming groups still come first. Once the planet has its floor the factor applies as
  before (so its air settles about the floor when its agents score far below others). Off: `"surface_new_floor": 0`.
  How new a planet is counts game time (the game does not run between shifts) from the tick an agent first stood on
  it, kept in `runs/RUN/surface-seen.json` and read up the run's `resumed-from` chain, so a restart or the next shift
  does not make every planet new again (the 23:27:52 restart had given Fulgora, reached shifts before, a new planet's
  38%). A planet the run reached before ticks were kept (`space-memory.json` `reached`, here or up the chain) is not
  new; to make one new by hand, put its first tick in `surface-seen.json` (`{"gleba": 6643925}`) before the service
  starts.
- Which surface counts: the planet the agent's body stands on, as the harness reports it (status and profiles read the
  body, so an agent working by remote view or with `platform=` counts for the planet it stands on). An agent aboard
  a platform or riding a cargo pod (no body on a planet) and anyone on a platform's surface (`platform-N`) counts for
  no planet: a platform has its own shots (visits, departures, work), and it never becomes a "new planet". Test
  (tools/stream/test_surfaces.py): 7 on Nauvis, 1 on Fulgora, 1 on Vulcanus, 30 min: Nauvis 25%, Fulgora 38%,
  Vulcanus 37%; shift09's case (Astra 33 on Nauvis, Sol 3.6 just landed on Gleba, 30 min): Gleba 10% without the
  floor (one rotation turn), 25% with it (half its 50% target).
- Trio (Nick, 2026-10-12: he liked the old one-big-two-small layout because each tile said who was doing what):
  sometimes the program shows all three clients in layout-3cam.json's holes, the one on air in the big tile (no cut:
  the same client stays on air) and the two standbys in small tiles, each labelled "Luna · fixing the north wall"
  (the agent's plan line, claim or action, `cameras.*.doing`); the on-air card stays highlighted. The director picks
  it when two other agents score at least 0.9x the subject on air and are 40+ tiles from it and each other
  (`trio_ratio`, `trio_apart`), or as a check-in after 15 min without one (`trio_every`); it lasts 90 s (`trio_hold`,
  kept within 60-120 s), then one camera again. No flicker: at least 480 s of one camera before a trio
  (`trio_gap`); never while a replay is on air or about to be, or an urgent or segment shot holds the camera; the
  small tiles are framed off air (jumps) and the layout switches once both are there. An urgent alert or a camera
  segment ends a trio at once. The 2-hour mock: a trio about every 10 minutes (~13% of airtime). The switch is live:
  `program.layout` "trio" and `program.tiles` (hole -> client) make cuts.py move the captures (transforms over the
  websocket, no scene rebuild) and the page take the three holes (from the snapshot, no reload). The vertical
  canvas stays one camera (the big tile's client). Hosts: `onair.layout` {mode, why, agents, since, until}; the
  caster's facts get `on_screen` (three tiles, the small tiles' agents). `"trio": false` in the run config's
  `director` turns it off; `serve.py --mock --trio` holds one for screenshots:
  `tools/stream/overlay_shot.sh 'http://127.0.0.1:8799/?preview' docs/stream-trio.png`.
- Overlay: a bar along the on-air view's bottom edge says "Following Luna · fixing the north wall" (snapshot
  `onair.doing`: the agent's team-plan line, else its claim, else its action). The bar also covers the client's
  bottom-centre hints ("Press Tab to skip cutscene"): the mod already sets `show_hotkey_suggestions` false
  (cameras.lua) and the hint still showed on 2026-10-12, so it is masked here. It is the intro cutscene's own hint
  (the cam clients joined a new Space Age world). cameras.lua ends a director's cutscene (`exit_cutscene`) before
  making it a spectator, but at 15:48 the clients were spectators (controller_type 5) and the hint still showed: a
  stale client-side hint. So every view on the program has a bottom bar holding its label: the trio's small tiles
  (32 px) and the inset (26 px), at least the main bar's share of their height. The agent's card is ringed and badged
  "On air". Toasts: at most two, identical lines merged, 12 s, nothing the label or inset already says, in a compact
  stack at the right just above the bar (captions and lower cards rise above them). `?layout=layout-3cam` gives the
  old page.
- Snapshot: `cameras.main` is the camera on air and `cameras.inset` the inset (what viewers see), so replays.py,
  model.py, push_live and the casters read them as before; `onair` {agent, display_name, doing, since, client} and
  `program` {onair, inset} (the clients) are new, `cuts` is cuts.py's status.
- Hosts: lull, camera, chat and board beats get `on_air` in their facts (the agent viewers are watching, and its label
  line); naturalist and spotlight beats pick it 85% of the time; it leads `busy_agents`.
- Vertical: layout-portrait.json has one camera too (1032x883, the band the three had, the same crop); cuts.py
  restacks "stream vertical" in Aitum Vertical's canvas the same way when that scene exists. Segment cards there are a
  strip along the camera's bottom (at most 220 px). On the first test run the vertical canvas still showed the
  three-camera page: its browser source had loaded before the change. Pages now reload themselves when the
  service's page files change (`static_version` in the snapshot), and `vertical.py scene` / `obs.py stream-scene`
  refresh their overlay source.
- Setup: `tools/obs.py stream-scene` (all three captures in the hole, cropped; `--layout
  tools/stream/static/layout-3cam.json` for the old one) and `tools/vertical.py scene`, then restart serve.py and the
  overlay page. Screenshots of a mock page: `tools/stream/overlay_shot.sh URL OUT.png`.

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
in the fight (its status `combat` went true; zoom 1.05, following), else to the fight itself: a fixed view on the
alert's position and surface, zoomed so its extent fits (the attacked 32-tile chunk, or the loss rectangle, plus 24
tiles: `60 / (extent + 24)`, sent as is), jumping there without easing. It no longer follows an agent near the attack:
in shake10 that framed the factory and the announced turret-fight replay showed the factory. Fight replays (replays.py,
after shake10, when the replay aired what the main camera had just shown while the battle went on): never while the
fight is going on (a clip waits until its fight, model `fights`, has been quiet 20 s; a death clip until no attack
within 40 tiles goes on); nothing of what the main camera showed live; a loss gets a clip of the program's own footage
of the spot (6 s before the loss to 15 s after, the longest stretch it was in frame, at most 10 s, at least 4 s), aired
after the fight, one per fight stretch. "In frame" is geometry since shift01 (15:14: four clips of the east attack at
(75, -55) aired Sol walking in the base, 35 tiles south; a camera "showed" a spot within 20 tiles of its agent, and
onecam treated alerts within 60 tiles as on air, so it neither cut nor inset): the spot inside the on-air camera's
frame (in a trio the big tile; not the inset or a small tile: the replay is the whole program recording, so
inset-only footage aired the agent on air doing something else, shift01 15:44; a minor loss shown only in the inset
gets no replay, a real one gets a cut and so footage), from the zoom sent to the game (32 px a tile on a 1920x1080 client) and the on-air crop
(`frame` in each camera row; director.in_frame); ticks while a replay is on air count for nothing. onecam's
"already on air" uses the same frame, so an off-frame loss gets an inset or a cut and so has footage. The seek offset
uses only the Mac clock (saved_t when SaveReplayBuffer is sent, minus show_from, back from the file's end); the box's
local-time file names are never read. A fight only a side camera showed
gets that camera's stretch (6 to 15 s), aired after it ends; no camera, no replay. It holds 20 s (`attack_hold`), at most
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

## Director client memory

Shake5's cam3 director crashed at load (05:20, 2026-10-11): the box was at 51.8 of 54.5 GB commit and each Space Age
director commits about 5.2 GB (cam1 5,266 MB, cam2 5,253 MB private). `start-client.ps1` wrote
`graphics-quality=low`, but Factorio 2.0's `[graphics]` section takes only `high` or `medium` for that key
(`; Options: high, medium` in a 2.0 generated config.ini). The invalid value was dropped and the client ran at high
("[Graphics quality: high] [Video memory usage: low]" in cam3's log); `video-memory-usage=low` was valid and applied.
The `-Human` value `normal` was invalid too. Source: the commented defaults in a Factorio 2.0 config.ini (format
version 13, with the Space Age debug keys) on the operator Mac. The box's own config.ini was not read: the sandbox
here has no network path to the box, and shake5 was running.

What directors (every client without `-Human`) now get, in `[graphics]`:

| Key | Value | What it does | Expected saving |
|---|---|---|---|
| `graphics-quality` | `medium` (was the invalid `low`, so high) | Sprite resolution. High loads the high-resolution sprite sheets; medium loads the normal ones, half the width and height, so a quarter of the pixels. The config comment ties the streamed atlas to it ("64 MB for high resolution and 32 MB for medium resolution"). | The largest one. My estimate, not measured: 1.5 to 3 GB of the ~5.2 GB per client, since most of a client's commit is sprite data and medium sprites hold a quarter of the pixels. The box test below decides. |
| `video-memory-usage` | `low` (unchanged) | How many sprite atlases are kept resident rather than streamed. | Already applied in shake5; no further change. |
| `texture-streaming` | `true` (the default, now written out) | Sprites are streamed into a virtual atlas on demand instead of all loaded at start. | None compared with shake5 (it was already on); written so a changed default cannot raise memory. |

`-Human` now gets `graphics-quality=high` and `video-memory-usage=all` (valid values; the game's own defaults).

Picture: medium is the sprite resolution the harness's own client uses (`vendor/factorio-harness/host/session.ts`
passes `--graphics-quality medium`). At the directors' zooms (0.45 to 2.73, median 1.3 in shake4) sprites are drawn
at or below their medium size most of the time, so a 1080p stream should look much the same. Close zooms above about
2 will be softer. Check on the first OBS frame after the restart.

Kept as they are, in case medium is not enough: `optimize-for-low-vram` (default false) targets video memory, not
the commit charge, and its effect is not documented. `texture-compression-level=low-quality` (default
`high-quality`) compresses harder with visible artefacts. `max-texture-size` (default 0, auto) caps atlas pages. The
`high-quality-animations`, `-shadows` and `-terrain` switches mostly cost GPU time. Try them one at a time with the
test below if a client still commits too much.

Box test (world n free after shake5 ends at 06:21; run from the repo root on the Mac). Restart one director with the
new settings, leave cam1 and cam2 as they are (old settings) for comparison:

```sh
git log -1 --format=%h -- tools/win/start-client.ps1        # the medium change must be in this checkout
tools/winps.sh tools/win/client-mem.ps1 -Name n -Slot -cam3  # before: every factorio process's private MB, commit
tools/winps.sh tools/win/stop-client.ps1 -Name n -Slot -cam3
tools/winps.sh tools/win/start-client.ps1 -Name n -GamePort 34205 -PlayerName pog-cam3 -Slot -cam3 \
  -Factorio 'D:\pog\factorio-2.0.77-expansion'
tools/winps.sh tools/win/client-mem.ps1 -Name n -Slot -cam3  # after load (~2 min), and again after ~10 min
```

`client-mem.ps1` is read-only: it lists each `factorio*` process's private and working-set MB with its start time,
the box's commit charge against its limit, and the lines of the client's log that name its graphics settings.
The log should now say `[Graphics quality: medium] [Video memory usage: low]`. Compare `factorio-cam3`'s private MB
with cam1 and cam2 at the same moment. Streaming grows memory as a camera sees new sprites, so the 10-minute reading
with the director service moving cam3 is the fair one. If the saving holds, restart cam1 and cam2 the same way
(cam1 with `-Sound`, as `start-team.sh` does), or let the next `start-team.sh` start them. `start-client.ps1` rewrites
config.ini on every start, so nothing on the box needs editing by hand. To go back: `git revert` the
start-client.ps1 commit and restart the client.

## Science per minute (2026-10-14, eng/spm)

Viewer joonazan (15:49): the sidebar's "science per minute" was packs made per minute, all colours summed (168/min at
15:50, 62 of it space science); players mean research throughput. The headline is now SPM as players say it:
research units a minute, the labs' use of packs in sets (`model.research_units`). Every 2.0 technology takes one of
each of its packs per unit (243 of 243 with units in the 2.0.77 data) and one runs at a time, so the units are the
count of the pack the labs used most. The agricultural pack is left out of that count: it spoils, and the labs'
agricultural count rose 3942 over shift12 while red rose 2149.

- Rates: the score's `consumed` (packs the labs used, all surfaces; `tools/pog.py`) over ~2.5 game minutes, as made
  rates come from `produced`. The series: `harness.USED_FLOW_LUA`, the consumption side of the production statistics
  in 30 two-minute buckets (the ten-hour precision's 2-minute samples, one read a bucket; 3.1 ms on world n, against
  16.5 ms for ten one-hour samples a bucket).
- Beside it: one chip per pack the labs used lately or the running technology takes (`current_packs` in the score),
  with the labs' use a minute; a running pack the labs did not use is dimmed. Under it: "research units/min · made
  168/min, all colours".
- shift12 in 10-game-minute windows: mean 11.9 SPM against 142.2 packs made a minute; the busiest, 72 SPM against
  177.4 made (game minute 2687, advanced asteroid processing).
- The same number for the hosts (`science_per_minute`, with `science_per_minute_is`, `science_packs_used_per_minute`
  and `science_packs_made_per_minute_all_colours`), the production card, the analyst (`game.spm`, `history.py`), the
  site's long run (SPM per shift and in 10-minute windows from the score logs' `consumed`; logs without it show none)
  and `/live/`.

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
- Night lift: it works on the box (above) but has only been seen on a daylit scene; look at it during a real game
  night and tune `gamma`.
- Replays called as replays: the Space Age pilot's one replay (01:39:04, after 262ef78) opened "Replay bites!", so the
  hosts do call it a replay. That line also read the raw "spaceship chunk x653"; banners and replay titles no longer
  carry hit or kill counts (78c03b6). Not yet heard on a real fight.
- `shot-sync.log` (shake4 P3 item 17): a screenshot for a workspace outside the run is reported once and left on the
  box, so the log no longer fills with one line per stale shot per pass (98,770 in shake4). Clearing the camera
  clients' old shots at launch would delete files on the box, so it is not done; `del` them by hand between runs if
  wanted. Checked with stand-in ssh/scp and `tools/test_shot_sync.py`, not on the box (shake5 was running).
- The overdue recap and the two-deaths replays (shake4 P3 items 15, 16) are checked in the selftest only.
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
