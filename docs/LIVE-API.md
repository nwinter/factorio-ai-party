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
  "state": {                    // the pushed snapshot, or null
    "schema": 1, "now": 1791695551.8, "tick": 144720, "paused": false, "game_time": "0h40m",
    "title": "Nine AIs, one factory", "subtitle": "...",
    "agents": [{"name": "astra", "display_name": "Astra", "color": "#7c5cff", "glyph": "✦", "motto": "...",
                "avatar": {"base": "robot"}, "model": "GPT-6 Astra", "harness": "Codex", "role": "...",
                "alive": true, "activity": "acting|thinking|idle|dead|offline", "action": "...",
                "active": "construct", "position": {"x": -64.8, "y": -23.6}, "location": "iron smelting",
                "last_said": {"text": "...", "tick": 144700}, "camera": "main|cam2|cam3|null", "combat": false,
                "died_at": null, "kind": "bot", "profile_set": true}],
    "chat": [{"seq": 1, "tick": 144720, "from": "Muse", "agent": "muse", "text": "...", "t": 1791695551.8}],  // last 40
    "research": {"current": "engine", "label": "Engine", "progress": 0.54, "done_count": 8,
                 "recent": [{"name": "steel-processing", "label": "Steel processing", "t": null}]},
    "production": [{"item": "iron-plate", "total": 4562, "rate": 239.8, "series": [/* per minute, last 30 */]}],
    "science": {"spm": 10.0, "series": [/* per minute */], "stage": 2, "stage_label": "Steel & logistics",
                "packs": [{"item": "automation-science-pack", "rate": 0.0, "total": 277}]},
    "alerts": [{"kind": "attack|death|low_power|research", "text": "...", "agent": "grok", "position": {"x": 0, "y": 0}}],
    "board": {"available": true, "open_unowned": 1, "in_progress": 2, "claims": [...], "events": [...]},
    "basemap": {"tick": 230400, "cell": 4, "x0": -112, "y0": -72, "w": 56, "h": 41, "buildings": 659,
                "rows": ["..DDDDDD", "....S.BB"],   // one string per cell row from y0; one letter per cell from x0
                "nests": [[150, 40, "s"], [140, 30, "w"]]},  // enemy spawners (s) and worms (w) near the base
    "cameras": {"main": {"agents": ["sol"], "pair": false, "since": 1791695548.8}}
  }
}
```

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
```

`ban` blocks the client that wrote message 41 and hides all its messages; `close` stops new messages.

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
