#!/usr/bin/env python3
"""Idle air and late builds (d26 batch240 IA, batch237 findings 1 and 3): python3 tools/stream/test_idlecam.py

shift80 06:11-10:15: 51.3% of the program showed a standing character or a walk loop; of 16 new builds (dry runs
aside) 4 aired at once, 9 late (75 s median), 3 never. The live read shows a character's running action only, so the
director saw no build, paste or silo load (done within the request); it went back to a stale story after each urgent
or timed shot (51.8 of the 125 idle minutes); the planet bonus held standing characters on air.

1. work.did_kind and DidFeed: a dry run, a launch that only sets the silo, ghosts of which none were placed are no
   build; a real one is the agent's row (where it landed, its platform) for DID_KEEP.
2. work.ClockFeed: idle replies in a row are one idle stretch from the first one's span start; a reply not idle ends
   it; an agent silent past CLOCK_KEEP is not known. airtime: a dry run is no fresh event, the real build after it is.
3. A build the read never shows: the agent placing ghosts by its character is on air within 30 s of a stale story.
4. A build away from the character: its spot is the shot while it is did_hold old, then the character again.
5. Back from a timed shot: not to a story standing still while another agent moves; to it when it acts; fresh news
   first.
6. A quiet view gives way to a fresh agent once it has been up quiet_min.
7. The planet bonus: for an agent on a short planet doing something, not for one standing there.
8. model.did_interest: a new build bumps its agent's interest once; did and idle_s reach the director (live.py, model).
9. director_replay.py: the log's timed shots (quiet views marked), positions read once a poll, instant requests no
   running action, loops and sleeps keeping no interest, running actions over busy clocks, did and idle_s inputs.
"""
import os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from onecam import OneCam  # noqa: E402
import airtime, director_replay, work  # noqa: E402

T0 = airtime.iso_t("2026-10-26T15:18:15Z")  # shift80 08:18:15


def at(t):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def rows(rid, t, action, args, result, ok=True):
    return [{"at": at(t), "event": "request", "request": {"id": rid, "action": action, "args": args}},
            {"at": at(t + 0.05), "event": "response", "response": {"id": rid, "ok": ok, "result": result}}]


GHOSTS = {"entities": [{"name": "beacon", "position": {"x": 91.5, "y": 111.5}}, {"name": "biolab", "position": {"x": 95.5, "y": 115.5}}]}


def did_feed():
    assert work.did_kind("place_ghosts", dict(GHOSTS, dry_run=True), {"dry_run": True, "note": "nothing was placed"}) is None
    assert work.did_kind("build", {"item": "pole"}, {"dry_run": True}) is None
    assert work.did_kind("launch", {"position": {"x": 14.5, "y": 140.5}, "auto_requests": True},
                         {"auto_requests": True, "settings": {"silo": "rocket-silo"}}) is None
    assert work.did_kind("place_ghosts", GHOSTS, {"placed": 0}) is None
    assert work.did_kind("deconstruct", {"area": {}}, {"changed": 0}) is None
    assert work.did_kind("observe", {}, {}) is None
    assert work.did_kind("place_ghosts", GHOSTS, {"placed": 14}) == "place_ghosts"
    feed = work.DidFeed()
    for r in rows("d1", T0 - 30, "place_ghosts", dict(GHOSTS, dry_run=True), {"dry_run": True}):
        feed.ingest("astra", r)
    assert feed.current("astra", T0 - 29) is None
    for r in rows("d2", T0, "place_ghosts", GHOSTS, {"placed": 14}):
        feed.ingest("astra", r)
    for r in rows("d3", T0 + 1, "load_silo", {"platform": "Loom", "position": {"x": 1, "y": 2}}, {"loaded": 1}, ok=False):
        feed.ingest("sol", r)
    d = feed.current("astra", T0 + 5)
    assert d == {"action": "place_ghosts", "t": T0, "position": {"x": 93.5, "y": 113.5}, "platform": None}, d
    assert feed.current("sol", T0 + 5) is None, "a refused request is no build"
    for r in rows("d4", T0 + 2, "deconstruct", {"platform": "Loom", "area": {"left_top": {"x": -4, "y": 4},
                                                                             "right_bottom": {"x": -3, "y": 6}}}, {"changed": 2}):
        feed.ingest("sol", r)
    assert feed.current("sol", T0 + 5)["platform"] == "Loom"
    assert feed.current("astra", T0 + work.DID_KEEP + 1) is None
    print("1. did_kind and DidFeed: no dry run, settings call, empty placement or refusal; a real build is a row: ok")


