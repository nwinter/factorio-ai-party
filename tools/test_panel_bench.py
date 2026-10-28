#!/usr/bin/env python3
"""The iMac panel benchmark (d27 batch285 B): python3 tools/test_panel_bench.py

1. tools/panel_bench.py: frame cost = cpu-frame minus sleep after the first 60 frames; RSS and VRAM from the second half
   of the samples; the drawable size from the log line; the other Factorio processes' CPU.
2. tools/imac-panel-bench.sh: cam1's pixels on the iMac's 2x display (1440x810 points), v-sync off, its own write-data,
   never Nick's data, and it stops nothing (no kill, pkill or killall).
No iMac: a run directory written here.
"""
import csv, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import panel_bench as P  # noqa: E402


def summary():
    d = os.path.join(tempfile.mkdtemp(), "2-b")
    os.makedirs(d)
    with open(os.path.join(d, "perf-2-b-.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["update", "prepare", "cpu-render", "sleep", "cpu-frame", "draw-call-count"])
        for i in range(160):
            loading = i < 60
            w.writerow([3.0, 9.9 if loading else 1.9, 0.6, 1.0 if loading else 9.6, 16.6, 426])
    with open(os.path.join(d, "samples.csv"), "w") as f:
        f.write("t,rss_mb,vram_free_mb,cpu_pct,load1,others\n")
        for t in range(10):
            f.write(f"{t},{900 if t < 5 else 4100},{9000 if t < 5 else 7861},80,6.1,4669:{10 + t}% \n")
    open(os.path.join(d, "summary.txt"), "w").write(
        "vram free before: 9385 MB\n   0.4   [Size] Window: 1440x810, Drawable: 2880x1620\n")
    s = P.summary(d)
    assert s["frames"] == 100 and s["cost_ms"] == 7.0 and s["prepare"] == 1.9 and s["draw_calls"] == 426, s
    assert s["rss_mb"] == 4100 and s["vram_free_mb"] == 7861 and s["vram_free_before_mb"] == 9385, s
    assert s["drawable"] == "2880x1620" and s["others"]["4669"] == {"median": 14.5, "max": 19.0, "samples": 10}, s
    assert "| 2-b | 2880x1620 | 7.0 ms (7.0) | 1.9 |" in P.table([s]), P.table([s])
    print("1. summary: frame cost, memory, drawable, other processes: ok")


def script():
    src = open(os.path.join(HERE, "imac-panel-bench.sh")).read()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    assert "window=${BENCH_WINDOW:-1440x810}" in code and "v-sync=false" in code
    assert "write-data=$dir" in code and "dir=/Users/owner/pog-copy/bench" in code
    assert "Application Support" not in code, "never Nick's Factorio data"
    for word in ("pkill", "killall", "kill -9", "kill $pid\"", "kill -TERM"):
        assert word not in code, word
    assert 'kill -0 $pid' in code  # only asks whether it still runs
    print("2. imac-panel-bench.sh: 2880x1620 px at 2x, v-sync off, its own data, stops nothing: ok")


def main():
    summary()
    script()
    print("test_panel_bench: ok")


if __name__ == "__main__":
    main()
