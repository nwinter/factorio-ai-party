#!/usr/bin/env python3
"""The idle nudge's rules and text (tools/idle_nudge.py), without a game: python3 tools/test_idle_nudge.py

The harness side (idle_report, the operator tell) is vendor/factorio-harness/tests/idle.lua.
"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import idle_nudge as N  # noqa: E402

T0 = 1_800_000_000.0


def row(name, standing_min, **kw):
    r = {"name": name, "standing_s": standing_min * 60, "alive": True, "action": None, "queue": {"state": "none"},
         "unread_chat": 0, "unread_mentions": 0, "unread_tells": 0, "unread_board": 0, "last_request_s": 30}
    r.update(kw)
    return r


def main():
    sent, rows = [], []
    send = lambda name, text: sent.append((name, text)) or {"seq": len(sent)}  # noqa: E731
    n = N.Nudger(["sonnet", "astra", "luna"], start=T0, deadline=T0 + 3600)

    # shift05's Sonnet: 25 minutes standing between sleeps, 7 unread chat lines, 2 mentions, a tell, a paused queue
    sonnet = row("sonnet", 25, sleeping_s=600, queue={"state": "paused", "steps": 3}, unread_chat=7,
                 unread_mentions=3, unread_tells=1)
    report = {"agents": [sonnet, row("astra", 3), row("luna", 12, action="wait_until"), row("nick", 40)]}
    assert n.step(report, T0 + 120, send, rows.append) == [] and not sent, "not in the first 5 minutes of the shift"
    out = n.step(report, T0 + 400, send, rows.append)
    assert [e["agent"] for e in out] == ["sonnet"], out  # astra 3 min, luna in a timed action, nick not on the team
    assert sent[0][1] == ("Operator (automatic, facts only): your character has stood idle for 25 min (no action, no "
                          "queue step, sleeping 10 min). Queue: paused with 3 steps. Unread for you: 7 chat messages, "
                          "2 mentions, 1 tell."), sent[0][1]
    e = rows[0]
    assert e["sent"] and e["tell_seq"] == 1 and e["standing_min"] == 25 and e["queue"] == "paused with 3 steps" \
        and e["sleeping_min"] == 10 and e["unread"]["unread_chat"] == 7, e
    # at most once per 20 minutes per agent, then again
    assert n.step(report, T0 + 400 + 19 * 60, send, rows.append) == []
    assert [x["agent"] for x in n.step(report, T0 + 400 + 20 * 60, send, rows.append)] == ["sonnet"]
    # 10 minutes is the line; a dead character, an action or a running queue is not idle
    assert n.due(row("astra", 9.9), T0 + 900) == "active" and n.due(row("astra", 10), T0 + 900) is None
    assert n.due(row("astra", 30, alive=False), T0 + 900) == "active"
    assert n.due(row("astra", 30, action="wait_ticks"), T0 + 900) == "in an action"
    assert n.due(row("astra", 30), T0 + 3600) == "after the deadline"
    # a standing order running for the agent is work (orders.lua; the report's orders.running), never a nudge
    assert n.due(row("astra", 30, orders={"set": 2, "running": "restock-ammo"}), T0 + 900) == "running a standing order"
    assert n.due(row("astra", 30, orders={"set": 2}), T0 + 900) is None
    t = N.nudge_text(row("astra", 12, orders={"set": 2}))
    assert "Queue: none. Standing orders: 2 set, none running. Unread for you:" in t, t
    assert "Standing orders: 1 set, paused." in N.nudge_text(row("astra", 12, orders={"set": 1, "paused": True}))
    t = N.nudge_text(row("astra", 12, orders={"set": 1, "paused": True, "operator_paused": True}))
    assert "Standing orders: 1 set, paused by the operator." in t, t
    assert "Standing orders" not in N.nudge_text(row("astra", 12))
    # a send that fails is logged and tried again at the next poll (not counted as a nudge)
    m = N.Nudger([], start=T0)
    bad = []
    def boom(name, text):
        raise RuntimeError("operator requests support board, ...")
    m.step({"agents": [row("grok", 15)]}, T0 + 600, boom, bad.append)
    assert bad[0]["sent"] is False and "operator requests" in bad[0]["error"] and "grok" not in m.last
    assert m.due(row("grok", 15), T0 + 660) is None
    # board lines show when there are any; no advice in the text
    t = N.nudge_text(row("opus", 11, unread_board=2))
    assert t.endswith("0 chat messages, 0 mentions, 0 tells, 2 board lines.") and "should" not in t and "please" not in t, t
    # the run's members and deadline from its files
    d = tempfile.mkdtemp()
    open(os.path.join(d, "panes.txt"), "w").write("astra w1:1 codex\nsonnet w1:2 claude\n")
    os.makedirs(os.path.join(d, "astra"))
    open(os.path.join(d, "astra", "deadline.txt"), "w").write("2026-10-13 10:56 PDT\n")
    assert N.team_members(d) == ["astra", "sonnet"]
    dl = N.run_deadline(d)
    assert dl and N.time.strftime("%Y-%m-%d %H:%M", N.time.localtime(dl)) == "2026-10-13 10:56", dl
    json.dumps(rows)  # the log rows are JSON
    print("idle nudge: ok (grace, 10 min, 20 min cooldown, deadline, team only, actions, standing orders and the dead "
          "skipped, facts text, failures retried, log rows)")


if __name__ == "__main__":
    main()
