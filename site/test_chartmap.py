#!/usr/bin/env python3
"""The live map's chart layer (d22 batch97 BG3): python3 site/test_chartmap.py

static/mapview.js under node, with a published chart index:
- the cells of the surface shown, each at its place and 384 tiles a side; drawn first, nearest-neighbour from 1 px a
  tile up; the coarse grid, ore and terrain frames not drawn where the chart is;
- train stop names from 0.5 px a tile, recipes from 6, as text (rich text tags as words), decluttered: a label that
  would overlap one kept before it is left out;
- hover on a cell says when its chunks were read; the legend and scale line say the oldest and newest cell;
- a platform in the chart: in the platform picker by its own name, framed on its buildings' box;
- push_live's core_box frames Nauvis when the grids are left out;
- the layer's toggle: "not read" with why when the chart has no cell of the surface.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
global.window = global;
global.document = { createElement: () => ({}), addEventListener() {} };
global.addEventListener = () => {};
global.localStorage = { getItem: () => null, setItem: () => {} };
require(process.argv[2]);
const M = global.PogMap;
const index = { v: 7, cell: 384, tick: 72000, surfaces: {
  nauvis: { cells: { '0,0': [5, 36000, 70000, 144, 10, 10, 300, 200], '-1,0': [6, 60000, 71000, 20] } },
  'platform-3': { platform: 'Asterion', cells: { '0,-1': [7, 71000, 71500, 9, 0, -40, 30, -2] } } } };
const labels = {};
labels['/live/chart/nauvis/0_0.labels.json?v=5'] = { stops: [[20, 20, 'Ore [item=iron-ore] north'], [21, 20, 'Overlap stop']],
  recipes: [[30, 30, 'iron-gear-wheel'], [30.5, 30, 'copper-cable'], [60, 30, 'electronic-circuit']] };
const base = { tick: 1, cell: 16, x0: 0, y0: 0, w: 2, h: 1, rows: ['AA'] };
const data = (extra) => Object.assign({ base, now_tick: 72000, chart: { base: '/live/chart/', index }, chart_labels: labels }, extra || {});
const out = {};
let d = M.prepare(data());
out.cells = d.chart.map((c) => [c.cx, c.cy, c.src, c.labels]);
out.oldest = d.chartOldest; out.newest = d.chartNewest;
const on = { chart: true, buildings: true, ore: true, terrain: true };
let sc = M.scene(d, { cx: 20, cy: 20, span: 100 }, 400, 400, on);
out.view = sc.chart.map((c) => [c.src, c.x, c.y, c.s]); out.smooth = sc.smooth; out.base = !!sc.base;
out.labelsMid = sc.labels.map((l) => l.text);
sc = M.scene(d, { cx: 30, cy: 30, span: 50 }, 400, 400, on);
out.labelsClose = sc.labels.map((l) => [l.text, l.kind]);
sc = M.scene(d, { cx: 0, cy: 0, span: 2000 }, 400, 400, on);
out.far = { smooth: sc.smooth, labels: sc.labels.length };
sc = M.scene(d, { cx: 20, cy: 20, span: 100 }, 400, 400, { buildings: true });
out.off = { chart: sc.chart.length, base: !!sc.base };
out.hit = M.chartHit(d, 100, 100);
out.hitOld = M.chartHit(d, -100, 100);
out.plain = M.plainLabel('[virtual-signal=signal-A] Copper [fluid=water] [color=red]east[/color]');
// the platform: the switch, its framing
const v = M.create ? null : null;
d = M.prepare(data({ surface: 'platform-3' }));
out.platform = { cells: d.chart.length, auto: d.auto };
// framing on push_live's core box
d = M.prepare(data({ base: { tick: 1, cell: 16, x0: 0, y0: 0, w: 2, h: 1, core_box: [-50, -60, 150, 140] } }));
out.coreBox = d.box && [d.box.x0, d.box.y0, d.box.x1, d.box.y1];
// no cell of Vulcanus
d = M.prepare(data({ surface: 'vulcanus', planets: { vulcanus: { cell: 4, x0: 0, y0: 0, w: 1, h: 1, rows: ['A'] } } }));
out.why = M.absentWhy(data(), d, 'chart');
out.whyNone = M.absentWhy({}, M.prepare({}), 'chart');
// paint: the chart's cells drawn first, smoothing off up close
const calls = [];
const ctx = new Proxy({}, { get: (t, k) => k === 'measureText' ? () => ({ width: 10 }) : k === 'drawImage' ? (img, x, y, w, h) => calls.push(['img', t.imageSmoothingEnabled, img.src, w]) : k in t ? t[k] : () => {},
  set: (t, k, val) => { t[k] = val; return true; } });
d = M.prepare(data());
sc = M.scene(d, { cx: 20, cy: 20, span: 40 }, 400, 400, on);
M.paint(ctx, sc, (src) => ({ src, width: 384 }), 'x');
out.painted = calls;
process.stdout.write(JSON.stringify(out));
"""

