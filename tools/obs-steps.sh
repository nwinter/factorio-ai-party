#!/usr/bin/env bash
# The OBS steps of a shift (start-team.sh's, and tools/obs-recover.sh's after a restart):
#   tools/obs-steps.sh [--stream] [--dry-run]
# stream scene (overlay URL, camera holes), program scene "stream", reload the overlay, start recording, and with
# --stream start streaming and check the vertical feed (Aitum Vertical starts with the main stream; started by hand
# when its status says it is not streaming). The overlay tunnel (start-team) must be up. Prints each step's outcome;
# exit 1 when the recording (or with --stream the stream) did not start, or was accepted but did not become active
# within POG_OS_ACTIVE_WAIT s (status / stream-status active=True), else 0. Then (d29 batch347 OR, shift100: the overlay
# blank for 26 min after its reload) the overlay check: the main overlay page connected to the stream service after the
# reload (tools/overlay_check.py start: within POG_OS_OVERLAY_WAIT s, default 30; else the scene item toggled off and
# on and checked again; a second failure is printed FAILED and the health line says overlay NOT connected; the exit
# code is the recording's and stream's only). Last, a read of each camera's crop (obs.py cams).
# Stubs for tests: POG_OS_OBS, POG_OS_VERTICAL, POG_OS_OVERLAY (commands, split on spaces), POG_OS_SLEEP (seconds before the
# vertical check, default 8), POG_OS_POLL (seconds between active checks, default 1).
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
  say "plan: ${obs[*]} stream-scene; scene stream; reload-overlay; start (then status until active, ${POG_OS_ACTIVE_WAIT:-10} s)${stream:+; stream-start (then stream-status until active); then ${vertical[*]} status (start --yes if not streaming)}; ${overlay[*]} start --since RELOAD (toggle-overlay if not connected); cams"
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
run "stream scene" 0 "${obs[@]}" stream-scene
run "program scene" 0 "${obs[@]}" scene stream
reload_t=$(date +%s)
run "reload overlay" 0 "${obs[@]}" reload-overlay
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
# (batch347) the main overlay page connected since its reload, else one toggle of its scene item (the same OBS command)
POG_OC_OBS="${obs[*]}" run "overlay" 0 "${overlay[@]}" start --since "$reload_t" --wait "${POG_OS_OVERLAY_WAIT:-30}"
# (d24 batch136 PH2) read only: each camera's hole and crop against the crop that hole takes, for the change's log
run "cameras" 0 "${obs[@]}" cams
exit $bad
