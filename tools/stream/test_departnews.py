#!/usr/bin/env python3
"""Routine platform departures stop taking the main camera (onecam.py maybe_departure, d22 batch83 AS1; Nick 09:28:
"There are so many routine flights now that it's pretty repetitive"): python3 tools/stream/test_departnews.py

1. News (on air depart_hold, as before): a maiden flight, a route the platform has not flown in depart_news_h (6 game
   hours), a leg to or from the solar system edge or the shattered planet, a planet new to the platform.
2. Routine (anything else): on air depart_routine_hold (25 s) at most once per depart_routine_every (20 min) across
   all platforms and once per depart_route_every (2 h) per route; else in the inset when it is free, at most once per
   depart_inset_every (10 min) and once per depart_inset_route_every (2 h) per route (AS2, operator 09:47: 53 insets
   in shift57's 3 hours were the same repetition, smaller), else not shown.
   Each decision is logged with its reason ("departure routine (inset): Cinder Nauvis->Gleba flown 6 min ago").
3. The model's route memory (model.add_route / route_last): the score's reads and the chronicle's platform_left
   events, one record per departure; kept in space-memory.json and read back along the run chain; seeded from the
   chronicle files along the chain.
4. Shift57 (06:21-09:24, runs/shift57/stream-service.log: 72 departures seen, 55 on air for 51.8 min) replayed through
   the director with each route's last flight before 06:21 from the chronicle: before (every departure news) and after.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from model import Model, platform_where  # noqa: E402
import chronicle_log  # noqa: E402

H = 216000  # game ticks an hour
T0 = 46377000  # the game tick at t=0 (shift57 06:21:00)
PLANETS = {"N": "nauvis", "G": "gleba", "V": "vulcanus", "F": "fulgora", "A": "aquilo", "E": "solar-system-edge"}
VIEWS = {}


def view(name):
    return VIEWS.setdefault(name, {"surface": f"platform-{len(VIEWS) + 1}", "hub": {"x": 0, "y": 0},
                                   "bounds": {"left": -14, "top": -10, "right": 14, "bottom": 12}, "hub_health": 100})


def plat(name, at):
    state = "on_the_path" if "->" in at or at == "in transit" else "waiting_at_station"
    return platform_where({"name": name, "at": at, "state": state, "speed": 1.2 if state == "on_the_path" else 0,
                           "view": view(name)})


def snap(plats, tick):
    return {"agents": [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3)], "alerts": [], "work": [], "fights": [],
            "space": {"platforms": list(plats)}, "tick": tick}


class Source:
    """The model's side for the director (route_last, platform_visited), on a real Model."""
    def __init__(self, routes=(), visited=None):
        self.m = Model({})
        for name, frm, to, tick in routes:
            self.m.add_route(name, frm, to, tick, save=False)
        for name, places in (visited or {}).items():
            self.m.platform_course[name] = {"visited": set(places)}

    def route_last(self, *a):
        return self.m.route_last(*a)

    def platform_visited(self, name):
        return self.m.platform_visited(name)


def depart(d, name, frm, to, t, tick, steps=4):
    """name still at frm, then travelling frm->to: steps of 1 s from t."""
    d.step(snap([plat(name, frm)], tick), t)
    for k in range(1, steps + 1):
        d.step(snap([plat(name, f"{frm}->{to} {k}%")], tick + k * 60), t + k)


def main_platform(d, t):
    return (d.public(t).get("main") or {}).get("platform") or {}


