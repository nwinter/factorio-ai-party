#!/usr/bin/env bash
# Standalone, self-restarting SSH tunnel to the game box: tools/tunnel.sh PORT...
# (ControlPath=none so it never rides the shared ControlMaster, whose forwards vanish when it times out.)
args=()
for p in "$@"; do args+=(-L "$p:127.0.0.1:$p"); done
while true; do
  ssh -N -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 "${args[@]}" pogwin 2>/dev/null
  sleep 3
done
