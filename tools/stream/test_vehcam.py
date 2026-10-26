#!/usr/bin/env python3
"""A remote spidertron shown where it is (d26 batch232 VC, viewer Aurora site:5020: "The site selected Opus at 09:26:50
PDT during recon, but spider 27069154 wasn't shown. Could batch224 check actual vehicle framing, noncombat motion and
the Astra/Opus handoff?"): python3 tools/stream/test_vehcam.py

shift80 09:26:50-09:27:46: the on-air view glided at 9-10 tiles/s (each step d/1.5 from where it was sent last) behind a
spider walking 13 tiles/s, led at 45 km/h from Opus's two replies; it fell about 130 tiles behind on the way back.

1. work.VehicleFeed: a go_to reply with no unit_number (Astra 09:23:26) takes the request's vehicle; the unit belongs to
   the agent who called it last (Opus 09:26:23); the service's live reads (harness VEHICLES_LUA) give its position,
   speed (km/h) and next target, `seen_t` the agent's own last call; a unit not read back drops its live row.
2. harness.Harness.vehicles: one raw Lua read for the units, rows by unit; live.py reads them every poll.
3. Walking out and back (live reads every 3 s): the on-air view keeps the spider in frame all the way, at 1 and 3
   cameras; each step aims vehicle_ahead s on and glides at no less than vehicle_glide x its speed.
4. The hand-off: Astra's spider shot on air; Opus calls the same spider: Astra's shot goes back to her character and
   Opus's goes to the spider.
5. A spider standing with live reads: shown while the agent's call is within vehicle_stale, then the character (the
   live read alone does not hold the shot).
6. The barrage frame's glide is a speed in tiles/s (cameras.lua), at least 2.
7. director_replay.py: the vehicle path model (any agent's replies; never past the next reply on its route) and
   vehicle_framing on a log.
8. (cp2, shift81 10:20-10:27: Opus never aired) model.py: a new target for an agent's remote vehicle bumps its interest
   VEHICLE_WEIGHT, a read of the same route does not; a walking vehicle keeps a little alive.
9. (cp2) The planets' air time is kept in runs/RUN/surface-air.json and read back at a restart (and from the run it
   resumed from), so the balance does not start every planet at 0%; director_replay --surface-from seeds it.
"""
import os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, SLOTS  # noqa: E402
from onecam import OneCam  # noqa: E402
import airtime, director_replay, harness, work  # noqa: E402

T0 = airtime.iso_t("2026-10-26T16:26:23Z")
UNIT = 27069154


def at(t):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def call(feed, who, rid, t, args, result):
    feed.ingest(who, {"at": at(t), "event": "request", "request": {"id": rid, "action": "vehicle", "args": args}})
    feed.ingest(who, {"at": at(t + 0.05), "event": "response", "response": {"id": rid, "ok": True, "result": result}})


def feed_rows():
    feed = work.VehicleFeed()
    # Astra 09:23:26: go_to with retreat and targeting; the reply names no unit_number
    call(feed, "astra", "a1", T0 - 177, {"remote": True, "vehicle": UNIT, "go_to": [{"x": -410, "y": -400}], "retreat": {}},
         {"spidertron": "spidertron", "position": {"x": -159.4, "y": -540.5}, "go_to": [{"x": -410, "y": -400}],
          "route": [{"x": -410, "y": -400}]})
    assert feed.current("astra", T0 - 170)["unit_number"] == UNIT
    assert feed.units(T0 - 170) == [UNIT]
    # Opus 09:26:23 takes it
    call(feed, "opus", "o1", T0, {"remote": True, "vehicle": UNIT, "go_to": {"x": -700, "y": -560}},
         {"spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -329.5, "y": -450.3},
          "go_to": {"x": -700, "y": -560}, "route": [{"x": -700, "y": -560}]})
    assert feed.current("astra", T0 + 1) is None, "handed on to Opus"
    v = feed.current("opus", T0 + 1)
    assert v["unit_number"] == UNIT and v["seen_t"] == v["t"] and not v.get("live"), v
    # the service's read 3 s on: walking at 0.0611 tiles a tick (13.2 tiles/s = 47.5 km/h)
    feed.apply_live({UNIT: {"unit": UNIT, "name": "spidertron", "surface": "nauvis", "x": -369.0, "y": -462.0,
                            "speed": 0.2199, "dest": {"x": -700, "y": -560}, "dests": 1, "health": 1}}, T0 + 3)
    v = feed.current("opus", T0 + 3.5)
    assert v["live"] and v["position"] == {"x": -369.0, "y": -462.0} and abs(v["speed"] - 47.5) < 0.1, v
    assert v["t"] == T0 + 3 and abs(v["seen_t"] - (T0 + 0.05)) < 1e-6 and v["target"] == {"x": -700, "y": -560}
    assert v["cmd_target"] == {"x": -700, "y": -560}
    # a stale live read (LIVE_KEEP) falls back to the reply; a unit not read back drops its live row
    assert not feed.current("opus", T0 + 3 + feed.LIVE_KEEP + 1).get("live")
    feed.apply_live({}, T0 + 6)
    assert not feed.current("opus", T0 + 6.5).get("live")
    print("1. VehicleFeed: the unit from the request, the hand-off, live reads merged: ok")


