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
    s["agents"][1].update(surface="vulcanus", where="Vulcanus", on_platform=False, travel=None)
    out = push_live.public_state(s)
    sol = out["agents"][1]
    assert (sol["surface"], sol["where"], sol["on_platform"], sol["travel"]) == ("vulcanus", "Vulcanus", False, None), sol
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
    # YouTube's "watching now" (viewers.py): passed on while fresh; unknown (None), stale or odd values left out
    yt = {"state": "live", "video": "liI0JzKylGc", "watching": 40, "watching_t": now - 39, "watching_error": None}
    w = push_live.public_state(dict(s, viewers_status={"youtube": yt}))
    assert w["watching"] == {"youtube": 40, "t": round(now - 39)} and w["stream"]["youtube_video_id"] == "liI0JzKylGc", w
    for bad in ({"watching": None}, {"watching_t": now - 400}, {"watching": True}, {"watching": "40"}, {"watching": -1}):
        assert "watching" not in push_live.public_state(dict(s, viewers_status={"youtube": dict(yt, **bad)})), bad
    assert "watching" not in push_live.public_state(s)
    # the joined chat pane's YouTube lines (eng/sitechat2): from the viewer lane, YouTube only, the site's hidden lines out
    import moderation
    h = moderation.Hidden()
    h.names.add("spammer")
    lane = [{"id": "yt:1", "source": "youtube", "name": "Joonazan", "text": "no biters on Gleba", "t": now - 30, "checked": "clef"},
            {"id": "s:2", "source": "site", "name": "bo", "text": "site line", "t": now - 20},
            {"id": "yt:3", "source": "youtube", "name": "Spammer", "text": "buy", "t": now - 10},
            {"id": "yt:4", "source": "youtube", "name": "mod", "text": "hi", "t": now - 5, "staff": True}]
    yt = push_live.public_youtube(lane, h)
    assert yt == [{"id": "yt:1", "name": "Joonazan", "text": "no biters on Gleba", "t": round(now - 30, 1)},
                  {"id": "yt:4", "name": "mod", "text": "hi", "t": round(now - 5, 1), "staff": True}], yt
    many = [dict(lane[0], id=f"yt:{i}", t=now + i) for i in range(push_live.YOUTUBE_MAX + 5)]
    assert [r["id"] for r in push_live.public_youtube(many)][0] == "yt:5"  # the newest kept, oldest first
    assert push_live.public_state(dict(s, viewers=lane))["youtube_chat"][0]["name"] == "Joonazan"


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
// static/live.js in a stub DOM with a stub map viewer, on the state in argv[3]; prints what it drew. argv[4]: sample
// mode (default), "live" (an API whose state is 4 s old, 3 pages on the site) or "stale" (10 min old)
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const mode = process.argv[4] || 'demo';
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
for (const id of ['dash', 'strip', 'alerts', 'run-title', 'run-sub', 'updated', 'next-shift', 'offline', 'live-badge', 'watching']) kids['#' + id] = el(id);
kids['#watching'].hidden = true;
const app = el('app');
app.querySelector = find;
app.dataset = { api: mode === 'demo' ? '' : 'https://api.test', status: '/live/status.json', poll: '10', video: '', channel: '' };
global.window = global;
global.addEventListener = () => {};
global.requestAnimationFrame = (f) => setImmediate(f);
global.document = { getElementById: (id) => (id === 'live-app' ? app : kids['#' + id] || null), hidden: false, documentElement: { dataset: {} },
  addEventListener() {}, querySelector: () => null };
