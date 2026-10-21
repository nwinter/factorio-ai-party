#!/usr/bin/env python3
"""The team library's placed areas in the stream service (d21 batch68 AD2, viewer Aurora): python3 tools/stream/test_libareas.py

1. harness.OPERATOR_READS lists library_areas (the client refuses an operator read it does not list).
2. live.LiveSource.observe_library_areas: once a library_areas_every, on a runtime that lists the read; the read's rows
   go to obs; a failed read waits 2 minutes; an older runtime is not asked.
3. model.Model keeps the last read and the snapshot carries it with its age; a cycle without a read keeps it.
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


check("an operator read the client allows", "library_areas" in harness.OPERATOR_READS)

AREA = {"name": "aq-cell", "surface": "aquilo", "box": [0, 0, 10, 10], "tick": 900, "by": "sol",
        "hookups": {"b": [0, 1, 1, 0], "p": [1, 1], "i": [0, 0, 0, 1], "e": [1, 1, 2, 0], "g": 0, "n": 26, "open": [], "t": 950}}


class FakeHarness:
    def __init__(self):
        self.calls, self.fail = [], False

    def operator_read(self, action, args=None):
        self.calls.append((action, args))
        if self.fail:
            raise RuntimeError("boom")
        return {"tick": 1000, "areas": [AREA], "placements": 1, "shown": 1}, 1000


src = live.LiveSource.__new__(live.LiveSource)
src.h = FakeHarness()
src.has_library_areas, src.next_library_areas, src.library_areas_every = True, 0, 60.0
obs, errors = {}, {}
src.observe_library_areas(obs, errors)
check("read and put in obs", obs.get("library_areas", {}).get("areas") == [AREA] and src.h.calls == [("library_areas", {})], (obs, src.h.calls))
obs2 = {}
src.observe_library_areas(obs2, errors)
check("not again within the minute", "library_areas" not in obs2 and len(src.h.calls) == 1, src.h.calls)
src.next_library_areas, src.h.fail = 0, True
obs3, errors3 = {}, {}
src.observe_library_areas(obs3, errors3)
check("a failed read: an error, no rows", "library_areas" not in obs3 and "library_areas" in errors3, (obs3, errors3))
old = live.LiveSource.__new__(live.LiveSource)
old.h, old.has_library_areas, old.next_library_areas = FakeHarness(), False, 0
old.observe_library_areas({}, {})
check("an older runtime is not asked", old.h.calls == [], old.h.calls)

m = Model({"agents": {"sol": {"display_name": "Sol"}}})
m.ingest({"tick": 10, "agents": [], "library_areas": obs["library_areas"]}, now=1000)
snap = m.snapshot(1030)
check("the snapshot carries it with its age", snap["library_areas"]["areas"] == [AREA] and snap["library_areas"]["age_s"] == 30, snap.get("library_areas"))
m.ingest({"tick": 20, "agents": []}, now=1060)
check("a cycle without a read keeps the last", m.snapshot(1060)["library_areas"]["areas"] == [AREA])
json.dumps(snap)

if failed:
    print("FAILED: " + ", ".join(failed))
    sys.exit(1)
print("all passed")
