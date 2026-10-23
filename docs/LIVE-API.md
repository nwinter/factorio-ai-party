# Live API: stream state and viewer chat

Branch `site`. The contract between the companion site's live page, the Mac (which pushes stream state), and
eng/viewers (which reads viewer chat). Code: `site/worker/worker.js` (Cloudflare Worker + one Durable Object),
`site/push_live.py` (the Mac-side pusher), `site/static/live.js` (the page).

Base URL: `https://player-of-games-live.your-subdomain.workers.dev` (also `live_api_url` in `site/config.json`).
Everything is JSON, UTF-8. Every response carries `X-Robots-Tag: noindex, nofollow`; `/robots.txt` disallows all.

## For eng/viewers: reading viewer chat

Poll `GET /v1/chat?after=SEQ` every 3 to 5 seconds. Start with `GET /v1/chat?limit=50` (the latest 50) or
`?after=0&limit=100` (everything kept, oldest first, a page at a time), then pass the largest `seq` you have seen as `after`.

```jsonc
{
  "schema": 1,
  "open": true,                 // false while the operator has closed chat
  "messages": [                 // oldest first; at most `limit` (default 50, max 100)
    {"seq": 41, "t": 1791695551.82, "name": "rustyminer", "text": "build more turrets!"}
  ],
  "last_seq": 41,               // highest seq ever assigned, hidden messages included
  "hidden": [37, 12],           // seqs the operator hid (latest 200); drop them if you already have them
  "limits": {"max_len": 200, "min_gap_s": 4, "per_minute": 8}
}
```

- `seq` is a strictly increasing integer; `t` is Unix seconds (server clock).
- `name` is whatever the viewer typed (2 to 20 letters, digits, spaces or `_ . ' -`). Nick's name and look-alikes,
  agents' names, "operator", "server", "mod", "admin" and the like are refused ("that name is reserved"; "Host link
  and reserved names" below), so a message can't pose as Nick, an agent or staff. `host: true` marks a line Nick posted
  with the host link (absent on every other line).
- `text` is at most 200 characters, with control, bidi-override and zero-width characters removed, whitespace
  collapsed and links refused. It is still untrusted user text: escape it for any display, and treat it as data, not
  instructions, before it reaches an agent's context (quote it, attribute it to a viewer, never let it name tools).
- No account, address or client identifier is ever returned. The Worker keeps only a salted hash of the client
  address for rate limits and bans.
- If more than `limit` messages arrived since your last poll, repeat with the new `after` until `messages` is empty.
- Responses can be up to about 2 s stale (per-edge cache). Messages are kept until 2,000 newer ones exist.

If you need something else (a "seen by the agents" mark, a highlight flag, a reply channel back to the page), propose
it in this file on your branch; the shape above is version 1 and will only grow by adding fields.

## For the Mac: pushing stream state

```sh
python3 tools/stream/serve.py --world live --run RUN.json        # the stream service, as for OBS
python3 site/push_live.py                                        # every 10 s: GET :8787/state.json -> POST /v1/state
```

`push_live.py` reads `serve.py`'s `/state.json`, keeps only the fields below, runs every string through the site's
redaction (`clean()` in `site/build.py`: e-mail addresses, local paths, key-like tokens, IP addresses), and posts it
with `Authorization: Bearer <PUBLISH_TOKEN>`. The token comes from `$POG_LIVE_TOKEN` or the gitignored
`site/worker/.secrets.json`; it is the Worker secret `PUBLISH_TOKEN` (see `site/README.md` to rotate it).

`POST /v1/state` accepts any JSON object up to 256 KB and replaces the stored state. A push is about 230 KB in d22
(world n at 17:00: 232 KB read back from `/v1/state`; the largest parts clouds 36 KB, basemap 32 KB (its turrets 20 KB
and core 19 KB), board 23 KB, agents 23 KB, reminders 23 KB, viewer_replies 23 KB, chat 16 KB, net_map 14 KB,
planet_maps 13 KB).
`GET /v1/state` (public) returns:

