#!/usr/bin/env python3
"""Agent cards' current work and stale plan line or focus (d20 batch70 AF3, viewer Aurora, d21 15:07: "Could agent
cards show the engineer's own current task plus background tests/deadlines, and flag stale plan/focus text? Sonnet's
plan still says free while sampling Cinder"): python3 tools/stream/test_workcard.py

1. RepeatFeed: the same request at a steady interval from the journal (Sonnet's `platform Cinder` every 60 s), a
   broken rhythm starting a new run, housekeeping actions never counted, gone once the requests stop.
2. workcard.rows and stale: a watch with its end and latest sample, queue steps with their run, a standing order, a
   repeating request; a plan line or focus set before the work began (after a grace), or old and not naming a test.
3. Model: work, plan_line beside a focus, stale; the sleep's own reason on the wait card, kept through sleep_checks.
4. live.py asks status {brief, alerts, work}, and without work from a runtime that refuses it; push_live keeps the
   cards' work within its byte budget; live.js draws it.
"""
import json
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
import workcard as wc  # noqa: E402
from waitcard import WaitFeed  # noqa: E402
from model import Model  # noqa: E402

NOW = 1792620426.0  # 15:07:06 PDT, Aurora's message
TICK = 43248000
MIN = 3600  # ticks


def at(t):
    return datetime.fromtimestamp(t, timezone.utc).isoformat().replace("+00:00", "Z")


def pair(feed, agent, n, action, args, t, tick):
    feed.ingest(agent, {"at": at(t), "event": "request", "request": {"id": str(n), "action": action, "args": args}})
    feed.ingest(agent, {"at": at(t + 0.1), "event": "response", "response": {"id": str(n), "ok": True, "tick": tick, "result": {}}})


def repeats():
    f = wc.RepeatFeed()
    start = NOW - 14 * 60
    n = 0
    for i in range(15):  # 14:53 to 15:07, a read a minute, sleeps and its own chat between
        t = start + 60 * i + (1 if i % 3 == 0 else 0)
        pair(f, "sonnet", n, "platform", {"name": "Cinder"}, t, TICK - 14 * MIN + i * MIN); n += 1
        pair(f, "sonnet", n, "sleep", {"seconds": 900, "peek": True}, t + 5, TICK); n += 1
        pair(f, "sonnet", n, "chat", {}, t + 7, TICK); n += 1
        pair(f, "sonnet", n, "chat_ack", {}, t + 8, TICK); n += 1
        pair(f, "sonnet", n, "uptime", {}, t + 9, TICK); n += 1
    cur = f.current("sonnet", NOW)
    assert len(cur) == 1, cur
    r = cur[0]
    assert (r["action"], r["target"], r["every_s"], r["n"], r["since_tick"]) == ("platform", "Cinder", 60, 15, TICK - 14 * MIN), r
    assert r["since_s"] == 14 * 60 - 1, r  # the first reply came at 14:53:01
    assert f.current("sonnet", NOW + 131) == [], "gone once two intervals and 10 s pass with none"
    assert f.current("sonnet", NOW + 129)
    # three reads are not yet a rhythm; a broken one starts again from the last read
    g = wc.RepeatFeed()
    for i, t in enumerate((0, 60, 120)):
        pair(g, "luna", i, "inspect", {"position": {"x": 3, "y": -4}}, NOW + t, TICK)
    assert g.current("luna", NOW + 120) == []
    pair(g, "luna", 3, "inspect", {"position": {"x": 3, "y": -4}}, NOW + 400, TICK)
    pair(g, "luna", 4, "inspect", {"position": {"x": 3, "y": -4}}, NOW + 460, TICK)
    assert g.runs["luna"][next(iter(g.runs["luna"]))]["n"] == 2, "the 280 s gap broke the 60 s rhythm"
    # other arguments are another request; a failed one counts for nothing; operator requests are not the agent's
    h = wc.RepeatFeed()
    for i in range(5):
        pair(h, "astra", 2 * i, "platform", {"name": "Cinder" if i % 2 else "Kestrel"}, NOW + 60 * i, TICK)
    assert h.current("astra", NOW + 240) == []
    h.ingest("astra", {"event": "request", "request": {"id": "op", "action": "inspect", "args": {}, "operator": True}})
    assert "op" not in h.requests["astra"]
    for i in range(300):
        h.ingest("astra", {"event": "request", "request": {"id": f"q{i}", "action": "inspect", "args": {}}})
    assert len(h.requests["astra"]) == 128
    assert wc.target_text({"platform": "Cinder", "position": {"x": 1.5, "y": -2}}) == "Cinder (1.5,-2)"


