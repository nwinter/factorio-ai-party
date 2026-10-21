#!/usr/bin/env python3
"""Every planet's detailed map (d21 batch68 AD1, viewer Aurora, operator inbox 08:40: "Could Aquilo get a detailed base map
using the Nauvis approach, with building footprints, coordinates and data age? Zoom currently only enlarges category
blocks"): python3 site/test_planetcore.py

push_live.py: pack() run-length packs a grid's rows ("....AAAA" -> "4.4A", rle 1), the basemap's coarse grid, core and
ore are packed, a planet map carries its core (packed, at twice the cell until it fits PLANET_CORE_BYTES), a planet with
no core sends none. static/mapview.js under node: unpack() restores the rows, prepare() draws a planet's core as
Nauvis's (the fine grid and the box round it), and the scale line gives the map's age on every surface.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
import push_live  # noqa: E402

JS = r"""
const fx = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
global.window = global;
require(process.argv[2]);
const M = global.PogMap;
const out = {};
out.unpacked = M.unpack(fx.packed).rows;
out.plain = M.unpack(fx.plainGrid).rows;
const data = M.unpackData(fx.state);
out.coreRows = data.planets.aquilo.core.rows;
const d = M.prepare(Object.assign({}, data, { surface: 'aquilo' }));
out.fine = !!d.fine && d.fine.cell;
out.box = d.box && [d.box.x0, d.box.y0, d.box.x1, d.box.y1];
const n = M.prepare(data);
out.nauvisFine = !!n.fine && n.fine.cell;
out.nauvisAge = M.mapAge(data, 'nauvis');
out.aquiloAge = M.mapAge(data, 'aquilo');
const g = M.prepare(Object.assign({}, data, { surface: 'gleba' }));
out.glebaFine = g.fine;
out.glebaBase = !!g.base;
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def main():
    g = {"cell": 1, "x0": 0, "y0": 0, "w": 10, "h": 2, "rows": ["....AAAA.B", "DD"]}
    p = push_live.pack(g)
    check("pack", p["rows"] == ["4.4A.B", "DD"] and p["rle"] == 1 and g["rows"][0] == "....AAAA.B", p)
    check("packed once", push_live.pack(p) is p)
    check("not a grid", push_live.pack({"rows": "x"}) == {"rows": "x"})
    bm = {"tick": 5, "cell": 16, "x0": 0, "y0": 0, "w": 4, "rows": ["AAAA"], "core": dict(g), "ore": {"cell": 16, "x0": 0, "y0": 0, "rows": ["iiii"]},
          "nests": [[1, 2, "s"]]}
    pb = push_live.public_basemap(bm)
    check("basemap packed", pb["rows"] == ["4A"] and pb["core"]["rows"][0] == "4.4A.B" and pb["ore"]["rows"] == ["4i"] and pb["nests"] == [[1, 2, "s"]], pb)
    # a planet map with its core, one a push
    aq = {"tick": 100, "cell": 4, "x0": 0, "y0": 0, "w": 3, "h": 1, "rows": ["AAE"], "buildings": 9,
          "core": {"cell": 1, "x0": 0, "y0": 0, "w": 12, "h": 2, "rows": ["AAAAAAEEEE", "..LLL"]}}
    gl = {"tick": 90, "cell": 8, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["SS"], "buildings": 2}
    push_live._planet_turn["i"] = 0
    listing, pm = push_live.public_planets({"aquilo": aq, "gleba": gl})
    check("listing", [x["surface"] for x in listing] == ["aquilo", "gleba"], listing)
    check("aquilo's core packed", pm["surface"] == "aquilo" and pm["core"]["rows"] == ["6A4E", "..3L"] and pm["core"]["rle"] == 1 and pm["rows"] == ["AAE"], pm)
    _, pm2 = push_live.public_planets({"aquilo": aq, "gleba": gl})
    check("gleba without a core sends none", pm2["surface"] == "gleba" and "core" not in pm2, pm2)
    # a core over the budget: twice the cell until it fits
    worst = {"cell": 1, "x0": 5, "y0": 3, "w": 160, "h": 160, "rows": ["AB" * 80] * 160}
    f = push_live.fitted(worst, limit=4096)
    check("fitted", f["cell"] == 2 and len(json.dumps(f, separators=(",", ":"))) <= 4096 and f["x0"] == 4 and f["y0"] == 2, (f["cell"], f["x0"], f["y0"]))
    c = push_live.coarser({"cell": 1, "x0": 1, "y0": 0, "w": 4, "h": 2, "rows": ["PDAB", "..I"]})
    check("coarser keeps the most telling", c["rows"] == ["PDB"] and c["cell"] == 2 and c["x0"] == 0, c)

    if not shutil.which("node"):
        print("planet core: push_live ok; mapview skipped (no node)")
        return
    state = {"base": {"tick": 600, "cell": 16, "x0": 0, "y0": 0, "w": 2, "rows": ["AA"]},
             "core": {"cell": 2, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AA"]},
             "planets": {"aquilo": pm, "gleba": push_live.pack(dict(gl, surface="gleba"))}, "now_tick": 600 + 3 * 3600}
    with tempfile.TemporaryDirectory() as d:
        fx = os.path.join(d, "fx.json")
        json.dump({"packed": p, "plainGrid": g, "state": state}, open(fx, "w"))
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
        check("node", r.returncode == 0, r.stderr)
        o = json.loads(r.stdout)
    check("unpack", o["unpacked"] == ["....AAAA.B", "DD"], o)
    check("plain rows as they are", o["plain"] == ["....AAAA.B", "DD"], o)
    check("a planet's core unpacked", o["coreRows"] == ["AAAAAAEEEE", "..LLL"], o)
    check("drawn as Nauvis's core", o["fine"] == 1 and o["box"] == [0, 0, 12, 2], o)
    check("Nauvis's core as before", o["nauvisFine"] == 2, o)
    check("ages", o["nauvisAge"] == 180 and o["aquiloAge"] == (600 + 3 * 3600 - 100) / 60, o)
    check("a planet with no core: its coarse grid", o["glebaFine"] is None and o["glebaBase"], o)
    print("planet core: ok (grids packed, a planet's core sent and drawn as Nauvis's, a map's age on every surface)")


if __name__ == "__main__":
    main()
