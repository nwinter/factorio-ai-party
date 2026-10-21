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
    assert "line" not in j and j["missed"] is None
    # (d17 batch35 D3) the runs each recipient missed, and the owner told, reach the site
    m.ingest({"reminders": {"tick": 200, "jobs": [{"id": 59, "owner": "sol", "message": "review", "enabled": True,
              "states": "grok overdue (10 runs missed, the owner told); sol acknowledged", "missed": {"grok": 10}}]}})
    j = m.reminders_snapshot()["jobs"][0]
    assert j["missed"] == {"grok": 10} and "the owner told" in j["states"], j
    m.ingest({"reminders": {"tick": 100, "jobs": [
        {"id": 1, "name": "ship review", "owner": "sol", "recipients": "astra, sol", "message": "Petrel ammo and fuel",
         "cadence": "every 15m00s", "enabled": True, "next_due_in_s": 420, "last_result": "900 magazines", "result_age_s": 480,
         "result_by": "sol", "states": "astra pending; sol acknowledged", "line": "not passed on"}]}})
    import time
    assert m.snapshot(time.time())["reminders"]["total"] == 1
    assert m.reminders_snapshot()["jobs"][0]["latest"] is None and m.reminders_snapshot()["jobs"][0]["backup"] is None
    # (d20 batch70 AF2, viewer Aurora) the backup and each recipient's latest; a long result cut for the panel
    m.ingest({"reminders": {"tick": 300, "jobs": [{"id": 107, "owner": "astra", "message": "verify receipts", "enabled": True, "backup": "sol",
              "latest": [{"name": "astra", "state": "overdue", "acked_tick": 42355277, "acked_ago_s": 8820, "result": "K2 " + "x" * 400,
                          "waiting_since_tick": 42358560, "waiting_s": 8580, "missed": 15, "first_missed_tick": 42394560,
                          "backup_told_tick": 42394560, "line": "not passed on"},
                         {"name": "sol", "state": "acknowledged", "acked_ago_s": 60, "result": "ok", "by": "astra"}, "junk"]}]}})
    j = m.reminders_snapshot()["jobs"][0]
    assert j["backup"] == "sol" and len(j["latest"]) == 2, j
    a, s_ = j["latest"]
    assert a["agent"] == "astra" and a["missed"] == 15 and a["waiting_s"] == 8580 and a["backup_told"] is True and "line" not in a, a
    assert len(a["result"]) == model.Model.LATEST_RESULT and a["result"].endswith("..."), a["result"]
    assert s_["by"] == "astra" and s_["result"] == "ok" and s_["waiting_s"] is None and s_["backup_told"] is False, s_
    many = [{"id": i, "owner": "sol", "message": f"job {i}", "enabled": True} for i in range(120)]
    m.ingest({"reminders": {"jobs": many}})
    s = m.reminders_snapshot()
    assert len(s["jobs"]) == model.Model.REMINDERS_MAX and s["total"] == 120, (len(s["jobs"]), s["total"])
    # (d20 batch65 AA4) every job of a list like world n's (25) for the panel's "Show all"
    m.ingest({"reminders": {"jobs": many[:25]}})
    assert len(m.reminders_snapshot()["jobs"]) == 25
    # (d19 batch43 A2, batch41 B2) a result up to 1000 characters and the evidence lines reach the site whole
    long = "the recycler loop fed at 92% and the legendary yield held at 3.1% " * 15
    m.ingest({"reminders": {"jobs": [{"id": 97, "owner": "sol", "message": "quality review", "enabled": True,
              "last_result": long[:1000], "evidence": ["by sol 30m ago: metric PU 540/min (tick 100)", "", 5]}]}})
    j = m.reminders_snapshot()["jobs"][0]
    assert j["last_result"] == long[:1000] and j["evidence"] == ["by sol 30m ago: metric PU 540/min (tick 100)", "5"], j
    # board items: a claim's, a job's and a project's evidence; a project's handoff whole (it was cut at 300)
    m.ingest({"board": {"items": [
        {"id": 5, "kind": "claim", "status": "open", "owner": "sol", "title": "Gleba farm", "updated_tick": 3,
         "evidence": ["by sol 1m ago: metric 40 towers"]},
        {"id": 6, "kind": "project", "status": "doing", "owner": "astra", "title": "Bastion", "progress": "1 of 4 steps",
         "handoff": "h" * 900, "evidence": ["by astra 3m ago: result hull sealed", "by astra 1m ago: next check tick 9"], "updated_tick": 2}],
        "active_ids": [5, 6]}})
    b = m.board_snapshot()
    assert b["claims"][0]["evidence"] == ["by sol 1m ago: metric 40 towers"], b["claims"]
    p = b["projects"][0]
    assert p["handoff"] == "h" * 900 and p["evidence"][-1] == "by astra 1m ago: next check tick 9", p
    print("reminders: ok (results and evidence whole, board items' evidence, a project's handoff whole)")


if __name__ == "__main__":
    main()
