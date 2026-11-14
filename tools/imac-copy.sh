#!/usr/bin/env bash
# A private copy of world n on the iMac (d27 batch279 IM; Nick booted it for us at 12:05): Factorio 2.0.77's macOS
# binary runs natively there as a headless server (--start-server), with RCON on a LAN port, so timings need no
# scaling for OrbStack's x86 emulation on this Mac. One copy per machine; holder.json says which engineer holds it.
#
#   tools/imac-copy.sh start HOLDER [SAVE.zip]   world n's newest save from pogwin (or SAVE.zip on this Mac, or
#                                                imac:PATH on the iMac), this checkout's harness mod, then the
#                                                server; refused while another holder runs it. /quit saves over the
#                                                copy's saves/copy.zip; the reference save for copy_bench comparisons
#                                                is imac:/Users/owner/pog-copy/ref/world-n-d27-1211.zip
#   tools/imac-copy.sh stop HOLDER [--force]     /quit, then the server's own PID if it is still up; frees the copy
#   tools/imac-copy.sh status                    who holds it, since when, the save, whether it answers (tick, paused)
#   tools/imac-copy.sh log [N]                   the server log's last N lines (default 200; 0: the whole log)
# IMAC_FACTORIO_DIR, IMAC_MOD (the agent-harness folder to serve), IMAC_MOD_LIST, IMAC_RCON_PORT and IMAC_GAME_PORT
# override defaults. Custom ports also apply to readiness, status and stop commands.
#
# Then the usual tools take world `imac` (bin/fh and tools/pog.py: imac.local:27400, ~/.config/pog/rcon-imac.pw):
#   POG_WORLD=imac FH_DESCRIBE_CACHE=$SCRATCH/.desc-imac.json bin/fh deploy          this checkout's runtime
#   POG_WORLD=imac bin/fh --bot astra call status                                    an action as a bot
#   python3 tools/pog.py --world imac resume                                         a shift save loads paused
#   python3 tools/pog.py --world imac rcon "/silent-command rcon.print(remote.call('agent_harness','profile_ticks',{seconds=60}))"
#   tools/imac-copy.sh log 0 > profile.log && python3 tools/profile_log.py profile.log
# The iMac has no node and no working python3 (the Xcode stub): every tool runs on this Mac and reaches the copy by
# RCON over the LAN. Only the server runs there. Nothing here touches world n beyond copying a save file from pogwin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
host=${IMAC_HOST:-imac.local}
dir=${IMAC_DIR:-/Users/owner/pog-copy}                       # on the iMac
install=${IMAC_FACTORIO_DIR:-/Users/owner/code/factorio-mac-2.0.77}  # the macOS client install (mt274, d27)
rcon_port=${IMAC_RCON_PORT:-27400} game_port=${IMAC_GAME_PORT:-34400}
pwfile=$HOME/.config/pog/rcon-imac.pw
mod=${IMAC_MOD:-$root/vendor/factorio-harness/mod/agent-harness_0.1.0}   # another branch's mod folder, e.g. mt274's
expected=${IMAC_EXPECT_VERSION:-}
cmd=${1:-status}; shift || true

remote() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "$@"; }
holder_json() { remote "cat '$dir/holder.json' 2>/dev/null" || true; }
field() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get(sys.argv[1]) or "")' "$1"; }
alive() { [ -n "$1" ] && remote "kill -0 $1 2>/dev/null"; }
rcon() { POG_RCON_HOST="$host" python3 "$root/tools/pog.py" --world imac --port "$rcon_port" rcon "$1"; }
endpoint_matches() {
  [ "$(echo "$1" | field rcon)" = "$host:$rcon_port" ] || {
    echo 'refused: holder RCON endpoint differs from this invocation' >&2; exit 3;
  }
}

binary() {
  # The server binary inside the install: factorio.app/Contents/MacOS/factorio (or a bin/ layout). No globs: the
  # iMac's login shell is zsh, which fails the whole command on a glob that matches nothing
  remote "for f in '$install'/factorio.app/Contents/MacOS/factorio '$install'/Factorio.app/Contents/MacOS/factorio '$install'/bin/x64/factorio; do [ -x \"\$f\" ] && { echo \"\$f\"; exit 0; }; done; exit 1" ||
    { echo "no Factorio binary under $host:$install (the macOS 2.0.77 install, d27 mt274); set IMAC_FACTORIO_DIR" >&2; exit 2; }
}

case $cmd in
status)
  h=$(holder_json)
  if [ -z "$h" ]; then echo "free: no copy running on $host"; exit 0; fi
  pid=$(echo "$h" | field pid)
  endpoint_matches "$h"
  echo "held by $(echo "$h" | field holder) since $(echo "$h" | field started) (save $(echo "$h" | field save); pid $pid $(alive "$pid" && echo running || echo 'not running'))"
  rcon "/silent-command rcon.print('tick ' .. game.tick .. (game.tick_paused and ' (paused)' or ''))" 2>/dev/null || echo "RCON $host:$rcon_port does not answer"
  ;;
