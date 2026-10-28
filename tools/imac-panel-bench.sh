#!/usr/bin/env bash
# One graphics benchmark of a save on the iMac's macOS client (d27 batch285 B: camera panels, GUI camera elements in
# cam1's client, against a second camera client). It opens a client window on the iMac's display: run it only when the
# operator says the iMac is free (Nick's own game closed), and not while another engineer times something there.
#
#   tools/imac-panel-bench.sh SAVE LABEL [OUT]
#     SAVE   a save on the iMac, e.g. /Users/owner/pog-copy/data/saves/b285x2-panels-2.zip (cameras.lua panels on
#            pog-cam1's screen; this client plays as pog-cam1)
#     LABEL  the run's name, e.g. 2-b; OUT (default ./panel-bench) gets OUT/LABEL/
#
# The client: `--benchmark-graphics` for BENCH_TICKS (1800) ticks, its own write-data in /Users/owner/pog-copy/bench
# (apart from Nick's ~/Library/Application Support/factorio), the camera clients' graphics (medium sprites, low video
# memory, no sound), v-sync off (Factorio still holds 60 fps by sleeping: a frame's cost is its time minus the sleep),
# `--output-perf-stats` per frame. The iMac's display draws at 2x, so BENCH_WINDOW (1440x810 points) gives cam1's
# 2880x1620 pixels; the log's `[Size] Window: ..., Drawable: ...` line is kept in summary.txt.
# Every second while it runs: its RSS and CPU, the GPU's free VRAM, the load, and every other Factorio process there
# (pid:CPU, list only). Then tools/panel_bench.py OUT/LABEL... gives the medians.
# `open -n -a` starts the client in the logged-in GUI session (an ssh session cannot reach the window server).
set -euo pipefail
save=${1:?usage: tools/imac-panel-bench.sh SAVE LABEL [OUT]} label=${2:?usage: tools/imac-panel-bench.sh SAVE LABEL [OUT]}
out=${3:-panel-bench}/$label
host=${IMAC_HOST:-imac.local}
app=${IMAC_FACTORIO_DIR:-/Users/owner/code/factorio-mac-2.0.77}/factorio.app
dir=/Users/owner/pog-copy/bench
ticks=${BENCH_TICKS:-1800} window=${BENCH_WINDOW:-1440x810}
mkdir -p "$out"
ssh "$host" "test -f '$save'" || { echo "no save $save on $host" >&2; exit 2; }
ssh "$host" "mkdir -p '$dir/config' '$dir/perf' && cat > '$dir/config/config.ini' <<EOF
[path]
read-data=__PATH__system-read-data__
write-data=$dir
[other]
check-updates=false
show-tips-and-tricks=false
[sound]
master-muted=true
music-volume=0
[graphics]
full-screen=false
graphics-quality=medium
video-memory-usage=low
texture-streaming=true
v-sync=false
EOF
printf '{\"service-username\": \"pog-cam1\"}' > '$dir/player-data.json'"
others() {
  ssh "$host" "ps -Ao pid=,pcpu=,args= | grep -i 'factorio.app/Contents/MacOS/factorio' | grep -v grep | grep -v 'pog-copy/bench/config'" |
    awk '{printf "%s:%s%% ", $1, $2} END {print ""}'
}
vram() { ssh "$host" "ioreg -r -d 1 -c IOAccelerator | grep -oE '\"vramFreeBytes\"=[0-9]+' | head -1 | cut -d= -f2"; }
ssh "$host" "pgrep -lf factorio" > "$out/procs-before.txt" || true
before=$(vram)
ssh "$host" "open -n -a '$app' --args --config '$dir/config/config.ini' --mod-directory /Users/owner/pog-copy/mods \
  --benchmark-graphics '$save' --benchmark-ticks $ticks --disable-audio --window-size $window \
  --output-perf-stats '$dir/perf/perf-$label-{tag}.csv'"
pid=""
for _ in $(seq 1 60); do
  pid=$(ssh "$host" "pgrep -f 'pog-copy/bench/config/config.ini' | head -1" || true)
  [ -n "$pid" ] && break
  sleep 1
done
[ -n "$pid" ] || { echo "no benchmark process after 60 s" >&2; exit 1; }
echo "t,rss_mb,vram_free_mb,cpu_pct,load1,others" > "$out/samples.csv"
t0=$(date +%s)
while ssh "$host" "kill -0 $pid 2>/dev/null"; do
  row=$(ssh "$host" "ps -o rss=,pcpu= -p $pid; ioreg -r -d 1 -c IOAccelerator | grep -oE '\"vramFreeBytes\"=[0-9]+' | head -1 | cut -d= -f2; sysctl -n vm.loadavg | awk '{print \$2}'" | tr '\n' ' ')
  read -r rss cpu free load _ <<< "$row" || true
  [ -n "${load:-}" ] && echo "$(( $(date +%s) - t0 )),$(( rss / 1024 )),$(( free / 1048576 )),$cpu,$load,$(others)" >> "$out/samples.csv"
  sleep 1
done
ssh "$host" "pgrep -lf factorio" > "$out/procs-after.txt" || true
echo "vram free before: $(( before / 1048576 )) MB" > "$out/summary.txt"
scp -q "$host:$dir/factorio-current.log" "$out/factorio.log"
scp -q "$host:$dir/perf/perf-$label-*.csv" "$out/" 2>/dev/null || echo "no perf stats file" >> "$out/summary.txt"
grep -E "\[Size\] Window|Display options" "$out/factorio.log" >> "$out/summary.txt" || echo "no window size line" >> "$out/summary.txt"
cat "$out/summary.txt"
