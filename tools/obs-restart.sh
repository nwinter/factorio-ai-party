#!/usr/bin/env bash
# Restart OBS on the box (operator 2026-10-13: at 08:29, after 24.5 h in one process, Quick Sync failed with
# MFX_ERR_MEMORY_ALLOC and the stream and recording stopped; restarting the outputs did not help, a new OBS did):
#   tools/obs-restart.sh [--dry-run] [--wait SECONDS]
# 1. outputs: obs.py stream-stop, stop (saves the recording), replay-stop; errors ignored (a broken OBS may refuse).
# 2. tools/winps.sh tools/win/obs-restart.ps1: close OBS cleanly from Nick's desktop session, force after 30 s, start
#    the pog-obs task, answer the Safe Mode ("Run in Normal Mode") and Authentication Failure dialogs; prints each step.
# 3. obs-websocket: wait until `obs.py stream-status` answers (up to --wait, default 90 s).
# Exit 0 when OBS answers again, 1 when not (callers go on with whatever runs). Scenes, recording and stream are the
# caller's (tools/obs-steps.sh). --dry-run: the plan and the box's state (obs-restart.ps1 -DryRun); touches nothing.
# Stubs for tests: POG_OR_OBS, POG_OR_WINPS (commands, split on spaces), POG_OR_SLEEP (seconds per websocket try).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
dry=0 wait=90
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --wait) wait=$2; shift ;;
    *) echo "usage: tools/obs-restart.sh [--dry-run] [--wait SECONDS]" >&2; exit 64 ;;
  esac
  shift
done
py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
read -ra obs <<<"${POG_OR_OBS:-$py tools/obs.py}"
read -ra winps <<<"${POG_OR_WINPS:-tools/winps.sh}"
step=${POG_OR_SLEEP:-3}
say() { printf '%s obs-restart: %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ $dry = 1 ]; then
  say "plan: 1. ${obs[*]} stream-stop, stop, replay-stop (errors ignored)"
  say "      2. ${winps[*]} tools/win/obs-restart.ps1 (close cleanly, force after 30 s, start pog-obs, answer dialogs)"
  say "      3. wait up to $wait s for ${obs[*]} stream-status to answer"
  "${winps[@]}" tools/win/obs-restart.ps1 -DryRun | sed 's/^/  box: /'
  exit 0
fi

# 1. Outputs off first: OBS asks before exiting with outputs active, and a clean exit saves the recording.
for cmd in stream-stop stop replay-stop; do
  out=$("${obs[@]}" "$cmd" 2>&1); rc=$?
  say "$cmd: $([ $rc = 0 ] && echo "${out##*$'\n'}" || echo "failed (ignored): $(echo "$out" | tail -1 | cut -c1-100)")"
done

# 2. Close and start on the box.
"${winps[@]}" tools/win/obs-restart.ps1 2>&1 | sed 's/^/  box: /'
box_rc=${PIPESTATUS[0]}
[ "$box_rc" = 0 ] || say "the box's restart reported a problem (exit $box_rc); checking the websocket anyway"

# 3. obs-websocket answers.
t0=$(date +%s)
while :; do
  if out=$("${obs[@]}" stream-status 2>&1); then
    say "OBS answers after $(( $(date +%s) - t0 )) s: $out"
    exit 0
  fi
  [ $(( $(date +%s) - t0 )) -ge "$wait" ] && break
  sleep "$step"
done
say "FAILED: OBS does not answer after $wait s: $(echo "$out" | tail -1 | cut -c1-120)"
exit 1