start)
  who=${1:?usage: tools/imac-copy.sh start HOLDER [SAVE.zip] (HOLDER: your engineer name, e.g. d20-b205/batch279)}
  save=${2:-}
  # Serialize starts before inspecting the holder or copying any data.
  remote "mkdir -p '$dir'; mkdir '$dir/launch.lock'" || { echo 'another launch is in progress' >&2; exit 3; }
  tmp=
  trap 'remote "rmdir '\''$dir/launch.lock'\''" >/dev/null 2>&1 || true; [ -z "$tmp" ] || rm -rf "$tmp"' EXIT
  h=$(holder_json)
  if [ -n "$h" ]; then
    pid=$(echo "$h" | field pid)
    if alive "$pid"; then echo "refused: $host's copy is held by $(echo "$h" | field holder) since $(echo "$h" | field started) (pid $pid); one copy at a time per machine" >&2; exit 3; fi
    echo "a stale holder.json ($(echo "$h" | field holder), pid $pid not running) is replaced"
  fi
  bin=$(binary)
  if [ -n "$expected" ]; then
    remote "if lsof -nP -iTCP:$rcon_port -sTCP:LISTEN -t >/dev/null 2>&1 || lsof -nP -iUDP:$game_port -t >/dev/null 2>&1; then echo 'private port already occupied' >&2; exit 3; fi"
    # Check the complete signed bundle without executing it (a partial copy can open a macOS dialog).
    remote "codesign --verify --deep --strict '$install/factorio.app'"
    actual=$(remote "cat '$install/factorio.app/Contents/data/base/info.json'" | field version)
    [ "$actual" = "$expected" ] || { echo "expected Factorio $expected, installed $actual" >&2; exit 2; }
    python3 - "$mod/info.json" "$expected" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
assert info['factorio_version'] == '.'.join(sys.argv[2].split('.')[:2]), 'harness engine version mismatch'
assert 'base >= ' + sys.argv[2] in info['dependencies'], 'harness base pin mismatch'
PY
  fi
  mkdir -p "$(dirname "$pwfile")"
  [ -s "$pwfile" ] || { python3 -c 'import secrets; print(secrets.token_hex(16))' > "$pwfile"; chmod 600 "$pwfile"; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/imac-copy.XXXXXX")
  if [ -z "$save" ]; then
    # world n's newest save (shift saves and autosaves), copied from pogwin: read only for world n
    name=$(ssh -o ConnectTimeout=15 pogwin 'dir /b /o-d D:\pog\inst\n\saves\*.zip' | tr -d '\r' | head -1)
    [ -n "$name" ] || { echo "no save of world n listed on pogwin" >&2; exit 2; }
    scp -q "pogwin:D:/pog/inst/n/saves/$name" "$tmp/copy.zip"
    save_label="world n $name"
  else
    case $save in
      --fresh) save_label="fresh ${expected:-engine default}" ;;
      imac:*) save_label=$save ;;   # a save already on the iMac, e.g. imac:/Users/owner/pog-copy/ref/world-n-d27-1211.zip
      *) cp "$save" "$tmp/copy.zip"; save_label=$save ;;
    esac
  fi
  cat > "$tmp/config.ini" <<EOF
; tools/imac-copy.sh: the copy's own write-data, apart from any Factorio client of the iMac's user
[path]
read-data=__PATH__system-read-data__
write-data=$dir/data
EOF
  python3 - "$tmp/server-settings.json" <<'EOF'
import json, sys
json.dump({"name": "pog private copy", "description": "tools/imac-copy.sh", "visibility": {"public": False, "lan": False},
           "require_user_verification": False, "max_players": 0, "allow_commands": "admins-only",
           "autosave_interval": 0, "autosave_slots": 1, "auto_pause": False, "only_admins_can_pause_the_game": True,
           "autosave_only_on_server": True}, open(sys.argv[1], "w"), indent=1)