def rules():
    log = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False).name
    d, _ = world(map_every=0, platform_every=0)
    d.log_path = log
    d.route_source = Source([("Cinder", "nauvis", "gleba", T0 - 30 * 3600), ("Cinder", "gleba", "nauvis", T0 - 24 * 3600),
                             ("Spindle", "nauvis", "vulcanus", T0 - 7 * H)],
                            {"Cinder": ["nauvis", "gleba"], "Spindle": ["nauvis", "vulcanus"], "Bastion": ["aquilo"]})
    # a route flown 30 game minutes ago, nothing routine on air yet: on main, held 25 s
    t = 1000
    depart(d, "Cinder", "nauvis", "gleba", t, T0)
    assert d.departs[-1][1:3] == ("Cinder", "main"), d.departs
    assert d.departs[-1][3] == "Cinder Nauvis->Gleba flown 30 min ago", d.departs
    assert main_platform(d, t + 4).get("why") == "departure", d.cuts
    for k in range(5, 60):
        d.step(snap([plat("Cinder", f"nauvis->gleba {k}%")], T0 + k * 60), t + k)
        if not main_platform(d, t + k):
            break
    assert 25 <= k <= 25 + 6, (k, d.cuts)  # 25 s and the framing (ready_s), then the story
    # its return 6 game minutes later: routine, the 20 minutes not over: in the inset
    t, tick = 1400, T0 + 400 * 60
    depart(d, "Cinder", "gleba", "nauvis", t, tick)
    assert d.departs[-1][1:3] == ("Cinder", "inset"), d.departs
    assert d.departs[-1][3].startswith("Cinder Gleba->Nauvis flown 31 min ago; a routine departure went on air 7 min ago"), d.departs
    pub = d.public(t + 4)
    assert pub["inset"]["platform"]["name"] == "Cinder" and not main_platform(d, t + 4), pub
    # another right after (AS2: one routine inset each 10 min): not shown
    depart(d, "Cinder", "nauvis", "gleba", t + 6, tick + 6 * 60, steps=2)
    assert d.departs[-1][1:3] == ("Cinder", "none") and \
        d.departs[-1][3].endswith("; a routine departure went in the inset 0 min ago"), d.departs
    # the inset's own spacing (AS2): 10 min across platforms, 2 h for the same route; then the inset being up
    assert d.routine_turn(("Kestrel", "nauvis", "gleba"), 1401 + 599, inset=True) == \
        "a routine departure went in the inset 10 min ago"
    assert d.routine_turn(("Kestrel", "nauvis", "gleba"), 1401 + 600, inset=True) is None
    assert d.routine_turn(("Cinder", "gleba", "nauvis"), 1401 + 3600, inset=True) == \
        "this route went in the inset 60 min ago"
    assert d.routine_turn(("Cinder", "gleba", "nauvis"), 1401 + 7200, inset=True) is None
    saved, d.routine_inset_t = d.routine_inset_t, []
    depart(d, "Cinder", "gleba", "nauvis", t + 10, tick + 10 * 60, steps=2)
    assert d.departs[-1][1:3] == ("Cinder", "none") and d.departs[-1][3].endswith("; an inset is up"), d.departs
    d.routine_inset_t = saved
    # news: a route not flown in 6 game hours (Spindle Nauvis->Vulcanus, 7 h), at once, on main for depart_hold
    t = 1500
    depart(d, "Spindle", "nauvis", "vulcanus", t, tick + 100 * 60)
    assert d.departs[-1][1:] == ("Spindle", "main", "Spindle Nauvis->Vulcanus: last flown 7.1 h ago"), d.departs
    assert main_platform(d, t + 4).get("name") == "Spindle"
    for k in range(5, 120):
        d.step(snap([plat("Spindle", f"nauvis->vulcanus {k}%")], tick + (100 + k) * 60), t + k)
        if not main_platform(d, t + k):
            break
    assert d.cfg["depart_hold"] <= k <= d.cfg["depart_hold"] + 6, k
    # a planet new to the platform; a leg to the solar system edge; a route with no flight remembered: news
    d.departure = None
    assert d.departure_news("Spindle", plat("Spindle", "nauvis->fulgora 1%"))[::2] == (
        True, "Spindle Nauvis->Fulgora: Fulgora is new to Spindle")
    news, _, why = d.departure_news("Bastion", plat("Bastion", "aquilo->solar-system-edge 1%"))
    assert news and why.endswith(": a leg to or from the solar system edge"), why
    assert d.departure_news("Cinder", plat("Cinder", "nauvis->vulcanus 1%"))[0]  # (vulcanus not visited)
    d.route_source.m.platform_course["Cinder"]["visited"].add("vulcanus")
    assert d.departure_news("Cinder", plat("Cinder", "vulcanus->nauvis 1%"))[2] == \
        "Cinder Vulcanus->Nauvis: no flight on this route remembered"
    # routine again after 20 min, another route: on main; the same route within 2 h: not on main
    t = 1400 + 1300
    d.game_tick = tick + 1300 * 60
    d.departure = {"name": "Cinder", "t": t, "label": "Cinder · leaving Gleba for Nauvis", "news": False,
                   "route": ("Cinder", "gleba", "nauvis"), "why": "Cinder Gleba->Nauvis flown 10 min ago"}
    assert d.routine_turn(("Cinder", "gleba", "nauvis"), t) is None
    assert d.routine_turn(("Cinder", "nauvis", "gleba"), t) == "this route went on air 28 min ago", d.routine_main
    # each decision is in the director log with its reason
    rows = [json.loads(l) for l in open(log)]
    dep = [r for r in rows if r.get("departure")]
    assert [r["departure"]["decision"] for r in dep] == ["main", "inset", "none", "none", "main"], dep
    assert dep[1]["reason"].startswith("departure routine (inset): Cinder Gleba->Nauvis flown 31 min ago"), dep[1]
    os.remove(log)
    # a maiden flight stays news: a routine route with the routine budget spent, its maiden moment in the same read
    d, _ = world(map_every=0, platform_every=0)
    d.route_source = Source([("Cinder", "nauvis", "gleba", T0 - 600 * 60)], {"Cinder": ["nauvis", "gleba"]})
    d.routine_main.append((2900, ("Kestrel", "nauvis", "gleba")))
    d.step(snap([plat("Cinder", "nauvis")], T0), 3000)
    s = snap([plat("Cinder", "nauvis->gleba 1%")], T0 + 60)
    s["space"]["moments"] = [{"kind": "maiden_flight", "id": "m-1", "t": 3001,
                              "facts": {"platform": "Cinder", "from": "Nauvis", "to": "Gleba", "built_by": "Luna"}}]
    d.step(s, 3001)
    for k in range(2, 6):
        d.step(snap([plat("Cinder", f"nauvis->gleba {k}%")], T0 + k * 60), 3000 + k)
    assert main_platform(d, 3005).get("maiden"), d.cuts
    assert not [x for x in d.departs if x[2] == "inset"], d.departs
    print("rules: ok")