VIEWER = r"""
global.window = global;
global.localStorage = { getItem: () => null, setItem: () => {} };
global.addEventListener = () => {};
function el(name) {
  const e = { name, dataset: {}, textContent: '', hidden: false, style: {}, attrs: {}, kids: {}, _html: '', clientWidth: 400, clientHeight: 400,
    classList: { s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); }, toggle() {} },
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, appendChild() {},
    querySelector(s) { return this.kids[s] || (this.kids[s] = el(s)); }, getContext() { return new Proxy({}, { get: (t, k) => k === 'measureText' ? () => ({ width: 10 }) : () => {} }); },
    getBoundingClientRect() { return { left: 0, top: 0, width: 400, height: 400 }; } };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = String(v); } });
  return e;
}
global.document = { createElement: (t) => { const e = el(t); e.kids['canvas'] = el('canvas'); return e; }, addEventListener() {}, fullscreenElement: null };
global.getComputedStyle = () => ({ fontFamily: 'x' });
global.Image = function () {};
global.requestAnimationFrame = () => 1;
require(process.argv[2]);
const M = global.PogMap;
const index = { v: 7, cell: 384, tick: 72000, surfaces: {
  nauvis: { cells: { '0,0': [5, 36000, 70000, 144, 10, 10, 300, 200] } },
  gleba: { cells: { '0,0': [6, 70000, 71000, 20, 0, 0, 50, 50] } },
  'platform-3': { platform: 'Asterion', cells: { '0,-1': [7, 71000, 71500, 9, 0, -40, 30, -2] } } } };
const v = M.create(el('host'), { storeKey: 'c' });
v.set({ base: { tick: 1, cell: 16, x0: 0, y0: 0, w: 2, h: 1, rows: ['AA'] }, now_tick: 72000, chart: { base: '/live/chart/', index } });
const layers = v.root.querySelector('.mapview-layers').innerHTML;
const legend = v.root.querySelector('.mapview-legend').innerHTML;
process.stdout.write(JSON.stringify({ layers, legend }));
"""


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:2000]))
    if not ok:
        sys.exit(1)


def main():
    if not shutil.which("node"):
        print("chart map: skipped (no node)")
        return
    mv = os.path.join(SITE, "static", "mapview.js")
    with tempfile.TemporaryDirectory() as d:
        js, jv = os.path.join(d, "t.js"), os.path.join(d, "v.js")
        open(js, "w").write(JS)
        open(jv, "w").write(VIEWER)
        r = subprocess.run(["node", js, mv], capture_output=True, text=True, timeout=30)
        r2 = subprocess.run(["node", jv, mv], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0 and r2.returncode == 0, r.stderr[-1500:] + r2.stderr[-1500:])
    o, w = json.loads(r.stdout), json.loads(r2.stdout)
    check("Nauvis's cells from the index, each with its versioned image and labels", sorted(o["cells"]) == sorted([
        [0, 0, "/live/chart/nauvis/0_0.png?v=5", "/live/chart/nauvis/0_0.labels.json?v=5"],
        [-1, 0, "/live/chart/nauvis/-1_0.png?v=6", "/live/chart/nauvis/-1_0.labels.json?v=6"]]), o["cells"])
    check("oldest and newest cell in game seconds", o["oldest"] == 600 and abs(o["newest"] - 1000 / 60) < 1e-6, (o["oldest"], o["newest"]))
    k = 400 / 100
    check("a cell in view at its place, 384 tiles a side", ["/live/chart/nauvis/0_0.png?v=5", 200 - 20 * k, 200 - 20 * k, 384 * k] in o["view"], o["view"])
    check("nearest-neighbour from 1 px a tile up; smoothed when zoomed out", o["smooth"] is False and o["far"]["smooth"] is True, (o["smooth"], o["far"]))
    check("the coarse grid not drawn under the chart", o["base"] is False)
    check("at 4 px a tile: stop names, no recipes; the second stop overlaps the first and is left out",
          o["labelsMid"] == ["Ore iron ore north"], o["labelsMid"])
    close = o["labelsClose"]
    check("at 8 px a tile: recipes as words too, one overlapping another left out", ["iron gear wheel", "recipe"] in close
          and ["copper cable", "recipe"] not in close and ["electronic circuit", "recipe"] in close, close)
    check("zoomed far out: no labels", o["far"]["labels"] == 0, o["far"])
    check("the layer off: no cells, the coarse grid back", o["off"] == {"chart": 0, "base": True}, o["off"])
    check("hover: the cell and when its chunks were read", o["hit"]["text"] == "Chart cell (0, 0), 144 chunks, read 33 s to 10 min ago", o["hit"])
    check("rich text as words", o["plain"] == "signal A Copper water east", o["plain"])
    check("a platform: its cell, framed on its buildings", o["platform"]["cells"] == 1 and o["platform"]["auto"]
          and abs(o["platform"]["auto"]["cx"] - 15) < 1e-6 and abs(o["platform"]["auto"]["cy"] + 21) < 1e-6, o["platform"])
    check("with the grids left out, Nauvis framed on push_live's core box", o["coreBox"] == [-50, -60, 150, 140], o["coreBox"])
    check("a surface without cells: not read and why", o["why"].startswith("not read: the published chart has no cell of Vulcanus")
          and o["whyNone"] == "not read: no chart published yet", (o["why"], o["whyNone"]))
    check("paint: the chart's image drawn, smoothing off up close", any(c[0] == "img" and c[1] is False and c[2].endswith("0_0.png?v=5") for c in o["painted"]), o["painted"])
    check("the switch: Gleba a planet button, Asterion in the platform picker", 'data-surface="gleba"' in w["layers"]
          and '<option value="platform-3">Asterion</option>' in w["layers"] and 'data-surface="platform-3"' not in w["layers"], w["layers"])
    check("the Chart toggle in the Terrain group", 'data-layer="chart"' in w["layers"], w["layers"])
    check("the legend: the chart and its ages", "Chart: the ground, resources and buildings in the game&#39;s map colours" in w["legend"]
          and "oldest cell" in w["legend"] and "publishes it hourly" in w["legend"], w["legend"])
    print("chart map: ok (cells under the overlays, labels decluttered, ages on hover and in the legend, platforms, framing)")


if __name__ == "__main__":
    main()
