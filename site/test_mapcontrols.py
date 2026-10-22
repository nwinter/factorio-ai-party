#!/usr/bin/env python3
"""The map's controls (d22 batch75 AK3, viewer Aurora, site:4119: "Could the map separate planet tabs from layer filters?
Give planets their own row, group layers below (terrain, networks, combat), and keep the item filter in a consistent
spot."): python3 site/test_mapcontrols.py

static/mapview.js's Viewer under node in a stub DOM. The planet tabs are a row of their own (.mapview-planets: planet
buttons only); the layers sit below in GROUPS (Terrain, Networks, Combat, Team), each under its label. A layer had once
keeps its button and its place on a planet with none of it (disabled, "none on Aquilo now"); the item picker opens the
Networks group on every planet, disabled where no networks map is read. Each layer's on/off stays across a planet
switch and a new page (the viewer's KEY-layers storage); a viewer that never had a networks map shows no Networks group.
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
const fs = require('fs');
const fx = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function el(name) {
  const e = { name, dataset: {}, textContent: '', hidden: false, style: {}, attrs: {}, kids: {}, _html: '', clientWidth: 400, clientHeight: 400,
    classList: { s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); }, toggle() {} },
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
const disk = {};
global.localStorage = { getItem: (k) => (k in disk ? disk[k] : null), setItem: (k, v) => { disk[k] = String(v); } };
global.Image = function () {};
let frames = [];
global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
const flush = () => { const f = frames; frames = []; f.forEach((x) => x()); };
require(process.argv[2]);
const M = global.PogMap;
const html = (v) => v.root.querySelector('.mapview-layers').innerHTML;
const pick = (v, s) => v.onClick({ target: { closest: () => ({ dataset: { surface: s } }) } });
const out = {};
const v = M.create(el('host'), { storeKey: 'k' });
v.set(fx.data);
flush();
out.nauvis = html(v);
v.onClick({ target: { closest: () => ({ dataset: { layer: 'power' } }) } });  // power on
v.onClick({ target: { closest: () => ({ dataset: { layer: 'nests' } }) } });  // nests off
flush();
pick(v, 'gleba'); flush();
out.gleba = html(v);
pick(v, 'aquilo'); flush();
out.aquilo = html(v);
out.groups = M.GROUPS.map((g) => [g[1], g[2]]);
out.layers = M.LAYERS.map((l) => l[0]);
// a new page over the same storage: the layers as they were left
const w = M.create(el('host2'), { storeKey: 'k' });
w.set(fx.data); flush();
out.reload = html(w);
// the time-lapse: no networks map ever, no other planet
const t = M.create(el('host3'), { storeKey: 't' });
t.set({ base: fx.data.base, agents: fx.data.agents, now_tick: fx.data.now_tick }); flush();
out.lapse = html(t);
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def grid(surface, tick, rows):
    return {"surface": surface, "tick": tick, "cell": 8, "x0": 0, "y0": 0, "w": len(rows[0]), "h": len(rows), "rows": rows, "buildings": 4}


def net(surface, tick, items):
    return {"surface": surface, "tick": tick, "electric": {"poles": 2, "nets": "7,A,2", "cell": 4, "x0": 0, "y0": 0, "w": 4, "h": 1, "rows": ["AAAA"]},
            "logistic": [{"id": 3, "lr": 25, "cr": 55, "n": 1, "ports": "4,4"}], "items": [[i, "A,3,1,0,0,4,4", "Q,3,1,5,0,8,8"] for i in items]}


def planet_row(h):
    m = re.search(r'<div class="mapview-planets"[^>]*>(.*?)</div>', h)
    return m.group(1) if m else ""


def groups(h):
    """[(label, [control ...])]: each group's label and its controls in order (item picker, then data-layer buttons)."""
    out = []
    for label, body in re.findall(r'<span class="mapview-group-label"[^>]*>([^<]+)</span><div class="mapview-group"[^>]*>(.*?)</div>', h):
        ctl = []
        for m in re.finditer(r'<(select|button)([^>]*)>', body):
            attrs = m.group(2)
            name = "item" if "data-item" in attrs else re.search(r'data-layer="(\w+)"', attrs).group(1)
            ctl.append(name + (" (disabled)" if " disabled" in attrs else "") + (" on" if 'aria-pressed="true"' in attrs else ""))
        out.append((label, ctl))
    return out


