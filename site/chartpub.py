"""The chart under the live map (d22 batch97 BG3): the cells the stream service draws from the game
(tools/stream/chart.py, runs/RUN/chart/out/: SURFACE/CX_CY.png at 1 px a tile, CX_CY.labels.json, index.json),
published with the site under /live/chart/ by site/build.py (hourly and at each shift change), and between builds by
site/chart_deploy.py within about 6.5 minutes of a change (d26 batch241). site/push_live.py reads the deployed index's version into the state; static/live.js fetches the
index when it changes and static/mapview.js draws the cells under the overlays.

- source(runs_dir, long): the run whose chart is newest: the long run's shifts and the run going on now (one whose
  resumed-from names one of them), by its index.json's time; None without one;
- publish(out, runs_dir, long): copies that run's chart/out/ to out/live/chart/; returns its index ({} without one)."""
import json, shutil
from pathlib import Path

URL = "/live/chart/"


def source(runs_dir, long):
    runs = Path(runs_dir)
    ids = {s["id"] for s in (long or {}).get("shifts") or [] if s.get("id")}
    cands = set(ids)
    for d in runs.iterdir() if runs.is_dir() else []:
        try:
            up = (d / "resumed-from").read_text().split("\n")[0].strip()
        except OSError:
            continue
        if up in ids:
            cands.add(d.name)
    best = None
    for name in cands:
        idx = runs / name / "chart" / "out" / "index.json"
        if idx.is_file() and (best is None or idx.stat().st_mtime > best.stat().st_mtime):
            best = idx
    return best.parent if best else None


def publish(out, runs_dir, long):
    src = source(runs_dir, long)
    if not src:
        return {}
    try:
        index = json.loads((src / "index.json").read_text())
    except (OSError, ValueError):
        return {}
    d = Path(out) / "live" / "chart"
    if d.exists():
        shutil.rmtree(d)
    shutil.copytree(src, d, ignore=shutil.ignore_patterns("*.tmp"))
    return index
