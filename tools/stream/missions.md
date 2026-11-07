# Mission commentary cp1 (batch460, Aurora site:6003 + site:6004)

Rook and Vale get a coalesced mission beat for the active featured ship, or a measured ship named in Goals.
Rook calls progress, incoming damage, first structure losses, empty guns, observed repair/construction, ammo
stock drawdown and recovery. Vale explains the measured fact's limits and the existing run target. These short
rule-written pairs use the existing caster/TTS/playback path and make no additional LLM or game-agent calls.
Existing arrival/destruction headlines still handle voyage results.

The service exposes `mission_metrics` from the existing offscreen featured cache; overlay-card selection stays
camera-specific. It adds absolute `sample_t` to published telemetry. One global game-read slot per 20 wall seconds
is unchanged: no new game reads, runtime work, harness Lua or mod changes. The director receives that same cache
for its existing shooting/repair framing. Speech carries the platform subject for existing camera coordination.

Each snapshot replaces the pending mission with current facts. Completed Rook reports reserve a 180-second
mission gap; failed attempts back off for 60 seconds. A new spoken tenth and at least .05% forward movement are
needed for repeated progress calls. Existing caster gaps, agent yield, tour hush and listeners still apply.
Mission priority is 7, preferred over research at that tie and below urgent priority 8+. Audio rank is ordinary
banter; urgent and agent audio retain priority.

Only samples acquired within 45 wall seconds are usable. Missing/future dates, removed ships, changed routes and
pauses fail closed. Each line is rechecked after synthesis and before push. Queued mission audio is withdrawn
when a later sample invalidates it; queue-start expiry cannot exceed the original 45-second sample deadline.
Already-playing audio may finish. Repair/build and fire cues must be at most 30 seconds old. Known zero new hits
and damage is never called a repaired hull. Structure losses exclude foundation; ammo net includes crafting and
cannot prove gun feeding or predict survival.

`runs/RUN/host-missions.json` records completed Rook capture receipts only, inheriting through `resumed-from`.
Keys include ship, directed route, reversal and departure tick. Heard 10/25/50/75/90% milestones, first structure
loss, ammo negative, repair/damage and recovery persist across shifts and restarts. Later percentage thresholds
subsume earlier ones. Generated, queued, interrupted, expired and skipped lines establish no milestone; playback
restoration is idempotent. An unrelated run inherits nothing.

Cp1 verification: `tools/stream/test_missions.py`, including slow-TTS expiration, changed facts, urgent preemption,
queued cancellation, unknown data, milestone inheritance and offscreen read budget. The ten-minute replay,
analyst digest/Goals extension and narrator integration are deliberately reserved for cp2 at the operator's
09:25 request. Cp1 deploys with the existing stream-service/caster restart; no analyst restart is required.
