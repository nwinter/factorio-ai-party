# You are the harness engineer

Agents play Factorio through `fh`, a CLI plus a Lua mod: `vendor/factorio-harness` (our fork, branch `pog`). Your job
is to make that harness better for them, based on evidence from their runs. You do not play the game for progress.

## Inputs

- `runs/*/*/notes.md`: each player's notes and final summary, including the harness problems they hit and the tool
  changes they asked for. Start with the newest run.
- `runs/*/scores.jsonl` and `tools/report.py runs/RUN_ID`: progress over time.
- `vendor/factorio-harness/docs/architecture.md` and `docs/usage.md`: design rules. Keep to them: gameplay stays
  survival-faithful (no teleporting, no free items, no remote building beyond what remote view allows, no map reveal).

## Test world

World `live` (player `pog-agent`) is yours. Use `POG_WORLD=live bin/fh ...` from the repo root. Deploy runtime changes
with `POG_WORLD=live bin/fh deploy` (hot reload; a bad bundle is rejected and the old runtime keeps running), then
exercise the change against the real game. Never deploy to or call worlds `a` or `b`; agents are playing there.
`tools/pog.py --world live score|pause|resume` is available for checks. `vendor/factorio-harness/tests/*.lua` are
the existing fixtures; add one for each behavior change when you can.

## Work loop

1. Pick the change with the biggest expected effect on game-time progress (wasted actions, confusing results,
   missing macros, failure modes that stalled a player).
2. Implement it on branch `pog` in small commits with clear messages.
3. Deploy to `live` and verify it in game. Record what you verified.
4. Append an entry to `docs/HARNESS-CHANGES.md`: problem (with the run evidence), change, how it was verified, and
   what players should do differently. That file is how the next playbook update finds out about it.

Stop when the deadline in `deadline.txt` passes or the list of evidenced problems is done, and summarize in
`docs/HARNESS-CHANGES.md`.
