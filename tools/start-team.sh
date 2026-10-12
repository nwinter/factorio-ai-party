#!/usr/bin/env bash
# Start a team run on a fresh world with bots, director cameras, overlay, recording and (optionally) the stream.
#   tools/start-team.sh RUN_ID MINUTES [--stream]
# Env: POG_TEAM_FILE (default agent/team-nine.tsv), POG_SEED (default 20261010), POG_ENEMIES (normal|peaceful, default
# normal), POG_WORLD_NAME (default n; game port 34205, RCON 27025), POG_CASTER (default 1: shoutcasters on),
# POG_YOUTUBE (@handle or video id for the YouTube chat bridge; default @NickWinter), POG_SPACE_AGE=1 (Space Age world, expansion-build
# directors, the agents' Space Age playbook section and the analyst's Space Age knowledge base).
# POG_ANALYST (default 1: analyst on; POG_ANALYST_MODEL default sonnet; POG_ANALYST_ROUTE default claude-b).
# POG_VIEWER_RELAY (default 1: viewer lines that pass the filters and Clef reach the agents in game chat; 0: off).
# POG_RESUME=PREVIOUS_RUN: a later shift of the same world (docs/SPACEAGE.md, shifts): no new instance; the server
# starts on the newest of saves\PREVIOUS_RUN.zip and the autosaves after it (copied to saves\RUN_ID.zip), existing bots
# are kept, and each agent starts from its notes.md of that run. POG_SPACE_AGE must match the instance's mods.
# POG_RESUME_DIR: the previous run's directory (default runs/PREVIOUS_RUN here, else in ~/code/player-of-games).
# POG_DRY_RUN=1: check what can be checked here and print the plan; touches nothing.
# Each team line: name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
run=$1 minutes=$2 stream=${3:-}
world=${POG_WORLD_NAME:-n} game=34205 rcon=27025
team=${POG_TEAM_FILE:-agent/team-nine.tsv}
seed=${POG_SEED:-20261010} enemies=${POG_ENEMIES:-normal}
export POG_SPACE_AGE=${POG_SPACE_AGE:-0}   # read again by tools/new-run.sh for each agent
# Voices agents may pick: POG_TTS_OFF=eleven leaves ElevenLabs' voices out (as when it ran out of credits on
# 2026-10-10; working again 2026-10-11 with auto top-up). The hosts stay on OpenAI unless POG_TTS_PREFER=eleven.
export POG_TTS_OFF=${POG_TTS_OFF-}
# YouTube chat: Nick's channel by default. An unlisted broadcast may not show on the channel's /live page; then
# pass the video id instead (POG_YOUTUBE=VIDEO_ID).
export POG_YOUTUBE=${POG_YOUTUBE-@NickWinter}
spaceage=() factorio=()
if [ "$POG_SPACE_AGE" = 1 ]; then
  spaceage=(-SpaceAge) factorio=(-Factorio 'D:\pog\factorio-2.0.77-expansion')
  export POG_KB=${POG_KB:-space-age-2.0.77}