def memory():
    m = Model({})
    m.add_route("Cinder", "nauvis", "gleba", 1000 * 60, save=False)
    m.add_route("Cinder", "nauvis", "gleba", 1000 * 60 + 300, save=False)  # the chronicle's record of the same one
    assert m.platform_routes["Cinder"]["nauvis>gleba"] == [60000], m.platform_routes
    for k in range(1, 7):
        m.add_route("Cinder", "nauvis", "gleba", (1000 + 10 * k) * 3600, save=False)
    assert len(m.platform_routes["Cinder"]["nauvis>gleba"]) == Model.ROUTE_KEEP
    assert m.route_last("Cinder", "nauvis", "gleba", 1045 * 3600) == 1040 * 3600
    assert m.route_last("Cinder", "gleba", "nauvis", 10 ** 9) is None
    # seen leaving a stop in the score's reads (the tick of the read)
    m = Model({})
    for t, at, tick in ((100, "nauvis", 5000), (101, "nauvis->gleba 1%", 5060)):
        m.ingest({"tick": tick, "agents": [], "space": {"platforms": [{"name": "Cinder", "at": at, "hub": True}]}}, t)
        m.snapshot(t)
    assert m.platform_routes == {"Cinder": {"nauvis>gleba": [5060]}}, m.platform_routes
    assert m.platform_visited("Cinder") == {"nauvis", "gleba"} and m.platform_visited("Nobody") is None
    # a new shift's model: no visited yet, the chronicle's routes say where it has been
    m = Model({})
    m.add_route("Spindle", "fulgora", "nauvis", 100, save=False)
    m.platform_course["Spindle"] = {"visited": {"nauvis"}}
    assert m.platform_visited("Spindle") == {"fulgora", "nauvis"}
    with tempfile.TemporaryDirectory() as root:
        prev, run = os.path.join(root, "shift56"), os.path.join(root, "shift57")
        os.makedirs(prev)
        os.makedirs(run)
        open(os.path.join(run, "resumed-from"), "w").write("shift56\n")
        # the earlier shift's space memory and chronicle: both seed the new run's routes
        json.dump({"visited": {}, "reached": [], "routes": {"Spindle": {"nauvis>vulcanus": [7000]}}},
                  open(os.path.join(prev, "space-memory.json"), "w"))
        with open(os.path.join(prev, "chronicle.jsonl"), "w") as f:
            for i, (p, a, b, tick) in enumerate((("Cinder", "gleba", "nauvis", 9000), ("Cinder", "nauvis", "gleba", 9500))):
                f.write(json.dumps({"type": "event", "id": i + 1, "kind": "platform_left", "platform": p, "at": a,
                                    "to": b, "tick": tick}) + "\n")
        assert chronicle_log.departures(os.path.join(run, "chronicle.jsonl")) == [
            ("Cinder", "gleba", "nauvis", 9000), ("Cinder", "nauvis", "gleba", 9500)]
        m = Model({})
        m.set_space_memory(os.path.join(run, "space-memory.json"), [os.path.join(prev, "space-memory.json")])
        m.set_platform_history(os.path.join(run, "chronicle.jsonl"))
        assert m.route_last("Spindle", "nauvis", "vulcanus", 10 ** 9) == 7000
        assert m.route_last("Cinder", "nauvis", "gleba", 10 ** 9) == 9500
        # a departure the chronicle reports: kept, and written to this run's space memory
        m.tick = 20000
        m._ingest_chronicle_event({"id": 9, "kind": "platform_left", "platform": "Cinder", "at": "gleba", "to": "nauvis",
                                   "tick": 20000}, 500)
        mem = json.load(open(os.path.join(run, "space-memory.json")))
        assert mem["routes"]["Cinder"]["gleba>nauvis"] == [9000, 20000], mem
        m2 = Model({})
        m2.set_space_memory(os.path.join(run, "space-memory.json"))
        assert m2.route_last("Cinder", "gleba", "nauvis", 10 ** 9) == 20000
    print("memory: ok")


