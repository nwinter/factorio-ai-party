#!/usr/bin/env python3
"""The camera visits the space platforms (onecam.py; Nick 21:25: "Do we have the camera look at the space platform
sometimes?"; Sol for awoo3391, 21:23: "occasional platform camera view and continuous view during departure"):
python3 tools/stream/test_platformcam.py

1. A visit about every platform_every: a standby gets a fixed view on the platform's surface (model.platform_shot:
   hub and build in frame, exact zoom), the program cuts to it, it holds platform_hold, labelled "Starling · in
   orbit of Nauvis", then the story comes back. Several platforms: the one shown longest ago next.
2. Never during a replay (hold_layout), an urgent shot, an inset or a fight, nor in the first platform_first.
3. A departure (a platform seen still starts travelling): on it for depart_hold (60 s), "Starling · leaving Nauvis
   for Vulcanus"; a platform already travelling when first seen is no departure; a big loss still cuts in.
4. An agent's platform action (snapshot work with platform=): the agent on air -> its platform, labelled "Astra ·
   working on Starling", held while its requests keep coming (up to work_max), then back to its character; an
   agent off air scoring far below the one on air does not take the camera.
5. The work feed (work.py): inspect/configure/launch/drop count with platform= only.
6. The hosts: snapshot onair.platform; the caster's facts say it.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from model import platform_where  # noqa: E402
from onecam import onair_info  # noqa: E402

VIEW = {"surface": "platform-1", "hub": {"x": 0, "y": 0}, "bounds": {"left": -14, "top": -10, "right": 14, "bottom": 12},
        "hub_health": 100}


def plat(name="Starling", at="nauvis", view=VIEW, **kw):
    state = "on_the_path" if "->" in at else "waiting_at_station"
    return platform_where(dict({"name": name, "at": at, "state": state, "speed": 1.2 if "->" in at else 0, "view": view},
                               **kw))


def snap(agents, plats=(), alerts=(), work=(), fights=()):
    return {"agents": agents, "alerts": list(alerts), "work": list(work), "fights": list(fights),
            "space": {"platforms": list(plats)}}


def team():
    return [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3)]


def main_row(d, t):
    return d.public(t).get("main") or {}


def visit():
    d, sent = world(map_every=0)
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
        if d.platforms:
            break
    assert d.platforms and d.platforms[0][1:] == ("Starling", "visit"), d.platforms
    shot = [b for b in sent if b.get("surface") == "platform-1"]
    assert shot and shot[-1]["smooth"] is False and shot[-1]["position"] == {"x": 0.0, "y": 1.0}, shot
    k0 = k
    for k in range(k0 + 1, k0 + 4):
        d.step(snap(a, [plat()]), t + k)
    row = main_row(d, t + k)
    assert row["agents"] == [] and row["platform"]["label"] == "Starling · in orbit of Nauvis", row
    assert row["surface"] == "platform-1" and row["frame"]["surface"] == "platform-1", row
    info = onair_info({"agents": a}, d.public(t + k))
    assert info["platform"]["name"] == "Starling" and info["agent"] is None, info
    # held platform_hold, then back to the story
    back = None
    for k in range(k0 + 4, k0 + 60):
        d.step(snap(a, [plat()]), t + k)
        if main_row(d, t + k).get("agents") == ["luna"]:
            back = k
            break
    assert back is not None and d.cfg["platform_hold"] <= back - k0 <= d.cfg["platform_hold"] + 5, (back - k0, d.cuts)
    # the next visit: the other platform (shown longest ago); a hurt hub says so
    two = [plat(), plat("Kestrel", view=dict(VIEW, surface="platform-2", hub_health=62))]
    d.last_platform = t + back - d.cfg["platform_every"]
    for k in range(back, back + 60):
        d.step(snap(a, two), t + k)
        if len(d.platforms) > 1:
            break
    assert d.platforms[-1][1] == "Kestrel", d.platforms
    d.step(snap(a, two), t + k + 2)
    assert main_row(d, t + k + 2)["platform"]["label"] == "Kestrel · in orbit of Nauvis · hub 62%", main_row(d, t + k + 2)


def never_when_busy():
    d, _ = world(map_every=0, platform_first=600)
    a, t = team(), 100
    for k in range(0, 60):
        d.step(snap(a, [plat()]), t + k)
    assert not d.platforms, d.platforms  # inside platform_first
    d, _ = world(map_every=0)
    d.hold_layout = True  # a replay on air
    for k in range(0, 60):
        d.step(snap(a, [plat()]), 1000 + k)
    assert not d.platforms, d.platforms
    d, _ = world(map_every=0)
    fight = {"key": "area:900,900", "kind": "attack", "position": {"x": 900, "y": 900}}
    for k in range(0, 60):
        d.step(snap(a, [plat()], fights=[dict(fight, last=1000 + k)]), 1000 + k)
    assert not d.platforms, d.platforms  # a fight going on somewhere
    d, _ = world(map_every=0)
    for k in range(0, 60):
        d.step(snap(a, [plat(view=None)]), 1000 + k)
    assert not d.platforms, d.platforms  # no view (no surface yet): nothing to show


def departure():
    d, sent = world(map_every=0, platform_every=0)
    a, t = team(), 1000
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    assert not d.platforms and main_row(d, t + 39)["agents"] == ["luna"]
    for k in range(40, 44):
        d.step(snap(a, [plat(at="nauvis->vulcanus 1%")]), t + k)
    assert d.platforms and d.platforms[-1][1:] == ("Starling", "departure"), d.platforms
    row = main_row(d, t + 43)
    assert row["platform"]["label"] == "Starling · leaving Nauvis for Vulcanus · 72 km/s", row
    for k in range(44, 40 + 58):
        d.step(snap(a, [plat(at=f"nauvis->vulcanus {k - 40}%")]), t + k)
        assert main_row(d, t + k).get("platform"), (k, d.cuts)  # held the whole departure
    for k in range(98, 115):
        d.step(snap(a, [plat(at=f"nauvis->vulcanus {k - 40}%")]), t + k)
    assert main_row(d, t + 114).get("agents") == ["luna"], d.cuts
    # first seen travelling (the service restarted mid-flight): no departure
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 60):
        d.step(snap(a, [plat(at=f"nauvis->vulcanus {k}%")]), t + k)
    assert not d.platforms, d.platforms
    # a big loss during a departure still cuts in
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 40):
        d.step(snap(a, [plat()]), t + k)
    for k in range(40, 50):
        d.step(snap(a, [plat(at="nauvis->vulcanus 2%")]), t + k)
    loss = {"id": "l1", "kind": "loss", "t": t + 50, "text": "26 lost near (-128, 38): 14 transport belt, 7 inserter",
            "position": {"x": -128, "y": 38, "extent": 20}, "key": "loss:-128,38"}
    for k in range(50, 54):
        d.step(snap(a, [plat(at="nauvis->vulcanus 3%")], alerts=[loss] if k == 50 else []), t + k)
    row = main_row(d, t + 53)
    assert row.get("attack") and not row.get("platform"), row
    # ... and once it is over, back to the departure for what is left of it, then the story
    back = None
    for k in range(54, 130):
        d.step(snap(a, [plat(at=f"nauvis->vulcanus {k - 40}%")]), t + k)
        row = main_row(d, t + k)
        if back is None and row.get("platform"):
            back = k
            assert row["platform"]["why"] == "departure", row
        if back is not None and not row.get("platform"):
            break
    assert back is not None and back < 95, (back, d.cuts)
    assert k <= 40 + 1.5 + d.cfg["depart_hold"] + 4 and row.get("agents") == ["luna"], (k, row, d.cuts)


def work():
    d, sent = world(map_every=0, platform_every=0)
    a, t = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 3)], 1000
    for k in range(0, 20):
        d.step(snap(a, [plat()]), t + k)
    assert main_row(d, t + 19)["agents"] == ["astra"]
    item = lambda at: {"id": f"work-astra-{at}", "agent": "astra", "action": "place_ghosts", "t": at,  # noqa: E731
                       "platform": "Starling", "view": VIEW, "surface": "platform-1"}
    items = [item(t + 20)]
    for k in range(20, 24):
        d.step(snap(a, [plat()], work=items), t + k)
    row = main_row(d, t + 23)
    # (d27 batch267) a build there: "building on"
    assert row["agents"] == ["astra"] and row["work"] == "Astra building on Starling" and row["surface"] == "platform-1", row
    assert row["platform"]["label"] == "Astra · building on Starling" and row["platform"]["why"] == "work", row
    info = onair_info({"agents": a}, d.public(t + 23))
    assert info["agent"] == "astra" and info["doing"] == "building on Starling", info
    # more requests keep it there past work_hold
    for k in range(24, 60):
        if k % 10 == 0:
            items.append(item(t + k))
        d.step(snap(a, [plat()], work=items), t + k)
        assert main_row(d, t + k).get("work"), (k, d.cuts)
    # quiet: back to Astra's character
    for k in range(60, 100):
        d.step(snap(a, [plat()], work=items), t + k)
    row = main_row(d, t + 99)
    assert row["agents"] == ["astra"] and not row.get("work") and row.get("surface") is None, (row, d.cuts)
    assert d.cuts[-1][2] == "back to astra", d.cuts
    # an agent off air far below the one on air: no cut to its platform for an inspection ...
    d, _ = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 200):
        w = [dict(item(t + k), id=f"w{k}", agent="sol", action="inspect")] if k > 100 and k % 10 == 0 else []
        d.step(snap(a, [plat()], work=w), t + k)
    assert not d.platforms, d.platforms
    # ... (d27 batch267 LB) but a build there is news whatever the scores: on air within work_build_fresh
    for k in range(200, 240):
        w = [dict(item(t + 201), id="wb", agent="sol")] if k >= 201 else []
        d.step(snap(a, [plat()], work=w), t + k)
    assert d.platforms and d.platforms[-1][1:] == ("Starling", "work") and d.platforms[-1][0] - (t + 201) <= 30, d.platforms


def feed():
    from work import WorkFeed
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, "astra"))
    path = os.path.join(root, "astra", "journal.jsonl")
    open(path, "w").close()
    f = WorkFeed(root, ["astra"])
    assert f.poll() == []
    reqs = [("inspect", {"position": {"x": 1, "y": 2}, "platform": "Starling"}),
            ("inspect", {"position": {"x": 1, "y": 2}}),
            ("launch", {"position": {"x": 40, "y": 8}, "platform": "Starling"}),
            ("configure", {"position": {"x": 3, "y": 3}, "recipe": "iron-gear-wheel"}),
            ("place_ghosts", {"entities": [{"name": "inserter", "position": {"x": 2, "y": 2}}], "platform": "Starling"})]
    with open(path, "a") as fh:
        for action, args in reqs:
            fh.write(json.dumps({"event": "request", "at": "2026-10-12T21:30:00Z",
                                 "request": {"id": action, "action": action, "args": args}}) + "\n")
    out = f.poll()
    assert [(w["action"], w["platform"], w["verb"]) for w in out] == [
        ("inspect", "Starling", "inspecting"), ("launch", "Starling", "launching a rocket to"),
        ("place_ghosts", "Starling", "building")], out


def hosts():
    import caster
    s = {"agents": [], "onair": {"agent": None, "platform": {"name": "Starling", "why": "departure",
                                                             "label": "Starling · leaving Nauvis for Vulcanus"}}}
    f = caster.facts_for({"kind": "lull", "angle": "explain"}, s)
    p = f["on_screen_platform"]
    assert p["platform"] == "Starling" and "leave" in p["note"] and p["shown_as"].endswith("Vulcanus"), f


def main():
    visit()
    never_when_busy()
    departure()
    work()
    feed()
    hosts()
    print("platformcam: ok (a visit every 12 min for 20 s, the one shown longest ago; never in a replay, an urgent "
          "shot or a fight; a departure held 60 s; an agent's platform work shows the platform, then its character; "
          "work feed counts inspect/configure/launch with platform=; hosts see onair.platform)")


if __name__ == "__main__":
    main()
