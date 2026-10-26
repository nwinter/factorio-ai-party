#!/usr/bin/env python3
"""The chart published with the site (d22 batch97 BG3, site/chartpub.py): python3 site/test_chartpub.py

- the newest chart among the long run's shifts and the run going on now (one resuming from a shift), by its index's time;
- copied whole to out/live/chart/ (cells, labels, index; no .tmp), an older publish replaced; nothing without one;
- push_live: the deployed index's version into the state, the coarse grids the chart replaces taken out (Nauvis's
  rows, core, ore, ground and frames, with the core's box kept; a charted planet's coarse map), the bytes saved said.
"""
import json, os, sys, tempfile, time
from pathlib import Path

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import chartpub  # noqa: E402
import push_live  # noqa: E402


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:1500]))
    if not ok:
        sys.exit(1)


def chart(run, v, t):
    d = run / "chart" / "out"
    (d / "nauvis").mkdir(parents=True)
    (d / "nauvis" / "0_0.png").write_bytes(b"png" + str(v).encode())
    (d / "nauvis" / "0_0.labels.json").write_text('{"recipes":[],"stops":[]}')
    (d / "nauvis" / "0_0.png.tmp").write_bytes(b"half")
    (d / "index.json").write_text(json.dumps({"v": v, "tick": 100, "surfaces": {"nauvis": {"cells": {"0,0": [v, 1, 2, 3]}}}}))
    os.utime(d / "index.json", (t, t))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runs, out = Path(tmp) / "runs", Path(tmp) / "out"
        for n in ("s1", "s2", "now", "other"):
            (runs / n).mkdir(parents=True)
        (runs / "now" / "resumed-from").write_text("s2\n")
        long = {"shifts": [{"id": "s1"}, {"id": "s2"}]}
        check("no chart anywhere: nothing published", chartpub.publish(out, runs, long) == {} and not (out / "live" / "chart").exists())
        t = time.time()
        chart(runs / "s1", 5, t - 300)
        chart(runs / "now", 9, t - 100)
        chart(runs / "other", 99, t)  # another world's run: not ours
        check("the newest of the long run's shifts and the run going on now", chartpub.source(runs, long) == runs / "now" / "chart" / "out",
              chartpub.source(runs, long))
        idx = chartpub.publish(out, runs, long)
        d = out / "live" / "chart"
        check("copied whole: cells, labels, index", idx.get("v") == 9 and (d / "nauvis" / "0_0.png").read_bytes() == b"png9"
              and (d / "nauvis" / "0_0.labels.json").is_file() and json.loads((d / "index.json").read_text())["v"] == 9, idx)
        check("no half-written files", not (d / "nauvis" / "0_0.png.tmp").exists())
        (d / "nauvis" / "stale.png").write_bytes(b"old")
        chartpub.publish(out, runs, long)
        check("a publish replaces the last one", not (d / "nauvis" / "stale.png").exists())
    # push_live: the version from the deployed index, the grids the chart replaces left out
    class R:
        def __init__(self, body): self.body = body
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self, *a): return self.body
    body = json.dumps({"v": 42, "tick": 777, "surfaces": {"nauvis": {"cells": {"0,0": [1, 2, 3, 4]}, "chunks": [9, 9], "complete": True},
                                                         "gleba": {"cells": {"1,1": [2, 2, 3, 4]}, "chunks": [4, 4], "complete": True},
                                                         "fulgora": {"cells": {"0,0": [3, 2, 3, 4]}, "chunks": [6, 600], "complete": False},
                                                         "vulcanus": {"cells": {}}}}).encode()
    push_live._chart.update(t=None, v=None)
    c = push_live.site_chart("https://example.test", now=1000, opener=lambda req, timeout: R(body))
    check("push_live reads the deployed index: its version, tick, the surfaces with cells, those complete",
          c == {"v": 42, "tick": 777, "surfaces": ["fulgora", "gleba", "nauvis"], "complete": ["gleba", "nauvis"]}, c)
    def boom(req, timeout):
        raise OSError("down")
    seen = []
    def counted(req, timeout):
        seen.append(req.full_url)
        return R(body)
    push_live.site_chart("https://example.test", now=1030, opener=counted)
    push_live.site_chart("https://example.test", now=1061, opener=counted)
    check("(batch241) read again after a minute, not before (it was 5 minutes: the site's map 5 more minutes behind)",
          seen == ["https://example.test/live/chart/index.json"], seen)
    check("the last one kept when a read fails",
          push_live.site_chart("https://example.test", now=1200, opener=boom) == c and "down" in push_live._chart["error"])
    state = {"basemap": {"tick": 5, "cell": 16, "x0": 0, "y0": 0, "w": 2, "h": 2, "rows": ["AA", "SS"] * 50, "nests": [[1, 2, "s"]],
                         "turrets": [[1, 1, 18]], "core": {"cell": 2, "x0": -10, "y0": -20, "w": 30, "h": 40, "rows": ["A" * 30] * 40},
                         "ore": {"cell": 16, "rows": ["ii"]}, "terrain_grid": {"rows": ["aa"] * 100}, "terrain": [{"src": "/live/terrain/x.webp"}]},
             "planet_map": {"surface": "gleba", "rows": ["A" * 40] * 40}, "planet_maps": {"gleba": {"rows": ["A"]}, "fulgora": {"rows": ["A"]}},
             "planets": [{"surface": "gleba"}, {"surface": "fulgora"}]}
    out = push_live.with_chart(json.loads(json.dumps(state)), c)
    bm = out["basemap"]
    check("Nauvis charted: rows, core, ore, ground and frames left out; nests, turrets and the core's box kept",
          not ({"rows", "core", "ore", "terrain_grid", "terrain"} & set(bm)) and bm["nests"] and bm["turrets"] and bm["core_box"] == [-10, -20, 50, 60], bm)
    check("a complete planet's coarse map left out, a partly charted one kept, the listing kept", "planet_map" not in out
          and out["planet_maps"] == {"fulgora": {"rows": ["A"]}} and out["planets"], out.get("planet_maps"))
    check("the state says the chart's version and the bytes saved", out["chart"]["v"] == 42 and out["chart"]["saved"] > 3000, out["chart"])
    # (cp7) the 21:11 publication: six Nauvis cells, no `complete` in its index: every grid kept
    push_live._chart.update(t=None, v=None)
    partial = json.dumps({"v": 65, "tick": 9, "surfaces": {"nauvis": {"cells": {"0,0": [1, 2, 3, 4]}}, "gleba": {"cells": {"1,1": [2, 2, 3, 4]}},
                                                          "fulgora": {"cells": {"0,0": [3, 2, 3, 4]}, "chunks": [6, 600], "complete": False}}}).encode()
    c2 = push_live.site_chart("https://example.test", now=5000, opener=lambda req, timeout: R(partial))
    out = push_live.with_chart(json.loads(json.dumps(state)), c2)
    check("a chart not yet complete (or an index without `complete`): every grid kept, the chart's version sent",
          c2["complete"] == [] and out["basemap"] == state["basemap"] and out["planet_map"] == state["planet_map"]
          and out["planet_maps"] == state["planet_maps"] and out["chart"]["v"] == 65 and out["chart"]["saved"] == 0, out.get("chart"))
    check("no chart published: the state as it was", push_live.with_chart(json.loads(json.dumps(state)), None) == state)
    print("chartpub: ok (the newest chart published under /live/chart/, its version pushed, the grids it replaces left out)")


if __name__ == "__main__":
    main()
