#!/usr/bin/env bash
# Start a Claude Code engineer on its own worktree and branch, in its own Herdr tab:
#   tools/launch-engineer.sh NAME BRANCH ROUTE EFFORT BRIEF.md MINUTES [web]
# The brief becomes CLAUDE.local.md in the worktree. "web" allows WebFetch/WebSearch and npx wrangler (unsandboxed).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
name=$1 branch=$2 route=$3 effort=$4 brief=$5 minutes=$6 web=${7:-}
worktrees_root="${POG_WORKTREES_ROOT:-/Users/owner/code/personal/player-of-games/worktrees}"
mkdir -p "$worktrees_root"
wt="$worktrees_root/pog-$name"
if [ ! -d "$wt" ]; then
  git -C "$root" worktree add -q -b "$branch" "$wt" main
  (cd "$wt/vendor/factorio-harness" && npm ci --silent >/dev/null 2>&1 && npm run build --silent >/dev/null 2>&1) || true
fi
cp "$brief" "$wt/CLAUDE.local.md"
date -v+"${minutes}"M "+%Y-%m-%d %H:%M %Z" > "$wt/deadline.txt"
printf 'Read CLAUDE.local.md in this directory and do the task it describes until the deadline in deadline.txt.\n' > "$wt/.task-prompt.md"
extra_allow="" extra_excl=""
if [ "$web" = web ]; then extra_allow=', "WebFetch", "WebSearch", "Bash(npx wrangler:*)", "Bash(npx --yes wrangler:*)"'; extra_excl=', "npx wrangler *", "npx --yes wrangler *"'; fi
mkdir -p "$wt/.claude"
cat > "$wt/.claude/settings.local.json" <<EOF
{
  "sandbox": {
    "enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
    "excludedCommands": ["tools/winps.sh *", "ssh *", "scp *"$extra_excl],
    "network": { "allowLocalBinding": true }
  },
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": ["Read", "Grep", "Glob", "Edit(/**)", "Write(/**)", "Bash(tools/winps.sh:*)", "Bash(ssh:*)", "Bash(scp:*)",
              "Bash(git:*)", "Bash(npm:*)", "Bash(lua:*)", "Bash(node:*)", "Bash(python3:*)", "Bash(bin/fh:*)"$extra_allow]
  }
}
EOF
out=$(/Users/owner/.local/bin/ai-session spawn --route "$route" --model opus --thinking "$effort" -C "$wt" --permission-mode dontAsk \
      --name "pog-$name" --herdr tab --prompt-file "$wt/.task-prompt.md" --start 2>&1)
pane=$(printf '%s\n' "$out" | sed -n 's/.*Herdr pane \([^ .]*\).*/\1/p' | tail -1)
test -n "$pane" || { printf '%s\n' "$out" >&2; exit 1; }
corrected=0
for _ in $(seq 1 40); do
  screen=$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null || true)
  # zsh autocorrect: answer only while it is the live prompt (the last line), never into Claude's input box
  if [ "$corrected" = 0 ] && grep -v '^[[:space:]]*$' <<<"$screen" | tail -1 | grep -q "correct '.*' to"; then
    herdr pane send-text "$pane" "n" >/dev/null; corrected=1; sleep 1; continue
  fi
  if grep -q "Yes, I trust this folder" <<<"$screen"; then
    grep -qE "^[[:space:]]*(❯|>)[[:space:]]*Yes, I trust" <<<"$screen" || { herdr pane send-keys "$pane" down >/dev/null; sleep 0.3; }
    herdr pane send-keys "$pane" enter >/dev/null; break
  fi
  if grep -qE "esc to interrupt|thinking|Musing|Proofing" <<<"$screen"; then break; fi
  sleep 1
done
tab=$(herdr pane get "$pane" | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; print(d.get('pane',d)['tab_id'])")
herdr tab rename "$tab" "$name" >/dev/null 2>&1 || true
echo "$name $pane $tab $wt"
