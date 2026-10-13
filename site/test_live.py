#!/usr/bin/env python3
"""The homepage is the live show, and the live payload stays small: python3 site/test_live.py

- push_live.public_state keeps a compact Space Age block (platforms' place or route, no camera views or moments),
  the fights reported in the last two minutes on Nauvis, and each camera's fight / work / segment label;
- the built homepage carries the live app and links to the rest of the site; /about/ has the old homepage, /live/
  still works; check.py passes;
- the map viewer (static/mapview.js scene() under node): framed on the base's core, basemap.core drawn over the coarse
  grid (clipped outside it), an inset of the whole base, an agent far away pinned to the edge; without basemap.core (an
  older stream service) the core comes from the coarse grid; layers on and off (turret range off by default), terrain
  frames placed by their tile edges and only up to the snapshot's tick, hits for hover and tap (agents first), and
  paint() on a recording canvas;
- static/live.js (a stub DOM and a stub viewer): the dashboard's cards are made once and the map gets the basemap,
  agents, fights, alerts and cameras.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
import push_live  # noqa: E402


def payload_tests():
    now = time.time()
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = now
    s["space"] = {"active": True, "rockets": 3, "planets": ["Nauvis"], "summary": "1 platform", "moments": [{"id": "m"}] * 8,
                  "platforms": [{"name": "Solstice", "where": "Nauvis → Vulcanus", "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42},
                                 "state": "on_the_path", "speed_kms": 72, "paused": False,
                                 "view": {"surface": "platform-1", "hub": {"x": 0, "y": 0}, "bounds": {}}}]}
    s["fights"] = [{"key": "area:-48,16", "kind": "attack", "text": "Base under attack near (-48, 16)", "first": now - 30,
                    "last": now - 5, "losses": [now - 10], "position": {"x": -48, "y": 16, "extent": 32.0, "surface": "nauvis"}},
                   {"key": "area:9,9", "kind": "attack", "text": "old", "first": now - 900, "last": now - 600, "losses": [],
                    "position": {"x": 9, "y": 9, "surface": "nauvis"}},
                   {"key": "attack:sol", "kind": "attack", "text": "on a platform", "first": now, "last": now, "losses": [],
                    "position": {"x": 1, "y": 1, "surface": "platform-1"}}]
    s["cameras"] = {"main": {"agents": [], "pair": False, "since": now, "attack": "Base under attack", "zoom": 1.2, "player": 3},
                    "cam3": {"agents": ["sol"], "pair": False, "since": now, "work": "Sol building on Solstice (from the ground)"}}
    out = push_live.public_state(s)
    assert out["space"] == {"rockets": 3, "planets": ["Nauvis"], "summary": "1 platform", "platforms": [
        {"name": "Solstice", "where": "Nauvis → Vulcanus", "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42},
         "state": "on_the_path", "paused": False, "speed_kms": 72}]}, out["space"]
    assert [(f["text"], f["age_s"], f["losses"], f["extent"]) for f in out["fights"]] == [
        ("Base under attack near (-48, 16)", 5, 1, 32.0)], out["fights"]  # recent, on Nauvis only
    assert out["cameras"]["main"] == {"agents": [], "pair": False, "since": now, "attack": "Base under attack"}
    assert out["cameras"]["cam3"]["work"].startswith("Sol building")
    size = len(json.dumps(out["space"]) + json.dumps(out["fights"]) + json.dumps(out["cameras"]))
    assert size < 1500, size  # the map's additions stay a small part of a ~16 KB push
    s["shift"] = {"start": 1, "end": 2, "next": 3, "next_exact": False}
    assert push_live.public_state(s)["shift"] == s["shift"]  # the offline state's "next shift" line
    s2 = dict(s, space={"active": False})
    s2.pop("fights")
    out2 = push_live.public_state(s2)
    assert "space" not in out2 and "fights" not in out2


def build_tests():
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, os.path.join(SITE, "build.py"), "--out", d], check=True, capture_output=True)
        r = subprocess.run([sys.executable, os.path.join(SITE, "check.py"), d], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        home = open(os.path.join(d, "index.html")).read()
        assert 'id="live-app"' in home and "/static/live.js" in home and "/static/avatar.js" in home
        assert home.index('id="live-app"') < home.index('class="home-more"'), "the live show comes first"
        assert 'href="/about/"' in home
        content = os.environ.get("POG_SITE_CONTENT") or os.path.join(SITE, "content", "site.json")  # what build.py read
        archive = json.load(open(content)).get("archive", True)
        for href in ("/experiments/", "/runs/", "/studies/"):  # the test history, only with the archive switch on
            assert (f'href="{href}"' in home) == archive, href
        about = open(os.path.join(d, "about", "index.html")).read()
        assert "Fair-play rules" in about and 'id="team"' in about
        assert 'id="live-app"' in open(os.path.join(d, "live", "index.html")).read()


LIVE_JS = r"""
// static/live.js in a stub DOM with a stub map viewer, sample mode, on the state in argv[3]; prints what it drew
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function cls() { const s = new Set(); return { add: (c) => s.add(c), remove: (c) => s.delete(c), toggle: (c, on) => (on ? s.add(c) : s.delete(c)), contains: (c) => s.has(c) }; }
const kids = {};
// the cards' parts exist once made; any other selector gets an element
const find = (s) => kids[s] || (/^#(cb-|map-|mm)/.test(s) ? null : (kids[s] = el(s)));
function el(name) {
  const e = { name, dataset: {}, textContent: '', value: '', hidden: false, classList: cls(), attrs: {}, _html: '',
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {},
    querySelector: (s) => find(s), querySelectorAll: () => [], scrollTop: 0, scrollHeight: 0 };
  // ids in assigned HTML become elements, as a browser would make them
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = v; for (const m of String(v).matchAll(/id="([\w-]+)"/g)) kids['#' + m[1]] = kids['#' + m[1]] || el(m[1]); } });
  return e;
}
for (const id of ['dash', 'strip', 'alerts', 'run-title', 'run-sub', 'updated', 'next-shift', 'offline', 'live-badge']) kids['#' + id] = el(id);
const app = el('app');
app.querySelector = find;
app.dataset = { api: '', status: '/live/status.json', poll: '10', video: '', channel: '' };
global.window = global;
global.addEventListener = () => {};
global.requestAnimationFrame = (f) => setImmediate(f);
global.document = { getElementById: (id) => (id === 'live-app' ? app : kids['#' + id] || null), hidden: false, documentElement: { dataset: {} },
  addEventListener() {}, querySelector: () => null };
