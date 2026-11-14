#!/usr/bin/env bash
# Private 2.1 laboratory. Never inherits the shared copy's paths or ports.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export IMAC_DIR=/Users/owner/pog-port21
export IMAC_FACTORIO_DIR=/Users/owner/code/factorio-mac-2.1.24
export IMAC_RCON_PORT=27478 IMAC_GAME_PORT=34478 IMAC_EXPECT_VERSION=2.1.24
export IMAC_MOD="$root/vendor/factorio-harness/mod/agent-harness_0.1.0"
export IMAC_MOD_LIST="$root/tools/imac-mod-list.json"
if [ "${1:-}" = fh ]; then
  shift
  unset POG_FH_SOCKET FH_SOCKET POG_BROKER FACTORIO_RCON_PASSWORD
  export POG_WORLD=port21 POG_RCON_HOST=${IMAC_HOST:-imac.local} POG_RCON_PORT=$IMAC_RCON_PORT
  export POG_RCON_PASSWORD_FILE="$HOME/.config/pog/rcon-imac.pw"
  export FH_DESCRIBE_CACHE="$root/.cache/port21-describe.json"
  exec "$root/bin/fh" "$@"
fi
# A save is always explicit. --fresh creates a new pinned-engine save in the private directory.
if [ "${1:-}" = start ] && [ "$#" -lt 3 ]; then
  echo 'usage: tools/port21-copy.sh start HOLDER SAVE.zip|imac:PATH|--fresh' >&2
  exit 64
fi
exec "$root/tools/imac-copy.sh" "$@"
