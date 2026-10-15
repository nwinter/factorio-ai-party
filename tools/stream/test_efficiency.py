#!/usr/bin/env python3
"""Machines at work on stream (Nick 15:50; efficiency.lua): python3 tools/stream/test_efficiency.py

1. efficiency.py: a read is a row in runs/RUN/efficiency.jsonl; the card's view keeps the team's agents with machines
   or items and the "built before the count" row apart; an agent's line; the agent for each card in turn; a notable
   change (machines working by a fifth and 10 or more, the share moved by machines by 10 points).
2. live.py reads `efficiency` as the operator every 5 minutes once `describe` lists it and appends the row.
3. segments.py: the "efficiency" card is due every 30 minutes at a free slot, the team's numbers and one agent's line,
   the next agent each time; unavailable while no machine is counted; the hosts get its facts and a neutral call.
4. model.py keeps the read and gives the hosts a notable change against the read 30 minutes before; caster.py puts it
   in the facts as machines_news.
"""
import os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import efficiency  # noqa: E402
import live  # noqa: E402
import model  # noqa: E402
from segments import Segments  # noqa: E402


def agent(name, items_shift, machines=0, running=0, share=None, hand=0):
    return {"name": name, "items": items_shift * 3, "items_shift": items_shift, "machines": machines, "running": running,
            "machine_share_pct": share, "hand_items_shift": hand, "ore_about": 0, "top_items": []}


def read(running=40, share=80, **more):
    agents = [agent("sol", 12000, 30, 25, 82, 2600), agent("grok", 0, 0, 0, None, 50), agent("astra", 3000, 12, 10, 60, 2000),
              agent("nick", 9, 1, 1), dict(agent(efficiency.BEFORE, 900, 200, 150), before=True)]
    return {"tick": 600, "team": {"items_shift": 15909, "machines": 243, "running": running, "machine_share_pct": share,
                                  "ore_about": 5000, **more}, "agents": agents, "walk": {"pass": 3}, "shift": {"seq": 2}}


def check_rows(tmp):
    path = efficiency.path_for(tmp)
    row = efficiency.append(path, read(), 1000.04)
    assert row["t"] == 1000.0 and row["team"]["machines"] == 243
    assert efficiency.append(path, {"error": "x"}, 1001) is None
    with open(path, "a") as f:
        f.write("not json\n")
    efficiency.append(path, read(), 1300)
    assert len(efficiency.read_rows(path)) == 2
    v = efficiency.view(row, {"sol", "grok", "astra"})
    # the team's agents with machines or items, by name; the before-the-count row apart; nick is not on the team
    assert [a["name"] for a in v["agents"]] == ["astra", "grok", "sol"], v["agents"]
    assert v["before"]["machines"] == 200 and v["team"]["running"] == 40
    sol = v["agents"][2]
    assert efficiency.agent_line(sol, str.title) == "Machines Sol built made 12k items this shift; 82% of Sol's items moved by machines"
    assert efficiency.agent_line(agent("grok", 950), str.title) == "Machines Grok built made 950 items this shift"
    # the agent for each card: in turn among those whose machines made something
    assert [efficiency.pick(v["agents"], t)["name"] for t in range(3)] == ["astra", "sol", "astra"]
    assert efficiency.pick([], 0) is None
    assert efficiency.fmt(12000) == "12k" and efficiency.fmt(41500) == "41.5k" and efficiency.fmt(9000) == "9,000"
    # notable: machines working 40 -> 52 (+12, 30%); the share 80 -> 66
    then, now = efficiency.view(row), efficiency.view(efficiency.append(None, read(running=52, share=66), 3000))
    n = efficiency.notable(then, now)
    assert n == {"machines_working_now": 52, "machines_working_30_min_ago": 40, "share_moved_by_machines_now_pct": 66,
                 "share_moved_by_machines_30_min_ago_pct": 80}, n
    assert efficiency.notable(then, efficiency.view(efficiency.append(None, read(running=45, share=75), 3000))) is None
    assert efficiency.notable(None, now) is None


class FakeHarness:
    def __init__(self):
        self.reads = []

    def operator_read(self, action, args=None):
        self.reads.append(action)
        return read(), None


