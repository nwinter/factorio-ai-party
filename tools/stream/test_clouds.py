#!/usr/bin/env python3
"""Pollution and spore clouds on the map (clouds.py, live.py, model.py, onecam.py, serve.py; viewer Joonazan, 13:00 on
2026-10-14: "can you show a shot of Gleba's spore cloud?"): python3 tools/stream/test_clouds.py

1. clouds.normalise: the harness's `clouds` rows -> one row per surface with a cloud ("Spores on Gleba", the game's map
   colour, cells, chunks, max, total, the nests reached); Vulcanus (no pollutant, cells {} from Lua) is left out.
2. clouds.shot frames every polluted chunk and every nest reached, for the on-air hole.
3. live.py reads `clouds` only from a runtime that lists it, once a minute; model.py carries it in the snapshot.
4. The director: the operator's call (POST /cloud) goes on air as a map shot of that surface, labelled, held
   cloud_hold, released after; an operator follow refuses it; a segment makes it wait. On its own, the director shows
   a cloud that reached nests it had not reached before (none at the start: old news), at most every cloud_every.
5. A cloud shot is no base map for mapframes.py and the hosts (onair.map None, onair.cloud set); the camera row
   carries map_view (position, surface, the zoom sent) for the overlay.
6. site/push_live.py passes the clouds to the site (colour, cells, reached nests), the most polluted CLOUD_CELLS.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clouds  # noqa: E402
from mock import MockSource  # noqa: E402
from model import Model  # noqa: E402
from onecam import onair_info  # noqa: E402
from test_onecam import agent, world  # noqa: E402

ROWS = MockSource.cloud_rows(3600)


def normalise():
    c = clouds.normalise(ROWS)
    assert set(c) == {"nauvis", "gleba"}, c.keys()
    g = c["gleba"]
    assert g["label"] == "Spores on Gleba" and g["pollutant"] == "spores", g["label"]
    assert g["color"]["css"] == "rgb(140, 140, 0)" and g["color"]["a"] == 0.584, g["color"]
    assert c["nauvis"]["label"] == "Pollution on Nauvis" and c["nauvis"]["color"]["css"] == "rgb(140, 0, 0)"
    assert g["chunks"] == len(g["cells"]) and g["max"] == max(x[2] for x in g["cells"]) and g["reached"][0]["x"] == -150
    # no colour in the read: the game's own; 0..255 colours scaled
    c2 = clouds.normalise([{"surface": "gleba", "pollutant": {"name": "spores"}, "cells": [[0, 0, 3]]},
                           {"surface": "nauvis", "pollutant": {"name": "pollution", "color": {"r": 140, "g": 0, "b": 0, "a": 150}},
                            "cells": [[1, 1, 2.25]]}])
    assert c2["gleba"]["color"]["css"] == "rgb(140, 140, 0)", c2["gleba"]["color"]
    assert c2["nauvis"]["color"]["r"] == 0.549 and c2["nauvis"]["color"]["a"] == 0.588, c2["nauvis"]["color"]
    assert clouds.normalise([{"surface": "x", "pollutant": {"name": "pollution"}, "cells": {}}]) == {}
    print(f"normalise: ok (gleba {g['chunks']} chunks, max {g['max']}; nauvis {c['nauvis']['chunks']} chunks)")


def framing():
    g = clouds.normalise(ROWS)["gleba"]
    sh = clouds.shot(g)
    xs = [x[0] for x in g["cells"]] + [-150 // 32]
    ys = [x[1] for x in g["cells"]] + [330 // 32]
    w = (max(xs) - min(xs) + 3) * 32
    h = (max(ys) - min(ys) + 3) * 32
    assert sh["size"] == [w, h], (sh, w, h)
    assert sh["position"] == {"x": (min(xs) - 1 + max(xs) + 2) * 16, "y": (min(ys) - 1 + max(ys) + 2) * 16}, sh
    # the whole box shows in the hole: width within the cropped client, height within 1080 px
    frac = (1208 / 1032) / (1920 / 1080)
    assert w * 32 * sh["zoom"] <= 1920 * frac + 1 and h * 32 * sh["zoom"] <= 1080 + 1, sh
    assert clouds.shot({"cells": []}) is None
    print(f"framing: ok (gleba {sh['size']} tiles at zoom {sh['zoom']})")


class FakeHarness:
    def __init__(self, reads):
        self.reads = reads
        self.calls = []

    def operator_read(self, action, args=None):
        self.calls.append(action)
        return {"clouds": ROWS, "tick": 1}, 1

    def dispatch(self, action, args=None, **who):
        return {"operator_reads": self.reads, "actions": {}}, 1


def live_and_model():
    from live import LiveSource
    src = LiveSource.__new__(LiveSource)  # (no probe: only the clouds read)
    src.h = FakeHarness(["clouds"])
    src.has_clouds, src.next_clouds, src.clouds_every = False, 0, 60.0
    obs, errors = {}, {}
    src.observe_clouds(obs, errors)
    assert "clouds" not in obs and not src.h.calls  # an older runtime: not asked
    src.agents_cfg, src.caps = {}, {"harness": True}
    src.board_probe()
    assert src.has_clouds
    src.observe_clouds(obs, errors)
    assert obs["clouds"] is ROWS and src.h.calls == ["clouds"], obs
    obs2 = {}
    src.observe_clouds(obs2, errors)
    assert "clouds" not in obs2 and src.h.calls == ["clouds"]  # once a minute
    m = Model({"agents": {}})
    m.ingest({"agents": [], "clouds": ROWS}, now=1000)
    snap = m.snapshot(1030)
    assert [c["surface"] for c in snap["clouds"]] == ["nauvis", "gleba"] and snap["clouds"][1]["age_s"] == 30, snap["clouds"]
    m.ingest({"agents": []}, now=1040)  # no read this round: the last stands
    assert len(m.snapshot(1041)["clouds"]) == 2
    print("live and model: ok")


def director():
    d, sent = world()
    team = [agent("luna", 0, 0, 5), agent("sol", 10, 0, 1)]
    t = 1000.0

    def step(snap_clouds=None, now=None, segment=None):
        s = {"agents": team, "alerts": [], "clouds": snap_clouds if snap_clouds is not None else rows}
        return d.step(s, now, segment)
    m = Model({"agents": {}})
    m.ingest({"agents": [], "clouds": ROWS}, now=t)
    rows = m.snapshot(t)["clouds"]
    step(now=t)
    t += 200
    step(now=t)
    assert d.cloud_seen and d.cloud_due is None  # the nests reached at the start are old news
    code, reply = d.request_cloud("mars", now=t)
    assert code == 400 and set(reply["clouds"]) == {"nauvis", "gleba"}, reply
    code, reply = d.request_cloud(None, 30, "nick", now=t)  # no surface: spores first
    assert code == 200 and reply["surface"] == "gleba" and reply["label"] == "Spores on Gleba" and reply["seconds"] == 30, reply
    seg = {"id": "s1", "label": "Spotlight", "zoom": 1.0, "until": t + 60}
    d.step({"agents": team, "alerts": [], "clouds": rows}, t, None)
    body = next(b for b in reversed(sent) if b.get("map"))
    assert body["surface"] == "gleba" and body["smooth"] is False, body
    sh = clouds.shot(rows[1], frac=d.cfg["view_frac"])
    assert body["position"] == sh["position"] and body["zoom"] == round(sh["zoom"], 2), (body, sh)
    t += 2
    cams = step(now=t)
    main = cams["main"]
    assert main["map"] == "Spores on Gleba" and main["cloud"]["surface"] == "gleba", main
    assert main["map_view"] == {"position": sh["position"], "surface": "gleba", "zoom": body["zoom"], "size": sh["size"]}
    info = onair_info({"agents": team}, cams)
    assert info["map"] is None and info["cloud"]["label"] == "Spores on Gleba", info  # no terrain frame (mapframes.py)
    # held cloud_hold (30 s asked), then the story again and the map client released
    t += 20
    assert step(now=t)["main"].get("cloud")
    t += 15
    step(now=t)
    t += 3
    cams = step(now=t)
    assert not cams["main"].get("map"), cams["main"]
    assert any(b.get("release") for b in sent), "the map client is released"
    # a segment on air: the call waits for it
    code, _ = d.request_cloud("nauvis", now=t)
    step(now=t, segment=seg)
    assert d.cloud_req, "waits for the segment"
    t += 61
    step(now=t)
    t += 2
    assert step(now=t)["main"].get("cloud", {}).get("surface") == "nauvis"
    # an operator follow refuses it
    d.set_follow("sol", t + 600, now=t)
    assert d.request_cloud("gleba", now=t)[0] == 409
    d.set_follow(None, 0)
    # on its own: a new nest reached on Gleba, after cloud_every since the last one it chose
    t += 200
    step(now=t)
    newer = [dict(r, reached=r["reached"] + [{"x": -200, "y": 360, "tick": 2, "spawners": 1}]) if r["surface"] == "gleba" else r
             for r in rows]
    d.last_program_cut = t - 100
    step(newer, now=t)  # due, and framed on a standby in the same step
    assert d.cloud_due is None and d.cloud_shots[-1][1:] == ("gleba", "reached 1 new nest"), d.cloud_shots
    t += 2
    main = step(newer, now=t)["main"]
    assert main.get("cloud", {}).get("why") == "reached 1 new nest", main
    # the next new nest within cloud_every: not shown
    t += 300
    step(newer, now=t)
    newest = [dict(r, reached=r["reached"] + [{"x": -260, "y": 360, "tick": 3, "spawners": 1}]) if r["surface"] == "gleba" else r
              for r in newer]
    step(newest, now=t + 1)
    assert d.cloud_due is None
    print(f"director: ok ({len(d.cloud_shots)} cloud shots: {[s[2] for s in d.cloud_shots]})")


def site():
    """push_live.py: the clouds go to the site with their colour, cells and reached nests; past CLOUD_CELLS cells in
    all, the most polluted are kept."""
    sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
    import push_live
    m = Model({"agents": {}})
    m.ingest({"agents": [], "clouds": ROWS}, now=1000)
    out = push_live.public_state(m.snapshot(1000))["clouds"]
    assert [c["surface"] for c in out] == ["nauvis", "gleba"] and out[1]["color"] == {"r": 0.549, "g": 0.549, "b": 0.0, "a": 0.584}
    assert out[1]["reached"] == [{"x": -150, "y": 330}] and len(out[1]["cells"]) == 29, out[1]
    keep, push_live.CLOUD_CELLS = push_live.CLOUD_CELLS, 10
    try:
        small = push_live.public_clouds(m.snapshot(1000)["clouds"])
    finally:
        push_live.CLOUD_CELLS = keep
    kept = [c for r in small for c in r["cells"]]
    every = sorted((c[2] for r in m.snapshot(1000)["clouds"] for c in r["cells"]), reverse=True)
    assert len(kept) == 10 and min(c[2] for c in kept) == every[9], (len(kept), every[:10])
    print("site: ok")


OVERLAY_JS = r"""
// overlay.js renderCloud on a recording canvas: the calls it makes and the key it returns
const fs = require('fs');
const code = fs.readFileSync(process.argv[2], 'utf8');
function grab(name) {
  const i = code.indexOf('  function ' + name + '(');
  let depth = 0;
  for (let k = code.indexOf('{', i); k < code.length; k++) {
    if (code[k] === '{') depth++;
    else if (code[k] === '}' && --depth === 0) return code.slice(i, k + 1);
  }
}
const ops = [];
function node(tag) {
  const n = { tag, children: [], dataset: {}, style: {}, className: '',
    classList: { set: new Set(), add(c) { this.set.add(c); }, remove(c) { this.set.delete(c); } },
    insertBefore(c) { this.children.unshift(c); },
    querySelector(sel) { return this.children.find((c) => sel === 'canvas.' + c.className) || null; } };
  if (tag === 'canvas') n.getContext = () => new Proxy({}, {
    get: (t, k) => (k in t ? t[k] : (...a) => ops.push([k, ...a])),
    set: (t, k, v) => { t[k] = v; ops.push(['set', k, v]); return true; } });
  return n;
}
global.document = { createElement: node };
eval(grab('fmtAmount') + grab('renderCloud') + '; global.renderCloud = renderCloud;');
const s = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const frame = node('div'); frame.clientWidth = 1208; frame.clientHeight = 1032;
const key = renderCloud(frame, s.cameras.main, s);
const none = renderCloud(frame, { map: 'Base map' }, s);
process.stdout.write(JSON.stringify({ ops, key, none, on: [...frame.children[0].classList.set] }));
"""


def overlay():
    """The overlay's layer (the first on-air shot, 13:59: the olive cells were lost on Gleba's yellow-green ground, and
    the key overlapped the bar): fills from 0.45 alpha, a hatch clipped to the cells, the cloud's edge only (dark,
    then the hue at full strength), and the key returned for the camera's label."""
    import json, shutil, subprocess, tempfile
    if not shutil.which("node"):
        print("overlay: skipped (no node)")
        return
    cloud = dict(clouds.normalise(ROWS)["gleba"], cells=[[0, 0, 15.6], [1, 0, 2.0]], chunks=2, max=15.6)
    state = {"clouds": [cloud], "cameras": {"main": {"map": "Spores on Gleba", "map_view": {
        "position": {"x": 32, "y": 16}, "surface": "gleba", "zoom": 0.25, "size": [64, 32]}}}}
    with tempfile.TemporaryDirectory() as d:
        js, sp = os.path.join(d, "r.js"), os.path.join(d, "s.json")
        open(js, "w").write(OVERLAY_JS)
        json.dump(state, open(sp, "w"))
        r = subprocess.run(["node", js, os.path.join(HERE, "static", "overlay.js"), sp], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    ops = o["ops"]
    fills = [op for op in ops if op[0] == "fillRect"]
    alphas = [float(op[2][:-1].split(",")[-1]) for op in ops if op[0] == "set" and op[1] == "fillStyle"]
    k = 1032 / 1080 * 32 * 0.25  # px a tile
    assert [(round(f[1]), round(f[2]), round(f[3] - 0.5)) for f in fills] == [(round(604 - 32 * k), round(516 - 16 * k), round(32 * k)),
                                                                               (604, round(516 - 16 * k), round(32 * k))], fills
    assert alphas == [0.85, round(0.45 + 0.4 * __import__("math").log1p(2) / __import__("math").log1p(15.6), 3)], alphas
    assert ["clip"] == [op[0] for op in ops if op[0] == "clip"], "the hatch is clipped to the cells"
    strokes = [i for i, op in enumerate(ops) if op[0] == "stroke"]
    assert len(strokes) == 5, strokes  # the hatch, the dark edge, the bright edge, the reached nest's two rings
    sets = [op for op in ops if op[0] == "set" and op[1] == "strokeStyle"]
    assert [s_[2] for s_ in sets][:3] == ["rgba(0, 0, 0, 0.35)", "rgba(0, 0, 0, 0.85)", "rgb(255, 255, 0)"], sets
    # 2 cells side by side: 6 outer sides, the one they share left out
    edge_moves = [op for op in ops[strokes[0] + 1:strokes[1]] if op[0] == "moveTo"]
    assert len(edge_moves) == 6, edge_moves
    assert o["key"] == {"rgb": "140, 140, 0", "bright": "255, 255, 0",
                        "text": "up to 15.6 spores per chunk · 2 chunks · 1 nest reached"}, o["key"]
    assert o["none"] is None and o["on"] == [], o  # a map shot of a surface without a cloud: the layer goes
    print("overlay: ok")


if __name__ == "__main__":
    normalise()
    site()
    overlay()
    framing()
    live_and_model()
    director()
    print("test_clouds: ok")
