#!/usr/bin/env bash
# (mt277, private) Start a multi-team run on the mt server on the iMac (tools/mt/imac_mt.sh): every team's agents in their
# own folder runs/RUN/TEAM/<agent>, with the team's own roster, prompt, RCON broker sockets, team-tools and carry.
#   tools/mt/start-mt.sh RUN_ID MINUTES [TEAMS_FILE]      (default agent/mt/teams-smoke.tsv: one agent per team)
# TEAMS_FILE: team<TAB>name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness; the team is the force
# (tools/mt/mt_map.py setup made red, blue, green, yellow). Each team's file runs/RUN/TEAM/team.tsv is the usual
# 7-column team file, so quota_check, quota_rest, team_bots and the launch read it unchanged.
# Env:
#   POG_MT_SAVE: the save to start the server on when it is not running (a path here, or imac:PATH); a running server is
#     used as it is. POG_RESUME=PREVIOUS_RUN: a later shift: each team's notes, tools/ and team-tools/ from
#     runs/PREVIOUS_RUN/TEAM (with no POG_MT_SAVE and no server running, the server starts on its own saves/mt.zip,
#     which tools/mt/stop-mt.sh's /quit left).
#   POG_MT_TEAMS: only these teams (comma-separated), POG_DRY_RUN=1: the plan only, POG_FULL_TOOLS=1 as start-team,
#   POG_SEED (default 274274), POG_ENEMIES (default normal), POG_IDLE_NUDGE (default 0: until mt276 part B the board
#   it names is every team's), POG_SCORE_EVERY (default 120 s).
# Always: Space Age, real time, POG_BROKER=1 (no key in the run; the broker reaches the iMac, which Claude Code's
# sandbox would not). No stream, cameras, site, polls, casters, analyst or viewer relay: nothing of this run is public.
# The operator's own files (this log, the plan, scores, the shared chat log) go in runs/RUN/op/, which every team's
# Claude Code and Grok sandboxes deny with the other teams' folders (tools/launch-agent.sh, tools/full_tools.py).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
run=${1:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]} minutes=${2:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]}
teams_file=${3:-agent/mt/teams-smoke.tsv}
world=mt
case $run in */*|.*|op) echo "RUN_ID: a plain name" >&2; exit 64 ;; esac
export POG_SPACE_AGE=1 POG_BROKER=1 POG_TIME_MODE=realtime POG_ENEMIES=${POG_ENEMIES:-normal} POG_SEED=${POG_SEED:-274274}
export POG_KB=${POG_KB:-space-age-2.0.77}
resume=${POG_RESUME:-}
only=${POG_MT_TEAMS:-}
teams=$(awk -F'\t' -v only=",$only," '!/^#/ && NF >= 8 && (only == ",," || index(only, "," $1 ",")) && !seen[$1]++ {print $1}' "$teams_file")
[ -n "$teams" ] || { echo "no team in $teams_file${only:+ (POG_MT_TEAMS=$only)}" >&2; exit 1; }
bad=$(awk -F'\t' '!/^#/ && NF && NF != 8' "$teams_file")
[ -z "$bad" ] || { echo "$teams_file: lines without 8 fields: $bad" >&2; exit 1; }
dup=$(awk -F'\t' '!/^#/ && NF {print $2}' "$teams_file" | sort | uniq -d)
[ -z "$dup" ] || { echo "$teams_file: a name in two lines: $dup" >&2; exit 1; }
if [ -n "$resume" ]; then
  [ "$resume" != "$run" ] || { echo "POG_RESUME names this run ($run)" >&2; exit 1; }
  [ -d "runs/$resume" ] || { echo "POG_RESUME=$resume: no runs/$resume" >&2; exit 1; }
fi
# One team's files (tools/start-team.sh's team.tsv and team.txt; written in a dry run too, into a temporary folder)
team_files() {   # TEAM DIR
  awk -F'\t' -v t="$1" 'NR == 1 {print "# name\tkind\troute\tmodel\teffort\tlabel\tharness"} !/^#/ && $1 == t {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8}' "$teams_file" > "$2/team.tsv"
  awk -F'\t' '!/^#/ && NF {print $1 "|" $6 " (" $7 ")"}' "$2/team.tsv" > "$2/team.txt"
}
members() { awk -F'\t' '!/^#/ && NF {print $1}' "$1"; }

if [ "${POG_DRY_RUN:-0}" = 1 ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  status=$([ "${POG_TEST:-0}" = 1 ] && echo 'not asked: POG_TEST=1' || tools/mt/imac_mt.sh status 2>&1 | head -1)
  echo "plan for $run ($minutes min) on world $world (the iMac mt server: $status), teams from $teams_file"
  if [ -n "${POG_MT_SAVE:-}" ]; then echo "1. server: started on $POG_MT_SAVE if not running"
  elif [ -n "$resume" ]; then echo "1. server: if not running, started on its own saves/mt.zip (the last stop's)"
  else echo "1. server: must be running (or set POG_MT_SAVE)"; fi
  echo "   runtime deployed from $(git rev-parse --short HEAD); the world unpaused"
  for t in $teams; do
    mkdir -p "$tmp/$t"; team_files "$t" "$tmp/$t"
    echo "2. team $t (force $t): $(members "$tmp/$t/team.tsv" | tr '\n' ' ')-> runs/$run/$t/<name>, broker sockets runs/$run/$t/.sock"
    python3 tools/quota_check.py "$tmp/$t/team.tsv" "$minutes" ${POG_QUOTA_BRIEF:+--brief "$POG_QUOTA_BRIEF"} 2>&1 | sed "s/^/   $t quota: /" || true
    if [ -n "$resume" ]; then
      python3 tools/full_tools.py carry --dry-run "runs/$run/$t" "runs/$resume/$t" $(members "$tmp/$t/team.tsv") 2>&1 | sed "s/^/   $t carry: /" || true
    fi
  done
  echo "3. agents: one Herdr tab per team; supervisors; scores and the shared chat log in runs/$run/op/; idle nudges $([ "${POG_IDLE_NUDGE:-0}" = 1 ] && echo 'on (per team)' || echo off)"
  exit 0
fi

rundir=runs/$run op=runs/$run/op
mkdir -p "$op"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$op/start.log"; }
cp "$teams_file" "$op/teams.tsv"
log "mt run $run, $minutes min, teams $(echo $teams) from $teams_file; code $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- tools agent vendor 2>/dev/null || echo ' plus uncommitted changes')"

# 1. The server.
if tools/mt/imac_mt.sh status | grep -q '^running'; then
  log "server: $(tools/mt/imac_mt.sh status)"
else
  save=${POG_MT_SAVE:-}
  [ -n "$save" ] || [ -z "$resume" ] || save=imac:/Users/owner/pog-mt/saves/mt.zip
  [ -n "$save" ] || { log "refusing: the mt server is not running and POG_MT_SAVE is not set"; exit 1; }
  tools/mt/imac_mt.sh start "$save" 2>&1 | while read -r line; do log "server: $line"; done
  tools/mt/imac_mt.sh status | grep -q '^running' || { log "refusing: the mt server did not start"; exit 1; }
fi
deployed=$(POG_WORLD=$world bin/fh deploy --format json 2>/dev/null || true)
deploy_status=$(printf '%s' "$deployed" | python3 tools/code_check.py --deploy-reply)
log "runtime deployed from $(git rev-parse --short HEAD): $deploy_status"
case $deploy_status in ok*) ;; *) exit 1 ;; esac
python3 tools/pog.py --world "$world" resume >/dev/null 2>&1 || true
log "world: $(python3 tools/pog.py --world "$world" rcon "/silent-command rcon.print('tick ' .. game.tick .. (game.tick_paused and ' (paused)' or ''))" 2>&1)"
[ -n "$resume" ] && echo "$resume" > "$rundir/resumed-from"

# 2. Per team: files, bots in the team's force, the broker, the carry.
has_agy=0
for t in $teams; do
  td=$rundir/$t; mkdir -p "$td"
  team_files "$t" "$td"
  python3 tools/team_bots.py "$td/team.tsv" "$world" "$t" 2>&1 | while read -r line; do log "$t bot $line"; done
  nohup python3 tools/fh_broker.py --world "$world" --dir "$td/.sock" --log "$td/broker.log" $(members "$td/team.tsv") >"$td/broker.err" 2>&1 &
  echo $! > "$td/broker.pid"
  last=$(members "$td/team.tsv" | tail -1)
  for _ in $(seq 1 20); do [ -S "$td/.sock/$last.sock" ] && break; sleep 0.5; done
  [ -S "$td/.sock/$last.sock" ] || { log "$t broker FAILED: $(tail -2 "$td/broker.err" | tr '\n' ' ' | cut -c1-200)"; exit 1; }
  log "$t broker: pid $(cat "$td/broker.pid"), sockets for $(members "$td/team.tsv" | tr '\n' ' ')"
  if [ -n "$resume" ]; then
    echo "../$resume/$t" > "$td/resumed-from"
    python3 tools/full_tools.py carry "$td" "runs/$resume/$t" $(members "$td/team.tsv") 2>&1 | while read -r line; do log "$t $line"; done || true
  fi
  if [ "${POG_FULL_TOOLS:-0}" = 1 ]; then
    nohup python3 tools/full_tools.py sync "$td" 5 >>"$td/team-tools-sync.log" 2>&1 &
    echo $! >> "$td/helpers.pid"
  fi
  awk -F'\t' '!/^#/ && $2 == "agy" {f = 1} END {exit !f}' "$td/team.tsv" && has_agy=1
done
if [ "$has_agy" = 1 ]; then
  if guard=$(python3 tools/agy_memguard.py --check); then log "$guard"
  else
    nohup python3 tools/agy_memguard.py --log "$op/agy-memguard.log" >/dev/null 2>&1 &
    log "agy memory guard started: pid $!, log $op/agy-memguard.log (it runs across shifts)"
  fi
fi

# 3. Agents: one Herdr tab per team.
prompt_args=()
for t in $teams; do
  td=$rundir/$t tab=""
  if [ -n "$resume" ]; then export POG_RESUME=$resume POG_RESUME_DIR=$root/runs/$resume/$t; fi
  while IFS=$'\t' read -r name kind route model effort label harness; do
    [ -z "$name" ] || [[ $name == \#* ]] && continue
    out=$(POG_MT_TEAM="$t" POG_TEAM="$td/team.txt" POG_NO_WAIT=1 POG_TAB="$tab" POG_WS="$name" POG_BOT="$name" \
          POG_MODEL="$label ($harness)" POG_ROUTE="$route" tools/launch-agent.sh "$run/$t" "$world" "$name" "$minutes" "$kind" "$model" "$effort")
    pane=$(echo "$out" | awk '{print $1}'); tab=$(echo "$out" | awk '{print $2}')
    log "$t agent $name ($label, $kind) in pane $pane tab $tab"
    echo "$name $pane $kind" >> "$td/panes.txt"
    echo "$t $name $pane $kind" >> "$op/panes.txt"
    prompt_args+=("$pane" "$td/$name")
  done < "$td/team.tsv"
  { python3 tools/quota_rest.py --at-limit "$td" "$td/team.tsv" ${resume:+--carry "runs/$resume/$t"} 2>&1 || true; } | while read -r line; do log "$t $line"; done
done
tools/clear-prompts.sh 90 "${prompt_args[@]}" | while read -r pane how; do log "pane $pane: $how"; done
log "started: $(wc -l < "$op/panes.txt" | tr -d ' ') agents; deadline $(cat "$rundir"/*/*/deadline.txt | head -1)"

