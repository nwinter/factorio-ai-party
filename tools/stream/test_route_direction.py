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


SCORE_FAKE = r"""
local stats = {get_input_count = function() return 5 end, get_output_count = function() return 0 end}
local any = setmetatable({}, {__index = function() return {} end})
local sunward = {valid = true, name = "Sunward", hub = {valid = true},
  schedule = {current = 2, records = {{station = "vulcanus"}, {station = "nauvis"}}}}
local starling = {valid = true, name = "Starling", hub = {valid = true}, space_location = {name = "vulcanus"}}
game = {tick = 600, ticks_played = 600, tick_paused = false,
  surfaces = {{name = "nauvis", planet = {}, count_entities_filtered = function() return 1 end}},
  forces = {player = {get_item_production_statistics = function() return stats end, get_entity_count = function() return 1 end, technologies = {},
    platforms = {sunward, starling}, rockets_launched = 3}}}
prototypes = {item = any, entity = any}
helpers = {table_to_json = function(t) return t end}
rcon = {print = function(t) OUT = t end}
"""
SCORE_PRINT = r"""
print("tick", OUT.tick)
for _, p in ipairs(OUT.platforms) do print("platform", p.name, p.at, tostring(p.to)) end
"""


def score_read_runs(pog):
    """The score read as it goes over RCON: one line (harness.one_line), run by a Lua interpreter against a fake
    game. shift07 15:10: a `--` comment inside SCORE_LUA (added with `to`) commented out the rest of the line, every
    score read failed ("'end' expected near <eof>"), the stream showed 0h00m with no research or platforms."""
    import shutil, subprocess, tempfile
    from harness import one_line
    lua = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("luajit")
    if not lua:
        print("score read: no lua interpreter, skipped")
        return
    src = SCORE_FAKE + "\n" + one_line(pog.SCORE_LUA) + "\n" + SCORE_PRINT
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(src)
    try:
        r = subprocess.run([lua, f.name], capture_output=True, text=True, timeout=30)
    finally:
        os.unlink(f.name)
    assert r.returncode == 0, "the one-line score read does not run: " + r.stderr
    rows = [line.split("\t") for line in r.stdout.splitlines()]
    assert ["tick", "600"] in rows, rows
    assert ["platform", "Sunward", "in transit", "nauvis"] in rows, rows  # the schedule's current stop
    assert ["platform", "Starling", "vulcanus", "nil"] in rows, rows      # no schedule: no `to`


