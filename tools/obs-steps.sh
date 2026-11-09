#!/usr/bin/env bash
# The OBS steps of a shift (start-team.sh's, and tools/obs-recover.sh's after a restart):
#   tools/obs-steps.sh [--stream] [--dry-run]
# Overlay startup gates scene setup on a tunnel snapshot (default 180 s), reloads,
# verifies rendering, and retries once. Overlay-only trouble is DEGRADED; outputs
# still start so a successful shift change can launch its watchdog.
# Exit 1 only when recording/stream output fails. All OBS calls are stubbed in tests.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
stream="" dry=0
for a in "$@"; do
  case $a in
    --stream) stream=--stream ;;
    --dry-run) dry=1 ;;
    *) echo "usage: tools/obs-steps.sh [--stream] [--dry-run]" >&2; exit 64 ;;
  esac
done
py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
read -ra obs <<<"${POG_OS_OBS:-$py tools/obs.py}"
read -ra vertical <<<"${POG_OS_VERTICAL:-$py tools/vertical.py}"
read -ra overlay <<<"${POG_OS_OVERLAY:-python3 tools/overlay_check.py}"
say() { printf '%s obs-steps: %s\n' "$(date +%H:%M:%S)" "$*"; }
if [ $dry = 1 ]; then
  say "plan: ${overlay[*]} startup (wait for tunnel, stream-scene, raise-overlay, scene stream, reload and verify rendered page; one retry); start (then status until active, ${POG_OS_ACTIVE_WAIT:-10} s)${stream:+; stream-start (then stream-status until active); then ${vertical[*]} status (start --yes if not streaming)}; cams"
  exit 0
fi
bad=0
run() {  # LABEL REQUIRED CMD...: one step, its outcome printed
  local label=$1 required=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc = 0 ]; then say "$label: ${out##*$'\n'}"
  else say "$label: FAILED: $(echo "$out" | tail -1 | cut -c1-140)"; [ "$required" = 1 ] && bad=1; fi
  return $rc
}
active() {  # LABEL STATUS-CMD: the output became active within POG_OS_ACTIVE_WAIT s (default 10)? A request OBS
  # accepted is not an output that started (15:06: StartStream answered, then "Stream output type 'rtmp_output'
  # failed to start!" without Quick Sync, and this script said "streaming to YouTube")
  local label=$1 cmd=$2 t=0 st=""
  while [ "$t" -le "${POG_OS_ACTIVE_WAIT:-10}" ]; do
    st=$("${obs[@]}" "$cmd" 2>&1)
    if grep -q 'active=True' <<<"$st"; then say "$label: active ($(echo "$st" | tail -1 | cut -c1-80))"; return 0; fi
    sleep "${POG_OS_POLL:-1}"; t=$((t + 1))
  done
  say "$label: FAILED: not active after ${POG_OS_ACTIVE_WAIT:-10} s ($(echo "$st" | tail -1 | cut -c1-100))"
  bad=1
  return 1
}
# Stream every readiness probe to the operator log; do not reduce this to the last line.
if ! POG_OC_OBS="${obs[*]}" "${overlay[@]}" startup --wait "${POG_OS_READY_WAIT:-180}" \
    --render-wait "${POG_OS_OVERLAY_WAIT:-30}" 2>&1 | while IFS= read -r line; do say "$line"; done; then
  say "overlay: DEGRADED: startup did not verify rendering; outputs continue, watchdog will retry"
fi
run "recording" 1 "${obs[@]}" start && active "recording" status
if [ "$stream" = --stream ]; then
  if run "stream" 1 "${obs[@]}" stream-start && active "stream" stream-status; then
    sleep "${POG_OS_SLEEP:-8}"
    vs=$("${vertical[@]}" status 2>&1); vrc=$?
    if [ $vrc != 0 ]; then
      say "vertical: no answer from the plugin (skipped): $(echo "$vs" | tail -1 | cut -c1-100)"
    elif grep -qiE "streaming['\"]?: *true" <<<"$vs"; then
      say "vertical: streaming (started with the main stream)"
    elif grep -qiE "streaming['\"]?: *false" <<<"$vs"; then
      run "vertical start" 0 "${vertical[@]}" start --yes
    else
      say "vertical: status unclear, left alone: $(echo "$vs" | tail -1 | cut -c1-100)"
    fi
  fi
fi
# (d24 batch136 PH2) read only: each camera's hole and crop against the crop that hole takes, for the change's log
run "cameras" 0 "${obs[@]}" cams
exit $bad