fi
resume=${POG_RESUME:-}
if [ -n "$resume" ]; then
  prev_dir=${POG_RESUME_DIR:-}
  if [ -z "$prev_dir" ]; then
    for d in "$root/runs/$resume" "$HOME/code/player-of-games/runs/$resume"; do [ -d "$d" ] && { prev_dir=$d; break; }; done
  fi
  [ -n "$prev_dir" ] && [ -d "$prev_dir" ] || { echo "POG_RESUME=$resume: no run directory runs/$resume here or in ~/code/player-of-games/runs; set POG_RESUME_DIR" >&2; exit 1; }
  [ "$resume" != "$run" ] || { echo "POG_RESUME names this run ($run); a shift needs a new run id" >&2; exit 1; }
  # A run whose agents never launched has no notes (shake9: its start failed after the save copy, and shake10's agents
  # began with empty notes). The save still comes from POG_RESUME; the notes come from the newest run up its
  # resumed-from chain that has any.
  hops=0
  while ! ls "$prev_dir"/*/notes.md >/dev/null 2>&1 && [ -f "$prev_dir/resumed-from" ] && [ $hops -lt 5 ]; do
    up=$(head -1 "$prev_dir/resumed-from"); [ -d "$(dirname "$prev_dir")/$up" ] || break
    echo "POG_RESUME=$resume: $prev_dir has no agent notes; taking notes from $up" >&2
    prev_dir=$(dirname "$prev_dir")/$up; hops=$((hops + 1))
  done
  export POG_RESUME POG_RESUME_DIR=$prev_dir   # tools/new-run.sh and tools/launch-agent.sh read them
fi
members=$(awk -F'\t' '!/^#/ && NF {print $1}' "$team")
# Quota headroom per route from ai-usage, read-only (docs/studies/shake5.md, P1 item 6: Gemini began shake5 at 72% of
# its 5-hour window and ran dry 47 minutes in). Warnings only; the run starts anyway. POG_QUOTA_BRIEF: a saved
# `ai-usage agent --json` to use instead (tests).
quota() { python3 tools/quota_check.py "$team" "$minutes" ${POG_QUOTA_BRIEF:+--brief "$POG_QUOTA_BRIEF"} || true; }
if [ "${POG_DRY_RUN:-0}" = 1 ]; then
  echo "plan for $run ($minutes min) on world $world (game $game, rcon $rcon), team $team: $(echo $members)"
  quota
  python3 tools/code_check.py || true
  if [ -n "$resume" ]; then
    echo "1. resume: tools/winps.sh tools/win/resume-save.ps1 -Name $world -From $resume -Check (refuse unless space_age=$POG_SPACE_AGE);"
    echo "   stop world $world; copy the newest of saves\\$resume.zip and later autosaves to saves\\$run.zip; refresh the instance's harness mod;"
    echo "   start the server on $run.zip; deploy the runtime; write runs/$run/resumed-from"
    last=$(tail -1 "$prev_dir/scores.jsonl" 2>/dev/null | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["score"]["tick"]; print(f"tick {t} (game {t//3600}m)")' 2>/dev/null || echo "no scores.jsonl")
    echo "   previous run $prev_dir: last score $last"
  else
    echo "1. fresh: stop world $world, new instance save $run (seed $seed, $enemies enemies, space_age=$POG_SPACE_AGE), start server, deploy"
  fi
  echo "2. directors cam1..3 join"
  for name in $members; do
    if [ -n "$resume" ]; then
      if [ -f "$prev_dir/$name/notes.md" ]; then notes="notes.md from $prev_dir/$name ($(wc -l < "$prev_dir/$name/notes.md" | tr -d ' ') lines)"; else notes="fresh notes.md (none in $resume)"; fi
      echo "3. bot $name: kept if the save has it, else created; $notes"
    else
      echo "3. bot $name: created; fresh notes.md"
    fi
  done
  echo "4. stream service, chat log, shot sync$([ "${POG_CASTER:-1}" != 0 ] && echo ', casters')$([ "${POG_ANALYST:-1}" != 0 ] && echo ', analyst')$([ "${POG_PLAYERS:-0}" = 1 ] && echo ', player votes'), recording$([ "$stream" = --stream ] && echo ', stream')"
  [ "${POG_BROKER:-0}" = 1 ] && echo "4b. RCON broker (POG_BROKER=1): sockets runs/$run/.sock/NAME.sock for $(echo $members); no key in the run"
  echo "5. agents launch$([ "${POG_FULL_TOOLS:-0}" = 1 ] && echo ' with full tools (POG_FULL_TOOLS=1: tools/, team-tools/, gamedata/, subagents, web)'); 6. supervisors and score loop"
  [ -n "$resume" ] && echo "prompt adds: $(tools/launch-agent.sh --resume-sentence)"
  exit 0
fi
rundir="runs/$run"; mkdir -p "$rundir"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$rundir/start.log"; }
quota | while read -r line; do log "$line"; done
# Launch from the code the fixes are in (docs/studies/shake5.md, P1 item 7): harness and stream commits on main or a
# recent branch that this checkout lacks, and a built host older than its sources. Warnings only.
{ python3 tools/code_check.py || true; } | while read -r line; do log "$line"; done
log "full tools: $([ "${POG_FULL_TOOLS:-0}" = 1 ] && echo 'on (docs/TOOLS-NOTES.md)' || echo off)"
log "RCON broker: $([ "${POG_BROKER:-0}" = 1 ] && echo 'on (agents get no password; docs/LAUNCH-NOTES.md)' || echo 'off (agents read runs/RUN/.keys)')"
log "player votes: $([ "${POG_PLAYERS:-0}" = 1 ] && echo "on (docs/PLAYERS-NOTES.md; protected: ${POG_PLAYERS_PROTECT:-none})" || echo off)"

if [ -n "$resume" ]; then
  # 1. A later shift: the same instance and save (docs/HARNESS3-NOTES.md, round 7).
  log "world $world: resuming run $resume ($prev_dir)"
  check=$(tools/winps.sh tools/win/resume-save.ps1 -Name "$world" -From "$resume" -Check) || true
  printf '%s\n' "$check" | while read -r line; do log "  $line"; done
  save_sa=$(printf '%s\n' "$check" | sed -n 's/^space_age=\([01]\).*/\1/p')
  [ -n "$save_sa" ] || { log "resume check failed: $(printf '%s' "$check" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  if [ "$save_sa" != "$POG_SPACE_AGE" ]; then
    log "refusing: world $world's mods have space-age $([ "$save_sa" = 1 ] && echo on || echo off) but POG_SPACE_AGE=$POG_SPACE_AGE; run again with POG_SPACE_AGE=$save_sa"
    exit 1
  fi
  log "world $world: stopping old processes"
  tools/winps.sh tools/win/stop-world.ps1 -Name "$world" >/dev/null || true
  scp -q -r vendor/factorio-harness/mod/agent-harness_0.1.0 pogwin:D:/pog/mods/ 2>/dev/null
  copied=$(tools/winps.sh tools/win/resume-save.ps1 -Name "$world" -From "$resume" -To "$run") || true
  printf '%s\n' "$copied" | grep -q '^copied=' || { log "resume copy failed: $(printf '%s' "$copied" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  log "world $world: $(printf '%s\n' "$copied" | grep '^save=') copied to $run.zip"
  echo "$resume" > "$rundir/resumed-from"
else
  # 1. Fresh world with the current mod (stop any previous one of this name first).
  log "world $world: stopping old processes"
  tools/winps.sh tools/win/stop-world.ps1 -Name "$world" >/dev/null || true
  scp -q -r vendor/factorio-harness/mod/agent-harness_0.1.0 pogwin:D:/pog/mods/ 2>/dev/null
  peaceful=(); [ "$enemies" = peaceful ] && peaceful=(-Peaceful)
  log "world $world: creating save $run (seed $seed, $enemies enemies)"
  tools/winps.sh tools/win/new-instance.ps1 -Name "$world" -Save "$run" -Seed "$seed" ${peaceful[@]+"${peaceful[@]}"} ${spaceage[@]+"${spaceage[@]}"} | grep -q FullName
  scp -q ~/.config/pog/rcon-$world.pw "pogwin:D:/pog/inst/$world/rcon.pw" 2>/dev/null
fi
tools/winps.sh tools/win/start-server.ps1 -Name "$world" -Save "$run" -GamePort $game -RconPort $rcon >/dev/null
# Wait for RCON before deploying: after a reboot the server took 21 s to open it, and the deploy at 19 s failed
# (shake9's first start). The first command on a fresh save is swallowed, so this also absorbs that one.
for _ in $(seq 1 45); do POG_WORLD=$world bin/fh call describe >/dev/null 2>&1 && break; sleep 2; done
deployed=$(POG_WORLD=$world bin/fh deploy --format json 2>/dev/null || true)
deploy_status=$(printf '%s' "$deployed" | python3 tools/code_check.py --deploy-reply)
log "runtime deployed from $(git rev-parse --short HEAD): $deploy_status"
case $deploy_status in ok*) ;; *) exit 1 ;; esac   # as before: no agents on a world without the runtime
# A fresh save puts every player's first join in the guest group (docs/PLAYERS-NOTES.md); the operator's own names
# (POG_TRUSTED_PLAYERS, default nick; empty for none) join in the normal group.
trusted=${POG_TRUSTED_PLAYERS-nick}
[ -n "$trusted" ] && log "trusted players: $(python3 tools/players.py --world "$world" trust-names $trusted 2>&1 | tail -1)"
if [ -n "$resume" ]; then
  # A save made while tick-paused would load paused; team runs are real time. Game time goes on from the save's tick.
  python3 tools/pog.py --world "$world" resume >/dev/null 2>&1 || true
  tick=$(python3 tools/pog.py --world "$world" score 2>/dev/null | python3 -c 'import json,sys; t=json.load(sys.stdin)["tick"]; print(f"{t} (game {t // 3600}m)")' 2>/dev/null || echo '?')
  log "world $world: resumed at tick $tick"
  # Losses in this shift start new incidents; the previous shift's stay in status alerts history.
  closed=$(python3 tools/pog.py --world "$world" rcon '/silent-command rcon.print(remote.call("agent_harness","shift_start"))' 2>&1)
  log "world $world: shift_start $closed"
