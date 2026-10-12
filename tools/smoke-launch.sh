#!/usr/bin/env bash
# Smoke-test the launcher: one agent per harness on world live for a few minutes, read and chat only, then close.
#   tools/smoke-launch.sh [RUN_ID] [MINUTES] [KINDS]  (run inside Herdr; default run smoke-HHMM, 3 minutes)
# KINDS or env POG_SMOKE_KINDS (default "codex claude grok agy muse") tests a subset, e.g. "claude muse".
# Codex launches through ai-session, which writes ~/.cache: run the script outside a sandbox that blocks that.
# World live is shared with harness engineers: the agents only read and chat; the script adds smoke-* bots.
# Prints one line per agent: journal requests, say calls, failed requests, describe.json lines, and its notes line
# about the tools it saw (a clean profile reports only shell and file tools).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
run=${1:-smoke-$(date +%H%M)} minutes=${2:-3} world=live
kinds=${3:-${POG_SMOKE_KINDS:-codex claude grok agy muse}}
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
EOP
# POG_FULL_TOOLS=1: also exercise the full engineer tools (tools/full_tools.py), still without acting in the game.
if [ "${POG_FULL_TOOLS:-}" = 1 ]; then cat >> "$rundir/prompt.md" <<'EOP'
6. Write `tools/circuit.py`, a Python script that reads `gamedata/recipes.json` and prints the ingredients of
   `electronic-circuit`; run it, then copy it into `team-tools/` under your name (for example `team-tools/NAME-circuit.py`).
7. Look up the Factorio wiki page for the electronic circuit on the web, if you have a web tool.
8. Start one subagent, if you can, that counts the lines of `describe.json` and reports the number back to you.
9. Try to read the first line of another smoke agent's `journal.jsonl` and of its `notes.md` (the folders beside yours).
10. In notes.md under `## Log`, write one line starting `full:` with `script=` (the ingredients or the error),
   `shared=` (ok or the error), `web=` (the URL you read, or why not), `subagent=` (the number, or why not),
   `teammate_journal=` (read or denied) and `teammate_notes=` (read or denied).
EOP
fi
echo "Then end your turn." >> "$rundir/prompt.md"
# Supervisors with a harmless nudge: shows whether a nudge reaches each harness (Muse's never did in shake2).
nudge_text='Supervisor delivery test: add one line starting nudge: under ## Log in notes.md, then end your turn. Do nothing else.'

# Bots for the smoke agents (bot_create refuses a name that exists, so a rerun reuses the earlier bot).
for k in $kinds; do read -r name _ <<<"$(row "$k")"
  python3 tools/pog.py --world $world rcon "/silent-command rcon.print(remote.call(\"agent_harness\",\"bot_create\",\"$name\"))" >/dev/null || true
done

# POG_BROKER=1: the RCON broker serves the smoke bots (tools/fh_broker.py); the run has no key. The report below adds
# its counts, and a probe from this script checks that a teammate's bot and a console command are refused.
broker_pid=""
if [ "${POG_BROKER:-0}" = 1 ]; then
  names=$(for k in $kinds; do row "$k" | awk '{print $1}'; done)
  nohup python3 tools/fh_broker.py --world $world --dir "$rundir/.sock" --log "$rundir/broker.log" $names >"$rundir/broker.err" 2>&1 &
  broker_pid=$!
  first=$(echo $names | awk '{print $1}') second=$(echo $names | awk '{print $NF}')
  for i in $(seq 1 20); do [ -S "$rundir/.sock/$second.sock" ] && break; sleep 0.5; done
  echo "broker: pid $broker_pid, $(ls "$rundir/.sock" | tr '\n' ' ')"
  tools/broker-probe.sh "$rundir/.sock" "$first" "$second" || true
fi

sync_pid=""
if [ "${POG_FULL_TOOLS:-}" = 1 ]; then   # Muse's own team-tools folder, mirrored with the shared one
  nohup python3 tools/full_tools.py sync "$rundir" 5 >"$rundir/team-tools-sync.log" 2>&1 &
  sync_pid=$!
fi

: > "$rundir/panes.txt"
t0=$(date +%s)
for k in $kinds; do read -r name route model effort label harness <<<"$(row "$k")"
  # All panes first, then one pass for trust prompts, as tools/start-team.sh does.
  out=$(POG_NO_WAIT=1 POG_WS="$name" POG_BOT="$name" POG_TEAM="$rundir/team.txt" POG_MODEL="${label//_/ } (${harness//_/ })" \
        POG_ROUTE="$route" POG_TIME_MODE=realtime POG_ONE_TURN=1 tools/launch-agent.sh "$run" "$world" "$name" "$minutes" "$k" "$model" "$effort")
  pane=$(echo "$out" | awk '{print $1}')
  echo "$name $pane $k" >> "$rundir/panes.txt"
  echo "launched $name ($k) after $(( $(date +%s) - t0 )) s: $out"
