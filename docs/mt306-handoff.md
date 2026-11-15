# mt306 handoff — resume without the old Mac or Codex session

Status at 19:05 PST, 2026-11-14: runtime work is tested through cp4; baseline is complete; matched after-bench is **pending**. mt307 still holds imac2 for r307 and restores it before handing it over. Keep this order. Do not treat mt306 as final or gate it until the after-bench is measured and reported. The operator, not this engineer, gates the final cp ref into main.

## What survives the move

All code and tests are on `mt/batch306`. The branch includes the report snapshot at `docs/mt306-report.md`, portable native bench scripts in `tools/mt/mt306`, and compact baseline evidence in `tools/mt/mt306/evidence`. No old worktree, build directory, ignored dependency link or Codex session is needed. Create a fresh worktree from the carried branch; a stale worktree registration in the copied Git metadata is not an existing directory on chonk. Use the project-layout conventions and a different unused path if necessary; do not remove old registrations blindly.

The main Git repository on the old Mac is `/Users/owner/code/player-of-games`; its Git directory owns all the branch/cp refs. The old mt306 worktree is `/Users/owner/code/personal/player-of-games/worktrees/pog-mt306`. It does **not** move. Do not follow absolute old-worktree paths from historical logs.

Non-reconstructible artifacts have been copied into the explicitly migrating operator directory:

- `/Users/owner/code/pog-operator/mt306-artifacts/baseline`: canonical save, raw profiles/calls, measurements, original helper snapshots and validation logs. `MANIFEST.json` records each file's byte count and SHA-256. Log command-line RCON secrets were redacted before copying. Frozen helper snapshots here are provenance; run the portable branch scripts instead.
- `/Users/owner/code/pog-operator/mt306-artifacts/lua-5.2.4.tar.gz`: compiler source, SHA-256 `b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b`. Rebuild for chonk rather than copying an executable from the old architecture. The same source is available at https://www.lua.org/ftp/lua-5.2.4.tar.gz .
- `/Users/owner/code/pog-operator/report-mt306.md` and `handoff-mt306.md`: current operator state. Update both these and the tracked report after native work.

Canonical save: `mt306-joined-cold-cp31.zip`, SHA-256 **1fc4ea6fde7fc541f8532f177c49c8ba5f49a6c116e538ebe71943e37acb38c9**. A second copy remains on imac2 at `/Users/owner/pog-mt21/data/saves/mt306-joined-cold-cp31.zip`. If the local operator copy is absent, retrieve that exact remote file after coordinating access and verify the hash. Never silently substitute a later save. Generated Lua bundles and cp31 module exports are reproducible from the refs; they were not carried as prerequisites.

Credentials are deliberately outside the branch/evidence: working SSH access to `imac.local`, and the existing private RCON password file (`~/.config/pog/rcon-imac2.pw`, normally linked to rcon-imac-mt.pw) are prerequisites. Provision them through Nick's normal machine setup; never print or commit them.

## Refs and measurements

- Baseline: `mt/batch290-cp31` = `bd280b33f51eba5d48704a852ff4af1692ac87ad`.
- Runtime optimization: `mt/batch306-cp4` = `0d364d6728f4867739b4f045f10acf0baf10e3e7`.
- cp4 compact bundle: `a661876e7ce841df`, 7,145,724 bytes. Baseline bundle: `a0e094d157c52007`, 7,144,403 bytes.
- Main through `fbe96e6c4` was merged for the migration checkpoint. It changed no harness Lua relative to the prior main merge. Merge newer main again before the final checkpoint if needed.
- Migration checkpoint `mt/batch306-cp5` includes portable bench/ownership tools and this handoff; use the current `mt/batch306` tip and latest `mt/batch306-cpN` ref. No engineer push or gate.sh was run. The operator pushed all branches at 18:30; later checkpoints still need inclusion in the final transfer/private push.

Changes: cached immutable production-leg engine version/shared ledger per tick; O(1) engine force counts for research; empty-belt census shortcut; direct network surface lookup; existing persisted background jobs for cold network/alert reads; preserved pending cursors; cached alert sight rendering; integer alert-cell keys; netmap walks live planet associations instead of every platform. Cold reads may explicitly report pending until complete. Every force retains its old scan cadence. No new require or gameplay rule change.