def main():
    if not shutil.which("node"):
        print("map controls: skipped (no node)")
        return
    t0 = 46_000_000
    cloud = {"surface": "gleba", "label": "Gleba spores", "pollutant": "spores", "color": {"r": 0.6, "g": 0.2, "b": 0.6, "a": 1},
             "cells": [[0, 0, 12.5]], "max": 12.5}
    data = {"base": dict(grid("nauvis", t0, ["AA"]), cell=16), "nests": [[40, 40, "s"]], "turrets": [[1, 1, 18]],
            "agents": [{"name": "sol", "position": {"x": 1, "y": 1}, "alive": True}], "clouds": [cloud], "now_tick": t0 + 60,
            "planets": {"gleba": grid("gleba", t0, ["AS"]), "aquilo": grid("aquilo", t0, ["SS"])},
            "net_maps": {"nauvis": net("nauvis", t0, ["iron-plate", "copper-cable"]), "gleba": net("gleba", t0, ["bioflux"])},
            "planet_list": [{"surface": "gleba", "tick": t0}, {"surface": "aquilo", "tick": t0}],
            "net_list": [{"surface": "nauvis", "tick": t0}, {"surface": "gleba", "tick": t0}]}
    with tempfile.TemporaryDirectory() as d:
        js, fx = os.path.join(d, "t.js"), os.path.join(d, "fx.json")
        open(js, "w").write(JS)
        json.dump({"data": data}, open(fx, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    # every layer in exactly one group
    grouped = [k for _, keys in o["groups"] for k in keys]
    check("every layer grouped once", sorted(grouped) == sorted(o["layers"]), (grouped, o["layers"]))
    check("groups named", [g for g, _ in o["groups"]] == ["Terrain", "Networks", "Combat", "Team"], o["groups"])
    for page in ("nauvis", "gleba", "aquilo"):
        h = o[page]
        row = planet_row(h)
        check(page + ": planets in a row of their own", re.findall(r'data-surface="(\w+)"', row) == ["nauvis", "aquilo", "gleba"]
              and "data-layer" not in row and "data-item" not in row, row)
        check(page + ": the planet row first, the groups below", h.index("mapview-planets") < h.index("mapview-groups"), h[:200])
        check(page + ": no planet button among the layers", "data-surface" not in h[h.index("mapview-groups"):], page)
    gn, gg, ga = groups(o["nauvis"]), groups(o["gleba"]), groups(o["aquilo"])
    check("Nauvis's groups", gn == [("Terrain", ["buildings on", "cloud (disabled) on"]), ("Networks", ["item", "power", "robots"]),
                                    ("Combat", ["coverage", "nests on"]), ("Team", ["agents on"])], gn)
    # the same controls in the same places on every planet; what the planet has none of is disabled
    shape = lambda g: [(label, [c.split(" ")[0] for c in ctl]) for label, ctl in g]  # noqa: E731
    check("the same places on Gleba", shape(gg) == shape(gn), gg)
    check("the same places on Aquilo", shape(ga) == shape(gn), ga)
    check("Gleba: the layer state kept across the switch", ("Networks", ["item", "power on", "robots"]) in gg, gg)
    check("Gleba: Nauvis-only layers disabled", ("Combat", ["coverage (disabled)", "nests (disabled)"]) in gg, gg)
    check("Aquilo: no networks map: the item picker disabled, in its place", ("Networks", ["item (disabled)", "power (disabled) on", "robots (disabled)"]) in ga, ga)
    check("Aquilo: why disabled", 'title="Power networks: none on Aquilo now"' in o["aquilo"] and "Item: no networks map of Aquilo yet" in o["aquilo"], o["aquilo"])
    check("Gleba's items", "Bioflux" in o["gleba"] and "Iron plate" not in o["gleba"], o["gleba"])
    check("Gleba's spores", ("Terrain", ["buildings on", "cloud on"]) in gg and ">Spores<" in o["gleba"], gg)
    check("a reload keeps the layers", groups(o["reload"]) == [("Terrain", ["buildings on", "cloud (disabled) on"]), ("Networks", ["item", "power on", "robots"]),
                                                                ("Combat", ["coverage", "nests"]), ("Team", ["agents on"])], groups(o["reload"]))
    check("the time-lapse: no planet row, no networks", "mapview-planets" not in o["lapse"] and [g for g, _ in groups(o["lapse"])] == ["Terrain", "Team"], o["lapse"])
    print("map controls: ok (planet tabs in their own row; layers grouped below, each in its place on every planet with the item "
          "picker first under Networks; layer state across switches and reloads)")


if __name__ == "__main__":
    main()
