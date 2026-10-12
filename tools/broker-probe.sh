#!/usr/bin/env bash
# Broker probe (tools/smoke-launch.sh with POG_BROKER=1): through OWN's socket, a request for OWN goes through and
# one for OTHER is refused.
#   tools/broker-probe.sh SOCKET_DIR OWN OTHER
# POG_FH: the fh to run (default bin/fh; tests pass a stub).
# fh's output is captured before it is read: a refused request exits nonzero, and under pipefail `fh | grep -q`
# then failed even when grep matched (smoke-br printed "NOT refused" while broker.log had the refusal).
set -uo pipefail
dir=$1 own=$2 other=$3
fh=${POG_FH:-bin/fh}
if POG_FH_SOCKET="$dir/$own.sock" "$fh" --bot "$own" call status >/dev/null 2>&1; then
  echo "broker probe: own bot ok"
else
  echo "broker probe: own bot FAILED"
fi
out=$(POG_FH_SOCKET="$dir/$own.sock" "$fh" --bot "$other" call status 2>&1) && code=0 || code=$?
case $out in
  *"this socket acts for bot $own"*) echo "broker probe: other bot refused" ;;
  *) echo "broker probe: other bot NOT refused (exit $code): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;;
esac
