#!/usr/bin/env bash
# Keep an agent playing until its deadline: tools/supervise.sh PANE RUN_WORKSPACE
# If the agent goes idle before deadline.txt, prompt it to continue. Logs to WORKSPACE/supervisor.log: each nudge, how
# it was delivered (herdr's exit status and reply), turns that ended on a refused command, and skipped nudges.
# Env: POG_NUDGE_TEXT replaces the nudge ({left} = minutes left; smoke tests use it to check delivery).
# POG_SUPERVISE_QUIET and POG_SUPERVISE_POLL (seconds, default 60 and 20) shorten the waits for tools/test_supervise.py.
pane=$1 dir=$2
quiet=${POG_SUPERVISE_QUIET:-60} poll=${POG_SUPERVISE_POLL:-20}
root=$(cd "$(dirname "$0")/.." && pwd)
log() { echo "$(date +%T) $*" >> "$dir/supervisor.log"; }
# deadline.txt has minutes only ("2026-10-10 22:44 PDT"); without explicit seconds date -j takes the current ones.
d=$(cat "$dir/deadline.txt")
deadline=$(date -j -f "%Y-%m-%d %H:%M:%S %Z" "${d% *}:00 ${d##* }" +%s)
read -r kind _ at _ 2>/dev/null < "$dir/.context-hooks" || kind=""
nudges=0
agent_status() { herdr pane get "$pane" 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | cut -d'"' -f4; }
# Seconds since the agent's last request in its journal (999999 with none). herdr's status reads idle or done while an
# agent waits on a backgrounded --wait or a long tool call (shake3: Grok nudged mid-turn, Muse five times while
# building), but the journal shows the work: a request in the last 2 minutes means working.
since_request() {
  local at
  at=$(tail -n 400 "$dir/journal.jsonl" 2>/dev/null | grep '"event":"request"' | tail -n 1 | cut -d'"' -f4)
  [ -n "$at" ] || { echo 999999; return; }
  echo $(( $(date +%s) - $(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${at%%.*}" +%s) ))
}

deliver() {
  local text=$1 out rc
  out=$(herdr agent prompt "$pane" "$text" 2>&1); rc=$?
  log "  delivery: agent prompt rc=$rc ${out:0:160}"
  if [ $rc -ne 0 ]; then
    # Panes herdr does not track as agents (Muse Code in shake2) reject agent prompt: type the text instead.
    out=$(herdr pane send-text "$pane" "$text" 2>&1 && sleep 0.5 && herdr pane send-keys "$pane" enter 2>&1); rc=$?
    log "  delivery: pane send-text rc=$rc ${out:0:160}"
  fi
}

while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$(agent_status)
  if [ "$status" = idle ] || [ "$status" = done ]; then
    # Agents waiting on background work can look idle between turns: require a quiet minute.
    sleep "$quiet"
    status=$(agent_status)
    now=$(date +%s)
    ago=$(since_request)
    # Claude Code reports idle only once its turn has ended, so a recent request means nothing there (shake4: Sonnet
    # and Haiku ended turns right after an auto-compaction and this skip held the nudge another round).
    if { [ "$status" = idle ] || [ "$status" = done ]; } && [ "$now" -lt "$((deadline - 30))" ] && [ "$ago" -lt 120 ] \
        && [ "$kind" != claude ]; then
      log "skip nudge (status $status): last request ${ago}s ago, working"
    elif { [ "$status" = idle ] || [ "$status" = done ]; } && [ "$now" -lt "$((deadline - 30))" ]; then
      left=$(( (deadline - now + 59) / 60 ))
      # Grok compacts at a fixed share of its window; a nudge's status/chat/board reads near that point set off a
      # minute-long compaction (shake2: 67 s of its last 2 minutes). Skip it in the last 3 minutes.
      if [ "$kind" = grok ] && [ $((deadline - now)) -le 180 ] && [ -n "$at" ] && [ "$at" -gt 0 ]; then
        tokens=$(python3 "$root/tools/context.py" grok-tokens "$dir")
        if [ "$tokens" -ge $((at - 25000)) ]; then
          log "skip nudge (${left}m left): grok context $tokens is near its compaction point $at"
          sleep 20; continue
        fi
      fi
      nudges=$((nudges + 1))
      log "nudge $nudges (status $status, ${left}m left)"
      text="The deadline in deadline.txt is $left minutes away (the clock: line shows it) and it is the only stop condition. Run ./fh call status, ./fh call chat and ./fh board, re-read notes.md, and keep playing until the deadline has passed."
      # A turn that ended on a refused command (Haiku in shake2 stopped 12 times on one denied loop).
      if herdr pane read "$pane" --source visible --lines 60 2>/dev/null \
          | grep -qiE "permission to use bash has been denied|denied by prompt policy|not pre-approved|command was denied"; then
        log "  turn ended on a refused command"
        text="$text Your last command was refused by the shell's permissions; only that command was refused. Write it as separate commands joined with && (no loop, no shell variables) or as a short python3 script, and carry on."
      fi
      [ -n "${POG_NUDGE_TEXT:-}" ] && text=${POG_NUDGE_TEXT//\{left\}/$left}
      deliver "$text"
    fi
  elif [ "$status" = blocked ]; then
    log "blocked: needs a human look"
  fi
  sleep "$poll"
done
log "deadline reached after $nudges nudges"
