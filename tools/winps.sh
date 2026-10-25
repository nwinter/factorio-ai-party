#!/usr/bin/env bash
# Run a local PowerShell script on the Windows box: tools/winps.sh script.ps1 [args...]
set -euo pipefail
host=${POG_WIN_HOST:-pogwin}
# (d24 batch186) never the box from a test run
if [ "${POG_TEST:-0}" = 1 ]; then echo "POG_TEST=1: winps.sh does not reach $host in a test run" >&2; exit 3; fi
script=$1; shift
name="pog_$(date +%s)_$$_$(basename "$script")"
scp -q "$script" "$host:C:/Users/player/AppData/Local/Temp/$name" 2>/dev/null
ssh "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\player\\AppData\\Local\\Temp\\$name $*" 2>&1 \
  | { grep -v -E '^\*\* |post-quantum|openssh.com/pq.html' || true; } | tr -d '\000'
ssh "$host" "del C:\\Users\\player\\AppData\\Local\\Temp\\$name" >/dev/null 2>&1 || true
