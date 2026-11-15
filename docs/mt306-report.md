# mt306 — harness headroom, operator d44

Updated 2026-11-14 12:49 PST. **Native cp31 baseline and GC sweep complete; imac2 restored and released at 12:40:45. Matched after-bench pending after mt307. Task not complete.**

## Migration checkpoint, 2026-11-14 evening

**Current continuation checkpoint: mt/batch306-cp5 (non-final).** Runtime unchanged from cp4; current main fbe96e6c4 merged with no harness Lua changes. Portable native drivers, ownership/restore helper, six migration tests, baseline summaries and this report/handoff are now tracked on the branch. Three collector tests also pass. The full runtime validation remains 799/799 under actual Lua 5.2.4.

The old worktree and family artifacts do not move. The canonical save and 90 evidence files were copied to /Users/owner/code/pog-operator/mt306-artifacts/baseline (106 MB total with Lua source), with per-file SHA-256 manifest and secret-redacted logs. Canonical hash reverified. Lua 5.2.4 source archive also preserved for a native chonk rebuild. No ignored node_modules/dist or old Codex session is required; compile/build from the carried branch.

Fresh-engineer entry point: docs/mt306-handoff.md on mt/batch306, mirrored at /Users/owner/code/pog-operator/handoff-mt306.md. Historical paths below identify original measurements; use the preserved baseline directory and tracked tools/mt/mt306 scripts for continuation. Do not run the old hardcoded-PID restore script from historical artifacts.

At handoff preparation mt307 still holds imac2; the matched after-bench follows its explicit release. Current live codex-b observation: 33%, below the >70% stop threshold. No server access was made during migration preparation. Baseline release at 12:40:45 remains the most recent mt306 release. The final checkpoint still needs the matched after measurements and an ENGWAKE release after restoring imac2.

## Ref and server coordination

- Branch `mt/batch306`, current non-final checkpoint **`mt/batch306-cp4` = `0d364d6728f4867739b4f045f10acf0baf10e3e7`**. cp3 (`3ca0ee39a8c8b92460770c645672b80ce5545c7d`) records the collector cap fix; cp2 (`9af7eec8f04a88a510a820be697f74ca46d6f8ea`) contains the earlier runtime changes. Previous offline checkpoint `mt/batch306-cp1` = `8ba886dd51703199cbf466bcc35d8c06b13adea7`.
- Base `mt/batch290-cp31` = `bd280b33f51eba5d48704a852ff4af1692ac87ad`.
- Worktree: /Users/owner/code/personal/player-of-games/worktrees/pog-mt306
- Artifacts: /Users/owner/code/personal/player-of-games/artifacts/mt306
- No push, main change, gate.sh, model agents, or world n access. imac2 claimed atomically at 11:49:26 PST and released at **12:40:45 PST**, within the 60-minute slot. Server stopped; both private ports free; prior save, mods, config, settings and whitelist restored and compared. Prior mt.zip SHA-256: c2ff265cda5e86f2dac15f2b490189f98e2395f0ebd017c8b4bc2ceb49d021d0. ENGWAKE release notice appended to /Users/owner/code/pog-operator/mt306-wake.jsonl.
- Restoration evidence: /Users/owner/code/personal/player-of-games/artifacts/mt306/restore-driver.log and server-release.json. The canonical cold save was also copied locally and hash-verified before release. mt307 has the next slot; no further server access until the operator frees the after-bench slot.
- Sampling request written: /Users/owner/code/pog-operator/note-mt306-sampling.md
- Slot acknowledgement: /Users/owner/code/pog-operator/note-mt306-slot.md
- codex-b weekly usage: 13% at start, **25% live after release**; stop threshold >70%. Snapshot: /Users/owner/code/personal/player-of-games/artifacts/mt306/quota-post-baseline.json

## Main integration and cp2

Operator lifted the secrecy/private-branch rules after main `f72c30929e9d1b6e7329075ea6c20b2ce67b4f83` went live. Merged that main into mt/batch306 as `25ff0e31`; ancestry is verified. The only conflict was equivalent math.floor forms in the networks fixture, resolved to main's version while retaining the surface-name lookup mock.

cp2 adds an upgrade regression fix: even an existing completed snapshot registers its playerless force for future background refreshes. Otherwise an old synchronous snapshot could remain indefinitely stale after installing the background-only reads. The added raw and compacted Lua 5.2 fixture confirms registration, preservation of the existing snapshot, and no synchronous entity queries.

