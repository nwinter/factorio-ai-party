# mt306 handoff — branch-only continuation on chonk

Runtime checkpoint: **mt/batch306-cp7 = 207aebf440b37c66d36af3388f4cc8e839525867**. **Final handoff checkpoint: mt/batch306-cp8.** It includes the measured report and evidence; the runtime is unchanged from cp7. The operator gates it into main; this engineer does not run gate.sh or push. Main fbe96e6c4adfd41594fbec70e9794053c87a8c9b is already an ancestor.

The complete result, table and limitations are in **docs/mt306-report.md**, mirrored at /Users/owner/code/pog-operator/report-mt306.md. The approximately 300 ms/game-s tick peak objective and complete removal of cold status latency remain unachieved. No GC default change is installed. Do not represent the short native exercise as a days-long guarantee.

imac2 was claimed atomically at 2026-11-14T19:14:24.997844-08:00 and restored/released at **2026-11-14T20:13:26.250554-08:00**, within 60 minutes. The exact owned PID was stopped; prior mt.zip, mods, config, settings and whitelist were restored and compared; both private ports were free. Prior/restored save SHA-256: c2ff265cda5e86f2dac15f2b490189f98e2395f0ebd017c8b4bc2ceb49d021d0. ENGWAKE was appended to /Users/owner/code/pog-operator/mt306-wake.jsonl. The durable receipt is /Users/owner/code/pog-operator/mt306-artifacts/after-cp5/server-lease.json. The final named save was copied and hash-verified into that directory. GC was checked running at 200/200 before shutdown.

## Files that survive

All source, tests, portable bench/ownership/analysis tools and compact evidence are on mt/batch306 in the main Git repository, /Users/owner/code/player-of-games on the old Mac. Old worktrees under /Users/owner/code/personal/player-of-games/worktrees do not move. Create a new worktree from the carried branch on chonk; do not assume an old worktree registration names an existing directory. No old Codex session, ignored dist/node_modules, external build artifact or old absolute worktree path is required.

Non-reconstructible evidence is in the migrating operator directory:

- /Users/owner/code/pog-operator/mt306-artifacts/baseline: canonical save and complete cp31 raw evidence, with SHA-256 manifest.
- /Users/owner/code/pog-operator/mt306-artifacts/after-cp5: the historical lease directory. **after-cp7-* files are the final matched measurements.** Earlier after-cp5, after-final and after-cp6 files are rejected pilots exposing cold terrain latency, pacing and missing-draw errors. Do not average them into the final table.
- /Users/owner/code/pog-operator/mt306-artifacts/lua-5.2.4.tar.gz: compiler source, SHA-256 b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b. Rebuild for chonk's architecture. Upstream source: https://www.lua.org/ftp/lua-5.2.4.tar.gz
- /Users/owner/code/pog-operator/handoff-mt306.md: mirror of this handoff.

Canonical save mt306-joined-cold-cp31.zip SHA-256 **1fc4ea6fde7fc541f8532f177c49c8ba5f49a6c116e538ebe71943e37acb38c9**. It begins paused at tick 82871732, Factorio 2.1.24, 12 stand-ins, four joined-but-disconnected players, 28 surfaces / 22 platforms. Never silently substitute a later save or re-run prepare_start.py: that script constructs the original fixture and starts a shift.

Baseline ref mt/batch290-cp31 = bd280b33f51eba5d48704a852ff4af1692ac87ad. Final runtime bundle ID **e8aae28b32362a0b**, 7,146,734 bytes, deployed source SHA-256 **e8aae28b32362a0b7641726105624f2f6444265487a5e905c5f7660055c0353e**. Deployment, source, initial-state and final-error receipts are preserved. Later final checkpoint changes only documentation, evidence and host analysis helpers.

## Offline rebuild and checks

Use Python 3 for the stdlib-only helpers. Build the preserved Lua 5.2.4 source with make macosx, then set LUA_BIN to its src/lua and confirm the version. In the new checkout:

```sh
set -e
export LUA_BIN=/absolute/path/to/lua-5.2.4/src/lua
(cd vendor/factorio-harness && npm ci && npm run build && LUA_BIN="$LUA_BIN" npm test)
python3 tools/test_lua52_syntax.py
python3 tools/test_brief.py
python3 -m unittest discover -s tools/mt -p test_perf_bench.py
python3 -m unittest discover -s tools/mt -p test_mt306_handoff.py
```

