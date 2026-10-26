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

The site's address on some cards (Nick, YouTube chat Oct 14 22:02; eng/d17-site8): every 2nd accepted segment that
is not a replay carries `site: "factorio.nickwinter.net"` (segments.py `SITE`; `site_every` in stream.json
`segments`, 0 turns it off). The card shows one line, "More on the run: factorio.nickwinter.net", at its foot above
the time bar (15 px on a lower card, 20 px on a full panel, muted), on both the landscape and the vertical page. It
stays inside the card, which already rises above the voice captions and never covers the agents' chat or bubbles. It
is outside `facts`, so the casters neither see nor say it. Shift 28 accepted at least 18 segments in its first 3
hours (the replay log's last id is seg-18; 5 were replays), so about 13 cards and 6-7 site lines in 3 hours: two an
hour, each up for the card's 10-45 s. Checked in a
stub DOM (tools/stream/test_sitecard.py), not yet seen in OBS.

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
  Since d22 batch83 AS1 (Nick 09:28: "so many routine flights now that it's pretty repetitive"; shift57 06:21-09:24
  put 55 departures on air for 51.8 min), only news holds `depart_hold`. News is a maiden flight, or a route
  (platform, from, to) not flown in `depart_news_h` (6 game hours), or a leg to or from the solar system edge or the
  shattered planet, or a planet new to the platform. The route memory is `model.add_route`: it comes from the score's
  reads and the chronicle's `platform_left`, is kept in `space-memory.json` `routes`, and is seeded from the
  chronicle files along the run chain. Any other departure is routine. It goes on air for `depart_routine_hold`
  (25 s), at most once per `depart_routine_every` (20 min) across all platforms and once per `depart_route_every`
  (2 h) per route. Otherwise it goes in a free inset (`depart_inset`), at most once per `depart_inset_every`
  (10 min) and once per `depart_inset_route_every` (2 h) per route (AS2, operator 09:47: without these limits the
  replay put 53 routine departures in the inset). Otherwise it is not shown. Each decision is a log
  line and a director-log row: `departure routine (inset): Cinder Gleba->Nauvis flown 31 min ago; a routine
  departure went on air 7 min ago`. The platform visit (`platform_every`) is unchanged.
  `tools/stream/test_departnews.py` replays shift57's 72 departures: 9 on air for 5.0 min, 11 in the inset for
  5.1 min, 52 not shown.
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
- Operator platform hold (eng/platformview): `POST /platform {name, seconds?, label?, by?}`, `DELETE /platform`.
  For example, `curl -X POST http://127.0.0.1:8788/platform -d '{"name":"Sunward","seconds":300,"label":"Asteroid crossing","by":"operator"}'`.
  Names are case-insensitive; seconds defaults to 600 and is clamped to 1–1800. Unknown names return 400; no
  platform snapshot or no surface/view returns 409. Non-numeric or non-finite seconds return 400.
  `runs/RUN/director-platform.json` stores `{name, until, label, by}` (until is epoch seconds); edits/deletion and
  restarts work like `/follow`. An expired file does not restart the hold. The platform snapshot supplies the view;
  this adds no game reads. If a saved platform is temporarily absent, normal directing runs until it returns.
  A platform hold takes priority over `/follow`; an unexpired follow resumes when the platform hold ends. `/cloud`
  returns 409 while a platform hold is active. Other urgent events use insets; segments, cues, rotation and new
  replays do not cut away. A followed agent aboard a platform also gets the whole-ship view, returning to character
  framing on landing. The on-air label and the hosts' `on_screen_platform` identify the platform, current route,
  agent aboard and optional operator label; `snapshot.platform_hold` includes its deadline and requester.
- Operator position shot (eng/d16-stream7; viewers LimeLight555 11:33 "the upcycler", 12:24 "the western wall"):
  `POST /look {surface, x, y, zoom?, seconds?, label?, by?}`, `DELETE /look` (lookcam.py). For example,
  `curl -X POST http://127.0.0.1:8788/look -d '{"surface":"nauvis","x":-180,"y":40,"seconds":30,"label":"The western wall","by":"operator"}'`.
  The main camera shows that spot (fixed view, exact zoom) for `seconds` (1–60, default 30), then the director
  returns to the story it left (or to an unexpired `/platform` hold or `/follow`). `surface` is a surface name (any
  case) or one of our platforms' names; `zoom` 0.3–3, default 0.75 (higher is closer). Only charted ground: one
  read checks that every 32-tile chunk the on-air frame covers at that zoom is charted by the team; otherwise 409
  with the reason ("(500, 0) on nauvis is not charted: the team has not seen that ground", or "12 of the 28
  chunks the frame at zoom 0.3 covers ... are not charted", where a closer zoom frames less). An unknown surface is
  400, a failed read 503. The read costs 0.9 ms in the game (LuaProfiler on world n, a zoom 0.3 frame, 16 chunks).
  `runs/RUN/director-look.json` stores `{surface, position, zoom, until, label, by}`; restarts and hand edits work
  like `/follow` and are chart-checked too. Precedence: **look > platform hold > follow** (test_look.py
  precedence): a look takes the camera from both, and each resumes when the one above it ends if its time is not up.
  During a look, other urgent events go in the inset; segments, cues, rotation, the trio, base map, cloud and
  platform shots and new replays wait; `POST /cloud` is refused. The caption on air is "📍 label" (or the spot,
  "Vulcanus · (120, -40)"); `snapshot.look` has its deadline and requester and the hosts get `on_screen_look`.
  There is no operator chat command for `/follow` or `/platform`, so none for `/look` either.
- An image on air (eng/d16-stream7; Sol 15:30 for viewer LimeLight, done by hand at 15:31): `POST /show {file,
  seconds?, label?, by?}`, `DELETE /show` (show.py). For example,
  `curl -X POST http://127.0.0.1:8788/show -d '{"file":"runs/shift24/sol/tools/aethera-design24.png","seconds":45,"label":"Aethera design (Sol, for LimeLight)","by":"operator"}'`.
  `file` is a PNG under runs/ (repo-relative or absolute; a symlink out of runs/ is refused), checked by its header,
  at most 10 MB and 32–4096 px a side; `seconds` 1–60 (default 30); `label` defaults to the file name. The service
  copies it to the box (`scp` to D:/pog/overlay/show-HASH.png) and adds a dark backdrop and the image to scene
  "stream", both bounded to the main hole (layout.json `main`, letterboxed), just below "stream overlay": above
  every camera (cuts.py only restacks the cameras among their own places, so a cut does not cover it), under the
  overlay, whose main caption reads "🖼️ label" meanwhile. The time counts only while "stream" is on program, so a
  replay in the middle pauses it, and an image that left the scene is put back. After it, both inputs are removed
  and the copy deleted. One at a time (409 while one is on; DELETE ends it early); a failed copy or OBS call is 502.
  OBS removes an input a moment after RemoveInput, so each show makes inputs with their own tag, and at start any
  leftover "pog show ..." input is removed. `snapshot.show` and the hosts' `on_screen_image` say what is on.
  Agents ask with `./fh operator "..."` and the file path, as Sol did; the operator runs the curl. Checked on the box's
  OBS 32.2.2 in a scratch scene (never on program, removed after): the calls, the order below a browser source, two
  shows in a row.
  The shared platform framing fits the build and the on-air crop, adding 32 tiles ahead and 8 aft/on either side
  while in transit (north on the platform surface, in either direction of the space connection). Held frames
  refresh on departure, arrival and bounds changes; label/progress updates alone send no camera command. The
  existing camera minimum zoom of 0.3 still limits how much a very large platform can fit. Offline regression:
  `python3 tools/stream/test_platformhold.py` (no arguments; HTTP test uses an ephemeral local port).
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

### Host view: Nick's own client on air (2026-10-17, eng/d17-hostview)

Nick, 16:39, spectating world n from his client on pogwin (`tools/win/start-client.ps1 -PlayerName nick -Slot -nick
-Human`): "it would be interesting for the stream viewers to also see my view, so I can show them things."

- OBS: the game capture "stream host" of factorio-nick.exe, matched by executable (never his Steam game, factorio.exe),
  slow hook rate, cursor shown. It sits in the on-air hole, cropped as the cameras, just above them and below the
  overlay, off. `obs.py stream-scene` builds it in a fresh scene; `obs.py host-view-source` adds it to the live scene
  and touches nothing else. A game capture with no window to hook draws nothing.
- Control: `POST /hostview {on: true|false, seconds?, caption?, by?}` (`DELETE /hostview` too), as `/follow`. For example,
  `curl -X POST http://127.0.0.1:8788/hostview -d '{"on": true, "caption": "the new smelting column"}'`. From his own chat
  (the site's host link or his YouTube channel, viewers.py's `host` flag) only: `!view`, `!view CAPTION`, `!view off`.
  Those lines are commands: not shown, not relayed. Anyone else's `!view` is chat.
- While on (hostview.py, onecam.py `hosting`):
  - cuts.py turns "stream host" on and in front of every camera (program `host`);
  - the director holds: no cut, no inset (it would sit over his view), no trio; segments, cues and new replays wait,
    and the cameras stay where they were;
  - the on-air card reads "🎥 NickWinter (host) · CAPTION" (default "showing the stream around");
  - the snapshot's `hostview` {label, caption, by, until, remaining_s}; `onair.host`, and `onair.agent` none (no agent
    is on air behind his view).
- It ends when turned off, when his client leaves the game, or after `seconds` (default 20 min, at most 60). The poll's
  extras read lists the connected players (`connected_players`; his name `nick`, run config `host_player`). A start is
  refused (409) while he is not in the game.
- A notice line in the stream's chat feed when it starts ("Nick is showing his view on stream: CAPTION") and ends
  ("... back to the cameras (its time ran out)").
- Kept in `runs/RUN/director-host.json` ({until, caption, by}), so a restart keeps it; a hand edit works too.
- One camera (POG_CAMS=1) and three alike: the host capture is not one of the director's cameras.
- The vertical scene shows the cameras as before: it has no host capture.
- Not now: his game audio (OBS takes game audio from factorio-cam1.exe only).
- Deploy: `obs.py host-view-source` once, then restart the service.
- Tests: tools/stream/test_hostview.py (commands, control, director with three clients and one, feed, HTTP),
  tools/stream/test_cuts.py (5. host view), tools/test_obs_hostview.py (the source, the one-off).

### Artillery impacts (2026-10-17, eng/d17-artycam)

Viewer Foobator, 12:48: "if there is only one arty shell in flight and nothing else interesting has happened, can you
show the impact on screen". A shell leaves at 1 tile a tick (artillery-shell on 2.0.77, no deviation), so it is up at
most 224 / 60 = 3.7 s, and the main poll (every 3 s) is too slow for it.

- Game side: the operator read `artillery_live` (vendor/factorio-harness/mod/agent-harness_0.1.0/artycam.lua). Our
  artillery turrets and wagons are found once and kept. A change in the force's count of them finds them again, one
  surface a read: Nauvis took 14 ms on world n, once. Each read, for each piece loaded with shells:
  - one find for artillery-projectile within 48 tiles of it (how far a shell flies between reads; 0.11 ms on n);
  - the shell's target: the enemy spawner or worm on the line from the piece through the shell, from the piece's
    targets in range, re-read once a minute (2.5 ms on n, 95 nests and worms round Opus's turret at (298.5,-320.5));
  - when the shell lands, from its distance and speed;
  - who fired: the agent who last put shells into the piece by hand (hauling.lua's moves), else the piece's
    `last_user`.
  A read with no loaded piece costs 0.03 ms. A shell aimed at a spot with no nest or worm (an artillery remote's
  flare) is left out.
- Service: serve.py reads `artillery_live` in its own thread. It reads every 0.5 s while a piece is loaded with targets
  in range, else every 10 s. A new shell wakes the director at once, without waiting for its 1 s tick.
- Director (onecam.py `maybe_artillery`): the shot is a cut to the target (zoom 0.8) if nothing outranks it and it
  lands at least `arty_lead` (0.6 s) from now. It is held `arty_after` (4 s) past the impact, then the story it left
  comes back. More shells landing within `arty_near` (32 tiles) of the target hold it longer, up to `arty_max` (20 s).
  - Outranked by (the shell is let go): an operator look, platform hold or follow, a key battle, an incoming group, a
    segment (launches, landings), a replay or the trio, an urgent shot held (a death, a loss), any fight reported
    within `fight_quiet`, or the agent on air fighting.
  - At most one artillery shot per `arty_gap` (180 s).
  - With three clients a standby jumps to the target and the cut waits `ready_s` (1.5 s), shortened to land half a
    second before the impact (at least 0.2 s); the director steps again then (`next_wake`).
  - With one client (POG_CAMS=1) the client on air moves at once.
- Caption (the on-air card's `work` line): "💥 Artillery · Opus's artillery turret (298, -320) → big spitter nest
  (398, -320), 100 tiles, with 1 medium worm turret".
- Live: `grep "artillery " runs/RUN/stream-service.log` lists each shell judged: cut, or drop with the reason. Off:
  `"artillery": false` in the run config's `director`.
- Tests: tools/stream/test_artycam.py (the cut in time, the label, back to the story, lead and spacing, more shells,
  outranked, one client, the service) and vendor/factorio-harness/tests/d17_artycam.lua (the read: the loader,
  target and landing time, one key per shell, the small find, the slow pace when nothing is loaded).
- Not seen live yet: no piece on world n held shells while this was built (3 turrets on Nauvis, all empty at 13:00).
  The read needs the harness deploy; until the runtime lists `artillery_live` in `describe`, the service does not ask.

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
  quota" (activity `resting`: a blue dot, not idle or offline; "out of quota until ..." for a quota sleep; both short
  enough for a card's line at 1080p, batch115), the hosts get it once per rest (an alert of kind `rest`, an info line for them), and the
  director leaves the agent out of its picks. The site's card shows the same state and text.
- tools/supervise.sh types no nudge into the sleeping loop (logs "skip nudges: resting until 18:17" once a rest), and
  tools/idle_nudge.py sends no tell ("resting until ..." as its reason).
- Tests: tools/test_quota.py (the state file, the wake line, the loop's next prompt), tools/test_supervise.py,
  tools/stream/test_pacing.py.
- (d22 batch108 BR1, Grok's weekly limit at 20:04 Thursday, reset Sat 15:59) Any agent can rest: tools/quota_rest.py
  RUN AGENT --until "YYYY-MM-DD HH:MM" [--reason quota|pace] writes the same file (and --done ends it), and
  start-team writes one for each agent whose account is at its limit. Those agents have no loop to call --woke, so
  pacing.py also ends a rest once the agent's journal has a request of its own after `since` (describe, profiles,
  cameras and peeks do not count, as in rests.lua). The card, the hosts' fact and the logs name the day when the rest
  ends on another day: "out of quota until Sat 15:59". supervise.sh reads the rest through
  `python3 tools/stream/pacing.py until DIR`. Test: test_pacing.py grok().

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

## One camera: POG_CAMS=1 (Sunday 2026-10-18, eng/d16-onecam)

On Sunday Nick plays his own Factorio on the box, so the stream runs on one camera client (cam1) and OBS only.

- `POG_CAMS` is a count (1-3: cam1 .. camN) or names ("cam1 cam3": a subset when the box is short of memory); unset
  means all three. `tools/cams.py` reads it for:
  - start-cams.sh, which starts and waits for only those clients;
  - start-team.sh, which writes the director's slots in stream.json (`POG_CAMS=1`: `[{"slot": "main", "player": 1}]`)
    and points shot-sync at those clients' folders;
  - the stream service, which hands cuts.py only those captures.
- start-team writes `POG_CAMS` and `POG_EXPECT_CAMS` (the number of clients) to runs/RUN/switches.env, and logs
  "cameras: cam1 (1 client: one camera, no inset or trio)". `POG_EXPECT_CAMS` is the count the operator's watchdog
  should expect in the game.
- At a shift change `POG_CAMS` carries over from the previous shift. One set in the operator's environment wins
  (shift_change.py ENV_FIRST): `POG_CAMS=1 tools/shift-change.sh ...` at the Saturday 21:30 change, and
  `POG_CAMS=3` at the first change after Sunday.
- The director with one client (onecam.py `retarget`):
  - Where three clients would frame a standby and cut, it moves the client on air to the new subject at once (a
    jump). The log gets a "program" row "move main: REASON", and the move counts as a program cut.
  - Until this change it moved the client only when nothing was on air: in a 3-hour mock simulation the one camera
    showed two agents and base attacks. Now it showed all nine; the program cut every 24 s on average (median 15 s
    on a subject), against 25 s and 16 s with three clients.
  - No inset (no client is free: alerts elsewhere become toasts, deaths and big losses still cut) and no trio
    (trio is off below three clients).
  - Urgent shots, battles, `/follow`, `/platform`, `/look` and segments move the one client the same way.
  - The vertical scene is restacked as before. The shots and the casters are unchanged.
- cuts.py keeps "stream cam1" on air in the main hole and turns the other camera captures off, in the stream scene
  and the vertical one. They match a window by title "Factorio 2.0.77", otherwise by executable (priority 2), and
  Nick's own Factorio window must not show through one of them. With three cameras again, cuts.py turns them back on:
  obs.py rehook-cams leaves an item that is off alone.
- Checked on the box's OBS in a scratch scene: references to the three captures and the overlay, never on program,
  removed after. In one-camera mode cam1 is on, cam2 and cam3 are off, and cam1 fills the main hole; in three-camera
  mode all three are on again. The live "stream" scene was not changed. The frame below is the scratch scene with
  the live overlay. Its empty inset frame is the live three-camera director's; a one-camera director publishes no
  inset.

![one camera, scratch scene](stream-onecam-scratch.png)

## Camera client memory, d16 (eng/d16-stream7)

The box (pogwin, 32 GB) at 15:06 on 2026-10-16: 0.4 GB free; nonpaged pool 3.1 GB; about 13 GB held by no process;
up since Oct 14 19:30. Each camera client starts at about 3.1 GB private and grows about 350 MB an hour; cam2 and
cam3 died at 14:59 with no Windows error (their logs just stop). Already set: medium sprites,
`video-memory-usage=low`, texture streaming (start-client.ps1, "Director client memory" above).

**Not measured yet.** This session could not reach the box: its sandbox blocks ssh and scp to pogwin, and the
operator's go-ahead to bypass it was refused by the guardrail hook. The Mac has no Factorio client (only the
Steam 2.0.72 user data, which cannot load a 2.0.77 save anyway). So there are no before/after numbers or screenshot
pair here yet. The scripts below get them; each one is read-only on the live server, OBS and cameras.

What a camera never needs:

- Sound on cam2 and cam3. OBS's "stream game audio" captures `factorio-cam1.exe` only, and every capture has
  `capture_audio` off (read from the box's OBS, 2026-10-16). `start-client.ps1 -NoAudio` adds `--disable-audio`, so
  the game loads no sound at all, for a camera started without `-Sound`. Picture: unchanged. Memory: not measured.
  It is opt-in until a test client has started with it, because an unknown flag would stop a camera from starting.
- Music: already 0. Chat on screen: already 1 tick.

The other `[graphics]` keys in a 2.0 config.ini (commented defaults), for a camera:

| Key | Default | For a camera |
|---|---|---|
| `streamed-atlas-physical-vram-size` | 0 (32 MB at medium) | The streamed atlas's size in video memory. Smaller means more re-streaming; system RAM effect unknown. |
| `max-texture-size` | 0 (auto) | Caps atlas page size: smaller pages, more of them. Effect on private bytes unknown. |
| `texture-compression-level` | high-quality | `low-quality` compresses sprites harder, with visible artefacts on stream. Last resort. |
| `optimize-for-low-vram` | false | Not documented. Try on a test client only. |
| `cache-sprite-atlas` | false | A disk cache of the atlas for faster loads. No steady-state saving expected. |
| `show-decoratives` | true | Grass, rocks and debris: part of the picture. Off only if a test shows a large saving. |
| `show-smoke`, `-particles`, `-clouds`, `-fog`, `-space-dust` | true | Small effects; little memory expected. Clouds and fog are part of the look. |
| `high-quality-animations`, `-shadows`, `-terrain` | true | Mostly GPU time. |

What grows each hour. There are three candidates, and `mem-sample.ps1` tells them apart:

1. Game state. The map, pollution, and the mods' Lua storage (journals, chronicle, tells). Every client holds the
   same game state as the server, so the world's server process would grow at the same rate as the cams.
2. Drawing. Sprites streamed in as the camera visits new places, and the chart textures behind the base-map
   shots. Only the clients would grow, the cam that travels most the fastest, and it would level off once the
   streamed atlas is full.
3. A driver. Neither the clients nor the server would grow, but `mem-audit.ps1`'s "no owner" figure or the GPU's
   shared usage would. 13 GB over about 44 hours is about 300 MB an hour, so this is worth checking first. Game
   capture of three windows and the encoder both live in the GPU driver.

What a reboot would recover, from the 15:06 counters:

- The nonpaged pool, 3.1 GB. A few hundred MB is usual; pool memory is freed only by its owner or by a reboot.
- The roughly 13 GB that no process holds: driver-locked memory or GPU memory shared with the system.
- Each running client's growth since it started.
- Roughly 15 to 16 GB in total, more if the cams have run long.

`mem-audit.ps1` shows these figures now, and running it again after a reboot confirms them. If poolmon or RAMMap is on
the box, it reports where they are, and poolmon's top tags name the driver behind the nonpaged pool.

Scripts (tools/win, run with `tools/winps.sh` from the Mac). They are written but not run: there is no PowerShell
here and no path to the box.

```sh
tools/winps.sh tools/win/mem-audit.ps1        # read-only: pools, "no owner", GPU memory, top processes, RAMMap/poolmon
tools/winps.sh tools/win/mem-sample.ps1       # read-only: one row per factorio*/obs64 process, appended to
                                              # D:\pog\memtest\samples.csv; run it every 15 min for an hour
tools/winps.sh tools/win/memtest-client.ps1 -Variant base             # isolated test client (below)
tools/winps.sh tools/win/mem-sample.ps1                                # after 3 and 15 min: factorio-memtest rows
tools/winps.sh tools/win/memtest-client.ps1 -Stop
tools/winps.sh tools/win/memtest-client.ps1 -Variant noaudio -NoAudio  # then the same samples
```

`memtest-client.ps1` sets up its own client:

- write dir D:\pog\memtest\VARIANT, exe `factorio-memtest.exe` (OBS does not capture it), task
  `pog-memtest-client`;
- a camera's `[graphics]` plus the variant's keys (`-Graphics 'key=value,...'`, `-NoAudio`);
- a copy of world n's newest save, loaded as a local game, so it never joins a server.

It refuses to start below 8 GB of commit headroom: as of 15:06, run it after a reboot or between shifts, not
now. It also runs one more copy of the simulation, so check the box's CPU first. Compare the variants at the same
age, after loading. A variant that changes the picture (decoratives, compression) needs a screenshot pair:
`tools/win/desktop-shot.ps1` while it runs.

## Machines at work (2026-10-14, eng/efficiency)

Nick (15:50): production credited fairly to the agents who build machines; viewers Enginerd and Foobator asked for
automation over hand work. The harness's operator read `efficiency` (efficiency.lua; vendor docs/usage.md) credits each
machine's output to the agent who built or planned it, read one 128-tile block every other tick.

- `live.py observe_efficiency` reads it every 5 minutes once `describe` lists it and appends the read to
  `runs/RUN/efficiency.jsonl` (`efficiency.py`). The shift's numbers are the runtime's own.
- The "efficiency" card ("Machines at work this shift", every 30 minutes, the first a third of a period in): items the
  team's machines made this shift, machines and how many working, the share moved by machines (against hand hauling),
  and one agent's line, the next agent each card ("Machines Sol built made 12k items this shift; 82% of Sol's items
  moved by machines"). No ranking.
- The hosts: the card's facts with a neutral call; and `machines_news` when, against the read 30 minutes before, the
  machines working moved by a fifth (10 or more) or the share moved by machines by 10 points.
- Machines built before the build log are "built before the count" until `tools/efficiency_seed.py --send` (from the
  agents' journals: hand builds by unit, batch builds and ghost placements by spot) names their builders.

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

## Maiden flights (2026-10-17, eng/d17-maiden)

Viewer Foobator (d17 14:24): "please show new ships on their maiden flight on stream". A platform's first departure
since it was built is a maiden flight. The director holds the camera on the ship through the departure and the first
minute and a half of flight, and the hosts get a card and a headline.

- Which departure is the first: chronicle_log.platform_history reads the platform_created, platform_left and
  platform_renamed events in the chronicle files along the run chain (runs/RUN/chronicle.jsonl, then each
  resumed-from shift's) when the stream service starts (serve.py, model.set_platform_history). It keeps each name's
  newest creation (who built it, where) and its departures since. A ship built again under an old name starts over:
  three ships have been called Kestrel. A renamed ship keeps its history under the new name. The live chronicle
  events keep it current. A platform with no creation record never counts: it was built before the chronicle, or renamed before
  the harness recorded renames.
- Renames: chronicle.lua tracks platforms by index and used to update a renamed one's name silently. It now records
  `platform_renamed {platform, from}`, a runtime change that needs a deploy. Two ships were renamed before that, on
  Oct 17, and have not flown since they were built: Spindle (built as Peregrine by Sol at 89h21m) and Kestrel II
  (built as Kestrel by Astra at 110h41m). Their first departures are not shown as maiden flights.
- model.py: a platform_left event with no departure since the creation is a `maiden_flight` moment and a "space"
  headline: platform, from, to, built by (the creation event's agent), game time; title "Maiden flight of Swiftlet to
  Aquilo". A departure read more than 2 game minutes late (a restart catching up) only goes into the history.
- The card: segments.py starts the moment as a space_moment segment, as for the other moments: the director starts it
  within 150 s as soon as nothing else runs. The card shows the platform, the route, who built it and the game time,
  over the ship framed for flight. The hosts' headline call names the ship, where it is going and who built it.
- The camera: onecam.py takes the moment as a departure held `maiden_hold` (105 s) instead of `depart_hold` (60 s),
  captioned "Swiftlet · maiden flight · Nauvis to Aquilo · built by Luna". If the plain departure is already on air, it
  becomes the maiden flight. A moment older than `maiden_late` (90 s) when the director sees it is not shown. Each
  moment is taken once, so once per ship.
- Rank: as a departure. An operator look, platform hold or follow, a key battle or incoming group, an urgent shot (a
  death, a big loss), a segment (its own card first) and a platform in danger come first. A departure cut short comes
  back for what is left of it. Host view (Nick's own view on air, hostview.py) comes first too: the director takes no
  maiden moment while it is on, and takes it after if it is still within `maiden_late`.
- One camera (POG_CAMS=1): plain departures and platform visits stay off with one client, but a maiden flight moves the
  one client to the ship, as a segment does.
- Tests: tools/stream/test_maiden.py covers the history along a run chain, a reused name and a rename, the moment
  and what is not one, three cameras and one camera, a departure already on air, a big loss and a segment first, the
  card's facts and camera, the overlay rows, and the hosts' call. vendor/factorio-harness/tests/chronicle.lua covers the
  rename event.


## A spidertron's fight on camera (2026-10-22, d22 batch93 BC2)

Viewer Foobator (13:33): "could the camera on spidertrons zoom out a bit more when rockets are fired? half the action
is not on cam". Shift58 13:28-13:30: Opus drove spidertron 2 to the nest at (-369,-943) with `vehicle {go_to}`, and its
rocket launchers fired on their own at spawners and worms about 32 tiles out. No `shoot` ran, so the agent row had no
combat. The director followed Opus at the follow zoom for driving, 0.75 x 1.5 = 1.12 sent: about 35 tiles across the
on-air hole (view_frac 0.658), so the rockets' targets were off frame.

- Status brief's `vehicle_fire` (runtime `M.vehicle_fire`): while the character drives a spidertron, the spidertron's
  guns' range (2.0.77: four rocket launchers, 36 tiles), the rockets loaded, and the enemies within that range (units,
  spawners, worms, segmented and spider units; up to 64): `targets`, `farthest`, `nearest`, `box`. live.py and the
  model pass it into the snapshot's agent row.
- onecam `fire_zoom`: an agent whose spidertron has rockets and enemies in range is framed to the farthest of them, at
  the fight shots' fit and limits (`fight_zoom` of twice that distance: at least 0.4), when that is wider than its
  follow zoom. `keep` widens the shot on air, refits as targets change by `zoom_delta` or more, and goes back to the
  activity's zoom once nothing is in range or no rockets are left. A cut to such an agent starts wide (`apply`).
- Opus at (-370,-926.4) on a copy of world n's 12:04 autosave: 17 enemies, the farthest 33.9 out. Before: zoom 1.12
  (about 35 tiles across on air); after: 0.43 (about 92 tiles), the log line `zoom 0.43 (its spidertron fires: 17
  enemies within 36 tiles, the farthest 33.9 out)`.
- Cost on the copy (x86 under Rosetta): a brief status seated in the spidertron 8.2-9.1 ms against 7.6-8.0 for an
  agent on foot; the find itself 0.025 ms.
- Tests: `tools/stream/test_spidercam.py`, `vendor/factorio-harness/tests/d22_batch93b.lua`.

## The site's chart (2026-10-22, d22 batch97 BG3)

Nick asked for a map like the Galaxy of Fame's. tools/stream/chart.py draws every planet and platform as 384-tile cells
at 1 px a tile in the game's map colours, from the harness's `chart` operator read (chart.lua), one read every 5 s
(3 s while chunks wait for their first read), each under 20 ms on world n (6 chunks or 1200 entities at most):
- protos once (colours and footprints), the surfaces every 5 minutes, then per surface a `list` of the charted chunks
  in 64-chunk blocks from the one round the origin outwards, every charted chunk read once (two reads in three), then
  `dirty` with `check: 48`, the surfaces in proportion to their chunks so every surface's count check comes round in
  about the same time (chunks marked by the harness's events or a changed entity count, each read at most once per 10
  game minutes), and chunks read 6 game hours ago again;
- the store, runs/RUN/chart/store/SURFACE/CX_CY.json (Nauvis 5.8 MB with Vulcanus and a platform on the d22 copy), is
  read back from the runs this one resumed from, as the map memory is, so the first pass runs once;
- a changed chunk's cell is drawn again (and a neighbour's when the chunk is on its edge): tiles, resources and nature,
  then buildings at their footprint turned by direction; rails as curves between their two ends (the ends of each
  rail type by direction, read on the private copy with LuaEntity.get_rail_end); runs/RUN/chart/out/SURFACE/CX_CY.png
  and .labels.json (recipes, stop names), out/index.json (each cell's version, its chunks' oldest and newest read
  tick, and the box round our buildings). site/build.py publishes out/ under /live/chart/ (docs/LIVE-API.md).
- On the d22 copy of world n the first pass of Nauvis (3,251 chunks), Vulcanus (916) and Asterion (91) took 1,178
  reads; its cells: Nauvis 30 (568 KB), Vulcanus 12 (388 KB), Asterion 4 (24 KB). A cell draws in about 70 ms.

## Clipped lines: a marquee, and fixed text that fits (2026-10-22, d22 batch115 BX1)

Nick: wrapped or cut status lines are useless on a stream nobody can scroll or hover. static/marquee.js (both pages):
- Changing single-line text wider than its box rests at its start and now and then pans to its end (3.5 font sizes a
  second: 49 px/s on a 14 px card line, 84 px/s on portrait's 24 px), holds 2.5 s and cuts back to its start (d23 batch124 CG3, Nick: the pan back was "a little excessive": a 0.2 s fade out, a jump, a 0.2 s fade in; it was a pan 4x faster, 1-3 s).
  Lines take turns page-wide: at most two away from their start at once, starts 4 s apart, the longest rested first,
  each at its start at least 12 s between pans and at least as long as its pan takes. New words go back to the start;
  a change in numbers only (an age, a countdown) keeps the turn. A soft fade at the right edge replaces the ellipsis.
- In marquees: the agent cards' line two (model and job), the action line, the wait condition and the location, the
  camera label's doing (the on-air bar and the trio's tiles), the research card's name and its line under the bar
  (done, latest and now the infinite levels, which had a second line no card cell had room for).
- Cost: a Web Animation of one transform per moving line (the compositor runs it); widths are measured when the text
  changes and on ResizeObserver; a 1 s timer picks turns. No per-frame script.
- Text we control is shortened instead: pacing.py's rest labels ("resting until 22:14 · pacing quota", "out of quota
  until Sat 15:59"), spark item names that do not fit about 80 px ("Low density", "EM sci.", "Prom. sci.", "Agri.
  sci."), the header subtitle (the first of three wordings that fits beside the title: "Factorio:" goes first), and
  five planet chips in the Space head (three letters each, in their colours, when the names do not fit). On portrait a
  squeezed name ("Muse S…") hides the token count.
- Left as they are: chat messages (3 lines, the newest 9: a moving feed already, and a vertical pan would fight new
  arrivals), the analyst desk's headline on an unused tile (2-3 lines, written short), segment and poll cards (timed),
  and the rotating board and Space widgets' rows (18 s on screen, less than a rest and a pan).
- Tests: tools/stream/test_marquee.py (timing, turns over 15 minutes, the DOM half with a fake document).

## Attack shots calibrated to how attacks go now (2026-10-23, d23 batch124 CG1)

Nick 10:00: the camera locked on biters approaching Nauvis, "slightly less interesting these days now that the defenses
are holding"; they "move for a little bit and then stopped"; following them, the camera "tended to lag their position".

- The shot: 09:53:51, group 24507 ("18 biters heading for the base, 630 m SW of spawn"), score 2.089 = size 1.389 (18
  against the last 30 groups) + outpost 0.7, bar 2.089 (38 candidates and 2 taken in the hour, budget 4). It panned
  with the group from (-691, 395) to (-540, 329) in 21 s, then the group stood; the follow ended at 09:54:56 "stopped:
  under 8 tiles in 44 s" (the rule was 8 tiles in 45 s, 80% of it read). Its stop was about 190 tiles west of the base
  map's edge, with no turret of the map within 290 tiles.
- This morning (director logs 03:46-10:06): 176 groups, 12 followed; every followed group ended "stopped" (11) or
  "turned back" (1) before contact; 3 real losses on Nauvis (a pole and construction robots to behemoth spitters at
  (-211, 170), a wall at (-213, -32)). Routine waves.
- threats.py tracks every group to its end (gone from the read for 60 s): contact or not, and the real losses (not a few
  walls, belts or chests) within 60 tiles of it or its target while it lived and 60 s after. routine = -1.2 x (1 - the
  share of the last 20 ended groups that destroyed something), from 8 ended on: about -1.2 today, so the 09:53 group
  scores 0.889, under the floor (1.5). no_cover (+1.0): its target (else our nearest building to it) inside the base
  map with no turret of the map reaching it. A fight that destroys something is a battle (score_fight, unchanged), so
  an attack doing damage still cuts in.
- The cut away: a followed group that moves under 8 tiles in 12 s (at least 80% read; not while gathering) is over;
  so is one gone from the read (disbanded or killed), one 40 tiles farther than its closest approach, or 240 s on.
- Ahead of it: each pan aims at where the group will be 4 s on, from its velocity over the last 6 s (at most 48 tiles
  ahead; as is under 0.5 tiles a second). The reads come about every 3 s and cameras.lua eases each move, so aiming at
  the last position kept the view a read behind (09:53: 20-36 tiles a pan).
- Tests: tools/stream/test_incoming.py (calibrated, the stop rule, the lead). Deploy: a stream service restart; the
  calibration starts from the run's threat-history.json and needs 8 ended groups (about 20 minutes today).

## Panning across spaceships (2026-10-23, d23 batch124 CG2)

Nick 10:00: "I think the panning across spaceships could be a little better." From the director logs of d23 07:55-10:10
(2637 reframes of ships; 84 platform cuts):

- Stop-and-go (fixed). The director steps every 1.1-1.5 s (1090 steps at 1.1 s, 698 at 1.2, 448 at 1.3-1.5) and each
  step moved the view about 6.7 tiles at a glide of 1.15x the pan's speed (6.77 tiles/s at zoom 0.3), so each glide
  ended in about 1.0 s and the view stood 0.1-0.5 s before the next: a stutter about once a second. Each step now aims
  where the pan will be 1.5 measured step intervals on and glides there over that time (onecam PAN_LEAD, the interval
  an average of the last steps), so the next step comes while it still moves.
- Hard starts and stops (fixed). A leg went from rest to full speed at the bow and stopped dead at the stern. Each leg
  is eased now (smoothstep): slow off the bow, fastest mid-ship (1.5x the average), slow onto the stern.
- Not changed, proposed: repeated shots of one ship start its pan from the bow each time (Sol's remote work on
  Asterion cut to it at 08:00, 08:03, 08:06 and 08:15, Astra's at 08:08 and 08:12: six bow-to-stern starts in 15
  minutes); a shot of a ship shown in the last 10 minutes could continue from where the last one left off, or the
  "platform work" cut could wait longer between visits to the same ship. The pans run along the ship's north-south
  axis, its long one (forward is north on a platform; thrusters aft), which suits the 16:9 frame's height.
- Tests: tools/stream/test_platformpan.py, test_shipcard.py. Deploy: a stream service restart.

## A narrated tour (2026-10-23, d20 batch125 CH1)

Nick (d23 10:28): a narrated camera tour, scripted ahead. tools/stream/tour.py plays a script of stops ({id, target
{surface, x, y, zoom} or {platform: NAME}, seconds, caption, narration, facts}) through the service:
- `tour.py prepare SCRIPT` renders every narration first (voices.TTS, keys in ~/.config/pog/) into
  SCRIPT_DIR/tour-clips/ with manifest.json; unchanged narrations keep their clips. One narrator voice for the whole
  tour: the first of `--voice` (default el-brian, then oa-fable) that renders every clip and that no host or agent
  speaks in.
- `tour.py dry-run SCRIPT` prints the timeline (no camera, no audio); `run SCRIPT [--from ID]` airs it; `stop` (from
  another terminal) ends it. A stop lasts max(seconds, clip + 2 s), timed from the clip's start on the page.
- Camera: POST /look (renewed before its 60 s limit) or POST /platform with the caption as the label; a refused target
  (uncharted, unknown platform) or a malformed stop is skipped with a log line. The director's cuts wait under a hold.
- Audio: POST /audio, channel `narrator`, rank `urgent` (the page plays one clip at a time and an urgent one next, so
  an agent's aloud line waits for the narrator). The hosts stay quiet: caster.py `--hush-file`
  (tools/stream/logs/hosts-hush.json {until, by, reason}) stops its lines, reactions and segment requests while
  `until` is ahead; the tour renews it each stop (remaining + 120 s) and removes it at the end, on `stop` or Ctrl-C.
- Log: tools/stream/logs/tour-START.jsonl, one row per stop (aired: started, on_air, narration_start, ended; or
  skipped with why).
- Tests: tools/stream/test_tour.py.

## The tour, version 2: timing (2026-10-23, d20 batch128 CK1)

Nick (17:30): "get the timing really tight between the shot durations and the measured voice line durations".
- What the 16:30 run did (tools/stream/logs/tour-20261023-163005.jsonl against the director log
  director-20261023-162515.jsonl): on planet stops the narration started 1.9 to 3.0 s *before* the program cut. From
  stop 2 on, the tour's on-air check matched any look (the previous stop's was still on air) and posted the clip at
  once, while the director framed the new look on a standby and cut 2.3 to 3.7 s after the POST (ready_s 1.5 s plus
  the 1 s tick). Ship stops checked the name: their narration started 0.6 to 0.8 s after the cut. Every stop then
  held about 20 s after its clip (the script's 60 s against clips of 33 to 47 s). Two narrations started 14 s late,
  behind agent lines already playing (Luna 19 s, Sol).
- Now a narrated stop is cut, LEAD_S 0.8 s, the clip's measured length, TAIL_S 1.5 s (`hold_s`, `min_seconds` in
  the script; `seconds` only for a stop without narration). One timeline on the clock: each stop goes to the service
  PREROLL_S 4 s ahead:
  - POST /look with `cut_at` (lookcam.py): a standby frames it at once, the program cuts at that moment (onecam
    `look_direct`; `next_wake` wakes the director for it); one client moves then. `id` tags it; the snapshot's
    look says `aired`. `{platform: NAME}` is a whole ship as the director frames it (no chart read), so ships and
    spots are one kind of hold. POST /look/extend renews it with no chart read.
  - POST /audio with `at` = cut + 0.8 (serve.py AudioHub, static/audio.js): the page loads the clip on arrival and
    starts it at that moment on its audio clock; until then no queued clip starts that would still play at `at`
    (one that does is ducked, `?duck=`); the start report carries `started_at`. /audio/status lists `queued`;
    POST /audio/cancel takes a clip back.
  - The drift (look.aired against the cut asked) is smoothed and the next cuts are asked that much sooner.
  - An agent's line waiting in the queue near a stop's end (and not expiring before the narration ends) holds the
    stop for its length; `--no-agent-gaps` turns that off (agent lines expire after 20 s in the queue).
- Measured on `serve.py --mock` (three cameras) with the real audio.js in node: the program cut 3 to 5 ms after the
  moment, the narration 0.800 s after the cut (the page's clock: 0 to 1 ms). On air the OBS z-order thread (cuts.py,
  0.1 s poll) adds up to 0.1 s to the cut.
- Script format for writers: tools/stream/tour-FORMAT.md. Tests: test_tour.py, test_tourcam.py, test_touraudio.py
  (tour_audio_selftest.mjs in node).
- Deploy: serve.py, lookcam.py, onecam.py and audio.js changed: restart the stream service and reload the overlay
  page (OBS browser source refresh) before the next tour; `tour.py run` refuses a service without /audio/status
  `queued`.

## The tour, version 2: camera moves (2026-10-23, d20 batch128 CK2)

- A stop's `move` (tools/stream/tour-FORMAT.md): `to` (pan and zoom), `zoom`, `path` (points), `"hold"`, or a list,
  timed in seconds from the cut (default the whole stop), eased (inout, in, out, linear). tour.py turns it into a
  camera move (tools/stream/camerapath.py: segments of points {x, y, zoom}, t0, t1, ease) over the stop's length.
- The math, in three places that agree: the time eased, along the path by length (|dx, dy| + 20 |ln z1/z0| a step,
  so a zoom has length), x and y by a cubic Hermite spline with chordal knots (a straight path at even speed, a
  bent one without corners), zoom by ln z. camerapath.py (the service, tests), cameras.lua `move` (the game, every
  tick: the view put exactly there, no easing; it rests at the end), and next the page (CK3's marks).
  test_camerapath.py and cameras_test.lua check the same five points.
- POST /look {move}: the look's spot is its first point; every point's frame is chart-checked (one read each). A
  standby frames the first point without it; the cut sends it (director.apply `move`); the snapshot's look has it
  with `aired` (the move's start). {platform, move: "pan", move_s}: a tall ship bow to stern (rests of PAN_END_S at
  each end) as a move; a ship that fits stays still. A camera reply without camera.move (a game whose harness has no
  `move` yet): the director steps the move itself, aiming 0.8 s ahead every 0.5 s with a glide (cameras.lua speed),
  so a tour works before the harness install too, less smoothly.
- Cheap on the game: no reads; one camera command a stop (the fallback: two a second while a move runs).
- Deploy: cameras.lua is harness Lua: the moves play smoothly after the harness install on world n; until then the
  fallback. The stream service restart (cp1) covers the rest.

## The tour, version 2: marks on the shot (2026-10-23, d20 batch128 CK3)

- A stop's `marks` (tools/stream/tour-FORMAT.md): arrow, circle, box, label at map positions, with text, colour and
  times from the cut. tourlay.py checks them; tour.py posts each stop's entry (POST /tour/overlay {id, cut, until,
  length, view, marks}) with the look, its view the look reply's (spot, zoom, move; a ship's the director's frame);
  serve.py keeps at most 3 entries (each gone at its until; DELETE /tour/overlay at the tour's end) and puts them in
  the snapshot as `tour`.
- The page: static/tourlay.js (index.html, portrait.html; ?tourlay=0 off) draws the entry on now as SVG in
  #cam-main over the capture's whole box, from the cut (the look's `aired` when the look on air has its id), every
  animation frame. World to screen: a tile is 32 * zoom * (hole height / 1080) px (a hole wider than 16:9: width /
  1920; the clients keep a 1080-line view, mapframes.py), about the hole's centre at the camera's position, which
  during a move is camerapath.py's math in JS (tourlay_selftest.mjs checks the same five points as Python and Lua).
  Text is kept inside the hole. Seen on `serve.py --mock` (overlay_shot.sh): ring, arrow, box and label on their
  tiles at zoom 0.8.
- dry-run lists each stop's marks and finds a mark out of the frame while it shows (the move sampled every 2 s).
- Tests: test_tourlay.py (marks, the store, off the frame, HTTP, the page's geometry in node), test_tour.py
  `overlays`. Deploy: the stream service restart and page refresh (cp1) cover it.

## The tour, version 2: subtitles (2026-10-23, d20 batch128 CK4)

- The narration as timed captions in the camera hole. tools/stream/subtitles.py times them from the text and the
  clip alone: pieces at punctuation weighed by syllables, the clip's pauses from ffmpeg silencedetect (-35 dB, 0.18
  s), each piece boundary on the nearest pause in order (within 1.2 s), else its estimate; captions of at most 84
  characters, a sentence's end (16+ characters) closing one. On the el-brian clips the narrator pauses 0.25-0.45 s
  at every comma and full stop; a writer's 39 s clip (nauvis-launch) came out as ten captions, each ending on a
  pause.
- `prepare` keeps them in the manifest (subs, subs_v; a kept clip gets them with no TTS call); `run` times older
  manifests' on the spot (ffmpeg, ~0.1 s a clip). The overlay entry carries subs with subs_at, the narration's
  moment, so they run on the same clock as the page's audio; the narrator clip goes with `caption: false` (audio.js
  leaves its caption box out; the stop's caption is still the look's label in the bar). static/tourlay.js shows the
  one on now in a band above the bar (`"top"`: under the hole's top edge, for old clips). `subtitles: false` per stop,
  `run --no-subtitles` for the tour: the caption box comes back.
- Tests: test_subtitles.py (pieces, timing, pauses on an ffmpeg-made clip), test_tourlay.py (captions in the store,
  captionAt in node), test_tour.py (prepare keeps them; run posts them; off). Seen on the mock (overlay_shot.sh).

## The tour, version 2: old clips (2026-10-23, d20 batch128 CK5)

- A stop's `clip` (tools/stream/tour-FORMAT.md): a clip library id (batch129: R2 <id>.mp4, H.264, already the
  camera hole's 1208 x 1032; <id>.json with seconds and caption) or an .mp4 url, start_s, seconds, caption.
  tour.py resolves each in dry-run and run (the .json and a HEAD on the .mp4; r2.dev answers Python's own
  User-Agent with 403, so it sends `pog-tour/2`); a stop whose clip is not there is skipped. The stop lasts at least
  the clip's play time + 0.5 s. With no target there is no look: the last stop's look is extended behind the clip.
- The page: tourlay.js loads a muted <video> per entry with a clip as the entry arrives (a stop ahead), shows it over
  the whole hole (z 2: marks 3, captions 4), plays it from start_s at the cut, keeps it within 0.35 s of the clock
  and holds its last frame to the stop's end; an ARCHIVE badge (caption, title) at the top left; captions go on top
  for a clip stop (the clips carry the old speech bubbles low).
- Sound: the clip plays muted. Its sound is the old hosts' voices (batch129: "the clip's audio has the old hosts'
  voices on it") and that hour's game, which would talk over the narrator and the hush; the stream's live game
  sound goes on as the bed, ducked under the voices by OBS as always (tools/obs.py stream-audio). Ducking it further
  for a clip was not needed: the bed is the same as on every other stop.
- Checked: a dry-run against the live library (s01-death-006: 22 s, "from shift 1, Oct 12", Opus died; a missing id
  named with the clipmaker command); in Chromium the video, badge and top caption are put in the hole (a frame of
  the video itself was not caught: the headless runs end before it loads); both local Chromes report H.264
  ("probably"). OBS's browser source (CEF, on the stream machine) was not tried.
- Tests: test_tour.py `old_clips`, test_tourlay.py (clips in the store), tourlay_selftest.mjs (clipAt).

## Camera crops after a shift change (2026-10-23, d23 batch124b)
- Nick 16:28: the main view was letterboxed, with a background camera on another planet showing.
- After the 16:20 shift change, "stream cam1" and "stream cam3" had crop 0, while cam2 had 492/492. stream_scene
  computes the crop from the capture's source size, and a game capture reads 0 x 0 until it hooks a client. The scene
  is set before the clients join, so crop_for got no size and set no crop. It was fixed live at 16:29 with
  crop_for(2880, 1620, 1208, 1032).
- Now `obs.py rehook-cams`, which start-cams runs once the clients have joined, crops each camera after turning it
  off and on:
  - A camera that is on is read every 0.5 s until its source has a size, with 10 s for the whole call.
  - Its crop is crop_for(source size, the item's bounds). The bounds are the hole that stream_scene placed it in.
  - A camera that is off stays off. It is read once and cropped if it already has a size.
  - Each camera's part of the reply, logged by start-cams as "OBS captures: …", gives the crop, the source size and
    the crop it replaced. For example: `stream cam1: re-enabled; crop 492/492 0/0 (source 2880x1620 into
    1208x1032, was 0/0 0/0)`. A source still with no size says "no source size after 10 s, crop not set".
- Not changed: "stream host" (Nick's client, off until host view) is still cropped only by stream_scene and
  host-view-source.
- Test: `tools/test_obs_rehook.py`.

## The hosts: arrivals gated, analyst beats (2026-10-23, d20 batch130 CM1-CM2)
From the hosts proposal (d23 18:40, section 3). On d23, 47% of host beats were dockings, and no analyst point reached
a host prompt.
- CM1, hoststory.ArrivalGate. An arrival (kind `arrival`) is a beat only when one of these holds:
  - it is the route's first this shift, by any platform;
  - it brings science or eggs, the platform's first delivery of that kind on that route this shift;
  - the team's goals name the ship;
  - it ends a leg of 60 game minutes or more.

  The reasons go into `why_it_matters`. Every other arrival is a `traffic` fact ("N routine platform arrivals in the
  last 10 minutes"), which a beat may use in a word. Space firsts pass and are noted. What was seen is kept in
  `runs/RUN/host-arrivals.json`.
- model.py's arrival alert now carries `leg_minutes` (from the route memory) and `carrying` (science and eggs in the
  hub). A new shift also reads `visited` and `reached` from the shifts before it. Before this, every ferry's next
  arrival at each planet aired as a priority-10 first ("Kestrel II reaches Fulgora": 62 of d23's 71 space beats).
- CM2. A fresh analyst point of priority 2 or more is a beat (kind `analyst`, priority 5). The limits: one per 240 s,
  aired or not, and one topic per 30 minutes, because the analyst posts each topic again every cycle under a new id.
  `how_to_call_it` asks for the one number, its cause and what it leads to. check_line holds the lines to the
  point's facts (ANALYST_CHECK), so background numbers are rejected.
- Replay: `python3 tools/stream/hosts_replay.py [--day 20261023]` runs a day's caster logs and every chronicle
  arrival through the gate, and counts the analyst beats that would have aired. On d23, 523 exchanges became 256, and
  logged arrivals went from 248 to 43. The chronicles had 11-19 speaking arrivals per shift out of 177-346. About 122
  analyst beats would have aired.
- Tests: tools/stream/test_hoststory.py (arrival_tests, analyst_tests), test_route_direction.py.

### The run in plain English (CM3)
- Every host prompt's `story` memo carries `run_so_far`, a block of about 340 words written from the d23 synthesis
  report. It lives in `runs/host-run-so-far.md`, beside the shift folders, and the caster creates it from
  `tools/stream/host-run-so-far.md` when it is missing. The memo reads it again at each rebuild (every 3 minutes),
  so an edit airs without a restart. `--run-block PATH` points the caster at another file.
- The plan's goals and each agent's plan line go through hoststory.PlainPlan, which rewrites them in plain English.
  It makes one call at most every 10 minutes, and only when there is text it has not rewritten yet. The model is
  `--plain-model`, else `--low-model` (live: Haiku 5.5, with reasoning off; with reasoning on it spent its 2,000
  tokens thinking and returned nothing).
  - The prompt carries the agents' and ships' names. It says to rewrite only (add, judge and advise nothing), and to
    drop ids, ticks and anything the model cannot read.
  - plain_checked drops a sentence that has a number missing from the note or a number of 7 digits or more (a tick),
    and keeps whole sentences up to 50 words for goals and 30 for a line.
  - The hosts' snapshot (`Caster.snap`, so the memo, team_plan and agent facts) has the rewrite only. A text not yet
    rewritten is left out. The Differ still compares the raw plan.
  - A plan change waits for its rewrite and then airs in plain English. It is dropped after 15 minutes. Rewrites are
    kept in `runs/RUN/host-plain.json`.
- Cost: the rewrite measured $0.00046-0.00057 a call (1,100 tokens in, 400-900 out), at most 6 calls an hour, so
  under $0.004 an hour. The run block adds about 450 input tokens to each host exchange, while CM1 removes about
  half the exchanges.
- Tests: tools/stream/test_hoststory.py (plain_tests).

## What changed this hour, and the analyst's repeats (2026-10-25, d20 batch197 NP1-NP4)
From the hosts proposal, idea E (Nick d23 and d25: the tour's depth on the normal stream). tools/stream/hourly.py
writes one prepared piece an hour for the narrator channel.
- NP1, the producer. `gather(run_dir, t0, t1)` turns the hour into numbered rows, each with its source and a weight:
  - scores.jsonl, the hour's first row against its last: rockets (against the hour before), research finished,
    infinite levels, the labs' sets a minute and the tightest colour, entity counts, new and gone platforms, planets;
  - chronicle.jsonl: research, deaths, platforms made, lost, renamed or deleted, a ship's first arrival at a planet
    along the resumed-from chain, rockets by planet and cargo, the agents' chronicle entries;
  - factory-digest.jsonl, efficiency.jsonl (machines working, machines built, the top maker);
  - the analyst's points (tools/stream/logs/analyst-*.jsonl): one per topic or much the same text, the best 8;
  - the agents' aloud lines (chat.jsonl, the last 2 each);
  - plan.json's lines and goals set in the hour, in the hosts' plain English when host-plain.json has the rewrite;
  - the attacks, losses and deaths the hosts called (tools/stream/logs/caster-*.jsonl).

  Camera targets are our ships by name, a death's spot, and spots where science is made on each planet (the middle
  of a science recipe's chart labels, kept only inside a building box of the chart index, as the tour build
  checked). A target is a row too: where a ship was at the hour's end.
- One model call (caster.LLMWriter on OpenRouter; default Opus 5.5 with reasoning at low effort, which batch196
  found it needs; `--model anthropic/claude-sonnet-5.5` works too). The prompt gives the rows best weight first
  (40 at most), the targets, the agents with the pronouns from the stream state (they/them when none), and the last
  two pieces. It asks for the two or three changes that matter most, as one piece of 60-110 words in one or two
  stops, with a cause and a consequence taken from the rows. The reply is JSON: changes, stops ({target, caption,
  narration}), and facts ({claim, source row}).
- NP2, the verifier, `check(piece, material)`:
  - the tour build's checks: 60-110 words, captions of at most 60 characters, no dashes, known targets;
  - every number the narration says (digits, and spelled out above ten) is in a fact's claim. A round figure may
    be rounded honestly: within 10%, "over" up to 1.5 times, "nearly" or "under" down to 0.85;
  - every name (agents, ships, planets; agents and planets in lower case too; any capitalised word mid-sentence) is
    in a fact's claim;
  - every number and name of a claim is in the row it names;
  - he or she only for a named agent who chose it; no "we"; no advice (should, must, needs to, consider ...).

  A refused piece is written once more with the reason. Refused again, it is dropped with a log line.
- `hourly.py dry-run --run-dir runs/RUN [--hours 4] [--from HH:MM] [--no-model]` writes the pieces for past hours
  into tools/stream/logs/hourly/: one JSON per piece (with its rows and targets) and RUN-pieces.md. Nothing airs.
  `--no-model` prints the rows only.
- What the verifier cannot see: a cause stated in words. The prompt says a cause comes from one row that states it
  and that two rows are never joined by "because", "so" or "it answers" unless a row says the link. A d25 live piece
  had said that a finished laser research "answers" the bow flaw Astra had named. Read the pieces for that.
- NP3, airing: `hourly.py run --run-dir runs/RUN` is the stream's helper. One hour after it starts, and every hour
  after that, it gathers the last hour, writes the piece and airs it as a one- or two-stop tour (tour.Tour). Each
  stop is a look with cut_at, and its narration plays at the cut plus lead in the tour's narrator voice, the first
  of el-brian and oa-fable that no host or agent speaks in. The hosts are hushed (the hush file) for the piece only.
  - It waits while hourly.blocked() names something on air. That is a fresh attack, loss or death (an alert under
    120 s old), a battle, an attack or an enemy group on air, or someone's look, follow, platform hold or host
    view. A tour overlay, a replay playing, or tour.py's run file with a live pid also make it wait.
  - It renders (tour.py prepare) only when it can air, then looks again. A piece not on air 10 minutes after it was
    written is dropped (`expired`, with what it waited for).
  - On air (Tour's new `interrupt` hook, looked at every 2 s): someone else's look or the host view ends the piece.
    With one camera (POG_CAMS=1: no inset for an attack), a fresh attack, loss or death or a battle ends it too.
    With more than one, the attack goes to the inset and the piece goes on. The camera count is `--cams`, else
    POG_EXPECT_CAMS, else the snapshot's cameras.
  - While it airs it writes tour.py's run file, so `tour.py stop` ends it and a tour started by hand waits.
  - Logs: tools/stream/logs/hourly-START.jsonl (written, dropped, aired, expired, with costs), each piece's
    tour-PIECE.jsonl, and the piece, its script and its clips in tools/stream/logs/hourly/.
  - `--once`: one piece for the last hour now, then it exits. `--no-air`: write only.
- The switch: POG_HOURLY=1 (default 0). start-team.sh starts the helper with it and writes it to switches.env, and
  shift_change.py carries it. POG_HOURLY=1 in the operator's environment at a change turns it on (ENV_FIRST). Its
  model is POG_HOURLY_MODEL (default anthropic/claude-opus-5.5).
- NP4, the analyst beats (caster.analyst_held, used by analyst_event): a point does not air while one of these aired
  in the last 2 hours (ANALYST_TOPIC_GAP, was 30 minutes), unless its number has moved by a tenth or more (and at
  least 1). Its number is its first numeric fact, else the first number in its text.
  - its topic;
  - much the same text;
  - the same subject (caster.SUBJECTS, by the text's words: research, a pack colour, mining, machines off,
    rockets, spoilage, power; attacks have none) with the same number of the same fact.

  `hourly.py repeats [--hours 24] [-v]` replays the analyst beats on air in the caster logs through it, joining
  each point's text to its topic in the analyst logs.
- Cost (d25): the piece's model call is $0.022-0.038 on Opus 5.5, and twice that when a draft is refused. The
  narration's TTS is $0.039-0.048 (el-brian, ElevenLabs, 520-600 characters, about 40 s). So about $0.07-0.12 a
  piece, and one piece an hour.
- Tests: tools/stream/test_hourly.py; test_hoststory.py analyst_tests (NP4); test_shift_change.py (the switch).

## Camera crops: the inset, and captures not hooked yet (2026-10-24, d24 batch136 PH2)
- After the 21:05 shift change (shift66), cam3 read crop 0 at about 21:07, and the operator set it with crop_for.
- **The change itself left all three cropped:**
  - OBS restarted at 21:00:51 (the box's clock runs an hour behind the Mac's; its log said 20:00:51).
  - The captures hooked their clients at 21:03:13 (cam2), 21:03:33 (cam1) and 21:03:56 (cam3).
  - rehook-cams at 21:04:30 read 2880x1620 and crop 492/492 on all three, so it said "unchanged".
  - obs-steps' stream-scene at 21:04:33 read the same sizes; OBS logged no capture restart in between.
- **cam3 was the inset at 21:07:** the director put it there at 21:06:58 ("attention: haiku inspecting"), and again at
  21:08:26 and 21:08:44. The inset (layout.json `inset`, 408x230) is 16:9, so cuts.py places it uncropped by design.
  Back in the main hole it is cropped again (place() on the role change).
- **A fault of the same kind, fixed:** Cuts.place(), stream_scene and host_capture wrote crop_for(0, 0, ...), which is
  no crop, for a capture not hooked yet (0 x 0). Cuts then kept the role as placed, so a capture that hooked later
  stayed uncropped in the main hole until its role changed. This fits the 16:20 change (cam1 and cam3 at crop 0).
- **Now:**
  - With no source size, the hole is set and the crop left as it is.
  - Cuts places such a capture again at its next apply, and keeps the role once it is cropped.
  - rehook-cams still crops each camera once its client joins.
- **`obs.py cams`** (read only) names each camera's hole by its bounds (main, inset, a trio tile), with its crop and
  the crop that hole takes: `ok`, `CROP OFF (that hole takes ...)` or `no source size (not hooked)`. obs-steps runs it
  last, so the change's log shows the cameras after the OBS steps.
- **Checked through the tunnel (reads only; nothing set or restarted):**
  - The scene's items read cam3 in the inset (bounds 408x230, crop 0), then in the main hole at 492/492.
  - `obs.py cams` read the same: "stream cam3: on, inset, crop 0/0 0/0, source 2880x1620: ok".
  - The box's OBS log gave the hook times.
- Tests: `tools/stream/test_cuts.py`, `tools/test_obs_hostview.py`, `tools/test_obs_rehook.py`,
  `tools/test_obs_restart.py`.

## A ship's bow on a long flight (2026-10-24, d24 batch170 QM1)

Viewer Caleb (site 14:51-14:52): "can you show the front part of Asterion while in flight for a few seconds each
round?" While a platform flies a leg to or from the solar system edge or the shattered planet, onecam's rotation gets a
bow shot (`bow_turn`):
- The hull: live.py `add_hulls` reads, for each platform on such a leg, its hull's box from its foundation tiles as the
  harness's asteroid watch finds it (asteroidwatch.lua M.hull: the chunks holding foundation, narrowed to the first and
  last row and column holding any) and the bow, the foundation's x extent in the hull's first 24 rows
  (`harness.PLATFORM_HULL_LUA`, `Harness.platform_hulls`). Each platform is read again after 10 minutes, at most two a
  read. The views' entity bounds cannot do it: PLATFORM_LUA stops at 4000 entities, and Asterion has about 7800 (its
  bounds read right = 6, the foundation reaches 71). On the d24 shift70 copy (Rosetta): Asterion 386 chunks, hull
  (-51,-50)..(71,230), bow x -51..51, 4.6-5.3 ms in the game; Chalk, Kestrel II and Meridian-V 2-4 ms.
- The shot: at a story turn (direct is about to cut to the next agent: a challenger, a rotation, a still subject), a
  fixed view on the bow for `bow_hold` (8 s; plus `ready_s` with three clients): the bow's width plus 12 tiles across
  (zoom 0.53 for Asterion), the hull's north edge `bow_ahead` (0.4) down the frame, so the space ahead, where
  asteroids come in, shows above it. Labelled "Asterion · the bow · travelling to Aquilo (21%) · 57 km/s". Then the
  story goes to the agent the turn was for ("after the bow: luna").
- At most once a round: not within `bow_gap` (300 s) of the last one, and the round over: every agent on air in the
  last `bow_window` (1 h, and still here) had a story since the last bow shot, or `bow_round_max` (20 min) has
  passed. The first comes `bow_first` (120 s) after a start; not for a ship on air in the last `bow_recent` (120 s).
- Rank: only at a story turn, so never over an urgent shot, a battle, an incoming group, a follow, a look, a platform
  hold or a segment (those hold the camera and no story turn comes); never during a replay, a trio or a cut being
  framed (plat_busy). A danger or edge shot takes a bow shot over. With one camera the client moves there and back.
- Simulation (`simulate.py --cams onecam --minutes 120 --long-flight`, `--clients 1` for POG_CAMS=1; mock.py
  `mock_long_flight` flies Asterion edge to Aquilo at 1% a minute with the d24 hull): 7 bow shots in 2 hours with three
  clients and with one, most at the 20-minute ceiling (the mock's Luna takes most stories, so a full round is rare).
- Dry run on the live service's snapshot at 15:06 (POG_CAMS=1, Asterion edge to Aquilo 21%, the copy's hull; no
  command sent): `{player 1, position (0, -43.6), zoom 0.53, surface platform-16}`. The operator's manual look for Caleb
  at 14:55 was (0, -40) at zoom 0.45.
- `python3 tools/stream/test_bowcam.py`.
- (d24 batch188 QAD1, viewer Caleb 19:15: "when showing Asterion's bow can you zoom out enough to see the asteroids
  in range?") With the guns read (the platform view's `guns`, model.gun_reach: each turret +- its range), the bow shot
  also fits the reach: the space ahead (`bow_ahead` of the frame) covers the reach's top plus 4 tiles
  (BOW_REACH_MARGIN), the frame its width plus 4 a side, centred on the bow and the reach together; the zoom is the
  smallest of that and the bow's own, at least 0.3, floored to the hundredth. Without guns, as before.
  - World n's Asterion at 19:30 (114 turrets: 23 railguns, range 40; 26 rocket, 36; 20 rare lasers, 28.8; 45 guns, 18
    and 19.8): the reach is x -88.5..88.5, top y -82.5, 32.5 tiles ahead of the bow's edge (y -50); it needs 36.5
    tiles ahead and 185 across. The mock's leg carries guns with that box.
  - On the live layout (layout.json's main crop, view_frac 0.658): before 0.35 (38.9 tiles ahead, 112.8 across),
    now 0.30 (45.3 ahead, 131.6 across): the reach's top is in frame, the outer 23 tiles each side of the railguns'
    reach are not (0.21 would fit them; 0.3 is the floor). With the whole width (view_frac 1, as the batch170 dry run
    had it, and the trio's 0.999): before 0.53 (25.7 ahead, 113 across), now 0.32 (42.5 ahead, 187.5 across: all of
    it).

## Loops, fresh events, base tours, remote vehicles (2026-10-26, d26 batch222 CD)

Viewer Aurora 20:09 (site:4963): "Grok's repeat walking often fills the stream. Could camera priority decay for repeated
loops, favor fresh work/events or a useful overview, and preserve host holds?"; site:4876-4879 (03:42-03:44: fresh
events and visible progress, remote work, quiet-time factory, ship and frontier views, ready frames before cuts, each
camera count); site:4851 (d24 23:34: follow a remotely controlled spidertron by its position). Viewer Caleb d25
09:56-11:02 (site:4914-4915): base tours, a wide slow pan of each planet's base (the operator did Nauvis, Vulcanus,
Gleba and Fulgora by hand with POST /look and a camera move).
- Measured (`tools/stream/airtime.py --log ... --runs ...`): what the program followed (the director log's program
  rows and each client's shots) against each agent's journal: its clock ("character idle Ns of it": idle at 90% or
  more) and its walk loops (a queue_repeat of walks, from its reply to a queue_cancel/queue_clear/queue_repeat, an
  idle queue_status, or a minute of idle clocks). Fresh events: an accepted visible request (build, ghosts, paste,
  deconstruct, mine, launch, a vehicle drive or go_to, fights...) of a kind the agent had not made in 10 minutes;
  the delay is to the program showing that agent (missed after 10 minutes).
- Rules (onecam.py ONECAM, module doc):
  - A short loop: `loop_travel` (120) tiles walked in `loop_window` (180 s) inside `loop_span` (64 tiles), with no
    pieces placed. Its score halves every `loop_half` (60 s), to `loop_floor` (0.1); its walk gets no move_boost; on
    air it is stale like a character standing still (the still rule's reason says "on a loop"). Standing `loop_end`
    (30 s) ends it.
  - Fresh: a kind of action not run in `fresh_window` (10 min), a big action starting, its remote vehicle given a new
    target, or new ground (`fresh_far` 96 tiles from where it stood in the window): x(1 + `fresh_boost`) fading over
    `fresh_s` (120 s). Pieces placed within `progress_s` (20 s): x`progress_boost` (1.3). A fresh agent (within
    `fresh_cut` 120 s, not stale itself) takes the camera after `onair_dwell` at `fresh_ratio` (1.0) of the story's
    score, and from a stale story after `still_min` whatever the scores.
  - Quiet time: the story on air stale `quiet_story` (90 s), nobody fresh or moving, nothing urgent, held, framed or
    fighting: the quiet view shown longest ago of a base tour, a platform visit (`quiet_platform_hold` 25 s) and the
    base map (the last two with a standby only), at most one every `quiet_gap` (150 s); after it the best agent that is
    not stale. Also a tour every `tour_every` (30 min; `tour_first` 15 min after a start) with the base map's guards.
    Host view, operator looks (tour.py and the hourly piece air as looks), follows and platform holds come first; a
    look takes the camera from a tour.
  - Base tours (basetour.py): from the run's chart (runs/RUN/chart/out: the machine labels and index): the densest
    machine (most others within 48 tiles), the machines within 120 tiles of it, their main axis from the 10th to the
    90th percentile (at most 200 tiles), 3 or 4 points each moved half way to the machines near it, west to east, zoom
    0.4, 3.5 tiles a second within 30-50 s, a 2 s rest at each end. Every point's on-air frame is on charted chunks
    (the chart store's, chart.Chart.known; the index's complete cells without a store); a point that is not is left
    out (2 at least). On shift78's chart: Nauvis (-115,-105) to (1,30), 54 s; Vulcanus (-48,158) to (90,112), 45.6 s;
    Gleba (-5,43) to (95,54), Fulgora (-8,199) to (71,188), Aquilo (-12,3) to (42,12), 34 s each; a plan 5-23 ms, kept
    until the chart index changes. On air: "Nauvis base · a slow pan" (the look card), snapshot onair.tour. The move
    goes with the standby's framing (the pan starts its 2 s rest later, about at the cut); one client moves on air.
  - Remote vehicles: work.VehicleFeed reads each agent's `vehicle {remote: true, vehicle}` replies (a spidertron's
    position, speed and route; a drive's "by remote view: tank (x,y)"), live.py passes `remote_vehicle`, and status
    `active.remote` (PLAN_KEYS) gives a drive's position every poll. A read under `vehicle_stale` (30 s; twice that once
    on air) at least `vehicle_near` (24 tiles) from the character: the agent's shot is a fixed view on the vehicle at
    `vehicle_zoom`, led toward its target at its read speed between reads, moved with it (a glide, no cut), labelled
    "Opus · spidertron by remote view" (snapshot onair.vehicle); else the character. A switch between the two is framed
    on a standby and cut to (one client: moved on air). Opus's spidertron in shift77: a read about every 5 s while it
    walked, 40-50 km/h, out to (-1500,225) with the character at the base.
  - One client: an urgent or quiet shot moves the client on air and writes a `move` program row (it wrote none
    before, so airtime.py counted no cut there).
- Replayed (`tools/stream/director_replay.py --log ... --runs ... --chart ... --cams N [--rules main]`): the agents'
  states rebuilt from their journals (positions from status replies and the log's follow results; walk loops walked;
  actions, idle and interest as model.py makes them) and stepped through main's rules and these, measured the same
  way. No alerts, platforms, segments or cues are replayed, so it compares the rules on the same input, not the
  program that aired.
- Today's director as it aired (the d25 logs, 02:07 to d26 00:44, 1347 minutes; shifts 73-78): an idle character or a
  walk loop on air 67.2% of the time (idle 34.9%, loop 32.3%: Grok's ag-watch-walk from 14:38); 30 of 84 fresh events
  never on air; 0.85 cuts a minute. 19:43-21:40 (Aurora's 20:09): 81.5% (loop 76.4%, Grok 88.8 of 116 minutes), 6 of
  8 fresh events missed, 1.02 cuts a minute.
- Replayed, main's rules -> these (3 cameras unless said; idle or loop share on air; fresh events missed, median
  delay to air; cuts a minute):

  | log | idle + loop | loop | fresh missed | median delay | cuts/min |
  |---|---|---|---|---|---|
  | 19:43-21:40 | 81.1% -> 47.0% | 68.7% -> 1.3% | 4 of 8 -> 0 | 41.5 -> 0 s | 0.53 -> 0.72 |
  | the same, 2 cameras | 82.3% -> 49.2% | 70.0% -> 1.3% | 3 -> 0 | 68 -> 0 s | 0.58 -> 0.78 |
  | the same, 1 camera | 81.6% -> 48.3% | 69.9% -> 1.3% | 2 -> 0 | 45.5 -> 0 s | 0.59 -> 0.79 |
  | 14:30-18:35 | 86.5% -> 52.9% | 68.5% -> 0.7% | 8 of 15 -> 0 | 58 -> 6 s | 0.44 -> 0.73 |
  | 06:15-10:18 (all reading) | 76.6% -> 61.4% | 0 -> 0 | 1 of 13 -> 0 | 3.5 -> 8 s | 0.39 -> 0.74 |
  | 21:52-01:46 | 82.6% -> 38.6% | 74.0% -> 0.7% | 2 of 5 -> 0 | 49 -> 45 s | 0.44 -> 0.75 |

  Base tours took 16-21% of the air time in these replays (about 45 tours of each planet over the 14.0 hours); the
  replays have no platforms or base map, which share the quiet rotation live. The rest of the idle share is stories
  of agents reading (the morning's agents made a status, observe or sleep request with the character idle).
- Not done: no frontier views (the edge of the charted ground); tours of platforms are the existing visits.
- `python3 tools/stream/test_freshcam.py`.

## Flare barrages and spider raids (2026-10-26, d26 batch224 AY and VS)

Viewer Aurora, d26 05:29 and 05:31 (site:4974, site:4976): "Could batch222 show remote Spidertron movement/combat and
artillery firing/impacts automatically? Opus's shelling is off-screen. Follow the vehicle or target area while the
action lasts."

What shift79 showed (02:06-03:34; runs/shift79, the director logs 020204 and 022342):
- Opus placed 1016 artillery flares in shift79, in bursts of 40-110 flares over 8-28 s every 3-5 minutes. Each burst
  covered nest clusters 50-500 tiles across, 1000-1460 tiles from 21 turrets that reached them.
- One artillery shot aired, at 02:21:06: an automatic shot at a big worm 627 tiles out. A flare's shell matched no
  target: artycam matched only the spawners and worms in automatic range (627.2 tiles), and its one sighting near the
  piece could not point a shell at a target 1400 tiles out anyway (below).
- The spiders walked by remote at 02:04-02:10, 02:17-02:20 and 02:24, and stood after that. batch222 went live at
  02:23:42 (the merge at 02:23:30 and the service restart): VehicleFeed fed one fresh event because only the 02:24 walk
  came after it. Its 608 rows changed target 352 times (two spiders read in turn), so the reads were neither stale nor
  the same. After 02:25 the raid was artillery only.
- Opus was on air 1.1 of the 88 minutes as aired (airtime.on_air_by).
- 03:56:39-42: keep_vehicle framed Opus's spidertron on cam2, direct() then framed Sol on the same standby, and the cut
  aired Sol with the vehicle's reason.

Game side (artycam.lua; live at a world restart):
- A team flare (artillery.lua's use_item hands it over) is a target: a shell on its path gets the flare's spot, the
  spawner or worm within 6 tiles of it, and who flared it.
- A shell's heading comes from two sightings in consecutive reads. On the private copy, shells started 0.3-2.4 tiles
  off the line from their piece's centre to the target (the muzzle's shift by orientation). The path through two
  sightings passed the flare within 0.2 tiles.
- Shells are looked for only after the surface's artillery shells used (item statistics, 5 us) rise: every loaded
  piece at the 0.2 s pace (a 20-tile find, 0.023 ms a piece), else 4 in turn. A piece seen firing is skipped for its
  200-tick cooldown.
- Automatic targets come from a nest index built one 8x8-chunk box a read (0.39 ms). The old find over a piece's
  627-tile range cost 10.5 ms on the copy once a minute a piece, nothing found.
- Pieces up to 64 (world n has 26 turrets; 16 were watched). `pieces` in the reply is a count unless asked.
- Cost on the copy (world n's 05:42 save; dispatch minus the reply's JSON): 0.49 ms a read with no flare (0.28 of it
  is dispatch itself, 0.24 the read); 0.84 ms median, 4.8 ms max during a 30-flare barrage at 0.2 s. Of 30 flares,
  every shot after the first read was resolved (15 of 15); the first read, long after the previous one, found 3 of 15.

Service (serve.py): the poller follows `every` down to 0.1 s; a flare request in a journal (WorkFeed.flare_at) cuts
its 10 s wait short.

Director (onecam.py; live at a stream-service restart):
- A shell is judged arty_pre (6 s) before it lands; the shot then holds while shells land within arty_near (48
  tiles) of its frame or are flared by the same agent, up to arty_max (90 s, was 20), its frame moved (a glide every
  arty_move 2.5 s at most) to the impacts due next, zoom down to arty_zoom_min (0.45). arty_gap (120 s) counts from the
  shot's end. A shell landing while the shot is still framed on its standby joins it.
- Caption: "💥 Artillery · Opus's flare → big spitter nest (-1392, 48), with 2 medium worm turret · artillery turret
  (-274, -558), 1300 tiles · 12 shells".
- A remote vehicle walking (a read under vehicle_stale with speed, or a target given and not reached at
  vehicle_speed 45 km/h), firing (status vehicle_fire, seated) or within fight_near of a reported fight keeps its
  agent acting (not still, not looping; the fight boost when fighting) and on the vehicle while that lasts, from a
  read up to vehicle_keep (600 s) old. A switch between vehicle and character is cut to as framed, at most every
  vehicle_flip (20 s).
- Priorities are unchanged: looks, platform holds, follows, battles, incoming groups, segments, urgent shots, a fight
  reported anywhere, the trio and replays outrank an artillery shot.

Replayed 02:06-03:34 (director_replay.py --fights, both logs; flares: shells modelled from Opus's flares, each taken by
the in-range piece free soonest 1 s on, then every 3.3 s, landing distance/60 s later; no turret turning). Minutes on
air of 88:

| rules | shells | cameras | Opus | artillery | Grok | Astra | Sol | Muse | Gemini | Haiku | tour | idle+loop | cuts/min |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| main | none (today) | 3 | 10.0 | 0 | 41.6 | 11.3 | 9.2 | 5.1 | 4.4 | 2.9 | 3.5 | 72.1% | 0.60 |
| main | flares (Lua only) | 3 | 15.1 | 5.1 | 38.5 | 10.1 | 8.8 | 7.1 | 3.0 | 1.0 | 3.5 | 67.8% | 0.95 |
| these | none (onecam only) | 3 | 12.1 | 0 | 40.0 | 10.6 | 10.8 | 6.3 | 5.0 | 1.0 | 2.3 | 70.4% | 0.62 |
| these | flares (both) | 3 | 16.6 | 6.4 | 41.0 | 8.4 | 10.0 | 5.3 | 4.5 | 0 | 2.3 | 66.5% | 0.94 |
| main | none | 2 | 9.7 | 0 | 44.6 | 8.6 | 10.7 | 5.4 | 2.0 | 1.0 | 4.4 | 70.8% | 0.65 |
| these | flares | 2 | 16.2 | 7.6 | 39.3 | 8.7 | 10.7 | 5.1 | 3.2 | 1.0 | 2.3 | 65.4% | 1.11 |
| main | none | 1 | 10.0 | 0 | 41.9 | 10.0 | 9.1 | 6.0 | 4.5 | 2.0 | 4.5 | 71.1% | 0.69 |
| these | flares | 1 | 16.6 | 8.0 | 39.4 | 8.5 | 10.7 | 4.9 | 3.1 | 1.0 | 2.3 | 65.2% | 1.12 |

- Opus's minutes include the artillery shots its flares made. 18 barrage shots at 3 cameras, held 10-32 s each (the
  modelled impacts last 15-25 s; live, turret turning spreads them more). Drops: 10 for spacing, 8 in a trio, 2 under
  an urgent shot.
- The replay has no losses, battles, platforms or segments: as aired these took about 20 minutes, and Opus had 1.1.
- Tests: tools/stream/test_raidcam.py, test_artycam.py, vendor/factorio-harness/tests/d17_artycam.lua.

## A remote spidertron framed where it is (2026-10-26, d26 batch232 VC)

Viewer Aurora, d26 09:54 (site:5020): "The site selected Opus at 09:26:50 PDT during recon, but spider 27069154 wasn't
shown. Could batch224 check actual vehicle framing, noncombat motion and the Astra/Opus handoff?"

What aired (shift80; director-20261026-072406.jsonl, Opus's and Astra's journals):
- Spidertron 27069154 is one spider for both agents. Astra sent it at 09:23:26 toward (-410,-400) then (-600,-560); the
  reply had no unit_number (go_to with retreat and targeting) and said the first leg crossed water at (-326.5,-446.5).
  Opus took it at 09:26:23 at (-329.5,-450.3), 192 tiles along: it had stood there. Opus sent it to (-700,-560), its
  scan found it there at 09:27:00.86 (386 tiles in at most 37 s), and back to (-160,-540) at 09:27:03; no read after,
  home by 09:32:09. Its walking reads in shifts 79-80: 46-50 km/h, median 47.5 (12.8-13.9 tiles/s).
- The view: each vehicle reframe glided at d/1.5 tiles/s, d from the last spot sent a second earlier: 9-10 tiles/s
  behind a spider walking 13, and the lead ran at 45 km/h from the replies alone. Simulating the client as cameras.lua
  moves it (at most `speed` tiles/s, a teleport only past 200 tiles) against the spider's path at 12.8-13.9 tiles/s:
  the frame started 30-58 tiles behind at 09:26:50, held it from about 09:26:55 to 09:27:08 (arrived and turned), and
  fell back from there: 44-56 tiles at 09:27:15, 133-146 at 09:27:45. In frame 13.5-15 s of 09:26:50-09:27:50 (frame
  half 26.8 x 15.1 tiles at zoom 1.12); vehicle_framing over the whole Opus shot (09:26:50-09:28:06): 22 of 75.5 s. Astra's shot (09:23:10-43) was led on at 45 km/h past where the spider stood.

The change (host only, live at a stream-service restart):
- The service reads the agents' remote vehicles by unit number every poll (harness.py VEHICLES_LUA, a raw Lua read like
  the platform reads: position, speed, next autopilot target, health; 5.4 us a spidertron on world n, 0.3 us a unit
  gone). work.VehicleFeed merges it: position and speed from the read (`live`), `seen_t` the agent's own last call.
- A unit belongs to the agent who called it last: an older row of another agent for it is dropped (Astra's shot goes
  back to her character when Opus takes the spider). A reply with no unit_number takes the request's `vehicle`.
- keep_vehicle aims vehicle_ahead (1 s) on and glides at d/1 tiles/s, at least vehicle_glide (1.2) x the vehicle's
  speed. vehicle_speed (the lead without a live read) 47.5 km/h (was 45). A switch between vehicle and character keeps
  the story's on-air start (it reset the 90 s dwell before).
- Staleness counts from the agent's own call: a spider standing with live reads is shown vehicle_stale (30 s) after
  the call, or while it walks, fights or fires (batch224); the live read alone does not hold the shot.
- Slot rows in the director log name the shot's vehicle (target.vehicle).
- Also fixed (batch224): the barrage frame's glide is a speed, d/1.5 tiles/s and at least 2 (it was 0.5-2).

Replayed 09:20-09:30 (director_replay.py --fights; --vehicles live models the reads from every vehicle reply in the
journals, walking each route at 47.5 km/h and never past where the next reply found it; vehicle_framing simulates the
on-air client against that path):

| rules | positions | cameras | spider shots on air | spider in frame |
|---|---|---|---|---|
| as aired | replies | 3 | 108 s | 42 s (Astra 20 of 32.5, Opus 22 of 75.5) |
| main | replies | 3 | 148 s | 46.5 s (Astra 32 of 71, Opus 14.5 of 77) |
| this | replies | 3 | 148 s | 112.5 s (Astra 35.5 of 70, Opus 77 of 78) |
| this | live read | 3 | 237 s | 236 s (Astra 63 of 63, Opus 173 of 174) |
| main | replies | 2 | 148 s | 46.5 s |
| this | live read | 2 | 148 s | 147 s |
| this | live read | 1 | 148 s | 148 s |

- The live rows in the replay come from the same path the metric checks, so "in frame" with them says the view keeps
  up with where the read says the spider is, not that the model is right. The model's legs: Astra's 192 tiles then
  standing (as Opus's reply found it), Opus's out and back straight at 47.5 km/h.
- Main's 1-camera replay log names no vehicle in its rows, so vehicle_framing cannot score it.
- Tests: tools/stream/test_vehcam.py (fails on main's onecam: 8 of 79 s in frame with the same live reads).

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

### Backlog lines after a restart are history (d22 batch111 BU1)

Nick: a Sol line "keeps coming back onto the stream at weird random times throughout the past few days". It was Sol's
confessional seq 67 (game tick 10291268), voiced 11 times in runs/shift52..60/caster.log, each about 20 s after a
caster start and right after Astra's seq 65 (tick 8953890, "The biggest lesson today is that an idle machine is often
a delivery problem..."). live.py reads `confessions`, `tells` and `board_events` from 0 after a restart (and
`operator_requests` from the inbox file's last seq); the first reads return the runtime's kept lines (the newest 30
confessionals, seqs 46-75 on world n, the newest at tick 16.3M), and model.py stamped each with now, so the caster took
them as new ("chat_decision ... voiced: true, label reaction", caster-20261022-210720.jsonl).

- model.py `backlog_old`: until a feed's first empty read, a line of it older than HISTORY_S (60 game seconds) by tick
  keeps its own time (`tick_time`: the game ticks since it before the tick read now, a lower bound across a shift
  break) and gets `history: true`, as restored chat already did (`_ingest_chat`, `chat_time`). It adds no interest
  for the director. Confessionals, tells, operator requests (and the snapshot's `operator_requests` rows) and board
  events (replayed 100 a read) follow it.
- caster.py's Differ skips `history` chat lines and board events outright (their old `t` already kept them out of
  its 30/60/120 s windows). The site and the overlay sort and mark them by their own time.
- Test: tools/stream/test_backlog.py. Deploy: a stream service restart.
