#!/usr/bin/env bash
# Answer first-run folder-trust prompts in agent panes, all panes in one pass (we created the folders):
#   tools/clear-prompts.sh SECONDS PANE DIR [PANE DIR ...]
# A pane is done when its trust prompt is answered, its screen shows the agent working, or its workspace journal grew
# since this script started (the agent made a request, so it is past any prompt). Prints "PANE trust|working|journal"
# as each pane is done and "PANE timeout" for the rest after SECONDS.
# shake3: launching one pane at a time, five agents showed none of these within the 40 s per-pane wait (44-49 s each),
# so a team launch took 4.5 minutes. tools/start-team.sh now starts every pane first (POG_NO_WAIT=1) and then waits
# for all of them together here.
set -uo pipefail
limit=$1; shift
size() { local n; n=$(wc -c 2>/dev/null < "$1") || n=0; echo $((n)); }
panes=() dirs=() base=() state=()
while [ $# -ge 2 ]; do
  panes+=("$1"); dirs+=("$2")
  base+=("$(size "$2/journal.jsonl")")   # the launcher's describe call is journaled too
  state+=("")
  shift 2
done
end=$(( $(date +%s) + limit )) pending=${#panes[@]}
while [ "$pending" -gt 0 ] && [ "$(date +%s)" -lt "$end" ]; do
  for i in "${!panes[@]}"; do
    [ -n "${state[$i]}" ] && continue
    pane=${panes[$i]} dir=${dirs[$i]} s=""
    screen=$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null || true)
    if grep -q "Yes, I trust this folder" <<<"$screen"; then
      # Claude lists "No, exit" first; Antigravity preselects "Yes". Move only if Yes is not highlighted.
      grep -qE "^[[:space:]]*(❯|>)[[:space:]]*Yes, I trust" <<<"$screen" || { herdr pane send-keys "$pane" down >/dev/null; sleep 0.3; }
      herdr pane send-keys "$pane" enter >/dev/null; s=trust
    elif grep -q "Trust and continue" <<<"$screen"; then
      herdr agent send-keys "$pane" enter >/dev/null; s=trust
    elif grep -qiE "trust this (folder|project|directory)" <<<"$screen"; then
      herdr pane send-keys "$pane" enter >/dev/null; s=trust
    elif grep -qE "Working|esc to interrupt|thinking|Thinking" <<<"$screen"; then
      s=working
    elif [ "$(size "$dir/journal.jsonl")" -gt "${base[$i]}" ]; then
      s=journal
    fi
    if [ -n "$s" ]; then state[$i]=$s; pending=$((pending - 1)); echo "$pane $s"; fi
  done
  [ "$pending" -gt 0 ] && sleep 1
done
for i in "${!panes[@]}"; do [ -n "${state[$i]}" ] || echo "${panes[$i]} timeout"; done
exit 0
