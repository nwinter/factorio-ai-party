#!/usr/bin/env python3
"""Projects worked on and blocked, with the blocker's reason (d22 batch75 AK11, viewer Foobator site:4284: "can projects
that are actively being worked on and blocked projects be easier to see on site? also, could you show blocker
reason?"): python3 tools/stream/test_project_state.py

- model.project_state: state "active" (status doing, or an agent's board focus on it), "blocked" (status blocked, or an
  open item in its blocked_by; a closed one does not count), none otherwise; the focus rows on it with their blocker;
  blocked_by with the open item's title, status and owner (an id alone for one the board read lacks); the newest note
  when blocked; the progress check's last state from board_progress rows (stalled, check error, ages);
- projects_snapshot: those worked on first, then the blocked ones, the latest changed first within each;
- live.read_progress: board_progress with no arguments, at most once every PROGRESS_EVERY (the last rows between),
  an empty table ({}) as no rows, an older runtime asked again later; harness.dispatch refuses it with owner or id;
- planlog.record: blocked_by and the newest note on the plan file's projects, doing then blocked first.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
import model  # noqa: E402
import planlog  # noqa: E402
import harness  # noqa: E402


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def items():
    return [
        {"id": 1, "kind": "project", "title": "Uranium outpost", "status": "blocked", "owner": "muse", "progress": "1 of 4 steps", "updated_tick": 900,
         "notes": [{"by": "muse", "text": "old", "tick": 100}, {"by": "muse", "text": "Waiting on 200 steel at the outpost chest", "tick": 800}]},
        {"id": 2, "kind": "project", "title": "Gleba breeder", "status": "doing", "owner": "grok", "progress": "2 of 5 steps", "updated_tick": 500},
        {"id": 3, "kind": "project", "title": "EM circuits", "status": "claimed", "owner": "luna", "progress": "0 of 3 steps", "updated_tick": 950,
         "blocked_by": [7, 8, 99], "notes": [{"by": "luna", "text": "needs the steel line", "tick": 940}]},
        {"id": 4, "kind": "project", "title": "Shipyard", "status": "open", "owner": "sonnet", "progress": "1 of 2 steps", "updated_tick": 990},
        {"id": 5, "kind": "project", "title": "Freighter", "status": "claimed", "owner": "sol", "progress": "3 of 8 steps", "updated_tick": 400},
        {"id": 6, "kind": "project", "title": "Old blocker gone", "status": "open", "owner": "astra", "progress": "0 of 1 steps", "updated_tick": 980,
         "blocked_by": [9]},
        {"id": 7, "kind": "task", "title": "Steel line", "status": "open", "owner": None, "updated_tick": 10},
        {"id": 8, "kind": "task", "title": "Copper", "status": "done", "owner": "opus", "updated_tick": 10},
        {"id": 9, "kind": "task", "title": "Done thing", "status": "done", "owner": "opus", "updated_tick": 10},
    ]


def main():
    m = model.Model({"agents": {n: {} for n in ("muse", "grok", "luna", "sonnet", "sol", "astra", "opus")}})
    m._ingest_board({"items": items(), "open_unowned": 0,
                     "focus": [{"agent": "sol", "id": 5, "step": "step 4 load cargo", "blocker": "no rocket fuel on Vulcanus"}],
                     "progress": [{"id": 1, "state": "waiting (sleep)", "unchanged_checks": 0, "checked_s": 84, "last_change_s": 600},
                                  {"id": 2, "state": "stalled: unchanged across 3 checks", "stalled": True, "unchanged_checks": 3, "checked_s": 30},
                                  {"id": 4, "state": "check failed", "check_error": "surface read failed", "checked_s": 12}]})
    rows = {r["id"]: r for r in m.projects_snapshot()}
    check("doing: active", rows[2]["state"] == "active", rows[2])
    check("focus: active, its blocker", rows[5]["state"] == "active" and rows[5]["focus"] == [{"agent": "sol", "step": "step 4 load cargo", "blocker": "no rocket fuel on Vulcanus"}], rows[5])
    check("status blocked: blocked, its newest note", rows[1]["state"] == "blocked" and rows[1]["note"] == {"by": "muse", "text": "Waiting on 200 steel at the outpost chest", "tick": 800}, rows[1])
    check("blocked_by an open item: blocked, the open ones (a closed one left out, an unknown id kept)",
          rows[3]["state"] == "blocked" and rows[3]["blocked_by"] == [{"id": 7, "title": "Steel line", "status": "open", "owner": None}, {"id": 99}], rows[3])
    check("its note when blocked", rows[3]["note"]["text"] == "needs the steel line", rows[3])
    check("blocked_by only closed items: not blocked", "state" not in rows[6] and "blocked_by" not in rows[6], rows[6])
    check("open, nothing: no state, no note", "state" not in rows[4] and "note" not in rows[4], rows[4])
    check("check facts", rows[2]["check"] == {"state": "stalled: unchanged across 3 checks", "stalled": True, "unchanged_checks": 3, "checked_s": 30}
          and rows[4]["check"]["error"] == "surface read failed" and rows[1]["check"]["last_change_s"] == 600, (rows[2].get("check"), rows[4].get("check")))
    order = [r["id"] for r in m.projects_snapshot()]
    check("worked on first, then blocked, the latest changed first within each", order == [2, 5, 3, 1, 4, 6], order)
    b = m.board_snapshot()
    check("the card: the 4 worked on or blocked", [r["id"] for r in b["projects"]] == [2, 5, 3, 1] and [r["id"] for r in b["projects_more"]] == [4, 6],
          ([r["id"] for r in b["projects"]], [r["id"] for r in b["projects_more"]]))
    m2 = model.Model({"agents": {"opus": {}}})
    m2._ingest_board({"items": [{"id": 40 + i, "kind": "project", "title": f"P{i}", "status": "doing" if i < 10 else "open", "owner": "opus",
                                 "progress": "0 of 1 steps", "updated_tick": i} for i in range(12)]})
    b2 = m2.board_snapshot()
    check("the card: every one worked on or blocked, up to PROJECTS_SHOWN_MAX", len(b2["projects"]) == model.PROJECTS_SHOWN_MAX
          and all(r["state"] == "active" for r in b2["projects"]) and len(b2["projects_more"]) == 4, [r["id"] for r in b2["projects"]])
    # a failed read keeps the rows it had
    m._ingest_board({"items": [], "progress": None})
    check("progress kept when a read gives none", 2 in m.board["progress"])

    # live.read_progress
    import live
    src = live.LiveSource.__new__(live.LiveSource)
    calls = []
    replies = [{"rows": [{"id": 1, "state": "progress"}, {"no": "id"}]}, {"rows": {}}]

    def read(action, args, **kw):
        calls.append((action, args))
        return replies.pop(0), None
    src.read, src.reader = read, lambda: {"bot": "astra"}
    t = [1000.0]
    live.time.time, real = (lambda: t[0]), live.time.time
    try:
        errors = {}
        r1 = src.read_progress(errors)
        check("rows with an id", r1 == [{"id": 1, "state": "progress"}] and calls == [("board_progress", {})], (r1, calls))
        t[0] += 10
        check("between reads: the last rows, no read", src.read_progress(errors) == r1 and len(calls) == 1)
        t[0] += live.PROGRESS_EVERY
        check("an empty table: no rows", src.read_progress(errors) == [] and len(calls) == 2)
    finally:
        live.time.time = real
    # harness: no arguments only
    h = harness.Harness.__new__(harness.Harness)
    try:
        h.dispatch("board_progress", {"owner": "sol"})
        raise SystemExit("FAIL board_progress with owner went through")
    except ValueError as e:
        check("owner refused", "no arguments" in str(e), e)
    check("a read action", "board_progress" in harness.READ_ACTIONS)

    # planlog: the plan file's projects
    rec = planlog.record({"goals": "g"}, items(), 0, 1000, now=1.0)
    ps = {p["id"]: p for p in rec["projects"]}
    check("plan file: blocked_by open ones", ps[3]["blocked_by"] == [{"id": 7, "title": "Steel line", "status": "open"}], ps[3])
    check("plan file: newest note when blocked", ps[1]["note"] == {"by": "muse", "text": "Waiting on 200 steel at the outpost chest"} and "note" not in ps[2], ps[1])
    check("plan file: doing, then blocked, first", [p["id"] for p in rec["projects"]][:3] == [2, 3, 1], [p["id"] for p in rec["projects"]])
    print("project state: ok (worked on: doing or focused; blocked: status or an open blocked_by; the reasons the board "
          "holds: open blockers, newest note, focus blocker, progress check; those first; board_progress read every "
          "2 min with no arguments; the plan file too)")


if __name__ == "__main__":
    main()
