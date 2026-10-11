# Companion site

A static site for player-of-games: what the project is, the experiments log, one page per run, the studies, and a
live page for the stream. `build.py` (Python 3 stdlib, no dependencies) reads the repo's run data and writes plain
HTML, CSS and a little JS to `site/dist/`. Charts are inline SVG generated at build time.

## Build and preview

```sh
python3 site/build.py                     # writes site/dist/
python3 site/check.py                     # HTML structure, internal links and anchors, noindex on every page
python3 -m http.server 8765 -d site/dist  # http://127.0.0.1:8765/
```

The site uses root-relative links (`/runs/...`), so open it through a server, not `file://`.

## Deploy

```sh
npx wrangler pages deploy site/dist --project-name player-of-games
```

The Cloudflare Pages project `player-of-games` has `main` as its production branch. Deploying from any other
branch (such as `site`) makes a preview deployment with its own URL; the production domain stays empty until
something is deployed from `main` (or with `--branch main`).

The site is unlisted for now. Three things keep it out of search engines; remove all three when it goes public:

- `<meta name="robots" content="noindex, nofollow">` in every page (`page()` in `build.py`),
- `robots.txt` disallowing everything,
- an `X-Robots-Tag: noindex, nofollow` header in `_headers`.

`site/check.py` fails the build check if a page lacks the meta tag or robots.txt allows crawling.

## Where the content comes from

| Page | Source |
|---|---|
| Run timelines, charts, end-of-run numbers | `runs/*/scores.jsonl` (the score logger, every ~2 wall minutes); `runs/*/final-score.json` when present supersedes later snapshots |
| Agent cards: final summary | the "Final summary" section of each agent's `runs/<run>/<agent>/notes.md` |
| Team chat and quotes | `runs/shake1/chat-full.jsonl` (rebuilt chat); quoted lines are picked by `seq` in `notable_chat` |
| Study pages | `docs/studies/*.md`, rendered by the small Markdown renderer in `build.py` |
| Everything written by hand | `site/content/site.json`: agent identities, experiment write-ups, milestone tables (from `docs/PLAN.md` and agent notes), per-agent stats (from the study), harness changes (from `docs/HARNESS-CHANGES.md` and `docs/BOTS-NOTES.md`) |
| Site settings | `site/config.json` |

Adding a run: put its entry under `runs` in `site/content/site.json` (directory, players, milestones, summary;
`kind` is `versus` for separate worlds or `team` for one shared world), add it to an experiment's `runs`, rebuild.
Adding a study: drop the Markdown in `docs/studies/` and add an entry under `studies`.

Agents are named by their game names everywhere. Model labels and harness names come from `site.json`, never from
agents.

### Privacy

Nothing personal goes on the site. `clean()` in `build.py` redacts e-mail addresses, absolute local paths
(`/Users/...`, `~/...`, `C:\...`), key-like tokens and IP addresses from everything taken from notes, chat and
studies, and the build fails if an e-mail address or local path survives into `dist/`. The repo's prompts,
`AGENTS.md`/`CLAUDE.md`, quota files, supervisor logs and stream logs are never read. If you add a new source,
pass its text through `clean()`.

## Configuration (`site/config.json`)

| Key | Meaning |
|---|---|
| `site_title`, `description` | header and meta description |
| `youtube_video_id` | the stream's video ID; when set, the live page embeds it (muted autoplay, youtube-nocookie) |
| `youtube_channel_id` | alternative: embed the channel's current live stream |
| `live_status_url` | where the live page fetches status (default `/live/status.json`) |
| `live_poll_seconds` | refresh interval (default 15; four times slower while the tab is hidden) |

No stream exists yet, so both YouTube keys are empty and the page shows a placeholder.

## Live status JSON

The live page polls `live_status_url` and renders whatever it finds. The publisher doesn't exist yet; it should
write this file (for example from the stream overlay service's `/state.json`, which already has most of these
fields) and upload it, or the URL can point at any HTTPS endpoint that serves it with CORS. `live/status.json` in
this folder is the offline default that ships with the site; `live/status.example.json` is a full sample, viewable
at `/live/?demo=1`.

```jsonc
{
  "schema": 1,                       // bump on breaking changes
  "updated": "2026-10-10T17:52:10-07:00",   // ISO time the publisher wrote this
  "live": true,                      // false: show "Offline" plus message/next/last_run only
  "message": "optional one-liner",
  "next": {"title": "Shakedown 2", "when": "2026-10-12T17:00:00-07:00"},   // optional, shown when offline
  "last_run": {"id": "shake1", "title": "Shakedown 1", "url": "/runs/shake1/"},  // optional, site-relative url
  "run": {"id": "shake2", "title": "...", "subtitle": "...", "mode": "realtime|turns", "enemies": "normal",
          "seed": 20261010, "started": "ISO", "deadline": "ISO"},
  "stream": {"youtube_video_id": "", "youtube_channel_id": ""},   // optional; overrides config when set
  "game": {
    "tick": 176400, "game_time": "49m00s", "paused": false, "rockets": 0,
    "research": {"current": "fluid-handling", "progress": 0.42, "done": 12,
                 "recent": [{"tech": "engine", "game_time": "48m55s"}]},
    "per_minute": {"iron-plate": 412, "automation-science-pack": 24},   // optional, not drawn yet
    "power": {"capacity_mw": 3.6, "load_mw": 1.6, "starved": 0}          // optional, not drawn yet
  },
  "agents": [{
    "id": "astra", "name": "Astra", "model": "GPT-6 Astra", "harness": "Codex",
    "color": "#9977ff", "glyph": "AS", "motto": "...",      // from profiles; null falls back to a hashed colour
    "state": "acting|thinking|idle|dead|offline",
    "action": "construct", "location": "green science",
    "camera": "main|cam2|cam3",                              // optional: which director camera shows them
    "respawn_s": 7                                           // optional, when dead
  }],
  "chat": [{"seq": 334, "game_time": "49m00s", "from": "gemini", "text": "..."}],   // last ~20; page shows 8
  "alerts": [{"kind": "attack|death|low_power|research", "text": "...", "game_time": "48m50s"}]  // page shows 3
}
```

All text is escaped before display, colours must be `#rrggbb`, and links in `last_run.url` must be site-relative.
`_headers` serves `/live/status.json` with `Cache-Control: no-store`.

## Files

- `build.py`: generator (data loading, Markdown renderer, SVG charts, page templates)
- `check.py`: post-build checks
- `content/site.json`: hand-written content
- `config.json`: settings
- `static/`: `style.css` (light/dark tokens, layout), `site.js` (theme toggle, chart hover), `live.js` (live page)
- `live/`: default and sample status files
- `dist/`: build output (not committed)
