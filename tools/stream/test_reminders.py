#!/usr/bin/env python3
"""The site's Reminders panel (d15 batch5 group I): python3 tools/stream/test_reminders.py

model.py reminders_snapshot: the team's reminder jobs from live.py's `reminders {all: true}` read (owner, message,
cadence, next due, last result and its age, each recipient's state), at most REMINDERS_MAX with the total; None before
the first read (an older runtime has no reminders and the panel stays away).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402


def main():
    m = model.Model({"agents": {n: {} for n in ("sol", "astra")}})
    assert m.reminders_snapshot() is None
    m.ingest({"reminders": {"tick": 100, "jobs": [
        {"id": 1, "name": "ship review", "owner": "sol", "recipients": "astra, sol", "message": "Petrel ammo and fuel",
         "cadence": "every 15m00s", "enabled": True, "next_due_in_s": 420, "last_result": "900 magazines", "result_age_s": 480,
         "result_by": "sol", "states": "astra pending; sol acknowledged", "line": "not passed on"}]}})
    s = m.reminders_snapshot()
    assert s["total"] == 1 and len(s["jobs"]) == 1, s
    j = s["jobs"][0]
    assert j["owner"] == "sol" and j["agent"] == "sol" and j["message"] == "Petrel ammo and fuel", j
    assert j["next_due_in_s"] == 420 and j["last_result"] == "900 magazines" and j["states"] == "astra pending; sol acknowledged", j
    assert "line" not in j
    import time
    assert m.snapshot(time.time())["reminders"]["total"] == 1
    many = [{"id": i, "owner": "sol", "message": f"job {i}", "enabled": True} for i in range(20)]
    m.ingest({"reminders": {"jobs": many}})
    s = m.reminders_snapshot()
    assert len(s["jobs"]) == model.Model.REMINDERS_MAX and s["total"] == 20, (len(s["jobs"]), s["total"])
    print("reminders: ok")


if __name__ == "__main__":
    main()
