# mt306 — measured harness headroom for the 2.1 team run

Updated 2026-11-14 20:13 PST. **Final handoff checkpoint: mt/batch306-cp8**, ready for operator review/gating; runtime measured at **mt/batch306-cp7 = 207aebf440b37c66d36af3388f4cc8e839525867**. Both matched workload phases, the shorter after GC sweep, restoration and migration handoff are complete. Average tick work improves 12.3% with stand-ins and 14.8% all-at-once. **The approximately 300 ms/s peak target and full cold-status latency objective remain unmet.** The stand-in worst tick bucket rises from 533.52 to 681.81 ms in a GC-finish second; no new GC default is installed. This is a final measured checkpoint, not clearance that the days-long performance target is achieved.

## Implementation and preserved behavior

- Production legs cache the immutable engine version and share their ledger lookup within each tick; direction watching and production boundary counters retain their cadence.
- Research's first-shift summary uses the engine-maintained force entity count, preserving technology/prototype filtering and order. It reads the technologies table once per summary.
- Empty census belts skip transport-line objects and contents tables. Nonempty belts, qualities and underground-line accounting retain the original path. All forces keep the original census cadence.
- Network view steps resolve a surface directly and read a force's player list once. Cold runtime reads request persisted jobs and explicitly remain pending until a complete snapshot exists; playerless forces register on request, including upgrades with an existing snapshot.
- Cold map/view jobs make capped native queries per force/surface, then process bounded 150-entity slices. A query at the cap falls back to the ordinary band walk. This avoids minutes walking empty terrain before the first result. An overflow step may include the capped probe and the first band query; agent calls themselves make zero entity queries.
- Cold push jobs use the original total entity budget, one planet query per step, bounded slices and the original closing-step pacing. A list that exhausts the query budget is still processed. Alert cursors and digest markers are not consumed while pending. Warm jobs retain their band walks.
- Push-alert cell keys use integer formatting. Board/status sight text is rendered once per completed alert snapshot and copied into a small caller-owned list; live coverage stays live.
- Netmap's idle path walks live planet associations, preserving index ties and discovery/retry cadence while avoiding all-platform enumeration and sorting. Force lookup waits until a real job step.

No new require, action argument, gameplay rule or visibility change. The explicit pending result is the intentional cold-read interface change. A proposed one-force-per-tick census shortcut was rejected because it slowed sparse walks by the number of forces.

## Controlled native comparison

Baseline ref: mt/batch290-cp31 = bd280b33f51eba5d48704a852ff4af1692ac87ad. Final tested runtime: cp7 above. Compact bundle ID **e8aae28b32362a0b**, 7,146,734 bytes, deployed source SHA-256 **e8aae28b32362a0b7641726105624f2f6444265487a5e905c5f7660055c0353e**.

Both runs start at paused tick 82871732 from mt306-joined-cold-cp31.zip, SHA-256 **1fc4ea6fde7fc541f8532f177c49c8ba5f49a6c116e538ebe71943e37acb38c9**. Factorio base 2.1.24; four joined-but-disconnected setup players, one per force; twelve scripted stand-ins at 0.9 calls/s each. Nauvis entity counts: red 14,173; blue 15,832; green 14,447; yellow 13,173. Initially 28 surfaces and 22 platforms. No model gameplay agents and no world n access.

The 11.5-minute stand-in phase precedes eight minutes of all-at-once exercise. All-at-once adds eight platforms, scripted hops, cargo pods, turret fire and a 300-iron market trade. Deployment occurs paused, followed by a paused save/reload to remove transient upload garbage before profiling. The after initial heap was 287.56 MB. A collector-ready handshake includes the first calls. Only one profiler runs at a time.