def observe_platforms_merges(LiveSource):
    """live.py merges the score row, the platform detail read, the camera view and the fresh location. Row and
    detail both carry `at` (and state): dict(row, **detail, ...) raised "multiple values for keyword argument 'at'"
    once the score read worked again (shift07), and every snapshot stayed at tick 0."""
    class H:
        @staticmethod
        def platform_views():
            return {"Sunward": {"surface": "platform-3"}}
    src = LiveSource.__new__(LiveSource)
    src.h, src.next_platforms, src.platform_every, src.platform_detail = H(), 0, 15.0, {}
    src.reader = lambda: {}
    src.read = lambda action, args, **kw: ({"platforms": [{"name": args["platform"], "at": "nauvis->vulcanus 40%",
                                                            "state": "on_the_path", "speed": 1.2}]}, None)
    space = {"platforms": [{"name": "Sunward", "at": "nauvis", "state": "waiting_at_station", "hub": True, "to": "nauvis"},
                           {"name": "Starling", "at": "in transit", "hub": True}]}
    errors = {}
    src.observe_platforms(space, errors)
    assert not errors, errors
    sun, star = space["platforms"]
    assert sun["at"] == "nauvis" and sun["speed"] == 1.2 and sun["view"] == {"surface": "platform-3"} \
        and sun["to"] == "nauvis" and sun["hub"] is True, sun  # arrived: the fresh location over the older detail
    assert star["at"] == "nauvis->vulcanus 40%" and star["state"] == "on_the_path", star  # the route stands


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
    assert [(x["text"], x["kind"]) for x in alerts(m, "arrive:")] == [
        ("Sunward is back at Nauvis", "arrival"), ("Sunward arrives at Vulcanus", "arrival")], \
        "it was seen at Nauvis before it left, and the orbit moment was its first at Vulcanus"

    # a ferry's round trips: the first arrival at each planet is a headline, every later one an ordinary arrival
    import caster
    m = model()
    read(m, t, "vulcanus", to="vulcanus")
    seq = []
    for trip in range(6):
        dest = "nauvis" if trip % 2 == 0 else "vulcanus"
        base = t + 100 * (trip + 1)
        read(m, base, "nauvis->vulcanus 50%", to=dest)
        read(m, base + 50, dest, to=dest)
    for a in alerts(m, "arrive:"):
        seq.append((a["text"], a["kind"], (a.get("facts") or {}).get("headline")))
    assert seq[0] == ("Sunward is back at Nauvis", "space", "platform_arrival"), seq  # its first at Nauvis
    assert all(k == "arrival" and h is None for _, k, h in seq[1:]) and len(seq) == 6, seq  # Vulcanus: seen at start
    assert caster.PRIORITY["arrival"] < caster.PRIORITY["loss"] < caster.PRIORITY["attack"]
    assert "arrival" not in caster.HEADLINE_KINDS
    ev = {"kind": "arrival", "prio": caster.PRIORITY["arrival"], "text": seq[-1][0], "facts": {"platform": "Sunward"}}
    assert caster.clip_rank(ev) == "banter"
    f = caster.facts_for(ev, {})
    assert f["arrival"]["platform"] == "Sunward" and "no big moment" in f["how_to_call_it"] and "headline" not in f

    # the run's first platform at a planet is a headline even for a second platform; a restart mid-trip (rows
    # with the schedule's stop) counts the planet it left as visited, so the trip's end is no false first
    m = model()
    read(m, t, "nauvis->vulcanus 40%", to="nauvis")  # first seen mid-trip home
    read(m, t + 10, "nauvis", to="nauvis")
    assert [a["kind"] for a in alerts(m, "arrive:")] == ["arrival"], "home, where the team is: a ferry, not a first"
    m = model()
    m.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [
        {"name": "Ferry", "at": "nauvis->vulcanus 40%", "to": "vulcanus", "hub": True}]}}, t)
    m.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [
        {"name": "Ferry", "at": "nauvis->vulcanus 60%", "to": "vulcanus", "hub": True}]}}, t + 5)
    m.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [
        {"name": "Ferry", "at": "nauvis", "to": "nauvis", "hub": True}]}}, t + 10)  # (a short trip back)
    assert [a["kind"] for a in alerts(m, "arrive:")] == ["arrival"], "Nauvis: where it left from"

    # restarts: the one-time "X reaches Vulcanus" moment (a headline and a segment) and arrival headlines are not
    # taken again for a ferry's next arrival. space-memory.json in the run folder keeps where each platform has been.
    import tempfile
    path = os.path.join(tempfile.mkdtemp(), "space-memory.json")
    first = model()
    first.set_space_memory(path)  # no file yet
    read(first, t, "nauvis", to="vulcanus")
    read(first, t + 10, "nauvis->vulcanus 50%", to="vulcanus")
    read(first, t + 20, "vulcanus", to="vulcanus")
    assert [x["kind"] for x in first.moments] == ["orbit"], "its first at Vulcanus: the moment"
    read(first, t + 30, "nauvis->vulcanus 50%", to="nauvis")
    import json
    mem = json.load(open(path))
    assert mem["visited"]["Sunward"] == ["nauvis", "vulcanus"] and "vulcanus" in mem["reached"], mem
    again = model()  # the service restarts with Sunward on its way home, then flies back to Vulcanus
    again.set_space_memory(path)
    read(again, t + 40, "nauvis->vulcanus 40%", to="nauvis")
    read(again, t + 50, "nauvis", to="nauvis")
    read(again, t + 60, "nauvis->vulcanus 50%", to="vulcanus")
    read(again, t + 70, "vulcanus", to="vulcanus")
    assert not again.moments, list(again.moments)
    assert [a["kind"] for a in alerts(again, "arrive:")] == ["arrival", "arrival"], alerts(again, "arrive:")
    assert not alerts(again, "space:orbit"), "no second 'Sunward reaches Vulcanus'"
    # (d23 batch130 CM1) a new shift (its own file not written yet) knows where each platform has been from the
    # shifts before it: d23's shift changes aired about 20 "X reaches Fulgora" firsts each for ferries
    nxt = model()
    nxt.set_space_memory(os.path.join(tempfile.mkdtemp(), "space-memory.json"), earlier=(path,))
    read(nxt, t + 75, "nauvis", to="vulcanus")  # docked when the shift's service starts
    read(nxt, t + 80, "nauvis->vulcanus 50%", to="vulcanus")
    read(nxt, t + 90, "vulcanus", to="vulcanus")
    assert not nxt.moments and [a["kind"] for a in alerts(nxt, "arrive:")] == ["arrival"], (list(nxt.moments), nxt.alerts)

    # no memory (the first start with it, or a platform made while the service was down), first seen mid-trip:
    # headed for a planet the team has reached, a ferry; headed somewhere new, still the moment
    cold = model()
    read(cold, t, "nauvis->vulcanus 60%", to="vulcanus")
    read(cold, t + 10, "vulcanus", to="vulcanus")
    assert not cold.moments and [a["kind"] for a in alerts(cold, "arrive:")] == ["arrival"], list(cold.moments)
    cold = model()
    cold.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [
        {"name": "Scout", "at": "nauvis->fulgora 30%", "to": "fulgora", "hub": True}]}}, t)
    cold.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "vulcanus"], "platforms": [
        {"name": "Scout", "at": "fulgora", "to": "fulgora", "hub": True}]}}, t + 10)
    assert [x["kind"] for x in cold.moments] == ["orbit"] and cold.moments[0]["title"] == "Scout reaches Fulgora"

    # (d23 batch131 CN1, Astra #2088) turned back mid-connection: the schedule's stop beyond the connection (Aquilo on
    # edge->shattered-planet), the distance shrinking: headed back to the edge, said as a turn back
    tb = model()
    tb.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "aquilo"], "platforms": [
        {"name": "Asterion", "at": "solar-system-edge", "to": "shattered-planet", "hub": True}]}}, t)
    for i, (at, to) in enumerate((("solar-system-edge->shattered-planet 1%", "shattered-planet"),
                                  ("solar-system-edge->shattered-planet 2%", "shattered-planet"),
                                  ("solar-system-edge->shattered-planet 2%", "aquilo"),
                                  ("solar-system-edge->shattered-planet 1%", "aquilo"))):
        tb.ingest({"agents": [], "space": {"rockets": 9, "planets": ["nauvis", "aquilo"], "platforms": [
            {"name": "Asterion", "at": at, "to": to, "hub": True, "state": "on_the_path"}]}}, t + 5 * (i + 1))
        p = next(x for x in tb.snapshot(t)["space"]["platforms"] if x["name"] == "Asterion")
        if i == 1:
            assert p["route"]["to"] == "Shattered Planet" and not p["route"].get("turned_back"), p["route"]
    assert p["route"] == {"from": "Shattered Planet", "to": "Solar system edge", "pct": 99, "turned_back": True}, p["route"]
    assert p["where"] == "back to Solar system edge (turned back)", p["where"]
    assert platform_place({"name": "A", "at": "solar-system-edge->shattered-planet 1%", "toward": "solar-system-edge",
                           "turned_back": True}) == "turned back, travelling to Solar system edge"

    # 4. live.py: the score's fresh location over a detail read from before
    from live import LiveSource
    assert LiveSource.fresh_at({"at": "nauvis"}, {"at": "nauvis->vulcanus 3%"}) == {"at": "nauvis"}  # arrived
    assert LiveSource.fresh_at({"at": "in transit"}, {"at": "vulcanus"}) == {"at": "in transit"}  # departed
    assert LiveSource.fresh_at({"at": "in transit"}, {"at": "nauvis->vulcanus 40%"}) == {}  # the route stands
    assert LiveSource.fresh_at({"at": "in transit"}, {}) == {}
    import pog
    assert "s.records[s.current]" in pog.SCORE_LUA and "to = ok and" in pog.SCORE_LUA
    score_read_runs(pog)
    observe_platforms_merges(LiveSource)
    print("route direction: ok (reversed route and progress, schedule, planet left, distance, paused drift, "
          "arrival home, orbit moment once, fresh location)")


if __name__ == "__main__":
    main()