Full merged harness suite with LUA_BIN pointing at actual Lua 5.2.4: **798 passed, 0 failed**, including main's expanded compacted-module suite. The later cache-registration edge case was checked with both raw and compacted new fixtures and the existing networks fixture. tools/test_mt304.py and tools/test_mt_launch.py also pass; the Python log contains inherited ResourceWarnings, not failures.

- /Users/owner/code/personal/player-of-games/artifacts/mt306/harness-tests-main-merge-lua52.log
- /Users/owner/code/personal/player-of-games/artifacts/mt306/main-merge-python.log
- /Users/owner/code/personal/player-of-games/artifacts/mt306/offline-main-merge-checks.log

cp2 is **not final**: matched optimized native timings and any GC default selection remain pending. Continue on mt/batch306; the operator gates the final cp ref into main when the task is done. No operator gate or public push was run here.

## Changes in cp1 (preserved through cp4)

1. **Production legs:** read immutable `script.active_mods.base` once per runtime; share the ledger across all ships in each tick. Keep per-tick direction watching and production boundary counters. The 2.1 migration remains once per state/version.
2. **Research first-shift block:** use the engine-maintained force-wide entity count for unlocked-building presence, with one technologies table per read. Preserve prototype-existence checks, researched-tech filtering, grouping and order. No surface traversal on the first reply.
3. **Census:** empty belts use the entity's total item count and skip transport-line objects and contents tables. Nonempty belts retain the previous accounting, including qualities and shared underground lines. Keep the previous force scheduling and work budget.
4. **Networks:** resolve each view step's surface by name; avoid repeated surface enumeration and duplicate force-player table reads. Runtime cold reads request persisted background jobs instead of synchronously scanning the whole force. A playerless force joins the scan on request, including after an empty player map has completed.
5. **Push alerts:** use integer formatting for frequently built chunk/area keys, preserving negative-coordinate spelling. Cold runtime reads wait for paced background jobs. Pending reads do not advance alert cursors or consume digest markers.
6. **Board/status:** reuse sight text from a completed alert snapshot; copy the small rendered line list for callers that append coverage. A new snapshot invalidates the text. Live coverage remains live.
7. **Bench instrumentation:** stand-ins now log startup status/queue calls separately from steady calls. The load collector keeps raw UPS intervals and per-window UPS, excluding intervals crossing a window boundary.

Completed snapshot fields and gameplay rules remain unchanged. A first network/alert reply may now explicitly say `pending: true` until its first complete snapshot exists. This is documented; an incomplete scan is never published as a completed empty result. No new Lua require.

Review caught and removed a proposed one-force-per-tick shortcut: it would multiply sparse census band-walk duration by the force count. All forces retain the previous pacing; the cold-read improvement comes from using the existing stepped jobs.

The API documents `LuaForce.get_entity_count` as an engine-maintained O(1) count by prototype, without a quality restriction:
https://lua-api.factorio.com/latest/classes/LuaForce.html#get_entity_count

## cp4: native-driven netmap allocation reduction

The native attribution probe measured netmap.tick at 3,442 KB/game-s. Its idle step enumerated all surfaces, including 30 platforms, allocated a list and closures, and sorted it every three ticks even while no planet map was due. It now walks the live `game.planets` associations and picks the oldest eligible surface with explicit index ties. No membership cache or refresh delay; creation, association and deletion remain visible on the next idle step. The force lookup is deferred until an actual job step.

The new counted fixture passes against both cp31 and optimized code: 600 ticks / six planets / 30 ships reduce whole-surface enumerations **200→0**, surface.planet reads **7,200→0**, idle force reads **200→0**, sorts **200→0**; the new loop reads planet.surface 1,200 times. It also checks equal-age ordering, exact retry boundaries, failed census retries, differently named associations, deleted surfaces, and persisted jobs across module reload. The existing netmap snapshot fixture remains intact with a game.planets mock added.

The engine API documents the one-to-one live association used here:
https://lua-api.factorio.com/latest/classes/LuaPlanet.html#surface
https://lua-api.factorio.com/latest/classes/LuaPlanet.html#associate_surface

Full harness suite with real Lua 5.2.4: **799 passed, 0 failed**, including compacted-module suites. All three mt306 fixtures pass raw and compacted; both whole bundles pass luac -p; Lua 5.2 syntax, brief and three collector tests pass. No new require. Main f72c3092 remains an ancestor; worktree clean at cp4. Evidence: harness-tests-netmap-lua52.log, netmap-before.log, netmap-after.log, mt306_netmap_test-compact.log and offline-netmap-checks.log in the artifact directory. Native benefit of cp4 remains unmeasured until the after slot.