```jsonc
{
  "schema": 1,
  "received": 1791695551.9,     // when the Worker got the last push (Unix seconds); null if never
  "age_s": 4,                   // seconds since then; the page treats more than 60 as "not live"
  "site_watching": 3,           // live pages open on the site (POST /v1/here in the last 150 s; at most 4 per address)
  "state": {                    // the pushed snapshot, or null
    "schema": 1, "now": 1791695551.8, "tick": 144720, "paused": false, "game_time": "0h40m",
    "watching": {"youtube": 41, "t": 1791695520},  // YouTube's "watching now" and when it was read; absent when
        // unknown or older than 3 min (viewers.py poll_watching, once a minute)
    "title": "Nine AIs, one factory", "subtitle": "...",
    "agents": [{"name": "astra", "display_name": "Astra", "color": "#7c5cff", "glyph": "✦", "motto": "...",
                "avatar": {"base": "robot"}, "model": "GPT-6 Astra", "harness": "Codex", "role": "...",
                "alive": true, "activity": "acting|thinking|idle|dead|offline", "action": "...",
                "active": "construct", "position": {"x": -64.8, "y": -23.6}, "location": "iron smelting",
                "last_said": {"text": "...", "tick": 144700}, "camera": "main|cam2|cam3|null", "combat": false,
                "died_at": null, "kind": "bot", "profile_set": true,
                "wait_line": "waiting: crafting done, ~2 min (idle 5 min)", "wait_reason": "I'm waiting for the gears.",
                    // null when no fresh current wait; reason: own explicit chat/aloud statement, at most 5 min old
                "job": "nuclear power plant: reactor", "job_from": "plan|notes",  // its team-plan line, else its
                    // notes.md "## Now" (null: neither); the live page's portrait tip shows it
                    // (viewer syndesis 22:13: hover or tap a portrait for its plan line and job)
                // what it carries, wears and builds (the harness's loadout read; absent while dead or before the read)
                "loadout": {"health": {"now": 250, "max": 350}, "vehicle": null, "selected_gun": 1,
                            "guns": [{"name": "submachine-gun", "count": 1}, false], "ammo": [{"name": "piercing-rounds-magazine", "count": 187}, false],
                            "armor": {"name": "power-armor-mk2", "equipment": [{"name": "energy-shield-equipment", "count": 2}],
                                      "shield": {"now": 37, "max": 150}},
                            "items": [{"name": "copper-cable", "count": 1200}], "item_kinds": 14, "slots": {"free": 12, "total": 90},
                            "crafting": {"queue": [{"recipe": "inserter", "count": 5}], "items": 5, "progress": 0.46},
                            "building": {"kind": "construct", "done": 7, "total": 20}, "age_s": 3.2}}],
    "chat": [{"seq": 1, "tick": 144720, "from": "Muse", "agent": "muse", "text": "...", "t": 1791695551.8}],  // last 40
    "research": {"current": "engine", "label": "Engine", "progress": 0.54, "done_count": 8,
                 "recent": [{"name": "steel-processing", "label": "Steel processing", "t": null}],
                 // (d20 batch57 S4, viewer Foobator) each infinite technology researched at least once (or being
                 // researched), the highest level first, at most 24: level is the last level done, next the level the
                 // tech tree shows; the one being researched has researching and progress
                 "repeating": [{"name": "mining-productivity-3", "label": "Mining productivity", "level": 14, "next": 15},
                               {"name": "rocket-fuel-productivity", "label": "Rocket fuel productivity", "level": 10,
                                "next": 11, "researching": true, "progress": 0.052}]},
    "production": [{"item": "iron-plate", "total": 4562, "rate": 239.8, "series": [/* per minute, last 30 */]}],
    "science": {"spm": 10.0, "series": [/* per minute */], "stage": 2, "stage_label": "Steel & logistics",
                "packs": [{"item": "automation-science-pack", "rate": 0.0, "total": 277}]},
    "alerts": [{"kind": "attack|death|low_power|research", "text": "...", "agent": "grok", "position": {"x": 0, "y": 0}}],
    // the run's chronicle (fh chronicle; viewers Alex and syndesis 22:24), newest last: the agents' entries (at most 8)
    // and the events the harness saw (at most 12; the live page shows platforms built, lost and deleted, rockets and
    // deaths); the whole run by shift is the site's /chronicle/ page (runs/RUN/chronicle.jsonl)
    "chronicle": {"entries": [{"seq": 7, "tick": 229420, "game_time": "1h03m", "agent": "sol", "name": "sol", "title": "Oil at last",
                               "text": "...", "where": "nauvis", "about": ["research finished: oil-processing"], "t": 1791695850.0}],
                  "events": [{"id": 12, "kind": "platform_lost", "tick": 230620, "game_time": "1h04m", "platform": "Starling",
                              "where": "flying nauvis->vulcanus 40%", "by": "medium-metallic-asteroid",
                              "hit_by": [{"name": "medium-metallic-asteroid", "count": 40}],
                              "cargo": [{"name": "iron-plate", "count": 450}], "cargo_items": 470, "line": "...", "t": 1791695870.0}]},
    "board": {"available": true, "open_unowned": 1, "in_progress": 2, "claims": [...], "events": [...],
              "projects": [{"id": 4, "title": "Nuclear power plant", "owner": "opus", "agent": "opus", "status": "claimed",
                            "progress": "3 of 6 steps", "done": 3, "total": 6,
                            "next": "Reactor and heat exchangers", "goal": "40 MW"}],   // open, latest changed first; at
                            // most 4; next: its first step not done (null: none), goal (null: none). When present
                            // (d15, viewer Foobator 08:31): steps [{n, text, done, by?, ago?, next?}] (all of them once
                            // the stream service read the project in full, board {id}, again only when it changed;
                            // steps_partial: only a list read's next open steps so far; steps_cut: push_live trimmed
                            // them to keep the board under 48 KB), needs {item: count}, handoff, requested_by (not
                            // the owner). projects_more: the open projects after the first 4 (up to 26 more);
                            // projects_done: the last 10 finished. The live page opens each project to its steps and
                            // shows projects_more and projects_done behind "Show all N projects" (kept per browser).
              "projects_total": 1,    // a project event row also has progress, steps_done, steps_total (verb step: step)
              // the jobs behind the counts (d15, viewer joonazan 08:19), from an active read of tasks and requests,
              // newest change first, 20 each; absent before such a read: open tasks/requests nobody owns, and those
              // claimed or being done; each {id, title, kind, owner, agent, status, requested_by}
              "open_items": [...], "open_items_total": 3, "doing_items": [...], "doing_items_total": 2,
              // the team plan (the harness's board_plan; the live page's Team plan; viewer Alex 22:12), null when it has
              // neither goals nor lines. Ticks are game ticks (60 a second): the page says "set N min ago" from the
              // state's tick. A line's tick and by, and goals_tick and updated_tick, come from runtimes with the board
              // read's plan_ticks; by: who set the line when not the agent itself.
              "plan": {"goals": "Blue science at 60/min, then the silo", "goals_tick": 220420,
                       "doing": [{"agent": "sol", "name": "sol", "text": "blue circuits at (40,-20)", "tick": 209620, "by": "astra"}],
                       "edited": "by astra, 6m ago", "updated_tick": 209620}},
    "basemap": {"tick": 230400, "cell": 4, "x0": -112, "y0": -72, "w": 56, "h": 41, "buildings": 659,
                "rows": ["..DDDDDD", "....S.BB"],   // one string per cell row from y0; one letter per cell from x0
                "nests": [[150, 40, "s"], [140, 30, "w"]],  // enemy spawners (s) and worms (w) near the base
                "turrets": [[12, -40, 18], [30, -40, 30]],  // ours: x, y, range in tiles (no artillery); at most 600
                "terrain": [{"src": "/live/terrain/a.webp", "x0": -320, "y0": -200, "x1": -64, "y1": -56,
                             "tick": 230000, "w": 1280, "h": 720}]},  // optional: map-camera frames, edges in tiles
    "cameras": {"main": {"agents": ["sol"], "pair": false, "since": 1791695548.8,
                         "attack": "Base under attack near (-48, 16): gun turret"},   // optional: a fight shot
                "cam3": {"agents": ["sol"], "pair": false, "since": 1791695548.8,
                         "work": "Sol building on Solstice (from the ground)"}},     // optional: work / segment shot
    "space": {"rockets": 3, "planets": ["Nauvis"], "summary": "1 platform · 3 rockets",   // only once Space Age shows
              "platforms": [{"name": "Solstice", "where": "Nauvis → Vulcanus", "state": "on_the_path", "speed_kms": 72,
                             "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42}, "paused": false},
                            {"name": "Dock", "where": "Gleba", "state": "waiting_at_station", "paused": false,
                             "waited_s": 725, "waited_more": true}]},  // every platform
    "fights": [{"kind": "attack|loss", "text": "...", "position": {"x": -48.0, "y": 16.0}, "extent": 32.0,
                "age_s": 6, "losses": 1}],  // reported in the last 2 minutes, on Nauvis; at most 12
    "shift": {"start": 1791733620, "end": 1791748020, "next": 1791748020, "next_exact": false}  // Unix seconds;
        // start-team.sh (tools/shift_times.py): the next is expected at this one's end unless POG_NEXT_SHIFT sets it
        // ("02:47", an ISO time, or "none" -> null); the page says when this shift ends, or when to come back
  }
}
```

