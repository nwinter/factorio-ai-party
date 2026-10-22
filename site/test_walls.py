#!/usr/bin/env python3
"""Walls as their own map category (d22 batch75 AK4, viewer Foobator, site:4136: "on the map view, i think walls are
"defense"? can walls be a separate item?"): python3 site/test_walls.py

Walls and gates were D ("Defence", with turrets) in the basemap (harness.py BASEMAP_LUA, census.lua) and drawn in
Defence red. Now they are W: their own colour and legend entry ("Walls and gates") on the live map and the run pages'
time-lapse (the same viewer, static/mapview.js), ranked under turrets so a cell with a turret stays D (the turret sweep
reads D cells only; turretsweep.areas) and over everything else as before. Here: the rank tables agree (BASEMAP_LUA,
census.lua, push_live.RANK); push_live.coarser keeps D over W and W over a lab; the sweep's areas skip W cells; the
viewer draws W in its colour (style.css .b-W the same) and lists it in the legend beside Defence.
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
sys.path.insert(0, SITE)
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import push_live  # noqa: E402
import turretsweep  # noqa: E402
import harness  # noqa: E402

JS = r"""
const fx = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
function el(name) {
  const e = { name, dataset: {}, textContent: '', hidden: false, style: {}, attrs: {}, kids: {}, _html: '', clientWidth: 400, clientHeight: 400,
    classList: { s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); }, toggle() {} },
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, appendChild() {},
    querySelector(s) { return this.kids[s] || (this.kids[s] = el(s)); }, getContext() { return ctx; }, getBoundingClientRect() { return { left: 0, top: 0, width: 400, height: 400 }; } };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = String(v); } });
  return e;
}
// a canvas that records the colour each cell run is filled with
const fills = [];
let style = '';
const ctx = new Proxy({}, { get: (t, k) => k === 'fill' || k === 'fillRect' ? () => fills.push(style) : k === 'measureText' ? () => ({ width: 10 }) : t[k] !== undefined ? t[k] : () => {},
  set: (t, k, v) => { if (k === 'fillStyle') style = v; t[k] = v; return true; } });
global.window = global;
global.document = { createElement: (t) => { const e = el(t); e.kids['canvas'] = el('canvas'); return e; }, addEventListener() {}, fullscreenElement: null };
global.addEventListener = () => {};
global.getComputedStyle = () => ({ fontFamily: 'x' });
global.localStorage = { getItem: () => null, setItem: () => {} };
global.Image = function () {};
let frames = [];
global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
require(process.argv[2]);
const M = global.PogMap;
const v = M.create(el('host'), { storeKey: 'w' });
v.set(fx.data);
frames.forEach((f) => f());
process.stdout.write(JSON.stringify({ base: M.BASE, legend: v.root.querySelector('.mapview-legend').innerHTML, runs: Object.keys(M.runs(fx.data.base)).sort(), fills: fills }));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def lua_rank(src):
    m = re.search(r"RANK = \{([^}]*)\}", src)
    return {k: int(v) for k, v in re.findall(r"(\w)\s*=\s*(\d+)", m.group(1))}


def main():
    census = open(os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0", "census.lua")).read()
    ranks = [lua_rank(harness.BASEMAP_LUA), lua_rank(census), push_live.RANK]
    check("the rank tables agree", ranks[0] == ranks[1] == ranks[2], ranks)
    check("W under D, over the rest", ranks[0]["D"] > ranks[0]["W"] > max(v for k, v in ranks[0].items() if k not in "DW"), ranks[0])
    for src in (harness.BASEMAP_LUA, census):
        check("walls and gates W", re.search(r"""\[?["']?wall["']?\]?\s*=\s*["']W["']""", src) and re.search(r"""\[?["']?gate["']?\]?\s*=\s*["']W["']""", src), src[:80])
        check("turrets D", re.search(r"""\[["']ammo-turret["']\]\s*=\s*["']D["']""", src), src[:80])
    c = push_live.coarser({"cell": 4, "x0": 0, "y0": 0, "w": 4, "h": 1, "rows": ["DWWR"]})
    check("coarser: D over W, W over a lab", c["rows"] == ["DW"], c)
    sweep = turretsweep.areas({"cell": 4, "x0": 0, "y0": 0, "rows": ["WWDDWW.D"]})
    check("the turret sweep skips wall cells", sweep == [[8, 0, 16, 4], [28, 0, 32, 4]], sweep)

    css = open(os.path.join(SITE, "static", "style.css")).read()
    if not shutil.which("node"):
        print("walls: tables ok; viewer skipped (no node)")
        return
    data = {"base": {"tick": 1, "cell": 4, "x0": 0, "y0": 0, "w": 6, "h": 2, "rows": ["DWWWA", "WW"]}, "agents": [], "now_tick": 60}
    with tempfile.TemporaryDirectory() as d:
        js, fx = os.path.join(d, "t.js"), os.path.join(d, "fx.json")
        open(js, "w").write(JS)
        json.dump({"data": data}, open(fx, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    base = {b[0]: b for b in o["base"]}
    check("W in the palette", base["W"][2] == "Walls and gates" and base["W"][1] != base["D"][1] and base["D"][2] == "Defence", base)
    check("the legend's colour the same", f".b-W {{ fill: {base['W'][1]}; background: {base['W'][1]}; }}" in css, base["W"])
    colours = [b[1].lower() for b in o["base"]]
    check("a colour of its own", len(set(colours)) == len(colours), colours)
    check("its runs", o["runs"] == ["A", "D", "W"], o["runs"])
    check("drawn in its colour", base["W"][1] in o["fills"] and base["D"][1] in o["fills"], sorted(set(map(str, o["fills"]))))
    check("the legend", '<i class="b-W"></i>Walls and gates' in o["legend"] and '<i class="b-D"></i>Defence' in o["legend"], o["legend"])
    print("walls: ok (walls and gates W in both basemap reads, under turrets; their own colour and legend entry; the turret sweep skips them)")


if __name__ == "__main__":
    main()
