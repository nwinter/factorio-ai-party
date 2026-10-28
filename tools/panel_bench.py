#!/usr/bin/env python3
"""Summaries of tools/imac-panel-bench.sh runs (d27 batch285 B): python3 tools/panel_bench.py [--table] RUN_DIR...

Per run, over its frames after the first 60 (the map just loaded): the frame cost (cpu-frame minus Factorio's own
sleep, which holds 60 fps with v-sync off) median and p95, and the medians of update, prepare, cpu-render and draw
calls; from the second half of the samples (loading done): the client's RSS and the GPU's free VRAM; the drawable
size the log names; every other Factorio process's CPU (median and max).
"""
import csv, glob, os, re, statistics, sys

SKIP_FRAMES = 60


def med(xs):
    return round(statistics.median(xs), 3) if xs else None


def p95(xs):
    xs = sorted(xs)
    return round(xs[int(0.95 * (len(xs) - 1))], 3) if xs else None


def summary(d):
    perf = sorted(glob.glob(os.path.join(d, "perf-*.csv")))
    rows = list(csv.DictReader(open(perf[0])))[SKIP_FRAMES:] if perf else []
    col = lambda k: [float(r[k]) for r in rows if r.get(k) not in (None, "")]
    cost = [float(r["cpu-frame"]) - float(r["sleep"]) for r in rows]
    samples = list(csv.DictReader(open(os.path.join(d, "samples.csv"))))
    steady = samples[len(samples) // 2:]
    text = open(os.path.join(d, "summary.txt")).read()
    size = re.search(r"Drawable: (\d+x\d+)", text)
    before = re.search(r"vram free before: (\d+)", text)
    others = {}
    for r in samples:
        for m in re.finditer(r"(\d+):([\d.]+)%", r.get("others") or ""):
            others.setdefault(m.group(1), []).append(float(m.group(2)))
    return {"run": os.path.basename(os.path.normpath(d)), "frames": len(rows), "drawable": size.group(1) if size else None,
            "cost_ms": med(cost), "cost_p95": p95(cost), "update": med(col("update")), "prepare": med(col("prepare")),
            "cpu_render": med(col("cpu-render")), "draw_calls": med(col("draw-call-count")),
            "rss_mb": med([int(r["rss_mb"]) for r in steady]), "vram_free_mb": med([int(r["vram_free_mb"]) for r in steady]),
            "vram_free_before_mb": int(before.group(1)) if before else None,
            "others": {k: {"median": med(v), "max": max(v), "samples": len(v)} for k, v in others.items()}}


def table(sums):
    out = ["| Run | Drawable | Frame cost (p95) | prepare | update | cpu-render | Draw calls | RSS | VRAM free |",
           "|---|---|---|---|---|---|---|---|---|"]
    for s in sums:
        out.append(f"| {s['run']} | {s['drawable']} | {s['cost_ms']} ms ({s['cost_p95']}) | {s['prepare']} | {s['update']} | "
                   f"{s['cpu_render']} | {s['draw_calls']:g} | {s['rss_mb']:g} MB | {s['vram_free_mb']:g} MB |")
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    as_table = "--table" in args
    sums = [summary(d) for d in args if d != "--table"]
    if as_table:
        print(table(sums))
    else:
        for s in sums:
            print(s)


if __name__ == "__main__":
    main()