# runs/shift57/stream-service.log 06:21:00-09:23:59, each departure the director saw: seconds after 06:21:00,
# platform, from and to (N Nauvis, G Gleba, V Vulcanus, F Fulgora; "--" in transit, its route not read)
EVENTS = """
26:Cinder:GN 72:Spindle:VN 405:Cinder:NG 771:Cinder:GN 853:Spindle:NF 1132:Cinder:NG 1562:Cinder:GN
1893:Spindle:FN 1926:Cinder:NG 2289:Spindle:NV 2379:Cinder:GN 2744:Cinder:NG 3131:Cinder:GN 3529:Cinder:NG
3899:Cinder:GN 3962:Spindle:VN 4272:Cinder:NG 4485:Spindle:NF 4705:Cinder:GN 5420:Cinder:NG 5648:Spindle:FN
5892:Cinder:GN 6027:Spindle:NV 6259:Cinder:NG 6634:Cinder:GN 6998:Cinder:NG 7383:Cinder:GN 7506:Spindle:VN
7629:Petrel_II:-- 7737:Cinder:NG 7737:Kestrel_IVa:NG 7737:Asterion:FN 7890:Petrel_II:NG 8073:Anvil:VN
8120:Cinder:GN 8120:Kestrel_II:GN 8136:Kestrel_IVa:GN 8304:Petrel:NG 8318:Spindle:NF 8472:Petrel_II:GN
8546:Kestrel_IVa:NG 8624:Kestrel_II:NF 8624:Petrel:GN 8744:Petrel_II:NG 8874:Asterion:NG 8888:Petrel:NG
8904:Anvil:NF 8951:Kestrel_IVa:GN 9011:Petrel_II:GN 9165:Petrel:GN 9246:Spindle:FN 9280:Cinder:NG
9360:Kestrel_IVa:NG 9425:Anvil:FN 9612:Spindle:NV 9628:Solstice:NG 9653:Cinder:GN 9759:Kestrel_IVa:GN
9869:Anvil:NV 10015:Cinder:NG 10168:Kestrel_IVa:NG 10244:Solstice:GN 10321:Asterion:GN 10387:Cinder:GN
10493:Spindle:VN 10571:Kestrel_IVa:GN 10604:Petrel_II:NG 10754:Solstice:NG 10860:Petrel_II:GN 10875:Petrel:NG
10938:Spindle:NF 10938:Anvil:VN
"""
# each route's last flight before 06:21:00 (runs/shift57/chronicle.jsonl along the run chain): game seconds before
SEED = """
Anvil:FN:287 Anvil:NF:770 Anvil:NV:4598 Anvil:VN:1238 Asterion:FN:2266 Asterion:NF:2997 Cinder:FG:307146
Cinder:FN:319098 Cinder:GN:2110 Cinder:NF:307510 Cinder:NG:1737 Cinder:NV:318795 Cinder:VN:318453
Kestrel_II:AF:239909 Kestrel_II:AG:4596 Kestrel_II:FA:5454 Kestrel_II:FN:235889 Kestrel_II:GA:171705
Kestrel_II:GF:296052 Kestrel_II:GN:3859 Kestrel_II:NF:6863 Kestrel_II:NG:172007 Kestrel_II:VG:341976
Kestrel_IVa:AG:152741 Kestrel_IVa:FA:153572 Kestrel_IVa:GN:1966 Kestrel_IVa:NF:161943 Kestrel_IVa:NG:2367
Petrel_II:GN:4069 Petrel_II:NG:4569 Petrel:FA:482665 Petrel:FN:301467 Petrel:GN:2286 Petrel:NF:302453
Petrel:NG:2550 Petrel:NV:490772 Petrel:VN:484874 Solstice:GN:5227 Solstice:NG:5841 Solstice:NV:73804
Solstice:VN:73329 Spindle:FG:274800 Spindle:FN:6015 Spindle:GF:275540 Spindle:GN:282694 Spindle:GV:273584
Spindle:NF:7064 Spindle:NG:276575 Spindle:NV:5627 Spindle:VN:7835
"""
# where each had been (runs/shift56/space-memory.json visited)
VISITED = """
Anvil:FNV Asterion:FN Cinder:GN Kestrel_II:AFGN Kestrel_IVa:GN Petrel:GN Petrel_II:GN Solstice:GN Spindle:FNV
"""


