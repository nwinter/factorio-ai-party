#!/usr/bin/env bash
# The director (camera) clients, one at a time (19:15: started back to back, all three loaded sprites at once, cam1
# was still at "Parallel sprite loader initialized" after 450 s, the server ran at 7 ticks/s and the stream was black
# for 10 minutes; alone, a client was in the game in about 40 s):
#   tools/start-cams.sh WORLD GAME_PORT [-- START-CLIENT ARGS...]
# For cam1, cam2, cam3: start the client (tools/win/start-client.ps1, cam1 with -Sound), then wait until its player
# (pog-camN) is connected (RCON game.get_player(...).connected) before starting the next. A client not in after
# POG_CAM_WAIT seconds (default 180) is stopped (tools/win/stop-client.ps1) and started once more; a second miss is
# logged and the next camera starts anyway. Once all are done, the OBS game captures "stream cam1..3" are turned off
# and on so they hook the new clients (tools/obs.py rehook-cams; POG_OBS=0 skips it).
# Prints one line per step; exit 0 when all three joined, 1 when one did not.
# Stubs for tests: POG_CAM_WINPS, POG_CAM_RCON (a command given the Lua; prints its rcon output), POG_CAM_OBS
# (commands, split on spaces), POG_CAM_POLL (seconds between checks, default 3).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
world=${1:?usage: tools/start-cams.sh WORLD GAME_PORT [-- START-CLIENT ARGS...]} game=${2:?game port}
shift 2
[ "${1:-}" = -- ] && shift
extra=("$@")
py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
read -ra winps <<<"${POG_CAM_WINPS:-tools/winps.sh}"
read -ra rcon <<<"${POG_CAM_RCON:-python3 tools/pog.py --world $world rcon}"
read -ra obs <<<"${POG_CAM_OBS:-$py tools/obs.py}"
wait_s=${POG_CAM_WAIT:-180} poll=${POG_CAM_POLL:-3}
say() { printf '%s start-cams: %s\n' "$(date +%H:%M:%S)" "$*"; }

joined() {  # NAME: the player is connected to the server now
  local out
  out=$("${rcon[@]}" "/silent-command local p=game.get_player('$1') rcon.print(p and p.connected and 'joined' or 'not yet')" 2>/dev/null)
  grep -q joined <<<"$out"
}
running() {  # CAM: its client process is up on the box (an unknown answer counts as up: only "stopped" is acted on)
  ! "${winps[@]}" tools/win/client-running.ps1 -Slot "-$1" 2>/dev/null | tr -d '\r' | grep -q '^stopped'
}
start() {  # CAM
  local sound=(); [ "$1" = cam1 ] && sound=(-Sound)  # stream audio: only the main director is audible
  "${winps[@]}" tools/win/start-client.ps1 -Name "$world" -GamePort "$game" -PlayerName "pog-$1" -Slot "-$1" \
    ${sound[@]+"${sound[@]}"} ${extra[@]+"${extra[@]}"} >/dev/null 2>&1
}
wait_join() {  # CAM -> 0 once joined, 1 after wait_s
  local t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$wait_s" ]; do
    joined "pog-$1" && { say "$1: joined after $(( $(date +%s) - t0 )) s"; return 0; }
    sleep "$poll"
  done
  return 1
}

bad=0
for cam in ${POG_CAMS:-cam1 cam2 cam3}; do  # POG_CAMS: a subset when the box is short of memory (2026-10-14 19:30)
  if joined "pog-$cam"; then
    if running "$cam"; then say "$cam: already in the game"; continue; fi
    # 12:00 2026-10-16: right after stop-client the server still lists the player for a few seconds, so this skipped
    # three stopped cameras. A listed player whose client is not running is waited out (up to 60 s), then started.
    say "$cam: listed as joined but its client is not running: waiting for the server to drop it"
    t0=$(date +%s); while joined "pog-$cam" && [ $(( $(date +%s) - t0 )) -lt 60 ]; do sleep 3; done
  fi
  say "$cam: starting"
  start "$cam"
  wait_join "$cam" && continue
  say "$cam: not in the game after $wait_s s: stopping it and starting it once more"
  "${winps[@]}" tools/win/stop-client.ps1 -Name "$world" -Slot "-$cam" 2>&1 | sed 's/^/  box: /'
  sleep "$poll"
  start "$cam"
  wait_join "$cam" && continue
  say "$cam: FAILED: still not in the game after a restart (the next camera starts anyway)"
  bad=1
done
if [ "${POG_OBS:-1}" != 0 ]; then
  out=$("${obs[@]}" rehook-cams 2>&1) && say "OBS captures: $out" || say "OBS captures: not rehooked: $(echo "$out" | tail -1 | cut -c1-120)"
fi
exit $bad