def clock(span, idle):
    return {"clock": f"game 307h53m; +{span}s since your last request, character idle {idle}s of it (100%); hand crafting 0s queued"}


def clock_feed():
    c = work.ClockFeed()
    for k, (span, idle) in enumerate([(5, 1), (20, 20), (20, 20), (20, 19)]):
        t = T0 + 5 + 20 * k  # replies at +5 (busy), +25, +45, +65 (idle: from +5 on)
        for r in rows(f"c{k}", t - 0.05, "observe", {}, clock(span, idle)):
            c.ingest("luna", r)
        if k == 0:
            assert c.current("luna", t + 1) == 0.0
    assert abs(c.current("luna", T0 + 66) - 61.0) < 0.2, c.state
    for r in rows("c9", T0 + 70, "status", {}, clock(5, 0)):
        c.ingest("luna", r)
    assert c.current("luna", T0 + 71) == 0.0
    assert c.current("luna", T0 + 71 + work.CLOCK_KEEP + 1) is None and c.current("sol", T0) is None
    j = airtime.Journal("astra")
    j.read(rows("a1", T0, "place_ghosts", dict(GHOSTS, dry_run=True), {"dry_run": True}) +
           rows("a2", T0 + 40, "place_ghosts", GHOSTS, {"placed": 14}))
    assert [round(t - T0) for t, _ in j.events] == [40], j.events
    print("2. ClockFeed: idle replies in a row from the first span's start, ended by a busy one; a dry run is no "
          "fresh event: ok")


def team(t, sol_did=None, sol_at=(500, 0), astra_idle=None):
    astra = agent("astra", 0, 0, 20, activity="thinking", active=False)
    astra["idle_s"] = astra_idle
    sol = agent("sol", sol_at[0], sol_at[1], 2, activity="thinking", active=False)
    sol["did"] = sol_did if sol_did and 0 <= t - sol_did["t"] <= work.DID_KEEP else None
    return {"agents": [astra, sol], "alerts": []}


def director(cams=3, log=None):
    d = OneCam(SLOTS[:cams], lambda body: {"ok": True}, log, trio=False, map_every=0, platform_every=0, bow=False)
    d.started = d.onair_since = T0 - 300
    return d


def near_build():
    d = director()
    t = T0 - 120
    while t < T0:
        d.step(team(t, astra_idle=t - (T0 - 200)), t)
        t += 1
    assert d.state[d.onair]["subject"] == "astra"
    did = {"action": "place_ghosts", "t": T0, "position": {"x": 505, "y": 3}, "platform": None}
    first = None
    while t < T0 + 60 and first is None:
        d.step(team(t, did, astra_idle=t - (T0 - 200)), t)
        if d.state[d.onair]["subject"] == "sol":
            first = t
        t += 1
    assert first is not None and first - T0 <= 30, (first, d.cuts[-3:])
    assert "fresh: ghosts placed" in d.cuts[-1][2], d.cuts[-1]
    assert d.state[d.onair].get("follow") == "sol" and not d.state[d.onair].get("did")
    print(f"3. ghosts placed by the character: on air {first - T0:.0f} s after, over a story standing still: ok")


def far_build():
    d = director()
    t = T0 - 120
    while t < T0:
        d.step(team(t), t)
        t += 1
    did = {"action": "place_ghosts", "t": T0, "position": {"x": 700, "y": 20}, "platform": None}
    seen = []
    while t < T0 + 120:
        d.step(team(t, did), t)
        cur = d.state[d.onair]
        seen.append((t - T0, cur["subject"], cur.get("did"), cur.get("follow")))
        if cur.get("did"):
            assert cur["position"] == {"x": 700.0, "y": 20.0}, cur
        t += 1
    spot = [s for s in seen if s[2] == "Sol · ghosts placed"]
    assert spot and spot[0][0] <= 30, seen[:40]
    assert any(c[2].startswith("sol: back to the character") for c in d.cuts), d.cuts[-4:]
    assert not [s for s in seen if s[2] and s[0] > d.cfg["did_hold"] + d.cfg["ready_s"] + 2], "the spot past did_hold"
    print(f"4. ghosts placed 200 tiles from the character: its spot on air {spot[0][0]:.0f} s after, the character "
          f"after did_hold: ok")


