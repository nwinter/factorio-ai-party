#!/usr/bin/env bash
# Smoke-test the launcher: one agent per harness on world live for a few minutes, read and chat only, then close.
#   tools/smoke-launch.sh [RUN_ID] [MINUTES]      (run inside Herdr; default run smoke-HHMM, 3 minutes)
# Env: POG_SMOKE_KINDS (default "codex claude grok agy muse") to test a subset.
# World live is shared with harness engineers: the agents only read and chat; the script adds smoke-* bots.
# Prints one line per agent: journal requests, say calls, failed requests, describe.json lines, and its notes line
# about the tools it saw (a clean profile reports only shell and file tools).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
run=${1:-smoke-$(date +%H%M)} minutes=${2:-3} world=live
kinds=${POG_SMOKE_KINDS:-codex claude grok agy muse}
rundir="runs/$run"; mkdir -p "$rundir"

# kind -> name, route, model, effort, label (the cheapest model per harness)
row() {
  case $1 in
    codex)  echo "smoke-luna codex-b gpt-6-luna low GPT-6_Luna Codex" ;;
    claude) echo "smoke-haiku claude haiku low Claude_Haiku_5.5 Claude_Code" ;;
    grok)   echo "smoke-grok - grok-4.7 low Grok_4.7 Grok_Build" ;;
    agy)    echo "smoke-gemini - gemini-3.8-flash-high - Gemini_3.8_Flash Antigravity" ;;
    muse)   echo "smoke-muse - muse-spark-1.3 low Muse_Spark_1.3 Muse_Code" ;;
  esac
}

: > "$rundir/team.txt"
for k in $kinds; do read -r name _ _ _ label harness <<<"$(row "$k")"
  echo "$name|${label//_/ } (${harness//_/ })" >> "$rundir/team.txt"; done

cat > "$rundir/prompt.md" <<'EOP'
Read AGENTS.md in this directory: it has your instructions, interface and rules. This session is a short launch smoke
test on a shared world, so do not move, mine, build, craft, take or give items, or post to the board. Only read and chat:
1. `grep '"say"' describe.json`
2. `./fh call status`, `./fh call chat` and `./fh board`
3. Run these two commands exactly as written (they only read): `for a in status board; do ./fh call $a > /dev/null && echo "$a ok"; done`
   and `python3 -c 'print("python ok")'`.
4. Say one short line in chat: your name, that this is a launch smoke test, and one thing you noticed in status.
5. In notes.md under `## Log`, write one line starting `tools:` that lists every tool, skill, plugin and MCP server
   available to you besides running shell commands and reading or editing files (write `tools: none` if there are
   none), one line starting `rules:` naming any instructions you were given besides AGENTS.md and this prompt (or
   `rules: none`), and one line starting `blocked:` that lists any command that was denied or failed to run (or
   `blocked: none`).
Then end your turn.
EOP
# Supervisors with a harmless nudge: shows whether a nudge reaches each harness (Muse's never did in shake2).
nudge_text='Supervisor delivery test: add one line starting nudge: under ## Log in notes.md, then end your turn. Do nothing else.'

# Bots for the smoke agents (bot_create refuses a name that exists, so a rerun reuses the earlier bot).
for k in $kinds; do read -r name _ <<<"$(row "$k")"
  python3 tools/pog.py --world $world rcon "/silent-command rcon.print(remote.call(\"agent_harness\",\"bot_create\",\"$name\"))" >/dev/null || true
done

: > "$rundir/panes.txt"
for k in $kinds; do read -r name route model effort label harness <<<"$(row "$k")"
  out=$(POG_WS="$name" POG_BOT="$name" POG_TEAM="$rundir/team.txt" POG_MODEL="${label//_/ } (${harness//_/ })" \
        POG_ROUTE="$route" POG_TIME_MODE=realtime POG_ONE_TURN=1 tools/launch-agent.sh "$run" "$world" "$name" "$minutes" "$k" "$model" "$effort")
  pane=$(echo "$out" | awk '{print $1}')
  echo "$name $pane $k" >> "$rundir/panes.txt"
  echo "launched $name ($k): $out"
  # agy runs one turn (POG_ONE_TURN) and has no supervisor in team runs either.
  [ "$k" = agy ] || POG_NUDGE_TEXT="$nudge_text" nohup tools/supervise.sh "$pane" "$rundir/$name" >/dev/null 2>&1 &
done

sleep $((minutes * 60 + 30))

while read -r name pane kind; do herdr pane close "$pane" >/dev/null 2>&1 || true; done < "$rundir/panes.txt"
python3 - "$rundir" <<'PY'
import json, os, sys
rundir = sys.argv[1]
for line in open(os.path.join(rundir, "panes.txt")):
    name, pane, kind = line.split()
    d = os.path.join(rundir, name)
    reqs = says = fails = 0
    try:
        for l in open(os.path.join(d, "journal.jsonl")):
            e = json.loads(l)
            if e.get("event") == "request":
                reqs += 1
                says += (e.get("request") or {}).get("action") == "say"
            elif e.get("event") == "response" and (e.get("response") or {}).get("ok") is False:
                fails += 1
    except OSError:
        pass
    desc = sum(1 for _ in open(os.path.join(d, "describe.json"))) if os.path.exists(os.path.join(d, "describe.json")) else 0
    notes = [l.strip() for l in open(os.path.join(d, "notes.md"))
             if l.lstrip("- ").startswith(("tools:", "rules:", "blocked:", "nudge:"))]
    sup = [l.strip() for l in open(os.path.join(d, "supervisor.log"))] if os.path.exists(os.path.join(d, "supervisor.log")) else []
    try:
        hooks = json.load(open(os.path.join(d, ".context-state.json"))).get("hooks_seen", "no")
    except (OSError, ValueError):
        hooks = "no"
    print(f"{name:13} {kind:6} requests={reqs} say={says} failed={fails} describe_lines={desc} hooks_seen={hooks}")
    print("    notes: " + (" | ".join(notes) or "no tools/rules/blocked/nudge lines"))
    print("    supervisor: " + (" | ".join(sup) or "none"))
PY