## Counted before/after (Lua 5.2.4, not native timings)

The same new fixture runs against cp31 module exports and cp1 modules. These counts demonstrate removed work; they do not predict Factorio wall time or prove the 300 ms/s target.

| Fixture / operation | cp31 before | cp1 after |
|---|---:|---:|
| 32 parked ships × 600 ticks: active_mods reads | 78,000 | 0 after construction |
| Same: state lookups | 39,000 | 600 |
| Same: production-counter reads | 0 | 0 |
| 3 research summaries × 32 surfaces: surface counts | 2,240 | 0 |
| Same: force counts / technologies table reads | 0 / 138 | 70 / 3 |
| 10,000 empty belts: line objects / contents tables | 20,000 / 20,000 | 0 / 0 |
| 600 network slices × 32 surfaces: name reads | 19,201 | 1 (plus 600 direct lookups) |
| 10,000 alerting labs: fast integer key formats | 0 | 20,000; identical group key/count |
| 12 board/status sight readers × 1,000 cells: sorts | 24 | 2 |

Cold fixture: twelve readers perform **zero entity queries** in their calls; no completed empty snapshot or alert cursor is stored. After a runtime reload mid-job, the playerless force's network and alert snapshots complete at tick **134**, with 11 total background queries and the expected no-power network warning. The fixture first builds an empty joined-player map, exercising late first-request invalidation. Every one of four forces walks 300 empty census bands in 600 ticks, preserving the old cadence.

Evidence:
- /Users/owner/code/personal/player-of-games/artifacts/mt306/counted-before.log
- /Users/owner/code/personal/player-of-games/artifacts/mt306/counted-after.log
- /Users/owner/code/personal/player-of-games/artifacts/mt306/cold-after.log

## Native comparison — completed cp31 baseline

Started the clean mt301 split with cp31 mod files, then deployed the exact cp31 bundle (7,144,403 bytes; source SHA-256 83259c9cc7533e4ae6e8804016f74a3ec78ebba515e3917001dea8f47bcf2ce1). All four setup players joined in 41 seconds each and disconnected. The canonical fixture has 12 bots, 28 surfaces, 22 platforms, and Nauvis entity counts red 14,173 / blue 15,832 / green 14,447 / yellow 13,173. No model agents.

Paused, set shift 306, cleared network and push-alert snapshots/jobs, and saved the same cold start to be used for the after run. Native canonical save:
/Users/owner/pog-mt21/data/saves/mt306-joined-cold-cp31.zip
SHA-256: 1fc4ea6fde7fc541f8532f177c49c8ba5f49a6c116e538ebe71943e37acb38c9

A collector-ready handshake starts profiling while paused, then unpauses and launches stand-ins. The saved baseline-source bundle and the host collectors remain fixed for the comparison. The ready wrapper adds only a host-side ready file and explicit end ticks to the normal load collector; it does not change the mod. The 8-minute all-at-once phase and GC/allocation probes followed the 11.5-minute stand-in phase.

Initial diagnostic run (not the final baseline; 300-second windows hit the 20,000-line cap, so the run was restarted from the canonical save with 60-second windows): startup worst total harness second 2,069.6 ms; research.shift_block 1,047.4 ms in a second; tick-only max 504.6 ms. These are provisional, not the completed baseline table. A source-save census error count of 3 predates the run (tick 82852994); track increases rather than attributing it to this run.



Historical columns are from mt302 section 3, **not reruns by mt306**. Both mt306 comparison columns use the same canonical split fixture with four disconnected joined players and twelve stand-ins at 0.9 calls/s each.

| Scenario / metric | Historical mt302 | mt306 cp31 rerun | mt306 after |
|---|---:|---:|---:|
| Stand-ins: harness tick ms/game-s | 266–275 | **266.74 average** | pending |
| Stand-ins: total harness ms/game-s | 327–339 | **331.61 average** | pending |
| Stand-ins: worst tick second | 515 ms | **533.52 ms** | pending |
| Stand-ins: UPS median / min | 59.9 / 46.4 | **60.0 / 24.7 (5-s samples)** | pending |
| Stand-ins: heap | 319–770 MB | **289–766 MB** | pending |
| First calls: worst total harness second | 2,156 ms | **2,191.69 ms** | pending |
| All-at-once: harness tick ms/game-s | 291.8–296.7 | **288.31 average** | pending |
| All-at-once: total harness ms/game-s | 350–366 | **348.62 average** | pending |
| All-at-once: worst tick second | 633–705 ms | **620.35 ms** | pending |
| All-at-once: UPS median / min | 59.9 / 59.2 | **60.0 / 56.7 (5-s samples)** | pending |
| All-at-once: heap | 315–777 MB | **317–780 MB** | pending |
| All-at-once: GC-finish tick seconds | about 450–470 ms | **360–435 ms window medians; 620 ms max** | pending |

