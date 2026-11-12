#!/usr/bin/env bash
# (mt277, private) Start a multi-team run on the mt server on the iMac (tools/mt/imac_mt.sh, world imac2): every team's
# agents in their own folder runs/RUN/TEAM/<agent>, with the team's own roster, prompt, RCON broker sockets, team-tools
# and carry, launched from the launch tree (tools/mt/launch-tree.sh) with the moderate lockdown (part E).
#   tools/mt/start-mt.sh RUN_ID MINUTES [TEAMS_FILE]      (default agent/mt/teams-test.tsv: two agents per team)
# TEAMS_FILE: team<TAB>name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness; the team is the force
# (tools/mt/mt_map.py setup made red, blue, green, yellow). Each team's file runs/RUN/TEAM/team.tsv is the usual
# 7-column team file, so quota_check, quota_rest, team_bots and the launch read it unchanged.
# Env:
#   POG_MT_SAVE: the save to start the server on when it is not running (a path here, or imac:PATH); a running server is
#     used as it is. POG_RESUME=PREVIOUS_RUN: a later shift: each team's notes, tools/ and team-tools/ from
#     runs/PREVIOUS_RUN/TEAM (with no POG_MT_SAVE and no server running, the server starts on its own saves/mt.zip,
#     which tools/mt/stop-mt.sh's /quit left).
#   POG_MT_FRESH=1: start from mt275-final; refuses a running server or POG_RESUME.
#     POG_MT_FRESH_SAVE overrides the local baseline path.
#   POG_MT_TREE: the launch tree (default worktrees/pog-p, made or updated from HEAD at each start);
#     POG_MT_TREE=here launches from this checkout (no tree: the agents' tools can read tools/mt and agent/mt).
#   POG_MT_TEAMS: only these teams (comma-separated), POG_DRY_RUN=1: the plan only, POG_FULL_TOOLS=1 as start-team,
#   POG_SEED (default 274274), POG_ENEMIES (default normal), POG_IDLE_NUDGE (default 0: until mt276 part B the board
#   it names is every team's: B is in now), POG_SCORE_EVERY (default 120 s), POG_MT_CAM (default 1: the camera client
#   on the iMac, tools/mt/imac_cam.py, which renders the agents' ./shot; 0 leaves it out and ./shot fails),
#   POG_MT_STREAM (default 0; 1: the stream service per team on this Mac, overlays at 127.0.0.1:8791...),
#   POG_MT_PUBLIC (default 0; 1: implies POG_MT_STREAM=1, pogwin spectator, public overlay, mt-stream OBS scene,
#     recording; NEVER starts streaming). POG_MT_YOUTUBE=VIDEO_ID selects the viewer chat broadcast.
#   POG_MT_HUMANS (default 0; 1: the human team, its freeze, and the server's game password and whitelist),
#   POG_NETGATE (default 0; 1: Grok's, Muse's and agy's shells through the run's network gate, tools/mt/netgate.py).
# Always: Space Age, real time, POG_BROKER=1 (no key in the run; the broker reaches the iMac, which Claude Code's
# sandbox would not). Public staging is opt-in; no site publishing, polls, casters or analyst.
# Lockdown (multiteam-design.md, moderate): POG_WEB_BLOCK (the site, YouTube, GitHub; tools/full_tools.py says per
# harness what that does), POG_DENY_READ (this checkout, every mt/ worktree, the operator's folder) for the Claude Code
# and Grok sandboxes, which also deny the other teams' folders (tools/launch-agent.sh). The operator's files (this log,
# the teams file, the per-team scores and chat logs, the team views) go in this checkout's runs/RUN/op/.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
run=${1:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]} minutes=${2:?usage: start-mt.sh RUN_ID MINUTES [TEAMS_FILE]}
teams_file=${3:-agent/mt/teams-test.tsv}
world=imac2
if [ "${POG_MT_PUBLIC:-0}" = 1 ]; then export POG_MT_STREAM=1; fi
export POG_MT_VIEWERS=${POG_MT_VIEWERS:-${POG_MT_PUBLIC:-0}}
export POG_GAME_TEST=${POG_GAME_TEST:-${POG_MT_FRESH:-0}}
if [ "$POG_MT_VIEWERS" = 1 ]; then export POG_MT_STREAM=1; fi
case $run in */*|.*|op) echo "RUN_ID: a plain name" >&2; exit 64 ;; esac
export POG_SPACE_AGE=1 POG_BROKER=1 POG_TIME_MODE=realtime POG_ENEMIES=${POG_ENEMIES:-normal} POG_SEED=${POG_SEED:-274274}
export POG_KB=${POG_KB:-space-age-2.0.77}
export POG_FACTORIO_VERSION=${MT_EXPECT_VERSION:-2.0.77}
# The brief (tools/brief.py): true of the team, nothing about the world's other players (multiteam-design.md: teams
# start believing their teammates are the only players); the map's starts, patches and nests were placed by the setup.
export POG_TEAM_LINE='You play in a team of {{TEAM_SIZE}} AI agents'
export POG_GOAL="a space platform of the team's reaching the solar system's edge, as soon as you can"
export POG_MAP_TEXT=$'map settings\nmade for this run'
export POG_IDENTITY_BRIEF='In your first minute, read profile {}. Choose your own character name and a one-line persona with profile {display_name, persona}; optional pronouns, motto and avatar are yours too. Your seeded color and glyph distinguish you from your teammate; keep them unless you have a reason to change. Do not use a model name plus a number as your identity. Keep the same chosen identity on later shifts. Your stable tool/roster ID stays unchanged; tells accept teammate IDs or chosen names. Introduce yourself to your teammate with say, then get to work.'
export POG_OPENING_BRIEF=${POG_OPENING_BRIEF:-'Start producing, not waiting: agree who builds power/smelting and who scouts, mines and supplies. Build a working production chain, then improve it while one teammate explores safe routes to more resources. Make tools and ammunition before risky exploration; defend yourself when attacked. Do not stand still waiting for a teammate once you have an independent useful task. If a plan is blocked, explain the concrete blocker once and choose productive work while it is resolved. After ninety seconds without a changed observation, stop repeating the same check. Record visible work and coordinate short handoffs; do not invent progress.'}
export POG_WEB_BLOCK="factorio.nickwinter.net youtube.com www.youtube.com youtu.be github.com raw.githubusercontent.com"
deny="$root /Users/owner/code/pog-operator"
for w in $(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/mt\//{print w}'); do
  case " $deny " in *" $w "*) ;; *) deny="$deny $w" ;; esac
done
export POG_DENY_READ=$deny
# Claude Code: reads scoped to the tree and the team's folder (tools/launch-agent.sh), so its settings name no other team
export POG_READ_SCOPE=1
# Nick d29 09:38: shell network closed for Codex (only its broker socket, tools/full_tools.py codex_socket_only) and
# Muse (not possible yet: Muse's restricted modes block the broker socket too, so its stays on); agy's page reads and
# browser off (POG_WEB_BLOCK above)
export POG_SHELL_NET=socket
resume=${POG_RESUME:-}
if [ "${POG_MT_FRESH:-0}" = 1 ]; then
  [ -z "$resume" ] && [ -z "${POG_MT_SAVE:-}" ] || { echo "POG_MT_FRESH conflicts with POG_RESUME/POG_MT_SAVE" >&2; exit 64; }
  export POG_MT_SAVE=${POG_MT_FRESH_SAVE:-/Users/owner/code/pog-headless-mt274/saves/mt275-final.zip}
  [ -f "$POG_MT_SAVE" ] || { echo "fresh baseline not found: $POG_MT_SAVE" >&2; exit 1; }
fi
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
  if [ -n "${POG_MT_SAVE:-}" ]; then echo "1. server: started on $POG_MT_SAVE if not running${POG_MT_FRESH:+; fresh mode refuses a running server}"
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
  echo "2b. humans: $([ "${POG_MT_HUMANS:-0}" = 1 ] && echo "on: team white, players $(grep -v '^#' agent/mt/humans.tsv | cut -f1 | tr '\n' ' ')(game password and whitelist on the server)" || echo 'off (POG_MT_HUMANS=0)')"
  echo "2c. camera: $([ "${POG_MT_CAM:-1}" = 1 ] && echo 'pog-cam1 joins on the iMac (tools/mt/imac_cam.py, about 5 GB there) and renders ./shot; copied into shots/' || echo 'off (POG_MT_CAM=0): ./shot fails')"
  echo "3. agents: one Herdr tab per team, each agent's web and network state in the log; supervisors; per-team scores and chat logs in runs/$run/op/TEAM/, the team views in runs/$run/op/views.html; idle nudges $([ "${POG_IDLE_NUDGE:-0}" = 1 ] && echo 'on (per team)' || echo off)"
  if [ "${POG_MT_PUBLIC:-0}" = 1 ]; then
    echo "4. public staging: team feeds on 8791..., overlay 127.0.0.1:${POG_MT_PUBLIC_PORT:-8790}; one pogwin spectator via reverse SSH/UDP; mt-stream scene; recording ON, streaming OFF; viewer chat through the team services"
  fi
  exit 0
fi

# Refuse a fresh reset before updating any launch files an existing run may still use.
if [ "${POG_MT_FRESH:-0}" = 1 ] && tools/mt/imac_mt.sh status | grep -q '^running'; then
  echo "refusing: POG_MT_FRESH needs a stopped server (stop the prior run first)" >&2
  exit 1
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
  [ "${POG_MT_FRESH:-0}" != 1 ] || { log "refusing: POG_MT_FRESH needs a stopped server (stop the prior run first)"; exit 1; }
  log "server: $(tools/mt/imac_mt.sh status)"
else
  save=${POG_MT_SAVE:-}
  [ -n "$save" ] || [ -z "$resume" ] || save=imac:${MT_DIR:-/Users/owner/pog-mt}/saves/mt.zip
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
# A character of the player force with no player (mt277: one at red's spawn in mt275-final, left when a setup account
# became a spectator) is no team's: every agent near it would see another force's body. Removed before agents start.
# (in a variable: bash brace-expands {a,b} in a command substitution inside double quotes, mt-net1)
stray_lua='/silent-command local n=0 for _,s in pairs(game.surfaces) do for _,e in ipairs(s.find_entities_filtered{type="character",force="player"}) do if not e.player then e.destroy() n=n+1 end end end rcon.print(n.." removed")'
log "stray bodies: $(python3 tools/pog.py --world "$world" rcon "$stray_lua" 2>&1 | cut -c1-120)"
# the player force's chat (an older save's) and each team's own (mt276 B: an operator request runs as its team field)
for t in "" $teams; do
  req="{\"id\":\"start-mt-scrub$t\",\"operator\":true${t:+,\"team\":\"$t\"},\"action\":\"mt_chat_scrub\",\"args\":{}}"
  scrub_lua="/silent-command rcon.print(remote.call('agent_harness','dispatch',[[$req]]))"
  log "chat${t:+ $t}: $(python3 tools/pog.py --world "$world" rcon "$scrub_lua" 2>&1 | cut -c1-200)"
done
mkdir -p "$rundir"
[ -n "$resume" ] && echo "$resume" > "$rundir/resumed-from"

# 2. Per team: files, bots in the team's force, the broker, the carry.
has_agy=0
for t in $teams; do
  td=$rundir/$t; mkdir -p "$td"
  team_files "$t" "$td"
  python3 tools/team_bots.py "$td/team.tsv" "$world" "$t" 2>&1 | while read -r line; do log "$t bot $line"; done
  python3 tools/mt/identities.py "$teams_file" "$t" --world "$world" --execute | while read -r line; do log "$t identity $line"; done
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

# 2b'. (mt278) POG_MT_HUMANS=1: the human team (humans.lua) set up: its roster from agent/mt/humans.tsv into its force
# when they join; the server was started with its game password and whitelist (imac_mt.sh). The team must be on the
# map (tools/mt/mt_map.py add-humans, once). POG_MT_HUMANS_ARGS: more mt_humans arguments (JSON fields, e.g.
# '"budget_h":10,"block_h":1').
if [ "${POG_MT_HUMANS:-0}" = 1 ]; then
  hreq=$(python3 - "${POG_MT_HUMANS_ARGS:-}" <<'EOF'
import json, sys
names = [l.split("\t")[0].strip() for l in open("agent/mt/humans.tsv") if l.strip() and not l.startswith("#")]
args = dict({"team": "white", "players": names}, **json.loads("{" + sys.argv[1] + "}"))
print(json.dumps({"id": "start-mt-humans", "operator": True, "action": "mt_humans", "args": args}))
EOF
)
  humans_lua="/silent-command rcon.print(remote.call('agent_harness','dispatch',[[$hreq]]))"
  log "humans: $(python3 tools/pog.py --world "$world" rcon "$humans_lua" 2>&1 | cut -c1-300)"
fi

# 2c. The camera client (pog-cam1, a director: spectator in the player force) for ./shot, and its copy into shots/.
if [ "${POG_MT_CAM:-1}" = 1 ]; then
  python3 tools/mt/imac_cam.py start 2>&1 | while read -r line; do log "camera: $line"; done
  nohup python3 tools/mt/imac_cam.py sync "$run" --tree "$tree" >"$op/cam-sync.log" 2>&1 &
  echo $! >> "$op/helpers.pid"
else
  log "camera: off (POG_MT_CAM=0): ./shot fails"
fi

# 2d. (mt284) POG_NETGATE=1: the run's network gate (tools/mt/netgate.py): a port per Grok, Muse or agy agent passing
# only its CLI's own hosts; the agent's launch gets HTTPS_PROXY and the rest in its own environment (POG_PROXY), nothing
# in ~ or the system. Refusals in op/netgate.jsonl (the team page counts them). Stopped with the helpers.
if [ "${POG_NETGATE:-0}" = 1 ]; then
  python3 tools/full_tools.py netgate-config "$op/netgate.json" "$op/netgate.tsv" "$rundir"/*/team.tsv | while read -r line; do log "netgate: $line"; done
  nohup python3 tools/mt/netgate.py "$op/netgate.json" "$op/netgate.jsonl" >"$op/netgate.err" 2>&1 &
  echo $! >> "$op/helpers.pid"
  log "netgate: pid $!, log $op/netgate.jsonl"