global.matchMedia = () => ({ matches: true });
global.location = { search: '?demo=1', hostname: 'localhost' };
global.localStorage = { getItem: () => null, setItem: () => {} };
global.PogAvatar = { svg: () => '<svg/>' };
const made = [], sets = [];
global.PogMap = { create: (host, opts) => { made.push({ host: host.name, opts }); return { set: (d) => sets.push(d) }; } };
global.fetch = (url) => Promise.resolve({ ok: true, json: () => Promise.resolve(url.indexOf('state') >= 0 ? state : { schema: 1 }) });
require(process.argv[2]);
setTimeout(() => process.stdout.write(JSON.stringify({ dash: kids['#dash'].innerHTML, made, sets,
  agents: (kids['#cb-agents'] || {}).innerHTML, cams: (kids['#map-cams'] || {}).innerHTML })), 300);
"""

SCENE_JS = r"""
// static/mapview.js's pure part under node: prepare(), scene(), hitAt(), paint() on the data in argv[3]
const fs = require('fs');
global.window = global;
require(process.argv[2]);
const M = global.PogMap, data = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const out = {};
function summary(sc) {
  return { span: sc.span, clip: !!sc.clip, core: !!sc.core, base: !!sc.base, inset: !!sc.inset, far: sc.far, coverage: sc.coverage.length,
    terrain: sc.terrain, nests: sc.nests.length, agents: sc.agents.map((a) => ({ name: a.name, far: a.far, x: a.x, y: a.y, label: !!a.label })),
    attention: sc.attention.length, fights: sc.fights.length, pins: sc.pins.length, step: sc.grid.step };
}
const d = M.prepare(data.full);
out.full = summary(M.scene(d, null, 400, 400));
out.allOn = summary(M.scene(d, null, 400, 400, Object.fromEntries(M.LAYERS.map((l) => [l[0], true]))));
out.allOff = summary(M.scene(d, null, 400, 400, Object.fromEntries(M.LAYERS.map((l) => [l[0], false]))));
out.old = summary(M.scene(M.prepare(data.old), null, 400, 400));
// a 600 x 300 full-screen canvas on a fixed view: the span is across the shorter side
const wide = M.scene(d, { cx: 40, cy: 30, span: 100 }, 600, 300, Object.fromEntries(M.LAYERS.map((l) => [l[0], true])));
out.wide = summary(wide);
const sc = M.scene(d, { cx: 40, cy: 30, span: 100 }, 400, 400);
const ag = sc.agents.find((a) => !a.far);
out.hitAgent = M.hitAt(sc, ag.x + 3, ag.y - 2);
const nest = sc.nests[0];
out.hitNest = nest ? M.hitAt(sc, nest.x, nest.y) : null;
out.hitNone = M.hitAt(sc, 1, 1);
// paint on a recording canvas: every call counted, terrain images drawn where scene() put them
const calls = {};
const ctx = new Proxy({}, { get: (t, k) => (k in t ? t[k] : (...args) => { (calls[k] = calls[k] || []).push(args); }), set: (t, k, v) => { t[k] = v; return true; } });
M.paint(ctx, wide, (src) => ({ width: 1280, height: 720, src }), 'sans-serif', null);
out.paint = { drawImage: (calls.drawImage || []).map((c) => c.slice(1).map((n) => Math.round(n))), fill: (calls.fill || []).length,
  fillText: (calls.fillText || []).map((c) => c[0]), rect: (calls.rect || []).length, arc: (calls.arc || []).length };
