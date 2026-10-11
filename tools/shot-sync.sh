#!/usr/bin/env bash
# Copy agent screenshots from the game box into run workspaces: tools/shot-sync.sh RUN_DIR CLIENT_DIR...
# CLIENT_DIR is a game client's folder under D:\pog\inst: an agent's own client (a-client) or, in team runs where
# agents are bots, the director clients (n-client-cam1 ...). ./shot asks for script-output\pog\WS\NAME.png; whichever
# client renders it, this moves it to RUN_DIR/WS/shots/NAME.png. Agents run sandboxed without SSH, so this runs on the
# operator machine; tools/start-team.sh starts it.
dir=$1; shift
prev=""
while true; do
  now=""
  for cl in "$@"; do
    remote="D:\\pog\\inst\\$cl\\script-output\\pog"
    list=$(ssh pogwin "if exist $remote dir /b /s /a-d $remote\\*.png" 2>/dev/null | tr -d '\r')
    [ -n "$list" ] && now+="$list"$'\n'
  done
  # Factorio writes a screenshot after the tick that asked for it: copy only files already listed on the last pass.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    grep -qxF -- "$path" <<<"$prev" || continue
    rel=${path#*\\script-output\\pog\\}   # WS\NAME.png
    ws=${rel%%\\*} f=${rel#*\\}
    [ "$ws" != "$rel" ] && [ -d "$dir/$ws/shots" ] || continue
    scp -q "pogwin:${path//\\//}" "$dir/$ws/shots/.incoming-$f" 2>/dev/null \
      && mv "$dir/$ws/shots/.incoming-$f" "$dir/$ws/shots/$f" \
      && ssh pogwin "del \"$path\"" >/dev/null 2>&1
  done <<<"$now"
  prev=$now
  sleep 1
done