EOF
  cp "${IMAC_MOD_LIST:-$root/tools/imac-mod-list.json}" "$tmp/mod-list.json"
  remote "mkdir -p '$dir/saves' '$dir/mods' '$dir/config' '$dir/data/saves'"
  rsync -a --delete "$mod/" "$host:$dir/mods/agent-harness_0.1.0/"
  scp -q "$tmp/mod-list.json" "$host:$dir/mods/mod-list.json"
  scp -q "$tmp/config.ini" "$host:$dir/config/config.ini"
  scp -q "$tmp/server-settings.json" "$host:$dir/server-settings.json"
  case $save in
    --fresh)
      # A unique output preserves every earlier migrated/fresh save. Only this new file becomes copy.zip.
      fresh="$dir/saves/fresh-$(date +%Y%m%d-%H%M%S)-$$.zip"
      create_pid=$(remote "nohup '$bin' --config '$dir/config/config.ini' --mod-directory '$dir/mods' --create '$fresh' > '$dir/create.out' 2>&1 < /dev/null & echo \$!")
      for attempt in $(seq 1 90); do
        alive "$create_pid" || break
        if [ "$attempt" -ge 6 ] && ! remote "test -s '$dir/create.out'"; then
          remote "kill $create_pid"; echo 'no Factorio create output after 10 s' >&2; exit 1
        fi
        sleep 2
      done
      if alive "$create_pid"; then remote "kill $create_pid"; echo 'fresh save creation timed out' >&2; exit 1; fi
      remote "test -s '$fresh' && cp '$fresh' '$dir/saves/copy.zip'" ;;
    imac:*) remote "cp '${save#imac:}' '$dir/saves/copy.zip'" ;;
    *) scp -q "$tmp/copy.zip" "$host:$dir/saves/copy.zip" ;;
  esac
  pw=$(cat "$pwfile")
  pid=$(remote "cd '$dir' && nohup '$bin' --config '$dir/config/config.ini' --start-server '$dir/saves/copy.zip' --mod-directory '$dir/mods' \
    --server-settings '$dir/server-settings.json' --rcon-bind 0.0.0.0:$rcon_port --rcon-password '$pw' --port $game_port \
    > '$dir/server.out' 2>&1 < /dev/null & echo \$!")
  started=$(date '+%Y-%m-%d %H:%M:%S %Z')
  python3 -c 'import json,sys; print(json.dumps({"holder": sys.argv[1], "started": sys.argv[2], "pid": int(sys.argv[3]), "save": sys.argv[4], "checkout": sys.argv[5], "rcon": sys.argv[6]}))' \
    "$who" "$started" "$pid" "$save_label" "$root" "$host:$rcon_port" | remote "cat > '$dir/holder.json'"
  echo "started pid $pid on $host ($save_label), held by $who; waiting for RCON $host:$rcon_port"
  for attempt in $(seq 1 90); do
    if out=$(rcon "/silent-command rcon.print('tick ' .. game.tick .. (game.tick_paused and ' (paused)' or ''))" 2>/dev/null) && [[ "$out" == tick\ * ]]; then
      if [ -n "$expected" ]; then
        check=$(rcon "/silent-command rcon.print(helpers.table_to_json({base=script.active_mods.base,harness=script.active_mods['agent-harness'],recycler=script.active_mods.recycler,interface=remote.interfaces.agent_harness~=nil}))")
        if ! remote "head -n 5 '$dir/server.out' | grep -F 'Factorio $expected (' >/dev/null" ||
           ! python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["base"]==sys.argv[2] and d.get("harness") and d.get("recycler") and d.get("interface")' "$check" "$expected"; then
          echo 'engine/harness readiness check failed; stopping this launch' >&2
          remote "kill $pid; rm -f '$dir/holder.json'"; exit 1
        fi
      fi
      echo "up: $out"; exit 0
    fi
    alive "$pid" || { echo "the server exited; its output:" >&2; remote "tail -30 '$dir/server.out'" >&2; remote "rm -f '$dir/holder.json'"; exit 1; }
    # macOS can hold exec at dyld while a Gatekeeper dialog waits on the user's desktop. Factorio normally writes
    # its first log line immediately. Never leave such a launch waiting for the user to dismiss a dialog.
    if [ "$attempt" -ge 6 ] && ! remote "test -s '$dir/server.out'"; then
      echo "no Factorio startup output after 10 s; stopping this launch (check macOS Gatekeeper logs)" >&2
      remote "kill $pid; rm -f '$dir/holder.json'"
      exit 1
    fi
    sleep 2
  done
  echo "RCON did not answer in 180 s; stopping this launch; tools/imac-copy.sh log 50" >&2
  remote "kill $pid; rm -f '$dir/holder.json'"
  exit 1
  ;;
stop)
  who=${1:?usage: tools/imac-copy.sh stop HOLDER [--force]}
  h=$(holder_json)
  [ -n "$h" ] || { echo "free: nothing to stop"; exit 0; }
  held=$(echo "$h" | field holder) pid=$(echo "$h" | field pid)
  if [ "$held" != "$who" ] && [ "${2:-}" != --force ]; then echo "refused: held by $held, not $who (--force only for a copy its holder left)" >&2; exit 3; fi
  endpoint_matches "$h"
  if ! alive "$pid"; then
    remote "rm -f '$dir/holder.json'"
    echo 'stale holder cleared; no RCON command or signal sent'; exit 0
  fi
  remote "ps -p $pid -o command= | grep -F -- ' --config $dir/config/config.ini ' >/dev/null" || {
    echo 'refused: holder PID no longer identifies this private server' >&2; exit 3;
  }
  rcon "/quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do alive "$pid" || break; sleep 1; done
  if alive "$pid"; then remote "kill $pid"; sleep 2; fi   # its own PID only (never by pattern)
  remote "rm -f '$dir/holder.json'"
  echo "stopped: pid $pid on $host; free"
  ;;
log)
  n=${1:-200}
  if [ "$n" = 0 ]; then remote "cat '$dir/data/factorio-current.log'"; else remote "tail -n $n '$dir/data/factorio-current.log'"; fi
  ;;
*) echo "usage: tools/imac-copy.sh start HOLDER [SAVE.zip] | stop HOLDER [--force] | status | log [N]" >&2; exit 64 ;;
esac
