#!/usr/bin/env bash
# Mirror agent screenshots from the box into run workspaces: tools/shot-sync.sh RUN_DIR WS[=CLIENT_DIR]...
# WS is the workspace under RUN_DIR; CLIENT_DIR is the client's folder under D:\pog\inst (default WS-client).
# Agents run sandboxed without SSH; ./shot requests a screenshot over RCON and waits for this to deliver it.
dir=$1; shift
while true; do
  for spec in "$@"; do
    ws=${spec%%=*}; cl=${spec#*=}; [ "$cl" = "$spec" ] && cl="$ws-client"
    remote="D:\\pog\\inst\\$cl\\script-output\\pog"
    files=$(ssh pogwin "if exist $remote\\*.png dir /b $remote\\*.png" 2>/dev/null | tr -d '\r')
    for f in $files; do
      scp -q "pogwin:D:/pog/inst/$cl/script-output/pog/$f" "$dir/$ws/shots/.incoming-$f" 2>/dev/null \
        && mv "$dir/$ws/shots/.incoming-$f" "$dir/$ws/shots/$f" \
        && ssh pogwin "del $remote\\$f" >/dev/null 2>&1
    done
  done
  sleep 1
done
