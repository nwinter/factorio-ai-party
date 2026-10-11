#!/usr/bin/env bash
# Start an agent on a world: tools/launch-agent.sh RUN_ID WORLD PLAYER MINUTES KIND [MODEL] [EFFORT]
#   KIND: codex | claude | grok | agy | muse
#   Env: POG_ROUTE (ai-session route for codex/claude), POG_TAB (Herdr tab to join), POG_TIME_MODE, and the co-op
#   overrides read by tools/new-run.sh (POG_WS, POG_CLIENT, POG_PLAYER_INDEX, POG_TEAMMATE, ...).
# Creates the workspace, starts the agent in Herdr, and clears first-run trust prompts (we created the folder).
# Prints: PANE TAB WORKSPACE
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4 kind=$5
dir=$("$root/tools/new-run.sh" "$run" "$world" "$player" "$minutes")
# describe.json, one action per line, ready before the agent starts (in shake1 Grok Build's permissions blocked the
# redirect that made it, and grep on the one-line file returned all of it).
"$dir/fh" call describe --format json 2>/dev/null | python3 "$root/tools/describe-lines.py" > "$dir/describe.json" 2>/dev/null \
  || rm -f "$dir/describe.json"
prompt="$root/runs/$run/prompt.md"
test -f "$prompt" || cat > "$prompt" <<'EOP'
Read AGENTS.md in this directory; it has your instructions, interface, rules, and deadline. Then play Factorio until the deadline in deadline.txt, keeping notes.md current, and finish with the final summary it asks for.
EOP
name="pog-${POG_WS:-$world}-$run"
allow='"Read", "Grep", "Glob", "Edit(/**)", "Write(/**)", "Bash(./fh:*)", "Bash(./shot:*)", "Bash(echo:*)",
              "Bash(sleep:*)", "Bash(date:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(grep:*)",
              "Bash(python3:*)", "Bash(jq:*)", "Bash(ls:*)", "Bash(wc:*)"'
# Compaction settings per model: agent/context.tsv, applied by tools/context.py (docs/CONTEXT-NOTES.md).
compact_rule='After any context compaction, read notes.md and deadline.txt before acting; notes.md is your memory.'

# Claude-style settings: Claude Code uses the sandbox; Grok Build reads the same file for its allowlist.
claude_settings() {
  mkdir -p "$dir/.claude"
  local sandbox='"sandbox": {"enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
    "network": {"allowLocalBinding": true}},'
  [ "${1:-}" = nosandbox ] && sandbox=''   # Grok Build: allowlist only (its own sandbox flags differ)
  cat > "$dir/.claude/settings.json" <<EOS
{
  $sandbox
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [$allow]
  }
}
EOS
}

# Open a Herdr pane for a non-ai-session harness: a new tab, or beside an agent in POG_TAB.
new_pane() {
  if [ -n "${POG_TAB:-}" ]; then
    local anchor
    anchor=$(herdr pane list --workspace "${POG_TAB%%:*}" | python3 -c "import json,sys; t=sys.argv[1]; print([p['pane_id'] for p in json.load(sys.stdin)['result']['panes'] if p['tab_id']==t][-1])" "$POG_TAB")
    herdr pane split "$anchor" --direction right --cwd "$dir" --no-focus | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['pane']['pane_id'])"
  else
    herdr tab create --workspace "${HERDR_WORKSPACE_ID:?run inside Herdr}" --label "$run" --cwd "$dir" --no-focus | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['root_pane']['pane_id'])"
  fi
}