| Scenario / metric | cp31 before | cp7 after |
|---|---:|---:|
| Stand-ins: tick ms/game-s | 266.74 | 233.81 |
| Stand-ins: total harness ms/game-s | 331.61 | 294.06 |
| Stand-ins: worst tick bucket ms | 533.52 | 681.81 |
| Stand-ins: worst total bucket ms | 2191.69 | 1037.72 |
| Stand-ins: UPS median / min | 60.0 / 24.7 | 60.0 / 53.4 |
| Stand-ins: heap MB | 289–766 | 279–770 |
| Stand-ins: profiled game seconds | 600.17 | 600.17 |
| Stand-ins: completed windows | 10 | 10 |
| Stand-ins: scripted calls | 7416 | 7391 |
| All-at-once: tick ms/game-s | 288.31 | 245.71 |
| All-at-once: total harness ms/game-s | 348.62 | 305.60 |
| All-at-once: worst tick bucket ms | 620.35 | 543.38 |
| All-at-once: worst total bucket ms | 697.84 | 646.98 |
| All-at-once: UPS median / min | 60.0 / 56.7 | 60.0 / 57.2 |
| All-at-once: heap MB | 317–780 | 336–790 |
| All-at-once: profiled game seconds | 420.12 | 420.12 |
| All-at-once: completed windows | 7 | 7 |
| All-at-once: scripted calls | 5146 | 5167 |

Tick averages change by -12.3% (standins), -14.8% (all). Total-harness averages change by -11.3% (standins), -12.3% (all).

The final workload has 7,391 stand-in calls and 5,167 combined calls; each phase has only the two expected initial mining misses, matching the baseline failure pattern. No new harness errors appeared through either workload. The inherited census error count stays at three, from tick 82852994 before the canonical start.

The combined exercise ended with 43 pods in flight, two turrets, all four Vulcanus pads holding 950 iron, and a delivered 300-iron trade. The market audit conserves 240,000 credits with no faults. Red/blue/yellow Nauvis pads each held 4,600 iron and 1,800 copper; green held 303 iron and 1,800 copper, versus 4,600 iron in the baseline. Thus the same traffic exercise ran, but the live pad inventories did not follow an identical trajectory; do not treat this as a bit-for-bit replay. Full counts and receipts are preserved in exercise-final-summary.json and exercise-run.json.

Averages include both partial boundary buckets and divide by actual profiled ticks. Historical mt302 and the saved legacy collector summaries use a different boundary convention; they are preserved but are not silently mixed with this table. All 17 reported workload windows have verified completion markers and zero dropped lines. Peaks are game-second buckets; UPS uses five-second wall intervals.

| Named part, ms/game-s (nested) | Stand-ins before | Stand-ins after | All before | All after |
|---|---:|---:|---:|---:|
| productionlegs.tick | 37.67 | 5.07 | 49.24 | 6.39 |
| netmap.tick | 5.72 | 5.03 | 5.78 | 5.23 |
| pushalerts.tick | 33.84 | 32.97 | 33.72 | 32.77 |
| networks.tick | 23.10 | 20.30 | 28.30 | 26.60 |
| networks.view_tick | 18.90 | 15.91 | 21.40 | 19.56 |
| census.step | 27.23 | 26.86 | 25.21 | 25.19 |
| census.walk | 22.39 | 21.94 | 20.58 | 20.65 |
| pushalerts.band | 14.21 | 13.62 | 13.91 | 13.40 |
| pushalerts.slice | 10.83 | 10.54 | 11.13 | 10.75 |
| board.team | 13.19 | 11.68 | 13.42 | 13.11 |

Named parts are nested; do not sum them. The native API equivalence probe found zero mismatches in 96 building-presence checks across four forces. Of 1,000 sampled belts, 578 were empty with zero false empties or count errors. Eight paired reads returned the same 7,646-item total; median line-enumeration time fell from 3.343 to 2.576 ms in that subroutine.

## First calls and remaining latency

| Cold first ten seconds | cp31 | cp7 |
|---|---:|---:|
| Worst total harness second | 2,191.69 ms | 1,037.72 ms |
| research.shift_block worst bucket | 1,056.03 ms / 6 calls | 43.31 ms / 10 calls |
| board.team worst bucket | 486.80 ms / 6 calls | 29.76 ms / 10 calls |
| dispatch status worst bucket | 401.26 ms / 6 calls | 653.86 ms / 10 calls |
| Synchronous networks.alert_groups | 307.59 ms / 2 calls | No synchronous scan; background job |
| Slowest of 24 client startup calls | 511.88 ms | 283.71 ms |

