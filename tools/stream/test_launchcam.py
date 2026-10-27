#!/usr/bin/env python3
"""The launch shot (d26 batch257 IB): python3 tools/stream/test_launchcam.py

shift83 18:37-22:41: 43.3% of the program a standing character; in 101 of its 107 idle minutes every character stood
(Sol's busy clocks were uptime measurements) and no platform action was within 12 s. 1261 rockets launched in it, none
on air. A silo ordered to launch lifts off 8-10 s later (launches.py), so the 3 s poll sees it coming.

1. launches.SiloFeed: silos from the agents' replies (their surface, else the reply's surface or planet; none without
   one), kept in silos.json; a read gives each silo's state, a launching one's lift-off window in wall seconds at the
   game's speed and its destination from the chronicle; a silo gone three reads is dropped; with the force's count over
   the list it sweeps one block a poll, then pauses.
2. harness SILOS_LUA and SILO_SWEEP_LUA: one line, no comments; Harness.silos sends the list and reads the reply.
3. A story standing still and a launch due: framed north of the silo, cut before lift-off, held through the flight, then
   the story; the next launch only after launch_gap.
4. No launch over another agent moving, the story's own news, a segment, a fight or a vehicle on its way.
5. A launch shot gives way to fresh news once its rocket is up, not before.
6. Silos of a planet launching together share the frame.
7. The trio: a busy trio only of agents doing something; a check-in trio gives way to news after quiet_min.
8. airtime: the chronicle's ticks at wall time, launches on air; director_replay.Launches: a silo's states from a
   rocket's order.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from onecam import OneCam  # noqa: E402
import airtime, director_replay, harness, launches  # noqa: E402

T0 = 1793070000.0
AQ = ("aquilo", -18.5, 17.5)


class FakeH:
    """The harness's silos() and silo_sweep() over a world of silo states."""

    def __init__(self, states, count=None, sweep=None):
        self.states, self.count, self.sweep = states, count, sweep or {}
        self.tick, self.asked, self.swept = 1000000, [], []

    def silos(self, silos):
        self.asked.append(list(silos))
        return {"tick": self.tick, "n": self.count if self.count is not None else len(silos),
                "s": [self.states.get((s, x, y), -1) for s, x, y in silos]}

    def silo_sweep(self, surface, area):
        self.swept.append((surface, area))
        found = [p for p in self.sweep.get(surface, []) if area[0][0] <= p[0] < area[1][0] and area[0][1] <= p[1] < area[1][1]]
        return {"silos": found, "planets": sorted(self.sweep) or ["nauvis"]}


def reply(result):
    return {"event": "response", "response": {"id": "r", "ok": True, "result": result}}


