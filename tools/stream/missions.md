# Mission commentary (batch460, Aurora site:6003 and site:6004)

Rook and Vale now have a coalesced mission beat for the active featured ship, or a measured ship named in current
Goals. Rook calls distance, milestone, incoming damage, structure losses, empty guns, observed repair/construction,
ammunition drawdown or recovery. Vale explains the scope of that observation and the measured reserves. These are
short rule-written pairs through the existing caster/TTS/playback path, not additional LLM requests. Existing
arrival/destruction headlines still handle the result of a voyage. No game agent is asked to write or spend quota.

The director's existing progress/fire/work cues and platform-metrics cache supply the facts. The service publishes
`mission_metrics` separately from the on-camera `platform_metrics` card, so offscreen featured telemetry remains
available to speech without displaying an offscreen ship's overlay. Both expose absolute `sample_t`. Collection
still has one global read slot every 20 wall seconds; this adds no game reads, runtime work, Lua or mod changes.
The director also receives the fresh offscreen cache for its existing shooting/repair framing.

One pending mission replaces its previous candidate on each snapshot. A completed Rook report reserves a global
180-second mission gap; failed attempts back off for 60 seconds. The normal caster gap, agent yield, tour hush,
listener check and segment scheduling still apply. Mission priority is 7, tied with research and preferred at that
tie, below urgent priority 8+. Its audio rank is ordinary banter, so urgent and agent audio retain priority. On a
quiet slow voyage a new spoken tenth of a percent and at least .05% forward movement warrants another update;
old work cues do not create updates; batch461 adds routine ammo slots and dated reports as described below.

Only telemetry acquired within 45 wall seconds is usable. Missing/future dates, removed ships, route changes,
pauses and changed spoken facts fail closed. A fact is checked again after synthesis and before each push; queued
mission audio is withdrawn when a later snapshot invalidates it. Queue-start expiry is also capped by the original
sample's 45-second deadline. Playback already underway may finish. Repair/build cues must be at most 30 seconds
old. Zero new hits/damage is reported only when both are known zero, and never called a repaired hull. Loss counts
exclude foundation; ammo net includes crafting and does not prove gun feeding or endurance.

`runs/RUN/host-missions.json` stores capture-completed host observations; only Rook establishes heard milestones. A mission key
contains ship, directed route, reversal flag and departure tick. The 10/25/50/75/90 percent milestones, first
structure loss, negative ammo types, repair/damage and recovery reports survive process restarts and a new shift
through `resumed-from`. A later crossed percentage subsumes earlier thresholds. Generated, queued, interrupted,
expired and skipped audio cannot establish a heard milestone. Playback restoration is idempotent. An unrelated
run inherits nothing. The recent 120 heard observations also feed hourly narration as explicitly dated historical
material, with the ship as camera target; the hourly/tour cadence and model-call count are unchanged.

Delivery diagnosis: `caster.log` distinguishes mission `queued`, `not queued` with a reason, and `capture completed`.
Queued does not mean heard. Completed lines restored at startup are not logged as a new airing. The structured
`tools/stream/logs/caster-*.jsonl` records pushes; `host-playback.json` retains capture receipts and interruption/
cancellation states. Before cp3, direct mission speech wrote the structured log but bypassed the console log.

The existing analyst digest gains current Goals, dated project plan lines and chronicle facts, recent relevant
agent speech, and fresh voyage telemetry. Added context is capped at 6,000 characters (approximately 1,500 input
tokens, before a short instruction). Ship-related analyst claims carry the exact sample revision and expire or
cancel on changed/old telemetry; unrelated research claims keep their usual provenance. Mission audio supplies
an explicit platform subject to the existing speech-camera resolver, which retains urgent-camera precedence.

Deployment: the operator's `restart-stream-svc.sh shift152` (or then-current shift) loads the service, caster and
hourly changes. The analyst is a separate process started by `tools/start-team.sh`; that restart helper does not
restart it. Its digest enhancement takes effect on its next normal launch, or an operator-managed restart with its
existing arguments, route and environment. The primary mission audio does not depend on the analyst enhancement.
No live service, OBS or private headless copy was started/restarted for verification.

Offline verification: `tools/stream/test_missions.py` and `tools/stream/missions_replay.py`. The replay runs ten
simulated minutes through the real caster scheduler, speech push code, receipt memory and OneCam subject framing,
with fake TTS durations and capture receipts. It prints every line, camera platform, playback rank and completed
exchange count, plus the identical trace with mission beats disabled. This is a synthetic recovery exercise, not
an assertion that live Asterion suffered the injected damage or a recording of actual listener playback.

## batch461: routine mission detail

The existing mission slot now rotates active ammo types (made/used per wall minute, hub reserve and loaded reserve),
even without a new progress tenth. Among types not yet covered, the shortest measured buffer goes first. Danger,
recovery and distance milestones keep their existing precedence. After an ammo report, one unheard dated agent
report can take the next routine slot: existing chat, last speech and plan lines supply short verbatim sentences
about the named ship's refits, bottlenecks, trials or next decisions. Reports carry agent and original game-hour/
minute attribution; plans and reports are not asserted as fresh measurements or confirmed test outcomes. Only
reports within one game hour (and one wall hour when a wall date exists) qualify. Undated, future, overlong or
unrelated statements are skipped. No summarizer or new model/game-agent call is added. Routine progress no longer
repeats the run goal; Goals remain in the analyst context.

Ammo guards compare all rounded spoken numbers, including Vale's reserves. Dated-report guards compare the exact
source statement. Original 45-second sample expiry and queued cancellation remain; an unrelated progress tenth
cannot cancel an ammo report. Every completed Rook OR Vale line enters the existing narrator history; only Rook
still establishes milestones and cadence. A dropped reserve line never enters that history. Restored receipts are
idempotent. Narration labels this material as historical, with the source date retained inside agent reports.

The three-minute minimum, retry backoff, urgent preemption, camera coordination, service read budget and model-call
cadences are unchanged. This can use previously silent mission slots (up to the existing 20 pairs/hour); it is not
zero TTS cost. Stream/caster restart remains operator-owned. `test_mission_details.py` covers numeric/unknown guards,
ammo rotation, dated report expiry/change, lineage and completed-only narrator detail alongside the original replay.
