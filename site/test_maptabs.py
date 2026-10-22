#!/usr/bin/env python3
"""The live map's surface tabs across partial updates (d20 batch50 D1, viewer Aurora, shift45 inbox 08:09: "Could partial
map updates retain the last map with its age? Tabs sometimes disappear and reset the selected planet"):
python3 site/test_maptabs.py

static/mapview.js's Viewer under node in a stub DOM: a first update with Vulcanus's and Gleba's maps and Gleba's spore
cloud, Gleba selected and the view panned; a second update (12 game minutes later) with Vulcanus's map only, no Gleba
map and no cloud, as a push that leaves a planet out. Gleba keeps its tab, its last map and the selection, the view
stays, and the tab and the scale line give the map's age. remember() and switchList() on their own; a newer map
replaces a kept one, an older one does not. static/live.js no longer drops a planet the push's listing leaves out.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
const fs = require('fs');
const fx = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function el(name) {
  const e = { name, dataset: {}, textContent: '', hidden: false, style: {}, attrs: {}, kids: {}, _html: '', clientWidth: 400, clientHeight: 400,
    classList: { s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); } },
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, appendChild() {},
    querySelector(s) { return this.kids[s] || (this.kids[s] = el(s)); }, getContext() { return ctx; }, getBoundingClientRect() { return { left: 0, top: 0, width: 400, height: 400 }; } };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = String(v); } });
  return e;
}
const noop = new Proxy(function () {}, { get: (t, k) => (k === 'width' ? 10 : noop), apply: () => noop, set: () => true });
const ctx = noop;
global.window = global;
global.document = { createElement: (t) => { const e = el(t); e.kids['canvas'] = el('canvas'); return e; }, addEventListener() {}, fullscreenElement: null };
global.addEventListener = () => {};
global.getComputedStyle = () => ({ fontFamily: 'x' });
global.localStorage = { getItem: () => null, setItem: () => {} };
global.Image = function () {};
let frames = [];
global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
const flush = () => { const f = frames; frames = []; f.forEach((x) => x()); };
require(process.argv[2]);
const M = global.PogMap;
const out = {};
// the pure parts
const memo = {};
let r = M.remember(memo, fx.first);
out.firstSeen = Object.keys(r.seen).sort();
r = M.remember(memo, fx.second);
out.secondPlanets = Object.keys(r.planets).sort();
out.glebaTick = r.planets.gleba.tick;
out.switchAfter = M.switchList(r).map((x) => x.text);
r = M.remember(memo, { planets: { vulcanus: Object.assign({}, fx.second.planets.vulcanus, { tick: 1, rows: ['XX'] }) }, now_tick: fx.second.now_tick });
out.olderKeptOut = r.planets.vulcanus.rows[0];  // an older map does not replace a newer one
// the viewer
const host = el('host');
const v = M.create(host, { storeKey: 't' });
v.set(fx.first);
flush();
const box = v.root.querySelector('.mapview-layers');
out.tabsFirst = (box.innerHTML.match(/data-surface="([^"]+)"/g) || []).map((s) => s.slice(14, -1));
// the viewer picks Gleba (a click on its switch) and pans
v.onClick({ target: { closest: () => ({ dataset: { surface: 'gleba' } }) } });
flush();
v.view = { cx: 10, cy: -20, span: 40 };
v.set(fx.second);
flush();
out.surface = v.surface;
out.view = v.view;
out.tabsSecond = (box.innerHTML.match(/data-surface="([^"]+)"[^>]*>([^<]*)</g) || []).map((s) => s.replace(/.*data-surface="([^"]+)"[^>]*>/, '$1:').replace(/<$/, ''));
out.pressed = /data-surface="gleba" aria-pressed="true"/.test(box.innerHTML);
out.drawnBase = !!(v.d && v.d.base);
out.scale = v.root.querySelector('.mapview-scale').textContent;
// a surface never seen (memo lost) falls back to Nauvis
const v2 = M.create(el('host2'), {});
v2.surface = 'aquilo';
v2.set(fx.second);
out.unseen = v2.surface;
process.stdout.write(JSON.stringify(out));
"""