fi

# 2. Director clients (players 1-3, spectators once a camera is set). They keep the server from auto-pausing.
for cam in cam1 cam2 cam3; do
  log "director $cam joining"
  sound=(); [ $cam = cam1 ] && sound=(-Sound)  # stream audio: only the main director is audible
  tools/winps.sh tools/win/start-client.ps1 -Name "$world" -GamePort $game -PlayerName "pog-$cam" -Slot "-$cam" \
    ${sound[@]+"${sound[@]}"} ${factorio[@]+"${factorio[@]}"} >/dev/null
done

# 3. Bots, one per team member; a resumed save keeps its bots (only members it lacks are created).
python3 tools/team_bots.py "$team" "$world" | while read -r line; do log "bot $line"; done

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
           "space_age": os.environ.get("POG_SPACE_AGE") == "1", "agents": agents, "cameras": [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2},
                                         {"slot": "cam3", "player": 3}]}, open(out, "w"), indent=1)
EOF
# Viewer chat: the companion site's chat always; YouTube when POG_YOUTUBE (an @handle, channel id or video id) is set.
viewers=(--viewers-site); [ -n "${POG_YOUTUBE:-}" ] && viewers+=(--viewers-youtube "$POG_YOUTUBE")
# Viewer lines that pass the filters and Clef go into the game as `viewer NAME: text` while this switch file exists:
# on unless POG_VIEWER_RELAY=0; `rm runs/RUN/viewers-relay.on` stops it mid-run, `touch` starts it (checked every 2 s).
viewers+=(--viewers-relay "$rundir/viewers-relay.on")
if [ "${POG_VIEWER_RELAY:-1}" = 1 ]; then touch "$rundir/viewers-relay.on"; else rm -f "$rundir/viewers-relay.on"; fi
nohup python3 tools/stream/serve.py --world "$world" --run "$rundir/stream.json" --port 8788 "${viewers[@]}" \
  >"$rundir/stream-service.log" 2>&1 &
