#!/usr/bin/env python3
"""The live map's vehicles layer (d26 batch233 VM): python3 site/test_vehicles.py

Viewer Aurora (site:5019): "Could vehicle maps start with Spidertrons? The planned item would make remote recon
visible. Show ID, position age, controller and destination." The harness census reads our spidertrons where our force
last saw them (census.lua part vehicles: the position now when the chunk is in sight, else the last one seen with its
tick; who rides it, who drives it by remote view, who last sent it a route, its destination); the stream service reads
it every 10 s (harness.vehicles, live.py), model.vehicles_snapshot counts the ages on to the snapshot, push_live sends
`vehicles` {rows, total, read_age_s} without anything else, and static/mapview.js draws each on the surface shown (a
square, grey from out of sight, a dashed line to its destination) and names it on hover.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
STREAM = os.path.join(os.path.dirname(SITE), "tools", "stream")
sys.path.insert(0, SITE)
sys.path.insert(0, STREAM)
sys.dont_write_bytecode = True
import push_live  # noqa: E402
import harness  # noqa: E402
from model import Model  # noqa: E402

# the census read on world n at tick 66924930 (d26, the module probe), with a sender and a destination added
READ = {"ready": True, "part": "vehicles", "tick": 66924930, "vehicles_total": 3, "vehicles": [
    {"unit_number": 23036938, "name": "spidertron", "type": "spider-vehicle", "surface": "nauvis", "age_s": 0,
     "seen_tick": 66924930, "position": {"x": -148.400000000000005684, "y": -543.1000000000000227}, "visible": True,
     "sent_by": "opus", "sent_tick": 66917730, "destination": {"x": -60.25, "y": -300.5}, "route_targets": 3},
    {"unit_number": 23117830, "name": "spidertron", "type": "spider-vehicle", "surface": "gleba", "age_s": 0,
     "seen_tick": 66924930, "position": {"x": 74, "y": 20}, "visible": True, "driver": "astra"},
    {"unit_number": 27069154, "name": "spidertron", "type": "spider-vehicle", "surface": "nauvis", "age_s": 300,
     "seen_tick": 66906930, "position": {"x": -158.5, "y": -540.7000000000000455}, "visible": False},
    {"unit_number": 27069155, "name": "spidertron", "type": "spider-vehicle", "surface": "nauvis", "unseen": True,
     "visible": False},
    # (cp2) a tank driven by remote view: its drive's target is its destination
    {"unit_number": 311799, "name": "tank", "type": "car", "surface": "nauvis", "age_s": 0, "seen_tick": 66924930,
     "position": {"x": -140, "y": -450}, "visible": True, "remote": "luna", "remote_target": {"x": -80, "y": -450},
     "destination": {"x": -80, "y": -450}}]}

JS = r"""
global.window = global;
global.document = { createElement: () => ({}), addEventListener() {} };
global.addEventListener = () => {};
global.localStorage = { getItem: () => null, setItem: () => {} };
require(process.argv[2]);
const M = global.PogMap;
const vehicles = JSON.parse(process.argv[3]);
const agents = [{ name: 'opus', display_name: 'Opus', position: { x: 0, y: 0 }, surface: 'nauvis' }];
const base = { cell: 16, x0: -200, y0: -600, w: 8, h: 8, rows: ['AAAAAAAA'] };
const out = {};
const look = (surface, layers, view) => {
  const d = M.prepare({ surface, base, agents, vehicles, planets: { gleba: { cell: 4, x0: 0, y0: 0, w: 10, h: 10, rows: ['AAAA'] } } });
  const sc = M.scene(d, view, 400, 400, layers);
  return { n: d.vehicles.length, marks: sc.vehicles, hits: sc.hits.map((h) => h.text) };
};
out.nauvis = look('nauvis', M.DEFAULT_ON, { cx: -150, cy: -500, span: 200 });
out.gleba = look('gleba', M.DEFAULT_ON, { cx: 70, cy: 20, span: 60 });
out.off = look('nauvis', Object.assign({}, M.DEFAULT_ON, { vehicles: false }), { cx: -150, cy: -500, span: 200 });
out.far = look('nauvis', M.DEFAULT_ON, { cx: 0, cy: 0, span: 40 });
out.none = M.absentWhy({}, M.prepare({ surface: 'nauvis', base, vehicles: { rows: [] } }), 'vehicles');
out.unread = M.absentWhy({}, M.prepare({ surface: 'nauvis', base }), 'vehicles');
out.layer = M.LAYERS.some((l) => l[0] === 'vehicles') && M.DEFAULT_ON.vehicles === true;
out.group = M.GROUPS.filter((g) => g[2].indexOf('vehicles') >= 0).map((g) => g[0]);
const sc = M.scene(M.prepare({ surface: 'nauvis', base, agents, vehicles }), { cx: -150, cy: -500, span: 200 }, 400, 400, M.DEFAULT_ON);
const calls = [];
const ctx = new Proxy({}, { get: (t, k) => k === 'measureText' ? () => ({ width: 10 }) : k in t ? t[k] : (...a) => { calls.push(k); }, set: (t, k, v) => { t[k] = v; return true; } });
M.paint(ctx, sc, {}, 'x');
out.painted = calls.filter((c) => c === 'fillRect').length;
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:2000]))
    if not ok:
        sys.exit(1)


class FakeHarness(harness.Harness):
    def __init__(self, reply):
        self.reply, self.asked = reply, []

    def lua(self, lua):
        self.asked.append(lua)
        return self.reply