def replay(news_h=None, step=2, end=11100):
    """Shift57's departures through the director, a step every `step` s: each ship travels 150 s after its departure
    (or until just before its next one), then waits at the destination. -> (on main, in the inset, not shown, minutes
    on main). news_h=0: every departure news (the rule before AS1)."""
    ev = []
    for tok in EVENTS.split():
        t, name, legs = tok.split(":")
        ev.append((int(t), name.replace("_", " "), PLANETS.get(legs[0]), PLANETS.get(legs[1])))
    seeds = []
    for tok in SEED.split():
        name, legs, s = tok.split(":")
        seeds.append((name.replace("_", " "), PLANETS[legs[0]], PLANETS[legs[1]], T0 - int(s) * 60))
    visited = {n.replace("_", " "): [PLANETS[c] for c in v] for n, v in (tok.split(":") for tok in VISITED.split())}
    cfg = {"map_every": 0, "platform_every": 0}
    if news_h is not None:
        cfg["depart_news_h"] = news_h
    d, _ = world(**cfg)
    src = d.route_source = Source(seeds, visited)
    ships = sorted({e[1] for e in ev})
    legs = {n: [e for e in ev if e[1] == n] for n in ships}
    def at(name, t):
        ls = legs[name]
        past = [e for e in ls if e[0] <= t]
        if not past:
            return ls[0][2] or "nauvis"
        e = past[-1]
        nxt = next((x[0] for x in ls if x[0] > e[0]), None)
        arrive = min(e[0] + 150, nxt - step if nxt else e[0] + 150)
        if t < arrive:
            if not e[2]:
                return "in transit"
            return f"{e[2]}->{e[3]} {min(99, 1 + int(98 * (t - e[0]) / 150))}%"
        if e[3]:
            src.m.platform_course.setdefault(name, {"visited": set()})["visited"].add(e[3])
        return e[3] or "nauvis"
    main_s = inset_s = 0.0
    for t in range(-20, end, step):
        d.step(snap([plat(n, at(n, t)) for n in ships], T0 + t * 60), t)
        if main_platform(d, t).get("why") == "departure":
            main_s += step
        if ((d.public(t).get("inset") or {}).get("platform") or {}).get("why") == "departure":
            inset_s += step
    count = {k: sum(1 for x in d.departs if x[2] == k) for k in ("main", "inset", "none")}
    d.inset_minutes = inset_s / 60
    return count, main_s / 60, d


def shift57():
    before, before_min, _ = replay(news_h=0)
    after, after_min, d = replay()
    news = [x for x in d.departs if x[2] == "main" and ":" in x[3].split(";")[0] and "flown" not in x[3]]
    print(f"shift57 06:21-09:24, 72 departures: before {before['main']} on main for {before_min:.1f} min "
          f"(the log: 55 for 51.8); after {after['main']} on main for {after_min:.1f} min, {after['inset']} in the inset "
          f"for {d.inset_minutes:.1f} min, "
          f"{after['none']} not shown; news: {[x[3] for x in news]}")
    assert before["main"] >= 50 and before_min >= 45, (before, before_min)
    assert after["main"] <= 15 and after_min <= 12, (after, after_min)
    assert after["inset"] <= 183 // 10 + 1, after  # (AS2) one routine inset each 10 min at most
    assert sum(after.values()) == 72, after  # each departure decided once
    return before, before_min, after, after_min, d


if __name__ == "__main__":
    rules()
    memory()
    shift57()
    print("departnews: ok (news on main, routine rationed to one each 20 min and a route each 2 h, else the inset "
          "(one each 10 min, a route each 2 h) or nothing, each decision logged; route memory in space-memory.json and from the chronicle; shift57 replayed)")