def rows_and_stale():
    watch = {"id": "uptime@" + str(TICK - 3 * MIN), "kind": "uptime", "scope": "14 machines (iron-plate 14) from (-67,97)",
             "state": "running", "start_tick": TICK - 3 * MIN, "end_tick": TICK + 7 * MIN,
             "latest": {"tick": TICK - 60, "line": "machine samples working 93%, no ingredients 7%"}, "reason": "Astra asked for it"}
    late = {"id": "belt_flow@1", "kind": "belt_flow", "scope": "belt line (1,2) to (9,2) (8 tiles) on nauvis", "state": "late",
            "start_tick": TICK - 20 * MIN, "end_tick": TICK - 12 * MIN}
    queues = {"body": {"active": {"id": 7, "action": "wait_ticks", "label": "let the smelters fill", "started_tick": TICK - 2 * MIN,
                                  "run": {"kind": "submit", "tick": TICK - 6 * MIN, "steps": 3}}, "pending": 2},
              "remote": {"active": {"id": 2, "action": "platform_schedule", "started_tick": TICK - 60,
                                    "run": {"kind": "repeat", "name": "edge-loop", "tick": TICK - 30 * MIN, "steps": 4}}},
              "platforms": {"Edge": {"active": False}}}
    order = {"name": "restock-ammo", "step": 2, "steps": 5, "started_tick": TICK - 90}
    rep = [{"action": "platform", "target": "Cinder", "every_s": 60, "n": 15, "since_s": 840, "since_tick": TICK - 14 * MIN, "last_s": 6}]
    rows = wc.rows([watch, late], queues, order, rep, TICK)
    lines = [r["line"] for r in rows]
    assert lines == [
        "uptime watch uptime@" + str(TICK - 3 * MIN) + ", 14 machines (iron-plate 14) from (-67,97): ends in 7 min; latest: machine samples working 93%, no ingredients 7%; its reason: Astra asked for it",
        "belt_flow watch belt_flow@1, belt line (1,2) to (9,2) (8 tiles) on nauvis: late: ended 12 min ago and no final result came",
        "queue: let the smelters fill, started 2 min ago; 2 more queued; submitted with 3 steps 6 min ago",
        "remote queue: platform schedule, started 1 s ago; repeating job edge-loop 30 min ago",
        "standing order restock-ammo: step 2 of 5, started 1 s ago",
        "repeating request: platform Cinder every 60 s for 14 min (15 so far)",
    ], lines
    assert [r["test"] for r in rows] == [True, False, False, False, False, True]
    # Sonnet at 15:07: its plan line set at 14:13, the Cinder reads from 14:53
    plan = "1689 step3 done; Solstice flight watch (sol), Vulcanus tungsten fixed natively; free for audits"
    only_rep = wc.rows(None, None, None, rep, TICK)
    assert wc.stale([("plan line", TICK - 54 * MIN, plan)], only_rep, TICK) == [
        "plan line set 54 min ago, before its repeating platform Cinder began 14 min ago"]
    # set after the test began: flagged once STALE_TEST_S old if it names none of it; naming it, not flagged
    assert wc.stale([("plan line", TICK - 5 * MIN, plan)], only_rep, TICK) == []
    assert wc.stale([("plan line", TICK - 11 * MIN, plan)], wc.rows(None, None, None, [dict(rep[0], since_tick=TICK - 12 * MIN)], TICK), TICK) == [
        "plan line set 11 min ago does not mention its repeating platform Cinder, running 12 min"]
    assert wc.stale([("plan line", TICK - 11 * MIN, "sampling Cinder hub for 1695")], only_rep, TICK) == []
    w = wc.rows([dict(watch, start_tick=TICK - 20 * MIN)], None, None, None, TICK)
    assert wc.stale([("focus", TICK - 15 * MIN, "#1695 Cinder validation")], w, TICK) == [
        "focus set 15 min ago does not mention its uptime watch, running 20 min"]
    assert wc.stale([("focus", TICK - 15 * MIN, "#1695 uptime of the smelters")], w, TICK) == []
    # a test begun within TEST_GRACE_S, a queue run within RUN_GRACE_S: not yet
    assert wc.stale([("plan line", TICK - 30 * MIN, "x")], wc.rows([watch], None, None, None, TICK), TICK) == [
        "plan line set 30 min ago, before its uptime watch began 3 min ago"]
    young = wc.rows([dict(watch, start_tick=TICK - 60)], None, None, None, TICK)
    assert wc.stale([("plan line", TICK - 5 * MIN, "x")], young, TICK) == []
    assert wc.stale([("plan line", TICK - 30 * MIN, "x")], young, TICK) == [], "an old line, a test 1 s old (the copy, 15:5x)"
    q = wc.rows(None, queues, None, None, TICK)
    assert wc.stale([("plan line", TICK - 8 * MIN, "x")], q, TICK) == ["plan line set 8 min ago, before its queue run began 6 min ago"]
    q4 = wc.rows(None, {"body": dict(queues["body"], active=dict(queues["body"]["active"], run={"kind": "submit", "tick": TICK - 4 * MIN, "steps": 1}))}, None, None, TICK)
    assert wc.stale([("plan line", TICK - 8 * MIN, "x")], q4, TICK) == []
    # the newest work begun after the line is the one named; no tick, no flag
    assert wc.stale([("plan line", TICK - 40 * MIN, "x")], rows, TICK) == ["plan line set 40 min ago, before its uptime watch began 3 min ago"]
    assert wc.stale([("plan line", None, "x")], rows, TICK) == []
    # a paused queue and a step from an earlier submission
    assert wc.rows(None, {"body": dict(queues["body"], paused=True)}, None, None, TICK) == []
    early = wc.rows(None, {"body": {"active": {"action": "build", "started_tick": TICK - 60}}}, None, None, TICK)
    assert early[0]["line"] == "queue: build, started 1 s ago" and early[0]["start_tick"] is None