echo $! > "$rundir/stream-service.pid"
helpers=("stream-service:$!:$rundir/stream-service.log")
# POG_OBS=0: no overlay tunnel, scene, recording or stream (test shifts). OBS control needs the obsws venv; a worktree
# without one uses the main checkout's.
if [ "${POG_OBS:-1}" != 0 ]; then
  py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
  nohup ssh -N -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -R 8787:127.0.0.1:8788 pogwin >/dev/null 2>&1 &
  echo $! > "$rundir/overlay-tunnel.pid"
  sleep 3
  "$py" tools/obs.py stream-scene >/dev/null
  "$py" tools/obs.py scene stream >/dev/null
  "$py" tools/obs.py reload-overlay >/dev/null || true
  "$py" tools/obs.py start
  [ "$stream" = --stream ] && "$py" tools/obs.py stream-start
else
  log "POG_OBS=0: no overlay tunnel, recording or stream"
fi

first_bot=$(awk -F'\t' '!/^#/ && NF {print $1; exit}' "$team")
nohup python3 tools/chat-log.py --world "$world" --bot "$first_bot" "$rundir/chat.jsonl" >"$rundir/chat-log.err" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
helpers+=("chat-log:$!:$rundir/chat-log.err")
# ./shot: bots have no client, so a director renders each screenshot; this copies them into the workspaces.
nohup tools/shot-sync.sh "$rundir" "$world-client-cam1" "$world-client-cam2" "$world-client-cam3" \
  >"$rundir/shot-sync.log" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
