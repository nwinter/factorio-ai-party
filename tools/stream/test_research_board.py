#!/usr/bin/env python3
"""Board widget: the team plan and finished research (eng/research): python3 tools/stream/test_research_board.py

- A `board` read's `plan` (board_plan) reaches the snapshot: goals, each agent's line matched to its card, last edit;
  an older runtime without `plan` leaves it None, and an empty plan is None.
- A research board event (by research, no item) is an event row titled with the technology's label; plan edits are
  not rows (the plan line shows them).
- live.py passes the plan on; overlay.js draws the plan line and research rows and still parses.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model  # noqa: E402


def main():
    m = Model({"agents": {"astra": {}, "sol": {}}})
    now = time.time()
    m.ingest({"board": {"items": [], "open_unowned": 0}})
    assert m.snapshot(now)["board"]["plan"] is None  # older runtime: no plan field
    m.ingest({"board": {"items": [], "open_unowned": 0, "plan": {"id": 7, "goals": "Robots by hour 3; [color=red]oil[/color] next",
                                                                  "doing": ["sol: oil at the north field",
                                                                            "astra: roboports (set by sol)"],
                                                                  "edited": "by sol, 1m00s ago"}}})
    plan = m.snapshot(now)["board"]["plan"]
    assert plan["goals"] == "Robots by hour 3; oil next", plan
    assert plan["doing"] == [{"agent": "sol", "name": "sol", "text": "oil at the north field"},
                             {"agent": "astra", "name": "astra", "text": "roboports"}], plan
    assert plan["edited"] == "by sol, 1m00s ago"
    m.ingest({"board": {"items": [], "plan": {"id": 7, "goals": None, "doing": None}}})
    assert m.snapshot(now)["board"]["plan"] is None  # an empty plan shows nothing
    m.ingest({"board": {"items": [], "plan": False}})
    assert m.snapshot(now)["board"]["plan"] is None

    m.ingest({"board_events": [
        {"seq": 1, "tick": 10, "by": "research", "kind": "research", "title": "logistic-robotics", "change": "done",
         "status": "done", "text": "unlocks: roboport, logistic-robot"},
        {"seq": 2, "tick": 11, "by": "sol", "id": 7, "kind": "plan", "title": "Team plan", "change": "edited",
         "status": "doing", "owner": "astra", "text": "astra: roboports"}]})
    events = m.snapshot(now)["board"]["events"]
    assert [(e["verb"], e["kind"], e["title"], e["agent"]) for e in events] == [("done", "research", "Logistic robotics", None)], events
    assert 7 in m.board["items"] and m.board["items"][7]["kind"] == "plan"  # the item cache still follows the plan

    live = open(os.path.join(HERE, "live.py")).read()
    assert '"plan": res.get("plan")' in live
    js = os.path.join(HERE, "static", "overlay.js")
    src = open(js).read()
    assert 'el("div", "bev plan")' in src and 'e.kind === "research"' in src
    subprocess.run(["node", "--check", js], check=True)
    print("research board: ok (plan line, research rows, no plan-edit rows)")


if __name__ == "__main__":
    main()
