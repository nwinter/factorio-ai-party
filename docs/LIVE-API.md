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
- `name` is whatever the viewer typed (2 to 20 letters, digits, spaces or `_ . ' -`); agents' names, "operator",
  "mod", "admin", "caster", "system" and the like are refused, so a message can't pose as an agent or staff.
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
    "board": {"available": true, "open_unowned": 1, "in_progress": 2, "claims": [...], "events": [...],
              "projects": [{"id": 4, "title": "Nuclear power plant", "owner": "opus", "agent": "opus", "status": "claimed",
                            "progress": "3 of 6 steps", "done": 3, "total": 6}],   // open, latest changed first; at most 4
              "projects_total": 1},   // a project event row also has progress, steps_done, steps_total (verb step: step)
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
pinch, + and −), Reset, Full screen, layers to toggle (terrain, ore, buildings, turret range, nests, agents, attention,
fights; turret range starts off; the choice is kept per browser), and a click or tap on an agent to centre on it and
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
