#!/usr/bin/env python3
"""The base's map over time, for the site's time-lapse: one basemap snapshot per 10 game minutes in
runs/RUN/basemap/TICK.json (the coarse grid, the dense core and the nests; the ore grid is left out, it barely
changes). About 20 KB a snapshot, half a megabyte a 4-hour shift.

live.py calls save() after each basemap read (once a minute). For a stream service started before this file existed,
run the logger beside it; it polls the service's state.json and writes the same files (save() skips a snapshot
within 10 game minutes of the newest one, so both together write each once):

    python3 tools/stream/basemap_log.py runs/shift05 [--url http://127.0.0.1:8788/state.json] [--every 60]
"""
import argparse
import json
import os
import sys
import time
import urllib.request

DIR = "basemap"
EVERY_TICKS = 36000  # 10 game minutes
KEEP = ("tick", "cell", "x0", "y0", "w", "h", "rows", "core", "nests", "turrets")


def newest(run_dir):
    """The newest snapshot's tick in runs/RUN/basemap/ (None without one)."""
    try:
        ticks = [int(f[:-5]) for f in os.listdir(os.path.join(run_dir, DIR)) if f.endswith(".json") and f[:-5].isdigit()]
    except OSError:
        return None
    return max(ticks) if ticks else None


def save(run_dir, basemap, every=EVERY_TICKS):
    """Write basemap as runs/RUN/basemap/TICK.json when it is at least `every` ticks after the newest snapshot (or
    older than it: a world loaded from an earlier save). Returns the path written, or None."""
    if not run_dir or not isinstance(basemap, dict) or not basemap.get("rows"):
        return None
    tick = basemap.get("tick")
    if not isinstance(tick, int) or tick < 0:
        return None
    last = newest(run_dir)
    if last is not None and 0 <= tick - last < every:
        return None
    d = os.path.join(run_dir, DIR)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"{tick}.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({k: basemap[k] for k in KEEP if k in basemap}, f, separators=(",", ":"))
    os.replace(tmp, path)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--url", default="http://127.0.0.1:8788/state.json")
    ap.add_argument("--every", type=float, default=60, help="seconds between polls")
    ap.add_argument("--once", action="store_true", help="poll once and exit")
    a = ap.parse_args()
    if not os.path.isdir(a.run_dir):
        sys.exit(f"no run folder {a.run_dir}")
    while True:
        try:
            with urllib.request.urlopen(a.url, timeout=10) as r:
                state = json.load(r)
            state = state.get("state") or state
            p = save(a.run_dir, state.get("basemap"))
            if p:
                print(f"{time.strftime('%H:%M:%S')} basemap_log: {p}", flush=True)
        except Exception as e:  # the service restarting, a slow read: try again next poll
            print(f"{time.strftime('%H:%M:%S')} basemap_log: {e}", file=sys.stderr, flush=True)
        if a.once:
            return
        time.sleep(a.every)


if __name__ == "__main__":
    main()
