# Final push countdown (batch450)

`serve.py` rereads the current run directory's `target.json` each snapshot through
`target_countdown.facts`. It uses `tools/run_target.py`'s existing timezone parser
and exports only `run_target: {goal, at, at_epoch}` (or null). No game reads or
target writes. The existing target carry at shift startup remains authoritative.
Invalid/partial/missing files clear the display without breaking the ticker.

The overlay and site's live pages use `static/target-countdown.js`. The clock says
“Final push in 5 h 12 min” with the goal verbatim below it; at the exact target
second it changes to “Final push under way · 0 min elapsed”. This is the planned
push time, not an arrival receipt, game ETA or run-end condition. Seconds count
wall time even while the game is paused. Under a minute is “< 1 min”; elapsed
minutes round down. Goal/time changes and clearing apply on the next snapshot
or site push/poll. An open page ticks every second without needing a reload.

The overlay panel sits in sidebar flow, outside all camera holes (landscape:
below the header; portrait: below the camera spacer, above the agents). It cannot
cover bow/gun/action closeups, telemetry, captions, alerts, or insets. It takes a
small amount of chat height. Unusually long goals clamp to two lines on stream;
the full goal/time remain in the title, and the site wraps the complete goal.
No camera positioning, batch428 clearance, or batch444 telemetry policy changes.

Lost snapshots hide the overlay countdown after 90 seconds. The live site clears
it on a failed fetch or a stale response (>60 seconds under its existing live
policy), with a 90-second timer backstop. Old snapshots with no run_target clear
it too. A fresh snapshot restores it. Nothing is persisted in browser storage.

Boundary activation: restart the stream-service and site-live pusher with their
normal next-shift run arguments; reload both OBS browser pages; rebuild/publish
the static site (the build copies and versions the shared script). No Worker,
game/harness, OBS process, encoder or camera-client restart is required by this
batch. The operator's separate planned reboot is independent. Reverting this
batch's implementation commit and repeating those steps removes it. Clearing
target.json also hides it but changes the team's target, so is not a UI rollback.

Offline checks: `tools/stream/test_target_countdown.py`,
`site/test_target_countdown.py`, and the existing stream/site suites. The optional
real-service fixture accepts `--target-run DIR` to exercise actual file edits and
clearing through the composed browser pages without any game connection.