helpers+=("shot-sync:$!:$rundir/shot-sync.log")
# Shoutcasters and voiced agent lines (docs/AUDIO-NOTES.md); POG_CASTER=0 turns them off.
if [ "${POG_CASTER:-1}" != 0 ]; then
  # --deadline: the agents' deadline.txt files (written as they launch, after this) give the hosts the time left;
  # --run-dir: its resumed-from (POG_RESUME) tells the hosts this is a later shift of a saved world
  # The hosts' writer: POG_CASTER_MODEL on OpenRouter (Nick picked Opus 5.5 from the 2026-10-11 writer comparison,
  # docs/AUDIO-NOTES.md); urgent beats stay on the fast Workers AI model. Empty, or no OpenRouter key: Workers AI.
  cmodel=${POG_CASTER_MODEL-anthropic/claude-opus-5.5} writer=()
  orkey=${OPENROUTER_API_KEY:-$(security find-generic-password -s openrouter -w 2>/dev/null || true)}
  [ -n "$cmodel" ] && [ -n "$orkey" ] && writer=(--writer or --model "$cmodel")
  # POG_CASTER_URGENT: the urgent beats' writer (default Kimi on Workers AI); e.g. or:anthropic/claude-haiku-5.5
  [ -n "${POG_CASTER_URGENT:-}" ] && writer+=(--urgent-model "$POG_CASTER_URGENT")
  OPENROUTER_API_KEY=$orkey nohup python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --tts auto --tts-fallback aura1 \
    --deadline "$rundir/*/deadline.txt" --run-dir "$rundir" ${writer[@]+"${writer[@]}"} >"$rundir/caster.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("caster:$!:$rundir/caster.log")
fi
# The companion site's live page (site/push_live.py; token in site/worker/.secrets.json, gitignored).
if [ -f site/worker/.secrets.json ] || [ -n "${POG_LIVE_TOKEN:-}" ]; then
  nohup python3 site/push_live.py --source http://127.0.0.1:8788/state.json >"$rundir/push-live.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("push-live:$!:$rundir/push-live.log")
fi
# Human players' votes (docs/PLAYERS-NOTES.md): the operator tally runs a carried kick, ban or trust; names in
# POG_PLAYERS_PROTECT (comma-separated) are never kicked or banned.
if [ "${POG_PLAYERS:-0}" = 1 ]; then
  nohup python3 tools/players.py --world "$world" watch --log "$rundir/votes.jsonl" >"$rundir/players.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("players:$!:$rundir/players.log")
