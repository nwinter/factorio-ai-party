#!/usr/bin/env python3
"""The team plan on the site (viewer Alex 22:12: "telemetry ... that shows the current shared plan the agents are
using"; viewer syndesis 22:13: a portrait's hover shows its plan line): python3 tools/stream/test_teamplan.py

1. live.py reads the board with plan_ticks (each line's tick); an older runtime refuses the argument and is asked
   without it from then on; the plan the stream read goes to runs/RUN/plan.json (planlog.py), replaced only on change.
2. model.py's plan snapshot carries each line's tick and who set it (when not the agent), the goals' and the last
   edit's ticks; open projects carry their next step and goal.
3. push_live sends the plan with its ticks and each agent's job_from to the site.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
import live  # noqa: E402
import model  # noqa: E402
import planlog  # noqa: E402

PLAN = {"id": 3, "goals": "Blue science, then the silo", "goals_tick": 1000,
        "doing": ["sol: blue circuits at (40,-20) (set by astra)", "luna: ammo north"], "edited": "by astra, 1m ago",
        "lines": [{"agent": "sol", "text": "blue circuits at (40,-20)", "by": "astra", "tick": 5000},
                  {"agent": "luna", "text": "ammo north", "by": "luna", "tick": 6000}], "updated_tick": 6000}
ITEMS = [{"id": 9, "kind": "project", "status": "doing", "title": "Rocket silo", "owner": "sol", "progress": "2 of 5 steps",
          "next_steps": ["[ ] Lay the foundation", "[ ] Feed it"], "goal": "a rocket by game 30h", "updated_tick": 5500},
         {"id": 10, "kind": "request", "status": "claimed", "title": "need 50 plates", "owner": "luna", "updated_tick": 5600},
         {"id": 11, "kind": "project", "status": "done", "title": "Old", "updated_tick": 10}]


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:1500]))
    if not ok:
        sys.exit(1)


def stream_reads():
    run = tempfile.mkdtemp()
    for refuse in (False, True):
        src = live.LiveSource.__new__(live.LiveSource)
        calls = []

        class H:
            def dispatch(self, action, args=None, **who):
                return {"events": [], "cursor": 0}, 7000

        def read(action, args=None, **who):
            calls.append((action, dict(args or {})))
            if refuse and (args or {}).get("plan_ticks"):
                raise RuntimeError("board: unknown argument plan_ticks for board; valid: full, mine, status")
            if (args or {}).get("kind"):
                return {"items": [it for it in ITEMS if it["kind"] == args["kind"]]}, 7000
            plan = dict(PLAN) if (args or {}).get("plan_ticks") else {k: v for k, v in PLAN.items() if k not in ("lines", "goals_tick", "updated_tick")}
            return {"items": ITEMS, "open_unowned": 2, "plan": plan, "tick": 7000}, 7000
        src.h, src.read, src.reader = H(), read, (lambda: {"bot": "sol"})
        src.caps, src.has_board, src.next_board_probe = {"harness": True}, True, time.time() + 999
        src.has_confess = src.has_tells = src.has_operator = False
        for name in ("observe_groups", "observe_hauling", "observe_efficiency", "observe_loadout", "observe_clouds"):
            setattr(src, name, lambda *a: None)
        src.board_seq, src.next_board, src.board_every, src.journals, src.plan_ticks_ok = 0, 0, 15.0, run, None
        obs, errors = {}, {}
        src.observe_board(obs, errors)
        boards = [a for n, a in calls if n == "board" and "kind" not in a]
        if not refuse:
            check("the board is read with plan_ticks", boards == [{"limit": 60, "plan_ticks": True}] and src.plan_ticks_ok, boards)
            check("its plan reaches obs with the lines' ticks", obs["board"]["plan"]["lines"][0]["tick"] == 5000 and not errors, (obs, errors))
            rec = json.load(open(os.path.join(run, "plan.json")))
            check("plan.json: goals, lines with who set them and when, open projects with the next step, counts",
                  rec["goals"] == "Blue science, then the silo" and rec["goals_tick"] == 1000
                  and rec["lines"][0] == {"agent": "sol", "text": "blue circuits at (40,-20)", "by": "astra", "tick": 5000}
                  and [(p["title"], p["next"], p["progress"]) for p in rec["projects"]] == [("Rocket silo", "Lay the foundation", "2 of 5 steps")]
                  and rec["open_unowned"] == 2 and rec["in_progress"] == 1 and rec["tick"] == 7000, rec)
        else:
            check("an older runtime refuses plan_ticks: read again without it, and from then on",
                  boards == [{"limit": 60, "plan_ticks": True}, {"limit": 60}] and src.plan_ticks_ok is False, boards)
            calls.clear(); src.next_board = 0
            src.observe_board({}, {})
            check("next time without asking", [a for n, a in calls if n == "board" and "kind" not in a] == [{"limit": 60}], calls)
            rec = json.load(open(os.path.join(run, "plan.json")))
            check("its plan file has the lines from 'agent: text', set by and ticks unknown",
                  rec["lines"][0] == {"agent": "sol", "text": "blue circuits at (40,-20)", "by": None, "tick": None}, rec["lines"])
    # replaced only when something besides the read's time changed
    rec = planlog.record(PLAN, ITEMS, 2, 7000, now=1.0)
    path = os.path.join(run, "plan.json")
    check("written when it changed", planlog.save(run, rec) is True)
    check("not again for a later read of the same plan", planlog.save(run, planlog.record(PLAN, ITEMS, 2, 9000, now=2.0)) is False
          and json.load(open(path))["tick"] == 7000)
    check("load reads it back", planlog.load(run)["lines"][1]["agent"] == "luna" and planlog.load(tempfile.mkdtemp()) is None)


def snapshot():
    m = model.Model({"agents": {"sol": {}, "luna": {}}})
    m._ingest_board({"items": ITEMS, "open_unowned": 2, "plan": PLAN})
    b = m.board_snapshot()
    p = b["plan"]
    check("the snapshot's lines carry when they were set and who set them", [(d["agent"], d["text"], d.get("tick"), d.get("by")) for d in p["doing"]]
          == [("sol", "blue circuits at (40,-20)", 5000, "astra"), ("luna", "ammo north", 6000, None)], p["doing"])
    check("and the goals' and the last edit's ticks", (p["goals_tick"], p["updated_tick"], p["edited"]) == (1000, 6000, "by astra, 1m ago"), p)
    check("an open project's next step and goal", [(x["title"], x["next"], x["goal"]) for x in b["projects"]]
          == [("Rocket silo", "Lay the foundation", "a rocket by game 30h")], b["projects"])
    m.board["plan"] = {k: v for k, v in PLAN.items() if k not in ("lines", "goals_tick", "updated_tick")}
    p = m.board_snapshot()["plan"]
    check("without ticks (an older runtime): the lines as before", "tick" not in p["doing"][0] and "goals_tick" not in p, p)


def site():
    import push_live
    check("push_live sends each agent's job_from", "job_from" in push_live.AGENT_KEYS and "job" in push_live.AGENT_KEYS)
    s = json.load(open(os.path.join(HERE, "..", "..", "site", "live", "state.example.json")))
    out = push_live.public_state(s)
    plan = out["board"]["plan"]
    check("and the board's plan with its ticks", plan["goals_tick"] == s["board"]["plan"]["goals_tick"]
          and plan["doing"][1]["by"] == "astra" and plan["doing"][0]["tick"] == s["board"]["plan"]["doing"][0]["tick"], plan)
    check("and the projects' next step", out["board"]["projects"][0]["next"] == "Reactor and heat exchangers", out["board"]["projects"])
    check("an agent's job_from", [a.get("job_from") for a in out["agents"] if a["name"] in ("opus", "muse")] == ["plan", "notes"])


def main():
    stream_reads()
    snapshot()
    site()
    print("team plan: ok (board plan_ticks with a fallback, plan.json on change, snapshot ticks and next steps, push_live)")


if __name__ == "__main__":
    main()
