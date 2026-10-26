#!/usr/bin/env python3
"""Old confessions stay dated history: python3 tools/stream/test_oldconfess.py

d26 batch236 OC (viewer Aurora 10:39: "Opus's shift15 confession c72 reappears beside fresh speech after startup.
Could old confessions stay dated history, without appearing or being voiced as new shift messages?"). At shift81's
start (10:19:44) the stream service's first confessions read returned the runtime's kept confessions, c71-c75 of
shift15-16 (no agent has confessed since). model.py marked them history (BU1) but put them into the chat window beside
the new shift's lines; push_live sent them to the site's live feed; the overlay, which reads no history mark, showed
them as current lines tagged "to camera". None was voiced (caster.py skips history). Checks, with shift81's own lines:
1. a backlog line from before the current shift (run shift.start; its time from its tick) is in no live feed: the
   snapshot's chat, push_live's state, the caster's events, the director's interest; confessions, tells, operator
   requests and board events alike;
2. one from earlier in this shift (a mid-shift restart) stays as before: history, its own time, not voiced;
3. a backlog line read before the game tick is known (it cannot be dated) is left out too;
4. after the backlog, a fresh confession is news and voiced as before; a run with no shift start keeps BU1's rule;
5. the overlay shows no history line or replayed board event (static/overlay.js filters).
No clock: every time is fixed.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
sys.dont_write_bytecode = True
import caster  # noqa: E402
import push_live  # noqa: E402
from model import Model  # noqa: E402

START = 1793035184.0  # shift81's start (runs/shift81/stream.json shift.start, 10:19:44)
NOW = START + 119  # the stream service's first reads, 10:21:43
TICK = 66979690  # the game tick then (Astra's line 24481)
AGENTS = {"sol": {"display_name": "Sol"}, "astra": {"display_name": "Astra"}, "opus": {"display_name": "Opus"},
          "grok": {"display_name": "Grok"}}
# the runtime's kept confessions as shift81's first read returned them (the stream service's /state.json, 10:44)
KEPT = [
    {"seq": 71, "tick": 10676132, "from": "sol", "text": "I am about to leave a factory that has needed a surprising amount of babysitting."},
    {"seq": 72, "tick": 11142140, "from": "opus", "text": "Today's lesson: half of our shortages were not missing materials. Four thousand "
     "solid fuel sat in chests nothing could pull from, while the furnaces beside them went cold. The factory needs plumbing more than it "
     "needs mining."},
    {"seq": 73, "tick": 12180561, "from": "astra", "text": "The ship is finally making ammunition."},
    {"seq": 74, "tick": 12715752, "from": "sol", "text": "The egg shortage was my mistake."},
    {"seq": 75, "tick": 16289175, "from": "grok", "text": "The breeder will multiply eggs until they hatch in the base if nobody caps it."}]


def agents():
    return [{"name": n, "alive": True, "position": {"x": 0, "y": 0}} for n in AGENTS]


class Clock:
    """The caster's clock (caster.Differ reads time.time()): fixed at the snapshot's time, so no wall clock."""
    def __init__(self, real):
        self.real, self.now = real, 0.0

    def time(self):
        return self.now

    def __getattr__(self, k):
        return getattr(self.real, k)


caster.time = Clock(caster.time)


def voiced(d, m, now):
    caster.time.now = now
    return [e for e in d.diff(m.snapshot(now)) if e["kind"] in ("chat", "operator_request", "board", "harness")]


def run(shift=True):
    return {"agents": AGENTS, **({"shift": {"start": START, "end": START + 14400}} if shift else {})}


def shift_start():
    m, d = Model(run()), caster.Differ()
    m.ingest({"tick": TICK - 360, "agents": agents()}, now=NOW - 6)
    voiced(d, m, NOW - 6)
    interest = {n: m.agents[n].interest for n in AGENTS}
    # the first reads: the kept confessions, one made 90 s ago in this shift; tells, an operator request and board
    # events from the last shift and from this one
    this_shift = TICK - 90 * 60
    last_shift = TICK - 3 * 3600 * 60
    m.ingest({"tick": TICK, "agents": agents(),
              "confessions": KEPT + [{"seq": 76, "tick": this_shift, "from": "sol", "text": "Shift 81: the labs are fed."}],
              "tells": [{"seq": 92001, "tick": last_shift, "from": "astra", "to": ["sol"], "text": "last shift's tell"},
                        {"seq": 92339, "tick": this_shift, "from": "astra", "to": ["sol"], "text": "this shift's tell"}],
              "operator_requests": [{"seq": 501, "tick": last_shift, "agent": "astra", "text": "last shift's request", "t": NOW}],
              "board_events": [{"seq": 24001, "tick": last_shift, "by": "sol", "id": 900, "change": "posted", "kind": "request",
                                "title": "last shift's request"},
                               {"seq": 24480, "tick": this_shift, "by": "sol", "id": 901, "change": "posted", "kind": "request",
                                "title": "this shift's request"}]}, now=NOW)
    snap = m.snapshot(NOW)
    chat = {c["seq"]: c for c in snap["chat"]}
    for c in KEPT:
        assert f"c{c['seq']}" not in chat, (c["seq"], chat.get(f"c{c['seq']}"))
    assert "t92001" not in chat and "o501" not in chat, sorted(chat)
    site = push_live.public_state(snap)
    assert not any("plumbing" in (c.get("text") or "") for c in site.get("chat") or []), "c72 on the site's live feed"
    assert not any(e.get("title") == "last shift's request" for e in snap["board"]["events"]), snap["board"]["events"]
    assert not any(r.get("text") == "last shift's request" for r in snap.get("operator_requests") or []), snap.get("operator_requests")
    # this shift's backlog: history with its own time, as before (BU1)
    c76, t = chat["c76"], chat["t92339"]
    assert c76["history"] is True and abs(c76["t"] - (NOW - 90)) < 1, c76
    assert t["history"] is True, t
    ev = next(e for e in snap["board"]["events"] if e.get("title") == "this shift's request")
    assert ev.get("history") is True, ev
    # nothing voiced, no interest from any of them
    assert voiced(d, m, NOW) == [], "old lines voiced"
    assert all(m.agents[n].interest == interest[n] for n in AGENTS), "interest from old lines"
    # the next reads are empty: the backlog is done; a fresh confession is news, voiced
    m.ingest({"tick": TICK + 120, "agents": agents(), "confessions": [], "tells": [], "operator_requests": [], "board_events": []},
             now=NOW + 2)
    m.ingest({"tick": TICK + 1920, "agents": agents(), "confessions": [
        {"seq": 77, "tick": TICK + 1910, "from": "opus", "text": "The spider recon is done."}]}, now=NOW + 32)
    r = next(c for c in m.snapshot(NOW + 32)["chat"] if c.get("seq") == "c77")
    assert "history" not in r and r["t"] == NOW + 32, r
    assert [(e["kind"], e["agent"]) for e in voiced(d, m, NOW + 32)] == [("chat", "opus")]
    print("shift start: ok (c71-c75 and last shift's tells, requests and board events in no live feed; this shift's backlog "
          "history; a fresh confession voiced)")


def undatable():
    # the first observe without a game tick (a failed status read) and the kept confessions in it: left out
    m = Model(run())
    m.ingest({"agents": agents(), "confessions": KEPT}, now=NOW)
    assert not any(c.get("confess") for c in m.snapshot(NOW)["chat"]), m.snapshot(NOW)["chat"]
    print("no tick yet: ok (the kept confessions are left out)")


def no_shift():
    # a run with no shift start (tests, replays): BU1's rule as it was: history with its own time
    m = Model(run(shift=False))
    m.ingest({"tick": TICK, "agents": agents(), "confessions": KEPT}, now=NOW)
    rows = [c for c in m.snapshot(NOW)["chat"] if c.get("confess")]
    assert len(rows) == 5 and all(c["history"] for c in rows), rows
    print("no shift start: ok (history, as before)")


def overlay():
    src = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert '!m.tell && !m.history && ((m.lane || "talk") === "talk"' in src, "the overlay's talk filter"
    assert "m.tell && !m.history" in src, "the overlay's tells filter"
    assert "(b.events || []).filter((e) => !e.history)" in src, "the overlay's board events filter"
    print("overlay: ok (no history line, tell or replayed board event)")


if __name__ == "__main__":
    shift_start()
    undatable()
    no_shift()
    overlay()
    print("test_oldconfess: ok")