def harness_read():
    h = harness.Harness.__new__(harness.Harness)
    seen = []
    h.lua = lambda lua: seen.append(lua) or {"vehicles": [{"unit": UNIT, "name": "spidertron", "surface": "nauvis",
                                                           "x": -158.5, "y": -540.7, "speed": 0, "health": 1}]}
    rows = h.vehicles([UNIT, "x", 5])
    assert rows == {UNIT: {"unit": UNIT, "name": "spidertron", "surface": "nauvis", "x": -158.5, "y": -540.7,
                           "speed": 0, "health": 1}}, rows
    assert "{%d,5}" % UNIT in seen[0] and "get_entity_by_unit_number" in seen[0]
    assert h.vehicles([]) == {} and len(seen) == 1, "no units: no read"
    h.lua = lambda lua: {"vehicles": {}}  # (table_to_json writes an empty table as {})
    assert h.vehicles([UNIT]) == {}
    assert " -- " not in harness.VEHICLES_LUA and "--" not in harness.one_line(harness.VEHICLES_LUA)
    src = open(os.path.join(HERE, "live.py")).read()
    assert "self.work.vehicles.apply_live(self.h.vehicles(units), now)" in src
    print("2. the live read: one raw Lua read by unit number, read every poll: ok")


class Spider:
    """A spidertron walking legs at 13.2 tiles/s (out to (-700,-560), back to (-160,-540)), standing between."""
    V = 47.5 / 3.6

    def __init__(self, t0):
        self.legs = [(t0, (-329.5, -450.3), (-700.0, -560.0)), (t0 + 40, (-700.0, -560.0), (-160.0, -540.0))]

    def at(self, t):
        for i, (s, a, b) in enumerate(self.legs):
            nxt = self.legs[i + 1][0] if i + 1 < len(self.legs) else 1e18
            if s <= t < nxt:
                d = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
                go = min(d, self.V * (t - s))
                p = {"x": a[0] + (b[0] - a[0]) * go / d, "y": a[1] + (b[1] - a[1]) * go / d}
                return p, (self.V if go < d else 0.0), ({"x": b[0], "y": b[1]} if go < d else None)
        return {"x": -329.5, "y": -450.3}, 0.0, None


