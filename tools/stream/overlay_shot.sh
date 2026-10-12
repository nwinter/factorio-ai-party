#!/usr/bin/env bash
# A 1920x1080 (or --size WxH) screenshot of an overlay page with Playwright's headless Chromium:
#   tools/stream/overlay_shot.sh URL OUT.png [--size 1080x1920] [--wait-ms 9000]
# Before/after a layout change, against mock stream services (no game, no OBS; ?preview greys the camera holes):
#   python3 ~/code/player-of-games/tools/stream/serve.py --mock --port 8798 &   # before: main's checkout
#   python3 tools/stream/serve.py --mock --port 8799 &                         # after: this branch
#   tools/stream/overlay_shot.sh 'http://127.0.0.1:8798/?preview' before.png
#   tools/stream/overlay_shot.sh 'http://127.0.0.1:8799/?preview' after.png
#   tools/stream/overlay_shot.sh 'http://127.0.0.1:8799/portrait?preview' vertical.png --size 1080x1920
set -euo pipefail
url=${1:?usage: overlay_shot.sh URL OUT.png [--size WxH] [--wait-ms N]}
out=${2:?usage: overlay_shot.sh URL OUT.png [--size WxH] [--wait-ms N]}
shift 2
size=1920x1080 wait=9000
while [ $# -gt 0 ]; do
  case $1 in
    --size) size=$2; shift ;;
    --wait-ms) wait=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
shell=$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell \
  2>/dev/null | sort -V | tail -1)
[ -n "$shell" ] || { echo "no Playwright headless shell: npx playwright install chromium-headless-shell" >&2; exit 1; }
# --timeout, not --virtual-time-budget: the page's event stream keeps virtual time from ever running out
"$shell" --window-size="${size/x/,}" --hide-scrollbars --timeout="$wait" --screenshot="$out" "$url" \
  2>/dev/null
echo "$out"
