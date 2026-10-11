#!/usr/bin/env bash
# Clean-profile probe, run through tools/context-probe.sh --profile (outside the sandbox):
#   tools/context-probe.sh [-C CHECKOUT] --profile KIND MODEL [ROUTE] [EXTRA CLI ARGS...]
# Prepares CHECKOUT/runs/ctxtest/profile-KIND as tools/launch-agent.sh does, runs one short headless turn with the
# same env and flags (tools/profile-flags.sh), and prints what reached the model, also saved to DIR/profile.txt:
#   claude: the model's own report on git status, email and the silent-turn reminder (forced on after 1 s and 1 turn),
#           once clean and once as a control with the reminder and git status switched back on
#   codex:  the developer-message blocks in the session rollout (<skills_instructions>, <multi_agent_role>, ...)
#   grok:   `grok inspect` (rules, skills, MCP servers, hooks) and the model's list of rules and MCP servers
#   muse:   which hooks ran (hook_run_started by source file) in the session record
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tools/profile-flags.sh"
base=$1 kind=$2 model=$3 route=${4:-}
shift 3; [ $# -gt 0 ] && shift
ws=profile-$kind
rm -rf "$base/runs/ctxtest/$ws"
dir=$(POG_WS=$ws "$base/tools/new-run.sh" ctxtest n "$ws" 30)   # world n is only named in the unused ./fh wrapper
cd "$dir"
route_root() { /Users/owner/.local/bin/ai-session routes | awk -v r="$1" -v h="$2" '$1 == r && $2 == h {print $NF}'; }
out=profile.txt
: > $out
say() { echo "$*" | tee -a $out; }
say "profile probe: $kind $model route=${route:--} dir=$dir $(date '+%H:%M:%S')"

case $kind in
  claude)
    route=${route:-claude}
    mkdir -p .claude
    printf '{"permissions": {"defaultMode": "dontAsk", "allow": ["Read", "Bash(sleep:*)"]}}\n' > .claude/settings.json
    python3 "$root/tools/context.py" setup claude "$model" "$dir" >/dev/null
    python3 "$root/tools/clean-profile.py" claude "$dir"
    croot=$(route_root "$route" claude)
    cenv="-u CLAUDE_CONFIG_DIR"; [ "$route" = claude ] || cenv="CLAUDE_CONFIG_DIR='$croot'"
    task="Run the shell command sleep 2 three times, each as its own Bash call (do not combine them). After the third, reply with exactly three lines: 'git: ' followed by the current git branch and the latest commit message if your context gives them, else 'git: none'; 'email: ' followed by the user's email address if your context gives one, else 'email: none'; 'reminder: ' followed by the text of any system reminder about the user not having heard from you, else 'reminder: none'."
    for variant in clean control; do
      extra="CLAUDE_CODE_SILENT_TURN_REMINDER_SECONDS=1 CLAUDE_CODE_SILENT_TURN_REMINDER_TURNS=1"
      [ $variant = control ] && extra="$extra CLAUDE_CODE_SILENT_TURN_REMINDER=1 CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=0"
      eval "env $claude_unset $cenv $claude_vars $extra /Users/owner/.local/bin/claude -p \"\$task\" --model $model $claude_flags --output-format stream-json --verbose $*" \
        > probe-$variant.jsonl 2> probe-$variant.err || true
      say "--- $variant"
      python3 - probe-$variant.jsonl "${croot:-$HOME/.claude}" "$dir" <<'EOF' | tee -a profile.txt
import glob, json, os, re, sys
path, croot, d = sys.argv[1:]
sid, result = None, ""
for line in open(path):
    try:
        row = json.loads(line)
    except ValueError:
        continue
    sid = sid or row.get("session_id")
    if row.get("type") == "result":
        result = row.get("result") or ""
print("model says:", " | ".join(l.strip() for l in result.splitlines() if l.strip()) or "(no result)")
esc = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(d))
for t in glob.glob(os.path.join(croot, "projects", esc, f"{sid}.jsonl")):
    text = open(t).read()
    print(f"transcript: silent-turn reminders={text.count(chr(39).join(['hasn', 't heard from you']))}")