def model():
    m = Model({"agents": {"sonnet": {}, "haiku": {}}})
    plan = {"goals": "g", "doing": ["sonnet: free for audits", "haiku: smelter uptime for astra"],
            "lines": [{"agent": "sonnet", "tick": TICK - 54 * MIN}, {"agent": "haiku", "tick": TICK - 20 * MIN}]}
    focus = [{"agent": "haiku", "id": 1700, "title": "Smelter output", "tick": TICK - 25 * MIN}]
    rep = [{"action": "platform", "target": "Cinder", "every_s": 60, "n": 15, "since_s": 840, "since_tick": TICK - 14 * MIN, "last_s": 6}]
    watch = {"id": "uptime@1", "kind": "uptime", "scope": "14 machines", "state": "running", "start_tick": TICK - 2 * MIN,
             "end_tick": TICK + 60, "latest": {"tick": TICK, "line": "machine samples working 100%"}}
    m.ingest({"tick": TICK, "agents": [{"name": "sonnet", "repeats": rep}, {"name": "haiku", "watches": [watch], "queues": {}}],
              "board": {"items": [], "plan": plan, "focus": focus}}, NOW)
    m.tick = TICK
    rows = {a["name"]: a for a in m.snapshot(NOW)["agents"]}
    s = rows["sonnet"]
    assert s["job"] == "free for audits" and s["work"] == ["repeating request: platform Cinder every 60 s for 14 min (15 so far)"], s
    assert s["stale"] == ["plan line set 54 min ago, before its repeating platform Cinder began 14 min ago"], s["stale"]
    assert "plan_line" not in s, "the job is the plan line already"
    h = rows["haiku"]
    assert h["job_from"] == "focus" and h["plan_line"] == "smelter uptime for astra" and h["plan_line_label"] == "plan line, set 20 min ago"
    assert h["work"] == ["uptime watch uptime@1, 14 machines: ends in 1 s; latest: machine samples working 100%"], h["work"]
    assert h["stale"] == ["focus set 25 min ago, before its uptime watch began 2 min ago"], h["stale"]
    assert "uptime" in h["plan_line"], "the plan line names the uptime watch: not flagged"
    assert wc.words("let the smelters fill", "edge-loop") == ("smelter", "fill", "edge", "loop")
    q = wc.rows(None, {"body": {"active": {"action": "wait_ticks", "label": "let the smelters fill", "started_tick": TICK - MIN,
                                           "run": {"kind": "submit", "tick": TICK - 6 * MIN, "steps": 3}}}}, None, None, TICK)
    assert wc.stale([("focus", TICK - 25 * MIN, "#1700 Smelter output")], q, TICK) == []
    assert wc.stale([("focus", TICK - 25 * MIN, "#1700 Copper output")], q, TICK) == ["focus set 25 min ago, before its queue run began 6 min ago"]
    # (d23 batch123 CF1) the runtime's marks on a focus and a plan line naming what a board change took away
    mark = 'marked stale 2s ago: step 3 of #1052 edited by astra (was: "Verify ... mash site"); this text names mash, site'
    m2 = Model({"agents": {"luna": {}}})
    m2.ingest({"tick": TICK, "agents": [{"name": "luna"}], "board": {"items": [], "plan": {"goals": "g", "doing": [
        "luna: #1052 hold until a mash site [" + mark + "]"], "lines": [{"agent": "luna", "tick": TICK - MIN, "text": "#1052 hold until a mash site", "stale": mark}]},
        "focus": [{"agent": "luna", "id": 1052, "title": "AG", "tick": TICK - MIN, "blocker": "no mash site", "stale": mark}]}}, NOW)
    m2.tick = TICK
    lu = m2.snapshot(NOW)["agents"][0]
    assert lu["stale"] == ["focus " + mark, "plan line " + mark], lu["stale"]
    assert m2.plan_snapshot()["doing"][0]["text"] == "#1052 hold until a mash site" and m2.plan_snapshot()["doing"][0]["stale"] == mark
    assert m2.project_state({"id": 1052})["focus"][0]["stale"] == mark
    m.ingest({"agents": [{"name": "sonnet", "repeats": []}]}, NOW + 200)
    s = {a["name"]: a for a in m.snapshot(NOW + 200)["agents"]}["sonnet"]
    assert s["work"] is None and s["stale"] is None
    # the sleep's own reason (fh sleep --reason), kept through its sleep_checks, before chat
    wf = WaitFeed()
    def ingest(i, action, args, result, t):
        wf.ingest("haiku", {"event": "request", "request": {"id": i, "action": action, "args": args}})
        wf.ingest("haiku", {"at": at(t), "event": "response", "response": {"id": i, "ok": True, "tick": TICK, "result": result}})
    ingest("a", "sleep", {"seconds": 300, "reason": "uptime@1 ends at tick " + str(TICK + 60)}, {"sleeping_s": 300, "until_tick": TICK + 5 * MIN}, NOW)
    ingest("b", "sleep_check", {}, {"sleeping_s": 280, "until_tick": TICK + 5 * MIN}, NOW + 20)
    wait = wf.current("haiku", TICK, NOW + 20)
    assert wait["reason"] == "uptime@1 ends at tick " + str(TICK + 60), wait
    m.ingest({"agents": [{"name": "haiku", "wait": wait}]}, NOW + 20)
    h = {a["name"]: a for a in m.snapshot(NOW + 20)["agents"]}["haiku"]
    assert h["wait_reason"] == "uptime@1 ends at tick " + str(TICK + 60), h
    ingest("c", "sleep", {"seconds": 300}, {"sleeping_s": 300, "until_tick": TICK + 5 * MIN}, NOW + 30)
    assert "reason" not in wf.current("haiku", TICK, NOW + 30), "a new sleep with none clears it"