The after status bucket includes ground.alerts 286.74 ms, survey.summary 155.46 ms and threat.summary 148.46 ms. Research and board improve substantially; status cost per call remains roughly similar (the bucket contains more calls).

Named-part values aggregate all calls in the worst bucket of the first ten game seconds. They are not individual-call latency, and faster startup changes how many calls share a bucket. The status path still has cold ground-alert, survey and threat-summary work; it is not fully bounded by this patch. The remaining hitch is included in the results.

The initial cp5 pilot exposed a delay masked by the tiny offline fixture: global terrain band walks took minutes before publishing the first network view. It was rejected as the final comparison. A development pilot exposed a missing alert closing step in the cost-budget regression test. The cp6 native pilot then recorded two new push-alert failures: its first network snapshot preceded power sampling, so a later sustained-power alert dereferenced an absent draw field. cp7 uses the latest real sample in that case, with an exact-line regression test. Both pilots were stopped and the final candidate restarted from the canonical save. Only after-cp7-* files constitute the final after comparison. The final native check found populated network/alert snapshots for all four teams and player by 93 game seconds; the preceding pilot observed them by 51 seconds. The first view can precede power sampling, so optional draw fields can be absent until a subsequent view refresh; the fresh network read remains available. The large-empty-box offline fixture completes at tick 94 with three queries and zero queries in twelve simultaneous first reads.

## GC and allocation

The default 200/200 pause/step multiplier is unchanged. Baseline candidates ran for 120 game seconds each; final after candidates run for 60 game seconds each to preserve the server deadline, with the same twelve stand-ins after the combined workload. Shorter after windows have less tail coverage and their peaks are not equivalent-duration estimates; settings restore in finally. These GC tables retain the original collector convention, separately from the boundary-audited workload table.

| Pause / step | Before 120 s: avg / p99 / max tick ms/s | After 60 s: avg / p99 / max tick ms/s | Before heap MB | After heap MB |
|---|---:|---:|---:|---:|
| 200 / 200 | 277.47 / 473.80 / 605.80 | 242.46 / 485.53 / 485.53 | 323–775 | 337–778 |
| 150 / 200 | 283.05 / 527.58 / 555.81 | 238.72 / 526.79 / 526.79 | 310–756 | 334–767 |
| 150 / 400 | 287.76 / 496.52 / 541.91 | 247.26 / 544.46 / 544.46 | 287–573 | 302–596 |
| 120 / 400 | 285.03 / 443.39 / 502.32 | 245.42 / 696.38 / 696.38 | 283–555 | 296–543 |

| Allocation source, KB/game-s (nested) | Before | After |
|---|---:|---:|
| * | 32088 | 21831 |
| tick | 26448 | 17096 |
| part productionlegs.tick | 7316 | 125 |
| part netmap.tick | 3442 | 3927 |
| dispatch observe | 2892 | 1965 |
| part census.step | 1342 | 1805 |
| part board.team | 1162 | 1114 |
| part pushalerts.tick | 1134 | 1816 |

Detailed-profile tick allocation per actual tick call: 439.3 KB before, 284.0 KB after.

Total attributed allocation fell from 32,088 to 21,831 KB/game-s (32.0%); tick allocation fell from 26,448 to 17,096 KB/game-s (35.4%). Netmap allocation did not improve in this short native sample (3,442 to 3,927 KB/s); its counted idle-loop improvement does not imply lower allocation during every active job. Census and push-alert sample allocations also rose, and remain follow-up targets.

A separate five-second GC-stopped attribution sample measures nested allocation sources; do not sum them. The baseline also has a separate outer-only timer and approximately three-second allocation probe excluding the detailed per-part profiler; this after run omits that extra probe to preserve the release deadline. Neither these short probes nor the sequential GC sweep prove a days-long bound. The 300 ms/s peak objective is not established, and no unproven GC preset is installed.

