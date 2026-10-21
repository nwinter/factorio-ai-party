#!/usr/bin/env python3
"""Each planet's networks map in the stream service (d21 batch68 AD3, viewer Aurora): python3 tools/stream/test_netmap.py

1. harness.OPERATOR_READS lists net_map (the client refuses an operator read it does not list).
2. live.LiveSource.observe_net_map: once a net_map_every, on a runtime that lists the read; the first call reads the
   listing, the next the first listed planet whose map is newer than the one read, then the next; a failed read waits
   2 minutes; an older runtime is not asked.
3. model.Model keeps a map a planet, the snapshot carries each with its age, and a planet the listing no longer has is
   dropped.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import harness  # noqa: E402
import live  # noqa: E402
from model import Model  # noqa: E402

failed = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)))
    if not ok:
        failed.append(name)


check("an operator read the client allows", "net_map" in harness.OPERATOR_READS)

MAPS = {"aquilo": {"surface": "aquilo", "tick": 900, "electric": {"nets": "5,A,40"}, "logistic": [], "items": []},
        "gleba": {"surface": "gleba", "tick": 950, "electric": {"nets": ""}, "logistic": [], "items": []}}


class FakeHarness:
    def __init__(self):
        self.calls, self.fail = [], False

    def operator_read(self, action, args=None):
        self.calls.append((action, args))
        if self.fail:
            raise RuntimeError("boom")
        res = {"tick": 1000, "surfaces": [{"surface": k, "tick": m["tick"]} for k, m in sorted(MAPS.items())]}
        if args and args.get("surface") in MAPS:
            res["map"] = MAPS[args["surface"]]
        return res, 1000


src = live.LiveSource.__new__(live.LiveSource)
src.h = FakeHarness()
src.has_net_map, src.next_net_map, src.net_map_every, src.net_map_seen, src.net_map_listed = True, 0, 20.0, {}, []
obs, errors = {}, {}
src.observe_net_map(obs, errors)
check("first the listing", src.h.calls == [("net_map", {})] and "net_map" not in obs and obs.get("net_map_listed") == ["aquilo", "gleba"], (src.h.calls, obs))
obs2 = {}
src.observe_net_map(obs2, errors)
check("not again within net_map_every", "net_map_listed" not in obs2 and len(src.h.calls) == 1, src.h.calls)
src.next_net_map = 0
obs3 = {}
src.observe_net_map(obs3, errors)
check("then the first planet with a newer map", src.h.calls[-1] == ("net_map", {"surface": "aquilo"}) and obs3.get("net_map", {}).get("surface") == "aquilo", (src.h.calls, obs3))
src.next_net_map = 0
obs4 = {}
src.observe_net_map(obs4, errors)
check("then the next", src.h.calls[-1] == ("net_map", {"surface": "gleba"}) and obs4["net_map"]["surface"] == "gleba", src.h.calls)
src.next_net_map = 0
obs5 = {}
src.observe_net_map(obs5, errors)
check("none newer: the listing only", src.h.calls[-1] == ("net_map", {}) and "net_map" not in obs5, src.h.calls)
MAPS["aquilo"] = dict(MAPS["aquilo"], tick=1900)
src.next_net_map = 0
src.observe_net_map({}, errors)
src.next_net_map = 0
obs6 = {}
src.observe_net_map(obs6, errors)
check("a planet's map made again: read again", src.h.calls[-1] == ("net_map", {"surface": "aquilo"}) and obs6["net_map"]["tick"] == 1900, src.h.calls)
src.next_net_map, src.h.fail = 0, True
obs7, errors7 = {}, {}
src.observe_net_map(obs7, errors7)
check("a failed read: an error, no map", "net_map" not in obs7 and "net_map" in errors7 and src.next_net_map > 0, (obs7, errors7))
old = live.LiveSource.__new__(live.LiveSource)
old.h, old.has_net_map, old.next_net_map = FakeHarness(), False, 0
old.observe_net_map({}, {})
check("an older runtime is not asked", old.h.calls == [], old.h.calls)

m = Model({"agents": {"sol": {"display_name": "Sol"}}})
m.ingest({"tick": 10, "agents": [], "net_map": obs3["net_map"], "net_map_listed": ["aquilo", "gleba"]}, now=1000)
m.ingest({"tick": 20, "agents": [], "net_map": obs4["net_map"]}, now=1010)
snap = m.snapshot(1030)
check("a map a planet with its age", sorted(snap["net_maps"]) == ["aquilo", "gleba"] and snap["net_maps"]["aquilo"]["age_s"] == 30
      and snap["net_maps"]["gleba"]["age_s"] == 20, snap.get("net_maps"))
m.ingest({"tick": 30, "agents": [], "net_map_listed": ["gleba"]}, now=1040)
check("a planet no longer listed is dropped", sorted(m.snapshot(1040)["net_maps"]) == ["gleba"], m.snapshot(1040)["net_maps"])
json.dumps(snap)

if failed:
    print("FAILED: " + ", ".join(failed))
    sys.exit(1)
print("all passed")