global.matchMedia = () => ({ matches: true });
global.location = { search: mode === 'demo' ? '?demo=1' : '', hostname: 'localhost' };
global.localStorage = { getItem: () => null, setItem: () => {} };
global.PogAvatar = { svg: () => '<svg/>' };
const made = [], sets = [];
global.PogMap = { create: (host, opts) => { made.push({ host: host.name, opts }); return { set: (d) => sets.push(d) }; } };
const posts = [];
const reply = (body) => Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
global.fetch = (url, opts) => {
  if (opts && opts.method === 'POST') { posts.push({ url, type: opts.headers['Content-Type'], body: JSON.parse(opts.body) }); return reply({ ok: true }); }
  if (mode !== 'demo' && url.indexOf('/v1/state') >= 0) return reply({ schema: 1, received: Date.now() / 1000, age_s: mode === 'stale' ? 600 : 4, state, site_watching: 3 });
  return reply(url.indexOf('state') >= 0 ? state : { schema: 1 });
};
require(process.argv[2]);
setTimeout(() => process.stdout.write(JSON.stringify({ dash: kids['#dash'].innerHTML, made, sets,
  agents: (kids['#cb-agents'] || {}).innerHTML, cams: (kids['#map-cams'] || {}).innerHTML, board: (kids['#cb-board'] || {}).innerHTML,
  watching: { text: kids['#watching'].textContent, hidden: kids['#watching'].hidden }, posts,
  vchat: (kids['#vchat'] || {}).innerHTML }), () => process.exit(0)), 300);
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
    attention: sc.attention.length, fights: sc.fights.length, pins: sc.pins.length, step: sc.grid.step,
    away: sc.away.map((a) => [a.text, Math.round(a.x), Math.round(a.y)]) };
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
const fills = [];  // the compositing state at each fill()
const ctx = new Proxy({}, { get: (t, k) => (k in t ? t[k] : (...args) => {
  (calls[k] = calls[k] || []).push(args);
  if (k === 'fill') fills.push([t.globalCompositeOperation || 'source-over', t.globalAlpha == null ? 1 : t.globalAlpha, t.fillStyle]);
}), set: (t, k, v) => { t[k] = v; return true; } });
M.paint(ctx, wide, (src) => ({ width: 1280, height: 720, src }), 'sans-serif', null);
out.paint = { drawImage: (calls.drawImage || []).map((c) => c.slice(1).map((n) => Math.round(n))), fill: (calls.fill || []).length,
  fillText: (calls.fillText || []).map((c) => c[0]), rect: (calls.rect || []).length, arc: (calls.arc || []).length,
  terrainFills: fills.slice(0, 2) };
const t0 = Date.now();
for (let i = 0; i < 60; i++) M.paint(ctx, M.scene(d, { cx: 40 + i, cy: 30, span: 100 + i }, 400, 400), () => null, 'sans-serif', null);
out.ms_per_frame = (Date.now() - t0) / 60;
// the cloud layer: Nauvis's pollution under the base; Gleba's spores on their own (no base, the agents on Gleba)
const dn = M.prepare(Object.assign({}, data.full, { clouds: data.clouds }));
const scn = M.scene(dn, { cx: 40, cy: 30, span: 100 }, 400, 400);
out.nauvis = { cells: scn.cloud.cells, base: !!scn.base, off: M.scene(dn, { cx: 40, cy: 30, span: 100 }, 400, 400,
  Object.fromEntries(M.LAYERS.map((l) => [l[0], l[0] !== 'cloud']))).cloud, hit: M.cloudHit(dn, 40, 40), miss: M.cloudHit(dn, 500, 500) };
const dg = M.prepare(Object.assign({}, data.gleba, { clouds: data.clouds, surface: 'gleba' }));
const scg = M.scene(dg, null, 400, 400);
out.gleba = Object.assign(summary(scg), { cells: scg.cloud.cells.length, auto: dg.auto, reached: scg.cloud.reached.length,
  hitNest: M.hitAt(scg, scg.cloud.reached[0].x, scg.cloud.reached[0].y), hit: M.cloudHit(dg, -200, -130) });
const calls2 = [];
M.paint(new Proxy({}, { get: (t, k) => (k in t ? t[k] : (...a) => calls2.push([k, t.fillStyle, ...a])), set: (t, k, v) => { t[k] = v; return true; } }),
  scg, () => null, 'sans-serif', null);
