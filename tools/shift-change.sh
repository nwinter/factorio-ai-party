#!/usr/bin/env bash
# One command for a shift change of a resumed world:
#   tools/shift-change.sh PREV NEXT MINUTES [--stream|--no-stream] [--dry-run] [--ignore CHECK[,CHECK]]
# 1. Checks, refusing with the reason: PREV ran agents (notes.md exist), quota for NEXT (start-team's check: no
#    WARNING line), the box reachable, OBS up, no other start-team or shift change running, NEXT not started yet, and
#    --stream or --no-stream given when PREV is streaming. --ignore quota,obs,... skips named checks (notes, quota,
#    box, obs, running, stream).
# 2. Reads PREV's switches while its helpers still run (tools/shift_change.py switches: switches.env, the helpers'
#    arguments, start.log, stream.json, viewers-relay.on, team.txt), then POG_STOP_WORLD=1 tools/stop-team.sh PREV,
#    closes PREV's agent panes (runs/PREV/panes.txt), and runs tools/start-team.sh NEXT MINUTES [--stream] with those
#    switches, POG_RESUME=PREV and POG_NEXT_SHIFT at NEXT's end.
# 3. Afterwards (POG_SC_HEALTH_WAIT seconds, default 180): one health line (agents up, broker, OBS and the stream
#    service, the viewer relay, harness Lua errors so far) and PREV's console audit (stop-team saved it).
# --dry-run: the checks, the switches and the plan (with start-team's own dry run); stops and starts nothing.
# Stubs for tests: POG_SC_STOP_TEAM, POG_SC_START_TEAM, POG_SC_QUOTA, POG_SC_SSH, POG_SC_OBS, POG_SC_HERDR,
# POG_SC_PGREP (commands, split on spaces), POG_SC_RUNS (where runs live), POG_SC_STATE_URL.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
usage="usage: tools/shift-change.sh PREV NEXT MINUTES [--stream|--no-stream] [--dry-run] [--ignore CHECK[,CHECK]]"
[ $# -ge 3 ] || { echo "$usage" >&2; exit 64; }
prev=$1 next=$2 minutes=$3; shift 3
stream="" dry=0 ignore=","
while [ $# -gt 0 ]; do
  case $1 in
    --stream) stream=--stream ;;
    --no-stream) stream=no ;;
    --dry-run) dry=1 ;;
    --ignore) ignore=",${2:-},"; shift ;;
    *) echo "unknown option $1; $usage" >&2; exit 64 ;;
  esac
  shift
done
[[ $minutes =~ ^[0-9]+$ ]] || { echo "MINUTES must be a whole number: $minutes" >&2; exit 64; }
[ "$prev" != "$next" ] || { echo "PREV and NEXT are the same run ($prev); a shift needs a new run id" >&2; exit 64; }