def main():
    h = FakeHarness(READ)
    v = h.vehicles()
    check("harness.vehicles asks the census for part vehicles as an operator read", 'part = "vehicles"' in h.asked[0]
          and 'action = "census"' in h.asked[0] and "operator = true" in h.asked[0], h.asked[0][:400])
    check("harness.vehicles: tick, rows, total", v["tick"] == 66924930 and len(v["rows"]) == 5 and v["total"] == 3, v)
    check("harness.vehicles: an empty list written as {} reads as no rows",
          FakeHarness(dict(READ, vehicles={}, vehicles_total=0)).vehicles()["rows"] == [])
    check("harness.vehicles: none from a runtime without the part (the read prints {})", FakeHarness({}).vehicles() is None)

    m = Model({"agents": {"opus": {"display_name": "Opus"}}})
    check("model: no vehicles before a read", m.vehicles_snapshot(1000.0) is None)
    m.ingest({"vehicles": dict(v, t=1000.0)}, now=1000.0)
    s = m.vehicles_snapshot(1012.0)
    a, b, c, u, tank = s["rows"]
    check("model: positions rounded, ages counted on to the snapshot (12 s later)",
          a["position"] == {"x": -148.4, "y": -543.1} and a["age_s"] == 12 and c["age_s"] == 312 and s["read_age_s"] == 12, s)
    check("model: the route's sender and its age (7200 ticks before the read, then 12 s)", a["sent_by"] == "opus" and a["sent_age_s"] == 132, a)
    check("model: the rider, the destination and the route's targets", b["driver"] == "astra" and a["destination"] == {"x": -60.25, "y": -300.5}
          and a["route_targets"] == 3, (a, b))
    check("model: an unseen one has no position or age", u.get("unseen") is True and "position" not in u and "age_s" not in u, u)
    check("model: no tick fields left (seen_tick, sent_tick)", not any(k in r for r in s["rows"] for k in ("seen_tick", "sent_tick")), s)
    snap = m.snapshot(1012.0)
    check("model: the snapshot carries vehicles", snap.get("vehicles", {}).get("total") == 3, snap.get("vehicles"))

    pv = push_live.public_vehicles(s)
    check("push_live: the rows with their facts", len(pv["rows"]) == 5 and pv["rows"][0]["destination"] == {"x": -60.2, "y": -300.5}
          and pv["total"] == 3 and pv["read_age_s"] == 12, pv)
    check("push_live: only the listed keys", all(set(r) <= set(push_live.VEHICLE_KEYS) | {"position", "destination", "remote_target"}
                                                for r in pv["rows"]), pv)
    check("push_live: none before a read or with none", push_live.public_vehicles(None) is None and push_live.public_vehicles({"rows": []}) is None)
    check("push_live: at most 64", len(push_live.public_vehicles({"rows": [dict(a, unit_number=i) for i in range(100)]})["rows"]) == 64)
    state = push_live.public_state({"vehicles": s, "agents": []})
    check("the public state carries vehicles", state.get("vehicles", {}).get("rows", [{}])[0].get("unit_number") == 23036938, state.get("vehicles"))
    check("about 250 bytes a row", max(len(json.dumps(r, separators=(",", ":"))) for r in pv["rows"]) < 300, pv["rows"])

    if not shutil.which("node"):
        print("vehicles: the page part skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), json.dumps(pv)], capture_output=True, text=True, timeout=30)
    check("node", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    n, g = o["nauvis"], o["gleba"]
    check("the layer is listed, on by default, in the Team group", o["layer"] and o["group"] == ["team"], o)
    check("Nauvis: its two spidertrons with a position and the tank (the unseen one is not drawn)", n["n"] == 3 and len(n["marks"]) == 3, n)
    check("the tank: a dot, with its dashed line to its drive's target", n["marks"][2]["car"] and not n["marks"][0]["car"]
          and n["marks"][2]["tx"] is not None, n["marks"])
    check("hover: the tank, driven by remote view",
          any(t.startswith("Tank 311799 · x -140, y -450 · Nauvis · seen 12 s ago (in sight) · driven by Luna by remote view · to x -80, y -450")
              for t in n["hits"]), n["hits"])
    check("the first has its dashed line to its destination; the one out of sight is grey",
          n["marks"][0]["tx"] is not None and n["marks"][0]["seen"] and n["marks"][1]["tx"] is None and not n["marks"][1]["seen"], n["marks"])
    hover = [t for t in n["hits"] if t.startswith("Spidertron 23036938")]
    check("hover: id, place, position age, controller, sender and destination",
          hover == ["Spidertron 23036938 · x -149, y -544 · Nauvis · seen 12 s ago (in sight) · no driver · route sent by Opus 2 min ago · "
                    "to x -61, y -301 (3 targets)"], n["hits"])
    check("hover: one out of sight says when it was last seen",
          any(t.startswith("Spidertron 27069154") and "last seen 5 min ago (out of sight since)" in t for t in n["hits"]), n["hits"])
    check("Gleba: the one there, driven by its rider", g["n"] == 1 and any("driven by Astra" in t for t in g["hits"]), g)
    check("off: nothing drawn", o["off"]["marks"] == [], o["off"])
    check("far away: pinned to the edge, no line, its distance from the base", all(mk["tx"] is None for mk in o["far"]["marks"])
          and any("tiles from the base" in t for t in o["far"]["hits"] if t.startswith("Spidertron")), o["far"])
    check("its toggle says none or not read", o["none"].startswith("none: no vehicle of ours on Nauvis") and o["unread"].startswith("not read"), o)
    check("painted: a square each spidertron", o["painted"] >= 4, o["painted"])
    print("vehicles: ok")


if __name__ == "__main__":
    main()
