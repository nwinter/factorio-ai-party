#!/usr/bin/env bash
# Run a local PowerShell script on the Windows box: tools/winps.sh script.ps1 [args...]
set -euo pipefail
host=${POG_WIN_HOST:-pogwin}
script=$1; shift
name="pog_$(date +%s)_$$_$(basename "$script")"
scp -q "$script" "$host:C:/Users/player/AppData/Local/Temp/$name" 2>/dev/null
ssh "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\player\\AppData\\Local\\Temp\\$name $*" 2>&1 \
  | { grep -v -E '^\*\* |post-quantum|openssh.com/pq.html' || true; } | tr -d '\000'
ssh "$host" "del C:\\Users\\player\\AppData\\Local\\Temp\\$name" >/dev/null 2>&1 || true
