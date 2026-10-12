#!/usr/bin/env python3
"""The homepage is the live show, and the live payload stays small: python3 site/test_live.py

- push_live.public_state keeps a compact Space Age block (platforms' place or route, no camera views or moments),
  the fights reported in the last two minutes on Nauvis, and each camera's fight / work / segment label;
- the built homepage carries the live app and links to the rest of the site; /about/ has the old homepage, /live/
  still works; check.py passes;
- the map (static/live.js under node, a stub DOM): framed on the base's core, basemap.core drawn over the coarse grid
  (clipped outside it), an inset of the whole base, a legend per kind, an agent far away pinned to the edge; without
  basemap.core (an older stream service) the core comes from the coarse grid.
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


MAP_JS = r"""
// static/live.js in a stub DOM, sample mode, on the state in argv[2]; prints the dashboard's HTML
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function cls() { const s = new Set(); return { add: (c) => s.add(c), remove: (c) => s.delete(c), toggle: (c, on) => (on ? s.add(c) : s.delete(c)), contains: (c) => s.has(c) }; }
const kids = {};
function el(name) {
  return { name, dataset: {}, innerHTML: '', textContent: '', value: '', hidden: false, classList: cls(), attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, addEventListener() {},
    querySelector: (s) => kids[s] || (kids[s] = el(s)), querySelectorAll: () => [], scrollTop: 0, scrollHeight: 0 };
}
const app = el('app');
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
global.fetch = (url) => Promise.resolve({ ok: true, json: () => Promise.resolve(url.indexOf('state') >= 0 ? state : { schema: 1 }) });
require(process.argv[2]);
setTimeout(() => process.stdout.write(kids['#dash'].innerHTML), 300);
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
          "buildings": 900}
    if core:
        bm["core"] = {"cell": 1, "x0": -8, "y0": -8, "w": 96, "h": 80,
                      "rows": ["AAA.SS.II.BBBB.TTTT.LL.EE.PP.MMM.RR.DD" * 2 for _ in range(80)]}
    s["basemap"] = bm
    for a in s.get("agents", []):
        a["position"] = {"x": 30, "y": 30}
    s["agents"][0]["position"] = {"x": 2, "y": -390}  # at the pumpjacks: off the core view, pinned to the edge
    return s


def map_tests():
    if not shutil.which("node"):
        print("map: skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "map.js")
        open(js, "w").write(MAP_JS)
        out = {}
        for core in (True, False):
            path = os.path.join(d, f"state-{core}.json")
            json.dump(map_state(core), open(path, "w"))
            r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
            assert r.returncode == 0, r.stderr
            out[core] = r.stdout
        html = out[True]
        assert 'id="mm"' in html and 'class="minimap"' in html
        assert '<clipPath id="mm-out">' in html and html.count('class="mm-base"') == 3, "coarse outside the core, fine core, inset"
        assert 'class="mm-inset"' in html, "the inset shows the whole base (the pipeline makes it 5 times the view)"
        view = float(re.search(r"About (\d+) tiles across", html).group(1))
        assert 90 <= view <= 200, view  # framed on the core (96 x 80 tiles, and the sample's alerts near it), not the 500-tile extent
        for label in ("Assembly", "Rails", "Inserters", "Logistics", "Belts", "Pipes", "Defence", "Labs", "Enemy nests"):
            assert f"</i>{label}</li>" in html, label
        assert "1-tile cells" in html and 'data-mm="in"' in html
        assert 'class="dot far"' in html, "the agent at the pumpjacks is pinned to the edge"
        old = out[False]  # an older stream service without basemap.core: the core framed from the coarse grid
        assert "mm-out" not in old and 'class="mm-inset"' in old
        assert 70 <= float(re.search(r"About (\d+) tiles across", old).group(1)) <= 200


def main():
    payload_tests()
    build_tests()
    map_tests()
    print("site live: ok (compact space, fights and camera labels; homepage is the live show; about and /live/ kept)")


if __name__ == "__main__":
    main()
