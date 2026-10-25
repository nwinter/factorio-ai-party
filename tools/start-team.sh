#!/usr/bin/env bash
# Start a team run on a fresh world with bots, director cameras, overlay, recording and (optionally) the stream.
#   tools/start-team.sh RUN_ID MINUTES [--stream]
# Env: POG_TEAM_FILE (default agent/team-nine.tsv), POG_SEED (default 20261010), POG_ENEMIES (normal|peaceful, default
# normal), POG_WORLD_NAME (default n; game port 34205, RCON 27025), POG_CASTER (default 1: shoutcasters on),
# POG_YOUTUBE (@handle or video id for the YouTube chat bridge; default @NickWinter), POG_SPACE_AGE=1 (Space Age world, expansion-build
# directors, the agents' Space Age playbook section and the analyst's Space Age knowledge base).
# POG_ANALYST (default 1: analyst on; POG_ANALYST_MODEL default sonnet; POG_ANALYST_ROUTE default claude-c).
# POG_VIEWER_RELAY (default 1: viewer lines that pass the filters and Clef reach the agents in game chat; 0: off).
# POG_VIEWER_ROUTE (default 0; 1: a viewer line that names no agent goes by what it is about, tools/stream/router.py).
# POG_RESUME=PREVIOUS_RUN: a later shift of the same world (docs/SPACEAGE.md, shifts): no new instance; the server
# starts on the previous run's stop save (its stopped.json, written by tools/stop-team.sh), else the newest save
# written after its stop, else the newest save (tools/win/resume-save.ps1; copied to saves\RUN_ID.zip); the tick it
# resumes at is checked against the previous run's last (tools/resume_guard.py; refused when it went back more than
# POG_RESUME_TICK_SLACK ticks, default 18 game minutes); existing bots are kept, and each agent starts from its
# notes.md of that run. POG_SPACE_AGE must match the instance's mods.
# POG_RESUME_DIR: the previous run's directory (default runs/PREVIOUS_RUN here, else in ~/code/player-of-games).
# POG_DRY_RUN=1: check what can be checked here and print the plan; touches nothing. With POG_RESUME, POG_DRY_RUN_PICK=1
# also asks the Windows box which save it would take (resume-save.ps1 -Check: read only, safe while the world runs).
# --stream: OBS is restarted first (tools/obs-restart.sh; POG_OBS_RESTART=0 skips it, POG_OBS_RESTARTED=1 says the
# caller did), then tools/obs-steps.sh --stream (scene, overlay, recording, stream, vertical).
# Each team line: name<TAB>kind<TAB>route<TAB>model<TAB>effort<TAB>label<TAB>harness
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
# (d24 batch186) a plan only (POG_DRY_RUN=1, or a test run, POG_TEST=1) marks itself for tools/shift-change.sh, which
# refuses while another start-team runs in this checkout: the gate runs test_resume's dry runs in the live checkout
plan_mark=""
if [ "${POG_DRY_RUN:-0}" = 1 ] || [ "${POG_TEST:-0}" = 1 ]; then
  plan_mark="${TMPDIR:-/tmp}/pog-start-team-plan.$$"; : > "$plan_mark"; trap 'rm -f "$plan_mark"' EXIT
