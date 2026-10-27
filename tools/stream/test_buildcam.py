#!/usr/bin/env python3
"""Builds on air within 30 s, and no repeated platform views (d27 batch267 LB): python3 tools/stream/test_buildcam.py

shift85 (vx_review): 11 of 23 new builds late (median 19 s; Astra's place_ghosts 03:13:16 aired 197 s later), 8 of them
on platforms, which were news only work_fresh (12 s) and waited out onair_dwell (90 s) and the score ratio; repeated
shots 35.4 min, "platform work: Sol · working on Loom" 25x (Sol's Loom requests: 179 inspect, 62 place_ghosts).
1. A build on a platform (BUILD_WORK) is news work_build_fresh: it takes over a story on air work_build_min, whatever
   the scores ("Sol · building on Starling"); the story's own news holds the camera.
2. A launch shot, a departure and a tour give way to a build once up work_build_min; a battle, an attack, a segment,
   a cue, danger and a look do not; no launch shot starts while a build waits.
3. A check-in or busy trio is left for a build by an agent off its big tile.
4. Repeats: a platform shown for work within work_repeat does not come back for an inspection; a build brings it
   back work_build_gap after its last work shot, as a closer view of where the build landed, without the requests'
   extension.
5. A build on the ground (the journal's did row) takes over a departure after work_build_min, and a story after
   fresh_min whatever the scores.
6. director_replay: the service's work rows (Work), the director's own timed views (own_target), the modelled shots
   left out of the timed ones.
7. model.py: a build after an inspection on the same platform within 20 s is its own work item.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from test_platformcam import VIEW, plat, snap, main_row  # noqa: E402
import test_launchcam as L  # noqa: E402
import director_replay  # noqa: E402

T = 1000


def item(agent_name, at, action="place_ghosts", position=None, platform="Starling", **kw):
    return dict({"id": f"work-{agent_name}-{at}-{action}", "agent": agent_name, "action": action, "t": at, "platform": platform,
                 "view": VIEW, "surface": "platform-1", "position": position,
                 "verb": {"place_ghosts": "building", "inspect": "inspecting", "deconstruct": "deconstructing"}[action]}, **kw)


def build_over_story():
    d, _ = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 22):
        d.step(snap(a, [plat()]), T + k)
    assert main_row(d, T + 21)["agents"] == ["astra"]
    # on main: no cut (onair_dwell 90 s, and sol 1 under work_ratio 0.8 of astra's 5) until the row is 12 s old
    on = None
    for k in range(22, 60):
        d.step(snap(a, [plat()], work=[item("sol", T + 22)]), T + k)
        if on is None and (main_row(d, T + k).get("platform") or {}).get("why") == "work":
            on = k
    assert on is not None and on - 22 <= 30, (on, d.cuts[-3:])
    row = d.cuts[-1] if d.cuts[-1][2].startswith("platform work") else next(c for c in d.cuts if c[2].startswith("platform work"))
    assert row[2] == "platform work: Sol · building on Starling", d.cuts[-3:]
    # the story's own news holds it
    d, _ = world(map_every=0, platform_every=0)
    for k in range(0, 22):
        d.step(snap(a, [plat()]), T + k)
    d.newsworthy = lambda n, now: n == "astra"
    for k in range(22, 50):
        d.step(snap(a, [plat()], work=[item("sol", T + 22)]), T + k)
    assert not d.platforms, d.platforms
    print(f"1. a platform build of an agent scoring 1/5 of the story on air: on air {on - 22} s after; the story's own news holds it: ok")


def yields():
    d, _ = world(map_every=0, platform_every=0)
    d.onair_since = T
    now = T + d.cfg["work_build_min"]
    ok = {"tour": {"subject": "@tour"}, "map": {"subject": "@map"}, "launch": {"subject": "@work", "launch": {"keys": ["k"]}},
          "departure": {"subject": "@platform", "platform": {"why": "departure"}},
          "visit": {"subject": "@platform", "platform": {"why": "visit"}},
          "inspection": {"subject": "@platform", "platform": {"why": "work"}}}
    no = {"battle": {"subject": "@battle"}, "attack": {"subject": "@attack"}, "segment": {"subject": "@segment"},
          "cue": {"subject": "@work", "work": "Astra at (1, 2)"}, "look": {"subject": "@look"},
          "danger": {"subject": "@platform", "platform": {"why": "danger"}},
          "operator": {"subject": "@platform", "platform": {"why": "operator"}},
          "a build": {"subject": "@platform", "platform": {"why": "work"}, "build": True}}
    for k, cur in ok.items():
        assert d.yields_to_build(cur, now), k
        assert not d.yields_to_build(cur, now - 1), (k, "before work_build_min")
    for k, cur in no.items():
        assert not d.yields_to_build(cur, now + 60), k
    # a launch shot gives way to a build on a platform once up work_build_min
    d = L.director()
    w = L.World({L.AQ: L.T0 + 1})
    L.run(d, w, L.T0 - 120, L.T0)
    t, launch_on, plat_on = L.T0, None, None
    while t < L.T0 + 40:
        work = [item("sol", L.T0 + 4)] if t >= L.T0 + 4 else []
        d.step({"agents": L.team(t), "alerts": [], "silos": w.silos(t), "work": work}, t)
        cur = d.state[d.onair]
        if launch_on is None and cur.get("launch"):
            launch_on = t
        if plat_on is None and (cur.get("platform") or {}).get("why") == "work":
            plat_on = t
        t += 1
    lift = L.T0 + 1 + 9.9
    assert launch_on is not None and plat_on is not None, d.cuts[-4:]
    assert plat_on - launch_on <= d.cfg["work_build_min"] + d.cfg["ready_s"] + 2 and plat_on < lift + d.cfg["launch_after"], \
        (launch_on, plat_on, lift, d.cuts[-4:])
    # no launch shot starts while a build waits
    d = L.director()
    w = L.World({})
    L.run(d, w, L.T0 - 120, L.T0)
    by = {a["name"]: a for a in L.team(L.T0)}
    scores = d.scores(L.team(L.T0), L.T0)
    assert d.launch_quiet(by, scores, L.T0, None), "quiet enough for a launch"
    d.builds_waiting = [item("sol", L.T0 - 3)]
    assert d.launch_quiet(by, scores, L.T0, None) is None
    print(f"2. tours, the map, visits, departures, launches and inspections give way to a build after "
          f"{d.cfg['work_build_min']:g} s (a launch: {plat_on - launch_on} s on air); battles, segments, cues, looks, danger "
          "and builds do not; no launch while a build waits: ok")


def trio():
    d, _ = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 3), agent("luna", 600, 0, 2)]
    for k in range(0, 10):
        d.step(snap(a, [plat()]), T + k)
    cur = d.state[d.onair]
    d.trio = {"agents": ["sol", "luna"], "until": T + 300, "why": "busy", "tiles": {}}
    d.mode, d.mode_since = "trio", T + 10
    by = {x["name"]: x for x in a}
    scores = d.scores(a, T + 12)
    d.builds_waiting = [item("luna", T + 11)]
    d.tiles(by, scores, T + 12)
    assert d.mode == "trio", "not before work_build_min"
    d.tiles(by, scores, T + 10 + d.cfg["work_build_min"])
    assert d.mode == "onecam" and d.layouts[-1][2] == "luna building on Starling", d.layouts[-1:]
    assert cur.get("subject") == "astra"
    print("3. a trio is left for a build by an agent off its big tile, after work_build_min: ok")


def repeats():
    d, _ = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 3)]
    items = []
    shown = []

    def run(k0, k1, add=None):
        for k in range(k0, k1):
            if add and k in add:
                items.append(add[k])
            d.step(snap(a, [plat()], work=[w for w in items if T + k - w["t"] < 60]), T + k)
            r = main_row(d, T + k)
            if (r.get("platform") or {}).get("why") == "work" and (not shown or shown[-1][1] != d.onair_since):
                shown.append((k, d.onair_since, r["platform"]["label"], r.get("frame", {}).get("position"), r.get("zoom")))
    run(0, 20)
    run(20, 120, {20: item("astra", T + 20, "inspect")})
    assert len(shown) == 1 and shown[0][2] == "Astra · working on Starling", shown
    # an inspection past work_gap (180 s) but within work_repeat (900 s): no repeat (on main: shown again)
    run(120, 300, {240: item("astra", T + 240, "inspect")})
    assert len(shown) == 1, shown
    # a build there: back, closer, where it landed; inspections every 10 s do not hold it past work_hold
    add = {300: item("astra", T + 300, "place_ghosts", position={"x": 5.0, "y": -3.0})}
    add.update({k: item("astra", T + k, "inspect") for k in range(305, 340, 10)})
    run(300, 340, add)
    assert len(shown) == 2 and shown[1][2] == "Astra · building on Starling", shown
    k, since = shown[1][0], shown[1][1]
    assert shown[1][3] == {"x": 5.0, "y": -3.0} and shown[1][4] == d.cfg["work_spot_zoom"], shown[1]
    ended = next(c[0] for c in d.cuts if c[0] > since)
    assert ended - since <= d.cfg["work_hold"] + d.cfg["ready_s"] + 2, (ended - since, d.cuts[-3:])
    # another build within work_build_gap of that shot: shown once the gap has passed (it is news work_build_fresh)
    run(340, 420, {345: item("astra", T + 345, "place_ghosts", position={"x": 9.0, "y": 2.0})})
    assert len(shown) == 3 and k + d.cfg["work_build_gap"] <= shown[2][0] <= 345 + d.cfg["work_build_fresh"], (k, shown)
    # past work_repeat after the last work shot: an inspection shows the whole platform again
    last = shown[-1][0]
    run(420, last + 920)
    subj = d.state[d.onair]["subject"]  # (an inspection by the agent on air: no dwell to wait out)
    run(last + 920, last + 960, {last + 920: item(subj, T + last + 920, "inspect")})
    assert shown[-1][2] == f"{subj.title()} · working on Starling" and shown[-1][0] >= last + 920, shown
    print(f"4. repeats: an inspection 220 s later not shown (work_repeat {d.cfg['work_repeat']:g} s), a build shown "
          f"closer at its spot for {ended - since:.0f} s, the whole platform again after work_repeat: ok")


def ground():
    d, _ = world(map_every=0, platform_every=0)
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    for k in range(0, 30):
        d.step(snap(a, [plat()]), T + k)
    dep = {"agents": [], "subject": "@platform", "position": {"x": 0, "y": 1}, "surface": "platform-1", "zoom": 1.0,
           "exact_zoom": True, "until": T + 30 + 60, "platform": {"name": "Starling", "why": "departure", "label": "Starling · leaving"}}
    d.urgent(dep, "platform departure: Starling · leaving", d.scores(a, T + 30), T + 30)
    first = None
    for k in range(30, 90):
        sol = dict(a[1], did={"action": "build", "t": T + 36, "position": {"x": 301, "y": 1}, "platform": None}) if k >= 36 else a[1]
        d.step(snap([a[0], sol], [plat()]), T + k)
        if first is None and main_row(d, T + k).get("agents") == ["sol"]:
            first = k
    # on main: the departure held its 60 s
    assert first is not None and first - 36 <= 30, (first, d.cuts[-3:])
    print(f"5. a build on the ground over a departure: on air {first - 36} s after: ok")


def replay_parts():
    class J:
        def __init__(self, requests):
            self.requests = requests
    js = {"sol": J([(100.0, "inspect", {"platform": "Loom"}, {}, True), (110.0, "inspect", {"platform": "Loom"}, {}, True),
                    (130.0, "place_ghosts", {"platform": "Loom", "entities": [{"name": "x", "position": {"x": 4, "y": 6}}]}, {}, True),
                    (140.0, "inspect", {}, {}, True), (150.0, "place_ghosts", {"position": {"x": 1, "y": 1}}, {}, True)])}
    log = [{"t": 50.0, "slot": "cam2", "reason": "standby", "cmd": {"position": {"x": 3, "y": 4}, "zoom": 0.5, "surface": "platform-9"}},
           {"t": 51.0, "slot": "program", "reason": "cut to cam2: platform work: Sol · working on Loom"},
           {"t": 70.0, "slot": "cam3", "reason": "standby", "cmd": {"position": {"x": 0, "y": 0}, "zoom": 0.4, "surface": "nauvis"}},
           {"t": 71.0, "slot": "program", "reason": "cut to cam3: platform departure: Anvil · leaving Nauvis for Vulcanus"},
           {"t": 90.0, "slot": "main", "reason": "standby", "cmd": {"position": {"x": 0, "y": 0}, "zoom": 0.5, "surface": "nauvis"}},
           {"t": 91.0, "slot": "program", "reason": "cut to main: launch: Rocket launch · Nauvis"},
           {"t": 95.0, "slot": "cam2", "reason": "standby", "cmd": {"position": {"x": 7, "y": 7}, "zoom": 0.9, "surface": "nauvis"},
            "target": {"did": "Sol · ghosts placed"}},
           {"t": 96.0, "slot": "program", "reason": "cut to cam2: back to sol"},
           {"t": 99.0, "slot": "program", "reason": "end"}]
    w = director_replay.Work(js, log)
    assert [(x["t"], x["action"]) for x in w.items] == [(100.0, "inspect"), (130.0, "place_ghosts")], w.items  # 110: within 20 s
    # a build 5 s after an inspection is its own row; another build 7 s after it is not
    w2 = director_replay.Work({"sol": J([(100.0, "inspect", {"platform": "Loom"}, {}, True),
                                         (105.0, "place_ghosts", {"platform": "Loom"}, {}, True),
                                         (112.0, "deconstruct", {"platform": "Loom"}, {}, True)])}, log)
    assert [(x["t"], x["action"]) for x in w2.items] == [(100.0, "inspect"), (105.0, "place_ghosts")], w2.items
    rows = w.rows(135.0)
    assert [r["action"] for r in rows] == ["inspect", "place_ghosts"] and rows[1]["view"]["surface"] == "platform-9", rows
    assert rows[1]["position"] == {"x": 4.0, "y": 6.0} and rows[1]["age_s"] == 5.0, rows[1]
    assert w.rows(200.0) == [], "kept 60 s"
    labels = [s["label"] for s in director_replay.timed_shots(log, 0, 200)]
    assert labels == ["platform work: Sol · working on Loom", "platform departure: Anvil · leaving Nauvis for Vulcanus",
                      "launch: Rocket launch · Nauvis"], labels  # an agent's build spot: the replay's own
    labels = [s["label"] for s in director_replay.timed_shots(log, 0, 200, modelled=("launch:", "platform work:"))]
    assert labels == ["platform departure: Anvil · leaving Nauvis for Vulcanus"], labels
    sh = director_replay.timed_shots(log, 0, 200)
    own = director_replay.own_target(sh[1])
    assert own["subject"] == "@platform" and own["platform"]["why"] == "departure" and own["platform"]["name"] == "Anvil", own
    assert director_replay.own_target(dict(sh[1], label="base map")) ["subject"] == "@map"
    assert director_replay.own_target(sh[0]) is None and director_replay.own_target(dict(sh[1], label="cue: Luna · x")) is None
    print("6. replay: work rows as model.py makes them, platform views from the log, the director's own views as its "
          "shots, modelled shots left out: ok")


def model_items():
    """model._ingest_work: a build after an inspection on the same platform within 20 s is its own item (shift85:
    Sol's place_ghosts on Loom at 06:16:58, 14 s after an inspection, was none and aired 403 s later)."""
    from model import Model
    m = Model({"agents": {"sol": {}}})
    m.agent("sol")
    m.space = {"platforms": [{"name": "Loom", "view": VIEW}]}
    for t, action in ((100.0, "inspect"), (114.0, "place_ghosts"), (120.0, "deconstruct"), (125.0, "inspect")):
        m._ingest_work({"agent": "sol", "action": action, "platform": "Loom", "verb": "x", "at": str(t)}, t)
    assert [(x["t"], x["action"]) for x in m.work] == [(100.0, "inspect"), (114.0, "place_ghosts")], list(m.work)
    print("7. the service's work items: a build after an inspection is its own item, one after a build is not: ok")


def main():
    build_over_story()
    yields()
    trio()
    repeats()
    ground()
    replay_parts()
    model_items()
    print("buildcam: ok")


if __name__ == "__main__":
    main()
