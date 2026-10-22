#!/usr/bin/env python3
"""Every platform's route and each stopped platform's time at its planet (d22 batch75 AK2, viewer Foobator, site:4034:
"the ship overview only has a progress bar for the first 2 that are in transit? can in transit be listed first and the
rest have their planetary waiting time displayed?"): python3 tools/stream/test_shipwait.py

Why only some had a bar (live site d22 06:2x, 18 platforms): live.py read the platform detail (state, "from->to N%",
speed) for the first 4 platforms only; the others had the score's location, "in transit" with no route. Here:
1. harness.PLATFORM_LUA (the views read, every platform in one call every 15 s) returns where: {state, paused, speed, at}.
2. live.py merges it under the detail read for every platform, so a 6th platform in flight has its route.
3. The model keeps the game tick of each platform's first read at a planet (stop {at, tick, seen}); the Space rows
   carry waited_s (game seconds there) and waited_more (there when first read: at least that long); flying clears it;
   space-memory.json keeps the stops across a restart, and a run without its own file takes them from the run it
   resumed from.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
from model import Model  # noqa: E402
import harness  # noqa: E402
import serve  # noqa: E402


def rows(m, t):
    return {p["name"]: p for p in m.space_snapshot({}, t)["platforms"]}


def read(m, t, tick, plats):
    m.ingest({"tick": tick, "agents": [], "space": {"rockets": 9, "planets": ["nauvis", "gleba"], "platforms": plats}}, t)


def main():
    # 1. the views read names each platform's place
    lua = harness.PLATFORM_LUA
    assert "where = w}" in lua and "pl.space_connection" in lua and "pl.distance" in lua and "--" not in lua, "views read"

    # 2. live.py: the 6th platform's route from the views read; the detail read still wins for the first 4
    from live import LiveSource
    names = [f"P{i}" for i in range(6)]

    class H:
        @staticmethod
        def platform_views():
            return {n: {"surface": f"platform-{i}", "where": {"state": "on_the_path", "at": "nauvis->gleba 30%", "speed": 1.0, "paused": False}}
                    for i, n in enumerate(names)}
    src = LiveSource.__new__(LiveSource)
    src.h, src.next_platforms, src.platform_every, src.platform_detail = H(), 0, 15.0, {}
    src.reader = lambda: {}
    src.read = lambda action, args, **kw: ({"platforms": [{"name": args["platform"], "at": "nauvis->gleba 31%", "state": "on_the_path", "speed": 1.1}]}, None)
    space = {"platforms": [{"name": n, "at": "in transit", "hub": True} for n in names]}
    errors = {}
    src.observe_platforms(space, errors)
    assert not errors, errors
    got = [(p["name"], p["at"], p["speed"]) for p in space["platforms"]]
    assert got[:4] == [(n, "nauvis->gleba 31%", 1.1) for n in names[:4]], got  # the detail read
    assert got[4:] == [(n, "nauvis->gleba 30%", 1.0) for n in names[4:]], got  # the views read (none before AK2)
    arrived = dict(space["platforms"][5])
    space = {"platforms": [{"name": "P5", "at": "gleba", "hub": True}]}
    src.next_platforms = 1e18  # between reads: the score's fresh planet over the views read's route
    src.observe_platforms(space, errors)
    assert space["platforms"][0]["at"] == "gleba", space
    assert arrived["view"]["surface"] == "platform-5"

    # 3. the model: waiting time at a planet in game seconds
    root = tempfile.mkdtemp()
    for run, up in (("shift56", None), ("shift57", "shift56")):
        os.makedirs(os.path.join(root, run))
        if up:
            open(os.path.join(root, run, "resumed-from"), "w").write(up + "\n")
    m = Model({"agents": {}, "space_age": True})
    m.set_space_memory(*serve.map_memory_paths(os.path.join(root, "shift56"), name="space-memory.json"))
    t, k = 1792660000.0, 46_000_000
    read(m, t, k, [{"name": "Ferry", "at": "nauvis->gleba 90%", "to": "gleba", "hub": True},
                   {"name": "Dock", "at": "nauvis", "hub": True, "state": "no_schedule"}])
    r = rows(m, t)
    assert "waited_s" not in r["Ferry"] and r["Ferry"]["route"]["pct"] == 90, r["Ferry"]
    assert r["Dock"]["waited_s"] == 0 and r["Dock"]["waited_more"], r["Dock"]  # there when first read
    read(m, t + 15, k + 900, [{"name": "Ferry", "at": "gleba", "to": "gleba", "hub": True},
                              {"name": "Dock", "at": "nauvis", "hub": True, "state": "no_schedule"}])
    read(m, t + 615, k + 900 + 36000, [{"name": "Ferry", "at": "gleba", "to": "gleba", "hub": True, "state": "waiting_at_station"},
                                       {"name": "Dock", "at": "nauvis", "hub": True, "state": "no_schedule"}])
    r = rows(m, t + 615)
    assert r["Ferry"]["waited_s"] == 600 and "waited_more" not in r["Ferry"], r["Ferry"]  # its arrival seen: 10 min
    assert r["Dock"]["waited_s"] == 615 and r["Dock"]["waited_more"], r["Dock"]
    mem = json.load(open(os.path.join(root, "shift56", "space-memory.json")))
    assert mem["stops"]["Ferry"] == {"at": "gleba", "tick": k + 900, "seen": True}, mem["stops"]

    # a restart (the next shift: no file of its own) keeps the arrival; the next departure clears it
    m2 = Model({"agents": {}, "space_age": True})
    m2.set_space_memory(*serve.map_memory_paths(os.path.join(root, "shift57"), name="space-memory.json"))
    read(m2, t + 700, k + 900 + 42000, [{"name": "Ferry", "at": "gleba", "to": "gleba", "hub": True},
                                        {"name": "Dock", "at": "nauvis", "hub": True}])
    r = rows(m2, t + 700)
    assert r["Ferry"]["waited_s"] == 700 and "waited_more" not in r["Ferry"], r["Ferry"]
    assert r["Dock"]["waited_s"] == 715 and r["Dock"]["waited_more"], r["Dock"]
    read(m2, t + 715, k + 900 + 42900, [{"name": "Ferry", "at": "gleba->nauvis 2%", "to": "nauvis", "hub": True}])
    r = rows(m2, t + 715)
    assert "waited_s" not in r["Ferry"] and r["Ferry"]["route"], r["Ferry"]
    read(m2, t + 730, k + 900 + 43800, [{"name": "Ferry", "at": "in transit", "to": "nauvis", "hub": True}])
    assert "stop" not in m2.platform_course["Ferry"]
    print("ship wait: ok (every platform's route from the views read; game time at a planet, at least when not seen "
          "arriving; kept across a restart and a shift change)")


if __name__ == "__main__":
    main()