fi
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
  carry_from=$prev_dir   # tools/full_tools.py carry walks the same chain for each agent's tools/ and team-tools/
  hops=0
  while ! ls "$prev_dir"/*/notes.md >/dev/null 2>&1 && [ -f "$prev_dir/resumed-from" ] && [ $hops -lt 5 ]; do
    up=$(head -1 "$prev_dir/resumed-from"); [ -d "$(dirname "$prev_dir")/$up" ] || break
    echo "POG_RESUME=$resume: $prev_dir has no agent notes; taking notes from $up" >&2
    prev_dir=$(dirname "$prev_dir")/$up; hops=$((hops + 1))
  done
  export POG_RESUME POG_RESUME_DIR=$prev_dir   # tools/new-run.sh and tools/launch-agent.sh read them
  # The previous run's stop record (tools/stop_save.py, in its own directory, not the notes one): which save it wrote
  # and when, by the Windows box's clock (operator 17:00: after a crash restart the 15:55 change took a 10:48 save).
  stop_dir=$carry_from
  stop_utc='' stop_save='' stop_tick=''
  if [ -f "$stop_dir/stopped.json" ]; then
    read -r stop_utc stop_save stop_tick < <(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("stop_utc") or "-", r.get("save") or "-", r.get("tick") if r.get("tick") is not None else "-")' "$stop_dir/stopped.json") || true
    [ "$stop_utc" = - ] && stop_utc=''; [ "$stop_save" = - ] && stop_save=''; [ "$stop_tick" = - ] && stop_tick=''
  fi
  stop_args=()
  [ -n "$stop_utc" ] && stop_args+=(-StopUtc "$stop_utc")
  [ -n "$stop_save" ] && stop_args+=(-StopSave "$stop_save")
fi
members=$(awk -F'\t' '!/^#/ && NF {print $1}' "$team")
has_agy=$(awk -F'\t' '!/^#/ && NF && $2 == "agy" {f = 1} END {print f + 0}' "$team")
# Quota headroom per route from ai-usage, read-only (docs/studies/shake5.md, P1 item 6: Gemini began shake5 at 72% of
# its 5-hour window and ran dry 47 minutes in). Warnings only; the run starts anyway. POG_QUOTA_BRIEF: a saved
# `ai-usage agent --json` to use instead (tests).
# --save FILE keeps the brief for the quota rests after the agents launch (step 5).
quota() { python3 tools/quota_check.py "$team" "$minutes" ${POG_QUOTA_BRIEF:+--brief "$POG_QUOTA_BRIEF"} "$@" || true; }
if [ "${POG_DRY_RUN:-0}" = 1 ]; then
  echo "plan for $run ($minutes min) on world $world (game $game, rcon $rcon), team $team: $(echo $members)"
  qbrief=$(mktemp); trap 'rm -f "$qbrief" ${plan_mark:+"$plan_mark"}' EXIT
  quota --save "$qbrief"
  python3 tools/code_check.py || true
  if [ -n "$resume" ]; then
    echo "1. resume: tools/winps.sh tools/win/resume-save.ps1 -Name $world -From $resume -Check (refuse unless space_age=$POG_SPACE_AGE);"
    echo "   stop world $world; copy the previous run's stop save (else the newest save after its stop; with no stop record the newest save) to saves\\$run.zip; refresh the instance's harness mod;"
    echo "   start the server on $run.zip; deploy the runtime; write runs/$run/resumed-from"
    if [ -n "$stop_utc" ]; then
      echo "   stop record $stop_dir/stopped.json: tick $stop_tick, save ${stop_save:-none (it fell back to /server-save)} at $stop_utc: resume-save gets ${stop_args[*]}"
    else
      echo "   no stop record in $stop_dir (stopped.json): resume-save takes the newest save"
    fi
    if [ "${POG_DRY_RUN_PICK:-0}" = 1 ]; then
      tools/winps.sh tools/win/resume-save.ps1 -Name "$world" -From "$resume" ${stop_args[@]+"${stop_args[@]}"} -Check 2>&1 | sed 's/^/   pick: /'
    fi
    last=$(tail -1 "$prev_dir/scores.jsonl" 2>/dev/null | python3 -c 'import json,sys; t=json.loads(sys.stdin.read())["score"]["tick"]; print(f"tick {t} (game {t//3600}m)")' 2>/dev/null || echo "no scores.jsonl")
    echo "   previous run $prev_dir: last score $last"
  else
    echo "1. fresh: stop world $world, new instance save $run (seed $seed, $enemies enemies, space_age=$POG_SPACE_AGE), start server, deploy"
  fi
  echo "2. directors $(python3 tools/cams.py list) join one at a time (tools/start-cams.sh: each in the game before the next, up to ${POG_CAM_WAIT:-180} s, a stuck one restarted once; then OBS's camera captures rehooked)"
  for name in $members; do
    if [ -n "$resume" ]; then
      src=$(python3 tools/full_tools.py notes-from "$prev_dir" "$name" 2>/dev/null || true); src=${src:-$prev_dir}   # (tools/new-run.sh)
      if [ -f "$src/$name/notes.md" ]; then notes="notes.md from $src/$name ($(wc -l < "$src/$name/notes.md" | tr -d ' ') lines)"; else notes="fresh notes.md (none in $resume)"; fi
      echo "3. bot $name: kept if the save has it, else created; $notes"
    else
      echo "3. bot $name: created; fresh notes.md"
    fi
  done
  [ -n "$resume" ] && python3 tools/full_tools.py carry --dry-run "runs/$run" "$carry_from" $members | sed 's/^/3b. /' || true
  echo "4. stream service, chat log, shot sync$([ "${POG_CASTER:-1}" != 0 ] && echo ', casters')$([ "${POG_ANALYST:-1}" != 0 ] && echo ', analyst')$([ "${POG_PLAYERS:-0}" = 1 ] && echo ', player votes'), recording$([ "$stream" = --stream ] && echo ', stream')"
  if [ "$stream" = --stream ] && [ "${POG_OBS:-1}" != 0 ]; then
    if [ "${POG_OBS_RESTART:-1}" = 0 ]; then echo "4c. OBS: no restart (POG_OBS_RESTART=0)"
    elif [ "${POG_OBS_RESTARTED:-0}" = 1 ]; then echo "4c. OBS: restarted by the caller (shift-change)"
    else echo "4c. OBS restart first: tools/obs-restart.sh (outputs off, close cleanly, start pog-obs, wait for the websocket)"; fi
    echo "    then tools/obs-steps.sh --stream: $(tools/obs-steps.sh --stream --dry-run | sed 's/^.*plan: //')"
  fi
  [ "${POG_BROKER:-0}" = 1 ] && echo "4b. RCON broker (POG_BROKER=1): sockets runs/$run/.sock/NAME.sock for $(echo $members); no key in the run"
  if [ "$has_agy" = 1 ]; then
    echo "4d. agy memory guard (an agy agent in the team): $(python3 tools/agy_memguard.py --check || true); started if not, log runs/$run/agy-memguard.log"
  fi
  echo "5. agents launch$([ "${POG_FULL_TOOLS:-0}" = 1 ] && echo ' with full tools (POG_FULL_TOOLS=1: tools/, team-tools/, gamedata/, subagents, web)'); 6. supervisors and score loop"
  rest_carry=(); [ -n "${carry_from:-}" ] && rest_carry=(--carry "$carry_from")   # (d24 batch172) the last run's rests
  { python3 tools/quota_rest.py --at-limit "runs/$run" "$team" ${rest_carry[@]+"${rest_carry[@]}"} --brief "${POG_QUOTA_BRIEF:-$qbrief}" --dry-run || true; } | sed 's/^/5a. /'
  [ -n "$resume" ] && echo "prompt adds: $(tools/launch-agent.sh --resume-sentence)"
  exit 0
fi
rundir="runs/$run"; mkdir -p "$rundir"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$rundir/start.log"; }
quota --save "$rundir/quota-brief.json" | while read -r line; do log "$line"; done
# Launch from the code the fixes are in (docs/studies/shake5.md, P1 item 7): harness and stream commits on main or a
# recent branch that this checkout lacks, and a built host older than its sources. Warnings only.
{ python3 tools/code_check.py || true; } | while read -r line; do log "$line"; done
log "full tools: $([ "${POG_FULL_TOOLS:-0}" = 1 ] && echo 'on (docs/TOOLS-NOTES.md)' || echo off)"
log "RCON broker: $([ "${POG_BROKER:-0}" = 1 ] && echo 'on (agents get no password; docs/LAUNCH-NOTES.md)' || echo 'off (agents read runs/RUN/.keys)')"
log "player votes: $([ "${POG_PLAYERS:-0}" = 1 ] && echo "on (docs/PLAYERS-NOTES.md; protected: ${POG_PLAYERS_PROTECT:-none})" || echo off)"
# The hosts' writer: POG_CASTER_MODEL on OpenRouter (Nick picked Opus 5.5 from the 2026-10-11 writer comparison,
# docs/AUDIO-NOTES.md); urgent beats stay on the fast Workers AI model. Empty, or no OpenRouter key: Workers AI.
cmodel=${POG_CASTER_MODEL-anthropic/claude-opus-5.5}
# The director's clients (tools/cams.py): POG_CAMS a count (1-3) or names; Sunday 2026-10-18 POG_CAMS=1 (cam1 alone, Nick
# plays on the box). POG_EXPECT_CAMS: how many the operator's watchdog expects in the game (switches.env below).
cams=$(python3 tools/cams.py list)
export POG_EXPECT_CAMS=$(python3 tools/cams.py count)
log "cameras: $cams ($POG_EXPECT_CAMS client$([ "$POG_EXPECT_CAMS" = 1 ] && echo ': one camera, no inset or trio' || echo s))"
# POG_CASTER_LOW_MODEL: the hosts' writer while YouTube says nobody (or one long-time viewer) is watching; empty: cmodel
clow=${POG_CASTER_LOW_MODEL-anthropic/claude-haiku-5.5}
# The switches this run starts with, for the next shift (tools/shift-change.sh starts it with the same ones).
printf '%s\n' "POG_BROKER=${POG_BROKER:-0}" "POG_FULL_TOOLS=${POG_FULL_TOOLS:-0}" "POG_SPACE_AGE=$POG_SPACE_AGE" \
  "POG_YOUTUBE=$POG_YOUTUBE" "POG_CASTER_MODEL=$cmodel" "POG_CASTER_URGENT=${POG_CASTER_URGENT:-}" "POG_CASTER_LOW_MODEL=$clow" \
  "POG_CASTER=${POG_CASTER:-1}" "POG_ANALYST=${POG_ANALYST:-1}" "POG_PLAYERS=${POG_PLAYERS:-0}" \
  "POG_VIEWER_RELAY=${POG_VIEWER_RELAY:-1}" "POG_VIEWER_ROUTE=${POG_VIEWER_ROUTE:-0}" "POG_TEAM_FILE=$team" "POG_CAMS=${POG_CAMS:-3}" \
  "POG_EXPECT_CAMS=$POG_EXPECT_CAMS" > "$rundir/switches.env"

if [ -n "$resume" ]; then
  # 1. A later shift: the same instance and save (docs/HARNESS3-NOTES.md, round 7).
  log "world $world: resuming run $resume ($prev_dir)"
  if [ -n "$stop_utc" ]; then log "world $world: the previous run's stop record: tick $stop_tick, save ${stop_save:-none} at $stop_utc"
  else log "world $world: no stop record in $stop_dir (stopped.json): resume-save takes the newest save"; fi
  check=$(tools/winps.sh tools/win/resume-save.ps1 -Name "$world" -From "$resume" ${stop_args[@]+"${stop_args[@]}"} -Check) || true
  printf '%s\n' "$check" | while read -r line; do log "  $line"; done
  refused=$(printf '%s\n' "$check" | sed -n 's/^refuse=//p')
  [ -z "$refused" ] || { log "refusing: resume-save would take no save: $refused"; exit 1; }
  save_sa=$(printf '%s\n' "$check" | sed -n 's/^space_age=\([01]\).*/\1/p')
  [ -n "$save_sa" ] || { log "resume check failed: $(printf '%s' "$check" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  if [ "$save_sa" != "$POG_SPACE_AGE" ]; then
    log "refusing: world $world's mods have space-age $([ "$save_sa" = 1 ] && echo on || echo off) but POG_SPACE_AGE=$POG_SPACE_AGE; run again with POG_SPACE_AGE=$save_sa"
    exit 1
  fi
  log "world $world: stopping old processes"
  tools/winps.sh tools/win/stop-world.ps1 -Name "$world" >/dev/null || true
  scp -q -r vendor/factorio-harness/mod/agent-harness_0.1.0 pogwin:D:/pog/mods/ 2>/dev/null
  copied=$(tools/winps.sh tools/win/resume-save.ps1 -Name "$world" -From "$resume" -To "$run" ${stop_args[@]+"${stop_args[@]}"}) || true
  printf '%s\n' "$copied" | grep -q '^copied=' || { log "resume copy failed: $(printf '%s' "$copied" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  resumed_save=$(printf '%s\n' "$copied" | sed -n 's/^save=//p')
  log "world $world: $resumed_save (written $(printf '%s\n' "$copied" | sed -n 's/^save_time=//p'); $(printf '%s\n' "$copied" | sed -n 's/^why=//p')) copied to $run.zip"
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
  tick=$(python3 tools/pog.py --world "$world" score 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["tick"])' 2>/dev/null || echo '?')
  # The tick against the previous run's last (tools/resume_guard.py): a world that went back is not played on.
  if [ "$tick" = '?' ]; then log "world $world: resumed; its tick could not be read"
  else
    guard=$(python3 tools/resume_guard.py "$stop_dir" "$tick" "${resumed_save:-}") && guard_ok=1 || guard_ok=0
    log "world $world: $guard"
    if [ "$guard_ok" = 0 ]; then
      python3 tools/pog.py --world "$world" pause >/dev/null 2>&1 || true
      log "refusing: world $world is paused on $run.zip; no agents start (check the saves, or POG_RESUME_TICK_SLACK)"
      exit 1
    fi
  fi
  # Losses in this shift start new incidents; the previous shift's stay in status alerts history.
  # The shift's number in the world, counted as the stream hosts count it (tools/shift_times.py, resumed-from chain):
  # the agents' shift block says the same number.
  shift_n=$(python3 tools/shift_times.py number "$rundir" 2>/dev/null || echo 0)
  # The last 3 shifts' team numbers (tools/progress.py, fh progress's measures; viewers Alex and Foobator): every
  # agent's shift retro carries them. One line, no quotes or brackets (progress.py strips them).
  progress=$(python3 tools/progress.py --shift-lines 2>/dev/null | tr -d '\n' || true)
  closed=$(python3 tools/pog.py --world "$world" rcon "/silent-command rcon.print(remote.call(\"agent_harness\",\"shift_start\",$shift_n,[==[$progress]==]))" 2>&1)
  log "world $world: shift_start $closed"
fi

# 2. Director clients (players 1-3, spectators once a camera is set). They keep the server from auto-pausing.
# One at a time, each in the game before the next starts (19:15: three loading at once stalled for 10 minutes and the
# stream was black); a stuck one is restarted once; then OBS's camera captures are rehooked (tools/start-cams.sh).
tools/start-cams.sh "$world" "$game" -- ${factorio[@]+"${factorio[@]}"} 2>&1 |
  while read -r line; do log "director ${line#* start-cams: }"; done ||
  log "director: a camera did not join (the shift goes on; tools/start-cams.sh $world $game starts a missing one)"

# 3. Bots, one per team member; a resumed save keeps its bots (only members it lacks are created).
python3 tools/team_bots.py "$team" "$world" | while read -r line; do log "bot $line"; done

# 4. Overlay service config, reverse tunnel for OBS, scene, recording, optional stream.
python3 - "$team" "$rundir/stream.json" "$run" "$minutes" <<'EOF'
import json, os, sys
sys.path.insert(0, "tools")
from shift_times import shift as shift_times
from cams import slots as cam_slots
team, out, run, minutes = sys.argv[1:]
# The shift's times for the site (a visitor between shifts sees when to come back): shifts run back to back, so the
# next is expected when this one ends; POG_NEXT_SHIFT sets it ("02:47", an ISO time, or "none"). tools/shift_times.py
shift = shift_times(minutes, os.environ.get("POG_NEXT_SHIFT", ""))
agents = {}
for line in open(team):
    if not line.strip() or line.startswith("#"): continue
    name, kind, route, model, effort, label, harness = line.rstrip("\n").split("\t")
    agents[name] = {"model": label, "harness": harness}
words = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten"}
json.dump({"title": f"{words.get(len(agents), len(agents))} AIs, one factory", "subtitle": ("Factorio: Space Age" if os.environ.get("POG_SPACE_AGE") == "1" else "Factorio") + " co-op · real time · no cheats",
           "space_age": os.environ.get("POG_SPACE_AGE") == "1", "shift": shift, "agents": agents,
           # the director's clients (tools/cams.py: POG_CAMS=1 is cam1 alone, Sunday 2026-10-18)
           "cameras": cam_slots()}, open(out, "w"), indent=1)
EOF
# Viewer chat: the companion site's chat always; YouTube when POG_YOUTUBE (an @handle, channel id or video id) is set.
viewers=(--viewers-site); [ -n "${POG_YOUTUBE:-}" ] && viewers+=(--viewers-youtube "$POG_YOUTUBE")
# Viewer lines that pass the filters and Clef go into the game as `viewer NAME: text` while this switch file exists:
# on unless POG_VIEWER_RELAY=0; `rm runs/RUN/viewers-relay.on` stops it mid-run, `touch` starts it (checked every 2 s).
viewers+=(--viewers-relay "$rundir/viewers-relay.on")
if [ "${POG_VIEWER_RELAY:-1}" = 1 ]; then touch "$rundir/viewers-relay.on"; else rm -f "$rundir/viewers-relay.on"; fi
# Routing by content (router.py) while runs/RUN/viewers-route.on exists: off unless POG_VIEWER_ROUTE=1; touch/rm mid-run.
if [ "${POG_VIEWER_ROUTE:-0}" = 1 ]; then touch "$rundir/viewers-route.on"; else rm -f "$rundir/viewers-route.on"; fi
nohup python3 tools/stream/serve.py --world "$world" --run "$rundir/stream.json" --port 8788 "${viewers[@]}" \
  >"$rundir/stream-service.log" 2>&1 &
echo $! > "$rundir/stream-service.pid"
helpers=("stream-service:$!:$rundir/stream-service.log")
# POG_OBS=0: no overlay tunnel, scene, recording or stream (test shifts). OBS control needs the obsws venv; a worktree
# without one uses the main checkout's.
if [ "${POG_OBS:-1}" != 0 ]; then
  py=tools/.venv/bin/python; [ -x "$py" ] || py=$HOME/code/player-of-games/tools/.venv/bin/python
  # In a loop: a box reboot or a dropped link ended the one ssh and the overlay vanished from the stream (2026-10-14).
  nohup bash -c 'while true; do ssh -N -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -R 8787:127.0.0.1:8788 pogwin; sleep 5; done' >/dev/null 2>&1 &
  echo $! > "$rundir/overlay-tunnel.pid"
  # A new OBS process for each streamed shift (2026-10-13 08:29: after 24.5 h in one process Quick Sync failed with
  # MFX_ERR_MEMORY_ALLOC and the stream stopped). tools/shift-change.sh restarts it between stop-team and this
  # (POG_OBS_RESTARTED=1); POG_OBS_RESTART=0 skips it. A failed restart goes on with the running OBS.
  if [ "$stream" = --stream ] && [ "${POG_OBS_RESTART:-1}" != 0 ] && [ "${POG_OBS_RESTARTED:-0}" != 1 ]; then
    if tools/obs-restart.sh 2>&1 | tee -a "$rundir/start.log" | tail -1 > "$rundir/obs-restart.txt"; then :; fi
    grep -q "OBS answers" "$rundir/obs-restart.txt" || log "OBS restart FAILED: going on with the running OBS"
  fi
  sleep 3
  tools/obs-steps.sh $stream 2>&1 | tee -a "$rundir/start.log" || log "OBS steps: a step failed (above); the run goes on"
else
  log "POG_OBS=0: no overlay tunnel, recording or stream"
fi

first_bot=$(awk -F'\t' '!/^#/ && NF {print $1; exit}' "$team")
nohup python3 tools/chat-log.py --world "$world" --bot "$first_bot" "$rundir/chat.jsonl" >"$rundir/chat-log.err" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
helpers+=("chat-log:$!:$rundir/chat-log.err")
# ./shot: bots have no client, so a director renders each screenshot; this copies them into the workspaces.
shot_dirs=(); for c in $cams; do shot_dirs+=("$world-client-$c"); done
nohup tools/shot-sync.sh "$rundir" "${shot_dirs[@]}" \
  >"$rundir/shot-sync.log" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
helpers+=("shot-sync:$!:$rundir/shot-sync.log")
# Shoutcasters and voiced agent lines (docs/AUDIO-NOTES.md); POG_CASTER=0 turns them off.
if [ "${POG_CASTER:-1}" != 0 ]; then
  # --deadline: the agents' deadline.txt files (written as they launch, after this) give the hosts the time left;
  # --run-dir: its resumed-from (POG_RESUME) tells the hosts this is a later shift of a saved world
  # The hosts' writer: cmodel above.
  writer=()
  orkey=${OPENROUTER_API_KEY:-$(security find-generic-password -s openrouter -w 2>/dev/null || true)}
  [ -n "$cmodel" ] && [ -n "$orkey" ] && writer=(--writer or --model "$cmodel" --low-model "$clow")
  # POG_CASTER_URGENT: the urgent beats' writer (default Kimi on Workers AI); e.g. or:anthropic/claude-haiku-5.5
  [ -n "${POG_CASTER_URGENT:-}" ] && writer+=(--urgent-model "$POG_CASTER_URGENT")
  OPENROUTER_API_KEY=$orkey nohup python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --tts auto --tts-fallback aura1 \
    --deadline "$rundir/*/deadline.txt" --run-dir "$rundir" ${writer[@]+"${writer[@]}"} >"$rundir/caster.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("caster:$!:$rundir/caster.log")
fi
# The companion site's live page (site/push_live.py; token in site/worker/.secrets.json, gitignored).
# POG_PUSH_LIVE=0: not pushed (test runs, which must not show on the public site).
# (d22 batch89 AY2) one pusher at a time: one already running (a shift not stopped, or one started by hand) is left
# alone and named; push_live.py's own lock refuses a second copy too.
if [ "${POG_PUSH_LIVE:-1}" != 0 ] && { [ -f site/worker/.secrets.json ] || [ -n "${POG_LIVE_TOKEN:-}" ]; }; then
  # (d24 batch186) only a pusher run from this checkout counts: a test's stand-in in a temp folder (test_shift_recovery's
  # other checkout, 18:03) made a live start skip its pusher
  running=""
  for pid in $(pgrep -f "site/push_live.py --source" || true); do
    c=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    [ "$c" = "$(pwd -P)" ] || [ "$c" = "$PWD" ] && running="$running$pid "
  done
  if [ -n "$running" ]; then
    log "push_live already runs (pid $running): not started again; tools/stop-team.sh stops it with its run"
  else
    nohup python3 site/push_live.py --source http://127.0.0.1:8788/state.json >"$rundir/push-live.log" 2>&1 &
    echo $! >> "$rundir/stream-service.pid"
    helpers+=("push-live:$!:$rundir/push-live.log")
  fi
fi
# (d22 batch97 BG3) the site rebuilt and deployed every hour (tools/site-refresh.sh), so the chart's cells the stream
# service draws (runs/RUN/chart/out/, published under /live/chart/) are at most about an hour old. POG_SITE_HOURLY=0
# turns it off; off with POG_PUSH_LIVE=0 (test runs must not deploy the public site).
if [ "${POG_PUSH_LIVE:-1}" != 0 ] && [ "${POG_SITE_HOURLY:-1}" != 0 ]; then
  nohup bash -c 'while sleep 3600; do tools/site-refresh.sh; done' >"$rundir/site-hourly.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("site-hourly:$!:$rundir/site-hourly.log")
fi
# The site's polls (site/polls_relay.py): RUN/polls.json for ./fh poll, the agents' team-block line, the stream's poll
# strip and the hosts; agents' votes (./fh poll vote) posted with the token; agents' and viewers' poll ideas into the
# operator inbox. POG_POLLS=0 turns it off; off with POG_PUSH_LIVE=0 (test runs must not vote in the public polls).
if [ "${POG_PUSH_LIVE:-1}" != 0 ] && [ "${POG_POLLS:-1}" != 0 ] && \
   { [ -f site/worker/.secrets.json ] || [ -n "${POG_LIVE_TOKEN:-}" ]; }; then
  nohup python3 -u site/polls_relay.py "$rundir" >"$rundir/polls-relay.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("polls-relay:$!:$rundir/polls-relay.log")
fi
# Viewers' blueprints shared on the site (site/viewer_blueprints.py): pulled into team-tools/viewer-blueprints/, one
# fact line each in game chat while the viewer relay is on. Off unless POG_VIEWER_BLUEPRINTS=1: Nick d17 08:30, after
# poll #1 (viewers: ideas in words, not blueprint strings): designs come from the team.
if [ "${POG_PUSH_LIVE:-1}" != 0 ] && [ "${POG_VIEWER_BLUEPRINTS:-0}" = 1 ] && \
   { [ -f site/worker/.secrets.json ] || [ -n "${POG_LIVE_TOKEN:-}" ]; }; then
  nohup python3 -u site/viewer_blueprints.py "$rundir" --world "$world" >"$rundir/viewer-blueprints.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("viewer-blueprints:$!:$rundir/viewer-blueprints.log")
fi
# Terrain for the site's maps (tools/stream/mapframes.py): a georeferenced frame of each base-map shot, from its OBS
# source, kept per area in runs/RUN/mapframes/ (site/terrain.py publishes them). Needs OBS and system python3's numpy
# and Pillow; POG_MAPFRAMES=0 turns it off. (Shift07 had none: it was never started.)
if [ "${POG_OBS:-1}" != 0 ] && [ "${POG_MAPFRAMES:-1}" != 0 ]; then
  nohup python3 -u tools/stream/mapframes.py "$rundir" --url http://127.0.0.1:8788/state.json >"$rundir/mapframes.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("mapframes:$!:$rundir/mapframes.log")
fi
# Human players' votes (docs/PLAYERS-NOTES.md): the operator tally runs a carried kick, ban or trust; names in
# POG_PLAYERS_PROTECT (comma-separated) are never kicked or banned.
if [ "${POG_PLAYERS:-0}" = 1 ]; then
  nohup python3 tools/players.py --world "$world" watch --log "$rundir/votes.jsonl" >"$rundir/players.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
  helpers+=("players:$!:$rundir/players.log")
fi
# The team blueprint library (blueprint_save; it lives in the save and goes on with the world): a copy of each entry in
# runs/RUN/blueprints/ (NAME.txt, index.json), one storage-only operator read a minute (tools/bplibrary.py).
nohup python3 tools/bplibrary.py --world "$world" --run-dir "$rundir" watch --interval 60 >"$rundir/bplibrary.log" 2>&1 &
echo $! >> "$rundir/stream-service.pid"
helpers+=("bplibrary:$!:$rundir/bplibrary.log")
# Analyst: talking points for the casters every 90 s, read-only (docs/ANALYST-NOTES.md); POG_ANALYST=0 turns it off.
if [ "${POG_ANALYST:-1}" != 0 ]; then
  # Its own Claude route, like the agents' (tools/launch-agent.sh), not whatever session started the run.
  aroute=${POG_ANALYST_ROUTE:-claude-c}
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

# A later shift: each agent's tools/ and the shared team-tools/ as the previous shift left them (up its resumed-from
# chain to the newest run that has them; files over 5 MB, caches, dotfiles and symlinks stay behind). The file list is
# in carried-tools.txt. Opus, 2026-10-13: they were copied by hand every shift.
if [ -n "$resume" ]; then
  python3 tools/full_tools.py carry "$rundir" "$carry_from" $members 2>&1 | while read -r line; do log "$line"; done || true
  [ -f "$rundir/carried-tools.txt" ] && log "carry: file list in $rundir/carried-tools.txt"
fi

# POG_FULL_TOOLS=1: Muse's team-tools is a folder of its own, mirrored with the shared one (tools/full_tools.py).
if [ "${POG_FULL_TOOLS:-0}" = 1 ]; then
  nohup python3 tools/full_tools.py sync "$rundir" 5 >"$rundir/team-tools-sync.log" 2>&1 &
  echo $! >> "$rundir/stream-service.pid"
fi

# The agy memory guard (tools/agy_memguard.py; d22 09:27: one agy turn of Gemini's grew to 21 GiB and filled the
# Mac's swap): kills a process under a run's .agy-loop.sh past 4 GiB. One per Mac (its lock), started here when the
# team has an agy agent, before the agents; not a supervisor: stop-team leaves it running for the next shift.
if [ "$has_agy" = 1 ]; then
  if guard=$(python3 tools/agy_memguard.py --check); then
    log "$guard"
  else
    nohup python3 tools/agy_memguard.py --log "$rundir/agy-memguard.log" >/dev/null 2>&1 &
    log "agy memory guard started: pid $!, cap 4 GiB, log $rundir/agy-memguard.log (it runs across shifts)"
  fi
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
# (d22 batch108 BR1, Grok's weekly limit at 20:04, reset Sat 15:59) A new run has no resting.json of the last one: an
# agent whose account the quota check above read at its limit (a window at 99% or more, its reset ahead) gets a quota
# rest until that reset (resting.json and the runtime push; the runtime is deployed and the workspaces exist now), so
# the card, the supervisor and the idle nudger see it from the first poll. The agent is launched anyway: at its limit
# it makes no request, and one that can play after all ends the rest with its first status. Not at its limit: nothing.
# (d24 batch172, viewer Aurora 16:05: Muse's hand-marked rest until Sun 17:00 was gone in shift70, its ai-usage data
# stale) A resumed run also starts with every rest of the previous one that has not ended, whatever ai-usage says,
# unless a fresh reading gives the account room (the start log says so).
rest_carry=(); [ -n "${carry_from:-}" ] && rest_carry=(--carry "$carry_from")
{ python3 tools/quota_rest.py --at-limit "$rundir" "$team" ${rest_carry[@]+"${rest_carry[@]}"} --brief "${POG_QUOTA_BRIEF:-$rundir/quota-brief.json}" 2>&1 || true; } \
  | while read -r line; do log "$line"; done
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
# A fact-only operator tell to an agent whose character has stood 10 minutes (tools/idle_nudge.py; at most every 20
# minutes per agent, not in the first 5): runs/RUN/nudges.jsonl. Also sends the halfway cached factory digest.
# POG_IDLE_NUDGE=0 turns off this supervisor, including the digest.
if [ "${POG_IDLE_NUDGE:-1}" = 1 ]; then
  nohup python3 tools/idle_nudge.py --run "$rundir" --world "$world" --port "$rcon" >"$rundir/idle-nudge.log" 2>&1 &
  echo $! >> "$rundir/supervisors.pid"
  log "idle nudges running (pid $!)"
fi
nohup tools/score-loop.sh "$rundir" 120 "$world" >/dev/null 2>&1 &
echo $! > "$rundir/score-loop.pid"
