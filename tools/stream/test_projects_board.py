#!/usr/bin/env python3
"""Board widget: projects (board kind project, eng/projects): python3 tools/stream/test_projects_board.py

- board_verb: a project's step_done is a `step` row; its other step changes, goal, handoff and areas are updates (not
  shown), so step_undone never reads as "finished".
- A project's events carry its progress: the row has progress, steps_done, steps_total and the step it did; the item
  cache follows the progress between `board` reads.
- board_snapshot lists the open projects, the latest changed first, with done and total for a bar ("no steps yet" is
  0 of 0); finished and dropped ones leave.
- overlay.js draws project rows with their progress and a Projects row; it still parses.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model, board_verb, project_steps  # noqa: E402


def ev(seq, change, by="astra", **kw):
    e = {"seq": seq, "tick": 100 + seq, "by": by, "id": 6, "change": change, "title": "Nuclear plant", "kind": "project",
         "owner": "sol", "requested_by": "sol", "status": "claimed"}
    e.update(kw)
    return e


def main():
    assert board_verb("step_done") == "step"
    for change in ("step_undone", "step_added", "step_removed", "goal", "handoff", "areas"):
        assert board_verb(change) == "updated", change
    assert board_verb("posted") == "posted" and board_verb("done") == "done"
    assert project_steps("3 of 7 steps") == (3, 7) and project_steps("0 of 1 step") == (0, 1)
    assert project_steps("no steps yet") == (0, 0) and project_steps(None) == (None, None)
    assert project_steps("x", 2, 5) == (2, 5)

    m = Model({"agents": {"astra": {}, "sol": {}}})
    now = time.time()
    m.ingest({"board_events": [
        ev(1, "posted", by="sol", progress="0 of 3 steps", steps_done=0, steps_total=3),
        ev(2, "step_added", progress="0 of 4 steps", steps_done=0, steps_total=4, text="4. turbines"),
        ev(3, "step_done", progress="1 of 4 steps", steps_done=1, steps_total=4, text="1. mine uranium"),
        ev(4, "step_undone", progress="0 of 4 steps", steps_done=0, steps_total=4, text="1. mine uranium"),
        ev(5, "handoff", by="sol", progress="0 of 4 steps", steps_done=0, steps_total=4, text="pumps placed"),
        ev(6, "step_done", progress="1 of 4 steps", steps_done=1, steps_total=4, text="1. mine uranium"),
    ]}, now)
    b = m.snapshot(now)["board"]
    rows = [(e["verb"], e["agent"], e.get("progress"), e.get("steps_done"), e.get("steps_total"), e.get("step")) for e in b["events"]]
    assert rows == [("posted", "sol", "0 of 3 steps", 0, 3, None), ("step", "astra", "1 of 4 steps", 1, 4, "1. mine uranium"),
                    ("step", "astra", "1 of 4 steps", 1, 4, "1. mine uranium")], rows
    assert b["projects"] == [{"id": 6, "title": "Nuclear plant", "owner": "sol", "agent": "sol", "status": "claimed",
                              "progress": "1 of 4 steps", "done": 1, "total": 4}], b["projects"]
    # a board read's rows (progress text only), the latest changed first; closed ones leave
    m.ingest({"board": {"items": [
        {"id": 7, "kind": "project", "title": "Robot mall", "owner": None, "status": "open", "progress": "no steps yet", "updated_tick": 500},
        {"id": 8, "kind": "project", "title": "Old rail", "owner": "sol", "status": "done", "progress": "4 of 4 steps", "updated_tick": 600},
        {"id": 9, "kind": "task", "title": "Gears", "owner": "astra", "status": "doing", "updated_tick": 700}]}})
    b = m.snapshot(now)["board"]
    assert [(p["id"], p["done"], p["total"], p["agent"]) for p in b["projects"]] == [(7, 0, 0, None), (6, 1, 4, "sol")], b["projects"]
    assert b["projects_total"] == 2 and b["in_progress"] == 1, b
    m.ingest({"board_events": [ev(7, "done", by="sol", status="done", progress="4 of 4 steps", steps_done=4, steps_total=4)]}, now)
    b = m.snapshot(now)["board"]
    assert [p["id"] for p in b["projects"]] == [7] and b["events"][-1]["verb"] == "done", b

    js = os.path.join(HERE, "static", "overlay.js")
    src = open(js).read()
    assert 'function projProgress(done, total)' in src and 'e.kind === "project" && e.steps_total != null' in src
    assert '"Projects"' in src and 'step: "finished a step of"' in src and 'project: "project"' in src
    subprocess.run(["node", "--check", js], check=True)
    print("projects board: ok (step rows with progress, no undone-as-finished, open projects with bars, older reads)")


if __name__ == "__main__":
    main()
