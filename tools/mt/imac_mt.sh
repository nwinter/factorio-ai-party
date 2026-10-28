#!/usr/bin/env bash
# (mt275, private) The multi-team server on the iMac, beside tools/imac-copy.sh's copy: its own folder, ports, password
# and write-data, this branch's mod folder (control.lua's on_chunk_charted needs the mod, not a hot deploy).
#   tools/mt/imac_mt.sh start SAVE.zip     (or imac:PATH) copy the save and the mod folder, start the server, wait for RCON
#   tools/mt/imac_mt.sh stop               /quit (saves over saves/mt.zip), then the server's own PID if still up
#   tools/mt/imac_mt.sh status
# Then: python3 tools/mt/mt_map.py ... --host imac.local --port 27475 --password-file ~/.config/pog/rcon-imac-mt.pw
# (mt277) world `imac2` for bin/fh, tools/pog.py and the broker: ~/.config/pog/rcon-imac2.pw, a link to the same password
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
host=${IMAC_HOST:-imac.local}
dir=${MT_DIR:-/Users/owner/pog-mt}
bin=/Users/owner/code/factorio-mac-2.0.77/factorio.app/Contents/MacOS/factorio
rcon_port=${MT_RCON_PORT:-27475} game_port=${MT_GAME_PORT:-34475}
pwfile=$HOME/.config/pog/rcon-imac-mt.pw
mod=$root/vendor/factorio-harness/mod/agent-harness_0.1.0
remote() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "$@"; }
ready() {
  python3 -c "
import sys; sys.path.insert(0, '$root/tools')
from pog import Rcon
r = Rcon('$host', $rcon_port, open('$pwfile').read().strip(), timeout=10)
print(r.command(\"/silent-command rcon.print('tick ' .. game.tick .. (game.tick_paused and ' (paused)' or ''))\"))"
}
case ${1:-status} in
start)
  save=${2:?usage: imac_mt.sh start SAVE.zip}
  if remote "[ -s '$dir/server.pid' ] && kill -0 \$(cat '$dir/server.pid') 2>/dev/null"; then echo "already running (pid $(remote "cat '$dir/server.pid'"))" >&2; exit 3; fi
  mkdir -p "$(dirname "$pwfile")"
  [ -s "$pwfile" ] || { python3 -c 'import secrets; print(secrets.token_hex(16))' > "$pwfile"; chmod 600 "$pwfile"; }
  [ -e "$(dirname "$pwfile")/rcon-imac2.pw" ] || ln -s "$(basename "$pwfile")" "$(dirname "$pwfile")/rcon-imac2.pw"
  remote "mkdir -p '$dir/saves' '$dir/mods' '$dir/config' '$dir/data/saves' '$dir/clients'"
  rsync -a --delete --exclude tests "$mod/" "$host:$dir/mods/agent-harness_0.1.0/"
  scp -q "$root/tools/imac-mod-list.json" "$host:$dir/mods/mod-list.json"
  printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s/data\n' "$dir" | remote "cat > '$dir/config/config.ini'"
  python3 -c 'import json; print(json.dumps({"name": "pog mt", "description": "tools/mt/imac_mt.sh", "visibility": {"public": False, "lan": False},
    "require_user_verification": False, "max_players": 0, "allow_commands": "admins-only", "autosave_interval": 0, "autosave_slots": 1,
    "auto_pause": False, "only_admins_can_pause_the_game": True, "autosave_only_on_server": True}))' | remote "cat > '$dir/server-settings.json'"
  case $save in
    imac:$dir/saves/mt.zip) ;;   # (mt277) the server's own save as its last /quit left it (tools/mt/start-mt.sh, POG_RESUME)
    imac:*) remote "cp '${save#imac:}' '$dir/saves/mt.zip'" ;;   # a save already on the iMac (mt_map.py seed-search)
    *) scp -q "$save" "$host:$dir/saves/mt.zip" ;;
  esac
  pw=$(cat "$pwfile")
  pid=$(remote "cd '$dir' && nohup '$bin' --config '$dir/config/config.ini' --start-server '$dir/saves/mt.zip' --mod-directory '$dir/mods' \
    --server-settings '$dir/server-settings.json' --rcon-bind 0.0.0.0:$rcon_port --rcon-password '$pw' --port $game_port \
    > '$dir/server.out' 2>&1 < /dev/null & echo \$!")
  echo "$pid" | remote "cat > '$dir/server.pid'"
  echo "started pid $pid on $host ($save); waiting for RCON $host:$rcon_port"
  for _ in $(seq 1 90); do
    if out=$(ready 2>/dev/null) && [ -n "$out" ]; then echo "up: $out"; exit 0; fi
    remote "kill -0 $pid 2>/dev/null" || { echo "the server exited:" >&2; remote "tail -20 '$dir/server.out'" >&2; exit 1; }
    sleep 2
  done
  echo "RCON did not answer in 180 s" >&2; exit 1
  ;;
stop)
  pid=$(remote "cat '$dir/server.pid' 2>/dev/null" || true)
  [ -n "$pid" ] || { echo "not running"; exit 0; }
  python3 -c "
import sys; sys.path.insert(0, '$root/tools')
from pog import Rcon
Rcon('$host', $rcon_port, open('$pwfile').read().strip(), timeout=10).command('/quit')" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do remote "kill -0 $pid 2>/dev/null" || break; sleep 1; done
  if remote "kill -0 $pid 2>/dev/null"; then remote "kill $pid"; sleep 2; fi   # its own PID only
  remote "rm -f '$dir/server.pid'"
  echo "stopped pid $pid"
  ;;
status)
  pid=$(remote "cat '$dir/server.pid' 2>/dev/null" || true)
  if [ -n "$pid" ] && remote "kill -0 $pid 2>/dev/null"; then echo "running pid $pid: $(ready 2>/dev/null || echo 'RCON does not answer')"; else echo "not running"; fi
  ;;
*) echo "usage: imac_mt.sh start SAVE.zip | stop | status" >&2; exit 64 ;;
esac
