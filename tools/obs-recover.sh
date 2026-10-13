#!/usr/bin/env bash
# The stream went inactive mid-shift (the operator's watchdog calls this): tools/obs-recover.sh [--dry-run]
# 1. stream-status: active -> nothing to do (exit 0).
# 2. Once: stream-start, and start (recording) if it is not recording; after POG_REC_SETTLE seconds (default 15:
#    an encoder failure shows as the output not becoming active, "Stream output type 'rtmp_output' failed to start!")
#    both active -> recovered without a restart (exit 0).
# 3. Else (08:29: MFX_ERR_MEMORY_ALLOC; only a new OBS process helped): tools/obs-restart.sh, then the shift's OBS
#    steps (tools/obs-steps.sh --stream: scene, reload overlay, record, stream, vertical); exit 0 when the stream is
#    active afterwards, else 1.
# One at a time (runs/.obs-recover.lock). --dry-run: the state and the plan; touches nothing.
# Stubs for tests: POG_REC_OBS, POG_REC_RESTART, POG_REC_STEPS (commands, split on spaces), POG_REC_SETTLE.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
dry=0
[ "${1:-}" = --dry-run ] && dry=1
py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
read -ra obs <<<"${POG_REC_OBS:-$py tools/obs.py}"
read -ra restart <<<"${POG_REC_RESTART:-tools/obs-restart.sh}"
read -ra steps <<<"${POG_REC_STEPS:-tools/obs-steps.sh}"
settle=${POG_REC_SETTLE:-15}
say() { printf '%s obs-recover: %s\n' "$(date +%H:%M:%S)" "$*"; }
streaming() { "${obs[@]}" stream-status 2>/dev/null | grep -q 'active=True'; }
recording() { "${obs[@]}" status 2>/dev/null | grep -q 'active=True'; }

st=$("${obs[@]}" stream-status 2>&1) || st="no answer: $(echo "$st" | tail -1 | cut -c1-100)"
rec=$("${obs[@]}" status 2>&1) || rec="no answer: $(echo "$rec" | tail -1 | cut -c1-100)"
say "stream: $st; recording: $rec"
if [ $dry = 1 ]; then
  say "plan: stream active -> nothing; else once stream-start (and start if not recording), wait $settle s;"
  say "      still not both active -> ${restart[*]}, then ${steps[*]} --stream"
  exit 0
fi
if grep -q 'active=True' <<<"$st"; then
  say "stream active: nothing to do"
  exit 0
fi
lock=$root/runs/.obs-recover.lock
mkdir -p "$root/runs"
if ! mkdir "$lock" 2>/dev/null; then
  say "another obs-recover is running ($lock): not starting a second one"
  exit 2
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

# 2. One plain retry of the outputs.
out=$("${obs[@]}" stream-start 2>&1); say "stream-start: $(echo "$out" | tail -1 | cut -c1-120)"
if ! grep -q 'active=True' <<<"$rec"; then
  out=$("${obs[@]}" start 2>&1); say "start (recording): $(echo "$out" | tail -1 | cut -c1-120)"
fi
sleep "$settle"
if streaming && recording; then
  say "recovered without a restart: streaming and recording"
  exit 0
fi
say "outputs did not come back (encoder failure?): restarting OBS"

# 3. A new OBS process and the shift's OBS steps.
"${restart[@]}"; rrc=$?
[ $rrc = 0 ] || say "restart reported a failure (exit $rrc); trying the OBS steps anyway"
"${steps[@]}" --stream; src=$?
[ $src = 0 ] || say "an OBS step failed (exit $src)"
sleep "$settle"
if streaming; then
  say "recovered after a restart: $("${obs[@]}" stream-status 2>&1 | tail -1); recording: $(recording && echo yes || echo NO)"
  exit 0
fi
say "FAILED: the stream is still not active after a restart: $("${obs[@]}" stream-status 2>&1 | tail -1 | cut -c1-120)"
exit 1