case $kind in
  codex|claude)
    if [ "$kind" = codex ]; then
      model=${6:-gpt-6-astra} effort=${7:-low}
      args=(--route "${POG_ROUTE:-codex-b}" --model "$model" --thinking "$effort" --sandbox workspace-write --network --approval never)
    else
      model=${6:-opus} effort=${7:-low}
      claude_settings
      args=(--route "${POG_ROUTE:-claude-b}" --model "$model" --thinking "$effort" --permission-mode dontAsk)
    fi
    # ai-session passes no extra flags or env, so compaction settings go in the workspace's own config.
    python3 "$root/tools/context.py" setup "$kind" "$model" "$dir" >/dev/null
    python3 "$root/tools/clean-profile.py" "$kind" "$dir"
    out=$(/Users/owner/.local/bin/ai-session spawn "${args[@]}" -C "$dir" --name "$name" --herdr tab --prompt-file "$prompt" --start 2>&1)
    pane=$(printf '%s\n' "$out" | sed -n 's/.*Herdr pane \([^ .]*\).*/\1/p' | tail -1)
    test -n "$pane" || { printf '%s\n' "$out" >&2; exit 1; }
    tab=$(herdr pane get "$pane" | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; print(d.get('pane',d)['tab_id'])")
    if [ -n "${POG_TAB:-}" ]; then
      anchor=$(herdr pane list --workspace "${POG_TAB%%:*}" | python3 -c "import json,sys; t=sys.argv[1]; print([p['pane_id'] for p in json.load(sys.stdin)['result']['panes'] if p['tab_id']==t][-1])" "$POG_TAB")
      herdr pane move "$pane" --tab "$POG_TAB" --split right --target-pane "$anchor" --no-focus >/dev/null
      herdr tab close "$tab" >/dev/null 2>&1 || true
      tab=$POG_TAB
    else
      herdr tab rename "$tab" "$run" >/dev/null 2>&1 || true
    fi
    ;;
  grok)
    model=${6:-grok-4.7} effort=${7:-low}
    claude_settings nosandbox
    ctx_env=$(python3 "$root/tools/context.py" setup grok "$model" "$dir")
    pane=$(new_pane)
    # --rules is part of the system prompt, which compaction keeps.
    herdr pane run "$pane" "cd '$dir' && $ctx_env grok -m $model --effort $effort --permission-mode dontAsk --rules '$compact_rule' \"\$(cat '$prompt')\"" >/dev/null
    ;;
  agy)
    model=${6:-gemini-3.8-flash-high}
    pane=$(new_pane)
    limit=$(python3 "$root/tools/context.py" limit agy "$model")
    # Antigravity's sandbox only works in print mode, so run sandboxed turns back to back until the deadline.
    # agy has no compaction threshold setting (it compacts near 280K): past the limit, the next turn starts a fresh
    # conversation that picks up from notes.md.
    cat > "$dir/.agy-loop.sh" <<EOL
#!/usr/bin/env bash
cd '$dir'
deadline=\$(date -j -f "%Y-%m-%d %H:%M %Z" "\$(cat deadline.txt)" +%s)
agy -p "\$(cat '$prompt')" --model $model --sandbox --dangerously-skip-permissions
while [ "\$(date +%s)" -lt "\$deadline" ]; do
  tokens=\$(python3 '$root/tools/context.py' agy-tokens '$dir')
  if [ "$limit" -gt 0 ] && [ "\$tokens" -ge "$limit" ]; then
    echo "{\"time\": \"\$(date '+%Y-%m-%d %H:%M:%S')\", \"event\": \"agy-fresh\", \"tokens\": \$tokens}" >> context.log
    agy -p "\$(cat '$prompt') This is a fresh conversation: your previous one was closed at \$tokens tokens to keep your context small. notes.md is your memory from it: read it and deadline.txt first, then check ./fh call status and chat." --model $model --sandbox --dangerously-skip-permissions
  else
    left=\$(( (deadline - \$(date +%s)) / 60 ))
    agy -c -p "Continue: the deadline in deadline.txt is \$left minutes away and it is the only stop condition. Re-read notes.md, check ./fh call status and chat, and take the most useful open item. Write the final summary only in the last three minutes." --model $model --sandbox --dangerously-skip-permissions
  fi
done
EOL
    chmod +x "$dir/.agy-loop.sh"
    herdr pane run "$pane" "'$dir/.agy-loop.sh'" >/dev/null
    ;;
  muse)
    model=${6:-muse-spark-1.3} effort=${7:-low}
    python3 "$root/tools/context.py" setup muse "$model" "$dir" >/dev/null
    pane=$(new_pane)
    herdr pane run "$pane" "cd '$dir' && muse --model $model --effort $effort --approval-mode never --sandbox-network enabled --trust-workspace \"\$(cat '$prompt')\"" >/dev/null
    ;;
  *) echo "unknown kind $kind" >&2; exit 1 ;;
esac
[ -n "${tab:-}" ] || tab=$(herdr pane get "$pane" | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; print(d.get('pane',d)['tab_id'])")
herdr pane rename "$pane" "$name" >/dev/null 2>&1 || true

# First-run prompts we can answer: folder trust (we created it).
for _ in $(seq 1 40); do
  screen=$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null || true)
  if grep -q "Yes, I trust this folder" <<<"$screen"; then
    # Claude lists "No, exit" first; Antigravity preselects "Yes". Move only if Yes is not highlighted.
    grep -qE "^[[:space:]]*(❯|>)[[:space:]]*Yes, I trust" <<<"$screen" || { herdr pane send-keys "$pane" down >/dev/null; sleep 0.3; }
    herdr pane send-keys "$pane" enter >/dev/null; break
  fi
  if grep -q "Trust and continue" <<<"$screen"; then herdr agent send-keys "$pane" enter >/dev/null; break; fi
  if grep -qiE "trust this (folder|project|directory)" <<<"$screen"; then herdr pane send-keys "$pane" enter >/dev/null; break; fi
  if grep -qE "Working|esc to interrupt|thinking|Thinking" <<<"$screen"; then break; fi
  sleep 1
done
echo "$pane $tab $dir"
