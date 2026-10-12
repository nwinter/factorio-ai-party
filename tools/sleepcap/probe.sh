#!/usr/bin/env bash
# Live check of the wait cap in one harness, outside the engineer sandbox (one short headless turn; quota):
#   tools/sleepcap/probe.sh KIND MODEL [ROUTE]      KIND: claude | codex | grok | muse | agy
# Prepares runs/ctxtest/sleepcap-KIND as tools/launch-agent.sh does (the wait cap included), with the cap at 3 s
# instead of 60, and asks the agent to run one shell command: which sleep it finds, a shell `sleep 8` and a Python
# time.sleep(8), each timed. Capped, both report about 3 s and the output has the cap's line; uncapped, about 8 s.
# Grok's allowlist has no bare shell command (only ./fh, ./shot, python3), so its probe is the Python half.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/tools/profile-flags.sh"
kind=${1:?usage: tools/sleepcap/probe.sh KIND MODEL [ROUTE]} model=${2:?model} route=${3:-}
export POG_SLEEP_CAP_SECONDS=3
ws=sleepcap-$kind
rm -rf "$root/runs/ctxtest/$ws"
dir=$(POG_WS=$ws "$root/tools/new-run.sh" ctxtest n "$ws" 30)
cd "$dir"
py='python3 -c "import time; t=time.time(); time.sleep(8); print(\"python slept\", round(time.time()-t), \"s\")"'
shell='command -v sleep; s=$(date +%s); sleep 8; echo "shell slept $(( $(date +%s) - s )) s"'
task="Run this exactly once as one shell command, then reply with its complete output (stdout and stderr) verbatim: $shell; $py"
[ "$kind" = grok ] && task="Run this exactly once as one shell command, then reply with its complete output (stdout and stderr) verbatim: $py"
route_root() { /Users/owner/.local/bin/ai-session routes | awk -v r="$1" -v h="$2" '$1 == r && $2 == h {print $NF}'; }
start=$(date +%s)
case $kind in
  claude)
    route=${route:-claude}
    mkdir -p .claude
    printf '{"permissions": {"defaultMode": "dontAsk", "allow": ["Bash"]}}\n' > .claude/settings.json
    python3 "$root/tools/context.py" setup claude "$model" "$dir" >/dev/null
    python3 "$root/tools/sleepcap/setup.py" claude "$dir"
    croot=$(route_root "$route" claude)
    cenv="-u CLAUDE_CONFIG_DIR"; [ "$route" = claude ] || cenv="CLAUDE_CONFIG_DIR='$croot'"
    eval "env $claude_unset $cenv $claude_vars '$sleepcap_run' /Users/owner/.local/bin/claude -p \"\$task\" --model $model $claude_flags" > probe.out 2>&1
    ;;
  codex)
    route=${route:-codex-b}
    python3 "$root/tools/context.py" setup codex "$model" "$dir" >/dev/null
    python3 "$root/tools/sleepcap/setup.py" codex "$dir"
    CODEX_HOME=$(route_root "$route" codex) /opt/homebrew/bin/codex exec --skip-git-repo-check -C "$dir" -m "$model" \
      -c 'model_reasoning_effort="low"' --sandbox workspace-write "$task" > probe.out 2>&1
    ;;
  grok)
    ctx_env=$(python3 "$root/tools/context.py" setup grok "$model" "$dir")
    home_env=$(python3 "$root/tools/grok-home.py" setup "$dir" 1800)
    eval "env $grok_env $home_env $ctx_env '$sleepcap_run' '$grok_bin' -p \"\$task\" -m $model $grok_allow --output-format plain" > probe.out 2>&1
    ;;
  muse)
    ctx_args=$(python3 "$root/tools/context.py" setup muse "$model" "$dir")
    clean_args=$(python3 "$root/tools/clean-profile.py" muse "$dir")
    eval "env $muse_env '$sleepcap_run' muse exec $ctx_args $clean_args --model $model --effort low --workspace '$dir' --trust-workspace --approval-mode never \"\$task\"" > probe.out 2>&1
    ;;
  agy)
    "$sleepcap_run" agy -p "$task" --model "$model" --dangerously-skip-permissions > probe.out 2>&1
    ;;
  *) echo "unknown kind $kind" >&2; exit 64 ;;
esac
echo "sleepcap probe: $kind $model, $(( $(date +%s) - start )) s, in $dir"
grep -E "sleep|slept|waits longer" probe.out | sed 's/^/  /'
if grep -q "slept 3 s" probe.out; then echo "capped: $(grep -c 'slept 3 s' probe.out) of the waits"; else echo "NOT capped (or the agent did not run it): see $dir/probe.out"; fi
