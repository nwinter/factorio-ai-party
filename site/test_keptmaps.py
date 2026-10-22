#!/usr/bin/env python3
"""Each planet's last map and networks map kept across refreshes, page loads and stream restarts, with their age (d22
batch75 AK1, viewer Aurora, site:4011: "Planet buttons and network layers disappear between refreshes. Could each planet
keep its last valid map and overlays, with their age shown, until a replacement arrives?"): python3 site/test_keptmaps.py

What dropped them on the live site (d22 06:21, shift57's start): push_live sent one planet's map and one networks map
a push, in turn, and the stream service starts empty after a restart (Aquilo alone for the first pushes, Gleba and
Vulcanus not yet read), so a page loaded then had a planet or two; the page kept what it had seen only while it stayed
open. Here: push_live sends the others' maps beside the one in turn while they fit; static/live.js keeps both kinds of
map in this browser's storage across page loads (a second page load with a state that lists Aquilo only still has Gleba
and Vulcanus), drops a map from past the state's tick and a planet left out of the listings for an hour; static/mapview.js
keeps the last clouds and Nauvis's basemap while a state has none, and the switch, the scale line and the legend give a
held map's age ("Gleba · 5 min old", "(kept until a newer one arrives)").
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import push_live  # noqa: E402

KEEP_JS = r"""
// static/live.js's keeping: two page loads over one browser storage, the clock under the test's hand
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const fx = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const start = src.indexOf('  var KEPT_KEY'), end = src.indexOf('  function mapData(s)');
const body = src.slice(start, end) + '; return { keepPlanets: keepPlanets, keepNets: keepNets, keepUp: keepUp, keepLast: keepLast };';
const disk = {};
const store = (k, v) => { if (v === undefined) return disk[k] == null ? null : disk[k]; disk[k] = v; };
let clock = 1792660000 * 1000;
Date.now = () => clock;
const page = () => new Function('store', body)(store);
const see = (p, s) => {
  const kl = p.keepLast(s), pl = p.keepPlanets(s), nt = p.keepNets(s), gone = p.keepUp(s);
  return { planets: Object.keys(pl).sort(), nets: Object.keys(nt).sort(), gone: gone, base: kl.bm.tick || null, home_held: kl.home_held == null ? null : kl.home_held,
    clouds: kl.clouds.map((c) => c.surface), clouds_held: kl.clouds_held == null ? null : kl.clouds_held };
};
const out = {};
// the first page: three pushes before the restart
let p = page();
fx.before.forEach((s) => see(p, s));
out.saved = Object.keys(JSON.parse(disk['pog-live-kept']).planets).sort();
out.savedLast = Object.keys(JSON.parse(disk['pog-live-kept']).last).sort();
// shift change: the page reloads while the restarted service lists Aquilo only
clock += 600 * 1000;
p = page();
out.reload = see(p, fx.restart);
// an hour of states that leave Vulcanus out (Gleba listed again): Vulcanus goes
clock += 1800 * 1000; see(p, fx.restart);
out.halfHour = see(p, fx.relisted);
clock += 1801 * 1000;
out.hour = see(p, fx.relisted);
// the world rolled back: a map from past the state's tick goes
out.rollback = see(p, Object.assign({}, fx.relisted, { tick: 100 }));
// storage older than KEEP_S is not read
clock += 13 * 3600 * 1000;
out.stale = see(page(), { tick: 1 });
process.stdout.write(JSON.stringify(out));
"""

VIEW_JS = r"""
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
global.localStorage = { getItem: (k) => (k === 'k-layers' ? JSON.stringify({ power: true }) : null), setItem: () => {} };
global.Image = function () {};
let frames = [];
global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
const flush = () => { const f = frames; frames = []; f.forEach((x) => x()); };
require(process.argv[2]);
const M = global.PogMap;
const out = {};
const tabs = (v) => (v.root.querySelector('.mapview-layers').innerHTML.match(/data-surface="[^"]+"[^>]*>[^<]*</g) || []).map((s) => s.replace(/.*>/, '').replace(/<$/, ''));
const layers = (v) => (v.root.querySelector('.mapview-layers').innerHTML.match(/data-layer="([^"]+)"/g) || []).map((s) => s.slice(12, -1));
const v = M.create(el('host'), { storeKey: 'k' });
v.set(fx.first);
flush();
out.firstTabs = tabs(v);
out.firstScale = v.root.querySelector('.mapview-scale').textContent;
// the restart: no basemap, no clouds, Aurora's planets missing from the listings, Gleba's networks listed newer
v.set(fx.second);
flush();
out.secondTabs = tabs(v);
out.nauvisScale = v.root.querySelector('.mapview-scale').textContent;
out.nauvisDrawn = !!v.d.base;
v.onClick({ target: { closest: () => ({ dataset: { surface: 'gleba' } }) } });
flush();
out.glebaScale = v.root.querySelector('.mapview-scale').textContent;
out.glebaLayers = layers(v);
out.glebaLegend = v.root.querySelector('.mapview-legend').innerHTML;
// a replacement arrives: no longer held
v.set(fx.third);
flush();
out.thirdTabs = tabs(v);
out.thirdLegend = v.root.querySelector('.mapview-legend').innerHTML;
out.thirdScale = v.root.querySelector('.mapview-scale').textContent;
// gone (live.js): Gleba's tab and maps go (its cloud stays a cloud-only switch)
v.set(Object.assign({}, fx.third, { planets: { vulcanus: fx.third.planets.vulcanus }, net_maps: {}, gone: ['gleba'] }));
flush();
out.goneTabs = tabs(v);
out.goneNet = !!v.data.net_maps.gleba;
process.stdout.write(JSON.stringify(out));
"""


def grid(surface, tick, rows):
    return {"surface": surface, "tick": tick, "cell": 8, "x0": 0, "y0": 0, "w": len(rows[0]), "h": len(rows), "rows": rows, "buildings": 4}


def net(surface, tick):
    return {"surface": surface, "tick": tick, "electric": {"poles": 2, "nets": "7,A,2", "cell": 4, "x0": 0, "y0": 0, "w": 4, "h": 1, "rows": ["AAAA"]},
            "logistic": [{"id": 3, "lr": 25, "cr": 55, "n": 1, "ports": "4,4"}], "items": []}


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def node(script, *args):
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "t.js")
        open(js, "w").write(script)
        fx = os.path.join(d, "fx.json")
        json.dump(args[1], open(fx, "w"))
        r = subprocess.run(["node", js, args[0], fx], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    return json.loads(r.stdout)


def main():
    # push_live: every planet's map beside the one in turn while they fit; over the budget, the ones after it in turn
    maps = {n: dict(grid(n, 100 + i, ["AS" * 8] * 4), core={"cell": 1, "x0": 0, "y0": 0, "w": 8, "h": 1, "rows": ["AAAALLLL"]})
            for i, n in enumerate(["aquilo", "fulgora", "gleba", "vulcanus"])}
    push_live._planet_turn["i"] = 1
    listing, one, others = push_live.public_planets(maps)
    check("one in turn", one["surface"] == "fulgora", one)
    check("the others beside it", list(others) == ["gleba", "vulcanus", "aquilo"] and others["gleba"]["core"]["rows"] == ["4A4L"], others)
    each = len(json.dumps(others["gleba"], separators=(",", ":"))) + len("gleba") + 4
    push_live._planet_turn["i"] = 1
    _, _, two = push_live.public_planets(maps, limit=2 * each + 10)
    check("within the budget, in turn", list(two) == ["gleba", "vulcanus"], list(two))
    _, _, none = push_live.public_planets({"gleba": maps["gleba"]})
    check("one planet: no others", none is None)
    state = push_live.public_state({"planet_maps": maps})
    check("the state", set(state["planet_maps"]) | {state["planet_map"]["surface"]} == set(maps) and len(state["planets"]) == 4, state.keys())

    if not shutil.which("node"):
        print("kept maps: push_live ok; pages skipped (no node)")
        return
    t0 = 46_000_000
    pm = lambda n, t: grid(n, t, ["AS"])  # noqa: E731
    lst = lambda *rows: [{"surface": n, "tick": t} for n, t in rows]  # noqa: E731
    cl = {"surface": "gleba", "cells": [[0, 0, 1]], "max": 1}
    before = [
        {"tick": t0, "basemap": {"tick": t0, "rows": ["AA"]}, "clouds": [cl], "planets": lst(("gleba", t0 - 60), ("vulcanus", t0 - 90)), "planet_map": pm("gleba", t0 - 60),
         "planet_maps": {"vulcanus": pm("vulcanus", t0 - 90)}, "net_maps": lst(("gleba", t0 - 30), ("nauvis", t0 - 10)), "net_map": net("gleba", t0 - 30)},
        {"tick": t0 + 600, "planets": lst(("gleba", t0 - 60), ("vulcanus", t0 - 90)), "planet_map": pm("vulcanus", t0 - 90),
         "net_maps": lst(("gleba", t0 - 30), ("nauvis", t0 - 10)), "net_map": net("nauvis", t0 - 10)},
    ]
    restart = {"tick": t0 + 36000, "planets": lst(("aquilo", t0 + 35000)), "planet_map": pm("aquilo", t0 + 35000),
               "net_maps": lst(("aquilo", t0 + 35500)), "net_map": net("aquilo", t0 + 35500)}
    relisted = {"tick": t0 + 40000, "planets": lst(("aquilo", t0 + 35000), ("gleba", t0 + 39000)), "planet_map": pm("gleba", t0 + 39000),
                "net_maps": lst(("aquilo", t0 + 35500))}
    k = node(KEEP_JS, os.path.join(SITE, "static", "live.js"), {"before": before, "restart": restart, "relisted": relisted})
    check("saved", k["saved"] == ["gleba", "vulcanus"] and k["savedLast"] == ["clouds", "home"], k)
    check("a reload during a restart keeps them", k["reload"] == {"planets": ["aquilo", "gleba", "vulcanus"], "nets": ["aquilo", "gleba", "nauvis"], "gone": [],
          "base": t0, "home_held": 600, "clouds": ["gleba"], "clouds_held": 600}, k["reload"])
    check("half an hour unlisted: kept", k["halfHour"]["planets"] == ["aquilo", "gleba", "vulcanus"] and k["halfHour"]["gone"] == [], k["halfHour"])
    check("an hour unlisted: gone", k["hour"]["planets"] == ["aquilo", "gleba"] and sorted(k["hour"]["gone"]) == ["nauvis", "vulcanus"]
          and k["hour"]["nets"] == ["aquilo", "gleba"], k["hour"])
    check("a rollback drops the future", k["rollback"]["planets"] == [] and k["rollback"]["nets"] == [] and k["rollback"]["base"] is None, k["rollback"])
    check("old storage not read", k["stale"]["planets"] == [] and k["stale"]["nets"] == [], k["stale"])

    cloud = {"surface": "gleba", "label": "Gleba spores", "pollutant": "spores", "color": {"r": 0.6, "g": 0.2, "b": 0.6, "a": 1},
             "cells": [[0, 0, 12.5]], "max": 12.5, "age_s": 30}
    base = {"tick": t0, "cell": 16, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AA"]}
    first = {"base": base, "clouds": [cloud], "agents": [], "now_tick": t0 + 60,
             "planets": {"gleba": pm("gleba", t0), "vulcanus": pm("vulcanus", t0)}, "net_maps": {"gleba": net("gleba", t0)},
             "planet_list": lst(("gleba", t0), ("vulcanus", t0)), "net_list": lst(("gleba", t0))}
    second = {"agents": [], "base": base, "clouds": [cloud], "home_held": 300, "clouds_held": 0, "now_tick": t0 + 5 * 3600, "planets": {"vulcanus": pm("vulcanus", t0 + 4 * 3600)}, "net_maps": {},
              "planet_list": lst(("vulcanus", t0 + 4 * 3600)), "net_list": lst(("gleba", t0 + 4 * 3600))}
    third = {"base": dict(base, tick=t0 + 5 * 3600), "clouds": [cloud], "agents": [], "now_tick": t0 + 6 * 3600,
             "planets": {"gleba": pm("gleba", t0 + 5 * 3600), "vulcanus": pm("vulcanus", t0 + 4 * 3600)},
             "net_maps": {"gleba": net("gleba", t0 + 5 * 3600)}, "planet_list": lst(("gleba", t0 + 5 * 3600), ("vulcanus", t0 + 4 * 3600)),
             "net_list": lst(("gleba", t0 + 5 * 3600))}
    v = node(VIEW_JS, os.path.join(SITE, "static", "mapview.js"), {"first": first, "second": second, "third": third})
    check("first tabs", v["firstTabs"] == ["Nauvis", "Gleba", "Vulcanus"], v["firstTabs"])
    check("not held", "kept" not in v["firstScale"], v["firstScale"])
    check("held planet's age on its switch", v["secondTabs"] == ["Nauvis", "Gleba · 5 min old", "Vulcanus"], v["secondTabs"])
    check("Nauvis's basemap kept", v["nauvisDrawn"] and "map from 5 min ago (kept until a newer one arrives)" in v["nauvisScale"], v["nauvisScale"])
    check("Gleba's map kept", "map from 5 min ago (kept until a newer one arrives)" in v["glebaScale"], v["glebaScale"])
    check("Gleba's layers kept", {"cloud", "power", "robots"} <= set(v["glebaLayers"]), v["glebaLayers"])
    check("held networks' age", "read 5 min ago (kept until a newer one arrives)" in v["glebaLegend"], v["glebaLegend"])
    check("held clouds' age", "Spores per chunk, up to 12.5, read 30 s ago (kept until a newer one arrives)" in v["glebaLegend"], v["glebaLegend"])
    check("replaced", v["thirdTabs"] == ["Nauvis", "Gleba", "Vulcanus"] and "kept" not in v["thirdLegend"] and "kept" not in v["thirdScale"],
          (v["thirdTabs"], v["thirdLegend"], v["thirdScale"]))
    check("gone", v["goneTabs"] == ["Nauvis", "Vulcanus", "Gleba spores"] and not v["goneNet"], v["goneTabs"])
    print("kept maps: ok (every planet's map a push; both maps kept across page loads and restarts with their age; a rollback, "
          "an hour unlisted and old storage drop them)")


if __name__ == "__main__":
    main()