done
prompt_args=()
while read -r name pane kind; do prompt_args+=("$pane" "$rundir/$name"); done < "$rundir/panes.txt"
tools/clear-prompts.sh 90 "${prompt_args[@]}" | sed 's/^/prompts: /'
echo "launch: $(wc -l < "$rundir/panes.txt" | tr -d ' ') agents ready or timed out after $(( $(date +%s) - t0 )) s"
while read -r name pane k; do
  # agy runs one turn (POG_ONE_TURN) and has no supervisor in team runs either.
  [ "$k" = agy ] || POG_NUDGE_TEXT="$nudge_text" nohup tools/supervise.sh "$pane" "$rundir/$name" >/dev/null 2>&1 &
done < "$rundir/panes.txt"

sleep $((minutes * 60 + 30))

while read -r name pane kind; do herdr pane close "$pane" >/dev/null 2>&1 || true; done < "$rundir/panes.txt"
if [ -n "$sync_pid" ]; then
  kill "$sync_pid" 2>/dev/null || true
  python3 tools/full_tools.py sync "$rundir" >> "$rundir/team-tools-sync.log"
  echo "team-tools sync: $(wc -l < "$rundir/team-tools-sync.log" | tr -d ' ') copies"
fi
if [ -n "$broker_pid" ]; then
  kill "$broker_pid" 2>/dev/null || true; sleep 1
  python3 tools/fh_broker.py summary "$rundir/broker.log"
  echo "keys in the run: $([ -d "$rundir/.keys" ] && ls "$rundir/.keys" | tr '\n' ' ' || echo none)"
fi
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
             if l.lstrip("- ").startswith(("tools:", "rules:", "blocked:", "nudge:", "full:"))]
    sup = [l.strip() for l in open(os.path.join(d, "supervisor.log"))] if os.path.exists(os.path.join(d, "supervisor.log")) else []
    try:
        hooks = json.load(open(os.path.join(d, ".context-state.json"))).get("hooks_seen", "no")
    except (OSError, ValueError):
        hooks = "no"
    start = ""
    if kind == "claude":   # context at the first model call (Haiku's post-compaction floor follows from it)
        import glob, re
        esc = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(d))
        for t in sorted(glob.glob(os.path.expanduser(f"~/.claude/projects/{esc}/*.jsonl")), key=os.path.getmtime)[-1:]:
            for l in open(t):
                u = (json.loads(l).get("message") or {}).get("usage") if '"usage"' in l else None
                if u:
                    start = f" start_context={sum(int(u.get(k) or 0) for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'))}"
                    break
            # Clean profile, round 4: no git status in the session context, no silent-turn reminder.
            text = open(t).read()
            start += f" gitStatus={text.count(chr(34) + 'gitStatus' + chr(34))} silent_reminders={text.count('t heard from you')}"
    if kind == "codex":    # clean profile, round 4: no skills list or multi-agent role in the TUI session either
        import glob
        for f in sorted(glob.glob(os.path.expanduser("~/.codex-account-b/sessions/*/*/*/*.jsonl")), key=os.path.getmtime)[-30:]:
            text = open(f, errors="replace").read()
            if os.path.realpath(d) in text[:20000]:
                start = (f" skills_instructions={text.count('<skills_instructions>')}"
                         f" multi_agent_role={text.count('<multi_agent_role>')}")
    if kind == "grok":     # run-local GROK_HOME: did .grok-run.sh start, and did the TUI log (smoke-l4g: it never did)
        started = open(os.path.join(d, "grok-start.log")).read().split()[:1] if os.path.exists(os.path.join(d, "grok-start.log")) else []
        pids = set()
        log = os.path.join(d, ".grok-home", "logs", "unified.jsonl")
        if os.path.exists(log):
            for l in open(log, errors="replace"):
                try:
                    pids.add(json.loads(l).get("pid"))
                except ValueError:
                    pass
        start = f" grok_started={started[0] if started else 'no'} grok_processes_logged={len(pids)}"
    if kind == "muse":     # no owner hooks, no skill-reminder decisions
        import glob, re
        for f in sorted(glob.glob(os.path.expanduser("~/.local/share/muse/sessions/*/*/*/*/session.jsonl")), key=os.path.getmtime)[-20:]:
            text = open(f, errors="replace").read()
            if os.path.realpath(d) in text:
                owner = sum(1 for k in re.findall(r'"kind":"hook_run_started","run_id":"([^"]+)"', text) if ".config/muse" in k)
                start = f" owner_hooks={owner} skill_reminders={text.count('skill_reminder_decision')}"
    print(f"{name:13} {kind:6} requests={reqs} say={says} failed={fails} describe_lines={desc} hooks_seen={hooks}{start}")
    print("    notes: " + (" | ".join(notes) or "no tools/rules/blocked/nudge lines"))
    print("    supervisor: " + (" | ".join(sup) or "none"))
shared = os.path.join(rundir, "team-tools")
if os.path.isdir(shared):   # POG_FULL_TOOLS=1: what the agents put in the shared folder
    print("team-tools: " + (" ".join(sorted(os.listdir(shared))) or "empty"))
PY
