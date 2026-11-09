# OBS overlay startup and watchdog

At a streamed shift change, `shift-change.sh` stops the previous team, restarts OBS, then calls
`start-team.sh` with `POG_OBS_RESTARTED=1`. OBS can load its saved browser source before the new
service or tunnel exists. A direct `start-team.sh --stream` starts `serve.py :8788` and the SSH
reverse-forward loop asynchronously, then restarts OBS unless already restarted. The loop forwards
pogwin `127.0.0.1:8787` to the Mac `127.0.0.1:8788`, retrying SSH after five seconds. `serve.py`
binds its listener after initializing its sources/helpers. The old fixed three-second sleep did
not prove readiness in either path; page-local fetch retries cannot repair a document that never loaded.

`obs-steps.sh` calls `overlay_check.py startup --wait 180 --render-wait 30`. Before
any scene setup or refresh, it fetches `http://127.0.0.1:8787/state.json` **on pogwin**,
using SSH and `curl.exe --fail --max-time 4`. Only a JSON snapshot with `tick` and an
`agents` array passes. Each probe and elapsed time is logged. Empty initial snapshots,
HTTP errors, missing tunnels and SSH failures retry until the deadline, with a final
readiness probe at timeout. Each probe is bounded by eight seconds, so the final two
probes can extend the deadline by up to sixteen seconds. `POG_OS_READY_WAIT` adjusts
this wait. Nothing reloads while the gate is closed, including scene setup's former
implicit `refreshnocache` (removed). OBS itself can load its saved browser source when
it restarts; that is not proof of readiness.

After the gate, startup sets the scene and overlay order, enables the source, then
requests a refresh. It requires a main-page connection and render report at or after
the refresh attempt within `POG_OS_OVERLAY_WAIT` (default 30 seconds). Missing status
is not a successful check. A blank page gets one more readiness-gated refresh and
render check. The existing render report proves page drawing, not final program pixels;
the watchdog's source screenshots and composition checks remain independent evidence.

Startup and watchdog use the durable, locked budget at `<state>.reload`. The default
state is `/tmp/claude-501/overlay-check.json`, overridable with `POG_OC_STATE` or
`--state`. The ordinary cooldown is `--again` (default 600 seconds, minimum 180).
Startup has exactly one exception: the same invocation can retry its own first
reservation once. A random invocation token and consumed-retry bit are persisted
before OBS, including failed/ambiguous calls. Another startup or the watchdog cannot
reuse the exception. Cooldown runs from the last attempt. An unavailable budget
defers reloads. Legacy `prepare`/`start` and watchdog recovery keep their ordinary budget.

An unresolved overlay or stream-service outage produces `health: DEGRADED`, exit 0
when required startup checks pass, an Operator site-chat notice, and an operator change
log line. The final health line is also appended to the new run's `start.log`, which
existing `autopilot.sh` copies into its own log before starting `watch-run3.sh`.
No operator-script deployment is needed. Recording/stream output, agents, broker,
world startup/resume and harness failures retain their failure paths. A recovered
overlay at the final health check does not leave a stale degraded notice.

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

Tests: `tools/test_shift_overlay_start.py`, `tools/test_overlay_guard.py`, `tools/test_overlay_check.py`, `tools/test_overlay_blank.py`,
`tools/test_obs_restart.py`. `POG_OC_READY` emits state JSON or fails; `POG_OC_SHOT` emits an OBS
`imageData` response; `POG_OC_OBS` replaces mutations. The new tests use fake time and stubs for
late service, late tunnel, initial empty snapshot, missing/stale health, near-empty capture,
cooldown (including failed requests) and sample frequency. No live reloads are used in these tests.