const t0 = Date.now();
for (let i = 0; i < 60; i++) M.paint(ctx, M.scene(d, { cx: 40 + i, cy: 30, span: 100 + i }, 400, 400), () => null, 'sans-serif', null);
out.ms_per_frame = (Date.now() - t0) / 60;
process.stdout.write(JSON.stringify(out));
"""


def map_state(core=True):
    """The sample state with a made-up base: a dense block, a 400-tile pipeline north to pumpjacks, and (core) the
    block at 1 tile a cell with rails, inserters and logistics."""
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    rows = ["AASS.MM.EE" * 2 for _ in range(16)]  # 80 x 64 tiles of buildings at 4 tiles a cell
    rows = ["" for _ in range(100)] + rows  # 400 tiles of nothing north of it, but for the pipeline
    for r in range(100):
        rows[r] = "P"
    rows[0] = "MMM"
    bm = {"tick": 1, "cell": 4, "x0": 0, "y0": -400, "w": 20, "h": len(rows), "rows": rows, "nests": [[90, 10, "s"]],
          "buildings": 900, "turrets": [[10, 10, 18], [20, 10, 18], [70, 60, 30]]}
    if core:
        bm["core"] = {"cell": 1, "x0": -8, "y0": -8, "w": 96, "h": 80,
                      "rows": ["AAA.SS.II.BBBB.TTTT.LL.EE.PP.MMM.RR.DD" * 2 for _ in range(80)]}
    s["basemap"] = bm
    for a in s.get("agents", []):
        a["position"] = {"x": 30, "y": 30}
    s["agents"][0]["position"] = {"x": 2, "y": -390}  # at the pumpjacks: off the core view, pinned to the edge
    s["agents"][1]["attention"] = {"position": {"x": 60, "y": 50}, "text": "inspecting a furnace", "dist": 36, "far": True}
    return s


def viewer_data(s):
    """What live.js mapData() gives the viewer, plus terrain frames: one in view, one from after the snapshot."""
    bm = s["basemap"]
    return {"base": bm, "core": bm.get("core"), "ore": bm.get("ore"), "nests": bm.get("nests"), "turrets": bm.get("turrets"),
            "terrain": [{"src": "/live/terrain/a.webp", "x0": 0, "y0": 0, "x1": 64, "y1": 36, "tick": 1},
                        {"src": "/live/terrain/later.webp", "x0": 0, "y0": 0, "x1": 64, "y1": 36, "tick": 99},
                        {"src": "javascript:alert(1)", "x0": 0, "y0": 0, "x1": 64, "y1": 36, "tick": 1}],
            "tick": 5, "agents": s["agents"], "fights": [], "pins": s.get("alerts") or [], "cams": s.get("cameras") or {}}


def map_tests():
    if not shutil.which("node"):
        print("map: skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "scene.js")
        open(js, "w").write(SCENE_JS)
        path = os.path.join(d, "data.json")
        json.dump({"full": viewer_data(map_state(True)), "old": viewer_data(map_state(False))}, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), path], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
        full = o["full"]
        assert 90 <= full["span"] <= 200, full["span"]  # framed on the core (96 x 80 tiles and the sample's alerts), not the 500-tile extent
        assert full["clip"] and full["core"] and full["base"], "the fine core over the coarse grid, clipped outside it"
        assert full["inset"], "the inset shows the whole base (the pipeline makes it 5 times the view)"
        astra = full["agents"][0]
        assert astra["far"] and list(full["far"]) == [astra["name"]] and full["far"][astra["name"]] > 300, full["far"]
        assert full["coverage"] == 0 and o["allOn"]["coverage"] == 3, "turret range: off by default, three turrets when on"
        assert full["nests"] == 1 and full["attention"] == 1
        # terrain: only frames up to the snapshot's tick, only site paths, placed by their tile edges
        assert [t["src"] for t in full["terrain"]] == ["/live/terrain/a.webp"], full["terrain"]
        off = o["allOff"]
        assert not off["base"] and off["agents"] == [] and off["terrain"] == [] and off["nests"] == 0 and off["attention"] == 0
        wide = o["wide"]  # 600 x 300 at 100 tiles across the short side: 3 px a tile, tile (40, 30) at the centre
        t = wide["terrain"][0]
        assert (round(t["x"]), round(t["y"]), round(t["w"]), round(t["h"])) == (180, 60, 192, 108), t
        assert o["paint"]["drawImage"] == [[180, 60, 192, 108]], o["paint"]["drawImage"]
        assert o["paint"]["fill"] > 10 and o["paint"]["arc"] >= 3 and any(x.startswith("Sol") or x.startswith("Grok") or x for x in o["paint"]["fillText"])
        assert o["hitAgent"] and o["hitAgent"]["agent"] and "·" in o["hitAgent"]["text"], o["hitAgent"]
        assert o["hitNone"] is None
        assert o["ms_per_frame"] < 50, o["ms_per_frame"]  # scene + paint of an 80 x 96 core, well under a frame budget even in node
        old = o["old"]  # an older stream service without basemap.core: the core framed from the coarse grid
        assert not old["clip"] and old["inset"] and 70 <= old["span"] <= 200, old

        js = os.path.join(d, "live.js")
        open(js, "w").write(LIVE_JS)
        spath = os.path.join(d, "state.json")
        json.dump(map_state(True), open(spath, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), spath], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        lv = json.loads(r.stdout)
        assert lv["dash"].count('class="fx-panel live-card') == 6 and 'id="cb-map"' in lv["dash"]
        assert len(lv["made"]) == 1 and lv["made"][0]["host"] == "mm", lv["made"]  # one viewer, kept across refreshes
        got = lv["sets"][-1]
        assert got["base"]["rows"] and got["core"]["cell"] == 1 and len(got["turrets"]) == 3 and got["nests"] == [[90, 10, "s"]]
        assert [a["name"] for a in got["agents"]] == [a["name"] for a in map_state(True)["agents"]] and "cams" in got
        assert "agent-live" in lv["agents"]


def main():
    payload_tests()
    build_tests()
    map_tests()
    print("site live: ok (compact space, fights and camera labels; homepage is the live show; about and /live/ kept)")


if __name__ == "__main__":
    main()
