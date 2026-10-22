#!/usr/bin/env python3
"""Every task, request, claim, project and reminder for the site's full lists: python3 tools/stream/test_board_all.py

d22 batch99 BI3 (viewer Aurora site:4316: "Could the board show all tasks and reminders, with paging if needed? Hidden
jobs and the nine omitted reminders make it hard to check what's actually finished."). Checks: model.py
board_all_snapshot lists every task and request of the active read and of the finished read (done, dropped), the
latest changed first, with status and updated_tick, past board_snapshot's 20 a list; every claim and project, the
reminder jobs whole; none before an active read; serve.py's /board.json gives it.
"""
import json
import os
import sys
import threading
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402
import serve  # noqa: E402


def snapshot():
    m = model.Model({"agents": {n: {} for n in ("opus", "haiku")}})
    assert m.board_all_snapshot() is None, "before an active read"
    doing = [{"id": 100 + i, "kind": "task", "title": f"job {i}", "status": "doing", "owner": "opus", "updated_tick": 1000 + i}
             for i in range(36)]
    done = [{"id": 200 + i, "kind": "request", "title": f"finished {i}", "status": "done", "owner": "haiku",
             "requested_by": "opus", "updated_tick": 500 + i} for i in range(18)]
    other = [{"id": 1, "kind": "claim", "title": "home boilers", "status": "doing", "owner": "haiku", "updated_tick": 80},
             {"id": 2, "kind": "request", "title": "stale, not in a read", "status": "open", "updated_tick": 10},
             {"id": 3, "kind": "task", "title": "dropped one", "status": "dropped", "owner": "opus", "updated_tick": 20}]
    m._ingest_board({"items": doing + done + other, "open_unowned": 0, "active_ids": [x["id"] for x in doing],
                     "finished_ids": [x["id"] for x in done] + [3]})
    m.reminders = {"jobs": [{"id": i, "name": f"r{i}", "owner": "opus", "message": "m", "states": "opus done",
                             "enabled": True} for i in range(31)]}
    b = m.board_snapshot()
    assert len(b["doing_items"]) == 20 and b["doing_items_total"] == 36, "the state's first view as before"
    a = m.board_all_snapshot()
    ids = [x["id"] for x in a["items"]]
    assert len(ids) == 36 + 18 + 1 and a["items_total"] == 55 and 2 not in ids, ids
    assert ids[0] == 135 and a["items"][0]["status"] == "doing" and a["items"][0]["updated_tick"] == 1035, a["items"][0]
    fin = [x for x in a["items"] if x["status"] == "done"]
    assert len(fin) == 18 and fin[0] == {"id": 217, "title": "finished 17", "kind": "request", "owner": "haiku",
                                         "agent": "haiku", "status": "done", "requested_by": "opus", "updated_tick": 517}, fin[0]
    assert [c["id"] for c in a["claims"]] == [1] and a["projects"] == []
    assert len(a["reminders"]) == 31 and a["reminders_total"] == 31, len(a["reminders"])
    json.dumps(a)
    return m


def endpoint(m):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(serve.Hub(), lambda: [], board_all=m.board_all_snapshot))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{srv.server_address[1]}/board.json", timeout=5) as r:
            body = json.load(r)
        assert body["items_total"] == 55 and len(body["reminders"]) == 31, body.keys()
    finally:
        srv.shutdown()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(serve.Hub(), lambda: []))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{srv.server_address[1]}/board.json", timeout=5) as r:
            assert json.load(r) is None, "no model: null"
    finally:
        srv.shutdown()


def main():
    endpoint(snapshot())
    print("board all: ok (every task and request of the active and finished reads, claims, projects, reminders; "
          "/board.json)")


if __name__ == "__main__":
    main()