`POST /v1/here` (public, from the site's origins or without an Origin) takes `{"id": "<16-32 hex digits>"}`: the live
page makes one random id per page load (never stored) and posts it on load and once a minute, as `text/plain` so the
browser sends no preflight. The Worker keeps ids in memory only (a restart counts again within a minute). The page
shows `Watching: 41 YouTube · 3 site` beside the Live badge, each part only when known, nothing while offline.

The map is `static/mapview.js` (the run page's time-lapse uses it too): one canvas with pan (drag), zoom (wheel,
pinch, + and −), Reset, Full screen, layers to toggle (terrain, ore, pollution, buildings, turret range, turret state, nests, agents,
attention, fights; turret range starts off; the choice is kept per browser), and a click or tap on an agent to centre on it and
follow it; hover or tap names a mark. `basemap.turrets` draws the turret-range layer (the union of every turret's reach).
`basemap.turret_state` (d20 batch50 G1, viewer Aurora; tools/stream/turretstate.py) draws the "Turret state" layer (on
by default): `{as_of, every_s, counts {armed, empty, no_power, unknown}, flagged [[x, y, state, name, age_s]], more?}`,
a marker at each turret that is empty (`e`: no ammo, shells or fluid; red), without power (`p`: a laser or tesla turret
under one shot's energy; amber) or unknown (`u`: not read since the last full pass, or never; a grey ring), at most 500
(`more` counts the rest); the tip says the turret, its state and how long ago it was read, the legend the counts. The
stream service reads every Nauvis turret in the basemap's defence cells, a pass at most once a minute, one command an
observe of at most 120 turrets (2.4 ms on world n, 7.0 ms on the d17 headless copy). `basemap.terrain` the terrain layer: each frame's image stretched over its tile edges (`x0`, `y0` the image's top
left, `x1`, `y1` its bottom right), older frames first, under everything else; `src` must be a site path or an https URL.
(d22 batch75 AK9, viewer Aurora site:4272: "Terrain is blank north of the base where Opus explored. Please trace charting,
capture and publishing, then make newly charted areas appear automatically with visible terrain freshness.") The frames
are OBS screenshots of the director's base map shot, framed on the core and its outposts and placed by matching our
buildings; every shift58 frame spans y -580 to 546, while the force has charted Nauvis north to y -1024 (Opus worked at
y -790 to -990), and a frame reaches the map only with a site deploy. So `basemap.terrain_grid` carries the charted
ground read from the game (tools/stream/terrain_grid.py; a read every 30 s, about 3 ms on world n): {cell 8, x0, y0, w,
h, rows (run-length packed as the other grids; a letter a cell: the tile at the cell's centre, "c" a cell with a cliff,
"." not read), palette [[letter, "#rrggbb" (the tile's map colour), tile name]], chunks, tick (the newest sample's),
oldest_tick, t (the newest read's wall time), age_s}. A chunk charted next to the known ground is in it within about 3
minutes; the stream keeps it in runs/RUN/terrain-grid.json (read back from the run it resumed from); push_live drops it
past 96 KB packed (3247 chunks of world n: 21.6 KB). The map draws it under the frames (a frame's uncharted part is
transparent) and dims both once; the legend says how many chunks and when the newest was read; a frame 30 min or more
older than now is labelled at its corner ("terrain from 2 h ago", the newest of frames whose corners are within 60 px)
and the scale line says the frames' and the ground's ages.
(d22 batch75 AK10, viewer Aurora site:4283: "Could disabled map layers distinguish missing data from a real zero? Vulcanus
currently labels unavailable power and logistics overlays as 'none', which is easy to misread.") A disabled layer's
tooltip says why (mapview.js absentWhy): "not read: ..." where the state has no read of it (the game has made no networks
map of Vulcanus, naming the planets that have one; no map of the planet; a layer read on Nauvis only; pollution, read on
the surfaces an agent is on), "not read yet: ..." where the state lists one this page has not had, and "none: ..." only
where a read says zero (a networks map with no electric or logistic network or no item, a planet map with no building,
the base read with no turret, spawner or worm, library areas read with none on the planet, no agent or attention mark
there now). The item picker's tooltip says the same.

(d22 batch75 AK11, viewer Foobator site:4284: "can projects that are actively being worked on and blocked projects be
easier to see on site? also, could you show blocker reason?") Each `board.projects` row carries, as the board holds it
(tools/stream/model.py project_state): `state` "active" (status doing, or an agent's board focus on it) or "blocked"
(status blocked, or an open item in its blocked_by); `focus` [{agent, step, blocker}]; `blocked_by` [{id, title, status,
owner}] (the open ones; an id alone for one the read lacks); `note` {by, text, tick} (its newest, when blocked); `check`
{state, stalled, unchanged_checks, checked_s, last_change_s, error} (progress.lua's last check: the stream reads
board_progress with no arguments every 2 minutes, 5.7 ms on world n). Those worked on come first, then the blocked
ones; the card shows every one of them (up to 8). The live page puts the status in a chip (doing green, blocked red), a
focus chip, and under each title the open blockers, a focus's blocker, the newest note (with its game age) and the
progress check; the shift pages' team plan (plan.json) shows the chip, the open blockers and the newest note.
The map is Nauvis: an agent whose `surface` is another planet, or with `on_platform` or `travel` set (a cargo pod), is
listed in its bottom-left corner instead ("Luna · Vulcanus", "Opus · Solstice (platform)") and takes no part in
the framing; each agent row carries `surface`, `where`, `on_platform` and `travel` from the stream service for that.
It draws `fights` as rings the size of their `extent` (solid while `age_s` is under 25,
faded after, a cross where `losses` happened), tags each agent a camera follows with its slot, lists what each camera
shows (`cameras`: its agents, or the `attack`, `work` or `segment` shot), shows the research in progress over the
map, and `space` as an inset under it. `space`, `fights` and the camera labels add a few hundred bytes to a push.
(d22 batch97 BG3) `threats` {incoming, big} draws the "Attacks" layer (on by default, under Combat) on the surface shown:
`incoming` the enemy groups on their way (harness `attack_groups_live`, read every 2 s while any, else 10 s)
`[{id, surface, position, target, size, kinds, state, target_distance, visible, age_s (since first seen), label}]`, a
diamond with a dashed line to its target; `big` the demolishers near our buildings or agents (`big_enemies_live`)
`[{id, name, surface, position, nearest {x, y, name}, speed, closing, nearest_distance, eta_s, label}]`, a ringed dot
with a dashed line to our nearest building while it closes; at most 12 of each, absent when there are none (about
300 bytes a row). The stream service read both before; they never reached the page.
(d22 batch75 AK2, viewer Foobator, site:4034: "the ship overview only has a progress bar for the first 2 that are in
transit? can in transit be listed first and the rest have their planetary waiting time displayed?") Every platform's
`state`, `route` and `speed_kms` come from the stream's views read (`PLATFORM_LUA`, every platform in one call every
15 s); before, only the first 4 platforms' detail reads had them and the rest said "in transit" without a route.
`waited_s` is the game seconds a platform has been at the planet it is at (the stream service's first read there; kept
in `space-memory.json` across restarts and from the run resumed); `waited_more` means it was there before the service
first read it, so at least that long. The inset lists the platforms in transit first, each with its progress bar, then
the rest in the stream's order with "waiting 12 min" ("12+ min" with `waited_more`).

`basemap` is the base as a coarse grid, read once a minute by the stream service (`BASEMAP_LUA` in
`tools/stream/harness.py`, an operator read like the score): every building of ours on nauvis except electric poles,
binned into `cell`-tile cells (4, doubled until the grid fits 128 cells a side), each cell labelled by its most telling
building: `D` defence (turrets), `W` walls and gates (d22 batch75 AK4, viewer Foobator: "can walls be a separate
item?"; under `D` where both share a cell, so the turret sweep's defence cells still hold every turret; grids read before
it have walls in `D`), `R` labs, `O` oil and chemistry (refineries, chemical plants,
pumpjacks), `A` assembly (assemblers, the silo), `S` smelting, `M` mining (drills, offshore pumps, agricultural
towers), `E` power (boilers, generators, solar, accumulators, reactors, fusion, lightning attractors and, d22 batch97 BG3,
heat pipes), `L` logistics and storage (chests, roboports, train stops, the cargo landing pad), `I` inserters, `B` belts
(undergrounds, splitters, loaders), `T` rails and signals, `P` pipes, pumps and tanks, `.` nothing; most telling first in
that order (census.lua RANK). (BG3) The legend's `K` storage was never emitted (storage is in `L`) and is gone. Cell (c, r) covers tiles `x0 + c*cell` to
`x0 + (c+1)*cell` and the same for y. Trailing empty cells are left off each row. It is absent until the first read.
`basemap.ore` (read every 5 minutes, the last one kept between reads) is a second grid with its own `cell`, `x0`,
`y0`, `w`, `rows` and (BG3) `tick`, the start of the census pass that read it (the census served a grid only within
19,800 ticks of that start while a pass takes 35-41k on world n, so the map had no ore; it serves its last one now), covering the base plus 64 tiles: one letter per cell for its commonest resource, `i` iron ore,
`c` copper ore, `k` coal, `s` stone, `o` crude oil, `u` uranium ore, `x` anything else. The page draws it faintly
under the buildings. With a base, the page frames the base and pins an agent more than a base-width away to the
map's edge (dashed, its distance in the tooltip).

(d22 batch97 BG3) **The chart.** The stream service draws every planet and platform from the game
(tools/stream/chart.py, the harness's `chart` operator read): 384-tile cells at 1 px a tile in the game's own map
colours (tiles; resources, trees, rocks and cliffs; then every building at its footprint, turned by its direction;
rails as curves), with recipes and train stop names as text (no game icons or sprites), kept in runs/RUN/chart/out/.
site/build.py publishes them with the site (tools/site-refresh.sh, hourly from tools/start-team.sh and at each shift
change, so a cell is at most about an hour older than the stream's copy) under `/live/chart/`:
`index.json` `{v, cell: 384, tick, surfaces: {name: {platform, cells: {"cx,cy": [version, oldest read tick, newest read
tick, chunks, x0, y0, x1, y1]}, chunks: [stored, charted], complete}}}` (the last four: the box round our buildings in
the cell, absent without any; `complete`: the surface's first pass is done, every charted chunk read and drawn, kept
from then on),
`SURFACE/CX_CY.png` (pixel (0,0) is tile (cx*384, cy*384)) and `SURFACE/CX_CY.labels.json` `{recipes: [[x, y, recipe]],
stops: [[x, y, name]]}` (tiles). push_live reads the deployed index every 5 minutes and sends `chart {v, tick,
surfaces, complete, saved}`; the page fetches `index.json?v=` when `v` changes and each cell as `CX_CY.png?v=version`. Once a
surface's published chart is `complete` (cp7, viewer Aurora 21:36: a first publish of six cells hid Nauvis's terrain
and buildings elsewhere) push_live leaves out what it replaces (`saved`: the bytes): on a complete Nauvis the basemap's `rows`,
`core`, `ore`, `terrain_grid` and `terrain` (it sends `core_box [x0, y0, x1, y1]`, the dense core's box, for the
framing; nests, turrets and turret states stay), and a complete planet's `planet_map` and `planet_maps` entry (`planets`
stays). On world n's state at 17:00 that is 18 KB with Nauvis, Vulcanus and a platform charted, 27 KB with every
planet; the terrain grid (up to 96 KB) goes too once it is live. With every grid kept the state was 238.0 KB at
21:45 (51 KB less with every planet complete).
The map draws the chart as its base layer ("Chart", on by default, first in the Terrain group): each cell in view,
nearest-neighbour from 1 px a tile up (smoothed when zoomed further out), over the coarse grid, ore, charted ground
and terrain frames the state carries: a chunk not read yet is transparent in its cell, so they show there and where
no cell is published. Train stop names show from 0.5 px a tile and recipes from 6 px (a 3-tile machine is 18 px),
as text, rich text tags as words, each left out where it would overlap one shown before it (stops first). Hover on a
cell says when its chunks were read ("Chart cell (0, -1), 144 chunks, read 3 to 41 min ago", from the state's tick);
the legend and the scale line say the oldest and newest cell. Every surface in the index gets a switch: planets as
buttons, platforms by their own names in a "Platform…" picker, each framed on its buildings' boxes. The overlays
(pollution, power, logistics, turret range and state, nests, attacks, fights, agents, attention, blueprints) draw on
top with their own toggles and ages as before.

`planets` and `planet_map` are the other planets we have built on (viewers craigNZ830 and Foobator, d15 07:05: the map
showed Nauvis only). `planets` lists them all, `[{surface, tick, buildings}]`. `planet_map` is one of them in turn
each push (`{surface, tick, cell, x0, y0, w, h, rows, buildings}`, the same letters as `basemap`, cell 4 doubled until
the planet's buildings fit 128 cells a side), so a push carries one planet's grid (at most about 17 KB); the page
keeps the ones it has seen. (d20 batch50 D1, viewer Aurora) A planet seen once keeps its tab and its last map, also
when a push or the census read leaves it out (the stream service keeps the last map too); a map 10 game minutes or
older says its age on its tab ("Gleba · 12 min old") and under the map ("map from 12 min ago", from the state's
`tick`); the planet shown and the view (pan, zoom) stay across updates. They come from the harness census's last
pass (`census {part: "planets"}` and `census {part: "basemap", surface}`, operator reads that answer from storage),
one planet a minute in the stream service. The map card shows a tab per planet beside Nauvis; on a planet's tab its
buildings are drawn, with the agents on it (the rest listed in the corner); no ore, terrain, nests or turret range
there.

`basemap.core` is the base's dense core: the box round its densest 32-tile blocks (8 tiles beyond them), each building's
footprint at `cell` 1, 2 or 4 tiles (doubled until the box fits 160 cells a side), the same letters; the page draws it
over the coarse grid inside its box, and zooming in shows each building. (d21 batch68 AD1, viewer Aurora: "Could Aquilo
get a detailed base map using the Nauvis approach, with building footprints, coordinates and data age?") A
`planet_map` carries its planet's `core` the same way, made by the same census pass (`census {part: "basemap",
surface}`); push_live sends it at twice the cell until its packed form fits 12 KB (each new cell the most telling of
the four). Every surface's scale line gives its map's age (`map from 2 min ago`: Nauvis's basemap read, a planet's
last census map), and the pointer's tile coordinates show in the corner on every surface.

`library_areas` (d21 batch68 AD2, viewer Aurora: "could installed blueprint areas show tested revision, required hookups
and last check, with failed or unverified hookups on every planet's map?") is the team library's placements the harness
remembers (a `blueprint_place {name}` paste: the last 4 of a name, 32 names; checks.lua), read once a minute by the
stream service (operator read `library_areas`, libareas.lua): `{tick, age_s, placements, areas, left_out?}`, newest
first, one per name and spot, at most 48 from the read and 16 KB in a push (the oldest left out). An area: `name`,
`surface`, `box` [l, t, r, b] (the paste's first 400 entities' extent), `tick` placed, `by`, `entities`, `description`
(its first 80 characters), `saved_tick` (the entry's save now) and `placed_save` (the save that was placed; pastes
before d21 batch68 have none), `deleted` (no entry of that name now), `retired` {by, reason, replaced_by, tick},
`check` {id, name, state (pass, fail, stale or not run), tick} (the newest blueprint check over it), and `hookups`
as the world shows them at the area's edge, read two areas a read (the ones read longest ago first) and kept with
their tick `t`: `b` belts [in joined, in open, out joined, out open] (a belt whose next tile is outside: fed from or
into a belt there, or not), `p` fluid connections to a tile outside [joined, open], `i` inserters reaching outside
[in joined, in open, out joined, out open], `e` power [poles, wires to poles outside, machines with no power, on low
power], `g` ghosts, `n` built, `open` the first 4 open ones `[x, y, what]`; or `capped` (over 1500 of ours in the area),
`too_big`, `error`. The map's Blueprints layer draws each area on its surface: red with an open hookup or a failed
check, dashed orange when not verified (no passing check, or hookups not read), green when its check passed and every
hookup is joined; hover gives the facts in words. On the d17 copy: a read 2.5-3.7 ms in the game with no hookups,
+0.1-0.5 ms an area's hookups (a 64x19 area of 448 belts included).

`net_maps` and `net_map` (d21 batch68 AD3, viewer Aurora 13:03: "Could maps show logistic/power network IDs and
coverage, plus a selected item's source-to-consumer blockers?"): `net_maps` lists every planet's networks map
`[{surface, tick}]` and `net_map` is one of them in full each push, in turn (the page keeps each planet's last). The
runtime makes one a planet a minute in the background from the census pass's lists (operator read `net_map {surface}`,
netmap.lua); the stream service reads the planet whose map changed, one read every 20 s. A map: `electric` {`nets`
"id,letter,poles;..." (the 52 networks with the most poles, most first), `more`/`more_poles` (the others, drawn `*`),
`poles`, a grid `cell, x0, y0, w, h, rows` (rle 1) where a cell carries the letter of the network one of whose poles'
supply area covers some of it (the bigger network where two do), `cell_from` when push_live sent it at a coarser cell
to fit 6 KB, `outside` (poles beyond the grid)}; `logistic` [{`id` (0: roboports in no logistic network), `lr`, `cr`
(the radius of its first roboport's logistic and construction areas, squares round the roboport), `n`, `ports` "x,y;...",
`odd` "x,y,lr,cr;..." (other radii), `robots` "logistic,idle,construction,idle"}]; `items` [[name, sources, consumers]],
each a string of groups "kind,network,count,amount,unpowered,x0,y0,x1,y1[,x,y]..." joined by `;` (a group of one:
"kind,network,1,amount,unpowered,x,y"): by kind (A crafter, M drill, R lab, P provider chest, S storage, B buffer, Q
requester, L cargo landing pad, T machines' trash slots) and by the logistic network at the members' spot (0: none);
amount is the count held (sources) or asked (requests); unpowered counts members with an electric energy source on no
electric network; `positions` (how many positions a group kept: 4, else 1 or 0 to fit) and `left_out` (items not sent,
those no consumer takes first), `research` (the force's research the labs count for), within 20 KB a push. Sources:
crafters whose recipe (a furnace's last) makes it, drills mining it, chests and landing pads holding it, trash slots
holding it; consumers: crafters whose recipe takes it, labs (the research's packs), requester and buffer requests. The
map's Power networks and Logistic networks layers (off at first) colour each network, hover names the networks under
the pointer, and the item picker shows the item's groups (sources green, consumers blue) with a red ring where a group
is outside every logistic network, its network holds no source (a consumer) or no consumer (a source) of it, or members
are on no electric network. On the d17 copy: a map 3.2-19.6 KB in a push (Nauvis 19.6 KB with one position a group),
a read 0.9-1.7 ms in the game.

(d22 batch75 AK1, viewer Aurora, site:4011: "Planet buttons and network layers disappear between refreshes. Could each
planet keep its last valid map and overlays, with their age shown, until a replacement arrives?") `planet_maps`
`{surface: map}` carries the other planets' maps beside `planet_map`, the ones after it in turn while they fit 24 KB
(packed, a planet's map is 2-4 KB), so a page just loaded has every planet's tab and map at once; `net_map` stays one
a push. The stream service keeps both kinds of map in `runs/RUN/map-memory.json` (at most once a minute) and starts
with the newest along the `resumed-from` chain, so a restart or a shift change lists every planet at once (shift57's
start, d22 06:21, listed Aquilo alone, then Aquilo and Fulgora for minutes); a planet the census has not listed for 30
minutes goes. The live page keeps both kinds of map in the browser's storage (`pog-live-kept`) across page loads,
drops a map whose tick is past the state's (a world rolled back) and a planet the states have left out of `planets`
and `net_maps` for an hour, and does not read storage older than 12 hours; it keeps the last `clouds` while a state has
none and Nauvis's last `basemap` while a state has none. A map the state lists a newer one of, or does not list, is
held: its tab gives its age ("Gleba · 5 min old"), the scale line says "(kept until a newer one arrives)", and so does
the networks or pollution legend line beside its read age.

(d22 batch75 AK3, viewer Aurora, site:4119: "Could the map separate planet tabs from layer filters? Give planets their
own row, group layers below (terrain, networks, combat), and keep the item filter in a consistent spot.") The map's
planet tabs are a row of their own; below them the layers sit in groups under labels: Terrain (terrain, ore, buildings,
pollution or spores), Networks (the item picker first, power, logistic), Combat (turret range, turret state, nests,
fights) and Team (agents, attention, blueprints). A layer the page has had once keeps its button and its place on every
planet, disabled where the planet shown has none of it ("Power networks: none on Aquilo now"); the item picker is
disabled where no networks map is read and has a fixed width, so a planet switch or a push moves no control. Each
layer's on/off is kept in the browser (`pog-live-map-layers`) across planet switches and reloads. (d22 batch75 AK5,
viewer Aurora: "Please compact the toolbar") Two groups a row, Terrain beside Networks and Combat beside Team, each label
over its buttons; when the toolbar is under 34rem wide (a phone) one group a row with its label at the left. The picker
is 8rem wide; the network toggles read "Power" and "Logistics" (their full names in the tooltip). (d22 batch75 AK7,
viewer Aurora site:4183: "Could you put category labels beside the buttons and tighten the gaps between groups, rows and
the planet selector?") Each label sits in a 3.5rem column at the left of its buttons at every width; Terrain + Networks
and Combat + Team are each a row of their own, side by side where both fit, else the second below the first (never paired
otherwise); the gaps are 4-5 px, the toolbar's buttons 7 px a side, the picker 6.5rem ("Item: -" while none is picked, and
disabled where no networks map is, the reason in its tooltip), and the Pollution/Spores toggle one width so nothing after it moves across planets.
Desktop toolbar 150 -> 98 px, a 400 px phone 215 -> 203 px.

push_live packs every grid's rows (`basemap`, `basemap.core`, `basemap.ore`, `planet_map`, `planet_map.core`) with
`rle: 1`: three or more of a letter as the count and the letter (`....AAAA` is `4.4A`); a grid without `rle` is
plain. On world n's state at 08:45 PDT d21 that took the push from 200-205 KB to 187-188 KB (the basemap 46.0 KB to
33.5 KB), and to 188-192 KB with the d17 copy's four planet cores (packed 1.1-4.7 KB each).

`youtube_chat` (eng/sitechat2; Luna 13:54, a viewer's suggestion) is the YouTube lines of the stream service's viewer
lane (tools/stream/viewers.py: only lines that passed its moderation, YouTube deletions it saw taken out), oldest
first, the newest 60: `[{id, name, text, t, staff?}]`; push_live.py also leaves out lines site/moderation.py hides
(earlier runs' deletions, site/hidden-viewers.json). The live page's Chat pane joins them with the site's own comments
(`/v1/chat`) in one time-ordered list, each line badged YT or SITE; the YouTube tab keeps YouTube's own chat.

`viewer_replies` (d15 08:07) is the agents' and the Operator's game-chat lines that answer a viewer or speak to the
viewers, newest 40, oldest first: `[{seq, t, tick, by (agent name or "operator"), text, kind ("reply" | "to_viewers"),
to [viewer names], link?, answers? {name, text?, t, source, id?}, also? [{name, text?, t, source, id?}], part? [k, n]}]` (tools/stream/viewer_replies.py, kept by model.py so they
outlive the chat window). A reply names a viewer who wrote in the last 15 minutes as `@name`, or as a vocative
("Foobator, ...", "Yes, Enginerd.", "Thanks Foobator, ..."), or was said with `reply_to` a viewer line's seq (d20
batch50); "Viewers, ..." and the like speak to the viewers. `answers` is the one viewer line it answers, and `link` says
how that line was found (d20 batch57 S1, viewer Aurora: "Could replies link to ... only the question they answer?"):
`reply_to` (the line its reply_to names, at any age), `only_line` (the named viewer's only line in the 15 minutes before),
`only_to` (their only line in that window addressed to the replier, the relay's "@sol ..."; for the Operator, an inbox
row or "Operator, ..."), `time` (the Operator's "your 13:59" names the line written at that minute), or `none` (no
`answers`: several lines fit and none was named). `answers.text` is left out when the site hides that line. The Chat
pane shows each one, badged REPLY (or TO VIEWERS) in the agent's colour, right under the line it answers when that
line is in the list, else in time order with the line quoted ("re “...”"); a reply says "matched by name: NAME's only
recent line (to AGENT)", "matched by the time it names" or "not linked to a question" (nothing for `reply_to`). "Show
agents' replies to viewers" hides them (kept in localStorage `chatReplies`). The archived shift pages' Viewers section
threads by the same rule (site/longrun.py). Shifts 46-47: 145 replies were threaded by name only; 7 sat under a line
they did not answer (2 of them Muse's, with reply_to lines 90 and 110 minutes old that the 15-minute list no longer
held); with this rule 50 of 157 are not linked, and 2 of the 107 linked ones are under the wrong line.

(d22 batch75 AK6, viewer Aurora site:4175: "Many AI replies are unlinked. Could you preserve source message IDs through
the harness and reply feed, then thread by those IDs? Allow one answer to link to several messages." and site:4176:
"Could replies show a short clickable quote of the source message, with a reply count on the original? Keep new replies
easy to spot without scattering unrelated conversations.") Shift57: 101 of 180 agent lines answered a viewer (named
one, or followed a viewer line to that agent within 5 minutes); 9 carried `reply_to`, all Muse's (Muse passed it on 12
of 16 says, the other agents on none of 245); Muse's 19841 (`reply_to` a list of 5 viewer lines, the harness kept the
first) and 19844 answered shift56 lines the stream service's log did not hold, and both were dropped as no reply. Now
the relay passes each viewer line's own id (`site:4175`, `yt:...`) to `viewer_say` and the game line keeps it
(`source_id`); a say's `reply_to` may be a list, and the line keeps every viewer line it answers as `replies_to`
[{seq, name, id, source, tick, text (160 bytes)}], so the stream service links it without the line itself; a say
without `reply_to` that closes a viewer's one open line to the agent by name is linked to that line by the harness
(`linked_by: "name"`, `link: "name"`: "linked by name: NAME's open line to AGENT"). `answers.id` is the line's id and
`also` the other lines one reply answers. The Chat pane finds each line by its id first (a site line by seq, a YouTube
line by id), then by the viewer's name and words; over a reply a short quote of each line it answers ("↪ Foobator:
“is the south wall closed?”") is a button to that line (the quote alone when the list does not show it); each line
answered shows its reply count, a button to the first reply. A reply threads under its first line when that line is
at most 20 minutes older, else it stays in time order at the bottom with its quote; a reply from the last 10 minutes
is marked new. A reply with `reply_to` whose line nothing kept (a runtime from before) is still a reply, linked to none.

(d22 batch75 AK8, viewer Aurora site:4249 and site:4250: "For replies directly under their actual parent question,
remove the repeated quote and use a compact header. Keep delivery status visible, with context links for standalone
replies." and "Put a small Details button in each header for routing and matching info. Keep full replies visible, put
reply counts inline and tighten spacing. Preserve open details and scroll on refresh.") A reply threaded right under
the line it answers has no quote of that line (the quotes of the other lines it answers stay) and a one-line header:
who, when, `↩` to whom, part, history, new, and a Details button; its full text below it. A reply standing alone keeps
the REPLY tag and its quotes, each a link to its line. Details (closed by default) opens in place: to whom, each line it
answers with its id and that line's delivery, how it was linked, its part, history. A viewer line keeps its delivery
status, with its reply count inline after it ("· 2 replies", a link to the first reply). Rows are tighter. Open
Details and the list's scroll (the line at its top and that line's offset, or the end) are kept when the list is
rebuilt and across a reload, in this tab's sessionStorage (`chatDetails`, `chatScroll`; a kept place waits up to 15 s
for its line to arrive and gives way when the reader scrolls).

The Operator names the line it answers with `tools/opreply.py` (d20 batch65 AA2, viewer Aurora 04:28: "Could replies
keep the original question ID through delivery, split parts and history?"; shift50's 04:20 two-line artillery answer
linked by name to her 04:06 line): `python3 tools/opreply.py --to site:3817 "text"` (or `--to Aurora@03:51`, the inbox
line written at that minute; `--list [NAME]` prints recent inbox lines with what `--to` takes) writes
`runs/RUN/operator-replies.jsonl` ({t, to, name, question {text, t, source}, parts}) and then posts "@Aurora Operator:
..." to the game chat over RCON, cut at sentence ends into "@Aurora (1/2) Operator: ..." parts over 500 bytes;
`--sent SEQ ...` links Operator lines already in the game chat; `--dry-run` prints the parts. model.py (and
longrun.py) read that file: each part answers the named line (`link` reply_to, `answers.id` "site:3817"), at any age and
after a restart. A reply with no record is matched by the rules above. `part` [k, n] marks one of a split reply's
parts (the tool's, or an agent's `fh say` parts), shown "part 1 of 2". The page finds a line by `answers.id` first; its
text match drops every leading @name ("@Muse @Luna ..." on the site, "@Luna ..." in a reply's quote).

`viewer_delivery` {seq: {s, ...}} gains `s` "expired" with `why` (d20 batch65 AA5, viewer Aurora 09:46: "Could messages
sent between shifts stay queued until delivery, with queued/delivered/expired labels?"), and `viewer_read` {after} is
the site seq the stream service has read up to. The service saves that seq in `runs/RUN/site-cursor.json` (just before
a line still waiting in the relay's queue); the next one (a restart, or the next shift along `resumed-from`) reads every
site line after it as queued: to the Operator's inbox at any age, to the agents when written at most 30 minutes before
it was read, else expired ("waited N min for the stream service ..."). A line read again that the last service had
already refused, relayed or put in the inbox keeps that record. A backlog line in no verdict log, inbox or relayed
file (one no service ever read, before the cursor) is expired with that reason. The page labels a site line past
`viewer_read.after` with no delivery "queued", and says the service is not running when the state is old.

`clouds` (viewer Joonazan, 2026-10-14: Gleba's spore cloud) is the pollution, or spores on Gleba, per 32-tile chunk on
each surface an agent is on, read about once a minute: `[{surface, label ("Spores on Gleba"), pollutant (pollution or
spores), color {r, g, b, a} (the game's map colour, 0..1), cells [[cx, cy, amount]], chunks, max, total, age_s,
reached [{x, y}]}]`; chunk (cx, cy) covers tiles `cx*32` to `cx*32+31`. At most 6000 cells over all surfaces, the
most polluted kept (about 14 bytes a cell). The map draws the shown surface's cells in that colour under the
buildings (the Pollution or Spores layer), the amount on hover, the nests it reached ringed; a surface switch shows
another surface's cloud alone (only the cloud, its nests and the agents there). Absent before the first read.

Field meanings are `serve.py`'s (see `docs/STREAM-NOTES.md`); dropped on purpose: `source`, `poll_ok`, `poll_error`,
`errors`, per-agent `seen`, `interest` and `voice`, and camera zoom/player indices. To show something new on the
page, add it to the keep-lists in `push_live.py` and document it here.

## The full board document (d22 batch99 BI3)

Viewer Aurora (site:4316): "Could the board show all tasks and reminders, with paging if needed? Hidden jobs and the
nine omitted reminders make it hard to check what's actually finished."

- **Why a second document:** the state keeps the board's first view within its share (`board`: 20 open and 20 in
  progress, 6 claims; `reminders`: what fits 24 KB). On world n at 16:20 that was 20 of 36 jobs in progress and 19 of
  31 reminders, and no finished tasks at all.
- **The document:** every task and request (open, claimed, doing, blocked, done, dropped), every claim, every project
  read and every reminder job, in a document of its own.
- **`POST /v1/board`** (Authorization: Bearer PUBLISH_TOKEN, at most 256 KB):
  `{tick, items: [{id, title, kind, owner, agent, status, requested_by, updated_tick, evidence?}], items_total, claims,
  projects, reminders, reminders_total}`.
  - site/push_live.py builds it from the stream service's `/board.json` (model.py `board_all_snapshot`).
  - It sends it when it changed (the tick aside), at most every 30 s, and at least every 5 minutes.
  - It is kept within 240 KB: each row's newest evidence line, then the finished projects' steps, then the
    reminders' recipient results, then the oldest tasks (`items_total` keeps the count).
  - A worker without the route (404) is asked again in 10 minutes.
- **`GET /v1/board`** (public, cached 10 s): `{schema, received, age_s, board}`.
  - The live page reads it when a full list opens (the tasks' "Show every task and request", or the reminders' "Show
    all"), then again 30 s later while one is open.
  - It pages them 20 at a time: tasks by Open / In progress / Finished / Dropped / All; reminders by All / Active /
    Overdue / Waiting or open / Finished.
- **Measured:** on world n's board at 16:20 the document was 72.6 KB (73 tasks and requests, 25 of them finished;
  5 claims, 11 projects, 31 reminders). The state push stayed 232 KB.

## Moderation (operator)

`POST /v1/mod` with the publish token and one of:

```json
{"action": "hide", "seq": 41}     {"action": "unhide", "seq": 41}
{"action": "ban", "seq": 41}      {"action": "unban", "seq": 41}
{"action": "close"}               {"action": "open"}
{"action": "clear"}
```

`ban` blocks the client that wrote message 41 and hides all its messages; `close` stops new messages; `clear` hides
every message so far (a fresh start for the public run: no test chat on the page). `seq` keeps counting after a clear,
so pollers using `after` miss nothing new.

## Posting: one message once

`POST /v1/chat {name, text, cid}`: `cid` is 16-32 hex digits the page makes once per message and sends again when it
retries that message (d15: joonazan, 08:05, "the site sends messages twice quite often"). The same `cid` from the same
client is stored once: a repeat, before any limit, answers `200 {"ok": true, "repeat": true, "message": <the first>}`. A
bad `cid` is `400`. Without `cid` (scripts, older pages) nothing changes. The live page also sends one message at a time
(the button is off while one is in flight) and polls `/v1/chat` once at a time, merging by `seq`: before this, a send or
a tab switch during a poll started a second poll and a second timer, and both appended the new messages, so lines showed
twice and more polls ran in parallel after every send.

Names (d22 batch75 AK12, viewer Aurora site:4296: "The site defaults blank names to viewer, but the relay rejects viewer
as impersonation:name. Please align the name rules and test blank-name posting all the way through delivery."): a blank
`name` was "viewer", which the relay to the game (tools/stream/viewers.py RESERVED) drops as `impersonation:name`, so the
line showed on the site and reached no agent (site:4293, d22). Now a blank name is "Guest" and four hex digits of the
poster's salted client hash ("Guest a46f": the same for that poster, another for another), and the reply says it
(`guest_name`; the page shows "Sent as Guest a46f"). The relay's reserved words (worker.js RELAY_RESERVED, the same list:
operator, host, team, viewer, agents, ...) are refused when typed ("that name is reserved") instead of being dropped
later; a site row the old Worker stored as "viewer", or with no name, is relayed as "Guest". The same default holds for
blueprints, poll votes and poll ideas.

## Viewers-only lines (channel)

Viewer LimeLight555 (d16 10:36) asked for a way to talk among viewers without it reaching the agents. `POST /v1/chat
{name, text, cid?, channel: "viewers"}` stores a line that stays on the site: `GET /v1/chat` leaves these out unless
asked with `&channels=all`, so the Mac's relay to the game (tools/stream/viewers.py, which reads without it and also
drops any row whose `channel` is not `game`) never sees them, and they are not on the stream. `channel` is `game`
(the default, and every line from before the column) or `viewers`; anything else is `400`. Viewers-only lines go
through the same code as the rest: the same text rules (length, no links, names), the same per-client and global
limits (one bucket for both channels), `cid`, and `/v1/mod` hide, ban and clear. With `channels=all` each message
carries its `channel`. The live page asks for both, badges a viewers-only line VIEWERS, and has a "Viewers only: not
sent to the agents" box under the message field (kept in localStorage `chatViewers`). YouTube chat is unchanged.

## Shared blueprints

Viewer LimeLight (d16 16:17) asked for ways to share blueprints other than a public GitHub repo (site chat takes 200
characters and no links; LimeLight's strings are 2-200 KB). The live page's "Share a blueprint with the agents" box
(under the chat) posts `POST /v1/blueprints {name, title, string, cid?}`:

- `string` (whitespace ignored) must be a blueprint or blueprint book string: the version byte `0`, base64, zlib, and
  JSON whose top key is `blueprint` or `blueprint_book`. At most 1 MB of string, and at most 16 MB once inflated (the
  Worker inflates through a stream and stops there). Planners and anything else are `400` with the reason. The same
  string again is refused while the first is kept.
- `name` follows chat's rules (2-20 characters; agents' and staff names refused), `title` is required, at most 80
  characters, no links.
- Chat's moderation and limits apply: bans, the open/closed switch, and the per-client gap and per-minute count,
  which blueprint posts share with chat messages. On top of that there are 6 posts per client and 40 in all per
  hour, because the strings are large. The Worker keeps the latest 300 (and at most 64 MB).
- The reply is `{ok, blueprint: {id, t, name, title, kind, label, blueprints, entities, bytes}}`. A repeat of the same
  `cid` returns the first (`repeat: true`).

Reading needs the publish token: `GET /v1/blueprints?after=ID` lists up to 20 (no strings) and
`GET /v1/blueprints/ID` returns one with its string. Moderation: `/v1/mod {"action": "hide_blueprint" |
"unhide_blueprint" | "ban_blueprint", "id": N}`. `ban_blueprint` bans whoever shared it and hides their chat lines and
blueprints, and chat's `ban` hides their blueprints too.

The Mac side is `site/viewer_blueprints.py`; start-team.sh runs it beside push_live.py, and
`POG_VIEWER_BLUEPRINTS=0` turns it off. Every minute it:

- pulls the new ones into `runs/RUN/team-tools/viewer-blueprints/`: `ID-SLUG.txt` is the string, and `ID-SLUG.json`
  holds the id, name, title, time, kind, label, counts, string file and the decoded `blueprint` JSON (decoded again
  with the same caps);
- posts one fact line per blueprint in game chat, which agents see as `server: viewer blueprint #12 from LimeLight:
  "Aethera" (blueprint book, 4 blueprints, 1356 entities): team-tools/viewer-blueprints/12-aethera.json, string in
  12-aethera.txt`.

It posts only while the viewer relay is on (`runs/RUN/viewers-relay.on`); a line not posted yet goes out once it is
on. The title passes the chat relay's checks (`tools/stream/viewers.py`: injection, orders to agents, personal data,
spam, impersonation). A title that fails them is replaced by "(title withheld)" in the line, and the file keeps it.
Nothing is imported into the game. The cursor is `runs/viewer-blueprints.json`, so a new shift gets only new ones;
team-tools is carried over to the next shift anyway.

## Host link and reserved names

Viewers posted as "NickWinter" (site chat has no accounts); Nick (d16 17:11): "a host link so I can have verified
comments and disallow similar nicks".

- `HOST_TOKEN` is a Worker secret (`npx wrangler secret put HOST_TOKEN --config site/worker/wrangler.toml`, 16
  characters or more). Nick's link is the live page with `?host=TOKEN`. The page keeps the token in localStorage
  (`hostToken`), takes it out of the address bar (`history.replaceState`), and sends it as the `X-Host-Token` header
  with every `POST /v1/chat`. It never goes in a URL the page fetches or in a body. The page shows "Signed in as host"
  with a Forget button, and the name box is off. (The published page never names the owner: build.py's blocked-word
  check fails the build on it.)
- The Worker compares the header with `HOST_TOKEN` in constant time, like the publish token. A match posts as
  "NickWinter" with `host: true`, whatever the name box says. Bans, the per-client gap and per-minute limits and the
  duplicate rule do not apply; a cap of 30 host lines a minute does. The text rules (200 characters, no links)
  still apply. A token that does not match, or any token while `HOST_TOKEN` is unset, is
  `403 {"error": "host link not valid"}` and nothing is stored: it is never posted as a viewer.
- Reserved names, without the token (worker.js `reservedName`, tools/stream/names.py `reserved`; the same rule and
  tables, tools/stream/test_names.py runs both on one list):
  - Normalize first: zero-width characters out, Cyrillic and Greek look-alikes to Latin, compatibility forms
    (fullwidth, math letters) and accents folded, lower case, leetspeak (0 o; 1, l, | i; 3 e; 4, @ a; 5, $ s; 7 t),
    then only a-z kept.
  - Then refuse when the result contains "nickwinter" or "nickw"; equals "nick", "winter", "operator", an agent's
    name (astra, sol, luna, opus, sonnet, haiku, grok, gemini, muse, fable), "server" or another staff word; or is
    within edit distance 2 of "nickwinter" or "operator".
  - The answer is `400 {"error": "that name is reserved"}`.
- Polls take both rules too: `POST /v1/polls/ID/vote` and `POST /v1/polls/suggest` refuse a reserved name (they use
  the same `viewerName`). With a matching `X-Host-Token` they vote or suggest as NickWinter, and that vote's comment
  carries `host: true` in `GET /v1/polls`. A wrong token is 403. polls.js sends the stored token on both. The host's
  cap of 30 a minute covers chat posts, votes and ideas together.
- `GET /v1/chat` carries `host: true` on host lines. The live page badges them HOST (gold), as it does Nick's YouTube
  lines (`youtube_chat[].host`, push_live.py).
- The relay (tools/stream/viewers.py):
  - A site row with `host: true` is the host's line. It is named "NickWinter (host)" in the game and on the stream,
    and it is never dropped as impersonation, rate-limited, held as a duplicate or rejected by Clef.
  - A site row under a reserved name without `host` is dropped. That includes rows an older Worker stored.
  - On YouTube the host is Nick's channel id (`names.HOST_YOUTUBE_CHANNEL`), never a display name. Any other YouTube
    author whose name is reserved gets " (viewer)" ("NickWinter (viewer)"); the line stays.
  - The stream's chat panel badges host lines HOST.

## Polls

Nick (d16 17:15) asked for polls viewers vote on; the operator decides which polls run. Everything is in the Worker's
Durable Object (tables `polls`, `votes`, `poll_ideas`).

Public:

- `GET /v1/polls` returns `{schema, now, open: [poll], closed: [poll], limits}`: the open polls (soonest to close
  first) and the latest 20 closed ones. A poll is `{id, question, intro, options, details, counts, total,
  viewer_counts, viewer_total, agent_counts, agent_total, opens, closes, created_by, status, left_s, comments}`.
  `options` are labels, and `details[i]` is option i's benefits and consequences ("" for none; viewer LimeLight's idea,
  up to 600 characters each). `intro` is at most 800 characters. `counts` is viewers' and agents' votes together, and
  the `viewer_`/`agent_` fields count them apart. `status` is `open` until `closes` (or an early close), then `closed`.
  `comments` are the newest 100 votes that carry a comment: `{id, t, name, option, comment, agent}`, where `agent` is
  true for an agent's vote. Client hashes are never public.
- `POST /v1/polls/ID/vote {option, name, comment?, cid?}`: `option` is the index. Each client (the same salted address
  hash chat's limits and bans use) has one vote per poll, and a later vote replaces it (`replaced: true`). The earlier
  rows stay in the voter log, the 20 latest per client and poll. `name` follows chat's rules (2-20 characters,
  reserved names refused). `comment` is optional, at most 200 characters, no links. Bans and chat's per-client gap and
  per-minute count apply (a vote counts as a message). The same vote again is `unchanged: true` and costs nothing. A
  repeated `cid` returns the first vote (`repeat: true`). A closed poll is `403 {"error": "this poll is closed"}`. The
  reply carries the poll's new counts.
- `POST /v1/polls/suggest {name, question, options, intro?, hours?, cid?}`: a viewer's poll idea, with the question
  and option rules below plus no links. It costs a chat message, with 3 ideas per client an hour on top. Ideas are
  never public: the operator reads them, and the Mac files each into the operator inbox (below).

Operator (publish token):

- `POST /v1/polls {question, intro?, options, hours?, created_by?}` opens a poll. Each option is a label (at most 100
  characters) or `{label, details}`, with 2 to 6 distinct options. The question is at most 200 characters and `hours`
  is above 0 and at most 72 (default 12). At most 4 polls can be open at once (`409` beyond that).
- `POST /v1/polls/ID/close` closes a poll early.
- `GET /v1/polls/ID/voters` returns the voter log, `{poll, votes: [{id, t, voter, name, option, choice, comment,
  current, hidden, agent}]}`. `current: 1` marks the vote that counts.
- `GET /v1/polls/suggestions?after=ID` returns `{ideas: [{id, t, name, question, intro, options, details, hours}],
  last_id}`, leaving out banned clients' ideas.
- An agent's vote is `POST /v1/polls/ID/vote {agent, name, option, comment?}` with the token (`./fh poll vote` sends
  it). The voter is `agent:AGENT`, and `name` is the agent's name as shown, with an AI badge. Each agent has one vote
  per poll, and a later vote replaces it. Viewer limits do not apply.
- `/v1/mod {"action": "hide_comment" | "unhide_comment", "id": VOTE_ID}` hides or shows a comment, and the vote still
  counts. `{"action": "ban_voter", "id": VOTE_ID}` bans that client: its votes stop counting, and its comments, chat
  lines and blueprints are hidden. Chat's `ban` and `ban_blueprint` hide that client's comments and stop its votes
  counting too.

`tools/poll.py` wraps these calls: `create --file tools/polls/first-poll.json` (or `--question Q --option A --option B
--hours 12`), `list`, `close ID`, `voters ID`, `ideas`, and `hide-comment VOTE_ID`.

The site has two views. The live page's poll card sits under the player and chat (`static/polls.js`). It shows the open
polls only, with the question, the intro, each option as a button with a Details toggle, an optional comment, and the
time left. After voting it shows the results: a bar per option split into viewers and agents, the counts apart and
together, "your vote", and "Change my vote". With no poll open (Nick d17 08:30) the card is one line, "Past polls ·
last: QUESTION (won: OPTION, N of M votes)", for a poll closed in the past day, and hidden after that. The card links
to `/polls/`, which lists the open polls in full, then "Past polls" (`#past`): each closed poll collapsed to a line with
its question, when it closed and the winner ("tie: A / B" or "no votes"), and its results, details and comments (with
AI badges on agents' comments) inside. `/polls/#poll-ID` opens that one. Then the "Suggest a poll" form. Voided and
banned votes are in no count, open or closed. The browser remembers the vote in localStorage `pollVotes` and the
name in `chatName` (chat's name box). Without the API the card stays hidden, and the page says polls are unavailable.

On the Mac, `site/polls_relay.py RUN` is the only process with the token for polls. start-team.sh starts it beside
push_live.py; it is off with `POG_PUSH_LIVE=0` or `POG_POLLS=0`. It does three jobs:

- It writes `RUN/polls.json` every 30 s, and right after an agent's vote: the public view, plus each open poll's
  current agent votes from the voter log.
- It handles agents' requests. `./fh poll vote|suggest` (`tools/fh_poll.py`) appends them to the agent's own
  workspace (`RUN/AGENT/.poll-requests.jsonl`), because an agent's sandbox writes only there and the folder names
  the agent. The relay posts a vote as `agent:AGENT` under its game name, or files an idea as one operator-inbox
  line, and answers in `.poll-replies.jsonl`.
- It files viewers' ideas into the operator inbox once each, with the cursor in `runs/poll-ideas.json`.

`RUN/polls.json` feeds three readers:

- `./fh poll` reads it.
- The host CLI (`vendor/factorio-harness/host/polls.ts`) puts one `team.poll` line in an agent's next reply when a
  poll opens, once per poll.
- serve.py reads it through `tools/stream/pollstrip.py` into the snapshot's `poll`. The overlay shows a strip under
  the chat (question, top counts with viewers and agents apart, "Vote at factorio.nickwinter.net") for 30 s every 10
  minutes while a poll is open, and the result for 60 s when it closes. The casters get the open poll as
  `site_poll` on non-urgent beats, and not again for 20 minutes after a line of theirs mentions a poll or votes.
  Nothing about polls goes into game chat.

## Limits

Per client: one message every 4 s and 8 per minute; all clients together: 60 per minute. Over the limit:
`429 {"error": "slow down", "retry_after_s": N}`. Other refusals are `400` (`empty message`, `links are not allowed`,
`that name is reserved`, ...) or `403` (`chat is closed`, banned client, or a browser on another site's origin).
Browsers may call the API only from `ALLOWED_ORIGINS` in `site/worker/wrangler.toml` (the custom domain, the Pages project and its
preview subdomains, plus local preview on port 8765); scripts without an `Origin` header are allowed and limited the
same way.

Free-plan capacity: each page view polls state every 10 s and chat every 4 s; the Worker answers repeats from a
per-edge cache for 2 to 3 s before waking the Durable Object. That is comfortable for a preview audience. For a
public launch, put the API on a custom domain (so the Cache API works) or move to the paid plan.
