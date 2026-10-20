#!/usr/bin/env python3
"""Turret readiness on the live map (d20 batch50 G1, viewer Aurora, shift46 inbox 09:09): python3 site/test_turretmap.py

static/mapview.js under node: basemap.turret_state (tools/stream/turretstate.py) gives the "Turret state" layer (on by
default): a marker at each turret that is empty, without power or unknown, a tip naming the turret, its state and how
long ago it was read (from the state's game tick), and a legend with the counts per state. Without turret_state the
layer is not offered.
"""
import json, os, shutil, subprocess, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
const fs = require('fs');
const fx = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function el(name) {
  const e = { name, dataset: {}, textContent: '', hidden: false, style: {}, attrs: {}, kids: {}, _html: '', clientWidth: 400, clientHeight: 400,
    classList: { s: new Set(), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); } },
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {}, appendChild() {},
    querySelector(s) { return this.kids[s] || (this.kids[s] = el(s)); }, getContext() { return ctx; } };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = String(v); } });
  return e;
}
const noop = new Proxy(function () {}, { get: (t, k) => (k === 'width' ? 10 : noop), apply: () => noop, set: () => true });
const ctx = noop;
global.window = global;
global.document = { createElement: (t) => el(t), addEventListener() {}, fullscreenElement: null };
global.addEventListener = () => {};
global.getComputedStyle = () => ({ fontFamily: 'x' });
global.localStorage = { getItem: () => null, setItem: () => {} };
global.Image = function () {};
global.requestAnimationFrame = () => 0;
require(process.argv[2]);
const M = global.PogMap, out = {};
const on = Object.fromEntries(M.LAYERS.map((l) => [l[0], M.DEFAULT_ON[l[0]]]));
const d = M.prepare(fx.with);
const sc = M.scene(d, { cx: 50, cy: 0, span: 200 }, 400, 400, on);
out.ready = sc.ready.map((m) => m.st);
out.tips = sc.ready.map((m) => (M.hitAt(sc, m.x, m.y) || {}).text);
out.off = M.scene(d, { cx: 50, cy: 0, span: 200 }, 400, 400, Object.assign({}, on, { readiness: false })).ready.length;
const v = M.create(el('host'), {});
v.set(fx.with);
out.layers = v.root.querySelector('.mapview-layers').innerHTML;
out.legend = v.root.querySelector('.mapview-legend').innerHTML;
const v2 = M.create(el('host2'), {});
v2.set(fx.without);
out.layersWithout = v2.root.querySelector('.mapview-layers').innerHTML;
process.stdout.write(JSON.stringify(out));
"""


def main():
    if not shutil.which("node"):
        print("turret map: skipped (no node)")
        return
    base = {"cell": 8, "x0": 0, "y0": -8, "w": 12, "h": 2, "rows": ["DDDDDDDDDDDD", "DDDD"],
            "turrets": [[2, 2, 18], [40, 3, 18], [70, 4, 24], [60, 6, 18]]}
    ts = {"as_of": 36000000, "every_s": 60, "counts": {"armed": 1, "empty": 1, "no_power": 1, "unknown": 2},
          "flagged": [[40, 3, "e", "gun-turret", 20], [70, 4, "p", "laser-turret", 5], [60, 6, "u", "gun-turret", 200],
                      [90, 1, "u", None, None]]}
    with_ = {"base": dict(base, turret_state=ts), "turrets": base["turrets"], "agents": [], "now_tick": 36000000 + 40 * 60}
    without = {"base": base, "turrets": base["turrets"], "agents": []}
    with tempfile.TemporaryDirectory() as d:
        fx = os.path.join(d, "fx.json")
        json.dump({"with": with_, "without": without}, open(fx, "w"))
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    assert o["ready"] == ["e", "p", "u", "u"], o["ready"]
    assert o["tips"] == ["Gun turret: empty (no ammo, shells or fluid) (read 60 s ago)",
                         "Laser turret: no power (less than one shot's energy) (read 45 s ago)",
                         "Gun turret: unknown (last read 4 min ago)", "Turret: unknown (never read)"], o["tips"]
    assert o["off"] == 0
    assert 'data-layer="readiness" aria-pressed="true">Turret state<' in o["layers"], o["layers"]
    assert "Turrets: 1 armed, 1 empty, 1 no power" in o["legend"] and "2 unknown (not read since the last refresh, every 60 s; newest reading 40 s ago)" in o["legend"], o["legend"]
    assert 'data-layer="readiness"' not in o["layersWithout"], o["layersWithout"]
    print("turret map: ok (turrets that cannot fire or are unknown marked, with what and how old; counts in the legend)")


if __name__ == "__main__":
    main()
