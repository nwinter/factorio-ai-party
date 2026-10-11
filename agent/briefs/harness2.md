# Engineer task: honest waits, clearer game messages, a labs view (branch eng/harness2)

The shake1 transcript study (`docs/studies/shake1-transcripts.md`, sections 4 and 5) found where the harness misled or
slowed the agents. Another engineer (branch eng/board) is changing the `fh` output shape at the same time: lossless
`chat`, `error:` as the last line with a nonzero exit, compact `--wait` replies, the time-left on the `clock:` line,
`say` from stdin and a `voice` profile field. Stay out of those; your side is mostly the Lua mod.

Do, in this order (P2 items 7, 8 and 10 of the study):

1. Real waits. `wait_until` takes its timeout from fh's `--wait-timeout` (up to 15 minutes) and reports hitting the
   cap as `timed_out` in its main line; `wait_ticks` becomes a direct timed action (or leaves the direct list in
   `describe`); add `fh sleep SECONDS` that lets the game run and returns early with the reason if the agent's
   character takes damage or a message mentions it (coordinate the mention check with eng/board's `team` block).
2. Messages that told agents the wrong thing:
   - the power warning only when some machine is low_power or unpowered, phrased like
     `power: 3 of 78 machines low_power; 1 unconnected`;
   - `move_to` that ends `arrived_near` is a success (exit 0);
   - `build` waits for a queued hand-craft of the same item (or add `craft --wait`);
   - footprint and `collect` refusals name the other player and the chest's claimant;
   - `inspect` works read-only at visible range, as `scan` does;
   - `transfer` from corpses (mind BOTS-NOTES: mine_entity on a corpse segfaults the server; take items without it);
   - fix stale examples in `bridge.md` and `docs/usage.md`.
3. A `labs` read: each lab's missing packs and input state, which feeders (inserters, belts) are idle or starved and
   why, research progress and ETA. One compact line per lab group, bounded output.

Context: `docs/SETUP.md`, `docs/BOTS-NOTES.md`, `vendor/factorio-harness/docs/architecture.md`, the study's error
appendix. Bots are addressed by name (`fh --bot NAME`); players by index.

Rules: survival rules unchanged (no teleport, no free items); keep per-tick cost bounded (9+ agents); new code in
sibling modules (runtime.lua is near Lua's 200-local limit); prefer runtime-only changes so live worlds can
hot-deploy, and say so if control.lua must change. Every behavior gets a fake-engine test; `npm test` and all
`lua tests/*.lua` stay green. Verify live on world `live` (docs/SETUP.md; recreate it with `tools/win/*.ps1` via
`tools/winps.sh`; bots via `remote.call("agent_harness","bot_create",name)` through `tools/pog.py --world live rcon`;
a director client keeps the server from auto-pausing). eng/board also verifies on `live`: use bot names starting
with `h2-` and do not stop or recreate the world while it is in use there (check `fh call profiles`). Never touch
worlds a, b, c or n. Update `vendor/factorio-harness/docs/usage.md` for every changed action. Commit to eng/harness2 in
small commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; do not push or touch main.
Write `docs/HARNESS2-NOTES.md` (what changed, verification, gaps). Stop by the deadline in deadline.txt.
