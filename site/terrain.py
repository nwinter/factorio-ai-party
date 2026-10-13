"""Terrain under the site's maps: the georeferenced base-map frames (tools/stream/mapframes.py, runs/RUN/mapframes/
AREA.webp + AREA.json) published as /terrain/index.json and /terrain/*.webp. For site/build.py, which calls publish();
the map viewers draw them with static/terrain.js (PogTerrain), the newest frame per area under the buildings.

index.json: {"frames": [{src, x, y, w, h (tiles: the image's top-left corner and size), tick, shift, surface, px}]},
oldest first, so a viewer that draws them in order has the newest on top. A frame is the newest of its area across the
run's shifts; a viewer showing an earlier moment (the time-lapse) picks the newest at or before that tick."""
import json, shutil
from pathlib import Path


def frames(long, runs_dir):
    """The newest frame per area over the run's shifts: [{area, shift, n, image (Path), meta}] by tick."""
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
            box = meta.get("box")
            if not img.is_file() or not (isinstance(box, list) and len(box) == 4 and all(isinstance(v, (int, float)) for v in box)):
                continue
            if box[2] <= 0 or box[3] <= 0:
                continue
            key = (meta.get("surface") or "nauvis", meta.get("area") or jp.stem)
            row = {"area": jp.stem, "shift": s["id"], "n": s.get("n"), "image": img, "meta": meta}
            old = best.get(key)
            if old is None or (meta.get("tick") or 0) >= (old["meta"].get("tick") or 0):
                best[key] = row
    return sorted(best.values(), key=lambda r: r["meta"].get("tick") or 0)


def publish(out, rows):
    """Copy the images to out/terrain/ and write out/terrain/index.json; returns the index (None without frames)."""
    if not rows:
        return None
    d = Path(out) / "terrain"
    d.mkdir(parents=True, exist_ok=True)
    listed = []
    for r in rows:
        m = r["meta"]
        name = f"{r['shift']}-{r['area']}-{m.get('tick') or 0}.webp"  # a new frame is a new name: no stale cache
        shutil.copy(r["image"], d / name)
        x, y, w, h = m["box"]
        listed.append({"src": f"/terrain/{name}", "x": x, "y": y, "w": w, "h": h, "tick": m.get("tick"),
                       "shift": r["n"], "surface": m.get("surface") or "nauvis", "px": m.get("px")})
    index = {"frames": listed}
    (d / "index.json").write_text(json.dumps(index, separators=(",", ":")))
    return index
