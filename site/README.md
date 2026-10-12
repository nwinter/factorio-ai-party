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

The long run (`/runs/long/`, `site/longrun.py`): the shifts chained by `runs/RUN/resumed-from`, read from the
repo's `runs/` (or `--runs-dir DIR`): each shift's `scores.jsonl`, the timestamps of `start.log`, the director's
death and loss cuts in `stream-service.log`, and the hosts' Space Age lines in `caster.log`. Without a chain (a
checkout without the shift folders) the page and its links are left out. Rebuild after a shift to add it.

## Deploy

```sh
npx wrangler pages deploy site/dist --project-name player-of-games --branch preview
```

The Cloudflare Pages project `player-of-games` has `main` as its production branch. Any other `--branch` makes a
preview deployment: each gets its own URL, and the branch also gets a stable alias
(`https://preview.player-of-games.pages.dev` for `--branch preview`). Without `--branch`, wrangler uses the current
git branch. The production domain stays empty until something is deployed with `--branch main`.

### Custom domain: factorio.nickwinter.net

`site/custom-domain.sh check|deploy|attach|verify` (from the repo root, in that order). `check` is read-only and
shows wrangler's account, the zone's account and the project in it; `deploy` builds, checks, deploys the live API
Worker (its `ALLOWED_ORIGINS` lists the domain) and Pages production (`--branch main`); `attach` adds the domain to the
Pages project and a proxied CNAME to `player-of-games.pages.dev` in the zone (in that order: a CNAME before the domain
is attached answers 522); `verify` checks the page, noindex and the live API's CORS for the new origin. `attach` and
`check`'s zone part need `CF_TOKEN`, an API token with Account > Cloudflare Pages > Edit and Zone > DNS > Edit and
Zone > Zone > Read for nickwinter.net. In the dashboard instead: Workers & Pages > player-of-games > Custom domains >
Set up a custom domain > `factorio.nickwinter.net`; with the zone in the same account it adds the CNAME itself.

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
| Study pages | `docs/studies/*.md`, rendered by the small Markdown renderer in `build.py`, after the study's `rewrite` list in `site.json` |
| Look and feel | `tools/stream/static/factorio-ui.css` (the art kit shared with the stream overlay, see `docs/ART-NOTES.md`), copied into `dist/static/` at build time; `site/static/style.css` maps the site onto its tokens |
| Agent portraits | `tools/stream/avatar.py` renders `/static/avatars/<name>.svg` from each agent's name, colour and optional `avatar` parts in `site.json`; the live page draws them in the browser with `tools/stream/static/avatar.js` |
| Agent pages (`/agents/<name>/`) | every run in `site.json` the agent played, with its role, outcome, stats and chat lines |
| Operator interventions per run | `incidents` in each run's `site.json` entry (from `operator-interventions.log`, agent notes and `docs/PLAN.md`) |
| Everything written by hand | `site/content/site.json`: agent identities, experiment write-ups, milestone tables (from `docs/PLAN.md` and agent notes), per-agent stats (from the study), harness changes (from `docs/HARNESS-CHANGES.md` and `docs/BOTS-NOTES.md`) |
| Site settings | `site/config.json` |

Adding a run: put its entry under `runs` in `site/content/site.json` (directory, players, milestones, summary;
`kind` is `versus` for separate worlds or `team` for one shared world), add it to an experiment's `runs`, rebuild.
Adding a study: drop the Markdown in `docs/studies/` and add an entry under `studies` (`title`, `short` for the
button on the experiments page, `run`, `date`, `summary`). Run pages and the experiments page link every study whose
`run` matches.

When an agent designs its avatar in game (`profile` with `avatar`, see `docs/ART-NOTES.md`), copy the parts object
into that agent's entry in `site.json` as `"avatar": {...}` and rebuild. Until then the portraits are the
renderer's defaults for the name and colour, the same ones the stream overlay shows.

Agents are named by their game names everywhere. Model labels and harness names come from `site.json`, never from
agents.

### Privacy

Nothing personal goes on the site. `clean()` in `build.py` redacts e-mail addresses, absolute local paths
(`/Users/...`, `~/...`, `C:\...`), key-like tokens and IP addresses from everything taken from notes, chat and
studies, and the build fails if an e-mail address or local path survives into `dist/`. The repo's prompts,
`AGENTS.md`/`CLAUDE.md`, quota files, supervisor logs and stream logs are never read. If you add a new source,
pass its text through `clean()`.

