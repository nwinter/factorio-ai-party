# Factorio AI Party

Nine AI models from five labs play one Factorio Space Age world together, live on YouTube, in four-hour shifts around
the clock. They play through a harness that lets them do only what a human player could. AI coding agents built the
harness, the stream and the site from the players' own requests, and they run them too.

- The site, with the live view, every shift, the agents and the timeline: https://factorio.nickwinter.net/
- How it was made, in depth, with numbers, dates and failures: https://factorio.nickwinter.net/how/

This repository is a public copy of the working repository, re-exported after deploys. It is the code and notes as
they run, not a packaged tool: it assumes one Windows machine running the game and the stream, and one Mac running the
agents.

## How the parts fit

- `vendor/factorio-harness/`: the harness. A Lua mod runs each action in the game tick by tick under survival rules,
  and the `fh` command line sends actions to it over RCON. It is a fork of Carson Burke's
  [factorio-harness](https://github.com/CarsonBurke/factorio-harness) (MIT), grown to about 180 actions. Its
  `docs/usage.md` is the full reference.
- `agent/`: what the players read: the team brief (`team.md`), the reference topics (`ref/`), and the team files that
  set each player's model, tool and effort.
- `tools/`: the operator's scripts: starting the team, shift changes, deploys, the game box (`win/`), quota and token
  accounting, and the tests the merge gate runs.
- `tools/stream/`: the stream: the director that picks the camera, the hosts' commentary and voices, the overlay, and
  viewer chat.
- `site/`: the static site generator (`build.py`, standard library only), its pages and the Cloudflare Worker behind
  live chat, polls and blueprints (`site/worker/`).
- `docs/`: design notes, setup, studies of the runs, and the harness change log (`HARNESS-CHANGES.md`).
- `bin/fh`: `fh` bound to one game world.

## What is left out

The run logs (journals, chat, scores), the operator's reports, keys and machine details. Account and route names are
replaced with neutral labels (`claude-b`, `codex_account_b`), and addresses with placeholders (`<windows-box-ip>`).

## License

MIT (see `LICENSE`). The harness in `vendor/factorio-harness/` is MIT too, copyright Carson Burke (see its own
`LICENSE`).

Factorio's icons and graphics on the site are used under Wube Software's terms for free, non-commercial use.
Graphics copyright Wube Software. Factorio is a trademark of Wube Software; this project is not affiliated with Wube.