def silo_feed():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "silos.json")
        f = launches.SiloFeed(path)
        f.ingest("sol", reply({"surface": "aquilo", "silos": [{"position": {"x": -18.5, "y": 17.5}, "status": "rocket_ready"}]}))
        f.ingest("luna", reply({"planet": "fulgora", "silos": [{"position": {"x": -65.5, "y": 90.5}}]}))
        f.ingest("luna", reply({"silos": [{"position": {"x": 1, "y": 2}}]}))  # no surface: not guessed
        f.ingest("astra", reply({"silos": [{"surface": "nauvis", "position": {"x": 15.5, "y": 59.5}}]}))
        assert sorted(f.silos) == ["aquilo@-18.5,17.5", "fulgora@-65.5,90.5", "nauvis@15.5,59.5"], f.silos
        assert len(json.load(open(path))["silos"]) == 3 and len(launches.SiloFeed(path).silos) == 3, "kept in silos.json"
        h = FakeH({AQ: 7, ("fulgora", -65.5, 90.5): 7, ("nauvis", 15.5, 59.5): 7})
        got = f.read(h, T0)
        assert [r["status"] for r in got["rows"]] == [7, 7, 7] and not any("lift" in r for r in got["rows"]), got
        f.note_rockets([{"kind": "rocket", "surface": "aquilo", "to": "platform Asterion", "tick": 1000150}])
        h.states[AQ], h.tick = 14, 1000180  # 180 ticks in 3 s: 60 UPS
        got = f.read(h, T0 + 3)
        row = next(r for r in got["rows"] if r["surface"] == "aquilo")
        assert row["lift"] == (round(T0 + 3 + 6.7, 1), round(T0 + 3 + 10.3, 1)) and row["to"] == "Asterion", row
        h.states[AQ], h.tick = 9, h.tick + 90  # 90 ticks in 3 s: the game at half speed, the window twice as long
        for k in range(4):
            got = f.read(h, T0 + 6 + 3 * k)
            h.tick += 90
        assert f.ups < 40, f.ups
        h.states.pop(("fulgora", -65.5, 90.5))  # mined
        for k in range(launches.MISS_DROP):
            f.read(h, T0 + 30 + 3 * k)
        assert "fulgora@-65.5,90.5" not in f.silos and len(json.load(open(path))["silos"]) == 2
    # no sweep in the first SWEEP_GRACE (the journals name the silos first)
    f = launches.SiloFeed(None)
    h = FakeH({}, count=3, sweep={"nauvis": [(15.5, 59.5)]})
    for k in range(5):
        f.read(h, T0 + 3 * k)
    assert not h.swept and f.sweep_after == T0 + launches.SWEEP_GRACE, (h.swept, f.sweep_after)
    # the force has a silo the list lacks: one block a poll, the planets in turn, then a pause
    old = launches.SWEEP_REACH
    launches.SWEEP_REACH = launches.SWEEP_BLOCK  # 4 blocks a planet
    try:
        f = launches.SiloFeed(None)
        f.add("nauvis", 15.5, 59.5, save=False)
        f.sweep_after = 1.0  # past the start's grace
        h = FakeH({("nauvis", 15.5, 59.5): 7, ("vulcanus", -3.5, 165.5): 7}, count=2,
                  sweep={"nauvis": [(15.5, 59.5)], "vulcanus": [(-3.5, 165.5)]})
        t = T0
        for _ in range(12):
            f.read(h, t)
            t += 3
        assert "vulcanus@-3.5,165.5" in f.silos and f.sweep is None, (f.silos, h.swept)
        n = len(h.swept)
        assert n <= 1 + 4 + 4, h.swept  # the planets read, then at most every block of both
        h.count = 3  # one more nowhere in reach: a whole sweep, then none for SWEEP_PAUSE
        for _ in range(20):
            f.read(h, t)
            t += 3
        swept = len(h.swept)
        for _ in range(20):
            f.read(h, t)
            t += 3
        assert len(h.swept) == swept and f.sweep_after > t, (len(h.swept), swept)
    finally:
        launches.SWEEP_REACH = old
    print("1. SiloFeed: silos from replies, states, lift-off window at the game's speed, destination, dropped, sweep: ok")


def harness_reads():
    for src in (harness.SILOS_LUA, harness.SILO_SWEEP_LUA):
        assert "--" not in src
        assert "\n" not in harness.one_line(src)
    sent = []
    h = harness.Harness.__new__(harness.Harness)
    h.command = lambda cmd: sent.append(cmd) or json.dumps({"tick": 5, "n": 2, "s": [7, 14]})
    got = h.silos([("aquilo", -18.5, 17.5), ("nauvis", 15.5, 59.5)])
    assert got == {"tick": 5, "n": 2, "s": [7, 14]}, got
    assert '{[[aquilo]],-18.5,17.5}' in sent[0] and "find_entity" in sent[0] and "get_entity_by_unit_number" not in sent[0]
    h.command = lambda cmd: sent.append(cmd) or json.dumps({"planets": ["nauvis", "gleba"], "silos": {}})
    got = h.silo_sweep("gleba", ((0, 0), (256, 256)))
    assert got == {"silos": [], "planets": ["nauvis", "gleba"]} and "{{0,0},{256,256}}" in sent[-1], got
    # each as sent, run under a stub game in the local lua (a name in [[...]] after "[" opened a long string: the
    # first sweep on world n failed to compile)
    lua = shutil.which("lua") or shutil.which("lua5.4")
    if lua:
        stub = ("local E = {rocket_silo_status = 7, position = {x = 65.5, y = 14.5}} "
                "local S = {find_entity = function(n, p) return E end, find_entities_filtered = function(f) return {E} end} "
                "game = {tick = 9, surfaces = {gleba = S, aquilo = S}, planets = {gleba = {surface = {name = 'gleba'}}}, "
                "forces = {player = {get_entity_count = function(n) return 2 end}}} "
                "helpers = {table_to_json = function(t) return 'ok' end} rcon = {print = function(x) io.write(x) end} ")
        for cmd in (sent[0], sent[-1]):
            out = subprocess.run([lua, "-e", stub + cmd[len("/silent-command "):]], capture_output=True, text=True)
            assert out.returncode == 0 and out.stdout == "ok", (out.stderr, cmd[:200])
    else:
        print("   (no lua here: the generated reads not compiled)")
    print("2. SILOS_LUA, SILO_SWEEP_LUA: one line; the list sent, the reply read (an empty table as {}); they run: ok")


