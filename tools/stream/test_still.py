#!/usr/bin/env python3
"""Standing still and the look-ahead (onecam.py; a viewer on shift01: "should move on air to next moving player if
they stand still too much"; Nick: the director could use the actions agents dispatch): python3 tools/stream/test_still.py

1. The character on air still for still_cut (25 s) and on air at least still_min (30 s): a cut to an agent moving
   now, within ready_s; that agent is not the pick again for still_block (60 s). Nobody moving: it stays.
2. "Thinking" with a still character scores like idle; walking, building, fighting score up; crafting, waits down.
3. A big visible action (a construct of many pieces) dispatched: scored up; the standby is framed to fit its bounds
   before the cut; on air it holds (no rotation) while it runs; once it ends, standing still plan_after is enough.
4. model.py carries each agent's plan (live.py: status `active`) while the action runs.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, snap, world  # noqa: E402
from onecam import big_plan  # noqa: E402


def thinker(name, x, y, interest=5):
    return agent(name, x, y, interest, activity="thinking", active=False)


def walker(name, x, y, interest=3):
    return agent(name, x, y, interest, activity="acting", active="move_to")


def onair(d):
    return ((d.public().get("main") or {}).get("agents") or [None])[0]


def until_onair(d, team, name, t0, t1, move=None):
    for t in range(t0, t1):
        if move:
            move(t)
        d.step(snap(team), t)
        if onair(d) == name:
            return t
    return None


def still_cut():
    d, _ = world()
    luna, sol = thinker("luna", 0, 0, 8), walker("sol", 300, 0, 3)
    team = [luna, sol]
    t = until_onair(d, team, "luna", 1000, 1010)
    assert t is not None, d.cuts
    def move(now):
        sol["position"] = {"x": 300 + (now - 1000) * 1.0, "y": 0}
    cut = until_onair(d, team, "sol", t + 1, t + 60, move)
    assert cut is not None and "still" in d.cuts[-1][2] and "sol moving" in d.cuts[-1][2], d.cuts
    assert cut - t >= d.cfg["still_min"] and cut - t <= d.cfg["still_min"] + d.cfg["ready_s"] + 2, (cut - t, d.cuts)
    # no ping-pong: Luna (far more interesting on paper) is not back within still_block, even when Sol stands still
    sol["active"], sol["activity"] = False, "thinking"
    luna["active"], luna["activity"] = "build", "acting"
    back = until_onair(d, team, "luna", cut + 1, cut + 55)
    assert back is None, (back - cut, d.cuts)


def nobody_moving():
    d, _ = world()
    team = [thinker("luna", 0, 0, 8), thinker("sol", 300, 0, 3)]
    t = until_onair(d, team, "luna", 1000, 1010)
    assert until_onair(d, team, "sol", t + 1, t + 85) is None, d.cuts  # stays (the dwell does the rest)


def scoring():
    d, _ = world()
    team = [thinker("luna", 0, 0, 4), walker("sol", 300, 0, 4), agent("opus", -300, 0, 4, active="craft"),
            agent("haiku", 0, 300, 4, active="build")]
    for t in range(1000, 1030):
        d.step(snap(team), t)
    s = d.scores(team, 1030)
    assert s["luna"] < s["opus"] < s["sol"], s  # thinking and still: like idle; crafting below walking
    assert s["haiku"] >= s["sol"], s


def lookahead():
    d, sent = world()
    luna, sol = thinker("luna", 0, 0, 8), thinker("sol", 300, 0, 4)
    team = [luna, sol]
    t = until_onair(d, team, "luna", 1000, 1010)
    sol.update(active="construct", activity="acting",
               plan={"kind": "construct", "total": 40, "remaining": 40, "bounds": {"left": 290, "top": -20, "right": 330, "bottom": 10}})
    assert big_plan(sol) and not big_plan(dict(sol, plan={"kind": "construct", "remaining": 2}))
    s = d.scores(team, t + 1)
    assert s["sol"] > 1.5 * 4 * 0.5, s  # plan_boost
    for k in range(1, 20):
        d.step(snap(team), t + k)
    framed = [b for b in sent if b.get("follow") == "sol"]
    assert framed and framed[-1]["smooth"] is False, sent[-3:]
    assert abs(framed[-1]["zoom"] - d.fight_zoom(40 + 2 * ((10 ** 2 + 5 ** 2) ** 0.5))) < 0.02, framed[-1]  # fits
    cut = until_onair(d, team, "sol", t + 20, t + 70)
    assert cut is not None and "construct ahead" in d.cuts[-1][2], d.cuts
    # on air it holds while the construct runs: past onair_max, with Luna far more interesting, no rotation
    luna.update(interest=60, active="build", activity="acting")
    assert until_onair(d, team, "luna", cut + 1, cut + 260) is None, d.cuts
    # it ends: Sol stands still plan_after (8 s) and Luna moving: the cut comes
    sol.update(active=False, activity="thinking", plan=None)
    def move(now):
        luna["position"] = {"x": now - cut, "y": 0}
    back = until_onair(d, team, "luna", cut + 260, cut + 300, move)
    assert back is not None and back - (cut + 260) <= d.cfg["plan_after"] + d.cfg["ready_s"] + 3, (back, d.cuts)


def model_plan():
    from model import Model
    m = Model({"agents": {"sol": {}}})
    plan = {"kind": "construct", "remaining": 12, "bounds": {"left": 0, "top": 0, "right": 10, "bottom": 10}}
    m.ingest({"agents": [{"name": "sol", "position": {"x": 0, "y": 0}, "active": "construct", "plan": plan}]}, 100)
    a = next(a for a in m.snapshot(100, {})["agents"] if a["name"] == "sol")
    assert a["plan"] == plan, a
    m.ingest({"agents": [{"name": "sol", "position": {"x": 0, "y": 0}, "active": False, "plan": None}]}, 103)
    assert next(a for a in m.snapshot(103, {})["agents"] if a["name"] == "sol")["plan"] is None


def main():
    still_cut()
    nobody_moving()
    scoring()
    lookahead()
    model_plan()
    print("still: ok (a still character gives way to a moving one after 25 s, no ping-pong for 60 s; thinking-still "
          "scores like idle; a big action is scored up, framed to its bounds, held while it runs; model carries plans)")


if __name__ == "__main__":
    main()
