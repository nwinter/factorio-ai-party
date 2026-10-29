#!/usr/bin/env bash
# (mt277, private) Start a multi-team run on the mt server on the iMac (tools/mt/imac_mt.sh, world imac2): every team's
# agents in their own folder runs/RUN/TEAM/<agent>, with the team's own roster, prompt, RCON broker sockets, team-tools
# and carry, launched from the launch tree (tools/mt/launch-tree.sh) with the moderate lockdown (part E).
#   tools/mt/start-mt.sh RUN_ID MINUTES [TEAMS_FILE]      (default agent/mt/teams-smoke.tsv: one agent per team)
# TEAMS_FILE: team<TAB>name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness; the team is the force
# (tools/mt/mt_map.py setup made red, blue, green, yellow). Each team's file runs/RUN/TEAM/team.tsv is the usual
# 7-column team file, so quota_check, quota_rest, team_bots and the launch read it unchanged.
# Env:
#   POG_MT_SAVE: the save to start the server on when it is not running (a path here, or imac:PATH); a running server is
#     used as it is. POG_RESUME=PREVIOUS_RUN: a later shift: each team's notes, tools/ and team-tools/ from
#     runs/PREVIOUS_RUN/TEAM (with no POG_MT_SAVE and no server running, the server starts on its own saves/mt.zip,
#     which tools/mt/stop-mt.sh's /quit left).
#   POG_MT_TREE: the launch tree (default worktrees/pog-p, made or updated from HEAD at each start);
#     POG_MT_TREE=here launches from this checkout (no tree: the agents' tools can read tools/mt and agent/mt).
#   POG_MT_TEAMS: only these teams (comma-separated), POG_DRY_RUN=1: the plan only, POG_FULL_TOOLS=1 as start-team,
#   POG_SEED (default 274274), POG_ENEMIES (default normal), POG_IDLE_NUDGE (default 0: until mt276 part B the board
#   it names is every team's), POG_SCORE_EVERY (default 120 s).
# Always: Space Age, real time, POG_BROKER=1 (no key in the run; the broker reaches the iMac, which Claude Code's
# sandbox would not). No stream, cameras, site, polls, casters, analyst or viewer relay: nothing of this run is public.
# Lockdown (multiteam-design.md, moderate): POG_WEB_BLOCK (the site, YouTube, GitHub; tools/full_tools.py says per
# harness what that does), POG_DENY_READ (this checkout, every mt/ worktree, the operator's folder) for the Claude Code
# and Grok sandboxes, which also deny the other teams' folders (tools/launch-agent.sh). The operator's files (this log,
# the teams file, scores, the shared chat log) go in this checkout's runs/RUN/op/.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
run=${1:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]} minutes=${2:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]}
teams_file=${3:-agent/mt/teams-smoke.tsv}
world=imac2
case $run in */*|.*|op) echo "RUN_ID: a plain name" >&2; exit 64 ;; esac
export POG_SPACE_AGE=1 POG_BROKER=1 POG_TIME_MODE=realtime POG_ENEMIES=${POG_ENEMIES:-normal} POG_SEED=${POG_SEED:-274274}
export POG_KB=${POG_KB:-space-age-2.0.77}
# The brief (tools/brief.py): true of the team, nothing about the world's other players (multiteam-design.md: teams
# start believing their teammates are the only players); the map's starts, patches and nests were placed by the setup.
export POG_TEAM_LINE='You play in a team of {{TEAM_SIZE}} AI agents'
export POG_GOAL="a space platform of the team's reaching the solar system's edge, as soon as you can"
export POG_MAP_TEXT=$'map settings\nmade for this run'
export POG_WEB_BLOCK="factorio.nickwinter.net youtube.com www.youtube.com youtu.be github.com raw.githubusercontent.com"
deny="$root /Users/owner/code/pog-operator"
for w in $(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/mt\//{print w}'); do
  case " $deny " in *" $w "*) ;; *) deny="$deny $w" ;; esac
done
export POG_DENY_READ=$deny
resume=${POG_RESUME:-}
only=${POG_MT_TEAMS:-}
teams=$(awk -F'\t' -v only=",$only," '!/^#/ && NF >= 8 && (only == ",," || index(only, "," $1 ",")) && !seen[$1]++ {print $1}' "$teams_file")
[ -n "$teams" ] || { echo "no team in $teams_file${only:+ (POG_MT_TEAMS=$only)}" >&2; exit 1; }
bad=$(awk -F'\t' '!/^#/ && NF && NF != 8' "$teams_file")
[ -z "$bad" ] || { echo "$teams_file: lines without 8 fields: $bad" >&2; exit 1; }
dup=$(awk -F'\t' '!/^#/ && NF {print $2}' "$teams_file" | sort | uniq -d)
[ -z "$dup" ] || { echo "$teams_file: a name in two lines: $dup" >&2; exit 1; }
tree=${POG_MT_TREE:-/Users/owner/code/personal/player-of-games/worktrees/pog-p}
[ "$tree" = here ] && tree=$root
# Each bot's broker socket, TREE/runs/RUN/TEAM/.sock/NAME.sock: macOS takes 103 bytes at most (mt-smoke1's first start
# stopped at blue's broker, 104 bytes under worktrees/pog-mt-launch).
while IFS=$'\t' read -r t name _; do
  [ -z "$t" ] || [[ $t == \#* ]] && continue
  case " $(echo $teams) " in *" $t "*) ;; *) continue ;; esac
  sock="$tree/runs/$run/$t/.sock/$name.sock"
  [ ${#sock} -le 103 ] || { echo "$name's broker socket would be ${#sock} bytes (macOS allows 103): $sock; use a shorter RUN_ID or POG_MT_TREE" >&2; exit 1; }
done < "$teams_file"
if [ -n "$resume" ]; then
  [ "$resume" != "$run" ] || { echo "POG_RESUME names this run ($run)" >&2; exit 1; }
  [ -d "$tree/runs/$resume" ] || { echo "POG_RESUME=$resume: no $tree/runs/$resume" >&2; exit 1; }
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
  echo "   runtime deployed from $(git rev-parse --short HEAD); the world unpaused; the setup's join lines dropped from the chat"
  if [ "$tree" = "$root" ]; then echo "   agents launch from this checkout (POG_MT_TREE=here)"
  else echo "   agents launch from $tree (tools/mt/launch-tree.sh from $(git rev-parse --short HEAD), then its scan)"; fi
  echo "   web blocked: $POG_WEB_BLOCK; reads denied: $POG_DENY_READ"
  for t in $teams; do
    mkdir -p "$tmp/$t"; team_files "$t" "$tmp/$t"
    echo "2. team $t (force $t): $(members "$tmp/$t/team.tsv" | tr '\n' ' ')-> $tree/runs/$run/$t/<name>, broker sockets there in .sock"
    python3 tools/quota_check.py "$tmp/$t/team.tsv" "$minutes" ${POG_QUOTA_BRIEF:+--brief "$POG_QUOTA_BRIEF"} 2>&1 | sed "s/^/   $t quota: /" || true
    if [ -n "$resume" ]; then
      python3 tools/full_tools.py carry --dry-run "$tree/runs/$run/$t" "$tree/runs/$resume/$t" $(members "$tmp/$t/team.tsv") 2>&1 | sed "s/^/   $t carry: /" || true
    fi
  done
  echo "3. agents: one Herdr tab per team, each agent's web and network state in the log; supervisors; scores and the shared chat log in runs/$run/op/; idle nudges $([ "${POG_IDLE_NUDGE:-0}" = 1 ] && echo 'on (per team)' || echo off)"
  exit 0
fi

op=$root/runs/$run/op
mkdir -p "$op"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$op/start.log"; }
cp "$teams_file" "$op/teams.tsv"
log "mt run $run, $minutes min, teams $(echo $teams) from $teams_file; code $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- tools agent vendor 2>/dev/null || echo ' plus uncommitted changes')"

# 0. The launch tree and its scan (a word naming the mode in it stops the start).
if [ "$tree" != "$root" ]; then
  tools/mt/launch-tree.sh "$tree" >/dev/null
  scan=$(tools/mt/launch-tree.sh --scan "$tree") || { log "refusing: launch tree $tree: $scan"; exit 1; }
  log "launch tree $tree from $(cat "$tree/.launch-tree"): $scan"
else
  log "launching from this checkout (POG_MT_TREE=here): the agents' tools can read tools/mt and agent/mt"
fi
echo "$tree" > "$op/launch-tree"
rundir=$tree/runs/$run
log "lockdown: web blocked $POG_WEB_BLOCK; reads denied $POG_DENY_READ"

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
# The game's join and leave lines of the setup's team accounts (mt-red, ...) out of the harness chat (multiteam.lua)
log "chat: $(python3 tools/pog.py --world "$world" rcon '/silent-command rcon.print(remote.call("agent_harness","dispatch",[[{"id":"start-mt-scrub","operator":true,"action":"mt_chat_scrub","args":{}}]]))' 2>&1 | cut -c1-200)"
mkdir -p "$rundir"
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
    python3 "$tree/tools/full_tools.py" carry "$td" "$tree/runs/$resume/$t" $(members "$td/team.tsv") 2>&1 | while read -r line; do log "$t $line"; done || true
  fi
  if [ "${POG_FULL_TOOLS:-0}" = 1 ]; then
    nohup python3 "$tree/tools/full_tools.py" sync "$td" 5 >>"$td/team-tools-sync.log" 2>&1 &
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

# 3. Agents: one Herdr tab per team, from the launch tree.
# A failed launch is logged as not started (op/not-started.txt, launch-agent.sh's last lines) and the others go on, as
# in tools/start-team.sh (batch331).
prompt_args=() wanted=0 missing=""
: >> "$op/panes.txt"
for t in $teams; do
  td=$rundir/$t tab=""
  if [ -n "$resume" ]; then export POG_RESUME=$resume POG_RESUME_DIR=$tree/runs/$resume/$t; fi
  while IFS=$'\t' read -r name kind route model effort label harness; do
    [ -z "$name" ] || [[ $name == \#* ]] && continue
    wanted=$((wanted + 1))
    if out=$(POG_TEAM="$td/team.txt" POG_NO_WAIT=1 POG_TAB="$tab" POG_WS="$name" POG_BOT="$name" \
          POG_MODEL="$label ($harness)" POG_ROUTE="$route" "$tree/tools/launch-agent.sh" "$run/$t" "$world" "$name" "$minutes" "$kind" "$model" "$effort" \
          2> >(tee "$op/launch-$t-$name.err" >&2)); then
      pane=$(echo "$out" | awk '{print $1}'); tab=$(echo "$out" | awk '{print $2}')
      log "$t agent $name ($label, $kind) in pane $pane tab $tab; $(cat "$td/$name/.web-state" 2>/dev/null || echo 'no .web-state')"
      echo "$name $pane $kind" >> "$td/panes.txt"
      echo "$t $name $pane $kind" >> "$op/panes.txt"
      prompt_args+=("$pane" "$td/$name")
    else
      sleep 0.2
      log "$t agent $name ($label, $kind) NOT STARTED: launch failed: $(tail -3 "$op/launch-$t-$name.err" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
      printf '%s\t%s\t%s\t%s\n' "$t" "$name" "$kind" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$op/not-started.txt"
      missing="$missing $t/$name"
    fi
  done < "$td/team.tsv"
  { python3 tools/quota_rest.py --at-limit "$td" "$td/team.tsv" ${resume:+--carry "$tree/runs/$resume/$t"} 2>&1 || true; } | while read -r line; do log "$t $line"; done
done
[ ${#prompt_args[@]} -gt 0 ] && tools/clear-prompts.sh 90 "${prompt_args[@]}" | while read -r pane how; do log "pane $pane: $how"; done
log "started: $(wc -l < "$op/panes.txt" | tr -d ' ')/$wanted agents${missing:+ (not started:$missing; $op/not-started.txt)}; deadline $(cat "$rundir"/*/*/deadline.txt 2>/dev/null | head -1)"
[ -s "$op/panes.txt" ] || { log "no agent started"; exit 1; }

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
