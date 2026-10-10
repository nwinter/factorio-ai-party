#!/usr/bin/env bash
# Keep an agent playing until its deadline: tools/supervise.sh PANE RUN_WORKSPACE
# If the agent goes idle before deadline.txt, prompt it to continue. Logs to WORKSPACE/supervisor.log.
pane=$1 dir=$2
deadline=$(date -j -f "%Y-%m-%d %H:%M %Z" "$(cat "$dir/deadline.txt")" +%s)
nudges=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$(herdr pane get "$pane" 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | cut -d'"' -f4)
  if [ "$status" = idle ] || [ "$status" = done ]; then
    # Agents waiting on background work look idle between turns: require 3 quiet minutes.
    sleep 180
    status=$(herdr pane get "$pane" 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | cut -d'"' -f4)
    if { [ "$status" = idle ] || [ "$status" = done ]; } && [ "$(date +%s)" -lt "$((deadline - 120))" ]; then
      nudges=$((nudges + 1))
      echo "$(date +%T) nudge $nudges (status $status)" >> "$dir/supervisor.log"
      herdr agent prompt "$pane" "The deadline in deadline.txt has not passed yet. Re-read notes.md, check ./fh call status, and keep playing toward the next milestone until the deadline." >/dev/null 2>&1
    fi
  elif [ "$status" = blocked ]; then
    echo "$(date +%T) blocked: needs a human look" >> "$dir/supervisor.log"
  fi
  sleep 60
done
echo "$(date +%T) deadline reached after $nudges nudges" >> "$dir/supervisor.log"
