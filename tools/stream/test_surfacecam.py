#!/usr/bin/env python3
"""Build, work and attention shots on the request's surface (d27 batch271 WS): python3 tools/stream/test_surfacecam.py

shift86 09:56: Astra's character stood on Aquilo while she marked old poles on Nauvis for deconstruction by remote
(surface="nauvis"), and at 10:03 placed pole ghosts there. The director framed "build: Astra · marked for
deconstruction" at (-89.5, 156.5) on Aquilo, and the attention inset "Astra placing medium electric pole ghosts 165 m
west" on Aquilo too: empty ice. Every part fails on main.

1. work.py: DidFeed, WorkFeed rows and attention points keep the request's surface; a row naming none takes the body's
   while it is fresh (live.py), and stays unknown after.
2. onecam: the build spot is on the request's surface, also when its coordinates are near the body's on another planet;
   a surface not known makes no spot; a surface naming a platform is no ground build.
3. model.py and onecam: the attention point is on Nauvis, far, "placing medium electric pole ghosts on Nauvis"; the
   inset frames Nauvis there. A surface naming a platform is that platform.
4. live.py and model.py: a remote build on another planet is away work, whatever the coordinates; its label names the
   planet.
5. director_replay: the replay's build rows are on the request's surface.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from test_idlecam import rows, T0  # noqa: E402
from onecam import OneCam  # noqa: E402
from model import Model  # noqa: E402
import airtime, director_replay, live, work  # noqa: E402

# Astra's requests of shift86 (runs/shift86/astra/journal.jsonl, 16:56:28Z and 17:03:02Z)
DECON = {"surface": "nauvis", "area": {"left_top": {"x": -89.6, "y": 156.4}, "right_bottom": {"x": -89.4, "y": 156.6}},
         "entity_names": ["medium-electric-pole"]}
POLES = {"surface": "nauvis", "entities": [{"name": "medium-electric-pole", "position": {"x": -187.5, "y": 11.5}}]}
BODY = {"x": -22.4, "y": 17.8}  # her character on Aquilo
VIEW = {"name": "Loom", "surface": "platform-7", "hub": {"x": 0, "y": 0},
        "bounds": {"left": -20, "top": -8, "right": 20, "bottom": 10}}


def feeds():
    feed = work.DidFeed()
    for r in rows("a1", T0, "deconstruct", DECON, {"changed": 1, "mode": "mark"}):
        feed.ingest("astra", r)
    d = feed.current("astra", T0 + 1)
    assert d["surface"] == "nauvis" and d["position"] == {"x": -89.5, "y": 156.5}, d
    feed.body_surface("astra", "aquilo", T0 + 1)
    assert feed.current("astra", T0 + 2)["surface"] == "nauvis", "the request's surface stands"
    plain = dict(POLES)
    del plain["surface"]
    for r in rows("a2", T0 + 10, "place_ghosts", plain, {"placed": 1}):
        feed.ingest("astra", r)
    assert feed.current("astra", T0 + 11)["surface"] is None
    feed.body_surface("astra", "aquilo", T0 + 11)
    assert feed.current("astra", T0 + 12)["surface"] == "aquilo", "none named: the body's, read while fresh"
    for r in rows("a3", T0 + 20, "place_ghosts", plain, {"placed": 1}):
        feed.ingest("sol", r)
    feed.body_surface("sol", "nauvis", T0 + 20 + work.DID_SURFACE_S + 1)
    assert feed.current("sol", T0 + 60)["surface"] is None, "a row read too late (a restart's tail) stays unknown"
    live_src = open(os.path.join(HERE, "live.py")).read()
    assert 'self.work.did.body_surface(a["name"], a.get("surface") or "nauvis", now)' in live_src
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "astra"))
    j = os.path.join(d, "astra", "journal.jsonl")
    open(j, "w").close()
    wf = work.WorkFeed(d, ["astra"])
    wf.poll()
    with open(j, "a") as f:
        for r in rows("a4", T0 + 30, "place_ghosts", POLES, {"placed": 1}):
            f.write(json.dumps(r) + "\n")
    out = wf.poll()
    assert [(w["action"], w["surface"]) for w in out] == [("place_ghosts", "nauvis")], out
    att = wf.take_attention()
    assert [(a["action"], a["surface"]) for a in att] == [("place_ghosts", "nauvis")], att
    print("1. the request's surface on the build rows, work rows and attention points; the body's only while fresh: ok")
    return wf, j


def team(t, did):
    astra = agent("astra", 0, 0, 2, activity="thinking", active=False)
    astra.update(surface="aquilo", position=dict(BODY))
    astra["did"] = did if did and 0 <= t - did["t"] <= work.DID_KEEP else None
    sol = agent("sol", 300, 0, 20, activity="thinking", active=False)
    return {"agents": [sol, astra], "alerts": []}


def run(did, secs=90):
    d = OneCam(SLOTS[:3], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0, bow=False)
    d.started = d.onair_since = T0 - 300
    t = T0 - 120
    while t < T0:
        d.step(team(t, None), t)
        t += 1
    seen = []
    while t < T0 + secs:
        d.step(team(t, did), t)
        cur = d.state[d.onair]
        if cur.get("did"):
            seen.append((t - T0, cur.get("surface"), cur.get("position")))
        t += 1
    return d, seen


def build_spots():
    did = {"action": "deconstruct", "t": T0, "position": {"x": -89.5, "y": 156.5}, "platform": None, "surface": "nauvis"}
    d, seen = run(did)
    assert seen and seen[0][0] <= 30, (seen, d.cuts[-4:])
    assert {s[1] for s in seen} == {"nauvis"}, seen
    assert seen[0][2] == {"x": -89.5, "y": 156.5}, seen[0]
    # ghosts on Nauvis a few tiles from where her body stands on Aquilo (by coordinates): still away
    near = dict(did, position={"x": BODY["x"] + 4, "y": BODY["y"]})
    _, seen = run(near)
    assert seen and {s[1] for s in seen} == {"nauvis"}, seen
    _, seen = run(dict(did, surface=None))
    assert not seen, ("a surface not known: no spot", seen)
    a = team(T0, did)["agents"][1]
    cam = OneCam(SLOTS[:3], lambda body: {"ok": True}, None, trio=False)
    spot = cam.did_spot(a, T0 + 1)
    assert spot["surface"] == "nauvis" and spot["label"] == "Astra · marked for deconstruction on Nauvis", spot
    cam.plat_rows = {"Loom": {"name": "Loom", "view": VIEW}}
    for s in ("Loom", "platform-7"):
        a["did"] = dict(did, surface=s)
        assert cam.did_row(a, T0 + 1) is None, s
    a["did"] = {k: v for k, v in did.items() if k != "surface"}  # a row from before batch271: the body's surface
    assert cam.did_spot(a, T0 + 1)["surface"] == "aquilo"
    print("2. the build spot on the request's surface (Nauvis, not Aquilo), near coordinates too; none when not known: ok")


def attention():
    m = Model({"agents": {"astra": {}, "sol": {}}})
    ag = m.agent("astra")
    ag.surface, ag.position, ag.display_name = "aquilo", dict(BODY), "Astra"
    x = dict(work.attention.point("place_ghosts", POLES), agent="astra")
    m._ingest_attention(x, T0)
    row = m.attention_row(ag, T0 + 1)
    assert row["surface"] == "nauvis" and row["far"] and row["dist"] is None, row
    assert row["text"] == "placing medium electric pole ghosts on Nauvis", row["text"]
    a = {"name": "astra", "display_name": "Astra", "surface": "aquilo", "position": dict(BODY), "attention": row}
    cam = OneCam(SLOTS[:3], lambda body: {"ok": True}, None, trio=False)
    att = cam.attention_far(a, {"astra": a}, T0 + 1)
    assert att, "far: on another planet"
    shot = cam.attention_target(att, "astra", "Astra", T0 + 20)
    assert shot["surface"] == "nauvis" and shot["position"] == {"x": -187.5, "y": 11.5}, shot
    assert shot["work"] == "Astra placing medium electric pole ghosts on Nauvis", shot["work"]
    # a request on her own planet still reads as a distance
    m._ingest_attention(dict(work.attention.point("place_ghosts", dict(POLES, surface="aquilo")), agent="astra"), T0 + 2)
    assert m.attention_row(ag, T0 + 3)["text"] == "placing medium electric pole ghosts 165 m west"
    # surface= naming a platform: that platform
    m.space = {"platforms": [{"name": "Loom", "view": VIEW}]}
    m._ingest_attention(dict(work.attention.point("inspect", {"surface": "Loom", "position": {"x": 1, "y": 2}}),
                             agent="astra"), T0 + 4)
    row = m.attention_row(ag, T0 + 5)
    assert row["platform"] == "Loom" and row["surface"] == "platform-7" and row["text"] == "inspecting on Loom", row
    print("3. attention: on Nauvis, far, \"placing medium electric pole ghosts on Nauvis\", the inset there: ok")


def away_work(wf, j):
    src = live.LiveSource.__new__(live.LiveSource)  # only observe_work: no harness needed
    src.work = wf
    with open(j, "a") as f:
        for r in rows("a5", T0 + 40, "deconstruct", dict(DECON, area={"left_top": {"x": -30, "y": 10},
                                                                       "right_bottom": {"x": -28, "y": 12}}), {"changed": 1}):
            f.write(json.dumps(r) + "\n")
        for r in rows("a6", T0 + 41, "deconstruct", {"area": {"left_top": {"x": -30, "y": 10},
                                                              "right_bottom": {"x": -28, "y": 12}}}, {"changed": 1}):
            f.write(json.dumps(r) + "\n")
    body = [{"name": "astra", "position": dict(BODY), "surface": "aquilo"}]
    out = src.observe_work(body, {})
    assert [(w["surface"], w["position"]) for w in out] == [("nauvis", {"x": -29.0, "y": 11.0})], out
    m = Model({"agents": {"astra": {}}})
    ag = m.agent("astra")
    ag.surface, ag.display_name = "aquilo", "Astra"
    m._ingest_work(dict(out[0], at="x"), T0 + 41)
    assert m.work[-1]["surface"] == "nauvis", m.work[-1]
    assert m.work[-1]["label"] == "Astra deconstructing at (-29, 11) on Nauvis (from afar)", m.work[-1]["label"]
    print("4. a remote build on another planet is away work, whatever its coordinates; its label names Nauvis: ok")


def replay():
    j = airtime.Journal("astra")
    j.read(rows("s0", T0 - 5, "status", {}, {"position": dict(BODY), "surface": "aquilo"}) +
           rows("s1", T0, "deconstruct", DECON, {"changed": 1}) +
           rows("s2", T0 + 20, "place_ghosts", dict(POLES, surface="aquilo"), {"placed": 1}) +
           rows("s3", T0 + 40, "place_ghosts", {"entities": POLES["entities"]}, {"placed": 1}))
    w = director_replay.World({"astra": j}, [], vehicle_interest=True)
    got = [w.snapshot(T0 + k)["agents"][0]["did"]["surface"] for k in (1, 21, 41)]
    assert got == ["nauvis", "aquilo", "aquilo"], got
    print("5. director_replay: build rows on the request's surface, else the body's: ok")


def main():
    wf, j = feeds()
    build_spots()
    attention()
    away_work(wf, j)
    replay()
    print("test_surfacecam: ok")


if __name__ == "__main__":
    main()
