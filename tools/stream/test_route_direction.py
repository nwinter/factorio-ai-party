#!/usr/bin/env python3
"""A platform flying a space connection backwards: python3 tools/stream/test_route_direction.py

shift06: Sunward left Vulcanus orbit at ~14:09 and reached Nauvis at 14:14:32. space.lua's location is the space
connection "nauvis->vulcanus N%" (its fixed ends, N from nauvis) whichever way it is flown, so the director said
14:09:30 "leaving Nauvis for Vulcanus" and 14:13:57 "travelling to Vulcanus (5%)", and the arrival at Nauvis was
no moment (Astra called it, the hosts did not).
1. platform_where turns the route round for a platform headed to the connection's `from`.
2. The model orients from the schedule's current stop (pog.py score `to`), the planet it left, the distance moving
   (not while paused), and keeps the way it was going.
3. Arrivals after a trip are called, home included; a first arrival elsewhere stays the orbit moment, once.
4. live.py: a fresh score location stands over a platform detail read from before.
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
from model import Model, platform_where, platform_place  # noqa: E402


def model():
    m = Model({"agents": {"astra": {}}, "space_age": True})
    return m


def read(m, t, at, **kw):
    row = dict({"name": "Sunward", "at": at, "hub": True, "state": "on_the_path" if "->" in at else "waiting_at_station"},
               **kw)
    m.ingest({"agents": [{"name": "astra", "surface": "platform-3", "platform": "Sunward", "position": {"x": 0, "y": 0}}],
              "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [row]}}, t)
    return next(p for p in m.snapshot(t)["space"]["platforms"] if p["name"] == "Sunward")


def alerts(m, prefix):
    return [a for a in m.alerts if a["key"].startswith(prefix)]


def main():
    # 1. platform_where
    w = platform_where({"name": "Sunward", "at": "nauvis->vulcanus 5%", "toward": "nauvis", "speed": 1.2})
    assert w["route"] == {"from": "Vulcanus", "to": "Nauvis", "pct": 95} and w["where"] == "Vulcanus → Nauvis", w
    assert platform_place({"name": "Sunward", "at": "nauvis->vulcanus 5%", "toward": "nauvis"}) == \
        "travelling from Vulcanus to Nauvis"
    w = platform_where({"name": "Starling", "at": "nauvis->vulcanus 42%", "toward": "vulcanus"})
    assert w["route"] == {"from": "Nauvis", "to": "Vulcanus", "pct": 42}, w
    assert platform_where({"name": "Old", "at": "nauvis->vulcanus 42%"})["route"]["to"] == "Vulcanus"  # no hint: as is

    # 2. shift06's trip, no schedule in the rows (a score from before pog.py's `to`): from the planet it left
    t = time.time()
    m = model()
    read(m, t, "vulcanus")                                    # 13:49 loc=vulcanus
    p = read(m, t + 10, "nauvis->vulcanus 99%")               # 14:09:30 departure
    assert p["route"] == {"from": "Vulcanus", "to": "Nauvis", "pct": 1}, p["route"]
    p = read(m, t + 20, "nauvis->vulcanus 60%", paused=True)  # paused: drifting back does not turn it round
    assert p["route"]["to"] == "Nauvis" and p["drifting"], p
    p = read(m, t + 30, "nauvis->vulcanus 5%")                # 14:13:57 "travelling to Vulcanus (5%)" before
    assert p["route"] == {"from": "Vulcanus", "to": "Nauvis", "pct": 95} and p["where"] == "Vulcanus → Nauvis", p
    assert not alerts(m, "arrive:")
    read(m, t + 40, "nauvis")                                 # 14:14:32 loc=nauvis
    a = alerts(m, "arrive:Sunward:nauvis")
    assert len(a) == 1 and a[0]["text"] == "Sunward is back at Nauvis" and a[0]["kind"] == "space", a
    assert a[0]["facts"]["came_from"] == "Vulcanus" and a[0]["facts"]["headline"] == "platform_arrival", a[0]["facts"]
    assert a[0]["facts"]["aboard"] == ["astra"] or a[0]["facts"]["aboard"] == ["Astra"], a[0]["facts"]
    read(m, t + 45, "nauvis")
    assert len(alerts(m, "arrive:")) == 1, "one call per arrival"

    # the schedule's current stop wins (the service started mid-trip: no planet left behind, no distance yet)
    m = model()
    p = read(m, t, "nauvis->vulcanus 70%", to="nauvis")
    assert p["route"] == {"from": "Vulcanus", "to": "Nauvis", "pct": 30}, p["route"]
    # a stop beyond this connection says nothing: the distance shrinking does
    m = model()
    p = read(m, t, "nauvis->vulcanus 70%", to="fulgora")
    assert p["route"]["to"] == "Vulcanus"  # nothing to go on yet: as the game names it
    p = read(m, t + 5, "nauvis->vulcanus 64%", to="fulgora")
    assert p["route"] == {"from": "Vulcanus", "to": "Nauvis", "pct": 36}, p["route"]
    p = read(m, t + 10, "nauvis->vulcanus 64%", to="fulgora")  # no change between reads: the way it was going
    assert p["route"]["to"] == "Nauvis", p["route"]

    # 3. the way out still reads forward; the first arrival at Vulcanus is the orbit moment, not a second call
    m = model()
    read(m, t, "nauvis")
    p = read(m, t + 10, "nauvis->vulcanus 3%", to="vulcanus")
    assert p["route"] == {"from": "Nauvis", "to": "Vulcanus", "pct": 3}, p["route"]
    read(m, t + 20, "in transit", to="vulcanus")  # a score read between detail reads
    read(m, t + 30, "vulcanus", to="vulcanus")
    assert [x["kind"] for x in m.moments] == ["orbit"] and not alerts(m, "arrive:"), (list(m.moments), m.alerts)
    assert alerts(m, "space:orbit:Sunward:vulcanus")
    read(m, t + 40, "nauvis->vulcanus 97%", to="nauvis")
    read(m, t + 50, "nauvis")
    read(m, t + 60, "nauvis->vulcanus 2%", to="vulcanus")
    read(m, t + 70, "vulcanus")  # a second visit: a plain arrival call
    assert [x["text"] for x in alerts(m, "arrive:")] == ["Sunward is back at Nauvis", "Sunward arrives at Vulcanus"]

    # 4. live.py: the score's fresh location over a detail read from before
    from live import LiveSource
    assert LiveSource.fresh_at({"at": "nauvis"}, {"at": "nauvis->vulcanus 3%"}) == {"at": "nauvis"}  # arrived
    assert LiveSource.fresh_at({"at": "in transit"}, {"at": "vulcanus"}) == {"at": "in transit"}  # departed
    assert LiveSource.fresh_at({"at": "in transit"}, {"at": "nauvis->vulcanus 40%"}) == {}  # the route stands
    assert LiveSource.fresh_at({"at": "in transit"}, {}) == {}
    import pog
    assert "s.records[s.current]" in pog.SCORE_LUA and "to = ok and" in pog.SCORE_LUA
    print("route direction: ok (reversed route and progress, schedule, planet left, distance, paused drift, "
          "arrival home, orbit moment once, fresh location)")


if __name__ == "__main__":
    main()
