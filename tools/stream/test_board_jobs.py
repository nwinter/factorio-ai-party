#!/usr/bin/env python3
"""The live page's Board card lists the jobs behind its counts (viewer joonazan, d15 08:19: "I can't see the open jobs
but would like to"): python3 tools/stream/test_board_jobs.py

model.py board_snapshot: open tasks and requests nobody owns, and those claimed or being done, from the last active
board read (live.py: active tasks and requests, board.active_ids), the latest changed first, 20 each with totals; an
item cached from an older read that the active read no longer lists (done, dropped) is left out; before an active read
(an older service, a failed read) only the counts, as before.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402


def main():
    m = model.Model({"agents": {n: {} for n in ("opus", "haiku")}})
    items = [{"id": 1, "kind": "request", "title": "Laser turrets for the east wall", "status": "open", "requested_by": "haiku", "updated_tick": 50},
             {"id": 2, "kind": "task", "title": "Rebuild NW coal", "status": "doing", "owner": "opus", "updated_tick": 60},
             {"id": 3, "kind": "request", "title": "Steel for barrels", "status": "claimed", "owner": "haiku", "requested_by": "muse", "updated_tick": 70},
             {"id": 4, "kind": "claim", "title": "home boilers", "status": "doing", "owner": "haiku", "updated_tick": 80},
             {"id": 5, "kind": "request", "title": "old, done since", "status": "open", "updated_tick": 10},
             {"id": 6, "kind": "task", "title": "blocked one", "status": "blocked", "owner": "opus", "updated_tick": 90}]
    # before an active read: counts only
    m._ingest_board({"items": items, "open_unowned": 1})
    b = m.board_snapshot()
    assert "open_items" not in b and b["open_unowned"] == 1 and b["in_progress"] == 2, b
    # the active read lists 1, 2, 3, 6 (5 was done since the older read)
    m._ingest_board({"items": items, "open_unowned": 1, "active_ids": [1, 2, 3, 6]})
    b = m.board_snapshot()
    assert [j["id"] for j in b["open_items"]] == [1] and b["open_items_total"] == 1, b["open_items"]
    assert b["open_items"][0] == {"id": 1, "title": "Laser turrets for the east wall", "kind": "request", "owner": None, "agent": None,
                                  "status": "open", "requested_by": "haiku"}, b["open_items"][0]
    assert [(j["id"], j["agent"], j["status"]) for j in b["doing_items"]] == [(3, "haiku", "claimed"), (2, "opus", "doing")], b["doing_items"]
    # bounded, with the totals
    many = [{"id": 100 + i, "kind": "task", "title": f"job {i}", "status": "open", "updated_tick": 1000 + i} for i in range(30)]
    m._ingest_board({"items": many, "open_unowned": 31, "active_ids": [1, 2, 3] + [x["id"] for x in many]})
    b = m.board_snapshot()
    assert len(b["open_items"]) == model.Model.JOBS_MAX == 20 and b["open_items_total"] == 31, (len(b["open_items"]), b["open_items_total"])
    assert b["open_items"][0]["title"] == "job 29", b["open_items"][0]
    # a failed active read: the lists go, the counts stay
    m._ingest_board({"items": [], "open_unowned": 31, "active_ids": None})
    assert "open_items" not in m.board_snapshot()
    print("board jobs: ok (open and in progress from the active read, newest change first, 20 each with totals, stale items left out)")


if __name__ == "__main__":
    main()
