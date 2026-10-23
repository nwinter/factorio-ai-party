#!/usr/bin/env python3
"""Backlog lines after a stream restart are history, not news: python3 tools/stream/test_backlog.py

d22 batch111 BU1 (Nick: a Sol line "keeps coming back onto the stream at weird random times throughout the past few
days"): Sol's confessional seq 67 (tick 10291268) and Astra's seq 65 (tick 8953890) were voiced at every caster start
in shift52-60, because live.py reads confessions from 0 after a restart and model.py stamped each with now. Checks, on
a world at tick 49.38M:
1. a restart's first confessions read: each old one keeps its own time (by tick) and is history; the caster voices
   none, the director gets no interest from them; after an empty read, a fresh confessional is voiced.
2. the same for tells and operator requests (the ticker and the site show them as old; the hosts get no
   operator_request beat), and for board events replayed 100 at a time (no board beat).
3. a fresh line inside the backlog read (its tick within HISTORY_S) is news as before.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
from model import Model  # noqa: E402

TICK = 49_380_000
AGENTS = {"sol": {"display_name": "Sol"}, "astra": {"display_name": "Astra"}, "opus": {"display_name": "Opus"}}
ASTRA = "The biggest lesson today is that an idle machine is often a delivery problem."
SOL = ("The biology is finally behaving. The awkward part is that a warning can describe eggs that have already been "
       "eaten by the time I walk over. I still check; the alternative has legs.")


def agents():
    return [{"name": n, "alive": True, "position": {"x": 0, "y": 0}} for n in AGENTS]


def voiced(d, m, now):
    """The caster's chat events for the model's snapshot now (caster.Differ, as on air)."""
    return [e for e in d.diff(m.snapshot(now)) if e["kind"] in ("chat", "operator_request", "board", "harness")]


def confessions():
    m, d = Model({"agents": AGENTS}), caster.Differ()
    now = time.time()
    m.ingest({"tick": TICK, "agents": agents()}, now=now)
    d.diff(m.snapshot(now))  # the caster's first snapshot: before live.py's first confessions read
    interest = {n: m.agents[n].interest for n in AGENTS}
    now += 6
    # the restart's first read: the runtime's kept confessionals (newest 30; two here, and one made 20 s ago)
    m.ingest({"tick": TICK + 360, "agents": agents(), "confessions": [
        {"seq": 65, "tick": 8953890, "from": "astra", "text": ASTRA},
        {"seq": 67, "tick": 10291268, "from": "sol", "text": SOL},
        {"seq": 76, "tick": TICK + 360 - 1200, "from": "opus", "text": "Fresh: the reactor is warm."}]}, now=now)
    rows = {c["seq"]: c for c in m.snapshot(now)["chat"] if c.get("confess")}
    for seq, tick in (("c65", 8953890), ("c67", 10291268)):
        r = rows[seq]
        assert r["history"] is True and abs(r["t"] - (now - (TICK + 360 - tick) / 60)) < 1, r
    assert "history" not in rows["c76"] and rows["c76"]["t"] == now, rows["c76"]
    ev = voiced(d, m, now)
    assert [e["agent"] for e in ev] == ["opus"], ev  # Sol's and Astra's old lines: not voiced
    assert m.agents["sol"].interest == interest["sol"] and m.agents["astra"].interest == interest["astra"]
    # the caster's queue takes the chat events; history lines never reach it
    assert not any(SOL[:30] in (e.get("text") or "") for e in ev)
    # the next read is empty: the backlog is done
    now += 2
    m.ingest({"tick": TICK + 480, "agents": agents(), "confessions": []}, now=now)
    assert voiced(d, m, now) == []
    # a fresh confessional after it: voiced, its time now
    now += 30
    m.ingest({"tick": TICK + 2280, "agents": agents(), "confessions": [
        {"seq": 77, "tick": TICK + 2270, "from": "sol", "text": "The eggs are capped at eight now."}]}, now=now)
    r = next(c for c in m.snapshot(now)["chat"] if c.get("seq") == "c77")
    assert "history" not in r and r["t"] == now, r
    assert [(e["kind"], e["agent"]) for e in voiced(d, m, now)] == [("chat", "sol")]
    print("confessions: ok (old ones history with their own time, not voiced; fresh ones voiced)")


def other_feeds():
    m, d = Model({"agents": AGENTS}), caster.Differ()
    now = time.time()
    m.ingest({"tick": TICK, "agents": agents()}, now=now)
    d.diff(m.snapshot(now))
    now += 6
    old = TICK - 3600 * 60  # an hour of game time ago
    m.ingest({"tick": TICK + 360, "agents": agents(),
              "tells": [{"seq": 300, "tick": old, "from": "sol", "to": ["astra"], "text": "eggs capped"}],
              "operator_requests": [{"t": now, "seq": 41, "tick": old, "agent": "astra", "text": "please restart cam2"}],
              # the board's kept events, oldest first, 100 a read: the first read
              "board_events": [{"seq": 900 + i, "tick": old + i, "by": "opus", "id": 1800 + i, "change": "done",
                                "title": f"Item {i}", "kind": "task"} for i in range(100)]}, now=now)
    snap = m.snapshot(now)
    tell = next(c for c in snap["chat"] if c.get("seq") == "t300")
    req = next(c for c in snap["chat"] if c.get("seq") == "o41")
    assert tell["history"] and tell["t"] < now - 3000 and req["history"] and req["t"] < now - 3000, (tell, req)
    assert m.operator_requests[-1]["history"] is True and m.operator_requests[-1]["t"] == req["t"]
    assert all(e.get("history") and e["t"] < now - 3000 for e in snap["board"]["events"]), snap["board"]["events"][-1]
    assert voiced(d, m, now) == [], voiced(d, m, now)
    # the board's second read: still the backlog (no empty read yet)
    now += 2
    m.ingest({"tick": TICK + 480, "agents": agents(), "tells": [], "operator_requests": [],
              "board_events": [{"seq": 1000 + i, "tick": old + 100 + i, "by": "opus", "id": 1900 + i, "change": "done",
                                "title": f"Later {i}", "kind": "task"} for i in range(50)]}, now=now)
    assert voiced(d, m, now) == []
    now += 2
    m.ingest({"tick": TICK + 600, "agents": agents(), "board_events": []}, now=now)
    # live now: a fresh request, tell and board event are news
    now += 10
    m.ingest({"tick": TICK + 1200, "agents": agents(),
              "operator_requests": [{"t": now, "seq": 42, "tick": TICK + 1190, "agent": "astra", "text": "cam2 is black"}],
              "board_events": [{"seq": 1100, "tick": TICK + 1195, "by": "opus", "id": 2001, "change": "done",
                                "title": "West wall", "kind": "task"}]}, now=now)
    kinds = sorted(e["kind"] for e in voiced(d, m, now))
    assert kinds == ["board", "operator_request"], kinds
    print("tells, operator requests, board events: ok (a restart's backlog is history; fresh ones are news)")


if __name__ == "__main__":
    confessions()
    other_feeds()
    print("test_backlog: ok")
