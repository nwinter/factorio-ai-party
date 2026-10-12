#!/usr/bin/env python3
"""Following the work and platform shots: python3 tools/stream/test_work.py

1. work.py tails the agents' fh journals from their end (no replay), keeps place/paste/deconstruct requests, finds
   where they land (platform, position / area / ghost centre) and survives a line split across polls.
2. live.py keeps what lands away from the body: on a platform (not one the body is aboard), or 48+ tiles off.
3. model.py labels it ("Sol building on Solstice (from the ground)") with the platform's surface from PLATFORM_LUA.
4. director.py cuts the last secondary camera to it (the whole platform, surface named, zoom sent as computed), holds
   15 s, spaces work cuts, and the page gets the label.
5. The space and space_moment segments put the platform itself on the main camera.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from director import Director  # noqa: E402
from model import Model, platform_shot  # noqa: E402
from segments import Segments  # noqa: E402
from work import WorkFeed, target_of  # noqa: E402
import harness as hz  # noqa: E402
import live  # noqa: E402

VIEW = {"name": "Solstice", "surface": "platform-1", "hub": {"x": 0, "y": 0},
        "bounds": {"left": -20, "top": -8, "right": 20, "bottom": 10}}


def req(action, args, at="2026-10-12T05:00:00.000Z"):
    return json.dumps({"at": at, "event": "request", "request": {"id": "x", "action": action, "bot": "sol", "args": args}})


def feed_tests(d):
    os.makedirs(os.path.join(d, "sol")), os.makedirs(os.path.join(d, "astra"))
    j = os.path.join(d, "sol", "journal.jsonl")
    open(j, "w").write(req("place_ghosts", {"platform": "Old", "entities": []}) + "\n")  # before the service started
    wf = WorkFeed(d, ["sol", "astra", "nobody"])
    assert wf.poll() == []  # starts at the end: the past is not replayed
    with open(j, "a") as f:
        f.write(req("place_ghosts", {"platform": "Solstice", "entities": [
            {"name": "asteroid-collector", "position": {"x": 4, "y": -6}}, {"name": "inserter", "position": {"x": 6, "y": -6}}]}) + "\n")
        f.write(json.dumps({"at": "t", "event": "response", "response": {"ok": True, "result": {"request": "x"}}}) + "\n")
        f.write(req("observe", {"platform": "Solstice"}) + "\n")  # a view, not work
        f.write(req("paste", {"position": {"x": 300, "y": 40}, "blueprint": "smelter"})[:40])  # half a line
    out = wf.poll()
    assert [(w["action"], w["platform"], w["position"]) for w in out] == [("place_ghosts", "Solstice", {"x": 5.0, "y": -6.0})], out
    with open(j, "a") as f:
        f.write(req("paste", {"position": {"x": 300, "y": 40}, "blueprint": "smelter"})[40:] + "\n")
    out = wf.poll()
    assert [(w["action"], w["verb"], w["position"]) for w in out] == [("paste", "pasting a blueprint", {"x": 300.0, "y": 40.0})], out
    assert target_of({"area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 10, "y": 20}}}) == (None, {"x": 5.0, "y": 10.0})
    assert target_of({"platform": "Solstice"}) == ("Solstice", None)
    return wf, j


def live_tests(d, wf, j):
    src = live.LiveSource.__new__(live.LiveSource)  # only observe_work: no harness needed
    src.work = wf
    with open(j, "a") as f:
        for args in ({"platform": "Solstice", "entities": [{"name": "solar-panel", "position": {"x": 1, "y": 1}}]},
                     {"position": {"x": 10, "y": 10}},           # deconstruct next to the body: the body cam shows it
                     {"position": {"x": 200, "y": 10}}):         # 190 tiles off: away
            f.write(req("deconstruct" if "platform" not in args else "place_ghosts", args) + "\n")
    agents = [{"name": "sol", "position": {"x": 10, "y": 12}, "surface": "nauvis"}]
    out = src.observe_work(agents, {})
    assert [(w["platform"], w["position"] and w["position"]["x"], w["surface"]) for w in out] == \
        [("Solstice", 1.0, None), (None, 200.0, "nauvis")], out
    with open(j, "a") as f:
        f.write(req("place_ghosts", {"platform": "Solstice", "entities": []}) + "\n")
    aboard = [{"name": "sol", "position": {"x": 0, "y": 0}, "surface": "platform-1", "platform": "Solstice"}]
    assert src.observe_work(aboard, {}) == []  # aboard Solstice: the body's camera is already there


def model_and_director_tests():
    run = {"agents": {"sol": {}, "astra": {}, "luna": {}}}
    m = Model(run)
    t = time.time()
    agents = [{"name": n, "display_name": n.title(), "position": {"x": 10 * i, "y": 0}, "alive": True, "active": "mine"}
              for i, n in enumerate(run["agents"])]
    space = {"rockets": 3, "planets": ["nauvis"], "platforms": [{"name": "Solstice", "at": "nauvis", "hub": True, "view": VIEW}]}
    m.ingest({"agents": agents, "space": space}, t)
    work = [{"agent": "sol", "action": "place_ghosts", "verb": "building", "platform": "Solstice", "position": {"x": 1, "y": 1},
             "surface": None, "at": "a1"}]
    m.ingest({"agents": agents, "space": space, "work": work}, t + 1)
    m.ingest({"agents": agents, "space": space, "work": [dict(work[0], at="a2")]}, t + 5)  # the same job: one item
    snap = m.snapshot(t + 5)
    assert [w["label"] for w in snap["work"]] == ["Sol building on Solstice (from the ground)"], snap["work"]
    assert snap["work"][0]["surface"] == "platform-1" and snap["space"]["platforms"][0]["view"] == VIEW

    sent = []
    d = Director([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}],
                 lambda b: sent.append(b) or {"ok": True}, None)
    d.step(snap, t + 5)
    cam3 = [b for b in sent if b["player"] == 5][-1]
    shot = platform_shot(VIEW)
    assert cam3["surface"] == "platform-1" and cam3["position"] == shot["position"] and cam3["zoom"] == shot["zoom"], cam3
    pub = d.public(t + 6)
    assert pub["cam3"]["work"] == "Sol building on Solstice (from the ground)" and pub["cam3"]["surface"] == "platform-1"
    assert pub["cam3"]["agents"] == ["sol"]
    assert all("sol" not in pub.get(s, {}).get("agents", []) for s in ("main", "cam2")), pub  # not its body too
    n = len(sent)
    d.step(m.snapshot(t + 12), t + 12)
    assert not [b for b in sent[n:] if b["player"] == 5], "held for work_hold"
    d.step(m.snapshot(t + 21), t + 21)
    assert "work" not in d.public(t + 21).get("cam3", {}), "back to directing after 15 s"
    # far work on the body's own surface: a position, zoom scaled like any secondary view
    m.ingest({"agents": agents, "work": [{"agent": "astra", "action": "paste", "verb": "pasting a blueprint",
                                          "platform": None, "position": {"x": 300, "y": 40}, "surface": "nauvis", "at": "b"}]}, t + 30)
    snap = m.snapshot(t + 30)
    assert snap["work"][-1]["label"] == "Astra pasting a blueprint at (300, 40) (from afar)"
    d.step(snap, t + 30)
    assert "work" not in d.public(t + 30).get("cam3", {}), "work cuts are spaced (45 s)"
    d.last_work_cut = -1e9
    d.work_seen.discard(snap["work"][-1]["id"])
    n = len(sent)
    d.step(snap, t + 31)
    cam3 = [b for b in sent[n:] if b["player"] == 5][-1]
    assert cam3["position"] == {"x": 300, "y": 40} and cam3["surface"] == "nauvis" and cam3["zoom"] == round(0.9 * 2.6, 2), cam3
    return m


def segment_tests(m):
    t = time.time()
    seg = Segments(spacing=0)
    snap = m.snapshot(t)
    seg.step(snap, t)
    code, rep = seg.request({"type": "space"}, t)
    assert code == 200 and rep["facts"]["shown"] == "Solstice", rep
    seg.step(snap, t + 0.5)  # a request starts on the next step
    cam = seg.camera()
    assert cam["surface"] == "platform-1" and cam["exact_zoom"] and cam["position"] == platform_shot(VIEW)["position"], cam
    sent = []
    d = Director([{"slot": "main", "player": 3}], lambda b: sent.append(b) or {"ok": True}, None)
    d.step(snap, t + 1, seg.camera())
    main = sent[-1]
    assert main["surface"] == "platform-1" and main["zoom"] == platform_shot(VIEW)["zoom"], main  # not x1.5
    # a first-platform moment shows the platform; a landing still follows the agent
    seg2 = Segments(spacing=0)
    snap2 = dict(snap, space=dict(snap["space"], moments=[{"id": "m1", "kind": "first_platform", "t": t,
                                                           "title": "First space platform: Solstice",
                                                           "facts": {"platform": "Solstice", "where": "Nauvis"}}]))
    seg2.step(snap2, t)
    seg2.cur = None  # step may have started it already; ask directly
    seg2.shown_moments.clear()
    title, facts, camera = seg2.build_space_moment({}, snap2, t)
    assert camera and camera["surface"] == "platform-1", camera


def platform_lua_tests():
    h = hz.Harness.__new__(hz.Harness)
    h.lua = lambda lua: {"platforms": [VIEW]} if "f.platforms" in lua else {}
    assert h.platform_views() == {"Solstice": VIEW}
    h.lua = lambda lua: {"platforms": {}}  # table_to_json writes an empty list as {}
    assert h.platform_views() == {}
    z = platform_shot({"surface": "s", "hub": {"x": 0, "y": 0}, "bounds": {"left": -100, "top": -5, "right": 100, "bottom": 5}})
    assert z["zoom"] == 0.3  # 210 tiles wide: clamped to the camera's minimum
    small = platform_shot({"surface": "s", "hub": {"x": 0, "y": 0}})  # the hub alone (default bounds +-6)
    assert small["zoom"] == round(min(2.0, 60 / 22, 34 / 22), 2) and small["position"] == {"x": 0, "y": 0}


def main():
    with tempfile.TemporaryDirectory() as d:
        wf, j = feed_tests(d)
        live_tests(d, wf, j)
    m = model_and_director_tests()
    segment_tests(m)
    platform_lua_tests()
    print("work: ok (journal tail, away filter, labels, director work cut and hold, platform shots in segments)")


if __name__ == "__main__":
    main()
