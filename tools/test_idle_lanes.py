#!/usr/bin/env python3
"""The idle nudge names the agent's other queue lanes and labels the character's own idleness (d26 batch252 cp2,
Astra 18:00: "Automatic idle report 93963 said idle 11 min / no queue while remote capture plan 391 and
platform:Asterion UM plan 249 had just run 600 s to 68601193/202, and K2 plan 79 remains active. It appears body-only;
please include remote/platform lanes or label character idle to avoid false no-work inference.").

Astra's row at 17:59:49 (runs/shift82 nudges.jsonl, tell 93963) with the lanes idle.lua now reports (tests/
d26_batch252.lua builds the same lanes from the queues): the text says "your character idle", "Body queue", and the
remote and platform lanes with their plans, steps and steps done; facts only, at most 500 bytes. A harness without
lanes: no lanes part. (d27 batch286 IL) Astra's shift88 row with platform:Resolute working: no idle nudge, the why logged
once; with the lane idle, or an unanswered tell or a mention open, the nudge goes. No game, no clock:
python3 tools/test_idle_lanes.py. Fails on main (shift88: Astra's row nudged).
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import idle_nudge as N  # noqa: E402

LANES = [
    {"lane": "body", "state": "paused", "steps": 0, "done": 0},
    {"lane": "remote", "state": "empty", "steps": 0, "done": 2, "plan": {"id": 391, "name": "capture"}, "last_done_s": 10},
    {"lane": "platform:Asterion", "state": "empty", "steps": 0, "done": 1, "plan": {"id": 249, "name": "UM"}, "last_done_s": 15},
    {"lane": "platform:K2", "state": "running", "steps": 2, "loop": True, "done": 0, "plan": {"id": 79, "name": "K2 ammo"},
     "step": {"action": "wait_ticks", "label": "settle", "left_s": 30}},
]


def astra(**kw):
    r = {"name": "astra", "standing_s": 11 * 60, "alive": True, "action": None, "queue": {"state": "paused", "steps": 0},
         "unread_chat": 0, "unread_mentions": 1, "unread_tells": 1, "unacked_tells": 2, "unacked_oldest_s": 120,
         "unread_board": 0, "orders": {"set": 1, "armed": "fish-heal"}, "lanes": LANES, "lanes_active": ["platform:K2"],
         "counted": {"minutes": 10, "text": "last 10 min: 0 game actions (other lanes' steps done: remote 2, "
                     "platform:Asterion 1), 46 reads, 17 messages; working 0%, asleep 34% (sleep 50 x8, sleep 20 x1), "
                     "waiting 0%, standing 66%"},
         "open": "open for you: 5 requests or tells to you unanswered (tell from sol 1s ago: K2Ftrace68602208..223)"}
    r.update(kw)
    return r


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("ok", what)


# (d27 batch286 IL) Astra's row at 16:49:44 (runs/shift88 nudges.jsonl, tell 98907): standing 11 min, asleep 96%
# (sleep 30 x23) while platform:Resolute ran plan 23 (14 steps done in 10 min, a wait_until step running).
RESOLUTE = [{"lane": "body", "state": "empty", "steps": 0, "done": 0},
            {"lane": "remote", "state": "empty", "steps": 0, "done": 0},
            {"lane": "platform:Resolute", "state": "running", "steps": 3, "done": 14, "plan": {"id": 23},
             "step": {"action": "wait_until", "left_s": 503}}]


def astra88(**kw):
    r = {"name": "astra", "standing_s": 11 * 60, "alive": True, "action": None, "queue": {"state": "empty", "steps": 0},
         "unread_chat": 0, "unread_mentions": 0, "unread_tells": 0, "unacked_tells": 0, "unread_board": 0,
         "orders": {"set": 2, "armed": "fish-heal, resolute-dock-ammo"}, "lanes": RESOLUTE,
         "counted": {"minutes": 10, "text": "last 10 min: 0 game actions, 1 queue step done (other lanes' steps done: "
                     "platform:Resolute 14), 55 reads, 19 messages; working 0%, asleep 96% (sleep 30 x23), waiting 0%, "
                     "standing 4%"},
         "open": "open for you: 5 board items of yours (#2207 Build a sustainable full-route Shattered Planet expedition [doing])"}
    r.update(kw)
    return r


def shift88():
    t0 = 1793150000.0
    sent, rows = [], []

    def send(name, text):
        sent.append((name, text))
        return {"seq": len(sent)}

    n = N.Nudger(["astra"], start=t0 - 3600)
    out = n.step({"agents": [astra88()]}, t0, send, rows.append)
    check(not sent and len(out) == 1 and out[0]["skipped"] and out[0]["why"] == "lanes working: platform:Resolute 14",
          "Astra's 16:49 row: no idle nudge; why logged (lanes working: platform:Resolute 14)")
    n.step({"agents": [astra88(lanes=[RESOLUTE[0], RESOLUTE[1], dict(RESOLUTE[2], done=13)])]}, t0 + 60, send, rows.append)
    check(len(rows) == 1 and not sent, "logged once while the same lanes work (the count changes every poll)")
    # 15:58: the lane running a wait_until step, none done yet
    n2 = N.Nudger(["astra"], start=t0 - 3600)
    out = n2.step({"agents": [astra88(lanes=[RESOLUTE[0], dict(RESOLUTE[2], done=0)])]}, t0, send, [].append)
    check(not sent and out[0]["why"] == "lanes working: platform:Resolute running", "a lane step running now: no idle nudge")
    # the same row with 0 lane steps and nothing running: nudged as before
    idle = [RESOLUTE[0], RESOLUTE[1], dict(RESOLUTE[2], state="empty", done=0, steps=0, step=None)]
    n3 = N.Nudger(["astra"], start=t0 - 3600)
    out = n3.step({"agents": [astra88(lanes=idle)]}, t0, send, [].append)
    check(len(sent) == 1 and sent[0][1].startswith("Operator (automatic, facts only): your character idle for 11 min")
          and out[0]["sent"], "0 lane steps and nothing running: the idle nudge")
    # an actionable item (16:20: a tell from haiku unanswered) still nudges while the lane works
    n4 = N.Nudger(["astra"], start=t0 - 3600)
    out = n4.step({"agents": [astra88(open="open for you: 1 request or tell to you unanswered (tell from haiku 47s ago: "
                                           "haiku: inspected 96.5,-19.5)")]}, t0, send, [].append)
    check(len(sent) == 2 and out[0].get("sent") and "Other lanes: platform:Resolute running" in sent[1][1]
          and "unanswered" in sent[1][1], "an unanswered tell still nudges, the lanes named")
    n5 = N.Nudger(["astra"], start=t0 - 3600)
    n5.step({"agents": [astra88(unread_mentions=2, unread_tells=0)]}, t0, send, [].append)
    check(len(sent) == 3, "an unread mention still nudges")
    # the lanes stop working: the skip ends and the idle nudge goes
    n.step({"agents": [astra88(lanes=idle)]}, t0 + 120, send, rows.append)
    check(len(sent) == 4 and "astra" not in n.lane_skip, "the lanes done: the idle nudge goes")


def main():
    t = N.nudge_text(astra())
    check(t.startswith("Operator (automatic, facts only): your character idle for 11 min (no action, no body queue step). "),
          "the character's own idleness, labelled")
    check("Body queue: paused with 0 steps. Other lanes: remote empty (last plan 391 capture; 2 steps done in 10 min); "
          "platform:Asterion empty (last plan 249 UM; 1 step done in 10 min); platform:K2 running (plan 79 K2 ammo; step "
          "wait_ticks settle, 30 s left; repeating)." in t, "the other lanes: plans, steps, steps done, the running one")
    check(len(t.encode()) <= N.TELL_MAX, "at most 500 bytes")
    for word in ("should", "please", "consider"):
        check(word not in t.lower(), f"facts only: no '{word}'")
    t = N.nudge_text(astra(lanes=[{"lane": "body", "state": "empty", "steps": 0, "done": 0}], lanes_active=None))
    check("Body queue: paused with 0 steps. Other lanes: none running." in t, "only a body lane: none running")
    t = N.nudge_text(astra(lanes=None))
    check("Other lanes" not in t, "a harness without lanes: no lanes part")
    many = [{"lane": f"platform:Ship-{i:02d}", "state": "running", "steps": 9, "done": 40,
             "plan": {"id": 1000 + i, "name": "a long plan name " * 3}, "step": {"action": "wait_until", "label": "x" * 40}}
            for i in range(12)]
    t = N.nudge_text(astra(lanes=many))
    check(len(t.encode()) <= N.TELL_MAX and "your character idle for 11 min" in t and "Other lanes: platform:Ship-00 running" in t,
          "twelve long lanes: still 500 bytes, the counts kept, cut at a word")
    shift88()
    print("test_idle_lanes: all ok")


if __name__ == "__main__":
    main()
