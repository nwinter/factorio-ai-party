#!/usr/bin/env bash
# Explicit private 2.1 switch. The 2.0 launcher and baseline remain separate.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
export MT_DIR=/Users/owner/pog-mt21
export MT_FACTORIO_APP=/Users/owner/code/factorio-mac-2.1.24/factorio.app
export MT_EXPECT_VERSION=2.1.24 MT_RCON_PORT=27475 MT_GAME_PORT=34475
export MT_MODS_FILE="$root/agent/mt/mods-2.1.24.tsv"
export POG_KB=space-age-2.1.24
export POG_MT_TREE=${POG_MT_TREE:-/Users/owner/code/personal/player-of-games/worktrees/pog-p21}
export POG_MT_FRESH_SAVE=${POG_MT_FRESH_SAVE:-/Users/owner/code/personal/player-of-games/artifacts/port21-p3/mt-baseline21.zip}
if [ "${POG_MT_PUBLIC:-0}" != 0 ]; then
  echo 'Closed 2.1 wrapper refuses public staging; use the explicitly pinned general launcher in docs/PORT21.md.' >&2
  exit 64
fi
export POG_MT_PUBLIC=0 POG_MT_STREAM=0
case ${1:-status} in
  start) shift; exec "$root/tools/mt/start-mt.sh" "$@" ;;
  stop) shift; exec "$root/tools/mt/stop-mt.sh" "$@" ;;
  server) shift; exec "$root/tools/mt/imac_mt.sh" "$@" ;;
  status) exec "$root/tools/mt/imac_mt.sh" status ;;
  camera) shift; exec python3 "$root/tools/mt/imac_cam.py" "$@" ;;
  map) shift; exec python3 "$root/tools/mt/mt_map.py" "$@" ;;
  fh) shift; unset POG_FH_SOCKET FH_SOCKET; export POG_WORLD=imac2; exec "$root/bin/fh" "$@" ;;
  *) echo 'usage: tools/mt/port21.sh start|stop|status|server|camera|map|fh ...' >&2; exit 64 ;;
esac