def team(t, moving=None, news=None):
    """Astra (on air) and Sol standing; `moving`: Luna walking; `news`: a build of Astra's at that time."""
    astra = agent("astra", 0, 0, 20, activity="thinking", active=False)
    sol = agent("sol", 500, 0, 2, activity="thinking", active=False)
    out = [astra, sol]
    if news is not None and 0 <= t - news <= 120:
        astra["did"] = {"action": "build", "t": news, "position": {"x": 2, "y": 1}, "platform": None}
    if moving is not None:
        out.append(agent("luna", 300 + (t - moving) * 3.0, 300, 1, activity="acting", active="walk"))
    return out


def director(**cfg):
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, **dict(dict(trio=False, map_every=0, platform_every=0, bow=False,
                                                                  tour_every=0), **cfg))
    d.started = d.onair_since = T0 - 300
    return d


def state(order, t):
    """A silo's status t after its order (director_replay.LAUNCH_STEPS), 7 before it or with none."""
    if order is None or t < order:
        return 7
    dt = t - order
    for st, d in director_replay.LAUNCH_STEPS:
        if dt < d:
            return st
        dt -= d
    return 7


class World:
    """A launch timeline: silo -> order wall time; the silos read every 3 s through SiloFeed."""

    def __init__(self, orders):
        self.orders = orders
        self.feed = launches.SiloFeed(None)
        for s, x, y in {k for k in orders} | {AQ}:
            self.feed.add(s, x, y, save=False)
        self.h = FakeH({})
        self.last, self.snap = -1e9, None

    def silos(self, t):
        if t - self.last >= 3.0:
            self.last = t
            for k in self.feed.silos.values():
                key = (k["surface"], k["x"], k["y"])
                self.h.states[key] = state(self.orders.get(key), t)
            self.h.tick = int(1000000 + (t - T0) * 60)
            self.snap = self.feed.read(self.h, t)
        return self.snap


def run(d, world, t0, t1, seg=None, **team_kw):
    t = t0
    while t < t1:
        d.step({"agents": team(t, **team_kw), "alerts": [], "silos": world.silos(t)}, t,
               seg if seg and t < seg["until"] else None)
        t += 1
    return t


def launch_shot():
    d = director()
    w = World({AQ: T0 + 1})  # ordered at T0 + 1: lifts off at T0 + 10.9
    run(d, w, T0 - 120, T0)
    assert d.state[d.onair]["subject"] == "astra"
    seen, tgt = [], None
    t = T0
    while t < T0 + 40:
        d.step({"agents": team(t), "alerts": [], "silos": w.silos(t)}, t)
        cur = d.state[d.onair]
        seen.append((t, cur.get("subject"), (cur.get("launch") or {}).get("label")))
        tgt = tgt or (cur if cur.get("launch") else None)
        t += 1
    on = [s for s in seen if s[2]]
    assert on, d.cuts[-3:]
    lift = T0 + 1 + 0.6 + 2.0 + 5.6 + 1.7
    assert on[0][0] < lift - 0.5, (on[0], lift)
    assert d.cuts[-2][2].startswith("launch: Rocket launch · Aquilo (astra still"), d.cuts[-2:]
    assert lift + 3 <= on[-1][0] <= lift + d.cfg["launch_after"] + 4, (on[-1], lift)
    assert d.cuts[-1][2] == "back to astra", d.cuts[-1]
    assert tgt["position"] == {"x": -18.5, "y": round(17.5 - d.cfg["launch_up"], 1)} and tgt["surface"] == "aquilo", tgt
    # another launch right after: not within launch_gap of the shot's end
    w.orders[AQ] = t + 1
    end = d.launch_end
    run(d, w, t, t + 30)
    later = [c for c in d.cuts if c[0] > end and c[2].startswith("launch:")]
    assert not later or later[0][0] >= end + d.cfg["launch_gap"], (later, end)
    print(f"3. a launch over a story standing still: on air {lift - on[0][0]:.1f} s before lift-off, off "
          f"{on[-1][0] - lift:.0f} s after, back to the story; launch_gap kept: ok")


