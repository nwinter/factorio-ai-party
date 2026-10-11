#!/usr/bin/env bash
# Start an agent on a world: tools/launch-agent.sh RUN_ID WORLD PLAYER MINUTES KIND [MODEL] [EFFORT]
#   KIND: codex | claude | grok | agy | muse
#   Env: POG_ROUTE (ai-session route for codex/claude), POG_TAB (Herdr tab to join), POG_TIME_MODE, POG_NO_WAIT=1
#   (return without clearing trust prompts; the caller runs tools/clear-prompts.sh), and the co-op
#   overrides read by tools/new-run.sh (POG_WS, POG_CLIENT, POG_PLAYER_INDEX, POG_TEAMMATE, ...).
# Creates the workspace, starts the agent in Herdr, and clears first-run trust prompts (we created the folder).
# Prints: PANE TAB WORKSPACE
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# A later shift (tools/start-team.sh, POG_RESUME): one neutral sentence on the prompt, no advice.
resume_sentence='This is a later shift of the same world: your bot and the factory are as the last shift left them, and notes.md is where you left off.'
if [ "${1:-}" = --resume-sentence ]; then echo "$resume_sentence"; exit 0; fi
. "$root/tools/profile-flags.sh"
run=$1 world=$2 player=$3 minutes=$4 kind=$5
dir=$("$root/tools/new-run.sh" "$run" "$world" "$player" "$minutes")
# describe.json, one action per line, ready before the agent starts (in shake1 Grok Build's permissions blocked the
# redirect that made it, and grep on the one-line file returned all of it).
"$dir/fh" call describe --format json 2>/dev/null | python3 "$root/tools/describe-lines.py" > "$dir/describe.json" 2>/dev/null \
  || rm -f "$dir/describe.json"
# Harness-specific notes (agent/harness-KIND.md) go before the compaction instructions at the end of AGENTS.md.
if [ -f "$root/agent/harness-$kind.md" ]; then
  python3 - "$dir/AGENTS.md" "$root/agent/harness-$kind.md" <<'EOP'
import sys
path, extra = sys.argv[1:]
text, add = open(path).read(), open(extra).read().rstrip("\n") + "\n\n"
i = text.find("## Compact instructions")
open(path, "w").write(text[:i] + add + text[i:] if i >= 0 else text.rstrip("\n") + "\n\n" + add)
EOP
fi
prompt="$root/runs/$run/prompt.md"
if [ ! -f "$prompt" ]; then
  cat > "$prompt" <<'EOP'
Read AGENTS.md in this directory; it has your instructions, interface, rules, and deadline. Then play Factorio until the deadline in deadline.txt, keeping notes.md current, and finish with the final summary it asks for.
EOP
  if [ -n "${POG_RESUME:-}" ]; then printf '%s\n' "$resume_sentence" >> "$prompt"; fi
fi
name="pog-${POG_WS:-$world}-$run"
allow='"Read", "Grep", "Glob", "Edit(/**)", "Write(/**)", "Bash(./fh:*)", "Bash(./shot:*)", "Bash(echo:*)",
              "Bash(sleep:*)", "Bash(date:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(grep:*)",
              "Bash(python3:*)", "Bash(jq:*)", "Bash(ls:*)", "Bash(wc:*)", "Bash(rg:*)", "Bash(sort:*)"'
# Compaction settings per model: agent/context.tsv, applied by tools/context.py (docs/CONTEXT-NOTES.md).
compact_rule='After any context compaction, read notes.md and deadline.txt before acting; notes.md is your memory.'

# Claude-style settings: Claude Code uses the sandbox; Grok Build reads the same file for its allowlist.
claude_settings() {
  mkdir -p "$dir/.claude"
  # ~/.config/pog holds the OBS password, the YouTube stream key and every world's RCON password; fh gets its one key
  # from runs/RUN/.keys (tools/new-run.sh). Claude Code reads "~/" in Read rules, Grok Build only absolute paths.
  local sandbox="\"sandbox\": {\"enabled\": true, \"autoAllowBashIfSandboxed\": true, \"allowUnsandboxedCommands\": false,
    \"network\": {\"allowLocalBinding\": true}, \"filesystem\": {\"denyRead\": [\"$HOME/.config/pog\"]}},"
  [ "${1:-}" = nosandbox ] && sandbox=''   # Grok Build: allowlist only (its own sandbox flags differ)
  cat > "$dir/.claude/settings.json" <<EOS
{
  $sandbox
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [$allow],
    "deny": ["Read(~/.config/pog/**)", "Read($HOME/.config/pog/**)", "Edit(~/.config/pog/**)", "Edit($HOME/.config/pog/**)"]
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
  claude)
    model=${6:-opus} effort=${7:-low}
    route=${POG_ROUTE:-claude-b}
    claude_settings
    python3 "$root/tools/context.py" setup claude "$model" "$dir" >/dev/null
    python3 "$root/tools/clean-profile.py" claude "$dir"
    # Started directly instead of through ai-session, which cannot pass flags: with the same environment ai-session
    # sets for the route (CLAUDE_CONFIG_DIR = the route's root, except for the default profile, and no API keys), plus
    # no MCP servers but our own (the user-scope cube-local leaked in smoke-2145), no Claude in Chrome, no skills.
    croot=$(/Users/owner/.local/bin/ai-session routes | awk -v r="$route" '$1 == r && $2 == "claude" {print $NF}')
    test -n "$croot" || { echo "unknown Claude route $route" >&2; exit 1; }
    cenv="-u CLAUDE_CONFIG_DIR"; [ "$route" = claude ] || cenv="CLAUDE_CONFIG_DIR='$croot'"
    pane=$(new_pane)
    # $claude_unset, $claude_vars and $claude_flags: tools/profile-flags.sh.
    herdr pane run "$pane" "cd '$dir' && env $claude_unset $cenv $claude_vars /Users/owner/.local/bin/claude --model $model --effort $effort $claude_flags \"\$(cat '$prompt')\"" >/dev/null
    ;;
  codex)
    model=${6:-gpt-6-astra} effort=${7:-low}
    args=(--route "${POG_ROUTE:-codex-b}" --model "$model" --thinking "$effort" --sandbox workspace-write --network --approval never)
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
    # --rules is part of the system prompt, which compaction keeps. $grok_env and $grok_allow: tools/profile-flags.sh.
    herdr pane run "$pane" "cd '$dir' && $grok_env $ctx_env grok -m $model --effort $effort $grok_allow --rules '$compact_rule' \"\$(cat '$prompt')\"" >/dev/null
    ;;
  agy)
    model=${6:-gemini-3.8-flash-high}
    pane=$(new_pane)
    limit=$(python3 "$root/tools/context.py" limit agy "$model")
    # Print-mode turns back to back until the deadline. No --sandbox: it blocked ./fh (its target is outside the
    # workspace) and the model bypassed it on 576 calls in shake1 (auto-approved), so it only cost time.
    # agy has no compaction threshold setting (it compacts near 280K): past the limit, the next turn starts a fresh
    # conversation that picks up from notes.md. The check runs only between turns, and one turn can last the hour
    # (shake2: 53 minutes); agy's own compaction covers that case.
    cat > "$dir/.agy-loop.sh" <<EOL
