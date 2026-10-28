#!/usr/bin/env python3
"""One-client paths for the timed shots (d28 batch318 OC, viewer Aurora 15:02: "ship danger, dense asteroid entry and
periodic visits require two physical clients. Please check panel mode. Give those shots a safe one-client path. Vary
overview, bow defense and machinery views. Hold readable action, decay unchanged views, and preserve urgent cuts"):
python3 tools/stream/test_oneclient.py

Since d27 10:21 the stream has run one camera client (POG_CAMS=1; camera panels since d28 09:13), and the base map, a
cloud, a platform in danger, an edge entry, a departure other than a maiden flight and a visit needed two clients.
1. The base map with one client and panels: the client moves to the map and back; the story's agent is in a panel
   meanwhile (an "away" inset); it waits while the story on air fights, runs a big action or has news. Without panels
   (POG_CAMS=1 alone) it airs with no inset. one_client_shots off: never (as before). Three clients: framed on a
   standby and cut, no away inset (unchanged).
2. A cloud that reached new nests: as the map.
3. A platform in danger: takes the one client at once, also from a story in a fight (urgent, as with three); the
   agent in a panel; the story back after.
4. A ship entering an edge leg's dense asteroids: once per leg, urgent.
5. A departure: news on air; a routine one in a free panel when it may not go on air (no panel: not shown).
6. A visit with one client: the whole ship visit_overview_s, then the bow defense (in flight) and the machinery (while
   machines work) visit_beat_s each, in turn from visit to visit; a docked ship with nothing working: the whole ship
   only. Three clients: the whole ship platform_hold as before.
7. Quiet time with one client: the platform visit and the map are quiet views again.
8. director_replay.py's inputs for these: camera panels, the platforms read (views from a service state file, where
   each platform is from the chronicle), the story beats, the program's shots by kind.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from onecam import OneCam  # noqa: E402
from test_onecam import SLOTS, agent  # noqa: E402
from test_platformcam import VIEW, plat, main_row  # noqa: E402
from test_mapcam import BASEMAP  # noqa: E402
from test_clouds import ROWS as CLOUD_ROWS  # noqa: E402

PANELS = [{"slot": "main", "player": 1},
          {"slot": "cam2", "player": 1, "panel": 1, "rect": [2388, 0, 492, 277], "scale": 0.171},
          {"slot": "cam3", "player": 1, "panel": 2, "rect": [0, 0, 492, 277], "scale": 0.171}]
ONE = PANELS[:1]
T = 1000
# a ship with turrets (two at the bow) and machines, four of them working
SHIP = dict(VIEW, surface="platform-3", bounds={"left": -20, "top": -40, "right": 20, "bottom": 40},
            guns=[{"x": -6, "y": -36, "range": 18}, {"x": 6, "y": -34, "range": 18}, {"x": 0, "y": 30, "range": 18}],
            machines=[{"x": -10.5, "y": 10.5, "w": 1}, {"x": -6.5, "y": 10.5, "w": 1}, {"x": -2.5, "y": 10.5, "w": 1},
                      {"x": 1.5, "y": 14.5, "w": 1}, {"x": 15.5, "y": -30.5, "w": 0}])


def director(slots, **cfg):
    sent = []
    d = OneCam(slots, lambda body: sent.append(body) or {"ok": True}, None,
               **dict({"trio": False, "map_every": 0, "platform_every": 0, "bow": False, "stories": False}, **cfg))
    d.started = 0
    return d, sent


def team(combat=False):
    a = [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3)]
    if combat:
        a[0]["combat"] = True
    return a


def snap(agents, plats=(), **kw):
    return dict({"agents": agents, "alerts": [], "space": {"platforms": list(plats)}, "basemap": BASEMAP}, **kw)


def inset_row(d, t):
    return d.public(t).get("inset") or {}


def run(d, k0, k1, mk, until=None):
    """Step d from T + k0 to T + k1 with mk(k) -> snapshot; stop early once until(d, k) is true; the last k."""
    for k in range(k0, k1):
        d.step(mk(k), T + k)
        if until and until(d, k):
            return k
    return k1 - 1


def base_map():
    cfg = dict(map_every=600, map_first=30)
    # one client and panels: the map on air, luna in a panel, back to luna after map_hold
    d, sent = director(PANELS, **cfg)
    k = run(d, 0, 120, lambda k: snap(team()), until=lambda d, k: bool(d.maps))
    assert d.maps and d.cuts[-1][2] == "base map", (d.maps, d.cuts[-3:])
    k = run(d, k + 1, k + 3, lambda k: snap(team()))
    m, ins = main_row(d, T + k), inset_row(d, T + k)
    assert m.get("map") == "Base map" and ins.get("agents") == ["luna"] and ins.get("client") == "cam3", (m, ins)
    assert d.aways and d.aways[0][1] == "luna", d.aways
    assert [b for b in sent if b.get("map")][-1]["player"] == 1
    k = run(d, k + 1, k + 40, lambda k: snap(team()), until=lambda d, k: not main_row(d, T + k).get("map"))
    assert main_row(d, T + k).get("agents") == ["luna"], main_row(d, T + k)
    k = run(d, k + 1, k + 3, lambda k: snap(team()))
    assert not d.inset, d.inset  # the story is back: its inset is over
    # the story fights: the map waits until it is over
    d, _ = director(PANELS, **cfg)
    run(d, 0, 200, lambda k: snap(team(combat=True)))
    assert not d.maps, d.maps
    run(d, 200, 320, lambda k: snap(team()), until=lambda d, k: bool(d.maps))
    assert d.maps, "the map after the fight"
    # one client, no panels: the map airs, no inset
    d, _ = director(ONE, **cfg)
    run(d, 0, 120, lambda k: snap(team()), until=lambda d, k: bool(d.maps))
    assert d.maps and not d.aways and not d.inset, (d.maps, d.aways)
    # one_client_shots off: no map (as before)
    d, _ = director(PANELS, one_client_shots=False, **cfg)
    run(d, 0, 200, lambda k: snap(team()))
    assert not d.maps, d.maps
    # three clients: a standby framed, then the cut; no away inset
    d, _ = director(SLOTS, **cfg)
    k = run(d, 0, 120, lambda k: snap(team()), until=lambda d, k: bool(d.maps))
    assert d.maps and d.pending and not d.aways, (d.maps, d.pending)
    # (map decay) the same base map: the next map after 600 s, then 1200 s; a changed map: map_every again
    d, _ = director(PANELS, map_every=600, map_first=30, quiet_story=1e9)
    run(d, 0, 3000, lambda k: snap(team()))
    ts = [m[0] - T for m in d.maps]
    assert len(ts) >= 3 and 600 <= ts[1] - ts[0] < 640 and 1200 <= ts[2] - ts[1] < 1240, ts
    other = dict(BASEMAP, rows=BASEMAP["rows"][:-1] + ["..MMM"])
    run(d, 3000, 3000 + 700, lambda k: snap(team(), basemap=other))
    assert [m[0] - T for m in d.maps][3:] == [3000, 3600], [m[0] - T for m in d.maps]  # (2400 s due for the same map)
    print("1. base map: one client moves there and back, the story in a panel, after its fight; no panels: no inset; "
          "off: none; three clients unchanged; the same map decays (600, 1200 s), a changed one does not: ok")


def cloud():
    d, _ = director(PANELS)
    run(d, 0, 40, lambda k: snap(team()))
    from model import Model
    m = Model({"agents": {}})
    m.ingest({"agents": [], "clouds": CLOUD_ROWS}, now=T)
    d.clouds = {r["surface"]: r for r in m.snapshot(T)["clouds"]}
    d.cloud_due = {"surface": "gleba", "t": T + 40, "nests": 2}
    d.last_program_cut = T
    k = run(d, 40, 50, lambda k: snap(team()), until=lambda d, k: bool(d.cloud_shots))
    assert d.cloud_shots and d.cloud_shots[-1][1:] == ("gleba", "reached 2 new nests"), d.cloud_shots
    k = run(d, k + 1, k + 3, lambda k: snap(team()))
    m = main_row(d, T + k)
    assert m.get("cloud", {}).get("surface") == "gleba" and inset_row(d, T + k).get("agents") == ["luna"], m
    print("2. a cloud at new nests: one client there, the story in a panel: ok")


def danger():
    d, sent = director(PANELS)
    run(d, 0, 30, lambda k: snap(team(combat=True)))
    p = plat("Wayfarer", view=dict(SHIP, surface="platform-2"))

    def mk(k):
        q = dict(p, danger={"kind": "fire", "reason": "Wayfarer under fire: 3 buildings lost", "last": T + min(k, 40),
                            "level": 3000})
        return snap(team(combat=True), [q])
    k = run(d, 30, 32, mk, until=lambda d, k: bool(d.platforms))
    assert d.platforms and d.platforms[-1][1:] == ("Wayfarer", "danger") and k == 30, (k, d.platforms)
    m, ins = main_row(d, T + k), inset_row(d, T + k)
    assert m["platform"]["why"] == "danger" and m["surface"] == "platform-2" and ins.get("agents") == ["luna"], (m, ins)
    assert sent[-2]["player"] == 1 and sent[-2].get("surface") == "platform-2" and sent[-2]["smooth"] is False, sent[-2:]
    k = run(d, k + 1, k + 120, mk, until=lambda d, k: not main_row(d, T + k).get("platform"))
    assert main_row(d, T + k).get("agents") == ["luna"] and 40 + d.cfg["danger_hold"] <= k <= 40 + d.cfg["danger_hold"] + 3, \
        (k, main_row(d, T + k))
    # one_client_shots off: not shown (as before)
    e, _ = director(PANELS, one_client_shots=False)
    run(e, 0, 40, mk)
    assert not e.platforms, e.platforms
    print("3. a platform in danger: the one client at once, also from a fight, the story in a panel, back after: ok")


def edge():
    import edgedense
    d, _ = director(PANELS)
    lo, hi = edgedense.trip_span("aquilo", "solar-system-edge")
    pct = round((lo + hi) / 2)

    def row(p):
        return plat("Bastion", at=f"aquilo->solar-system-edge {p}%", view=dict(SHIP, surface="platform-5"),
                    toward="solar-system-edge")
    run(d, 0, 30, lambda k: snap(team(), [row(max(1, round(lo) - 5))]))
    assert not d.platforms
    k = run(d, 30, 40, lambda k: snap(team(), [row(pct)]), until=lambda d, k: bool(d.platforms))
    assert d.platforms[-1][1:] == ("Bastion", "edge"), d.platforms
    assert main_row(d, T + k + 0)["platform"]["label"] == "Bastion · dense asteroids near the solar system edge"
    run(d, k + 1, k + 200, lambda k: snap(team(), [row(pct)]))
    assert [p[2] for p in d.platforms].count("edge") == 1, d.platforms  # once per leg
    # (one_repeat) back at Aquilo and out again within the hour: the next leg's entry is a repeat, not shown; a leg
    # after one_repeat is shown again
    k = run(d, k + 200, k + 230, lambda k: snap(team(), [plat("Bastion", at="aquilo", view=dict(SHIP, surface="platform-5"))]))
    k = run(d, k + 1, k + 60, lambda k: snap(team(), [row(pct)]))
    assert [p[2] for p in d.platforms].count("edge") == 1 and ("Bastion", "edge") in [r[1:3] for r in d.repeats], \
        (d.platforms, d.repeats)
    # (its departure, news by its edge leg, went on air as a routine one: rationed, the first in depart_routine_every)
    assert [r[2] for r in d.repeats] == ["departure", "edge"] or [r[2] for r in d.repeats] == ["edge", "departure"], d.repeats
    k = run(d, k + 1, k + 30, lambda k: snap(team(), [plat("Bastion", at="aquilo", view=dict(SHIP, surface="platform-5"))]))
    k0 = k + 3700
    run(d, k0, k0 + 60, lambda k: snap(team(), [row(pct)]))
    assert [p[2] for p in d.platforms].count("edge") == 2, d.platforms
    print("4. an edge leg's dense asteroids: the one client there once per leg; the same ship within one_repeat: not "
          "shown: ok")


def departures():
    # news: on air with the story in a panel
    d, _ = director(PANELS)
    run(d, 0, 40, lambda k: snap(team(), [plat()]))
    k = run(d, 40, 50, lambda k: snap(team(), [plat(at="nauvis->vulcanus 1%")]), until=lambda d, k: bool(d.platforms))
    assert d.platforms[-1][1:] == ("Starling", "departure"), d.platforms
    k = run(d, k + 1, k + 3, lambda k: snap(team(), [plat(at="nauvis->vulcanus 1%")]))
    assert main_row(d, T + k)["platform"]["why"] == "departure" and inset_row(d, T + k).get("agents") == ["luna"]
    # (one_repeat) the same ship's next departure within the hour, news by its route: routine with one client
    run(d, k + 1, k + 120, lambda k: snap(team(), [plat(at="vulcanus")]))
    run(d, k + 120, k + 130, lambda k: snap(team(), [plat(at="vulcanus->nauvis 1%")]))
    assert d.repeats and d.repeats[-1][1:3] == ("Starling", "departure") and d.departs[-1][2] in ("inset", "main", "none"), \
        (d.repeats, d.departs[-2:])
    assert "(one client)" in d.departs[-1][3] and d.departs[-1][2] == "main", d.departs[-1]  # (no routine aired yet: on air)
    # routine, a routine one on air lately: in a panel (no panel: not shown, logged)
    for slots, where in ((PANELS, "inset"), (ONE, "none")):
        d, _ = director(slots)
        run(d, 0, 40, lambda k: snap(team(), [plat()]))
        now = T + 40
        d.routine_main.append((now - 60, ("Cinder", "nauvis", "gleba")))
        d.departure = {"name": "Starling", "t": now, "label": "Starling · leaving Nauvis for Vulcanus", "news": False,
                       "route": ("Starling", "nauvis", "vulcanus"), "why": "Starling Nauvis->Vulcanus flown 41 min ago"}
        d.step(snap(team(), [plat()]), now)  # (the departure set by hand: watch_platforms sees no other)
        assert d.departs and d.departs[-1][2] == where, (where, d.departs)
        if where == "inset":
            assert d.inset["why"] == "departure" and d.state[d.inset["slot"]]["surface"] == "platform-1", d.inset
            assert main_row(d, now).get("agents") == ["luna"]
    print("5. departures: news on air with the story in a panel; routine in a free panel, else not shown: ok")


def visits():
    cfg = dict(platform_every=300, platform_first=30)
    d, sent = director(PANELS, **cfg)
    fly = plat("Starling", at="nauvis->vulcanus 40%", view=SHIP)
    k = run(d, 0, 120, lambda k: snap(team(), [fly]), until=lambda d, k: bool(d.platforms))
    assert d.platforms[-1][2] == "visit", d.platforms
    k0 = k
    t = d.state[d.onair]
    assert t["until"] == T + k0 + d.cfg["ready_s"] + 7 + 2 * 7 and [b["why"] for b in t["beats"]] == ["bow defense", "machinery"], t
    rows = []
    k = run(d, k0 + 1, k0 + 40, lambda k: snap(team(), [fly]),
            until=lambda d, k: rows.append((k, main_row(d, T + k).get("work"), main_row(d, T + k).get("zoom"))) or
            not main_row(d, T + k).get("platform"))
    works = [r[1] for r in rows if r[1]]
    assert works[0] == "Starling · whole ship", rows[:3]
    bow = next(r for r in rows if r[1] and "bow defense" in r[1])
    mach = next(r for r in rows if r[1] and "machinery" in r[1])
    assert bow[0] - k0 in (7, 8) and mach[0] - bow[0] in (7, 8), (k0, bow, mach)
    assert bow[1] == "Starling · bow defense: 2 turrets ahead", bow
    assert mach[1] == "Starling · machinery: 4 working here, 4 of 5 on the ship" and mach[2] == 0.7, mach
    # the bow frame holds the two bow turrets and the space they reach ahead
    bb = [b for b in sent if b.get("surface") == "platform-3" and b.get("speed")]
    assert bb and bb[0]["position"]["y"] < -36 and bb[1]["position"] == {"x": -4.5, "y": 12.5}, bb[:2]
    assert main_row(d, T + k).get("agents") == ["luna"] and k - k0 <= 7 + 14 + d.cfg["ready_s"] + 2, (k, k0)
    # the next visit opens with the other framing after the whole ship
    k = run(d, k + 1, k + 400, lambda k: snap(team(), [fly]), until=lambda d, k: len(d.platforms) >= 2)
    assert [b["why"] for b in d.state[d.onair]["beats"]] == ["machinery", "bow defense"], d.state[d.onair]["beats"]
    # docked, nothing working: the whole ship visit_overview_s only (decayed from platform_hold)
    still = plat("Starling", view=dict(SHIP, machines=[dict(m, w=0) for m in SHIP["machines"]]))
    d, _ = director(PANELS, **cfg)
    k = run(d, 0, 120, lambda k: snap(team(), [still]), until=lambda d, k: bool(d.platforms))
    t = d.state[d.onair]
    assert t["beats"] == [] and t["until"] == T + k + d.cfg["ready_s"] + d.cfg["visit_overview_s"], t
    # three clients: as before (platform_hold, no framings)
    d, _ = director(SLOTS, **cfg)
    k = run(d, 0, 120, lambda k: snap(team(), [fly]), until=lambda d, k: bool(d.platforms))
    t = d.state[d.pending["slot"]]
    assert "beats" not in t and t["until"] == T + k + d.cfg["ready_s"] + d.cfg["platform_hold"], t
    print("6. visits with one client: the whole ship, then bow defense and machinery in turn; a still ship decays to "
          "the overview; three clients unchanged: ok")


def quiet():
    d, _ = director(PANELS, quiet_story=60, quiet_gap=120)
    still = [agent("luna", 0, 0, 5, activity="idle", active=None), agent("sol", 300, 0, 3, activity="idle", active=None)]
    run(d, 0, 400, lambda k: snap(still, [plat()]))
    kinds = [q[1] for q in d.quiets]
    assert "platform" in kinds and "map" in kinds, d.quiets
    e, _ = director(PANELS, quiet_story=60, quiet_gap=120, one_client_shots=False)
    run(e, 0, 400, lambda k: snap(still, [plat()]))
    assert not e.quiets, e.quiets  # (no chart here: no tours; as before, no platform or map view with one client)
    print(f"7. quiet time with one client: {kinds}: ok")


def replay_feeds():
    import director_replay as R
    with tempfile.TemporaryDirectory() as tmp:
        run = os.path.join(tmp, "shift93")
        os.makedirs(run)
        ev = [{"type": "event", "kind": "platform_left", "platform": "Starling", "at": "nauvis", "to": "vulcanus",
               "tick": 6000, "t": 1100.0},
              {"type": "event", "kind": "platform_arrived", "platform": "Starling", "at": "vulcanus", "tick": 42000,
               "t": 1700.0}]
        with open(os.path.join(run, "chronicle.jsonl"), "w") as f:
            f.write("\n".join(json.dumps(r) for r in ev + ev[:1]) + "\n")  # (a repeated row counts once)
        state = os.path.join(tmp, "state.json")
        with open(state, "w") as f:
            json.dump({"space": {"platforms": [{"name": "Starling", "view": SHIP}, {"name": "Unbuilt", "view": {}}]},
                       "basemap": BASEMAP}, f)
        P = R.Platforms([run], state)
        assert list(P.views) == ["Starling"] and P.basemap == BASEMAP
        assert P.rows(1000)[0]["where"] == "Nauvis" and not P.rows(1000)[0]["route"], P.rows(1000)
        mid = P.rows(1400)[0]
        assert mid["route"] == {"from": "Nauvis", "to": "Vulcanus", "pct": 50} and mid["route_ids"] == ["nauvis", "vulcanus"], mid
        assert P.rows(1800)[0]["where"] == "Vulcanus", P.rows(1800)
        assert P.tick_at(1400) == 6000 + 300 * 60 and P.route_last("Starling", "nauvis", "vulcanus", 7000) == 6000
        assert P.route_last("Starling", "nauvis", "vulcanus", 6000) is None
        st = os.path.join(tmp, "stories.json")
        with open(st, "w") as f:
            json.dump({"stories": [{"id": "astra:flight#1", "platform": "Starling", "agent": "astra", "verdict": "passed",
                                    "beats": {"open": {"t": 1000, "caption": "Q"}, "result": {"t": 2000, "caption": "R"}}}]}, f)
        S = R.Stories(st)
        assert [b["key"] for b in S.rows(1500)] == ["astra:flight#1:open"] and S.rows(2001)[0]["verdict"] == "passed"
        assert S.rows(1000 + S.keep) == []
    rows = [{"t": 1, "slot": "program", "reason": "move main: base map"},
            {"t": 2, "slot": "cam3", "reason": "inset away: luna (base map)"},
            {"t": 3, "slot": "program", "reason": "move main: platform visit: Starling · in orbit of Nauvis"},
            {"t": 4, "slot": "program", "reason": "move main: tour: Nauvis (quiet: luna still 70 s)"},
            {"t": 9, "slot": "program", "reason": "move main: launch: Rocket launch · Nauvis"}]
    assert R.shot_counts(rows, 0, 5) == {"map": 1, "away inset": 1, "visit": 1, "tour": 1}, R.shot_counts(rows, 0, 5)
    print("8. the replay's panels, platforms, stories and shot counts: ok")


def main():
    base_map()
    cloud()
    danger()
    edge()
    departures()
    visits()
    quiet()
    replay_feeds()
    print("oneclient: ok")


if __name__ == "__main__":
    main()