def out_and_back(cams):
    log = tempfile.mktemp(suffix=".jsonl")
    d = OneCam(SLOTS[:cams], lambda body: {"ok": True}, log, trio=False, map_every=0, platform_every=0)
    d.started = d.onair_since = T0 - 10
    feed = work.VehicleFeed()
    spider = Spider(T0)
    call(feed, "opus", "o1", T0, {"remote": True, "vehicle": UNIT, "go_to": {"x": -700, "y": -560}},
         {"spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -329.5, "y": -450.3},
          "go_to": {"x": -700, "y": -560}, "route": [{"x": -700, "y": -560}]})
    t, last_read = T0 + 1, -1e9
    while t < T0 + 90:
        if abs(t - (T0 + 40)) < 0.5:  # Opus sends it back
            call(feed, "opus", "o2", t, {"remote": True, "vehicle": UNIT, "go_to": {"x": -160, "y": -540}},
                 {"spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -700.0, "y": -560.0},
                  "go_to": {"x": -160, "y": -540}, "route": [{"x": -160, "y": -540}]})
        if t - last_read >= 3.0:  # the service's poll
            last_read = t
            p, v, q = spider.at(t)
            feed.apply_live({UNIT: {"unit": UNIT, "name": "spidertron", "surface": "nauvis", "x": p["x"], "y": p["y"],
                                    "speed": v / 60.0, "dest": q}}, t)
        opus = agent("opus", -158, -540, 6, activity="thinking", active=False)
        opus["remote_vehicle"] = feed.current("opus", t)
        d.step({"agents": [opus, agent("sol", 300, 0, 1)], "alerts": []}, t)
        t += 1.0
    rows = list(airtime.rows_of(log))
    os.remove(log)
    framing = director_replay.vehicle_framing(rows, lambda who, tt: spider.at(tt)[0] if who == "opus" else None,
                                              T0 + 3, T0 + 85)
    on, inside = framing["on_air_s"], framing["in_frame_s"]
    assert on >= 70 and inside >= on - 2, (cams, framing)
    glides = [r["cmd"]["speed"] for r in rows if r.get("reason") == "reframe" and (r.get("cmd") or {}).get("speed")]
    assert glides and min(g for g in glides) >= 1.0 and max(glides) >= d.cfg["vehicle_glide"] * spider.V - 0.01, glides
    print(f"3. a spider walking out and back at {cams} camera(s): {inside:.0f} of {on:.0f} s on air in frame: ok")


