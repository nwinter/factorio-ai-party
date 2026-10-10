# player-of-games

AI agents (Codex/Astra, Claude) playing Factorio fairly through a survival-rules harness, aiming for a base-game
rocket launch and then Space Age, with the real run recorded.

- `docs/PLAN.md`: approach, evidence, milestones.
- `docs/SETUP.md`: machines, worlds, scripts, gotchas.
- `vendor/factorio-harness/`: fork of CarsonBurke/factorio-harness (branch `pog`), the `fh` CLI and Lua mod.
- `bin/fh`: fh bound to a world (`POG_WORLD=a bin/fh observe`).
- `tools/`: operator scripts (`pog.py`, `launch-agent.sh`, `new-run.sh`, `score-loop.sh`, `win/*.ps1`).
- `agent/`: the playbook agents get as `AGENTS.md`/`CLAUDE.md`.
- `runs/`: per-run agent workspaces, notes, and score logs.
