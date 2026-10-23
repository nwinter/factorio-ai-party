#!/usr/bin/env python3
"""The live map's attacks layer (d22 batch97 BG3): python3 site/test_threats.py

The stream service read the enemy groups on their way (harness attack_groups_live, model.py `incoming`) and the
demolishers near ours (big_enemies_live, `big_enemies`) every 2-10 s, but push_live left both out of the state, so the
page never had them. push_live.public_threats sends them as `threats` {incoming, big} without the service's own fields
(first_seen, t, gathered, first_size), at most 12 of each; static/mapview.js draws them on the surface shown (a diamond
with a dashed line to the target; a ringed dot with a line to our nearest building while it closes), names them on
hover, and the layer's toggle says "none" when there are none.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import push_live  # noqa: E402

# world n's stream state at 17:00 (d22): one group on its way
GROUP = {"id": 24099, "surface": "nauvis", "position": {"x": 680, "y": -837}, "size": 18,
         "kinds": "6 behemoth-spitter, 6 big-spitter, 2 big-biter, 2 medium-biter", "state": "moving",
         "gathered": {"x": 793, "y": -885}, "first_size": 18, "target": {"x": 672, "y": -836}, "target_distance": 7,
         "visible": False, "age_s": 48.8, "first_seen": 1792711318.357787, "t": 1792711366.459739,
         "label": "18 biters and spitters heading for the base, 1070 m NE of spawn"}
BIG = {"id": 7, "name": "small-demolisher", "surface": "vulcanus", "position": {"x": 120.4, "y": -40.6}, "speed": 1.2,
       "closing": True, "nearest": {"x": 20, "y": -30, "name": "gun-turret"}, "nearest_distance": 100, "eta_s": 83,
       "character": {"x": 0, "y": 0, "player": "sol"}, "character_distance": 127, "t": 1792711366.4,
       "label": "Small demolisher · 100 tiles from Sol's gun turrets"}

JS = r"""
global.window = global;
global.document = { createElement: () => ({}), addEventListener() {} };
global.addEventListener = () => {};
global.localStorage = { getItem: () => null, setItem: () => {} };
require(process.argv[2]);
const M = global.PogMap;
const threats = JSON.parse(process.argv[3]);
const base = { cell: 16, x0: 600, y0: -900, w: 8, h: 8, rows: ['AAAAAAAA'] };
const out = {};
const on = { threats: true, buildings: true };
const look = (surface, layers, view) => {
  const d = M.prepare({ surface, base, planets: { vulcanus: { cell: 4, x0: 0, y0: -60, w: 10, h: 10, rows: ['AAAA'] } }, threats });
  const sc = M.scene(d, view, 400, 400, layers);
  return { groups: d.groups.length, big: d.big.length, marks: sc.threats, hits: sc.hits.map((h) => h.text), has: M.absentWhy ? M.absentWhy({}, d, 'threats') : null };
};
out.nauvis = look('nauvis', on, { cx: 676, cy: -836, span: 40 });
out.vulcanus = look('vulcanus', on, { cx: 70, cy: -35, span: 200 });
out.off = look('nauvis', { buildings: true }, { cx: 676, cy: -836, span: 40 });
out.far = look('nauvis', on, { cx: 0, cy: 0, span: 40 });
const empty = M.prepare({ surface: 'nauvis', base });
out.none = M.absentWhy({}, empty, 'threats');
const sc = M.scene(M.prepare({ surface: 'vulcanus', planets: { vulcanus: { cell: 4, x0: 0, y0: -60, w: 10, h: 10, rows: ['AAAA'] } }, threats }), { cx: 70, cy: -35, span: 200 }, 400, 400, on);
const ctx = new Proxy({}, { get: (t, k) => k === 'measureText' ? () => ({ width: 10 }) : k in t ? t[k] : () => {}, set: (t, k, v) => { t[k] = v; return true; } });
M.paint(ctx, sc, {}, 'x');
out.painted = true;
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:2000]))
    if not ok:
        sys.exit(1)


def main():
    th = push_live.public_threats([GROUP, {"id": 2}], [BIG])
    g, b = th["incoming"][0], th["big"][0]
    check("push_live: a group keeps its place, target, size, kinds, age and label", g["position"] == {"x": 680, "y": -837}
          and g["target"] == {"x": 672, "y": -836} and g["size"] == 18 and g["age_s"] == 48.8 and g["label"].startswith("18 biters")
          and g["visible"] is False, g)
    check("push_live: none of the service's own fields (first_seen, t, gathered, first_size)",
          not ({"first_seen", "t", "gathered", "first_size"} & set(g)) and not ({"t", "character", "character_distance"} & set(b)), (g, b))
    check("push_live: a row without a position is left out", len(th["incoming"]) == 1, th)
    check("push_live: a demolisher with its rounded place, nearest building, closing and ETA",
          b["position"] == {"x": 120, "y": -41} and b["nearest"] == {"x": 20, "y": -30, "name": "gun-turret"} and b["closing"] is True
          and b["eta_s"] == 83, b)
    check("push_live: at most 12 of each", len(push_live.public_threats([dict(GROUP, id=i) for i in range(30)], [])["incoming"]) == 12)
    check("push_live: none, no key", push_live.public_threats([], None) is None)
    state = push_live.public_state({"incoming": [GROUP], "big_enemies": [BIG], "agents": []})
    check("the public state carries threats", state.get("threats", {}).get("incoming", [{}])[0].get("id") == 24099
          and state["threats"]["big"][0]["id"] == 7, state.get("threats"))
    check("about 300 bytes a row", len(json.dumps(g, separators=(",", ":"))) < 400 and len(json.dumps(b, separators=(",", ":"))) < 400,
          (len(json.dumps(g)), len(json.dumps(b))))
    if not shutil.which("node"):
        print("threats: the page part skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), json.dumps(th)], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    n, v = o["nauvis"], o["vulcanus"]
    check("Nauvis: the group only (the demolisher is on Vulcanus)", n["groups"] == 1 and n["big"] == 0 and len(n["marks"]) == 1, n)
    check("the group's mark has its dashed line to the target", n["marks"][0]["tx"] is not None and not n["marks"][0]["big"], n["marks"])
    check("hover names the group, its size and when it was first seen",
          any(t.startswith("18 biters and spitters heading for the base") and "seen 49 s ago" in t for t in n["hits"]), n["hits"])
    check("Vulcanus: the demolisher, closing, with its line to our building", v["big"] == 1 and v["groups"] == 0
          and v["marks"][0]["big"] and v["marks"][0]["tx"] is not None, v)
    check("hover names the demolisher and its ETA", any(t.startswith("Small demolisher · 100 tiles from Sol's gun turrets · closing, about 83 s away")
                                                        for t in v["hits"]), v["hits"])
    check("the layer off: no marks", o["off"]["marks"] == [], o["off"])
    check("a group off the view is pinned to the edge, its distance on hover, no line", o["far"]["marks"][0]["tx"] is None
          and any("tiles from the base" in t for t in o["far"]["hits"]), o["far"])
    check("none: the toggle says so", o["none"].startswith("none: no enemy group on its way and no demolisher near ours on Nauvis"), o["none"])
    check("paint draws them", o["painted"])
    print("threats: ok (groups on their way and demolishers near ours reach the page and are drawn on their surface)")


if __name__ == "__main__":
    main()
