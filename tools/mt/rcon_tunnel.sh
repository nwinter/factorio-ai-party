#!/usr/bin/env bash
# (mt309) Forward 127.0.0.1:PORT on this Mac to the iMac's RCON over ssh, restarting ssh if it drops.
#   tools/mt/rcon_tunnel.sh [PORT]      (default 27475, imac2); then IMAC_RCON_HOST=127.0.0.1 for tools/pog.py and the brokers
# Why: on chonk macOS Local Network privacy refused Python's own connections to imac.local from Nov 19 12:47
# ("No route to host") while Apple's ssh still connects. Loopback connections are not subject to it.
set -u
port=${1:-27475}
host=${IMAC_HOST:-imac.local}
while true; do
  /usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 -L "127.0.0.1:$port:127.0.0.1:$port" "$host"
  echo "$(date +%T) ssh tunnel exited ($?), restarting" >&2
  sleep 2
done