EOF
    done
    ;;
  codex)
    route=${route:-codex-b}
    python3 "$root/tools/context.py" setup codex "$model" "$dir" >/dev/null
    python3 "$root/tools/clean-profile.py" codex "$dir"
    croot=$(route_root "$route" codex)
    CODEX_HOME=$croot /opt/homebrew/bin/codex exec --json --skip-git-repo-check -C "$dir" -m "$model" \
      -c 'model_reasoning_effort="low"' --sandbox read-only "$@" "Reply with the word ready." > probe.jsonl 2> probe.err || true
    python3 - probe.jsonl "$croot" <<'EOF' | tee -a profile.txt
import glob, json, os, re, sys
path, croot = sys.argv[1:]
tid = None
for line in open(path):
    try:
        row = json.loads(line)
    except ValueError:
        continue
    tid = tid or row.get("thread_id")
files = [f for f in glob.glob(os.path.join(croot, "sessions", "*", "*", "*", "*.jsonl")) if tid and tid in f]
if not files:
    print("no rollout found; probe.err:", open(path.replace(".jsonl", ".err")).read()[-800:])
for f in files:
    print("rollout:", f)
    for line in open(f):
        row = json.loads(line)
        p = row.get("payload") or {}
        if p.get("type") == "message" and p.get("role") == "developer":
            for c in p.get("content") or []:
                text = c.get("text") or ""
                tag = re.match(r"\s*<([a-z_ ]+)>", text)
                print(f"  developer block: {tag.group(1) if tag else text[:60]!r} ({len(text)} chars)")
EOF
    ;;
  grok)
    ctx_env=$(python3 "$root/tools/context.py" setup grok "$model" "$dir")
    eval "env $grok_env $ctx_env grok inspect" > inspect.txt 2>&1 || true
    say "--- grok inspect (bundled skills omitted)"
    grep -v " bundled" inspect.txt | grep -vE "^\s*$" | tee -a $out
    eval "env $grok_env $ctx_env GROK_LOG_FILE='$dir/grok.log' grok -p \"\$(printf '%s' 'List, one per line, every instruction file or rules text you were given besides AGENTS.md and CLAUDE.md (its name or first heading), or write rules: none; then one line naming the MCP servers you can use, or mcp: none; then one line naming the skills you can use, or skills: none.')\" -m $model $grok_allow --output-format plain $*" \
      > probe.out 2> probe.err || true
    say "--- model says"; tee -a $out < probe.out
    say "mcp errors in grok.log: $(grep -ciE 'mcp.*(error|fail)' grok.log 2>/dev/null || true)"
    ;;
  muse)
    ctx_args=$(python3 "$root/tools/context.py" setup muse "$model" "$dir")
    clean_args=$(python3 "$root/tools/clean-profile.py" muse "$dir")
    # One tool call, so the workspace's PostToolUse hook (.muse/hooks.json, tools/context.py) shows it still loads.
    eval "env $muse_env muse exec $ctx_args $clean_args --model $model --effort low --workspace '$dir' --trust-workspace --approval-mode never --json $* 'Run the shell command ls once, then reply with the word ready.'" \
      > probe.jsonl 2> probe.err || true
    python3 - "$dir" <<'EOF' | tee -a profile.txt
import collections, glob, json, os, re, sys
d = sys.argv[1]
files = sorted(glob.glob(os.path.expanduser("~/.local/share/muse/sessions/*/*/*/*/session.jsonl")), key=os.path.getmtime)
for f in reversed(files[-20:]):
    text = open(f, errors="replace").read()
    if d not in text:
        continue
    print("session:", f)
    keys = collections.Counter(m.split(":")[0] for m in re.findall(r'"kind":"hook_run_started","run_id":"([^"]+)"', text))
    print("hooks run by source:", dict(keys) or "none")
    print("tooling text:", text.count("shared agent tooling"), "skill reminder decisions:", text.count("skill_reminder_decision"))
    tools = re.search(r'"active_tools":\[([^\]]*)\]', text)
    print("active tools:", tools.group(1).replace('"', "") if tools else "?")
    roster = re.search(r'"reminder_roster":\{.*?"agents":\[(.*?)\]\}', text)
    print("reminder agents:", re.findall(r'\{"id":"([a-z-]+)"', roster.group(1)) if roster else "?")
    try:
        print("workspace hooks seen:", json.load(open(os.path.join(d, ".context-state.json"))).get("hooks_seen", "no"))
    except (OSError, ValueError):
        print("workspace hooks seen: no")
    break
else:
    print("no session found; probe.err:", open(os.path.join(d, "probe.err")).read()[-800:])
EOF
    ;;
  *) echo "unknown kind $kind" >&2; exit 1 ;;
esac