fi
# Analyst: talking points for the casters every 90 s, read-only (docs/ANALYST-NOTES.md); POG_ANALYST=0 turns it off.
if [ "${POG_ANALYST:-1}" != 0 ]; then
  # Its own Claude route, like the agents' (tools/launch-agent.sh), not whatever session started the run.
  aroute=${POG_ANALYST_ROUTE:-claude-b}
  aroot=$(/Users/owner/.local/bin/ai-session routes | awk -v r="$aroute" '$1 == r && $2 == "claude" {print $NF}')
  aenv=(-u CLAUDE_CONFIG_DIR); [ "$aroute" = claude ] || aenv=("CLAUDE_CONFIG_DIR=$aroot")
  # Viewer questions from the site/YouTube lane, one answer per 150 s at most, voiced by the hosts; POG_VIEWER_QUESTIONS=0 off.
  aflags=(); [ "${POG_VIEWER_QUESTIONS:-1}" != 0 ] && aflags+=(--viewer-questions)
  nohup env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
    "${aenv[@]}" ENABLE_CLAUDEAI_MCP_SERVERS=false python3 tools/stream/analyst.py --world "$world" --bot "$first_bot" --feed http://127.0.0.1:8788 \
    --run-dir "$rundir" --model "${POG_ANALYST_MODEL:-sonnet}" --every 90 --ask-port 8789 ${aflags[@]+"${aflags[@]}"} >"$rundir/analyst.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("analyst:$!:$rundir/analyst.log")
fi
# What code the helpers run, and whether each came up (docs/studies/shake3.md, P1 item 2).
log "code $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- tools agent vendor 2>/dev/null || echo ' plus uncommitted changes')"
sleep 8
for h in "${helpers[@]}"; do
  IFS=: read -r hname hpid hlog <<<"$h"
  if kill -0 "$hpid" 2>/dev/null; then log "helper $hname pid $hpid up: $(head -1 "$hlog" 2>/dev/null | cut -c1-120)"
  else log "helper $hname pid $hpid FAILED: $(tail -2 "$hlog" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; fi
done

# 4b. The RCON broker (POG_BROKER=1, tools/fh_broker.py): it holds the password, the run has no key, and each
# agent's fh talks to its own socket runs/RUN/.sock/NAME.sock. Stopped with the helpers (stream-service.pid).
if [ "${POG_BROKER:-0}" = 1 ]; then
  nohup python3 tools/fh_broker.py --world "$world" --port "$rcon" --dir "$rundir/.sock" --log "$rundir/broker.log" \
    $members >"$rundir/broker.err" 2>&1 &
  broker_pid=$!
  echo $broker_pid >> "$rundir/stream-service.pid"
  last=$(echo $members | awk '{print $NF}')
  for i in $(seq 1 20); do [ -S "$rundir/.sock/$last.sock" ] && break; sleep 0.5; done
  if [ -S "$rundir/.sock/$last.sock" ]; then log "broker: pid $broker_pid, sockets for $(echo $members)"
  else log "broker FAILED: $(tail -2 "$rundir/broker.err" | tr '\n' ' ' | cut -c1-200)"; exit 1; fi
fi

# POG_FULL_TOOLS=1: Muse's team-tools is a folder of its own, mirrored with the shared one (tools/full_tools.py).
if [ "${POG_FULL_TOOLS:-0}" = 1 ]; then
  nohup python3 tools/full_tools.py sync "$rundir" 5 >"$rundir/team-tools-sync.log" 2>&1 &
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
  # POG_NO_WAIT: start every pane now and clear the trust prompts of all of them in one pass below (shake3: the
  # per-pane 40 s wait ran out for five agents and the launch took 4.5 minutes).
  out=$(POG_NO_WAIT=1 POG_TAB="$tab" POG_WS="$name" POG_BOT="$name" POG_MODEL="$label ($harness)" POG_ROUTE="$route" \
        tools/launch-agent.sh "$run" "$world" "$name" "$minutes" "$kind" "$model" "$effort")
  pane=$(echo "$out" | awk '{print $1}'); tab=$(echo "$out" | awk '{print $2}')
  log "agent $name ($label, $kind) in pane $pane tab $tab"
  echo "$name $pane $kind" >> "$rundir/panes.txt"
  n=$((n + 1))
done < "$team"
prompt_args=()
while read -r name pane kind; do prompt_args+=("$pane" "$rundir/$name"); done < "$rundir/panes.txt"
tools/clear-prompts.sh 90 "${prompt_args[@]}" | while read -r pane how; do log "pane $pane: $how"; done
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