def no_launch():
    for why, kw, seg in (("another agent moving", {"moving": T0 - 200}, None),
                         ("the story's own news", {"news": T0 - 20}, None),
                         ("a segment", {}, {"id": "s", "label": "Spotlight", "zoom": 0.5, "until": T0 + 40,
                                            "position": {"x": 0, "y": -100}, "surface": "nauvis", "exact_zoom": True})):
        d = director()
        w = World({AQ: T0 + 1})
        run(d, w, T0 - 120, T0 + 30, seg, **kw)
        assert not [c for c in d.cuts if c[2].startswith("launch:")], (why, d.cuts[-3:])
    d = director()
    w = World({AQ: T0 + 1})
    run(d, w, T0 - 120, T0)
    d.fight_list = [{"key": "f", "first": T0 - 5, "last": T0}]
    d.fight_t = lambda f: T0
    t = T0
    while t < T0 + 8:
        d.step({"agents": team(t), "alerts": [], "silos": w.silos(t), "fights": [{"key": "f", "first": T0 - 5, "last": T0,
                                                                                    "position": {"x": 900, "y": 900}}]}, t)
        t += 1
    assert not [c for c in d.cuts if c[2].startswith("launch:")], d.cuts[-3:]
    d = director()
    d.state[d.onair] = {"subject": "astra", "agents": ["astra"], "follow": "astra", "vehicle": "spidertron", "zoom": 1}
    d.vehicle_stuck_s = lambda n, now: 0
    assert d.launch_quiet({"astra": {"name": "astra"}}, {"astra": 1}, T0, None) is None
    print("4. no launch over another agent moving, the story's news, a segment, a fight or a vehicle on its way: ok")


def gives_way():
    d = director()
    w = World({AQ: T0 + 1})
    run(d, w, T0 - 120, T0)
    lift = T0 + 1 + 9.9
    t = T0
    first_sol = None
    while t < T0 + 30:
        sol_did = {"action": "build", "t": T0 + 4, "position": {"x": 501, "y": 1}, "platform": None} if t >= T0 + 4 else None
        a = team(t)
        a[1]["did"] = sol_did
        d.step({"agents": a, "alerts": [], "silos": w.silos(t)}, t)
        if first_sol is None and d.state[d.onair].get("subject") == "sol":
            first_sol = t
        t += 1
    assert first_sol is not None and lift <= first_sol <= lift + 6, (first_sol, lift, d.cuts[-4:])
    print(f"5. a build during a launch: on air {first_sol - lift:.0f} s after lift-off, not before: ok")


def together():
    d = director()
    a, b = ("nauvis", 23.5, 101.5), ("nauvis", 35.5, 111.5)
    w = World({a: T0 + 1, b: T0 + 2})
    run(d, w, T0 - 120, T0 + 6)
    cut = next(c for c in d.cuts if c[2].startswith("launch:"))
    assert "Nauvis" in cut[2] and "2 rockets" in cut[2], cut
    print("6. two Nauvis silos launching together: one frame, '2 rockets': ok")


