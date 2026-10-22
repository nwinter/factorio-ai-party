#!/usr/bin/env python3
"""Projects with their steps for the live page (viewer Foobator, d15 08:31: "the site lists projects, but we cant see the
individual steps. there is also no way to browse hidden projects"): python3 tools/stream/test_project_steps.py

- model.parse_steps: the board's step lines ("[x] 3. text (done by sol, 5m00s ago)", "[ ] 4. text") as rows, the first
  open one marked next;
- board_snapshot: each project with its steps (steps_partial while only a list read's next steps are known), needs,
  handoff, who asked; the card's 4, projects_more (the rest of the open ones) and projects_done (the last finished);
- live.py full_steps: a project is read in full (board {id}) only when its updated_tick changed, at most STEP_READS a
  refresh, and the cache forgets projects no longer listed.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402


def parse_tests():
    rows = model.parse_steps(["[x] 1. Find a coal patch (done by opus, 12m03s ago)", "[x] 2. Lay the belt (done by sol, 5s ago)",
                              "[ ] 3. Feed the boilers", "[ ] 4. Add turrets", "nonsense"])
    assert rows == [{"n": 1, "text": "Find a coal patch", "done": True, "by": "opus", "ago": "12m03s"},
                    {"n": 2, "text": "Lay the belt", "done": True, "by": "sol", "ago": "5s"},
                    {"n": 3, "text": "Feed the boilers", "done": False, "next": True},
                    {"n": 4, "text": "Add turrets", "done": False}], rows
    # a list row's next_steps carry no number on older runtimes; a long step is cut
    rows = model.parse_steps(["[ ] build 8 furnaces", "[ ] " + "x" * 400])
    assert rows[0] == {"n": None, "text": "build 8 furnaces", "done": False, "next": True} and len(rows[1]["text"]) == model.STEP_TEXT
    assert model.parse_steps(None) == [] and len(model.parse_steps(["[ ] s"] * 50)) == model.STEPS_MAX
    # d15 batch5 J2 (viewer Foobator): a step's own owner and the parallel mark; the parallel steps after the next one
    # are next too; a "(name)" that is no teammate stays in the text
    known = {"sol", "luna", "opus"}.__contains__
    rows = model.parse_steps(["[x] 1. Lay foundation (sol) (parallel) (done by sol, 2m00s ago)", "[ ] 2. Guns on the rear (luna) (parallel)",
                              "[ ] 3. Fuel makers (parallel)", "[ ] 4. Test flight (Fulgora)", "[ ] 5. Name it (opus)"], known)
    assert rows[0] == {"n": 1, "text": "Lay foundation", "done": True, "owner": "sol", "parallel": True, "by": "sol", "ago": "2m00s"}, rows[0]
    assert rows[1] == {"n": 2, "text": "Guns on the rear", "done": False, "owner": "luna", "parallel": True, "next": True}, rows[1]
    assert rows[2] == {"n": 3, "text": "Fuel makers", "done": False, "parallel": True, "next": True}, rows[2]
    assert rows[3] == {"n": 4, "text": "Test flight (Fulgora)", "done": False}, rows[3]
    assert rows[4] == {"n": 5, "text": "Name it", "done": False, "owner": "opus"}, rows[4]
    assert model.parse_steps(["[ ] 1. Ask (sol)"])[0]["text"] == "Ask (sol)", "no known names: the text as it is"


def snapshot_tests():
    m = model.Model({"agents": {n: {} for n in ("opus", "sol")}})
    items = []
    for i in range(7):
        items.append({"id": 10 + i, "kind": "project", "title": f"Project {i}", "status": "doing" if i != 2 else "blocked",
                      "owner": "opus", "requested_by": "sol" if i == 0 else "opus", "progress": "1 of 3 steps", "updated_tick": 100 + i,
                      "next_steps": ["[ ] 2. Second step", "[ ] 3. Third step"]})
    items[6]["steps"] = ["[x] 1. First (done by opus, 1m00s ago)", "[ ] 2. Second step", "[ ] 3. Third step"]
    items[6]["needs"] = {"iron-plate": 200, "bad": "x"}
    items[6]["handoff"] = "Coal belt runs to (10,40); turrets next."
    items.append({"id": 30, "kind": "project", "title": "Old silo", "status": "done", "owner": "sol", "progress": "4 of 4 steps",
                  "updated_tick": 50, "steps": ["[x] 1. Build it (done by sol, 2h01m ago)"]})
    m._ingest_board({"items": items, "open_unowned": 0})
    b = m.board_snapshot()
    # (d22 batch75 AK11) those worked on (doing) first, then the blocked one, the latest changed first within each; the
    # card shows every one worked on or blocked (all 7 here)
    assert [p["id"] for p in b["projects"]] == [16, 15, 14, 13, 11, 10, 12] and b["projects_total"] == 7, b["projects"]
    assert b["projects_more"] == [], b["projects_more"]
    assert [p["id"] for p in b["projects_done"]] == [30] and b["projects_done"][0]["status"] == "done", b["projects_done"]
    full = b["projects"][0]
    assert [s["text"] for s in full["steps"]] == ["First", "Second step", "Third step"] and "steps_partial" not in full, full
    assert full["steps"][1].get("next") and full["next"] == "Second step", full
    assert full["needs"] == {"iron-plate": 200} and full["handoff"].startswith("Coal belt") and "requested_by" not in full, full
    partial = b["projects"][5]
    assert partial["steps_partial"] is True and partial["requested_by"] == "sol" and partial["steps"][0]["text"] == "Second step", partial
    assert b["projects"][-1]["status"] == "blocked" and b["projects"][-1]["state"] == "blocked"


def full_steps_tests():
    import live
    calls = []

    class Fake:
        STEP_READS = live.LiveSource.STEP_READS
        full_steps = live.LiveSource.full_steps

        def __init__(self):
            self.project_steps = {}

        def reader(self):
            return {}

        def read(self, action, args=None, **who):
            calls.append(args["id"])
            return {"item": {"steps": [f"[ ] 1. step of {args['id']}"]}}, None

    f = Fake()
    items = [{"id": i, "updated_tick": 1} for i in range(10)]
    f.full_steps(items)
    assert calls == list(range(8)) and items[0]["steps"] == ["[ ] 1. step of 0"] and "steps" not in items[9], calls
    calls.clear()
    items = [{"id": i, "updated_tick": 1 if i != 3 else 2} for i in range(10)]
    f.full_steps(items)
    assert calls == [3, 8, 9] and all("steps" in it for it in items), calls  # changed or never read
    calls.clear()
    f.full_steps([{"id": 1, "updated_tick": 1}])
    assert calls == [] and list(f.project_steps) == [1], f.project_steps  # unchanged: no read; the rest forgotten


def main():
    parse_tests()
    snapshot_tests()
    try:
        import live  # noqa: F401
    except Exception as e:
        print(f"project steps: live.py part skipped ({e})")
    else:
        full_steps_tests()
    print("project steps: ok (step rows, next marked, steps on each project, projects_more and projects_done, full reads only on change)")


if __name__ == "__main__":
    main()