Baseline with four joined-but-disconnected players, 12 stand-ins at 0.9 calls/s each, 22 platforms initially / 30 during all-at-once:

| Metric | Stand-ins | All-at-once |
|---|---:|---:|
| Tick ms/game-s, full-boundary average | 266.74 | 288.31 |
| Total harness ms/game-s | 331.61 | 348.62 |
| Worst tick bucket | 533.52 | 620.35 |
| UPS median/min, 5s intervals | 60.0 / 24.7 | 60.0 / 56.7 |
| Heap MB, legacy collector bounds | 289–766 | 317–780 |

Cold peak total: 2,191.69 ms. Worst cold buckets: research.shift_block 1,056.03 ms, board.team 486.80, dispatch status 401.26, networks.alert_groups 307.59 (aggregate parts, not individual calls).

GC 200/200, 150/200, 150/400, 120/400 all exceeded 500 ms/s peak; lower pauses increased average cost. **No new default chosen.** Baseline original/restored setting is 200/200. Gross allocation without detailed profiling remained 27,722 KB/game-s. Productionlegs and netmap were the largest attributable tick sources. The approximately 300 ms/s target is not established.

Important measurement pitfall: old `window_stats` selects bucket start ticks and omits the first partial bucket. The branch's `audit_boundaries.py` includes both boundary fragments, sums their actual tick counts, and normalizes averages by that count. Use its values for both before/after; peaks above are unchanged. Keep legacy output too. Profiles have a 20,000-line cap: use 60-second workload windows; reject dropped/incomplete windows. GC uses bounded 120-second windows whose completion was verified. There is only one active profiler.

## Offline rebuild and verification

Use a Python 3 interpreter for the stdlib-only helpers; no new virtual environment is required. In the fresh checkout run the harness's declared npm install/build workflow (its old ignored node_modules/dist cannot be assumed to exist). Compile the preserved Lua source with `make macosx`; set `LUA_BIN` to that build's `src/lua`. Confirm `lua -v` says 5.2.4 and use its sibling `luac`.

```sh
set -e
export LUA_BIN=/absolute/path/to/lua-5.2.4/src/lua
(cd vendor/factorio-harness && npm ci && npm run build && LUA_BIN="$LUA_BIN" npm test)
python3 tools/test_lua52_syntax.py
python3 tools/test_brief.py
python3 -m unittest discover -s tools/mt -p test_perf_bench.py
python3 -m unittest discover -s tools/mt -p test_mt306_handoff.py
```

cp4 passed 799/799 harness tests under real Lua 5.2.4, including compacted module suites, all three raw/compact mt306 fixtures, full-bundle luac parsing, syntax and brief checks. The portability changes do not modify harness Lua. Six handoff/ownership tests cover import without credentials, atomic claim conflict, restoration requirement, changed claim, PID reuse, wake release and cold partial-bucket auditing.

## Exact after-bench procedure

Wait for mt307/operator's explicit release. An absent claim alone is not a handoff. Do not touch World n. No model agents, camera, streaming or setup-player joins are needed: the canonical save already has one LuaPlayer on each of the four forces. All commands run from the branch checkout. Use a **new** artifact directory/label for each attempt.

```sh
set -e
export MT306_ART="$HOME/code/pog-operator/mt306-artifacts/after-cpN"
export MT306_LABEL=after-cpN
export MT306_PASSWORD_FILE="$HOME/.config/pog/rcon-imac2.pw"
export MT_PASSWORD_FILE="$MT306_PASSWORD_FILE"
export POG_CLAIM_OWNER=eng-mt306
unset POG_FH_SOCKET FH_SOCKET
mkdir -p "$MT306_ART"
python3 tools/mt/mt306/server_guard.py claim --note 'operator released mt307; matched after-bench'
python3 tools/mt/mt306/server_guard.py backup
# Verify canonical SHA-256 before this command.
tools/mt/port21.sh server start "$HOME/code/pog-operator/mt306-artifacts/baseline/mt306-joined-cold-cp31.zip"
python3 tools/mt/mt306/server_guard.py capture-pid
POG_WORLD=imac2 bin/fh deploy --file vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua
```