out.gleba.paintCells = calls2.filter((c) => c[0] === 'fillRect' && String(c[1]).startsWith('rgba(140, 140, 0,')).length;
process.stdout.write(JSON.stringify(out));
"""


# the stream's clouds (tools/stream/clouds.py): pollution east of the sample base, spores on Gleba with a nest reached
CLOUDS = [{"surface": "nauvis", "label": "Pollution on Nauvis", "pollutant": "pollution", "max": 40,
           "color": {"r": 0.549, "g": 0, "b": 0, "a": 0.584}, "cells": [[1, 1, 20], [2, 1, 40], [9, 9, 3]]},
          {"surface": "gleba", "label": "Spores on Gleba", "pollutant": "spores", "max": 15.5,
           "color": {"r": 0.549, "g": 0.549, "b": 0, "a": 0.584}, "cells": [[-7, -5, 14.7], [-6, -5, 15.5], [-6, -4, 1.2]],
           "reached": [{"x": -170, "y": -150}]}]


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
    # off Nauvis: Luna on Vulcanus (its coordinates are Vulcanus's), Opus aboard a platform, Grok in a cargo pod
    s["agents"][2].update(surface="vulcanus", where="Vulcanus", position={"x": 5000, "y": -3000})
    s["agents"][3].update(surface="platform-1", where="Solstice", on_platform=True, position={"x": 0, "y": 0})
    s["agents"][6].update(surface="nauvis", travel="descending", location="cargo pod to Nauvis")
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
        gleba = viewer_data(map_state(True))
        gleba["agents"] = [dict(a) for a in gleba["agents"]]
        gleba["agents"][4].update(surface="gleba", where="Gleba", position={"x": -190, "y": -120})
        json.dump({"full": viewer_data(map_state(True)), "old": viewer_data(map_state(False)), "gleba": gleba,
                   "clouds": CLOUDS}, open(path, "w"))
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
        # agents off Nauvis are listed in the corner, never drawn on the map nor framing it
        names = [a["name"] for a in full["agents"]]
        assert "luna" not in names and "opus" not in names and "grok" not in names and "sol" in names, names
        away = [a[0] for a in full["away"]]
        assert away[:2] == ["Luna · Vulcanus", "Opus · Solstice (platform)"] and len(away) == 3, away
        assert away[2].startswith("Grok") and away[2].endswith(" · cargo pod to Nauvis"), away  # its display name
        assert full["away"][0][1:] == [8, 386] and full["away"][1][2] == 366, full["away"]
        assert o["allOff"]["away"] == []
        # terrain: only frames up to the snapshot's tick, only site paths, placed by their tile edges
        assert [t["src"] for t in full["terrain"]] == ["/live/terrain/a.webp"], full["terrain"]
        off = o["allOff"]
        assert not off["base"] and off["agents"] == [] and off["terrain"] == [] and off["nests"] == 0 and off["attention"] == 0
        wide = o["wide"]  # 600 x 300 at 100 tiles across the short side: 3 px a tile, tile (40, 30) at the centre
        t = wide["terrain"][0]
        assert (round(t["x"]), round(t["y"]), round(t["w"]), round(t["h"])) == (180, 60, 192, 108), t
        assert o["paint"]["drawImage"] == [[180, 60, 192, 108]], o["paint"]["drawImage"]
        # terrain is a background: part desaturated (a grey 'saturation' blend), then dimmed toward the ground colour
        assert o["paint"]["terrainFills"] == [["saturation", 0.6, "#808080"], ["source-over", 0.45, "#1b1f1a"]], o["paint"]["terrainFills"]
        assert o["paint"]["fill"] > 10 and o["paint"]["arc"] >= 3 and any(x.startswith("Sol") or x.startswith("Grok") or x for x in o["paint"]["fillText"])
        assert o["hitAgent"] and o["hitAgent"]["agent"] and "·" in o["hitAgent"]["text"], o["hitAgent"]
        assert o["hitNone"] is None
        assert o["ms_per_frame"] < 50, o["ms_per_frame"]  # scene + paint of an 80 x 96 core, well under a frame budget even in node
        old = o["old"]  # an older stream service without basemap.core: the core framed from the coarse grid
        assert not old["clip"] and old["inset"] and 70 <= old["span"] <= 200, old
        # the cloud layer (viewer Joonazan, 13:00): Nauvis's two chunks in view under the base, 4 px a tile, stronger
        # where there is more; off with its layer; the amount of the chunk under the pointer
        n = o["nauvis"]
        assert n["base"] and [(round(c["x"]), round(c["y"]), round(c["s"])) for c in n["cells"]] == [(168, 208, 128), (296, 208, 128)], n["cells"]
        assert n["cells"][0]["a"] < n["cells"][1]["a"] == 0.584 and n["off"] is None, n
        assert n["hit"]["text"] == "Pollution 20 in chunk (1, 1), tiles 32..63, 32..63" and n["miss"] is None, n["hit"]
        g = o["gleba"]  # Gleba: no base, ore, nests or fights; its cloud framed, the agent on Gleba drawn, the rest listed
        assert not g["base"] and g["nests"] == 0 and g["fights"] == 0 and g["cells"] == 3 and g["reached"] == 1, g
        assert [a["name"] for a in g["agents"]] == ["sonnet"] and len(g["away"]) == 8, (g["agents"], g["away"])
        assert g["away"][0][0] == "Astra · Nauvis" and g["away"][2][0] == "Luna · Vulcanus", g["away"]
        assert -232 <= g["auto"]["cx"] <= -150 and g["hitNest"]["text"] == "Enemy nest the spores reached", g
        assert g["hit"]["text"].startswith("Spores 14.7 in chunk (-7, -5)") and g["paintCells"] == 3, g

        js = os.path.join(d, "live.js")
        open(js, "w").write(LIVE_JS)
        spath = os.path.join(d, "state.json")
        # the joined chat pane (eng/sitechat2): the YouTube lines push_live publishes, in time order, badged
        yt = [{"id": "yt:2", "name": "Joonazan", "text": "no biters on Gleba", "t": 1792015200.0},
              {"id": "yt:1", "name": "Enginerd", "text": "<b>hi</b>", "t": 1792015100.0}]
        json.dump(dict(map_state(True), youtube_chat=yt), open(spath, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), spath], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        lv = json.loads(r.stdout)
        vc = lv["vchat"]
        assert vc.count('c-src-yt') == 2 and vc.index("Enginerd") < vc.index("Joonazan"), vc  # oldest first
        assert "&lt;b&gt;hi" in vc and "<b>hi" not in vc, vc  # escaped
        assert lv["dash"].count('class="fx-panel live-card') == 6 and 'id="cb-map"' in lv["dash"]
        assert len(lv["made"]) == 1 and lv["made"][0]["host"] == "mm", lv["made"]  # one viewer, kept across refreshes
        got = lv["sets"][-1]
        assert got["base"]["rows"] and got["core"]["cell"] == 1 and len(got["turrets"]) == 3 and got["nests"] == [[90, 10, "s"]]
        assert [a["name"] for a in got["agents"]] == [a["name"] for a in map_state(True)["agents"]] and "cams" in got
        assert "agent-live" in lv["agents"]
        # the board card: open projects with their progress, and a project step with the step it did (eng/projects)
        bd = lv["board"]
        assert '<h4>Projects</h4><ul class="board-projects">' in bd and "<b>Nuclear power plant</b>" in bd, bd
        assert 'aria-valuenow="50"' in bd and "3 of 6 steps" in bd and "no owner" in bd and "--fx-value:25%" in bd, bd
        assert "finished a step of</span> Nuclear power plant" in bd and "3. Reactor and heat exchangers" in bd, bd
        # watchers: the sample shows its YouTube reading; no heartbeat without an API
        assert lv["watching"] == {"text": "Watching: 41 YouTube", "hidden": False} and lv["posts"] == [], (lv["watching"], lv["posts"])

        def live(mode, st):
            json.dump(st, open(spath, "w"))
            r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), spath, mode], capture_output=True,
                               text=True, timeout=30)
            assert r.returncode == 0, r.stderr
            return json.loads(r.stdout)
        st = map_state(True)
        st["watching"] = {"youtube": 40, "t": 1}
        lv = live("live", st)
        assert lv["watching"] == {"text": "Watching: 40 YouTube · 3 site", "hidden": False}, lv["watching"]
        assert [(p["url"], p["type"]) for p in lv["posts"]] == [("https://api.test/v1/here", "text/plain")], lv["posts"]
        assert re.fullmatch(r"[0-9a-f]{24}", lv["posts"][0]["body"]["id"]), lv["posts"]  # the worker's id rule
        st.pop("watching")
        assert live("live", st)["watching"] == {"text": "Watching: 3 site", "hidden": False}  # YouTube unknown
        assert live("stale", st)["watching"] == {"text": "", "hidden": True}  # offline: no count


def main():
    payload_tests()
    build_tests()
    map_tests()
    print("site live: ok (compact space, fights and camera labels; homepage is the live show; about and /live/ kept)")


if __name__ == "__main__":
    main()
