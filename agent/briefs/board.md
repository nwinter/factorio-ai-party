# Engineer task: team board, reply hints, harness requests, saved plans (branch eng/board)

Implement the harness side of `docs/BOARD-API.md` in `vendor/factorio-harness` (Lua mod + `fh` CLI): the board
actions (`board`, `board_post`, `board_update`, `board_events`), the per-agent `team` reply-hint block (mentions,
board, attack/loss alerts, profile reminder), `harness_request`, and saved plans (`plan_save`, `plan_run`, `plans`),
plus `tools/harness-requests.py` (operator: list/answer harness requests over RCON). Another engineer builds the stream
overlay against the same contract on branch eng/stream2.

Context: read `docs/SETUP.md`, `docs/BOTS-NOTES.md`, `docs/studies/shake1.md` (why this is needed: unowned requests
went undone, nobody noticed the biter raid), and `vendor/factorio-harness/docs/architecture.md`. Bots are addressed by
name (`fh --bot NAME`); players by index. Attack data already exists in `threat.lua`/`survey.lua` (status shows
`alerts`); reuse it instead of new scans.

Rules: survival rules unchanged; keep per-tick cost bounded (9+ agents); new code in sibling modules (runtime.lua is
near Lua's 200-local limit); prefer runtime-only changes (no control.lua) so live worlds can hot-deploy, and say so
explicitly if control.lua must change. Every behavior gets a fake-engine test; `npm test` and all `lua tests/*.lua`,
`lua mod/tests/*.lua` stay green. Verify live on world `live` (see docs/SETUP.md; recreate it with `tools/win/*.ps1`
via `tools/winps.sh`; create a few bots with `remote.call("agent_harness","bot_create",name)` via `tools/pog.py --world
live rcon`; a director client keeps the server from auto-pausing). Never touch worlds a, b, c or n. Update
`vendor/factorio-harness/docs/usage.md` and add a short section for agents to `agent/team.md` (how to use the board,
plans and harness requests; keep it under 15 lines). Commit to eng/board in small commits ending with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; do not push or touch main. Write `docs/BOARD-NOTES.md`
(what was built, verification, gaps). Stop by the deadline in deadline.txt.