# 4. Supervisors (agy runs its own loop), scores, the shared chat log, idle nudges per team (POG_IDLE_NUDGE=1).
while read -r t name pane kind; do
  [ "$kind" = agy ] && continue
  nohup tools/supervise.sh "$pane" "$rundir/$t/$name" >/dev/null 2>&1 &
  echo $! >> "$rundir/$t/supervisors.pid"
done < "$op/panes.txt"
nohup tools/score-loop.sh "$op" "${POG_SCORE_EVERY:-120}" "$world" >/dev/null 2>&1 &
echo $! >> "$op/helpers.pid"
first_bot=$(awk '{print $2; exit}' "$op/panes.txt")
nohup python3 tools/chat-log.py --world "$world" --bot "$first_bot" "$op/chat.jsonl" >"$op/chat-log.err" 2>&1 &
echo $! >> "$op/helpers.pid"
if [ "${POG_IDLE_NUDGE:-0}" = 1 ]; then
  for t in $teams; do
    nohup python3 tools/idle_nudge.py --run "$rundir/$t" --world "$world" >"$rundir/$t/idle-nudge.log" 2>&1 &
    echo $! >> "$rundir/$t/supervisors.pid"
  done
fi
log "supervisors, scores ($op/scores.jsonl) and chat log ($op/chat.jsonl) running"