Before measurement, use padlib.lua to verify paused=true, tick=82871732, base=2.1.24, 12 bots, four force player counts, and cold network/push state matching `evidence/canonical-start.json`; save a receipt. Record the exact ref, bundle ID/source SHA and current GC settings. **Do not run prepare_start.py on the canonical save again**: it starts another shift and is only the original fixture-construction recipe. Deployment must occur while paused, so first agent calls are profiled before caches warm.

```sh
set -e
python3 -u tools/mt/mt306/run_phase.py "$MT306_LABEL" standins --minutes 11.5 > "$MT306_ART/standins-driver.log" 2>&1
# Optional original equivalence probe, outside the profiles (LUA_BIN must be set):
python3 tools/mt/mt306/api_equivalence.py > "$MT306_ART/api-equivalence.log" 2>&1
python3 -u tools/mt/mt306/run_phase.py "$MT306_LABEL" all --minutes 8 > "$MT306_ART/all-driver.log" 2>&1
python3 -u tools/mt/mt306/run_gc.py > "$MT306_ART/gc-driver.log" 2>&1
python3 -u tools/mt/mt306/light_profile.py > "$MT306_ART/light-driver.log" 2>&1
for phase in standins all; do
  python3 tools/mt/mt306/summarize.py "$MT306_ART/$MT306_LABEL-$phase"
  python3 tools/mt/mt306/audit_boundaries.py "$MT306_ART/$MT306_LABEL-$phase"
done
python3 tools/mt/mt306/summarize_gc.py "$MT306_ART/$MT306_LABEL-gc.json"
```

`run_phase` uses the original collector-ready handshake, 60s windows/5s UPS and the exact twelve scripted stand-ins. All-at-once adds eight platforms, pods every five seconds, scripted hops every 45 seconds, turrets and a 300-iron trade. This is not evidence for native thruster behavior or a days-long run. Read phase errors, verify all child exit codes and market/pad outcomes, and distinguish inherited pre-start errors. Do not write cargo-pod forces. GC helpers restore their original settings in finally; explicitly recheck GC running and settings before closing.

Always save the final game/error evidence and complete profile log **before stopping**, since later server starts replace the log. Stop only owned local helper PIDs if interrupted. The lease receipt records the remote backup and exact captured PID/start time. A successful backup is required before launch; an incomplete backup is not a restoration source. If start failed before PID capture, inspect the owned process/receipt instead of guessing a PID. Restore can resume after a recorded successful stop if file restoration was interrupted.

```sh
set -e
python3 tools/mt/mt306/server_guard.py restore
python3 tools/mt/mt306/server_guard.py release
```

Release verifies restore/ports, atomically removes only the matching claim, and appends the requested ENGWAKE line to pog-operator/mt306-wake.jsonl. Do this before lengthy report work. Never release a failed restore as complete.

## Closeout or continuation

Fill the after column in both operator and tracked report, with cold calls, named parts, allocation, GC tradeoffs, normalized averages/peaks and coverage. If the ~300 ms target still fails, report that and use the new profile to identify the residual source; do not declare a days-long guarantee. mt307's rehearsal samples are supporting early-game evidence, not the large-base comparison. Request no new permissions for the already authorized after-bench once its slot is released.

codex-b is explicitly authorized for this task, but **stop and report if weekly use exceeds 70%**. Most recent checked live observation during handoff preparation was 33%; refresh/check freshness before more sustained work. Do not interpret a refresh lock timeout as zero usage. No Codex/Claude gameplay agents.

Before ending today: commit every useful source/measurement/handoff update, keep a current cpN ref, ensure main ancestry, update `/Users/owner/code/pog-operator/report-mt306.md` and `/Users/owner/code/pog-operator/handoff-mt306.md`, and state whether the checkpoint is final for operator gating. Keep raw new evidence beneath pog-operator so it moves. No public push or gate.sh.
