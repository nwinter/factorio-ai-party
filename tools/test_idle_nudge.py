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


def sonnet_shift07():
    """Sonnet, shift07 15:13-16:24 (its journal: tools/idle_nudge_sonnet_shift07.json): plan_run loop3, queue_resume,
    then a direct wait_ticks of 20000 or 30000 ticks, again and again; each wait held the plan back, which ran a few
    seconds between waits. The nudge started 15:13:50 and logged nothing in 70 minutes (viewer Joonazan 16:24: "Sonnet
    hasn't done anything except wait"). Replayed through idle_report rows as the shift07 harness gave them (waits
    were work there: standing 0, the queue "running"), one poll a minute as the nudge runs."""
    import datetime as dt
    data = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "idle_nudge_sonnet_shift07.json")))
    ev = [(dt.datetime.fromisoformat(e["at"].replace("Z", "+00:00")).timestamp(), e) for e in data["events"]]
    start = dt.datetime.fromisoformat("2026-10-13T22:13:50+00:00").timestamp()
    end = dt.datetime.fromisoformat("2026-10-13T23:24:30+00:00").timestamp()
    n = N.Nudger(["sonnet"], start=start)
    sent, logged = [], []
    last_request, unread = start, 0

    def send(name, text):
        sent.append(text)
        return {"seq": len(sent)}
    t = start
    while t <= end:
        act, queued = None, False
        for at, e in ev:
            if at > t:
                break
            if "active" in e:
                act = e["active"]
            if e.get("request") == "plan_run":
                queued = True
            if e.get("request") in ("wait_ticks", "queue_resume") and at > last_request:
                last_request = at
                unread = 0  # a reply carries the team block, tells included
        r = row("sonnet", 0, action=act, queue={"state": "running", "steps": 7} if queued else {"state": "none"},
                unread_tells=unread, last_request_s=t - last_request)
        for e in n.step({"agents": [r]}, t, send, logged.append):
            unread += 1
        t += 60
    times = [dt.datetime.fromisoformat(e["t"]).astimezone(dt.timezone.utc).strftime("%H:%M") for e in logged]
    assert times == ["22:23", "22:43", "23:03", "23:23"], times  # 15:23, 15:43, 16:03, 16:23 PDT: 10 min in, then 20
    assert logged[0]["action"] == "wait_ticks" and "in wait_ticks, your queue's 7 steps start only after it" in sent[0], \
        sent[0]
    # its replies carried each tell (it kept making requests): delivered, though it reads 2 lines of each reply
    assert all(e["since_last_nudge"] == {"tell_delivered": True, "requests": True} for e in logged[1:]), logged


