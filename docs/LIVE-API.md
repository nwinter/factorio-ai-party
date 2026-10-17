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

`POST /v1/state` accepts any JSON object up to 256 KB and replaces the stored state; a typical push is 12 KB.
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
                 "recent": [{"name": "steel-processing", "label": "Steel processing", "t": null}]},
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
                             "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42}, "paused": false}]},  // at most 6
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
pinch, + and −), Reset, Full screen, layers to toggle (terrain, ore, pollution, buildings, turret range, nests, agents,
attention, fights; turret range starts off; the choice is kept per browser), and a click or tap on an agent to centre on it and
follow it; hover or tap names a mark. `basemap.turrets` draws the turret-range layer (the union of every turret's reach)
and `basemap.terrain` the terrain layer: each frame's image stretched over its tile edges (`x0`, `y0` the image's top
left, `x1`, `y1` its bottom right), older frames first, under everything else; `src` must be a site path or an https URL.
The map is Nauvis: an agent whose `surface` is another planet, or with `on_platform` or `travel` set (a cargo pod), is
listed in its bottom-left corner instead ("Luna · Vulcanus", "Opus · Solstice (platform)") and takes no part in
the framing; each agent row carries `surface`, `where`, `on_platform` and `travel` from the stream service for that.
It draws `fights` as rings the size of their `extent` (solid while `age_s` is under 25,
faded after, a cross where `losses` happened), tags each agent a camera follows with its slot, lists what each camera
shows (`cameras`: its agents, or the `attack`, `work` or `segment` shot), shows the research in progress over the
map, and `space` as an inset under it. `space`, `fights` and the camera labels add a few hundred bytes to a push.

`basemap` is the base as a coarse grid, read once a minute by the stream service (`BASEMAP_LUA` in
`tools/stream/harness.py`, an operator read like the score): every building of ours on nauvis except electric poles,
binned into `cell`-tile cells (4, doubled until the grid fits 128 cells a side), each cell labelled by its most telling
building: `D` defence (turrets, walls, gates), `R` labs, `O` oil and chemistry (refineries, chemical plants,
pumpjacks), `A` assembly (assemblers, the silo), `S` smelting, `M` mining (drills, offshore pumps), `E` power,
`K` storage, `B` belts and inserters, `P` pipes, `.` nothing. Cell (c, r) covers tiles `x0 + c*cell` to
`x0 + (c+1)*cell` and the same for y. Trailing empty cells are left off each row. It is absent until the first read.
`basemap.ore` (read every 5 minutes, the last one kept between reads) is a second grid with its own `cell`, `x0`,
`y0`, `w` and `rows`, covering the base plus 64 tiles: one letter per cell for its commonest resource, `i` iron ore,
`c` copper ore, `k` coal, `s` stone, `o` crude oil, `u` uranium ore, `x` anything else. The page draws it faintly
under the buildings. With a base, the page frames the base and pins an agent more than a base-width away to the
map's edge (dashed, its distance in the tooltip).

`planets` and `planet_map` are the other planets we have built on (viewers craigNZ830 and Foobator, d15 07:05: the map
showed Nauvis only). `planets` lists them all, `[{surface, tick, buildings}]`. `planet_map` is one of them in turn
each push (`{surface, tick, cell, x0, y0, w, h, rows, buildings}`, the same letters as `basemap`, cell 4 doubled until
the planet's buildings fit 128 cells a side), so a push carries one planet's grid (at most about 17 KB); the page
keeps the ones it has seen and drops a planet `planets` no longer lists. They come from the harness census's last
pass (`census {part: "planets"}` and `census {part: "basemap", surface}`, operator reads that answer from storage),
one planet a minute in the stream service. The map card shows a tab per planet beside Nauvis; on a planet's tab its
buildings are drawn, with the agents on it (the rest listed in the corner); no core, ore, terrain, nests or turret
range there.

`youtube_chat` (eng/sitechat2; Luna 13:54, a viewer's suggestion) is the YouTube lines of the stream service's viewer
lane (tools/stream/viewers.py: only lines that passed its moderation, YouTube deletions it saw taken out), oldest
first, the newest 60: `[{id, name, text, t, staff?}]`; push_live.py also leaves out lines site/moderation.py hides
(earlier runs' deletions, site/hidden-viewers.json). The live page's Chat pane joins them with the site's own comments
(`/v1/chat`) in one time-ordered list, each line badged YT or SITE; the YouTube tab keeps YouTube's own chat.

`viewer_replies` (d15 08:07) is the agents' and the Operator's game-chat lines that answer a viewer or speak to the
viewers, newest 40, oldest first: `[{seq, t, tick, by (agent name or "operator"), text, kind ("reply" | "to_viewers"),
to [viewer names], answers? {name, text?, t, source}}]` (tools/stream/viewer_replies.py, kept by model.py so they
outlive the chat window). A reply names a viewer who wrote in the last 15 minutes as `@name`, or as a vocative
("Foobator, ...", "Yes, Enginerd.", "Thanks Foobator, ..."); "Viewers, ..." and the like speak to the viewers. `answers`
is the viewer line it answers (one addressed to the agent first); its `text` is left out when the site hides that line.
The Chat pane shows each one, badged REPLY (or TO VIEWERS) in the agent's colour, right under the line it answers when
that line is in the list, else in time order; "Show agents' replies to viewers" hides them (kept in localStorage
`chatReplies`). The archived shift pages' Viewers section uses the same rule (site/longrun.py).

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
- `GET /v1/chat` carries `host: true` on host lines. The live page badges them HOST (gold), as it does Nick's YouTube
  lines (`youtube_chat[].host`, push_live.py).
- The relay (tools/stream/viewers.py):
  - A site row with `host: true` is the host's line. It is named "NickWinter (host)" in the game and on the stream,
    and it is never dropped as impersonation, rate-limited, held as a duplicate or rejected by Clef.
  - A site row under a reserved name without `host` is dropped. That includes rows an older Worker stored.
  - On YouTube the host is Nick's channel id (`names.HOST_YOUTUBE_CHANNEL`), never a display name. Any other YouTube
    author whose name is reserved gets " (viewer)" ("NickWinter (viewer)"); the line stays.
  - The stream's chat panel badges host lines HOST.

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
