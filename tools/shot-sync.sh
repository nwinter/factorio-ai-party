#!/usr/bin/env bash
# Copy agent screenshots from the game box into run workspaces: tools/shot-sync.sh RUN_DIR CLIENT_DIR...
# CLIENT_DIR is a game client's folder under D:\pog\inst: an agent's own client (a-client) or, in team runs where
# agents are bots, the director clients (n-client-cam1 ...). ./shot asks for script-output\pog\WS\NAME.png; whichever
# client renders it, this moves it to RUN_DIR/WS/shots/NAME.png. Agents run sandboxed without SSH, so this runs on the
# operator machine; tools/start-team.sh starts it with its output in RUN_DIR/shot-sync.log.
# Logs a start line, each copy, and errors (shake3's log was empty: everything went to /dev/null). A listing error
# that repeats every second (the box unreachable) is logged when it changes and then once a minute.
dir=$1; shift
prev=""
last_err="" last_err_t=0
ts() { date +%H:%M:%S; }
note_err() {  # note_err KEY MESSAGE: log unless the same KEY was logged in the last 60 s
  local now_s; now_s=$(date +%s)
  if [ "$1" != "$last_err" ] || [ $((now_s - last_err_t)) -ge 60 ]; then
    echo "[shot-sync] $(ts) $2"
    last_err=$1 last_err_t=$now_s
  fi
}
echo "[shot-sync] $(ts) start: $dir <- $*"
while true; do
  now=""
  for cl in "$@"; do
    remote="D:\\pog\\inst\\$cl\\script-output\\pog"
    # cmd's dir exits 1 with "File Not Found" when there are no screenshots: that is an empty list, not an error
    if ! out=$(ssh pogwin "if exist $remote dir /b /s /a-d $remote\\*.png" 2>&1) && ! grep -qi "file not found" <<<"$out"; then
      note_err "list:$cl:$out" "listing $cl failed: $(tr -d '\r' <<<"$out" | tail -2 | tr '\n' ' ')"
      continue
    fi
    list=$(tr -d '\r' <<<"$out" | grep -i '\.png$')
    [ -n "$list" ] && now+="$list"$'\n'
  done
  # Factorio writes a screenshot after the tick that asked for it: copy only files already listed on the last pass.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    grep -qxF -- "$path" <<<"$prev" || continue
    rel=${path#*\\script-output\\pog\\}   # WS\NAME.png
    ws=${rel%%\\*} f=${rel#*\\}
    if [ "$ws" = "$rel" ] || [ ! -d "$dir/$ws/shots" ]; then
      note_err "skip:$path" "skipped $path: no workspace $dir/$ws/shots"
      continue
    fi
    if ! err=$(scp -q "pogwin:${path//\\//}" "$dir/$ws/shots/.incoming-$f" 2>&1); then
      note_err "scp:$path" "copy of $path failed: $(tr '\n' ' ' <<<"$err")"
      continue
    fi
    mv "$dir/$ws/shots/.incoming-$f" "$dir/$ws/shots/$f" || continue
    echo "[shot-sync] $(ts) copied $ws/shots/$f"
    if ! err=$(ssh pogwin "del \"$path\"" 2>&1); then
      note_err "del:$path" "copied but could not delete $path on the box: $(tr -d '\r' <<<"$err" | tr '\n' ' ')"
    fi
  done <<<"$now"
  prev=$now
  sleep 1
done