def resume():
    def run(astra_moves, sol_did=None):
        d = director()
        t = T0 - 120

        def snap(t):
            s = team(t, sol_did)
            if astra_moves:
                s["agents"][0]["position"] = {"x": (t - T0) * 2.0, "y": 0}
                s["agents"][0].update(activity="acting", active="walk")
            luna = agent("luna", 300 + (t - T0) * 3.0, 300, 1, activity="acting", active="walk")
            s["agents"].append(luna)
            return s
        while t < T0:
            d.step(snap(t), t)
            t += 1
        assert d.state[d.onair]["subject"] == "astra", d.cuts
        seg = {"id": "timed-1", "label": "platform visit: Loom", "zoom": 0.5, "until": T0 + 20,
               "position": {"x": 0, "y": -100}, "surface": "platform-21", "exact_zoom": True}
        while t < T0 + 40:
            d.step(snap(t), t, seg if t < seg["until"] else None)
            t += 1
        return d
    d = run(False)
    after = [c for c in d.cuts if c[0] > T0 + 19]
    assert after and after[0][2].startswith("luna moving (astra still"), after
    d = run(True)
    after = [c for c in d.cuts if c[0] > T0 + 19]
    assert after and after[0][2] == "back to astra", after
    did = {"action": "build", "t": T0 + 10, "position": {"x": 501, "y": 1}, "platform": None}
    d = run(False, did)
    after = [c for c in d.cuts if c[0] > T0 + 19]
    assert after and after[0][2].startswith("sol fresh: building (astra still"), after
    print("5. back from a timed shot: a moving agent over a story standing still, the story when it acts, fresh "
          "news first: ok")


def quiet_yield():
    d = director()
    t = T0 - 120
    while t < T0:
        d.step(team(t), t)
        t += 1
    target = {"agents": [], "subject": "@map", "map": True, "position": {"x": 0, "y": 0}, "surface": "nauvis",
              "zoom": 0.1, "exact_zoom": True, "until": T0 + 60}
    d.quiet_log("map", "Base map", "astra still 120 s", t)
    d.urgent(target, "base map (quiet: astra still 120 s)", {}, t)
    did = {"action": "paste", "t": T0 + 12, "position": {"x": 502, "y": 0}, "platform": None}
    first = None
    while t < T0 + 50 and first is None:
        d.step(team(t, did if t >= did["t"] else None), t)
        if d.state[d.onair]["subject"] == "sol":
            first = t
        t += 1
    assert first is not None and first - did["t"] <= 5, (first, d.cuts[-3:])
    print(f"6. a quiet view gives way to a fresh paste {first - did['t']:.0f} s after it: ok")


def planet_bonus():
    d = director()
    now = T0
    d.surface_air = [(now - 600 + k, "nauvis", 1.0) for k in range(600)]
    astra = dict(agent("astra", 0, 0, 5, activity="thinking", active=False), surface="aquilo")
    sol = dict(agent("sol", 50, 0, 5, activity="acting", active="walk"), surface="vulcanus")
    for k in range(60):
        sol["position"] = {"x": 50 + k, "y": 0}
        d.track([astra, sol], now - 60 + k)
    f = d.surface_factors([astra, sol], {"astra": 5, "sol": 5}, now)
    assert "astra" not in f and f.get("sol", 1) > 1.0, f
    astra["idle_s"] = None
    for k in range(5):
        astra["position"] = {"x": k * 2.0, "y": 0}
        d.track([astra, sol], now + k)
    f = d.surface_factors([astra, sol], {"astra": 5, "sol": 5}, now + 5)
    assert f.get("astra", 1) > 1.0, f
    print("7. the planet bonus: none for a character standing on a short planet, back once it moves: ok")


