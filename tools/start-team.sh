#!/usr/bin/env bash
# Start a team run on a fresh world with bots, director cameras, overlay, recording and (optionally) the stream.
#   tools/start-team.sh RUN_ID MINUTES [--stream]
# Env: POG_TEAM_FILE (default agent/team-nine.tsv), POG_SEED (default 20261010), POG_ENEMIES (normal|peaceful, default
# normal), POG_WORLD_NAME (default n; game port 34205, RCON 27025), POG_CASTER (default 1: shoutcasters on),
# POG_YOUTUBE (@handle or video id for the YouTube chat bridge), POG_SPACE_AGE=1 (Space Age world, expansion-build
# directors, the agents' Space Age playbook section and the analyst's Space Age knowledge base).
# POG_ANALYST (default 1: analyst on; POG_ANALYST_MODEL default sonnet; POG_ANALYST_ROUTE default claude-b).
# Each team line: name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
run=$1 minutes=$2 stream=${3:-}
world=${POG_WORLD_NAME:-n} game=34205 rcon=27025
team=${POG_TEAM_FILE:-agent/team-nine.tsv}
seed=${POG_SEED:-20261010} enemies=${POG_ENEMIES:-normal}
export POG_SPACE_AGE=${POG_SPACE_AGE:-0}   # read again by tools/new-run.sh for each agent
spaceage=() factorio=()
if [ "$POG_SPACE_AGE" = 1 ]; then
  spaceage=(-SpaceAge) factorio=(-Factorio 'D:\pog\factorio-2.0.77-expansion')
  export POG_KB=${POG_KB:-space-age-2.0.77}
fi
rundir="runs/$run"; mkdir -p "$rundir"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$rundir/start.log"; }

# 1. Fresh world with the current mod (stop any previous one of this name first).
log "world $world: stopping old processes"
tools/winps.sh tools/win/stop-world.ps1 -Name "$world" >/dev/null || true
scp -q -r vendor/factorio-harness/mod/agent-harness_0.1.0 pogwin:D:/pog/mods/ 2>/dev/null
peaceful=(); [ "$enemies" = peaceful ] && peaceful=(-Peaceful)
log "world $world: creating save $run (seed $seed, $enemies enemies)"
tools/winps.sh tools/win/new-instance.ps1 -Name "$world" -Save "$run" -Seed "$seed" ${peaceful[@]+"${peaceful[@]}"} ${spaceage[@]+"${spaceage[@]}"} | grep -q FullName
scp -q ~/.config/pog/rcon-$world.pw "pogwin:D:/pog/inst/$world/rcon.pw" 2>/dev/null
tools/winps.sh tools/win/start-server.ps1 -Name "$world" -Save "$run" -GamePort $game -RconPort $rcon >/dev/null
POG_WORLD=$world bin/fh call describe >/dev/null 2>&1 || true          # first command on a fresh save is swallowed
POG_WORLD=$world bin/fh deploy >/dev/null

# 2. Director clients (players 1-3, spectators once a camera is set). They keep the server from auto-pausing.
for cam in cam1 cam2 cam3; do
  log "director $cam joining"
  sound=(); [ $cam = cam1 ] && sound=(-Sound)  # stream audio: only the main director is audible
  tools/winps.sh tools/win/start-client.ps1 -Name "$world" -GamePort $game -PlayerName "pog-$cam" -Slot "-$cam" \
    ${sound[@]+"${sound[@]}"} ${factorio[@]+"${factorio[@]}"} >/dev/null
done

# 3. Bots, one per team member.
python3 - "$team" "$world" <<'EOF'
import json, os, sys
sys.path.insert(0, "tools"); import pog
team, world = sys.argv[1:]
r = pog.Rcon("127.0.0.1", pog.PORTS[world], open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip())
for line in open(team):
    if not line.strip() or line.startswith("#"): continue
    name = line.split("\t")[0]
    print(name, r.command(f'/silent-command rcon.print(remote.call("agent_harness","bot_create","{name}"))'))
EOF

# 4. Overlay service config, reverse tunnel for OBS, scene, recording, optional stream.
python3 - "$team" "$rundir/stream.json" "$run" <<'EOF'
import json, os, sys
team, out, run = sys.argv[1:]
agents = {}
for line in open(team):
    if not line.strip() or line.startswith("#"): continue
    name, kind, route, model, effort, label, harness = line.rstrip("\n").split("\t")
    agents[name] = {"model": label, "harness": harness}
words = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten"}
json.dump({"title": f"{words.get(len(agents), len(agents))} AIs, one factory", "subtitle": ("Factorio: Space Age" if os.environ.get("POG_SPACE_AGE") == "1" else "Factorio") + " co-op · real time · no cheats",
           "agents": agents, "cameras": [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2},
                                         {"slot": "cam3", "player": 3}]}, open(out, "w"), indent=1)
