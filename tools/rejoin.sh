#!/usr/bin/env bash
# Reconnect a dropped agent client: tools/rejoin.sh WORLD [SLOT PLAYER_NAME INDEX]
# Kills the stale client, restarts it, and keeps the (possibly turn-paused) world ticking until the player is back.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
world=$1 slot=${2:-} name=${3:-pog-$1} index=${4:-1}
case $world in live) game=34197 rcon=27015 ;; a) game=34201 rcon=27021 ;; b) game=34202 rcon=27022 ;; c) game=34203 rcon=27023 ;; *) echo "unknown world" >&2; exit 1 ;; esac
tmp=$(mktemp -t pogkill).ps1
cat > "$tmp" <<EOP
Get-CimInstance Win32_Process -Filter "Name like 'factorio%.exe'" | Where-Object { \$_.CommandLine -match 'inst\\\\$world-client$slot\\\\' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }
EOP
"$root/tools/winps.sh" "$tmp"; rm -f "$tmp"
"$root/tools/.venv/bin/python" "$root/tools/rejoin_tick.py" "$world" "$rcon" 240 "$index" & tick=$!
args=(-Name "$world" -GamePort "$game" -PlayerName "$name"); [ -n "$slot" ] && args+=(-Slot "$slot")
"$root/tools/winps.sh" "$root/tools/win/start-client.ps1" "${args[@]}" >/dev/null
wait $tick