Boundary audit: the older mt302 collector selects buckets by their starting tick, omitting the first partial bucket and retaining the last partial bucket. Its saved means are 264.27/327.76 ms/s (tick/total) for stand-ins and 286.38/346.21 for all-at-once. The table above instead includes **both boundary fragments and divides by actual profiled tick count**, giving 266.74/331.61 and 288.31/348.62. Peak values are unchanged. The first partial cold-start bucket was also checked: 846.44 ms total, below the reported 2,191.69 ms maximum. Reproduce this audit with audit_boundaries.py; results are baseline-matched-standins-boundaries-audit.json and baseline-matched-all-boundaries-audit.json. Use the same audit after optimization. Historical mt302 values retain their original collector convention.

The completed stand-in phase has 36,010 profiled ticks (600.17 seconds, including the profiler's endpoint ticks) in ten complete 60-second windows during 11.5 minutes of workload. Inter-window waits and the final tail are unprofiled; no profile lines were dropped. 7,416 calls (24 startup + 7,392 steady), two expected initial mine failures. The new UPS intervals are 5 seconds; historical intervals differ, so compare the raw/aggregated intervals when judging the startup minimum. Full evidence is baseline-matched-standins.json, .jsonl, .profile.log and -summary.json under the artifact directory.

The combined phase has 25,207 profiled ticks (420.12 seconds) in seven complete 60-second windows during eight minutes of workload, with no dropped lines. 5,146 calls, two expected initial mine failures. Eight additional platforms bring the total to 30. Four Nauvis pads each finished with 4,600 iron and 1,800 copper; four Vulcanus pads each had 950 iron. Scripted hops succeeded; 43 pods remained in flight. The 300-iron market trade delivered, with wallet/escrow audit conserving 240,000 credits and no faults. The final error snapshot contains only inherited survey/belt errors from ticks before the canonical start. Evidence: baseline-matched-all-summary.json, exercise-run.json and baseline-errors-end.json in the artifact directory.

| Named part, average ms/game-s (nested; do not sum) | Stand-ins | All-at-once |
|---|---:|---:|
| productionlegs.tick | 37.67 | 49.24 |
| pushalerts.tick | 33.84 | 33.72 |
| networks.tick | 23.10 | 28.30 |
| networks.view_tick | 18.90 | 21.40 |
| census.step | 27.23 | 25.21 |
| census.walk | 22.39 | 20.58 |
| pushalerts.band | 14.21 | 13.91 |
| board.team | 13.19 | 13.42 |

Native API equivalence probe: **96 building-presence checks across four forces, zero mismatches** between force.get_entity_count presence and the original surface searches. Of 1,000 sampled belts, 578 were empty; zero counter errors or false empties. Eight paired reads returned identical 7,646-item totals; median old line enumeration 3.343 ms versus empty-belt guard 2.576 ms, a **22.9% subroutine reduction in this sample**, not a whole-census gain. Evidence: api-equivalence.json and api-equivalence.log.

| Cold first ten seconds: worst named-part bucket | cp31 ms | Calls in bucket | Optimized |
|---|---:|---:|---:|
| part research.shift_block | 1056.03 | 6 | pending |
| part board.team | 486.80 | 6 | pending |
| dispatch status | 401.26 | 6 | pending |
| part networks.alert_groups | 307.59 | 2 | pending |

These are aggregate durations per game-second bucket, not a single-call latency. The slowest client startup call was 511.88 ms. Evidence: baseline-cold-parts.json and baseline-matched-standins.jsonl.

The historical first-call total includes dispatch work; it is a different metric from worst harness **tick** second. Report both. The all-at-once exercise uses scripted travel, pods, turret fire and one market fill, as mt302 did; it does not establish performance for real thrusters or a days-long run.

## Native GC and allocation measurements

Original pause/step multiplier **200/200**, restored and rechecked before shutdown. Each candidate ran for 120 game seconds with twelve stand-ins on the post-combined fixture. All windows completed with zero dropped lines. No setting was selected for production. This GC table retains the original collector bucket convention (unlike the boundary-audited workload table above); all raw profiles are preserved.

| pause / stepmul | Average tick ms/s | p99 tick ms/s | Worst tick ms/s | Heap MB |
|---|---:|---:|---:|---:|
| 200 / 200 | 277.47 | 473.80 | 605.80 | 323–775 |
| 150 / 200 | 283.05 | 527.58 | 555.81 | 310–756 |
| 150 / 400 | 287.76 | 496.52 | 541.91 | 287–573 |
| 120 / 400 | 285.03 | 443.39 | 502.32 | 283–555 |

Discarding the first 30 seconds per setting gives average/worst 277.63/605.80, 282.44/555.81, 289.08/541.91 and 285.74/502.32 ms/s respectively. Thus smaller pauses reduce heap and some tails here, while increasing average cost; **none meets the approximately 300 ms/s target**. This short sequential sweep does not establish a final default for a days-long run.

A separate five-second GC-stopped attribution sample measured about 32,088 KB/game-s overall and 26,448 KB/game-s inside tick. Largest nested sources were productionlegs.tick 7,316 KB/s, netmap.tick 3,442 KB/s, observe 2,892 KB/s, census.step 1,342 KB/s, board.team 1,162 KB/s and pushalerts.tick 1,134 KB/s. Nested values overlap and must not be summed; detailed profiler timers contribute allocations too. cp4 removes the newly measured netmap idle platform enumeration; its native allocation reduction will be measured in the after slot.

An outer-timer-only 3,600-tick probe measured **4.391349 ms/tick = 263.48 ms/game-s**. With detailed profiling disabled, a separate approximately three-second GC-stopped gross allocation sample still measured **27,722 KB/game-s**. Allocation pressure is real; these separate samples do not isolate a precise profiler overhead. GC was restarted and 200/200 settings restored after both allocation probes.

Evidence in /Users/owner/code/personal/player-of-games/artifacts/mt306:
- baseline-gc.json, baseline-gc-summary.json, baseline-gc.profile.log
- baseline-light-result.json, baseline-light.json
- baseline-server-complete.log.gz

The after slot reloads the same canonical fixture, deploys the tested optimized successor, repeats both workload phases, and measures GC again. The target remains no harness tick second over about 300 ms; **unestablished**. Further changes are driven by these measured allocation sources. No runtime changes were deployed during the baseline slot.

Prepared assets (cp31 deployed for baseline; optimized bundle remains offline):
- cp31 mod: /Users/owner/code/personal/player-of-games/artifacts/mt306/baseline-src/vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua
- cp31 compact bundle: /Users/owner/code/personal/player-of-games/artifacts/mt306/baseline-bundle.lua — ID `a0e094d157c52007`, 7,144,403 bytes.
- Current cp4 compact bundle: /Users/owner/code/personal/player-of-games/artifacts/mt306/offline-bundle.lua — ID `a661876e7ce841df`, 7,145,724 bytes. The offline check script rebuilds this path from the current branch.
- mt302 exercise adapted for this claim/tree: /Users/owner/code/personal/player-of-games/artifacts/mt306/exercise.py and /Users/owner/code/personal/player-of-games/artifacts/mt306/padlib.py

## Validation

- Full harness `npm test`: **798 passed, 0 failed**. /Users/owner/code/personal/player-of-games/artifacts/mt306/harness-tests-offline.log
- Actual Lua 5.2.4: both new fixtures pass against raw and compacted changed modules; both full compact bundles pass luac -p. Existing targeted production-leg, research, alert, network and census fixtures also passed 5.2 checks during implementation.
- tools/test_lua52_syntax.py, tools/test_brief.py, git diff --check: pass.
- Three offline Python collector tests: pass (UPS boundaries, startup-call recording, and missing/interrupted/truncated profile detection). The native baseline exposed the 20,000-line profile cap; the collector now defaults to 60-second windows and marks incomplete coverage explicitly.
- Reproduction script: /Users/owner/code/personal/player-of-games/artifacts/mt306/check-offline.sh
- Check output: /Users/owner/code/personal/player-of-games/artifacts/mt306/offline-checks.log
- Lua executable: /Users/owner/code/personal/player-of-games/artifacts/mt304/lua-5.2.4/src/lua
- Standard npm harness tests use the installed Lua; explicit 5.2/compact checks above cover the new fixtures and changed bundle. No new dependency install.

Next action: run the matched after-bench from the canonical save with tested cp4 (or a tested successor) when the operator releases imac2 after mt307. Collect both boundary fragments, cold-call latency, native netmap/productionlegs allocations and the same GC candidates before deciding a default. Do not mark mt306 complete or advertise whole-harness native gains before that comparison.
