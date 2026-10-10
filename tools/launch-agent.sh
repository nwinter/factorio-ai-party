#!/usr/bin/env bash
# Start an agent on a world: tools/launch-agent.sh RUN_ID WORLD PLAYER MINUTES codex|claude [MODEL] [THINKING]
# Creates the workspace, spawns the agent in Herdr via ai-session, and accepts the first-run folder-trust prompt
# (we created the folder). Prints the pane id, tab id and workspace.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4 kind=$5
dir=$("$root/tools/new-run.sh" "$run" "$world" "$player" "$minutes")
prompt="$root/runs/$run/prompt.md"
test -f "$prompt" || cat > "$prompt" <<'EOP'
Read AGENTS.md in this directory; it has your instructions, interface, rules, and deadline. Then play Factorio until the deadline in deadline.txt, keeping notes.md current, and finish with the final summary it asks for.
EOP
if [ "$kind" = codex ]; then
  model=${6:-gpt-6-astra} thinking=${7:-low}
  args=(--route codex-b --model "$model" --thinking "$thinking" --sandbox workspace-write --network --approval never)
else
  model=${6:-fable} thinking=${7:-low}
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<'EOS'
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false,
    "network": { "allowLocalBinding": true }
  },
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": ["Read", "Grep", "Glob", "Edit(/**)", "Write(/**)", "Bash(./fh:*)", "Bash(./shot:*)", "Bash(echo:*)",
              "Bash(sleep:*)", "Bash(date:*)", "Bash(cat:*)", "Bash(python3:*)", "Bash(jq:*)"]
  }
}
EOS
  args=(--route claude-b --model "$model" --thinking "$thinking" --permission-mode dontAsk)
fi
# Each run gets its own Herdr tab (POG_TAB=<tab id> puts this agent beside one already there).
out=$(/Users/owner/.local/bin/ai-session spawn "${args[@]}" -C "$dir" --name "pog-$world-$run" --herdr tab --prompt-file "$prompt" --start 2>&1)
pane=$(printf '%s\n' "$out" | sed -n 's/.*Herdr pane \([^ .]*\).*/\1/p' | tail -1)
test -n "$pane" || { printf '%s\n' "$out" >&2; exit 1; }
tab=$(herdr pane get "$pane" | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; print(d.get('pane',d)['tab_id'])")
if [ -n "${POG_TAB:-}" ]; then
  anchor=$(herdr pane list --workspace "${POG_TAB%%:*}" | python3 -c "import json,sys; t=sys.argv[1]; print([p['pane_id'] for p in json.load(sys.stdin)['result']['panes'] if p['tab_id']==t][0])" "$POG_TAB")
  herdr pane move "$pane" --tab "$POG_TAB" --split right --target-pane "$anchor" --no-focus >/dev/null
  herdr tab close "$tab" >/dev/null 2>&1 || true
  tab=$POG_TAB
else
  herdr tab rename "$tab" "$run" >/dev/null 2>&1 || true
fi
for _ in $(seq 1 40); do
  screen=$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null || true)
  if grep -q "Yes, I trust this folder" <<<"$screen"; then herdr agent send-keys "$pane" down >/dev/null; sleep 0.3; herdr agent send-keys "$pane" enter >/dev/null; break; fi
  if grep -q "Trust and continue" <<<"$screen"; then herdr agent send-keys "$pane" enter >/dev/null; break; fi
  if grep -qE "Working|esc to interrupt|thinking" <<<"$screen"; then break; fi
  sleep 1
done
echo "$pane $tab $dir"
