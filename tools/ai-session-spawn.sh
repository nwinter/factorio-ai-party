#!/usr/bin/env bash
# ai-session spawn for tools/launch-agent.sh, through a slow shell (d29 batch331 LS): tools/ai-session-spawn.sh ARGS...
# runs `ai-session spawn ARGS...` and prints the Herdr pane the agent runs in, or exits 1 with ai-session's output on
# stderr.
#
# ai-session gives a new pane's shell 20 s to start (place_in_herdr). shift96 (d29 00:21) and shift97 (00:37) failed at
# Astra's and Sol's launch when an interactive zsh took longer than that during a start (swap 9.2 of 10.2 GB): it
# raised "Herdr pane P did not finish shell startup; kept it for inspection. After fixing startup, run
# .../ai-session run ID there." and left the pane at a plain prompt. That case is carried on here: wait for the pane's
# shell (a marker it must compute itself, `echo pog-ready-$((N+1))`, so text echoed before the shell reads it never
# matches; sent again every POG_SHELL_RETRY_S, default 10 s, in case the shell dropped what was typed before it
# started), up to POG_SHELL_WAIT_S (default 90 s), then run the manifest it names there, as ai-session would have.
# Any other failure, or a shell still not ready, exits 1 and leaves the pane for inspection.
# POG_AI_SESSION: the ai-session binary (tests: a stub); herdr is the one on PATH.
set -euo pipefail
ai=${POG_AI_SESSION:-/Users/owner/.local/bin/ai-session}
wait_s=${POG_SHELL_WAIT_S:-90} retry_s=${POG_SHELL_RETRY_S:-10}
rc=0
out=$("$ai" spawn "$@" 2>&1) || rc=$?
pane_of() { printf '%s\n' "$1" | sed -n 's/.*Herdr pane \([^ .]*\).*/\1/p' | tail -1; }
pane=$(pane_of "$out")
if [ "$rc" = 0 ]; then
  test -n "$pane" || { printf '%s\n' "$out" >&2; exit 1; }
  echo "$pane"
  exit 0
fi
# the slow-shell case only: its pane and the manifest it names ("run LAUNCHER run ID there")
slow=$(printf '%s\n' "$out" | grep 'did not finish shell startup' | tail -1 || true)
manifest=$(printf '%s\n' "$slow" | sed -n 's/.* run \([^ ]*\) there\..*/\1/p')
launcher=$(printf '%s\n' "$slow" | sed -n 's/.*startup, run \(.*\) run [^ ]* there\..*/\1/p')
if [ -z "$pane" ] || [ -z "$manifest" ]; then printf '%s\n' "$out" >&2; exit 1; fi
n=$(( (RANDOM % 9000) + 1000 ))
marker="pog-ready-$((n + 1))"
echo "ai-session: pane $pane shell not ready after 20 s; waiting up to ${wait_s} s for it" >&2
start=$(date +%s) ready=0
while [ $(( $(date +%s) - start )) -lt "$wait_s" ]; do
  herdr pane run "$pane" "echo pog-ready-\$(($n + 1))" >/dev/null 2>&1 || true
  left=$(( wait_s - ($(date +%s) - start) ))
  [ "$left" -gt "$retry_s" ] && left=$retry_s
  [ "$left" -gt 0 ] || break
  if herdr pane wait-output "$pane" --match "$marker" --timeout $((left * 1000)) >/dev/null 2>&1; then ready=1; break; fi
done
if [ "$ready" != 1 ]; then
  printf '%s\n' "$out" >&2
  echo "ai-session: pane $pane shell still not ready after ${wait_s} s; left for inspection" >&2
  exit 1
fi
herdr pane run "$pane" "$(printf '%q run %q' "${launcher:-$ai}" "$manifest")" >/dev/null
echo "ai-session: pane $pane ready after $(( $(date +%s) - start )) s; ran manifest $manifest there" >&2
echo "$pane"
