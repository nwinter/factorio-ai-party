#!/usr/bin/env python3
"""The charted ground under the live map, with its age (d22 batch75 AK9, viewer Aurora site:4272: "Terrain is blank north
of the base where Opus explored. Please trace charting, capture and publishing, then make newly charted areas appear
automatically with visible terrain freshness."): python3 site/test_terrainground.py

push_live.public_terrain_grid packs the stream's terrain_grid (tools/stream/terrain_grid.py) into basemap.terrain_grid,
checks its palette and drops it past its byte cap. static/mapview.js under node (prepare, scene, paint):
- the grid (run-length packed) unpacks and draws in its own palette, under the map frames: its first fill before the
  first frame's drawImage, and one dimming pass whose path takes the ground's box and the frames;
- a frame older than the ground read by 30 min is labelled "terrain from 2 h ago" at its corner, one label for frames
  whose corners lie within 60 px (the newest), none for a frame a newer one covers, none for a fresh frame, none on the
  run pages' time-lapse (no now);
- the ground's age (the newest read) and chunk count for the legend; a ground without a palette falls back to the
  viewer's water, cliffs and uncharted colours.
"""
import json, os, shutil, subprocess, sys, tempfile, time

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import push_live  # noqa: E402

JS = r"""
const fx = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
global.window = global;
global.document = { createElement: () => ({}), addEventListener() {} };
global.addEventListener = () => {};
global.localStorage = { getItem: () => null, setItem: () => {} };
require(process.argv[2]);
const M = global.PogMap;
const out = {};
const data = M.unpackData(fx.data);
out.rows = data.ground.rows;
const d = M.prepare(data);
out.pal = d.groundPal; out.age = d.groundAge; out.chunks = d.groundChunks;
const sc = M.scene(d, { cx: 0, cy: 0, span: 600 }, 400, 400);
out.groundPal = sc.ground.pal; out.gw = sc.ground.gw; out.ages = sc.terrainAges;
// paint with a recording canvas: fills by colour, images drawn, rects in the dimming path
const ops = [];
let style = '', rects = [];
const ctx = new Proxy({}, { get: (t, k) => {
  if (k === 'fill') return () => ops.push(['fill', style, rects.length]);
  if (k === 'beginPath') return () => { rects = []; };
  if (k === 'rect') return (x, y, w, h) => rects.push([x, y, w, h]);
  if (k === 'drawImage') return (img, x) => ops.push(['image', img.src]);
  if (k === 'fillText') return (s) => ops.push(['text', s]);
  if (k === 'measureText') return () => ({ width: 10 });
  return t[k] !== undefined ? t[k] : () => {};
}, set: (t, k, v) => { if (k === 'fillStyle') style = v; t[k] = v; return true; } });
M.paint(ctx, sc, (src) => ({ src, width: 100 }), 'x');
out.ops = ops;
// no palette: the viewer's own ground colours
const d2 = M.prepare(Object.assign({}, data, { ground: Object.assign({}, data.ground, { palette: [] }) }));
out.fallback = d2.groundPal.map((p) => p[0]);
// the run pages' time-lapse (no now): no age labels
out.lapseAges = M.scene(M.prepare(Object.assign({}, data, { now: undefined })), { cx: 0, cy: 0, span: 600 }, 400, 400).terrainAges.length;
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def main():
    # push_live: packed, palette checked, capped
    g = {"cell": 8, "x0": -64, "y0": -64, "w": 16, "h": 16, "rows": ["iiiirrrr" * 2] * 8 + ["." * 12 + "cccc"] * 8,
         "palette": [["i", "#37350b", "grass-1"], ["r", "#33535f", "water"], ["c", "#5b4a36", "cliffs"], ["1", "#000000", "bad"], ["x", "red", "bad"]],
         "chunks": 4, "tick": 1000, "oldest_tick": 400, "t": time.time() - 90, "age_s": 90, "extra": 1}
    p = push_live.public_terrain_grid(g)
    check("packed", p["rle"] == 1 and p["rows"][0] == "4i4r4i4r" and p["rows"][8] == "12.4c", p["rows"][:9])
    check("palette checked", [x[0] for x in p["palette"]] == ["i", "r", "c"], p["palette"])
    check("only its keys", "extra" not in p and p["chunks"] == 4, sorted(p))
    check("capped", push_live.public_terrain_grid(g, limit=50) is None)
    check("nothing without rows", push_live.public_terrain_grid({"rows": []}) is None and push_live.public_terrain_grid(None) is None)
    state = {"basemap": {"cell": 16, "x0": 0, "y0": 0, "w": 1, "h": 1, "rows": ["A"]}, "terrain_grid": g}
    check("into the basemap", push_live.public_state(state)["basemap"]["terrain_grid"]["chunks"] == 4)
    check("no basemap: not sent", "terrain_grid" not in json.dumps(push_live.public_state({"terrain_grid": g})))

    if not shutil.which("node"):
        print("terrain ground: push_live ok; viewer skipped (no node)")
        return
    now = time.time()
    frames = [  # oldest first: an old frame, one under it covered by a newer one, a fresh frame
        {"src": "/live/terrain/a.webp", "x0": -200, "y0": -200, "x1": 200, "y1": 200, "tick": 1, "w": 100, "h": 100, "t": now - 3 * 86400},
        {"src": "/live/terrain/b.webp", "x0": -150, "y0": -150, "x1": 100, "y1": 100, "tick": 2, "w": 100, "h": 100, "t": now - 2 * 86400},
        {"src": "/live/terrain/c.webp", "x0": -205, "y0": -205, "x1": 190, "y1": 190, "tick": 3, "w": 100, "h": 100, "t": now - 7200},
        {"src": "/live/terrain/d.webp", "x0": 50, "y0": 50, "x1": 250, "y1": 250, "tick": 4, "w": 100, "h": 100, "t": now - 60}]
    data = {"base": {"cell": 16, "x0": -32, "y0": -32, "w": 4, "h": 4, "rows": ["AAAA"] * 4}, "terrain": frames, "now": now,
            "now_tick": 3000, "ground": dict(p, x0=-300, y0=-300, w=16, h=16, cell=32)}
    with tempfile.TemporaryDirectory() as d:
        js, fx = os.path.join(d, "t.js"), os.path.join(d, "fx.json")
        open(js, "w").write(JS)
        json.dump({"data": data}, open(fx, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    check("unpacked", o["rows"][0] == "iiiirrrriiiirrrr" and o["rows"][8] == "............cccc", o["rows"][:9])
    check("its palette", [x[0] for x in o["pal"]] == ["i", "r", "c"] and o["groundPal"] == o["pal"] and o["gw"] == 16, o["pal"])
    check("its age", 80 <= o["age"] <= 120 and o["chunks"] == 4, (o["age"], o["chunks"]))
    ops = o["ops"]
    first_ground = next(i for i, x in enumerate(ops) if x[0] == "fill" and x[1] == "#37350b")
    first_image = next(i for i, x in enumerate(ops) if x[0] == "image")
    check("ground under the frames", first_ground < first_image, ops[:12])
    dim = [x for x in ops if x[0] == "fill" and x[1] == "#808080"]
    check("one dimming pass over the frames and the ground", len(dim) == 1 and dim[0][2] == 5, dim)
    texts = [x[1] for x in ops if x[0] == "text"]
    labels = [t for t in texts if t.startswith("terrain from")]
    check("one label for the old corner, the newest's age; none for the fresh frame", labels == ["terrain from 2 h ago"], (labels, o["ages"]))
    check("no labels without now (the time-lapse)", o["lapseAges"] == 0, o["lapseAges"])
    check("the fallback colours", o["fallback"] == ["w", "c", "u"], o["fallback"])
    print("terrain ground: ok (packed with its palette into the basemap, capped; drawn under the frames in its own colours, "
          "dimmed with them once; old frames labelled with their age, one a corner; the ground's age)")


if __name__ == "__main__":
    main()