#!/usr/bin/env bash
cd '$dir'
# deadline.txt has minutes only; without explicit seconds date -j takes the current ones (shake2: a turn at 22:46:12).
d=\$(cat deadline.txt)
deadline=\$(date -j -f "%Y-%m-%d %H:%M:%S %Z" "\${d% *}:00 \${d##* }" +%s)
agy -p "\$(cat '$prompt')" --model $model --dangerously-skip-permissions
${POG_ONE_TURN:+exit 0  # POG_ONE_TURN: smoke tests run the first turn only}
while [ "\$(date +%s)" -lt "\$((deadline - 20))" ]; do
  tokens=\$(python3 '$root/tools/context.py' agy-tokens '$dir')
  left=\$(( (deadline - \$(date +%s) + 59) / 60 ))
  # No fresh start in the last 2 minutes: it costs a re-read of notes.md (shake3: Grok's compaction 39 s before its
  # deadline ended its play).
  if [ "$limit" -gt 0 ] && [ "\$tokens" -ge "$limit" ] && [ "\$((deadline - \$(date +%s)))" -gt 120 ]; then
    echo "{\"time\": \"\$(date '+%Y-%m-%d %H:%M:%S')\", \"event\": \"agy-fresh\", \"tokens\": \$tokens}" >> context.log
    agy -p "\$(cat '$prompt') This is a fresh conversation: your previous one was closed at \$tokens tokens to keep your context small. notes.md is your memory from it: read it and deadline.txt first, then check ./fh call status and chat. The deadline is \$left minutes away." --model $model --dangerously-skip-permissions
  else
    agy -c -p "Continue: the deadline in deadline.txt is \$left minutes away (the clock: line shows it) and it is the only stop condition. Re-read notes.md, check ./fh call status, ./fh call chat and ./fh board, and keep playing until the deadline has passed." --model $model --dangerously-skip-permissions
  fi
done
EOL
    chmod +x "$dir/.agy-loop.sh"
    herdr pane run "$pane" "'$dir/.agy-loop.sh'" >/dev/null
    ;;
  muse)
    model=${6:-muse-spark-1.3} effort=${7:-low}
    ctx_args=$(python3 "$root/tools/context.py" setup muse "$model" "$dir")   # -c context_compaction.* options
    clean_args=$(python3 "$root/tools/clean-profile.py" muse "$dir")         # -c 'hooks={}'; $muse_env: profile-flags.sh
    pane=$(new_pane)
    printf '%s\n' '#!/usr/bin/env bash' "cd '$dir'" \
      "exec env $muse_env muse $ctx_args $clean_args --model $model --effort $effort --approval-mode never --sandbox-network enabled --trust-workspace \"\$(cat '$prompt')\"" \
      > "$dir/.muse-run.sh"
    chmod +x "$dir/.muse-run.sh"
    herdr pane run "$pane" "'$dir/.muse-run.sh'" >/dev/null
    ;;
  *) echo "unknown kind $kind" >&2; exit 1 ;;
esac
[ -n "${tab:-}" ] || tab=$(herdr pane get "$pane" | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; print(d.get('pane',d)['tab_id'])")
herdr pane rename "$pane" "$name" >/dev/null 2>&1 || true

# First-run prompts we can answer: folder trust (we created it). POG_NO_WAIT=1 skips this so a team launch can start
# every pane first and clear all prompts in one pass (tools/start-team.sh).
[ "${POG_NO_WAIT:-}" = 1 ] || "$root/tools/clear-prompts.sh" 40 "$pane" "$dir" >/dev/null
echo "$pane $tab $dir"
