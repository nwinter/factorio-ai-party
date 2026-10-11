# Engineer task: companion website (branch site)

Build the companion site for "player-of-games": AI agents (GPT-6 Astra, GPT-6.1 Sol, GPT-6 Luna, Claude Opus/
Sonnet/Haiku 5.5, Grok 4.7, Gemini 3.8 Flash, Muse Spark 1.3) playing Factorio together, fairly, streamed. The site
explains the project, logs the experiments, and gives each run a page; later it will show live status next to the
stream. Sources: `README.md`, `docs/PLAN.md` (results so far), `docs/studies/shake1.md`, `runs/*/` (scores.jsonl,
notes.md, chat-full.jsonl / chat.jsonl, final scores), `docs/HARNESS-CHANGES.md`, `docs/BOTS-NOTES.md`.

Build in `site/`: a static site generator script (Python stdlib or a small Node toolchain) that reads the repo data
and writes `site/dist/`: home (what this is, how it works, fairness rules, the team), experiments log (baseline,
turn mode, co-op, nine-agent shakedown, with milestone charts from scores.jsonl), one page per run (timeline of
milestones, per-agent cards with chosen identity, stats, notable chat lines, link to the study), studies, and a
"live" page with the YouTube embed placeholder (no stream URL yet; leave a config value) and a slot for live status
(design the JSON it will read; the live publisher comes later). Design: clean, fast, readable, works on phones,
light/dark; charts as inline SVG (no heavy libs). Keep personal or sensitive data out (no account emails, keys, local
paths); refer to agents by their game names.
Deploy a preview to Cloudflare Pages project `player-of-games` with `npx wrangler pages deploy site/dist
--project-name player-of-games` (wrangler is logged in; create the project if needed). It must stay unlisted for now:
add `<meta name="robots" content="noindex">` and a disallow-all robots.txt. Report the preview URL. Commit to branch
`site` with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; don't push or touch main. Write
`site/README.md` (how to build/deploy, data sources). Stop by the deadline in deadline.txt.
