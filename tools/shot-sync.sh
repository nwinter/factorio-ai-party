#!/usr/bin/env bash
# Mirror agent screenshots from the box into run workspaces: tools/shot-sync.sh RUN_DIR WORLD...
# Agents run sandboxed without SSH; ./shot requests a screenshot over RCON and waits for this to deliver it.
dir=$1; shift
while true; do
  for w in "$@"; do
    remote="D:\\pog\\inst\\$w-client\\script-output\\pog"
    files=$(ssh pogwin "if exist $remote\\*.png dir /b $remote\\*.png" 2>/dev/null | tr -d '\r')
    for f in $files; do
      scp -q "pogwin:D:/pog/inst/$w-client/script-output/pog/$f" "$dir/$w/shots/.incoming-$f" 2>/dev/null \
        && mv "$dir/$w/shots/.incoming-$f" "$dir/$w/shots/$f" \
        && ssh pogwin "del $remote\\$f" >/dev/null 2>&1
    done
  done
  sleep 1
done