def check_live(tmp):
    h = FakeHarness()
    src = live.LiveSource.__new__(live.LiveSource)
    src.h, src.agents_cfg = h, {"sol": {}, "astra": {}}
    src.has_efficiency, src.next_efficiency = True, 0
    src.efficiency_path = efficiency.path_for(tmp)
    obs, errors = {}, {}
    src.observe_efficiency(obs, errors)
    assert h.reads == ["efficiency"] and not errors
    assert [a["name"] for a in obs["efficiency"]["agents"]] == ["astra", "sol"], obs["efficiency"]
    obs = {}
    src.observe_efficiency(obs, errors)  # within 5 minutes: no read
    assert len(h.reads) == 1 and "efficiency" not in obs
    assert src.next_efficiency > time.time() + efficiency.READ_EVERY - 5
    assert len(efficiency.read_rows(efficiency.path_for(tmp))) == 1
    off = live.LiveSource.__new__(live.LiveSource)
    off.h, off.has_efficiency, off.next_efficiency = h, False, 0
    off.observe_efficiency({}, errors)
    assert len(h.reads) == 1  # a runtime without the read: nothing asked

    class Broken:
        def operator_read(self, action, args=None):
            raise RuntimeError("rcon closed")
    bad = live.LiveSource.__new__(live.LiveSource)
    bad.h, bad.has_efficiency, bad.next_efficiency, bad.efficiency_path = Broken(), True, 0, None
    errs = {}
    bad.observe_efficiency({}, errs)
    assert errs["efficiency"] == "rcon closed" and bad.next_efficiency <= time.time() + 61


def snap_with(view):
    return {"agents": [{"name": "sol", "display_name": "Sol", "alive": True, "position": {"x": 0, "y": 0}},
                       {"name": "astra", "display_name": "Astra", "alive": True, "position": {"x": 1, "y": 0}}],
            "efficiency": view}


def check_segment():
    now = 10_000.0
    seg = Segments(recap_every=10**9, lull_after=10**9, hauling_every=10**9, tokens_every=10**9)
    seg.last_recap = seg.last_efficiency = seg.last_end = now - 100
    seg.last_start = now - 1000
    snap = snap_with(efficiency.view(read(), {"sol", "astra"}))
    seg.step(snap, now)
    assert seg.public() is None  # not due yet
    empty = snap_with(efficiency.view({"team": {}, "agents": []}))
    seg.step(empty, now + 1800)
    assert seg.public() is None and seg.last_efficiency == now + 1800
    assert seg.why_unavailable("efficiency", empty) == "no machines counted yet"
    t = now + 3600
    seg.step(snap, t)
    assert seg.queue and seg.queue["type"] == "efficiency", seg.queue
    out = seg.step(snap, t + 1)
    assert out and out["title"] == "Machines at work this shift" and out["by"] == "director", out
    f = out["facts"]
    assert f["team_items_this_shift"] == 15909 and f["machines"] == 243 and f["machines_working"] == 40, f
    assert f["moved_by_machines_pct"] == 80 and f["ore_mined_about"] == 5000, f
    first = f["agent"]
    assert f["agent_line"].startswith("Machines " + first + " built made"), f
    # the next card names the next agent
    f2 = seg.build_efficiency({}, snap, t + 2000)[1]
    assert f2["agent"] != first, (first, f2["agent"])
    called = caster.card_facts(dict(out, started=t, ends=t + 15))
    assert called["on_screen_now"]["agent_line"] == f["agent_line"] and "no ranking" in called["how_to_call_it"], called
    # a host may ask for it while machines are counted
    seg3 = Segments(recap_every=10**9, lull_after=10**9)
    seg3.last_start = now - 1000
    seg3.snap = snap
    assert seg3.request({"type": "efficiency"}, now)[0] == 200
    seg3.queue = None
    seg3.snap = empty
    assert seg3.request({"type": "efficiency"}, now + 1000)[1]["why"] == "no machines counted yet"


def check_model():
    m = model.Model({"agents": {"sol": {}}})
    t0 = time.time()
    m.ingest({"efficiency": efficiency.view(read(running=40, share=80))}, now=t0 - 1900)
    m.ingest({"efficiency": efficiency.view(read(running=60, share=80))}, now=t0)
    s = m.snapshot(t0)
    assert s["efficiency"]["team"]["running"] == 60
    assert s["efficiency_news"] == {"machines_working_now": 60, "machines_working_30_min_ago": 40}, s["efficiency_news"]
    f = caster.context_facts(s)
    assert f.get("machines_news") == {"machines_working_now": 60, "machines_working_30_min_ago": 40}, f
    m2 = model.Model({})
    m2.ingest({"efficiency": efficiency.view(read())}, now=t0)
    assert m2.snapshot(t0)["efficiency_news"] is None  # no read 30 minutes back yet


def check_overlay():
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'seg.type === "efficiency"' in js and '"Made by machines"' in js


def main():
    with tempfile.TemporaryDirectory() as tmp:
        check_rows(tmp)
    with tempfile.TemporaryDirectory() as tmp:
        check_live(tmp)
    check_segment()
    check_model()
    check_overlay()
    print("efficiency: ok (the run file, the card's view and lines, live reads every 5 min, the 30-min card, news for the hosts)")


if __name__ == "__main__":
    main()