def live_and_site():
    from live import LiveSource as Live
    import push_live

    class Fake:
        brief_ok = None
        def __init__(self, refuse): self.refuse, self.asked = refuse, []
        def read(self, action, args=None, **who):
            self.asked.append(dict(args or {}))
            if self.refuse and (args or {}).get("work"):
                raise RuntimeError("unknown argument work for status; valid: brief, alerts, inventory")
            return {"brief": True, "watches": [{"id": "uptime@1"}] if not self.refuse else None}, 1
        def agent_status(self, name, cfg): return Live.agent_status(self, name, cfg)
    f = Fake(False)
    assert Live.agent_status(f, "haiku", {})["watches"] == [{"id": "uptime@1"}]
    assert f.asked == [{"brief": True, "alerts": True, "work": True}] and f.work_ok is True
    old = Fake(True)
    Live.agent_status(old, "haiku", {})
    assert old.asked == [{"brief": True, "alerts": True, "work": True}, {"brief": True, "alerts": True}] and old.work_ok is False
    Live.agent_status(old, "haiku", {})
    assert old.asked[-1] == {"brief": True, "alerts": True}, "not asked again before FOCUS_RETRY"
    old.work_retry_t = 0
    old.refuse = False
    Live.agent_status(old, "haiku", {})
    assert old.asked[-1].get("work") and old.work_ok is True, "asked again after a deploy"
    assert {"work", "plan_line", "plan_line_label", "stale"} <= set(push_live.AGENT_KEYS)
    agents = [{"name": "a", "work": ["x" * 190] * 4}, {"name": "b", "work": ["y" * 190] * 2}, {"name": "c"}]
    push_live.agent_work(agents, limit=800)
    assert [len(a.get("work") or []) for a in agents] == [2, 2, 0] and agents[0]["work_cut"] == 2, agents
    assert sum(len(json.dumps(a.get("work") or [])) for a in agents) <= 800
    code = open(os.path.join(HERE, "..", "..", "site", "static", "live.js")).read()
    assert "jobHtml(a) + workHtml(a)" in code and "a.plan_line_label" in code and "a.stale" in code


def main():
    repeats()
    rows_and_stale()
    model()
    live_and_site()
    print("work cards: ok (repeating requests, watches, queue runs, standing order; stale plan line and focus with the "
          "times; sleep reason; status work asked and its fallback; site budget)")


if __name__ == "__main__":
    main()
