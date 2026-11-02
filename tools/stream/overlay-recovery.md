# OBS overlay startup and watchdog

At a streamed shift change, `shift-change.sh` stops the previous team, restarts OBS, then calls
`start-team.sh` with `POG_OBS_RESTARTED=1`. OBS can load its saved browser source before the new
service or tunnel exists. A direct `start-team.sh --stream` starts `serve.py :8788` and the SSH
reverse-forward loop asynchronously, then restarts OBS unless already restarted. The loop forwards
pogwin `127.0.0.1:8787` to the Mac `127.0.0.1:8788`, retrying SSH after five seconds. `serve.py`
binds its listener after initializing its sources/helpers. The old fixed three-second sleep did
not prove readiness in either path; page-local fetch retries cannot repair a document that never loaded.

`obs-steps.sh` now calls `overlay_check.py prepare --wait 120` after scene setup. It fetches
`http://127.0.0.1:8787/state.json` **on pogwin**, using SSH and `curl.exe --fail --max-time 4`.
Only a JSON snapshot with `tick` and an `agents` array permits `reload-overlay`. Empty initial
snapshots, HTTP errors, a missing tunnel and SSH failures retry until the deadline. Each probe is
bounded by eight seconds, so an in-flight final probe can extend the deadline by that much.
`POG_OS_READY_WAIT` adjusts the startup wait. A timeout is logged; recording/stream startup still
proceeds, preserving existing output policy, and the watchdog can recover after readiness returns.

Startup, watchdog and the existing toggle/reload/toggle fallback share a durable, locked reload
budget at `<state>.reload`. The default state is `/tmp/claude-501/overlay-check.json`, overridable
with `POG_OC_STATE` or `--state`. Every reload waits at least `--again` seconds (default 600,
minimum 180) after the previous attempt, including failed or ambiguous requests. An unavailable
budget defers the reload. This budget survives service/OBS restarts and is reserved before sending
the command. Each attempted reload and its outcome is logged. Existing scene-item enable/toggle
and overlay-on-top checks remain; they do not bypass the refresh budget.

The existing operator watchdog calls `overlay_check.py watch`. Added signals:

- No OBS **main** page health report for 120 seconds, using batch408's server-side receive time.
  Before the first report, the grace period starts at service startup. Browser previews and
  portrait reports do not satisfy it. A page reporting state age >=120 seconds also fails.
- Two consecutive source PNGs of at most 2048 bytes, sampled at least 60 seconds apart. This is a
  near-empty-image heuristic, not proof of transparency. Screenshot errors do not trigger reloads.
  A healthy page-health report does not override repeated near-empty source images.

Either signal requests one readiness-gated, rate-limited refresh and records failure/pending
verification in watchdog state. The next healthy pass clears it. Existing stream/render and
composition checks continue. These checks do not prove final scene visibility; batch408's ordering
guard covers stacking separately. No game/RCON reads were added.

Cost: at most one `GetSourceScreenshot` per 60 seconds of watchdog passes, 480x270 PNG, source
`stream overlay`, websocket timeout three seconds, automatic request retries disabled. The state
stores byte count and wall time, not the image. One read-only sample on shift121 measured 31.3 ms
and 54,714 PNG bytes (~73 KB base64); it was healthy. This is one observation, not a latency bound
or OBS GPU benchmark. The current operator `watch-run3.sh` sleeps 120 seconds between passes, plus
the time spent checking, so in practice screenshots are at least 120 seconds apart; two-sample
detection takes two watchdog passes. Sampling later than 60 seconds follows that cadence. Health
uses the already-fetched `/overlay/status`; a recovery adds a remote readiness probe.

Tests: `tools/test_overlay_guard.py`, `tools/test_overlay_check.py`, `tools/test_overlay_blank.py`,
`tools/test_obs_restart.py`. `POG_OC_READY` emits state JSON or fails; `POG_OC_SHOT` emits an OBS
`imageData` response; `POG_OC_OBS` replaces mutations. The new tests use fake time and stubs for
late service, late tunnel, initial empty snapshot, missing/stale health, near-empty capture,
cooldown (including failed requests) and sample frequency. No live reloads are used in these tests.