## Counted checks and validation

| Counted workload | Before | After |
|---|---:|---:|
| 32 parked ships × 600 ticks: active_mods reads | 78,000 | 0 after factory construction |
| Same: state lookups | 39,000 | 600 |
| Three research summaries × 32 surfaces: surface counts | 2,240 | 0 |
| Same: force counts / technologies table reads | 0 / 138 | 70 / 3 |
| 10,000 empty belts: line objects / contents tables | 20,000 / 20,000 | 0 / 0 |
| 600 network slices × 32 surfaces: name reads | 19,201 | 1 plus 600 direct lookups |
| 10,000 alerting labs: integer formats | 0 | 20,000, same group key/count |
| 12 sight readers × 1,000 cells: sorts | 24 | 2 |
| 600 ticks, six planets, 30 ships: surface enumerations / sorts | 200 / 200 | 0 / 0 |
| Same: surface.planet / idle force reads | 7,200 / 200 | 0 / 0; 1,200 planet.surface reads |

Actual Lua 5.2.4: **799/799 full harness tests pass**, including compacted modules. Raw and compacted mt306 fixtures, full-bundle luac parsing, tools/test_lua52_syntax.py, tools/test_brief.py, three collector tests and seven ownership/handoff tests pass. New cold tests cover a 4,001-by-4,001-chunk empty box, reload with a held result, capped network fallback, all 20,000 held push entities, playerless forces, cursor preservation and unchanged four-force census cadence. The existing alert cost-budget test now exercises the runtime cold path. No gate.sh or public push.

## Server restoration, migration and next work

imac2 was claimed atomically at 2026-11-14T19:14:24.997844-08:00 and restored/released at **2026-11-14T20:13:26.250554-08:00**, within 60 minutes. The exact owned PID was stopped; prior mt.zip, mods, config, settings and whitelist were restored and compared; both private ports were free. Prior/restored save SHA-256: c2ff265cda5e86f2dac15f2b490189f98e2395f0ebd017c8b4bc2ceb49d021d0. ENGWAKE was appended to /Users/owner/code/pog-operator/mt306-wake.jsonl. The durable receipt is /Users/owner/code/pog-operator/mt306-artifacts/after-cp5/server-lease.json. The final named save was copied and hash-verified into that directory. GC was checked running at 200/200 before shutdown.

Main fbe96e6c4adfd41594fbec70e9794053c87a8c9b was merged and remains an ancestor at the final checkpoint. The operator gates the final cp ref. This engineer does not mutate main or run gate.sh.

All non-reconstructible evidence is under the migrating operator directory. Baseline: /Users/owner/code/pog-operator/mt306-artifacts/baseline. After lease directory: /Users/owner/code/pog-operator/mt306-artifacts/after-cp5 (historical directory name; **after-cp7** is the final measurement label). Canonical save, raw profiles/calls, compact summaries, deployment SHA, lease/restoration receipts and compiler source survive the move. Useful code, tests and compact evidence are committed on mt/batch306; the report and fresh-engineer procedure are also tracked at docs/mt306-report.md and docs/mt306-handoff.md. Neither the old worktree nor ignored dist/node_modules is a continuation prerequisite.

Follow-up priorities: bound the remaining cold status subreads; reduce residual allocations identified in the final table; test a longer GC policy under the same loaded fixture before changing defaults. The mt307 rehearsal used a different runtime and early Nauvis factories (about 73–76 tick ms/game-s), so it supports supervision/soak evidence but cannot substitute for this late-game comparison. Scripted travel here is not native-thruster or days-long coverage.

Operator report: /Users/owner/code/pog-operator/report-mt306.md
Fresh-engineer handoff: /Users/owner/code/pog-operator/handoff-mt306.md

Live codex-b weekly usage at closeout: **36%**, below the >70% stop threshold. The shared quota refresher was stale; a direct read reused the installed ai-usage Codex adapter. Receipt: quota-closeout.json.
