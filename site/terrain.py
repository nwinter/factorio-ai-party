"""Terrain under the site's maps: the georeferenced base-map frames (tools/stream/mapframes.py, runs/RUN/mapframes/
AREA.webp + AREA.json), in the shape the map viewer (static/mapview.js) reads:

    {"src": "/live/terrain/shift06--1_-1-4633539.webp", "x0": -641.5, "y0": -544.5, "x1": 928.6, "y1": 553.4,
     "tick": 4633539, "w": 2048, "h": 1432, "t": 1792433272}  (t: the capture's wall time, when the frame has one)

pixel (0,0) is tile (x0,y0) and pixel (w,h) tile (x1,y1); older frames first, so the newest is drawn on top.

- terrain_frames(runs_dir, long): the newest frame per area over the run's shifts (Nauvis), for the time-lapse
  (timelapse.data(), the viewer's owner calls it) and the live map;
- publish(out, runs_dir, long): site/build.py's step: the images in out/live/terrain/ and out/live/terrain/index.json
  {"terrain": [...]}; site/push_live.py reads that index from the deployed site into the live state's basemap.terrain
  (a new frame shows on the live map once a site deploy has it)."""
import json, shutil
from pathlib import Path

URL = "/live/terrain/"
MAX_LIVE = 16  # the live state carries at most this many (the newest)


def _rows(long, runs_dir):
    best = {}
    for s in long["shifts"]:
        d = Path(runs_dir) / s["id"] / "mapframes"
        if not d.is_dir():
            continue
        for jp in sorted(d.glob("*.json")):
            img = jp.with_suffix(".webp")
            try:
                meta = json.loads(jp.read_text())
            except (OSError, ValueError):
                continue
            box, px = meta.get("box"), meta.get("px")
            if not img.is_file() or (meta.get("surface") or "nauvis") != "nauvis":
                continue
            if not (isinstance(box, list) and len(box) == 4 and all(isinstance(v, (int, float)) for v in box)) or box[2] <= 0 or box[3] <= 0:
                continue
            if not (isinstance(px, list) and len(px) == 2 and all(isinstance(v, int) and v > 0 for v in px)):
                continue
            key = meta.get("area") or jp.stem
            old = best.get(key)
            if old is None or (meta.get("tick") or 0) >= (old["meta"].get("tick") or 0):
                best[key] = {"name": f"{s['id']}-{jp.stem}-{meta.get('tick') or 0}.webp", "image": img, "meta": meta}
    return sorted(best.values(), key=lambda r: r["meta"].get("tick") or 0)


def _entry(r):
    m = r["meta"]
    x, y, w, h = m["box"]
    out = {"src": URL + r["name"], "x0": x, "y0": y, "x1": round(x + w, 1), "y1": round(y + h, 1), "tick": m.get("tick"),
           "w": m["px"][0], "h": m["px"][1]}
    if isinstance(m.get("t"), (int, float)):  # (d19 batch42 B3) when it was captured, wall time: the map's legend says so
        out["t"] = int(m["t"])
    return out


def terrain_frames(runs_dir, long):
    """[{src, x0, y0, x1, y1, tick, w, h}], the newest frame per area, oldest first ([] without frames)."""
    return [_entry(r) for r in _rows(long, runs_dir)]


def publish(out, runs_dir, long):
    """Copy the frames to out/live/terrain/ (a new frame is a new name: no stale cache) and write its index.json;
    returns the entries ([] and nothing written without frames)."""
    rows = _rows(long, runs_dir)
    if not rows:
        return []
    d = Path(out) / "live" / "terrain"
    d.mkdir(parents=True, exist_ok=True)
    for r in rows:
        shutil.copy(r["image"], d / r["name"])
    entries = [_entry(r) for r in rows]
    (d / "index.json").write_text(json.dumps({"terrain": entries}, separators=(",", ":")))
    return entries


def live(index):
    """The live state's basemap.terrain from a published index.json: the newest MAX_LIVE, oldest first."""
    rows = [e for e in (index or {}).get("terrain") or [] if isinstance(e, dict) and str(e.get("src", "")).startswith(URL)
            and all(isinstance(e.get(k), (int, float)) for k in ("x0", "y0", "x1", "y1", "w", "h"))]
    rows.sort(key=lambda e: e.get("tick") or 0)
    return rows[-MAX_LIVE:]