def trio_rules():
    d = OneCam(SLOTS, lambda body: {"ok": True}, None, map_every=0, platform_every=0, bow=False, tour_every=0)
    d.started = d.onair_since = T0 - 900
    def grok(t):
        g = agent("grok", 900, 900, 1, activity="thinking", active=False)
        if t >= T0 + 3:
            g["did"] = {"action": "build", "t": T0 + 3, "position": {"x": 900, "y": 900}, "platform": None}
        return g
    for t in range(int(T0) - 120, int(T0)):
        ag = [agent("astra", 0, 0, 20, activity="thinking", active=False), agent("sol", 500, 0, 19, activity="thinking", active=False),
              agent("luna", -500, 300, 19, activity="thinking", active=False)]
        d.step({"agents": ag + [grok(t)], "alerts": []}, t)
    scores = {"astra": 20, "sol": 19, "luna": 19, "grok": 1}
    by = {a["name"]: a for a in ag}
    d.last_trio = T0  # no check-in due
    by["grok"] = grok(T0 - 1)
    assert d.trio_pick("astra", by, scores, ["astra", "sol", "luna", "grok"], T0) is None, "three standing: no busy trio"
    d.cfg["trio_busy_lively"] = False
    assert d.trio_pick("astra", by, scores, ["astra", "sol", "luna", "grok"], T0)[1] == "busy"
    d.cfg["trio_busy_lively"] = True
    # a check-in trio up, then news of an agent off it
    d.trio = {"tiles": {"cam2": "cam2", "cam3": "cam3"}, "agents": ["sol"], "why": "check-in", "until": T0 + 90}
    d.set_mode("trio", "check-in: sol", T0)
    t = T0
    while t < T0 + 20 and d.mode == "trio":
        d.step({"agents": ag + [grok(t)], "alerts": []}, t)
        t += 1
    assert d.mode == "onecam" and d.cfg["quiet_min"] <= t - T0 <= d.cfg["quiet_min"] + 2, (d.mode, t - T0, d.layouts[-2:])
    assert d.layouts[-1][2].startswith("grok fresh:"), d.layouts[-1]
    print(f"7. trio: no busy trio of standing agents; a check-in trio left for news {t - T0:.0f} s in: ok")


def counts():
    rows = [{"type": "event", "kind": "rocket", "surface": "aquilo", "tick": 600000, "t": T0 + 2.0},
            {"type": "event", "kind": "rocket", "surface": "nauvis", "tick": 606000, "t": T0 + 101.5},
            {"type": "event", "kind": "research", "tick": 612000, "t": T0 + 200.5}]
    rk, ev = airtime.chronicle_rockets(rows)
    assert [round(r[0] - T0, 1) for r in rk] == [0.5, 100.5] and len(ev) == 3, rk  # the lowest t - tick/60 nearby (row 3)
    log = [{"t": T0, "slot": "main", "reason": "standby: astra", "cmd": {"follow": "astra"}, "target": {"agents": ["astra"]}},
           {"t": T0 + 5, "slot": "cam2", "reason": "launch: Rocket launch · Aquilo (astra still 40 s)", "cmd": {},
            "target": {"agents": []}},
           {"t": T0 + 7, "slot": "program", "reason": "cut to cam2: launch: Rocket launch · Aquilo (astra still 40 s)"},
           {"t": T0 + 20, "slot": "program", "reason": "cut to main: back to astra"},
           {"t": T0 + 200, "slot": "main", "reason": "reframe", "cmd": {}}]
    m = airtime.launches_on_air(log, rk, T0, T0 + 200)
    assert m == {"shots": 1, "shot_min": 0.2, "rockets": 2, "on_air": 1, "cut_before": 1}, m
    plan = director_replay.Launches.__new__(director_replay.Launches)
    plan.plan = {AQ: [T0]}
    seq = [plan.status(AQ, T0 + s) for s in (-1, 0.3, 1.0, 3.0, 9.0, 11.0, 20.0, 27.0, 40.0)]
    assert seq == [7, 8, 14, 9, 10, 11, 5, 6, 7], seq
    print("8. chronicle ticks at wall time, launches on air; the replay's silo states from an order: ok")


def main():
    silo_feed()
    harness_reads()
    launch_shot()
    no_launch()
    gives_way()
    together()
    trio_rules()
    counts()
    print("test_launchcam: ok")


if __name__ == "__main__":
    main()