def main():
    sent, rows = [], []
    send = lambda name, text: sent.append((name, text)) or {"seq": len(sent)}  # noqa: E731
    n = N.Nudger(["sonnet", "astra", "luna"], start=T0, deadline=T0 + 3600)

    # shift05's Sonnet: 25 minutes standing between sleeps, 7 unread chat lines, 2 mentions, a tell, a paused queue
    sonnet = row("sonnet", 25, sleeping_s=600, queue={"state": "paused", "steps": 3}, unread_chat=7,
                 unread_mentions=3, unread_tells=1)
    report = {"agents": [sonnet, row("astra", 0, action="mine"), row("luna", 12, action="wait_until"), row("nick", 40)]}
    assert n.step(report, T0 + 120, send, rows.append) == [] and not sent, "not in the first 5 minutes of the shift"
    out = n.step(report, T0 + 400, send, rows.append)
    # astra mining; luna in a wait (not work: shift07), nick not on the team. The same report twice: this process's
    # own count has gone on 280 s since it first saw them (25 + 4.7 min)
    assert [e["agent"] for e in out] == ["sonnet", "luna"], out
    assert sent[0][1] == ("Operator (automatic, facts only): idle for 30 min (no action, no queue step, sleeping 10 min). "
                          "Unread for you: 7 chat messages, 2 mentions, 1 tell. Queue: paused with 3 steps."), sent[0][1]
    assert sent[1][1].startswith("Operator (automatic, facts only): idle for 17 min (in wait_until). Unread for you: "), sent[1][1]
    assert sent[1][1].endswith("Queue: none."), sent[1][1]
    e = rows[0]
    assert e["sent"] and e["tell_seq"] == 1 and e["standing_min"] == 30 and e["queue"] == "paused with 3 steps" \
        and e["sleeping_min"] == 10 and e["unread"]["unread_chat"] == 7 and "since_last_nudge" not in e, e
    # at most once per 20 minutes per agent, then again
    assert n.step(report, T0 + 400 + 19 * 60, send, rows.append) == []
    again = n.step(report, T0 + 400 + 20 * 60, send, rows.append)
    assert [x["agent"] for x in again] == ["sonnet", "luna"]
    # since the last nudge: Sonnet's tell still unread (its replies went to a file), Luna's delivered
    assert again[0]["since_last_nudge"] == {"tell_delivered": False, "requests": True}, again[0]
    assert again[1]["since_last_nudge"] == {"tell_delivered": True, "requests": True}, again[1]
    # 10 minutes is the line; a dead character, work or a running queue is not idle; a wait is
    assert n.due(row("astra", 9.9), T0 + 900) == "active" and n.due(row("astra", 10), T0 + 900) is None
    assert n.due(row("astra", 30, alive=False), T0 + 900) == "active"
    assert n.due(row("astra", 30, action="wait_ticks"), T0 + 900) is None
    assert n.due(row("astra", 30, action="mine"), T0 + 900) == "in an action"
    assert n.due(row("astra", 30, queue={"state": "running", "steps": 2}), T0 + 900) == "in an action"
    assert n.due(row("astra", 30, action="wait_ticks", queue={"state": "running", "steps": 7}), T0 + 900) is None
    assert n.due(row("astra", 30), T0 + 3600) == "after the deadline"
    # a standing order running for the agent is work (orders.lua; the report's orders.running), never a nudge
    assert n.due(row("astra", 30, orders={"set": 2, "running": "restock-ammo"}), T0 + 900) == "running a standing order"
    assert n.due(row("astra", 30, orders={"set": 2}), T0 + 900) is None
    t = N.nudge_text(row("astra", 12, orders={"set": 2}))
    assert t.endswith("Queue: none. Standing orders: 2 set, none running."), t
    assert "Standing orders: 1 set, paused." in N.nudge_text(row("astra", 12, orders={"set": 1, "paused": True}))
    t = N.nudge_text(row("astra", 12, orders={"set": 1, "paused": True, "operator_paused": True}))
    assert "Standing orders: 1 set, paused by the operator." in t, t
    assert "Standing orders" not in N.nudge_text(row("astra", 12))
    # armed orders (d17 batch16 A5, cp4): the nudge still fires (standing accrues), and its text names the orders on watch
    armed = {"set": 2, "armed": "rearm, refuel"}
    assert n.due(row("astra", 30, action="sleep", sleeping_s=1800, orders=armed), T0 + 900) is None
    t = N.nudge_text(row("haiku", 30, action="sleep", sleeping_s=1800, orders=armed))
    assert "Standing orders: 2 set, none running; on watch: rearm, refuel." in t and "sleeping 30 min" in t, t
    # an order that ran a while does not leave this process's own count standing when it ends
    o = N.Nudger([], start=T0)
    o.observe(row("astra", 0, orders={"set": 1, "running": "restock-ammo"}), T0 + 600)
    o.observe(row("astra", 0, orders={"set": 1, "running": "restock-ammo"}), T0 + 610)
    o.observe(row("astra", 0, orders={"set": 1}), T0 + 1800)
    assert o.standing(row("astra", 0), T0 + 1800) == 0, o.idle_since
    sonnet_shift07()
    # One definition of idle (agent-minds study, fix 2): a harness that reports what it counted is the only count (its
    # standing ended on Grok's short walks: this process, polling once a minute, never sees them); the text says what
    # was counted and what idle means.
    k = N.Nudger(["grok"], start=T0)
    counted = {"text": "last 10 min: 0 game actions (and 35 with no effect), 12 reads, 2 messages; working 0%, asleep "
                       "79% (sleep 300 x2), waiting 0%, standing 21%", "actions": 0}
    for i in range(12):
        k.observe(row("grok", 0, counted=counted), T0 + 60 * i)
    assert k.standing(row("grok", 0, counted=counted), T0 + 720) == 0, "the harness's standing, not this process's own"
    assert k.standing(row("grok", 0), T0 + 720) >= 660, "an older harness: the longer one"
    t = N.nudge_text(row("haiku", 12, counted=counted))
    assert t.endswith("Queue: none. Counted, last 10 min: 0 game actions (and 35 with no effect), 12 reads, 2 messages; "
                      "working 0%, asleep 79% (sleep 300 x2), waiting 0%, standing 21%. Idle: a wait or sleep counts; a "
                      "game action that changed something, a move to a new spot or 20 s of work in 2 min ends it."), t
    logged = []
    N.Nudger(["haiku"], start=T0).step({"agents": [row("haiku", 12, counted=counted)]}, T0 + 600, send, logged.append)
    assert logged[0]["counted"] == counted["text"], logged
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
    assert "0 chat messages, 0 mentions, 0 tells, 2 board lines. Queue: none." in t and "should" not in t and "please" not in t, t
    # (d23 batch121 CD1, viewer Aurora site:4387, 4406) the unread chat lines naming it, and the tells shown in a team
    # block but not acknowledged, apart from those pending delivery, with the oldest's age
    t = N.nudge_text(row("opus", 11, unread_chat=158, unread_chat_to_you=3, unread_tells=1, unread_mentions=1,
                         unacked_tells=4, unacked_oldest_s=1500))
    assert ("Unread for you: 158 chat messages (3 naming you), 0 mentions, 1 tell, "
            "4 tells shown, not acknowledged (oldest 25 min). Queue: none.") in t, t
    assert "naming you" not in N.nudge_text(row("opus", 11, unread_chat=0, unread_chat_to_you=0))
    # what is open for the agent (open.lua, d15 H3) ends the text; a harness before it sends none
    t = N.nudge_text(row("sonnet", 12, open="open for you: 1 board item of yours (#425 purple science [doing])"))
    assert t.endswith("Queue: none. Open for you: 1 board item of yours (#425 purple science [doing])."), t
    assert "Open for you" not in N.nudge_text(row("sonnet", 12))
    # (d20 batch70 AF1) Haiku d21 12:11:50: nudged 72 s into a 120 s uptime watch Astra had asked of it. A harness
    # that reports the watch running (measuring) is busy with it; one late, stalled, invalid or with its final unread
    # is named in the tell, as the harness's line.
    h = N.Nudger([], start=T0)
    hk = row("haiku", 11, measuring="uptime@42660741", counted={"text": "last 10 min: 0 game actions; measuring 80% (uptime@42660741)"})
    assert h.due(hk, T0 + 900) == "measuring (uptime@42660741)", h.due(hk, T0 + 900)
    assert h.step({"agents": [hk]}, T0 + 900, lambda n, t: {"seq": 1}, lambda e: None) == []
    late = {"id": "uptime@42744959", "state": "late", "end_tick": 42780959, "line": "uptime@42744959 1 machine (processing-unit 1) "
            "from (-40,-91): late: its end tick 42780959 passed 20 s ago and no final result came; it is not counted as work; 590 samples."}
    done_read = {"id": "turret_tally@1", "state": "done", "final_read": True, "line": "turret_tally@1 ..."}
    unread = {"id": "belt_flow@2", "state": "done", "final_read": False, "line": "belt_flow@2 belt line (0.5,0.5) to (0.5,9.5) "
              "(10 tiles) on nauvis: done at tick 900, its final not read yet (belt_flow {} reads it); 75 samples"}
    t = N.nudge_text(row("haiku", 12, measures=[late, done_read, unread]))
    assert ("Queue: none. Watches: uptime@42744959 1 machine (processing-unit 1) from (-40,-91): late: its end tick 42780959 "
            "passed 20 s ago and no final result came; it is not counted as work; 590 samples; belt_flow@2 belt line") in t, t
    assert "turret_tally@1" not in t and t.count("Watches:") == 1, t
    assert "Watches" not in N.nudge_text(row("haiku", 12, measures=[done_read]))
    logged = []
    h.step({"agents": [row("haiku", 12, measures=[late])]}, T0 + 960, lambda n, t: {"seq": 2}, logged.append)
    assert logged[0]["watches"] == [{"id": "uptime@42744959", "state": "late", "end_tick": 42780959, "final_read": None}], logged
    # (operator d21 13:18) the agent's own reason to wait, given with its sleep, quoted as given; nothing suggested
    t = N.nudge_text(row("haiku", 12, sleeping_s=60, sleep_reason="waiting for astra's go on the wall."))
    assert t.endswith("Queue: none. Your reason to wait (your sleep): waiting for astra's go on the wall."), t
    assert "reason" not in N.nudge_text(row("haiku", 12))
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