Some studies describe the owner's own machine setup (account routes, personal config, tool names). Those passages
are rewritten at build time by the study's `rewrite` list in `site.json` (regex, replacement pairs). Each pattern
must still match or the build stops, so an edit to the study can't slip the original text through. The build also
fails if any name in `_BLOCKED` in `build.py` (the owner's name, account and personal-tool names) reaches `dist/`.

The only third-party request is the Titillium Web font from Google Fonts, which the art kit uses. Without it the
pages fall back to Segoe UI or the system font.

## Configuration (`site/config.json`)

| Key | Meaning |
|---|---|
| `site_title`, `description` | header and meta description |
| `youtube_video_id` | the broadcast's video ID. When set, the live page embeds the player (muted autoplay, youtube-nocookie) and the YouTube live chat beside it. Unlisted broadcasts work if embedding is allowed on the broadcast |
| `youtube_channel_id` | alternative: embed the channel's current live stream (no chat embed: YouTube's chat embed needs a video ID) |
| `live_api_url` | the live API (Worker) base URL; empty turns the dashboard and site chat off |
| `live_status_url` | the offline notice (default `/live/status.json`: message, next run, latest run, optional stream IDs) |
| `live_poll_seconds` | dashboard refresh interval (default 10, matching the pusher; four times slower while the tab is hidden) |

No stream exists yet, so both YouTube keys are empty and the page shows a placeholder.

## Live page

`/live/` is the place to watch a run. Top: the YouTube player and a chat panel with two tabs, "YouTube chat" (the
live chat embed, `embed_domain` set to the page's host) and "Site chat" (our own, no accounts). Below: a dashboard
drawn from the stream service's state: a status strip (game time, technologies, science per minute, research
progress), alerts, one panel per agent (portrait, model and role, state, current action and place, last two chat
lines, camera), a map of the base (buildings by category in 4-tile cells, enemy nests, from the stream service's
once-a-minute `basemap` read) with the agents, camera rings and alert pins on top, the board (owners and recent events),
research, production and science charts for the last 30 minutes, and the team's game chat. `/live/?demo=1` shows it
with `live/state.example.json`, a snapshot of the stream service's mock session passed through the pusher's filter.

Data flow, all documented in `docs/LIVE-API.md`:

```
game host -> tools/stream/serve.py (/state.json) -> site/push_live.py (every 10 s, filtered + redacted)
          -> Worker player-of-games-live (POST /v1/state, token) <- live page (GET /v1/state, GET/POST /v1/chat)
                                                                  <- eng/viewers on the Mac (GET /v1/chat)
```

When the latest state is more than 60 s old the page shows "Offline", dims the last dashboard and shows the notice
from `live/status.json`.

### The Worker (`site/worker/`)

```sh
npx wrangler deploy --config site/worker/wrangler.toml          # deploy or update
npx wrangler dev --config site/worker/wrangler.toml --port 8791 --ip 127.0.0.1 --inspector-port 9339   # local
python3 site/worker/test_api.py http://127.0.0.1:8791            # 20 checks: auth, CORS, chat limits, moderation
```

One Durable Object (SQLite-backed, free plan) holds the latest state and the chat. `PUBLISH_TOKEN` is a Worker secret
for pushing state and moderating; the same value lives in `site/worker/.secrets.json` (and `.dev.vars` for local
runs), both gitignored and mode 600. To rotate: write a new value into `.secrets.json`, run
`npx wrangler secret bulk site/worker/.secrets.json --config site/worker/wrangler.toml`, and restart the pusher.
`ALLOWED_ORIGINS` in `wrangler.toml` lists the origins whose pages may call the API (add a custom domain there).

### The pusher (`site/push_live.py`, on the Mac)

```sh
python3 site/push_live.py                    # serve.py on 127.0.0.1:8787, push every 10 s until stopped
python3 site/push_live.py --once --print     # show what would be published
```

It forwards only the fields listed in `docs/LIVE-API.md` and passes every string through `clean()`.

## Files

- `build.py`: generator (data loading, Markdown renderer, SVG charts, page templates)
- `check.py`: post-build checks
- `content/site.json`: hand-written content
- `config.json`: settings
- `static/`: `style.css` (light/dark tokens on top of the art kit, layout), `site.js` (theme toggle, chart hover),
  `live.js` (live page). `factorio-ui.css`, `avatar.js` and `avatars/` are added to `dist/static/` by the build.
- `live/`: `status.json` (offline notice) and `state.example.json` (sample state for `?demo=1`)
- `push_live.py`: Mac-side state pusher
- `worker/`: the live API Worker (`worker.js`, `wrangler.toml`, `test_api.py`)
- `dist/`: build output (not committed)
