#!/usr/bin/env bash
# Keep an agent playing until its deadline: tools/supervise.sh PANE RUN_WORKSPACE
# If the agent goes idle before deadline.txt, prompt it to continue. Logs to WORKSPACE/supervisor.log.
pane=$1 dir=$2
deadline=$(date -j -f "%Y-%m-%d %H:%M %Z" "$(cat "$dir/deadline.txt")" +%s)
nudges=0
agent_status() { herdr pane get "$pane" 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | cut -d'"' -f4; }
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$(agent_status)
  if [ "$status" = idle ] || [ "$status" = done ]; then
    # Agents waiting on background work can look idle between turns: require a quiet minute.
    sleep 60
    status=$(agent_status)
    now=$(date +%s)
    if { [ "$status" = idle ] || [ "$status" = done ]; } && [ "$now" -lt "$((deadline - 30))" ]; then
      nudges=$((nudges + 1))
      left=$(( (deadline - now) / 60 ))
      echo "$(date +%T) nudge $nudges (status $status, ${left}m left)" >> "$dir/supervisor.log"
      herdr agent prompt "$pane" "The deadline in deadline.txt is $left minutes away and it is the only stop condition. Run ./fh call status and ./fh call chat, re-read notes.md, and take the most useful open item (unfuelled burners, starved labs, turrets low on ammo, requests naming you, open board items). Write the final summary only in the last three minutes." >/dev/null 2>&1
    fi
  elif [ "$status" = blocked ]; then
    echo "$(date +%T) blocked: needs a human look" >> "$dir/supervisor.log"
  fi
  sleep 20
done
echo "$(date +%T) deadline reached after $nudges nudges" >> "$dir/supervisor.log"
