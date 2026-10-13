#!/usr/bin/env bash
# The OBS steps of a shift (start-team.sh's, and tools/obs-recover.sh's after a restart):
#   tools/obs-steps.sh [--stream] [--dry-run]
# stream scene (overlay URL, camera holes), program scene "stream", reload the overlay, start recording, and with
# --stream start streaming and check the vertical feed (Aitum Vertical starts with the main stream; started by hand
# when its status says it is not streaming). The overlay tunnel (start-team) must be up. Prints each step's outcome;
# exit 1 when the recording (or with --stream the stream) did not start, else 0.
# Stubs for tests: POG_OS_OBS, POG_OS_VERTICAL (commands, split on spaces), POG_OS_SLEEP (seconds before the
# vertical check, default 8).
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
say() { printf '%s obs-steps: %s\n' "$(date +%H:%M:%S)" "$*"; }
if [ $dry = 1 ]; then
  say "plan: ${obs[*]} stream-scene; scene stream; reload-overlay; start${stream:+; stream-start; then ${vertical[*]} status (start --yes if not streaming)}"
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
run "stream scene" 0 "${obs[@]}" stream-scene
run "program scene" 0 "${obs[@]}" scene stream
run "reload overlay" 0 "${obs[@]}" reload-overlay
run "recording" 1 "${obs[@]}" start
if [ "$stream" = --stream ]; then
  if run "stream" 1 "${obs[@]}" stream-start; then
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
exit $bad