def interest_and_wiring():
    import model
    ag = model.Agent("sol", {})
    ag.did = {"action": "place_ghosts", "t": T0, "position": None, "platform": None}
    model.did_interest(ag, None, T0)
    i1 = ag.interest
    assert i1 >= model.DID_WEIGHT - 1e-9, i1
    model.did_interest(ag, dict(ag.did), T0 + 1)
    assert ag.interest == i1, "the same build again"
    ag.did = dict(ag.did, t=T0 + 30, action="build")
    model.did_interest(ag, {"t": T0}, T0 + 30)
    assert ag.interest > i1 * 0.5 + model.ACTION_WEIGHT["build"] - 1e-6
    live = open(os.path.join(HERE, "live.py")).read()
    assert 'a["did"] = self.work.did.current(a["name"], now)' in live
    assert 'a["idle_s"] = self.work.clocks.current(a["name"], now)' in live
    src = open(os.path.join(HERE, "model.py")).read()
    assert '"did": ag.did, "idle_s": ag.idle_s' in src
    feed = work.WorkFeed(tempfile.mkdtemp(), [])
    assert isinstance(feed.did, work.DidFeed) and isinstance(feed.clocks, work.ClockFeed)
    print("8. a new build bumps its agent's interest once; did and idle_s reach the director: ok")


def replay():
    log = [
        {"t": T0, "slot": "cam2", "reason": "standby: astra", "target": {"agents": ["astra"]},
         "cmd": {"follow": "astra", "zoom": 0.75}},
        {"t": T0 + 2, "slot": "program", "reason": "cut to cam2: astra 5 beats sol 1"},
        {"t": T0 + 10, "slot": "main", "reason": "platform visit: Loom", "target": {"agents": []},
         "cmd": {"position": {"x": 1, "y": 2}, "zoom": 0.4, "surface": "platform-21"}},
        {"t": T0 + 12, "slot": "program", "reason": "cut to main: platform visit: Loom"},
        {"t": T0 + 30, "slot": "program", "reason": "cut to cam2: back to astra"},
        {"t": T0 + 99, "slot": "program", "reason": "quiet map: Base map (astra still 99 s)"},
        {"t": T0 + 100, "slot": "main", "reason": "base map (quiet: astra still 99 s)", "target": {"agents": []},
         "cmd": {"position": {"x": 0, "y": 0}, "zoom": 0.05, "surface": "nauvis"}},
        {"t": T0 + 101, "slot": "program", "reason": "cut to main: base map (quiet: astra still 99 s)"},
        {"t": T0 + 120, "slot": "program", "reason": "cut to cam2: after the quiet view: astra"},
    ]
    shots = director_replay.timed_shots(log, T0, T0 + 200)
    assert [(s["t"] - T0, s["until"] - T0, s["quiet"]) for s in shots] == [(12, 30, False), (101, 120, True)], shots
    assert shots[0]["position"] == {"x": 1, "y": 2} and shots[0]["surface"] == "platform-21"
    assert director_replay.timed_shots(log, T0, T0 + 200, own_quiet=True) == shots[:1]
    j = airtime.Journal("sol")
    j.read(rows("s0", T0 - 5, "status", {}, {"position": {"x": 0, "y": 0}, "surface": "nauvis"}) +
           rows("s1", T0, "place_ghosts", GHOSTS, {"placed": 14}) +
           rows("s2", T0 + 1, "mine", {"position": {"x": 3, "y": 0}}, {"until_tick": 1}) +
           rows("s3", T0 + 40, "observe", {}, clock(39, 2)) +
           rows("s4", T0 + 60, "sleep", {"seconds": 60}, {}) +
           rows("s5", T0 + 125, "observe", {}, clock(65, 65)))
    w = director_replay.World({"sol": j}, [], vehicle_interest=True)
    got = {k: w.snapshot(T0 + k)["agents"][0] for k in (0.5, 30, 50, 70, 126)}
    assert got[0.5]["did"]["action"] == "place_ghosts" and got[0.5]["active"] in (False, None), got[0.5]
    assert got[30]["active"] == "mine", "a running action over its busy clock"
    assert got[50]["active"] in (False, None) and got[70]["active"] == "sleep"
    assert got[126]["idle_s"] and got[126]["idle_s"] >= 60, got[126]
    i70 = got[70]["interest"]
    assert w.snapshot(T0 + 100)["agents"][0]["interest"] < i70, "a sleep keeps no interest up"
    w.snapshot(T0 + 130)
    w.snapshot(T0 + 131)
    assert w.polled["sol"][0] == T0 + 130, "positions read once a poll (POLL_S)"
    print("9. director_replay: timed shots (quiet ones marked), poll-read positions, instant requests, sleeps, busy "
          "clocks, did and idle_s: ok")


def main():
    did_feed()
    clock_feed()
    near_build()
    far_build()
    resume()
    quiet_yield()
    planet_bonus()
    interest_and_wiring()
    replay()
    print("test_idlecam: ok")


if __name__ == "__main__":
    main()