read -ra stop_team <<<"${POG_SC_STOP_TEAM:-tools/stop-team.sh}"
read -ra start_team <<<"${POG_SC_START_TEAM:-tools/start-team.sh}"
read -ra quota_cmd <<<"${POG_SC_QUOTA:-python3 tools/quota_check.py}"
read -ra ssh_cmd <<<"${POG_SC_SSH:-ssh}"
read -ra herdr <<<"${POG_SC_HERDR:-herdr}"
read -ra pgrep_cmd <<<"${POG_SC_PGREP:-pgrep}"
py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
read -ra obs <<<"${POG_SC_OBS:-$py tools/obs.py}"
runs=${POG_SC_RUNS:-}
state_url=${POG_SC_STATE_URL:-http://127.0.0.1:8788/state.json}

# PREV's run directory: here, or in the main checkout (as start-team looks for it).
prev_dir=""
for d in ${runs:+"$runs/$prev"} "$root/runs/$prev" "$HOME/code/player-of-games/runs/$prev"; do
  [ -d "$d" ] && { prev_dir=$d; break; }
done
next_dir=${runs:-$root/runs}/$next

refused=()
check() {  # NAME OK REASON: a failed check refuses unless --ignore names it
  if [ "$2" = 1 ]; then echo "check $1: ok${3:+ ($3)}"
  elif [[ $ignore == *",$1,"* ]]; then echo "check $1: FAILED, ignored (--ignore $1): $3"
  else echo "check $1: FAILED: $3"; refused+=("$1: $3"); fi
}

# 1. Checks.
if [ -z "$prev_dir" ]; then
  echo "refused: no run directory for $prev (runs/$prev here or in ~/code/player-of-games/runs)" >&2; exit 2
fi
notes=$(ls "$prev_dir"/*/notes.md 2>/dev/null | wc -l | tr -d ' ')
check notes "$([ "$notes" -gt 0 ] && echo 1 || echo 0)" \
  "$([ "$notes" -gt 0 ] && echo "$notes agents' notes in $prev_dir" || echo "$prev ran no agents (no notes.md in $prev_dir); resume from the run that did")"
[ -f "$next_dir/start.log" ] && check next 0 "$next already started ($next_dir/start.log)"

# The switches, read while PREV's helpers still run.
sw=()
while IFS= read -r line; do [ -n "$line" ] && sw+=("$line"); done < <(python3 tools/shift_change.py switches "$prev_dir")
explain=$(python3 tools/shift_change.py switches "$prev_dir" --explain)
swval() { local l; for l in ${sw[@]+"${sw[@]}"}; do [ "${l%%=*}" = "$1" ] && { echo "${l#*=}"; return; }; done; echo "${2:-}"; }
team=$(swval POG_TEAM_FILE agent/team-nine.tsv)

warnings=$("${quota_cmd[@]}" "$team" "$minutes" 2>&1 | grep '^WARNING' || true)
check quota "$([ -z "$warnings" ] && echo 1 || echo 0)" "${warnings:-$team for $minutes min}"
if "${ssh_cmd[@]}" -o BatchMode=yes -o ConnectTimeout=8 pogwin true >/dev/null 2>&1; then check box 1 "pogwin"
else check box 0 "pogwin is not reachable over ssh"; fi
if [ "${POG_OBS:-1}" != 0 ]; then
  obs_status=$("${obs[@]}" status 2>&1); obs_ok=$?
  check obs "$([ $obs_ok = 0 ] && echo 1 || echo 0)" "$([ $obs_ok = 0 ] && echo "$obs_status" || echo "OBS is not answering: $(echo "$obs_status" | tail -1 | cut -c1-120)")"
  streaming=$("${obs[@]}" stream-status 2>/dev/null | grep -c 'active=True' || true)
  if [ "${streaming:-0}" -gt 0 ] && [ -z "$stream" ]; then
    check stream 0 "$prev is streaming: pass --stream to keep the stream going, or --no-stream to end it"
  fi
fi
others=$("${pgrep_cmd[@]}" -f 'tools/start-team.sh' 2>/dev/null | tr '\n' ' ')
check running "$([ -z "${others// /}" ] && echo 1 || echo 0)" "another start-team is running (pid ${others% })"
lock=${runs:-$root/runs}/.shift-change.lock
if [ $dry = 0 ]; then
  if mkdir "$lock" 2>/dev/null; then trap 'rmdir "$lock" 2>/dev/null' EXIT
  else check running 0 "another shift change holds $lock"; fi
fi

next_shift=$(python3 tools/shift_change.py next-shift "$minutes")
[ "$stream" = no ] && stream=""
echo "switches from $prev:"; printf '  %s\n' "$explain"
echo "plan: POG_STOP_WORLD=1 ${stop_team[*]} $prev; close $(wc -l < "$prev_dir/panes.txt" 2>/dev/null | tr -d ' ' || echo 0) agent panes of $prev;"
echo "      ${start_team[*]} $next $minutes${stream:+ $stream} with the switches above, POG_RESUME=$prev, POG_NEXT_SHIFT=$next_shift;"
echo "      then a health line after ${POG_SC_HEALTH_WAIT:-180} s and $prev's console audit"
if [ ${#refused[@]} -gt 0 ]; then
  printf 'refused: %s\n' "${refused[@]}" >&2
  exit 2
fi
if [ $dry = 1 ]; then
  env ${sw[@]+"${sw[@]}"} POG_RESUME="$prev" POG_NEXT_SHIFT="$next_shift" POG_DRY_RUN=1 \
    "${start_team[@]}" "$next" "$minutes" ${stream:+"$stream"}
  exit 0
fi

# 2. Stop PREV, close its panes, start NEXT.
echo "stopping $prev"
POG_STOP_WORLD=1 "${stop_team[@]}" "$prev" || echo "stop-team $prev exited $? (going on: the save step is what matters)"
if [ -f "$prev_dir/panes.txt" ]; then
  closed=0
  while read -r name pane kind; do
    [ -n "$pane" ] || continue
    if "${herdr[@]}" pane close "$pane" >/dev/null 2>&1; then closed=$((closed + 1)); else echo "pane $pane ($name): already gone"; fi
  done < "$prev_dir/panes.txt"
  echo "closed $closed agent panes of $prev"
fi
started=$(date +%s)
echo "starting $next"
if ! env ${sw[@]+"${sw[@]}"} POG_RESUME="$prev" POG_NEXT_SHIFT="$next_shift" "${start_team[@]}" "$next" "$minutes" ${stream:+"$stream"}; then
  echo "start-team $next FAILED; see $next_dir/start.log" >&2
  exit 1
fi

# 3. Health and the console audit.
sleep "${POG_SC_HEALTH_WAIT:-180}"
# Lua errors from start-team's start until now: the agents launch at its end, so this covers their first minutes.
hargs=(--team "$team" --since "$started" --window "$(( $(date +%s) - started + 1 ))" --state-url "$state_url")
[ "$(swval POG_BROKER 0)" = 1 ] && hargs+=(--broker)
[ -n "$stream" ] && hargs+=(--stream)
[ "${POG_OBS:-1}" != 0 ] && hargs+=(--obs "${obs[*]}")
python3 tools/shift_change.py health "$next_dir" "${hargs[@]}"; healthy=$?
if [ -f "$prev_dir/console-audit.json" ]; then
  echo "console audit of $prev:"
  python3 tools/console_audit.py --file "$prev_dir/console-audit.json" | sed 's/^/  /'
else
  echo "console audit of $prev: none saved (stop-team writes $prev_dir/console-audit.json)"
fi
exit $healthy
