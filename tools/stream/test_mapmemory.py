#!/usr/bin/env python3
"""Each planet's last map and networks map across a stream service restart (d22 batch75 AK1, viewer Aurora, site:4011:
"Planet buttons and network layers disappear between refreshes"): python3 tools/stream/test_mapmemory.py

At shift57's start (d22 06:21) the restarted service had Aquilo's map alone for the first pushes and read the others a
planet a minute, so the site listed fewer planets. The model keeps both kinds of map in runs/RUN/map-memory.json (at most
once a minute), and a service started in a run that resumed another (serve.map_memory_paths: resumed-from, followed back)
starts with the newest file along the chain; a read replaces a kept map. A planet the census's list leaves out goes after
PLANET_GONE_S (one pass may list fewer).
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
from model import Model  # noqa: E402
import serve  # noqa: E402


def grid(surface, tick):
    return {"surface": surface, "tick": tick, "cell": 8, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AS"], "buildings": 2}


def main():
    root = tempfile.mkdtemp()
    for run, up in (("shift55", None), ("shift56", "shift55"), ("shift57", "shift56")):
        os.makedirs(os.path.join(root, run))
        if up:
            open(os.path.join(root, run, "resumed-from"), "w").write(up + "\n")
    path, earlier = serve.map_memory_paths(os.path.join(root, "shift57"))
    assert path == os.path.join(root, "shift57", "map-memory.json"), path
    assert earlier == [os.path.join(root, "shift56", "map-memory.json"), os.path.join(root, "shift55", "map-memory.json")], earlier

    # shift56's service reads three planets and two networks maps, and saves them
    t = 1792660000.0
    a = Model({"agents": {}})
    assert a.set_map_memory(*serve.map_memory_paths(os.path.join(root, "shift56"))) is None  # nothing to read yet
    for i, n in enumerate(("aquilo", "gleba", "vulcanus")):
        a.ingest({"planet_map": grid(n, 1000 + i)}, t + 60 * i)
    a.ingest({"net_map": {"surface": "gleba", "tick": 1500, "electric": {}}, "net_map_listed": ["gleba", "nauvis"]}, t + 200)
    a.ingest({"net_map": {"surface": "nauvis", "tick": 1600, "electric": {}}}, t + 210)  # within a minute: not saved yet
    mem = json.load(open(os.path.join(root, "shift56", "map-memory.json")))
    assert sorted(mem["planet_maps"]) == ["aquilo", "gleba", "vulcanus"] and sorted(mem["net_maps"]) == ["gleba"], mem.keys()
    a.ingest({"planet_names": ["aquilo", "gleba", "vulcanus"]}, t + 300)
    mem = json.load(open(os.path.join(root, "shift56", "map-memory.json")))
    assert sorted(mem["net_maps"]) == ["gleba", "nauvis"] and mem["net_maps"]["nauvis"]["t"] == t + 210, mem["net_maps"]

    # shift57's service starts with them (no file of its own yet); its first read replaces Aquilo's
    b = Model({"agents": {}})
    got = b.set_map_memory(*serve.map_memory_paths(os.path.join(root, "shift57")))
    assert got == os.path.join(root, "shift56", "map-memory.json"), got
    s = b.snapshot(t + 400)
    assert sorted(s["planet_maps"]) == ["aquilo", "gleba", "vulcanus"] and s["planet_maps"]["gleba"]["tick"] == 1001, s["planet_maps"]
    assert sorted(s["net_maps"]) == ["gleba", "nauvis"] and s["net_maps"]["gleba"]["age_s"] == 200, s["net_maps"]
    b.ingest({"planet_map": grid("aquilo", 9000)}, t + 410)
    assert b.snapshot(t + 410)["planet_maps"]["aquilo"]["tick"] == 9000
    assert sorted(json.load(open(os.path.join(root, "shift57", "map-memory.json")))["planet_maps"]) == ["aquilo", "gleba", "vulcanus"]

    # a census pass that leaves Vulcanus out: kept for PLANET_GONE_S, then gone
    b.ingest({"planet_names": ["aquilo", "gleba"]}, t + 500)
    b.ingest({"planet_names": ["aquilo", "gleba"]}, t + 500 + b.PLANET_GONE_S - 1)
    assert "vulcanus" in b.planet_maps
    b.ingest({"planet_names": ["aquilo", "gleba", "vulcanus"]}, t + 500 + b.PLANET_GONE_S)  # listed again: its clock restarts
    b.ingest({"planet_names": ["aquilo", "gleba"]}, t + 600 + b.PLANET_GONE_S)
    b.ingest({"planet_names": ["aquilo", "gleba"]}, t + 600 + 2 * b.PLANET_GONE_S - 1)
    assert "vulcanus" in b.planet_maps
    b.ingest({"planet_names": ["aquilo", "gleba"]}, t + 600 + 2 * b.PLANET_GONE_S)
    assert sorted(b.planet_maps) == ["aquilo", "gleba"], sorted(b.planet_maps)
    b.ingest({"planet_names": []}, t + 600 + 3 * b.PLANET_GONE_S)  # the census before its first pass lists none: no change
    assert sorted(b.planet_maps) == ["aquilo", "gleba"]

    # a broken file is not read
    open(os.path.join(root, "shift57", "map-memory.json"), "w").write("{")
    c = Model({"agents": {}})
    assert c.set_map_memory(*serve.map_memory_paths(os.path.join(root, "shift57"))) == os.path.join(root, "shift56", "map-memory.json")
    print("map memory: ok (both maps kept across a restart and along the resumed-from chain; a read replaces one; "
          "a planet unlisted for PLANET_GONE_S goes)")


if __name__ == "__main__":
    main()
