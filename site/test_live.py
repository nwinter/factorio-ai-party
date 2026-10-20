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
    # the other planets' maps (viewers craigNZ830, Foobator, d15 07:05): all listed, one grid a push, in turn
    grid = lambda n: {"tick": n, "cell": 8, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AS"], "buildings": n, "capped": None}
    sp = dict(s, planet_maps={"vulcanus": grid(5), "gleba": grid(7)})
    a_, b_ = push_live.public_state(sp), push_live.public_state(sp)
    assert a_["planets"] == [{"surface": "gleba", "tick": 7, "buildings": 7}, {"surface": "vulcanus", "tick": 5, "buildings": 5}], a_["planets"]
    assert {a_["planet_map"]["surface"], b_["planet_map"]["surface"]} == {"gleba", "vulcanus"} and a_["planet_map"]["rows"] == ["AS"]
    assert "capped" not in a_["planet_map"] and "planet_maps" not in a_
    assert "planets" not in push_live.public_state(s)
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
    # (d17 batch35 D1) site lines' delivery: by seq, YouTube left out, unknown statuses dropped
    dv = push_live.public_delivery({"delivery": [{"id": "site:2707", "status": "relayed", "to": "astra"},
                                                 {"id": "site:2721", "status": "not_relayed", "why": "clef:injection"},
                                                 {"id": "yt:9", "status": "relayed", "to": "sol"},
                                                 {"id": "site:2730", "status": "held", "why": "Clef unavailable"},
                                                 {"id": "site:2731", "status": "weird"}]})
    assert dv == {"2707": {"s": "relayed", "to": "astra"}, "2721": {"s": "not_relayed", "why": "clef:injection"},
                  "2730": {"s": "held", "why": "Clef unavailable"}}, dv
    # (d19 batch42 A3, A4) every recipient of a group line, and the operator's inbox receipt beside the agents' copy
    # (d19 batch43 A3) a long delivery reason: cut at a word end with "…" past 240
    why = "about its work (" + "Sol on Gleba doing the agricultural science line, " * 8 + ")"
    w = push_live.public_delivery({"delivery": [{"id": "site:1", "status": "relayed", "why": why}]})["1"]["why"]
    assert len(w) <= 240 and w.endswith("…") and why.startswith(w[:-1]) and why[len(w) - 1] == " ", w
    # (d19 batch43 A2) evidence and long results within the reminders' share: over it, the newest evidence line each
    rem = {"total": 1, "jobs": [{"id": 1, "last_result": "r" * 1000, "evidence": ["e%d " % i + "x" * 500 for i in range(5)]} for _ in range(12)]}
    pr = push_live.public_reminders(rem)
    assert all(j["evidence"] == [rem["jobs"][0]["evidence"][-1]] and j["evidence_more"] == 4 and len(j["last_result"]) == 1000
               for j in pr["jobs"]), pr["jobs"][0]
    small = {"total": 1, "jobs": [{"id": 1, "evidence": ["a", "b"]}]}
    assert push_live.public_reminders(small) == small
    big = {"projects": [{"id": i, "title": "p", "evidence": ["x" * 3000] * 5} for i in range(5)], "claims": [{"id": 1, "evidence": ["c1", "c2"]}]}
    pb = push_live.public_board(big)
    assert all(len(p["evidence"]) == 1 and p["evidence_more"] == 4 for p in pb["projects"]) and pb["claims"][0]["evidence"] == ["c2"], pb["claims"]
    dv = push_live.public_delivery({"delivery": [{"id": "site:3200", "status": "relayed", "to": "sol", "to_all": ["sol", "luna"]},
                                                 {"id": "site:3201", "status": "relayed", "to": "muse", "to_all": ["muse"], "inbox": True},
                                                 {"id": "site:3202", "status": "not_relayed", "why": "impersonation:text", "inbox": True}]})
    assert dv == {"3200": {"s": "relayed", "to": "sol", "to_all": ["sol", "luna"]}, "3201": {"s": "relayed", "to": "muse", "op": 1},
                  "3202": {"s": "not_relayed", "why": "impersonation:text", "op": 1}}, dv
    # (d17 batch35 D5) each agent's most repeated haul this shift and its destination's feed now
    hl = push_live.public_haul({"rows": [{"name": "gemini", "top": {"item": "iron-plate", "surface": "fulgora", "to_name": "stone-furnace",
                                                                     "times": 30, "items": 600, "from": {"x": 1, "y": 2}}},
                                          {"name": "grok", "top": {"item": "coal", "times": 1}}, {"name": "haiku", "top": None}],
                                 "feeds": {"gemini": {"agent": "gemini", "item": "iron-plate", "line": "stone-furnace (-60,71) on fulgora, fed iron-plate without hands now: none"}}})
    assert hl == {"gemini": {"item": "iron-plate", "surface": "fulgora", "to_name": "stone-furnace", "times": 30, "items": 600,
                             "feed": "stone-furnace (-60,71) on fulgora, fed iron-plate without hands now: none"}}, hl
    assert push_live.public_haul(None) == {}
    assert push_live.public_state(dict(s, hauling={"rows": [{"name": s["agents"][0]["name"], "top": {"item": "coal", "times": 3}}]}))["agents"][0]["haul"]["times"] == 3
    assert push_live.public_delivery(None) == {} and len(push_live.public_delivery(
        {"delivery": [{"id": f"site:{i}", "status": "held"} for i in range(200)]})) == 150
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
  const e = { name, dataset: {}, textContent: '', value: '', hidden: false, classList: cls(), attrs: {}, _html: '', style: {}, on: {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; },
    addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); }, appendChild() {},
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
  addEventListener() {}, querySelector: () => null, createElement: (t) => (kids['new:' + t] = el(t)) };
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
// The portrait tip and the scroll to a plan line (viewer syndesis): a mouse hover, a click, then two taps on a phone.
const fire = (type, ev) => (app.on[type] || []).forEach((f) => f(ev));
const portraitOf = (name) => ({ dataset: { agent: name }, getBoundingClientRect: () => ({ left: 10, top: 10, bottom: 58 }), contains: () => false });
const evOn = (p, extra) => Object.assign({ target: { closest: (sel) => (sel.indexOf('data-agent') >= 0 ? p : null) }, preventDefault() {} }, extra);
const taps = {};
setTimeout(() => {
  const tip = kids['new:div'];
  if (!tip || !(app.on.pointerover || []).length) return;
  const sol = portraitOf('sol'), muse = portraitOf('muse');
  fire('pointerover', evOn(sol, { pointerType: 'mouse' }));
  taps.hover = { hidden: tip.hidden, html: tip.innerHTML };
  fire('pointerdown', evOn(sol, { pointerType: 'mouse' }));
  fire('click', evOn(sol, {}));
  taps.click = { hidden: tip.hidden, flash: !!(kids['#plan-line-sol'] && kids['#plan-line-sol'].classList.contains('is-flash')) };
  fire('pointerdown', evOn(muse, { pointerType: 'touch' }));
  fire('click', evOn(muse, {}));
  taps.tap1 = { hidden: tip.hidden, html: tip.innerHTML };
  fire('pointerdown', evOn(muse, { pointerType: 'touch' }));
  fire('click', evOn(muse, {}));
  taps.tap2 = { hidden: tip.hidden, plan_card: !!(kids['.card-plan'] && kids['.card-plan'].classList.contains('is-flash')) };
}, 200);
setTimeout(() => process.stdout.write(JSON.stringify({ dash: kids['#dash'].innerHTML, made, sets, taps, plan: (kids['#cb-plan'] || {}).innerHTML,
  agents: (kids['#cb-agents'] || {}).innerHTML, cams: (kids['#map-cams'] || {}).innerHTML, board: (kids['#cb-board'] || {}).innerHTML,
  chronicle: (kids['#cb-chronicle'] || {}).innerHTML,
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
// another planet's coarse map (viewers craigNZ830, Foobator, d15 07:05): its buildings, the agents on it; Nauvis lists it
const dv = M.prepare(Object.assign({}, data.full, { planets: data.planets, surface: 'vulcanus' }));
out.vulcanus = Object.assign(summary(M.scene(dv, null, 400, 400)), { auto: dv.auto });
out.planetsOnNauvis = M.prepare(Object.assign({}, data.full, { planets: data.planets })).planets;
// (d19 batch43 A4) the cursor's tile and the surface shown
out.coords = [M.coordsText(12.7, -40.2, 'nauvis'), M.coordsText(-0.5, 3, 'fulgora'), M.coordsText(5, 5)];
// (d19 batch42 B3) when the terrain frames were captured: wall time when they have it, else the game tick
out.terrainNotes = [M.prepare(data.full).terrainNote,
  M.prepare(Object.assign({}, data.full, { terrain: [Object.assign({}, data.full.terrain[0], { t: 1792433272 })] })).terrainNote];
// (d19 batch42 B2) the turret layer says what it holds: every turret the sweep read, or the capped first 600
const many = Array.from({ length: 600 }, (_, i) => [i, 0, 18]);
out.turretNotes = [M.prepare(Object.assign({}, data.full, { turrets_read: { turrets: 1459, drawn: 1221, complete: true } })).turretNote,
  M.prepare(Object.assign({}, data.full, { turrets: many, turrets_read: { turrets: 600, capped: true } })).turretNote,
  M.prepare(Object.assign({}, data.full, { turrets: many })).turretsCapped, M.prepare(data.full).turretNote];
// (d19 batch42 B1, viewer Aurora) Fulgora's 32-tile grid: scattered single cells, no block dense; it frames its cells
const df = M.prepare(Object.assign({}, data.full, { planets: data.planets, surface: 'fulgora' }));
out.fulgora = Object.assign(summary(M.scene(df, null, 400, 400)), { auto: df.auto, box: [df.box.x0, df.box.y0, df.box.x1, df.box.y1] });
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
        planets = {"vulcanus": {"surface": "vulcanus", "tick": 3, "cell": 8, "x0": 4960, "y0": -3040, "w": 10, "h": 10,
                                "rows": ["SSAAEE" for _ in range(10)], "buildings": 120},
                   # 25 building cells, each alone in its 32-tile block: none of the old blocks was dense
                   "fulgora": {"surface": "fulgora", "tick": 3, "cell": 32, "x0": -320, "y0": -320, "w": 20, "h": 20,
                               "rows": ["A...A...A...A...A..." if i % 4 == 0 else "" for i in range(20)],
                               "buildings": 25}}
        json.dump({"full": viewer_data(map_state(True)), "old": viewer_data(map_state(False)), "gleba": gleba,
                   "clouds": CLOUDS, "planets": planets}, open(path, "w"))
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
        v = o["vulcanus"]  # Vulcanus: its coarse map drawn and framed; Luna, who is there, drawn; no Nauvis nests or fights
        assert v["base"] and v["nests"] == 0 and v["fights"] == 0, v
        assert "luna" in [a["name"] for a in v["agents"]] and not any(a[0].startswith("Luna") for a in v["away"]), v
        assert 4960 <= v["auto"]["cx"] <= 5040, v["auto"]
        assert o["planetsOnNauvis"] == ["fulgora", "vulcanus"], o["planetsOnNauvis"]
        assert o["coords"] == ["x 12, y -41 · Nauvis", "x -1, y 3 · Fulgora", "x 5, y 5 · Nauvis"], o["coords"]
        assert o["terrainNotes"][0] == "captured at game tick 1" and o["terrainNotes"][1].startswith("captured ") \
            and "19" in o["terrainNotes"][1], o["terrainNotes"]
        assert o["turretNotes"] == ["all 1459 turrets, 238 within 2 tiles of another merged",
                                    "incomplete: the first 600 turrets read; the rest are not drawn yet", True, ""], o["turretNotes"]
        f = o["fulgora"]
        assert f["base"] and f["nests"] == 0 and f["box"] == [-328, -328, 232, 232], f  # every cell, plus 8 tiles
        assert -100 <= f["auto"]["cx"] <= 100, f["auto"]
        assert g["hit"]["text"].startswith("Spores 14.7 in chunk (-7, -5)") and g["paintCells"] == 3, g

        js = os.path.join(d, "live.js")
        open(js, "w").write(LIVE_JS)
        spath = os.path.join(d, "state.json")
        # the joined chat pane (eng/sitechat2): the YouTube lines push_live publishes, in time order, badged
        yt = [{"id": "yt:2", "name": "Joonazan", "text": "no biters on Gleba", "t": 1792015200.0},
              {"id": "yt:1", "name": "Enginerd", "text": "<b>hi</b>", "t": 1792015100.0}]
        pm = {"surface": "vulcanus", "tick": 3, "cell": 8, "x0": 4960, "y0": -3040, "w": 6, "h": 2, "rows": ["SSAAEE", "SS"], "buildings": 9}
        st = map_state(True)
        # (d19 batch43 A2, batch41 B2) a 1000-character reminder result and evidence lines on a reminder and a claim
        long_result = ("Quality review: legendary yield 3.1% over the last hour, rare 9.8%, the recycler loop fed at 92%; " * 11)[:1000]
        st["reminders"]["jobs"][1].update(last_result=long_result, result_age_s=60,
                                          evidence=["by sol 30m ago: metric PU 540/min (tick 100)", "by astra 2m ago: metric PU 600/min "
                                                    "(tick 200); decision keep the second line; next check tick 300 " + "x" * 300])
        st["board"]["claims"][0]["evidence"] = ["by haiku 5m ago: metric 12 drills on the south-west patch"]
        # (d19 batch46 item 0) batch41's missed-runs text has its own "; " inside the parentheses
        st["reminders"]["jobs"][0]["states"] = ("astra overdue (8 runs missed (the first at tick 33987840, 7m35s ago; the last at tick "
                                                "33987840, 7m35s ago), the owner told); sol acknowledged")
        json.dump(dict(st, youtube_chat=yt, planets=[{"surface": "vulcanus", "tick": 3, "buildings": 9}], planet_map=pm),
                  open(spath, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), spath], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        lv = json.loads(r.stdout)
        vc = lv["vchat"]
        assert vc.count('c-src-yt') == 2 and vc.index("Enginerd") < vc.index("Joonazan"), vc  # oldest first
        assert "&lt;b&gt;hi" in vc and "<b>hi" not in vc, vc  # escaped
        assert lv["dash"].count('class="fx-panel live-card') == 8 and 'id="cb-map"' in lv["dash"] and 'id="cb-plan"' in lv["dash"] and 'id="cb-chronicle"' in lv["dash"]
        # the Chronicle card (viewers Alex and syndesis 22:24): the newest entry in the agent's words with its title, game
        # time, where and what it is filed beside; the harness's record (a platform lost with its cargo; research left out)
        cr = lv["chronicle"]
        assert "<b>Sol</b>" in cr and "Oil at last" in cr and "The pumpjacks are breathing." in cr and "1h03m · nauvis" in cr, cr
        assert "Beside: research finished: oil-processing" in cr, cr
        assert ">Lost</span> platform Starling lost flying nauvis-&gt;vulcanus 40%" in cr and "cargo lost: 450 iron plate, 20 rocket fuel" in cr, cr
        assert "plastics" not in cr and 'href="/chronicle/"' in cr, cr
        assert len(lv["made"]) == 1 and lv["made"][0]["host"] == "mm", lv["made"]  # one viewer, kept across refreshes
        got = lv["sets"][-1]
        assert got["base"]["rows"] and got["core"]["cell"] == 1 and len(got["turrets"]) == 3 and got["nests"] == [[90, 10, "s"]]
        assert [a["name"] for a in got["agents"]] == [a["name"] for a in map_state(True)["agents"]] and "cams" in got
        assert got["planets"]["vulcanus"]["rows"] == ["SSAAEE", "SS"], got.get("planets")  # the push's planet map reaches the viewer
        assert "agent-live" in lv["agents"]
        # the board card: open projects with their progress, and a project step with the step it did (eng/projects)
        bd = lv["board"]
        assert '<h4>Projects</h4><ul class="board-projects">' in bd and "<b>Nuclear power plant</b>" in bd, bd
        assert 'aria-valuenow="50"' in bd and "3 of 6 steps" in bd and "no owner" in bd and "--fx-value:25%" in bd, bd
        assert "finished a step of</span> Nuclear power plant" in bd and "3. Reactor and heat exchangers" in bd, bd
        # a step's own owner and the parallel steps (d15 batch5 J2, viewer Foobator)
        assert 'class="step step-next step-parallel"' in bd and "· Luna</span>" in bd and ">parallel</span>" in bd, bd
        # the team's reminder jobs (d15 batch5 group I): owner, message, next due, the last result with its age, states
        assert '<h4>Reminders</h4><ul class="board-claims board-reminders">' in bd and "ship review: Petrel ammo, fuel and hub room" in bd, bd
        assert "every 15m00s, next in 7 min" in bd and "last result 8 min ago:</span> Petrel 900 magazines" in bd, bd
        assert 'fx-chip--red">Astra overdue (8 runs missed (the first at tick 33987840, 7m35s ago; the last at tick 33987840, 7m35s ago), the owner told)</span>' in bd \
            and 'fx-chip--green">Sol acknowledged' in bd, bd
        # (d19 batch43 A2) the long result whole, collapsed to a line that opens; evidence newest first, the older after
        assert '<details class="lt" data-lt="rem2:result">' in bd and bd.count(long_result) == 2, bd  # the line and the opened text
        assert bd.index("PU 600/min") < bd.index("PU 540/min") and "earlier evidence:" in bd and "x" * 300 in bd, bd
        assert "evidence:</span> by haiku 5m ago: metric 12 drills" in bd, bd
        # the Team plan (viewer Alex, 22:12): the goals with when they were set, each agent's line with when it was set
        # and by whom when not itself, the agents with no line, open projects with their next step, the request counts
        pl = lv["plan"]
        assert "<h4>Goals</h4>" in pl and "Blue science at 60/min" in pl and "set 3 min ago" in pl, pl
        assert 'id="plan-line-sol"' in pl and "blue circuits line at (40,-20)" in pl and "set 6 min ago by Astra" in pl, pl
        assert "set 25 min ago" in pl and "set 2 min ago" in pl, pl  # opus 25 game minutes ago, luna 90 s (2 min)
        assert "No line: Astra, Opus" not in pl and "No line: Astra, Sonnet, Haiku, Grok the Unyielding Builder, Gemini, Muse" in pl, pl
        assert '<span class="fx-muted">Next:</span> Reactor and heat exchangers' in pl and "Rails from (120,-300)" in pl, pl
        assert "nobody on them" in pl and "in progress" in pl and "Plan last edited by astra, 6m ago." in pl, pl
        # portraits of the team take focus and name the agent; any other portrait stays hidden from screen readers
        assert 'data-agent="sol" tabindex="0" role="button" aria-label="Sol: plan line and job"' in pl, pl
        assert 'data-agent="opus"' in lv["agents"], lv["agents"]
        t = lv["taps"]
        assert t["hover"]["hidden"] is False and "Sol" in t["hover"]["html"] and "blue circuits line at (40,-20)" in t["hover"]["html"], t
        assert "(set 6 min ago)" in t["hover"]["html"] and "Click for its line" in t["hover"]["html"], t
        assert t["click"] == {"hidden": True, "flash": True}, t  # the click scrolls to Sol's line and marks it
        # a tap shows Muse's tip (no line on the plan; its job from its notes); a second tap goes to the plan card
        assert t["tap1"]["hidden"] is False and "no line on the team plan" in t["tap1"]["html"], t
        assert "Job (notes.md Now line):</span> refill the furnace row" in t["tap1"]["html"] and "Tap again" in t["tap1"]["html"], t
        assert t["tap2"] == {"hidden": True, "plan_card": True}, t
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