EOF
# Viewer chat: the companion site's chat always; YouTube when POG_YOUTUBE (an @handle, channel id or video id) is set.
viewers=(--viewers-site); [ -n "${POG_YOUTUBE:-}" ] && viewers+=(--viewers-youtube "$POG_YOUTUBE")
nohup python3 tools/stream/serve.py --world "$world" --run "$rundir/stream.json" --port 8788 "${viewers[@]}" \
  >"$rundir/stream-service.log" 2>&1 &
echo $! > "$rundir/stream-service.pid"
nohup ssh -N -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -R 8787:127.0.0.1:8788 pogwin >/dev/null 2>&1 &
echo $! > "$rundir/overlay-tunnel.pid"
sleep 3
tools/.venv/bin/python tools/obs.py stream-scene >/dev/null
tools/.venv/bin/python tools/obs.py scene stream >/dev/null
tools/.venv/bin/python tools/obs.py reload-overlay >/dev/null || true
tools/.venv/bin/python tools/obs.py start
[ "$stream" = --stream ] && tools/.venv/bin/python tools/obs.py stream-start

first_bot=$(awk -F'\t' '!/^#/ && NF {print $1; exit}' "$team")
nohup python3 tools/chat-log.py --world "$world" --bot "$first_bot" "$rundir/chat.jsonl" >"$rundir/chat-log.err" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
# ./shot: bots have no client, so a director renders each screenshot; this copies them into the workspaces.
nohup tools/shot-sync.sh "$rundir" "$world-client-cam1" "$world-client-cam2" "$world-client-cam3" \
  >"$rundir/shot-sync.log" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
# Shoutcasters and voiced agent lines (docs/AUDIO-NOTES.md); POG_CASTER=0 turns them off.
if [ "${POG_CASTER:-1}" != 0 ]; then
  nohup python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --tts auto --tts-fallback aura1 >"$rundir/caster.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
fi
# The companion site's live page (site/push_live.py; token in site/worker/.secrets.json, gitignored).
if [ -f site/worker/.secrets.json ] || [ -n "${POG_LIVE_TOKEN:-}" ]; then
  nohup python3 site/push_live.py --source http://127.0.0.1:8788/state.json >"$rundir/push-live.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
fi
# Analyst: talking points for the casters every 90 s, read-only (docs/ANALYST-NOTES.md); POG_ANALYST=0 turns it off.
if [ "${POG_ANALYST:-1}" != 0 ]; then
  # Its own Claude route, like the agents' (tools/launch-agent.sh), not whatever session started the run.
  aroute=${POG_ANALYST_ROUTE:-claude-b}
  aroot=$(/Users/owner/.local/bin/ai-session routes | awk -v r="$aroute" '$1 == r && $2 == "claude" {print $NF}')
  aenv=(-u CLAUDE_CONFIG_DIR); [ "$aroute" = claude ] || aenv=("CLAUDE_CONFIG_DIR=$aroot")
  nohup env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
    "${aenv[@]}" ENABLE_CLAUDEAI_MCP_SERVERS=false python3 tools/stream/analyst.py --world "$world" --bot "$first_bot" --feed http://127.0.0.1:8788 \
    --run-dir "$rundir" --model "${POG_ANALYST_MODEL:-sonnet}" --every 90 --ask-port 8789 >"$rundir/analyst.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
fi

# 5. Agents: three per Herdr tab, real time, team playbook.
POG_TEAM="$rundir/team.txt"
awk -F'\t' '!/^#/ && NF {print $1 "|" $6 " (" $7 ")"}' "$team" > "$POG_TEAM"
export POG_TEAM POG_TIME_MODE=realtime POG_ENEMIES=$enemies POG_SEED=$seed
n=0 tab=""
while IFS=$'\t' read -r name kind route model effort label harness; do
  [ -z "$name" ] || [[ $name == \#* ]] && continue
  [ $((n % 3)) -eq 0 ] && tab=""
  out=$(POG_TAB="$tab" POG_WS="$name" POG_BOT="$name" POG_MODEL="$label ($harness)" POG_ROUTE="$route" \
        tools/launch-agent.sh "$run" "$world" "$name" "$minutes" "$kind" "$model" "$effort")
  pane=$(echo "$out" | awk '{print $1}'); tab=$(echo "$out" | awk '{print $2}')
  log "agent $name ($label, $kind) in pane $pane tab $tab"
  echo "$name $pane $kind" >> "$rundir/panes.txt"
  n=$((n + 1))
done < "$team"
log "started: $(wc -l < "$rundir/panes.txt") agents; deadline $(cat "$rundir"/*/deadline.txt | head -1)"

# 6. Supervisors (agy runs its own loop until the deadline).
while read -r name pane kind; do
  [ "$kind" = agy ] && continue
  nohup tools/supervise.sh "$pane" "$rundir/$name" >/dev/null 2>&1 &
  echo $! >> "$rundir/supervisors.pid"
done < "$rundir/panes.txt"
log "supervisors running"
nohup tools/score-loop.sh "$rundir" 120 "$world" >/dev/null 2>&1 &
echo $! > "$rundir/score-loop.pid"