def handoff():
    d = OneCam(SLOTS[:3], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d.started = d.onair_since = T0 - 200
    feed = work.VehicleFeed()
    call(feed, "astra", "a1", T0 - 177, {"remote": True, "vehicle": UNIT, "go_to": [{"x": -410, "y": -400}]},
         {"spidertron": "spidertron", "position": {"x": -159.4, "y": -540.5}, "go_to": [{"x": -410, "y": -400}],
          "route": [{"x": -410, "y": -400}]})

    def team(t):  # (live at 09:26:50: "opus 8.401 beats astra 0.563")
        astra = agent("astra", 0, 300, 6 if t < T0 else 0.5, activity="thinking", active=False)
        opus = agent("opus", -158, -540, 1 if t < T0 else 8, activity="thinking", active=False)
        astra["remote_vehicle"], opus["remote_vehicle"] = feed.current("astra", t), feed.current("opus", t)
        return {"agents": [astra, opus], "alerts": []}
    for k in range(6):
        t = T0 - 175 + k
        feed.apply_live({UNIT: {"unit": UNIT, "x": -159.4 - 13 * k, "y": -540.5 + 7 * k, "speed": 0.22,
                                "dest": {"x": -410, "y": -400}}}, t)
        d.step(team(t), t)
    cur = d.state[d.onair]
    assert cur["subject"] == "astra" and cur.get("vehicle") == "Astra · spidertron by remote view", cur
    call(feed, "opus", "o1", T0, {"remote": True, "vehicle": UNIT, "go_to": {"x": -700, "y": -560}},
         {"spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -329.5, "y": -450.3},
          "go_to": {"x": -700, "y": -560}, "route": [{"x": -700, "y": -560}]})
    assert feed.current("astra", T0 + 1) is None
    labels = set()
    for k in range(1, 60):
        t = T0 + k
        feed.apply_live({UNIT: {"unit": UNIT, "x": -329.5 - 12 * k, "y": -450.3 - 3 * k, "speed": 0.22,
                                "dest": {"x": -700, "y": -560}}}, t)
        d.step(team(t), t)
        labels.add(d.state[d.onair].get("vehicle"))
    assert "Opus · spidertron by remote view" in labels, labels
    assert any(c[2].startswith("astra: back to the character") for c in d.cuts) or \
        d.state[d.onair].get("vehicle") != "Astra · spidertron by remote view", d.cuts[-4:]
    print("4. the hand-off: Astra's spider shot ends, Opus's spider goes on air: ok")


def standing():
    d = OneCam(SLOTS[:1], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d.started = d.onair_since = T0 - 10
    feed = work.VehicleFeed()
    call(feed, "opus", "o1", T0, {"remote": True, "vehicle": UNIT},
         {"spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -700.0, "y": -560.0}, "speed": 0,
          "route": []})
    opus = agent("opus", -158, -540, 6, activity="thinking", active=False)
    stale = d.cfg["vehicle_stale"]
    for k in range(0, int(stale) + 30):
        t = T0 + k
        feed.apply_live({UNIT: {"unit": UNIT, "x": -700.0, "y": -560.0, "speed": 0}}, t)
        opus["remote_vehicle"] = feed.current("opus", t)
        spot = d.vehicle_spot(opus, t)
        assert (spot is not None) == (k <= stale), (k, spot)
        assert d.vehicle_activity(opus, t) is None
    print("5. a spider standing: shown within vehicle_stale of the call, then not, live reads or not: ok")


def barrage_glide():
    import json
    src = open(os.path.join(HERE, "onecam.py")).read()
    assert "glide=round(max(2.0, d / 1.5), 2))" in src
    print("6. the barrage frame glides at d/1.5 tiles/s, at least 2: ok")
    return json


def replay_model():
    j = airtime.Journal("astra")
    rows = []
    for rid, who_t, args, res in (
            ("a1", T0 - 177, {"remote": True, "vehicle": UNIT, "go_to": [{"x": -410, "y": -400}]},
             {"spidertron": "spidertron", "position": {"x": -159.4, "y": -540.5}, "route": [{"x": -410, "y": -400}]}),):
        rows.append({"at": at(who_t), "event": "request", "request": {"id": rid, "action": "vehicle", "args": args}})
        rows.append({"at": at(who_t + 0.05), "event": "response", "response": {"id": rid, "ok": True, "result": res}})
    j.read(rows)
    o = airtime.Journal("opus")
    o.read([{"at": at(T0), "event": "request", "request": {"id": "o1", "action": "vehicle",
                                                          "args": {"remote": True, "vehicle": UNIT, "go_to": {"x": -700, "y": -560}}}},
            {"at": at(T0 + 0.05), "event": "response", "response": {"id": "o1", "ok": True, "result": {
                "spidertron": "spidertron", "unit_number": UNIT, "position": {"x": -329.5, "y": -450.3},
                "go_to": {"x": -700, "y": -560}}}}])
    paths = director_replay.vehicle_paths({"astra": j, "opus": o})
    ev = paths[UNIT]
    assert len(ev) == 2, ev
    p, v, _ = director_replay.path_at(ev, T0 - 177 + 5)
    assert v > 13 and p["x"] < -159.4
    p, v, _ = director_replay.path_at(ev, T0 - 60)  # past where Opus's reply found it: standing there
    assert v == 0.0 and abs(p["x"] + 329.5) < 6 and abs(p["y"] + 450.3) < 6, p  # (its route's point nearest it)
    p, v, q = director_replay.path_at(ev, T0 + 10)
    assert v > 13 and q == {"x": -700, "y": -560}
    where = director_replay.vehicle_where({"astra": j, "opus": o}, paths)
    assert where("astra", T0 - 100) and where("opus", T0 - 100) is None and where("opus", T0 + 1)
    # vehicle_framing: one client, a vehicle shot jumped onto the spider and not moved: in frame while it is near
    log = [{"t": T0, "slot": "main", "reason": "standby: vehicle: Opus · spidertron by remote view",
            "target": {"agents": ["opus"], "zoom": 0.75, "vehicle": "Opus · spidertron by remote view"},
            "cmd": {"position": {"x": -329.5, "y": -450.3}, "zoom": 1.12, "smooth": False}},
           {"t": T0, "slot": "program", "reason": "cut to main: vehicle"}]
    f = director_replay.vehicle_framing(log, where, T0, T0 + 6)
    assert f["on_air_s"] == 6.0 and 1.5 <= f["in_frame_s"] <= 2.5, f  # 26.8 tiles of half frame at 13.2 tiles/s
    print("7. director_replay: the vehicle path model and vehicle_framing: ok")


def interest():
    import model
    ag = model.Agent("opus", {})
    ag.interest, ag.interest_t = 1.0, T0
    row = {"vehicle": "spidertron", "unit_number": UNIT, "position": {"x": -158.5, "y": -540.7}, "speed": None,
           "target": {"x": -600, "y": -560}, "t": T0}
    m = model.Model.__new__(model.Model)
    was, ag.remote_vehicle = ag.remote_vehicle, row
    model.vehicle_interest(ag, was, T0)
    assert abs(ag.interest - (1.0 + model.VEHICLE_WEIGHT)) < 1e-6, ag.interest
    # a read of the same route 16 s on (walking): no new bump, a little kept alive
    read = dict(row, position={"x": -329.5, "y": -548.5}, speed=46, t=T0 + 16)
    before = ag.interest * 0.5 ** (16 / model.HALF_LIFE)
    was, ag.remote_vehicle = ag.remote_vehicle, read
    model.vehicle_interest(ag, was, T0 + 16)
    assert abs(ag.interest - (before + 0.04 * model.VEHICLE_WEIGHT)) < 1e-6, (ag.interest, before)
    # a live read's next waypoint is not a new target (cmd_target stays)
    live = dict(read, target={"x": -500, "y": -555}, cmd_target={"x": -600, "y": -560}, speed=0, t=T0 + 17)
    was, ag.remote_vehicle = ag.remote_vehicle, live
    v0 = ag.interest * 0.5 ** (1 / model.HALF_LIFE)
    model.vehicle_interest(ag, was, T0 + 17)
    ag.decay(T0 + 17)
    assert abs(ag.interest - v0) < 1e-6
    # the next leg: a new target
    nxt = dict(row, target={"x": -850, "y": -560}, t=T0 + 46)
    was, ag.remote_vehicle = ag.remote_vehicle, nxt
    v0 = ag.interest * 0.5 ** (29 / model.HALF_LIFE)
    model.vehicle_interest(ag, was, T0 + 46)
    assert abs(ag.interest - (v0 + model.VEHICLE_WEIGHT)) < 1e-6
    assert m is not None and "vehicle_interest(ag, was_vehicle, now)" in open(os.path.join(HERE, "model.py")).read()
    print("8. a new target for the remote vehicle bumps its agent's interest; a read of the same route does not: ok")


def surface_air():
    import json, shutil, time
    root = tempfile.mkdtemp()
    prev, run = os.path.join(root, "shift80"), os.path.join(root, "shift81")
    os.makedirs(prev)
    os.makedirs(run)
    open(os.path.join(run, "resumed-from"), "w").write("shift80\n")
    now = time.time()
    d = OneCam(SLOTS[:1], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d.set_surface_memory(os.path.join(prev, "surface-seen.json"))
    d.surface_air = [(now - 600 + k, "aquilo" if k % 3 else "nauvis", 1.0) for k in range(300)]
    d.save_surface_air(now)
    saved = json.load(open(os.path.join(prev, "surface-air.json")))["air"]
    assert len(saved) == 300 and saved[1][1] == "aquilo"
    d.save_surface_air(now + 10)  # (at most every AIR_SAVE_S)
    # the next shift's service: read back through resumed-from, the old part of the window left out
    json.dump({"air": saved + [[now - 4000, "fulgora", 1.0]]}, open(os.path.join(prev, "surface-air.json"), "w"))
    e = OneCam(SLOTS[:1], lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    e.set_surface_memory(os.path.join(run, "surface-seen.json"))
    assert len(e.surface_air) == 300 and all(s != "fulgora" for _, s, _ in e.surface_air), len(e.surface_air)
    share = e.surface_shares(now)
    assert abs(share["aquilo"] - 2 / 3) < 0.01, share
    shutil.rmtree(root, True)
    # the replay's seed: what the program showed, from a log
    log = [{"t": 100.0, "slot": "main", "reason": "standby: astra", "target": {"agents": ["astra"]}, "cmd": {"follow": "astra"},
            "result": {"camera": {"surface": "aquilo"}}},
           {"t": 100.0, "slot": "program", "reason": "cut to main: initial"},
           {"t": 160.0, "slot": "cam2", "reason": "standby: opus", "cmd": {"follow": "opus"}, "result": {"camera": {"surface": "nauvis"}}},
           {"t": 160.0, "slot": "program", "reason": "cut to cam2: x"}]
    air = director_replay.surface_air_of(log, 100.0, 200.0)
    assert sum(1 for a in air if a[1] == "aquilo") == 60 and sum(1 for a in air if a[1] == "nauvis") == 40, air[:3]
    print("9. the planets' air time kept across a restart (and the run it resumed from); the replay's seed: ok")


def main():
    feed_rows()
    harness_read()
    out_and_back(3)
    out_and_back(1)
    handoff()
    standing()
    barrage_glide()
    replay_model()
    interest()
    surface_air()
    print("vehcam: ok (a remote spidertron framed where it is, out and back, at 1 and 3 cameras; the hand-off between "
          "agents; the live read)")


if __name__ == "__main__":
    main()
