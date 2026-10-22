#!/usr/bin/env python3
"""Why a map layer is disabled: missing data or a real zero (d22 batch75 AK10, viewer Aurora site:4283: "Could disabled map
layers distinguish missing data from a real zero? Vulcanus currently labels unavailable power and logistics overlays as
'none', which is easy to misread."): python3 site/test_layerwhy.py

static/mapview.js absentWhy(data, d, layer) under node, for each layer:
- Power, Logistics and the item picker: "not read" when the live state lists no networks map of the planet (naming the
  planets it has), "not read yet" when it lists one this page has not had, "not read" with no listing at all; "none"
  only from a networks map read with no electric network, no logistic network, no item;
- Buildings on a planet: "none" when its map was read with no building, else not read (listed or not);
- terrain, ore, turrets, turret state, nests, fights: "not read: ... on Nauvis only" on another planet; on Nauvis with no
  base map "not read", with one "none" from the base read;
- Pollution: "not read" (the read covers the surfaces an agent is on), naming those it has;
- Blueprints: "none" when library areas were read, "not read" when the state has none; agents and attention: "none".
And the toolbar's tooltips on Vulcanus with Nauvis's networks map only (the case Aurora saw).
"""
import json, os, shutil, subprocess, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))

JS = r"""
global.window = global;
global.document = { createElement: () => ({}), addEventListener() {} };
global.addEventListener = () => {};
global.localStorage = { getItem: () => null, setItem: () => {} };
require(process.argv[2]);
const M = global.PogMap;
const grid = (rows) => ({ cell: 8, x0: 0, y0: 0, w: rows[0] ? rows[0].length : 0, h: rows.length, rows });
const net = (surface, tick, electric, logistic, items) => ({ surface, tick,
  electric: electric ? { poles: 2, nets: '7,A,2', cell: 4, x0: 0, y0: 0, w: 2, h: 1, rows: ['AA'] } : { poles: 0, nets: '', cell: 4, x0: 0, y0: 0, w: 0, h: 0, rows: [] },
  logistic: logistic ? [{ id: 3, lr: 25, cr: 55, n: 1, ports: '4,4' }] : [], items: items ? [['iron-plate', 'A,3,1,0,0,4,4']] : [] });
const base = { cell: 16, x0: 0, y0: 0, w: 1, h: 1, rows: ['A'] };
const why = (data, layers) => { const d = M.prepare(M.unpackData(data)); const o = {}; layers.forEach((k) => { o[k] = M.absentWhy(data, d, k); }); return o; };
const NETS = ['power', 'robots', 'item'];
const out = {};
// Vulcanus: the state lists networks maps of other planets only (live, d22 14:06)
out.unlisted = why({ surface: 'vulcanus', base, net_list: [{ surface: 'nauvis', tick: 5 }, { surface: 'gleba', tick: 6 }], net_maps: {}, now_tick: 100 }, NETS);
// listed, not had yet
out.listed = why({ surface: 'vulcanus', base, net_list: [{ surface: 'vulcanus', tick: 7 }], net_maps: {}, now_tick: 100 }, NETS);
// no listing at all
out.nolist = why({ surface: 'vulcanus', base, net_maps: {}, now_tick: 100 }, NETS);
// a networks map read: no electric network, no logistic network, no items: none
out.zero = why({ surface: 'vulcanus', base, net_list: [{ surface: 'vulcanus', tick: 3600 }], net_maps: { vulcanus: net('vulcanus', 3600, false, false, false) }, now_tick: 7200 }, NETS);
// a planet's buildings: read with none, listed, not listed
out.bzero = why({ surface: 'vulcanus', planets: { vulcanus: grid([]) }, planet_list: [{ surface: 'vulcanus', tick: 1 }] }, ['buildings']);
out.blisted = why({ surface: 'vulcanus', planets: {}, planet_list: [{ surface: 'vulcanus', tick: 1 }] }, ['buildings']);
out.bnone = why({ surface: 'vulcanus', planets: {}, planet_list: [] }, ['buildings']);
const NAUVIS_ONLY = ['terrain', 'ore', 'coverage', 'readiness', 'nests', 'alerts'];
out.away = why({ surface: 'vulcanus', planets: {} }, NAUVIS_ONLY);
out.homeNoBase = why({}, NAUVIS_ONLY.concat(['buildings']));
out.homeBase = why({ base }, ['coverage', 'nests', 'alerts']);
out.cloud = why({ surface: 'vulcanus', clouds: [{ surface: 'nauvis', cells: [[0, 0, 1]] }, { surface: 'gleba', cells: [[0, 0, 1]] }] }, ['cloud']);
out.libRead = why({ surface: 'vulcanus', library_areas: [], library_read: true }, ['library']);
out.libNot = why({ surface: 'vulcanus', library_areas: [], library_read: false }, ['library']);
out.team = why({ surface: 'vulcanus' }, ['agents', 'attention']);
// the toolbar on Vulcanus with Nauvis's networks map only: the tooltips
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
const v = M.create(el('host'), { storeKey: 'w' });
v.set({ base, planets: { vulcanus: grid(['AA']) }, planet_list: [{ surface: 'vulcanus', tick: 1 }], net_list: [{ surface: 'nauvis', tick: 5 }],
  net_maps: { nauvis: net('nauvis', 5, true, true, true) }, now_tick: 100 });
v.onClick({ target: { closest: () => ({ dataset: { surface: 'vulcanus' } }) } });
out.titles = [...v.root.querySelector('.mapview-layers').innerHTML.matchAll(/title="([^"]+)"/g)].map((m) => m[1]);
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def main():
    if not shutil.which("node"):
        print("layer why: skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js")], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    for k in ("power", "robots", "item"):
        check(f"{k}: not read, the planets it has", o["unlisted"][k] == "not read: the game has made no networks map of Vulcanus (it has: Nauvis, Gleba)", o["unlisted"][k])
        check(f"{k}: listed, not had yet", o["listed"][k].startswith("not read yet: a networks map of Vulcanus is listed (game tick 7)"), o["listed"][k])
        check(f"{k}: no listing", o["nolist"][k] == "not read: no networks maps in the live state yet", o["nolist"][k])
    check("power: none from a read", o["zero"]["power"] == "none: the networks map of Vulcanus (read 1 min ago) has no electric network", o["zero"]["power"])
    check("robots: none from a read", o["zero"]["robots"].startswith("none: ") and "no logistic network" in o["zero"]["robots"], o["zero"]["robots"])
    check("item: none from a read", o["zero"]["item"].startswith("none: ") and "no item source or consumer" in o["zero"]["item"], o["zero"]["item"])
    check("buildings: none from a read", o["bzero"]["buildings"] == "none: the map of Vulcanus read shows no building of ours", o["bzero"])
    check("buildings: listed", o["blisted"]["buildings"].startswith("not read yet:"), o["blisted"])
    check("buildings: not in the state", o["bnone"]["buildings"] == "not read: no map of Vulcanus in the live state", o["bnone"])
    check("Nauvis only, elsewhere", all(v.startswith("not read: ") and v.endswith("read on Nauvis only") for v in o["away"].values())
          and o["away"]["terrain"] == "not read: terrain is read on Nauvis only" and o["away"]["nests"] == "not read: nests are read on Nauvis only", o["away"])
    check("Nauvis without a base map: not read", all(v.startswith("not read") for k, v in o["homeNoBase"].items() if k != "alerts"), o["homeNoBase"])
    check("Nauvis with a base map: none from it", o["homeBase"]["coverage"] == "none: the base read lists no turret"
          and o["homeBase"]["nests"].startswith("none: the base read") and o["homeBase"]["alerts"].startswith("none: "), o["homeBase"])
    check("pollution: not read, what it covers", o["cloud"]["cloud"] == "not read: the last pollution read has no row for Vulcanus (it reads the surfaces an agent is on; it has: Nauvis, Gleba)", o["cloud"])
    check("blueprints: none when read, not read when not", o["libRead"]["library"].startswith("none: ") and o["libNot"]["library"].startswith("not read: "), (o["libRead"], o["libNot"]))
    check("agents and attention: none", all(v.startswith("none: ") for v in o["team"].values()), o["team"])
    t = o["titles"]
    check("Vulcanus tooltips: not read, never none", "Power networks: not read: the game has made no networks map of Vulcanus (it has: Nauvis)" in t
          and "Logistic networks: not read: the game has made no networks map of Vulcanus (it has: Nauvis)" in t
          and "Item: not read: the game has made no networks map of Vulcanus (it has: Nauvis)" in t and not any(": none on" in x for x in t), t)
    print("layer why: ok (each disabled layer says not read and why, or none where a read says zero; Vulcanus's power and "
          "logistics: not read, naming the planets with a networks map)")


if __name__ == "__main__":
    main()