LIVE_JS = r"""
// static/live.js's keepPlanets: a push whose listing leaves Gleba out keeps Gleba's map
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const start = src.indexOf('  var KEPT_KEY'), end = src.indexOf('  function mapData(s)');
const keepPlanets = new Function('store', src.slice(start, end) + '; return keepPlanets;')(() => null);
const g = { surface: 'gleba', tick: 100, cell: 8, x0: 0, y0: 0, w: 2, h: 1, rows: ['AS'] };
const v = { surface: 'vulcanus', tick: 200, cell: 8, x0: 0, y0: 0, w: 2, h: 1, rows: ['SS'] };
keepPlanets({ planets: [{ surface: 'gleba' }, { surface: 'vulcanus' }], planet_map: g });
const kept = keepPlanets({ planets: [{ surface: 'vulcanus' }], planet_map: v });
process.stdout.write(JSON.stringify(Object.keys(kept).sort()));
"""


def grid(surface, tick, rows):
    return {"surface": surface, "tick": tick, "cell": 8, "x0": 0, "y0": 0, "w": len(rows[0]), "h": len(rows), "rows": rows, "buildings": 4}


def main():
    if not shutil.which("node"):
        print("map tabs: skipped (no node)")
        return
    t0 = 36_000_000
    cloud = {"surface": "gleba", "label": "Gleba spores", "pollutant": "spores", "color": {"r": 0.6, "g": 0.2, "b": 0.6, "a": 1},
             "cells": [[0, 0, 12.5]], "max": 12.5}
    first = {"planets": {"vulcanus": grid("vulcanus", t0, ["SSAA"]), "gleba": grid("gleba", t0, ["AAEE", "EE"])},
             "clouds": [cloud], "agents": [], "now_tick": t0 + 60}
    second = {"planets": {"vulcanus": grid("vulcanus", t0 + 12 * 3600, ["SSAA"])}, "clouds": [], "agents": [],
              "now_tick": t0 + 12 * 3600 + 60}
    with tempfile.TemporaryDirectory() as d:
        fx = os.path.join(d, "fx.json")
        json.dump({"first": first, "second": second}, open(fx, "w"))
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
        lj = os.path.join(d, "l.js")
        open(lj, "w").write(LIVE_JS)
        r = subprocess.run(["node", lj, os.path.join(SITE, "static", "live.js")], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        kept = json.loads(r.stdout)
    assert o["firstSeen"] == ["gleba", "vulcanus"], o
    assert o["secondPlanets"] == ["gleba", "vulcanus"] and o["glebaTick"] == t0, o  # Gleba's last map kept
    assert o["switchAfter"] == ["Nauvis", "Gleba · 12 min old", "Vulcanus"], o["switchAfter"]
    assert o["olderKeptOut"] == "SSAA", o
    assert o["tabsFirst"] == ["nauvis", "gleba", "vulcanus"], o["tabsFirst"]
    assert o["surface"] == "gleba" and o["pressed"], o  # the selection stays
    assert o["view"] == {"cx": 10, "cy": -20, "span": 40}, o["view"]  # and the view
    assert o["tabsSecond"] == ["nauvis:Nauvis", "gleba:Gleba · 12 min old", "vulcanus:Vulcanus"], o["tabsSecond"]
    assert o["drawnBase"], o  # Gleba's last map is what is drawn
    assert "map from 12 min ago" in o["scale"], o["scale"]
    assert o["unseen"] == "nauvis", o
    assert kept == ["gleba", "vulcanus"], kept
    print("map tabs: ok (a planet a push leaves out keeps its tab, its last map with its age, the selection and the view)")


if __name__ == "__main__":
    main()