The final runtime passed 799/799 harness tests under real Lua 5.2.4, including all compacted Lua suites; raw/compacted mt306 fixtures and full-bundle luac parsing also pass. Three collector and seven ownership/handoff tests pass. New tests exercise sparse cold terrain, reloads, cap overflow, full-budget held lists, playerless registration, pending cursors, unchanged census cadence, alert cost pacing and sustained power when the first view predates sampling.

## Reproduce the report without server access

From the branch checkout, substitute the current operator path if the home directory changed:

```sh
set -e
mt306_before="$HOME/code/pog-operator/mt306-artifacts/baseline"
mt306_after="$HOME/code/pog-operator/mt306-artifacts/after-cp5"
for phase in standins all; do
  python3 tools/mt/mt306/summarize.py "$mt306_after/after-cp7-$phase"
  python3 tools/mt/mt306/audit_boundaries.py "$mt306_after/after-cp7-$phase"
done
python3 tools/mt/mt306/cold_parts.py "$mt306_after/after-cp7-standins"
python3 tools/mt/mt306/comparison.py "$mt306_before" "$mt306_after" --label after-cp7
python3 tools/mt/mt306/summarize_gc.py "$mt306_after/after-cp7-gc.json"
```

Workload averages include both partial boundary buckets and normalize by actual profiled ticks. Legacy collector means omit the first partial bucket and differ. Do not combine those conventions. Comparison.py verifies profile-completion markers and zero drops. Cold named-part buckets aggregate multiple calls; compare their call counts too. The GC baseline uses 120-second candidates, after uses 60-second candidates because of the release deadline; their maxima have different coverage. Allocation attribution is nested and must not be summed. The baseline outer-only timing/allocation probe was not repeated after the final restart.

## Remaining engineering work

1. Bound cold status's ground-alert, survey and threat subreads. Research/board improve substantially but status still contributes a startup hitch.
2. Cut residual census, push-alert, network and other allocations using the final attribution table. First network views may precede sampling; optional draw fields can remain absent until a later refresh, and the fresh network read remains available. The sustained-power alert now handles that state with a measured sample.
3. Measure longer GC candidates on the loaded fixture before changing production defaults. The old 200/200 is restored. A 60-second sweep is insufficient to establish a reliable tail bound.
4. Do any further matched native run only after a fresh operator slot, atomic claim, verified prior-state backup and exact PID/start receipt. World n is untouched. The actual rollout is three teams of two agents; this four-force/twelve-stand-in fixture is the requested mt302 stress comparison, not that rollout.

For a future native slot, tools/mt/mt306/server_guard.py owns atomic claim/backup/capture-pid/restore/release. All helpers derive repo paths from __file__; MT306_ART selects a fresh artifact directory, MT306_LABEL selects the run label, and MT306_PASSWORD_FILE selects the existing private RCON password file. No credential is stored in Git. Working SSH to imac.local and Nick's normal private credential setup are prerequisites.

Use tools/mt/port21.sh server start with the exact canonical save, capture the owned PID, deploy the branch runtime while paused, then stop/reload that paused deployed save and update the receipt's PID/start time. This removes transient upload garbage before the cold profile. Run run_phase.py LABEL standins --minutes 11.5, then all --minutes 8. run_gc.py defaults to 120-second candidates; --seconds 60 is the deadline-limited variant. Keep one profiler active. capture_end.py preserves errors/GC state, requests a named final save and copies the log before stop. Restore and verify prior mt.zip/mods/config/settings/whitelist before release; release appends ENGWAKE to mt306-wake.jsonl. Never use historical hardcoded-PID restoration scripts.

codex-b is authorized, with a hard stop if weekly use exceeds 70%. The final measured live usage was 36%, recorded in the report/evidence. The shared quota refresher can time out while holding its lock; do not kill other refreshers, remove their lock, or interpret stale data as zero. A read-only direct Codex rate-limit query reused the installed ai-usage adapter during this run.

All final refs were created after the operator's 18:30 private push, so ensure they are included in the main-repository transfer or the operator's later private sync. Nothing useful should remain only in the old worktree.