fi
proxy_of() { [ -f "$op/netgate.tsv" ] && awk -v n="$1" '$1 == n {print "http://127.0.0.1:" $2; exit}' "$op/netgate.tsv"; }

# Arm fresh-game objectives before any model starts, while the map still has no contacts.
if [ "$POG_GAME_TEST" = 1 ]; then
  nohup python3 tools/mt/game_test.py "$run" --minutes "$minutes" --execute >"$op/game-scenario.log" 2>&1 &
  game_pid=$!; echo "$game_pid" >> "$op/helpers.pid"
  ready=0
  for _ in $(seq 1 30); do
    if python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("phase") != "running")' "$op/game-scenario.json" 2>/dev/null; then ready=1; break; fi
    kill -0 "$game_pid" 2>/dev/null || break
    sleep 1
  done
  [ "$ready" = 1 ] || { log "fresh-game objectives failed to arm; see $op/game-scenario.log"; exit 1; }
  log "fresh-game objectives armed: production and scouting; negotiation/combat after actual contact"
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
    if out=$(POG_PROXY="$(proxy_of "$name")" POG_TEAM="$td/team.txt" POG_NO_WAIT=1 POG_TAB="$tab" POG_WS="$name" POG_BOT="$name" \
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

# 4. Supervisors (agy runs its own loop), per-team scores and chat logs, the team views, idle nudges per team (POG_IDLE_NUDGE=1).
while read -r t name pane kind; do
  [ "$kind" = agy ] && continue
  nohup tools/supervise.sh "$pane" "$rundir/$t/$name" >/dev/null 2>&1 &
  echo $! >> "$rundir/$t/supervisors.pid"
done < "$op/panes.txt"
# Per team (mt276 B: chat and the board are the team's): its force's score rows and its chat, read as its first
# agent, in op/TEAM/; tools/mt/team_views.py puts them beside the team's board and tells in op/views.html.
for t in $teams; do
  mkdir -p "$op/$t"
  POG_FORCE=$t nohup tools/score-loop.sh "$op/$t" "${POG_SCORE_EVERY:-120}" "$world" >/dev/null 2>&1 &
  echo $! >> "$op/helpers.pid"
  first_bot=$(awk -v t="$t" '$1 == t {print $2; exit}' "$op/panes.txt")
  [ -n "$first_bot" ] || continue
  nohup python3 tools/chat-log.py --world "$world" --bot "$first_bot" "$op/$t/chat.jsonl" >"$op/$t/chat-log.err" 2>&1 &
  echo $! >> "$op/helpers.pid"
done
nohup python3 tools/mt/team_views.py "$run" --every "${POG_VIEWS_EVERY:-5}" >"$op/team-views.err" 2>&1 &
echo $! >> "$op/helpers.pid"
# POG_MT_STREAM=1: the stream service per team (tools/stream/serve.py --team), its overlay at 127.0.0.1:879N (red
# 8791, then in teams-file order; 8788 is world n's): no camera calls or highlights (pog-cam1 renders the agents'
# ./shot), no OBS, replays, night lift or image show. Audience relay is separately opt-in. Its run config and state sit in the
# team's folder (its journals, token logs and its own force's facts); the director logs in op/TEAM/.
if [ "${POG_MT_STREAM:-0}" = 1 ]; then
  : > "$op/streams.txt"
  port=8791
  for t in $teams; do
    td=$rundir/$t
    python3 - "$td/team.tsv" "$td/stream.json" <<'EOF'
import json, sys
agents = {}
for line in open(sys.argv[1]):
    if line.strip() and not line.startswith("#"):
        name, kind, route, model, effort, label, harness = line.rstrip("\n").split("\t")
        agents[name] = {"model": label, "harness": harness}
json.dump({"title": "Factorio: Space Age", "subtitle": "real time", "space_age": True, "agents": agents, "cameras": [],
           "show": False, "cuts": False, "highlights": False, "replays": False, "night": False}, open(sys.argv[2], "w"), indent=1)
EOF
    viewer_args=()
    if [ "$POG_MT_VIEWERS" = 1 ]; then
      touch "$td/viewer-relay"
      viewer_args=(--viewers-relay "$td/viewer-relay" --viewers-broadcast-roster
        --viewers-hidden "${POG_HIDDEN_VIEWERS:-$root/site/hidden-viewers.json}")
      if [ -n "${POG_MT_VIEWER_REPLAY:-}" ]; then
        # Closed smoke only: the real Feed/Relay with a local recorded source.
        viewer_args+=(--viewers-replay "$POG_MT_VIEWER_REPLAY" --viewers-classifier heuristic)
      else
        viewer_args+=(--viewers-site "${POG_MT_SITE_CHAT:-https://player-of-games-live.your-subdomain.workers.dev}")
        [ -z "${POG_MT_YOUTUBE:-}" ] || viewer_args+=(--viewers-youtube "$POG_MT_YOUTUBE")
      fi
    fi
    nohup python3 tools/stream/serve.py "${viewer_args[@]}" --world "$world" --team "$t" --run "$td/stream.json" --port $port --poll 5 \
      --no-camera --no-highlights --no-replays --no-night --no-cuts --log-dir "$op/$t/stream-logs" >"$op/$t/stream-service.log" 2>&1 &
    echo $! >> "$op/helpers.pid"
    echo "$t http://127.0.0.1:$port/" >> "$op/streams.txt"
    log "$t stream: http://127.0.0.1:$port/ (pid $!)"
    port=$((port + 1))
  done
fi
if [ "${POG_MT_PUBLIC:-0}" = 1 ]; then
  if python3 tools/mt/public_stream.py start "$run" 2>&1 | tee -a "$op/start.log"; then
    log "public stream staged: mt-stream scene, recording on; OBS streaming remains OFF"
  else
    log "PUBLIC STAGING FAILED: agents and team services remain running; inspect $op/public-stream.log, then retry public_stream.py start $run"
    exit 1
  fi
fi
if [ "${POG_IDLE_NUDGE:-0}" = 1 ]; then
  for t in $teams; do
    nohup python3 tools/idle_nudge.py --run "$rundir/$t" --world "$world" >"$rundir/$t/idle-nudge.log" 2>&1 &
    echo $! >> "$rundir/$t/supervisors.pid"
  done
fi
log "supervisors, per-team scores and chat logs ($op/TEAM/) and the team views ($op/views.html) running"
