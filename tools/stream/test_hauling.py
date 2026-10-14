#!/usr/bin/env python3
"""Hand hauling on stream (operator 05:00, viewer Joonazan): python3 tools/stream/test_hauling.py

1. hauling.py: a read is a row in runs/RUN/hauling.jsonl; a shift's numbers are the last row less the first, by agent,
   most items first, the team only; counters that went down (a new save) count from zero; the haul repeated most in
   between.
2. live.py reads `hauling` as the operator every 5 minutes once `describe` lists it, appends the row, keeps the file's
   first row as the shift's start (also after a restart), and passes the shift's numbers on.
3. segments.py: the "hauling" card is due every 30 minutes at a free slot (not over a fight), ranked, numbers only;
   unavailable while nothing is counted; the hosts get the card's facts and a neutral call.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import hauling  # noqa: E402
import live  # noqa: E402
import model  # noqa: E402
from segments import Segments  # noqa: E402


def agent(name, items, calls, queue=0, order=0, carry=0, hauls=None):
    return {"name": name, "items": items, "calls": calls, "direct_items": items - queue - order, "direct_calls": calls,
            "queue_items": queue, "queue_calls": 0, "order_items": order, "order_calls": 0, "carry_tiles": carry,
            "hauls": hauls or []}


def haul(item, times, items, fx=-48, fy=74, tx=-63, ty=71):
    return {"item": item, "surface": "fulgora", "from": {"x": fx, "y": fy}, "to": {"x": tx, "y": ty},
            "to_name": "stone-furnace", "times": times, "items": items}


def check_rows():
    first = {"t": 100, "agents": [agent("gemini", 500, 40, hauls=[haul("solid-fuel", 10, 200)]), agent("grok", 900, 90),
                                  agent("nick", 5, 1)]}
    last = {"t": 1900, "agents": [
        agent("gemini", 2810, 452, queue=300, order=10, carry=1200,
              hauls=[haul("solid-fuel", 22, 440), haul("iron-plate", 30, 600, tx=-60)]),
        agent("grok", 1300, 100), agent("haiku", 40, 3), agent("sol", 0, 0), agent("nick", 50, 2)]}
    rows = hauling.shift_rows(first, last, team={"gemini", "grok", "haiku", "sol"})
    assert [r["name"] for r in rows] == ["gemini", "grok", "haiku"], rows  # most items first; nothing: no row; team only
    g = rows[0]
    assert g["items"] == 2310 and g["calls"] == 412 and g["queue_items"] == 300 and g["carry_tiles"] == 1200, g
    # the haul repeated most in between: iron-plate (30 new) beats solid-fuel (22 - 10 = 12)
    assert g["top"]["item"] == "iron-plate" and g["top"]["times"] == 30 and g["top"]["items"] == 600, g["top"]
    assert rows[1]["items"] == 400 and rows[1]["top"] is None
    # a new save: counters lower than the first row count from zero
    reset = hauling.shift_rows({"agents": [agent("grok", 900, 90)]}, {"agents": [agent("grok", 30, 2)]})
    assert reset[0]["items"] == 30 and reset[0]["calls"] == 2, reset
    line = hauling.card_line(rows, 5, lambda n: n.title())
    assert line == "Hand hauling this shift: 1. Gemini 2,310 items, 2. Grok 400 items, 3. Haiku 40 items", line
    assert hauling.card_line([], 5) is None


def check_file(tmp):
    path = hauling.path_for(tmp)
    assert hauling.append(path, {"tick": 10, "agents": [agent("grok", 1, 1)]}, 1000.04)["t"] == 1000.0
    assert hauling.append(path, {"error": "x"}, 1001) is None
    assert hauling.append(None, {"tick": 11, "agents": []}, 1002) == {"t": 1002, "tick": 11, "agents": []}
    with open(path, "a") as f:
        f.write("not json\n")
    hauling.append(path, {"tick": 20, "agents": [agent("grok", 5, 2)]}, 1300)
    rows = hauling.read_rows(path)
    assert [r["tick"] for r in rows] == [10, 20], rows


class FakeHarness:
    def __init__(self):
        self.reads, self.items = [], 100

    def operator_read(self, action, args):
        self.reads.append((action, args))
        self.items += 50
        return {"tick": 60 * len(self.reads), "agents": [agent("grok", self.items, len(self.reads)),
                                                         agent("nick", 9, 1)]}, None


def live_source(tmp, h):
    src = live.LiveSource.__new__(live.LiveSource)  # the hauling part only: no world, no probe
    src.h, src.agents_cfg = h, {"grok": {}, "gemini": {}}
    src.has_hauling, src.next_hauling = True, 0
    src.hauling_path = hauling.path_for(tmp)
    src.hauling_first = (hauling.read_rows(src.hauling_path) or [None])[0]
    return src


def check_live(tmp):
    h = FakeHarness()
    src = live_source(tmp, h)
    obs, errors = {}, {}
    src.observe_hauling(obs, errors)
    assert h.reads == [("hauling", {"top": 10})] and not errors
    first = obs["hauling"]
    assert first["rows"] == [] and first["since"] == first["t"], first  # the shift's start: nothing yet
    obs = {}
    src.observe_hauling(obs, errors)  # within 5 minutes: no read
    assert len(h.reads) == 1 and "hauling" not in obs
    src.next_hauling = 0
    src.observe_hauling(obs, errors)
    rows = obs["hauling"]["rows"]
    assert [r["name"] for r in rows] == ["grok"] and rows[0]["items"] == 50 and rows[0]["calls"] == 1, rows  # no nick
    assert src.next_hauling > time.time() + hauling.READ_EVERY - 5
    # a restarted service starts from the file's first row, not from its own first read
    again = live_source(tmp, h)
    again.observe_hauling(obs, errors)
    assert obs["hauling"]["rows"][0]["items"] == 100, obs["hauling"]
    assert len(hauling.read_rows(hauling.path_for(tmp))) == 3
    # a runtime without the read: nothing asked
    none = live_source(tmp, h)
    none.has_hauling = False
    n = len(h.reads)
    none.observe_hauling({}, errors)
    assert len(h.reads) == n
    # a failed read: the error, and another try in a minute
    class Broken:
        def operator_read(self, action, args):
            raise RuntimeError("rcon closed")
    bad = live_source(tmp, Broken())
    errs = {}
    bad.observe_hauling({}, errs)
    assert errs["hauling"] == "rcon closed" and bad.next_hauling <= time.time() + 61


def snap_with(rows, now):
    return {"agents": [{"name": "gemini", "display_name": "Gemini", "alive": True, "position": {"x": 0, "y": 0}},
                       {"name": "grok", "display_name": "Grok", "alive": True, "position": {"x": 1, "y": 0}}],
            "hauling": {"rows": rows, "since": now - 1800, "t": now} if rows is not None else None}


def check_segment():
    now = 10_000.0
    seg = Segments(recap_every=10**9, lull_after=10**9)
    seg.last_recap = seg.last_hauling = seg.last_end = now - 100
    seg.last_start = now - 1000
    rows = hauling.shift_rows({"agents": [agent("gemini", 0, 0), agent("grok", 0, 0)]},
                              {"agents": [agent("gemini", 2310, 412, queue=1000, carry=900), agent("grok", 400, 30)]})
    snap = snap_with(rows, now)
    seg.step(snap, now)
    assert seg.public() is None  # not due yet
    # unavailable while nothing is counted; the next one is due 30 minutes on
    empty = snap_with([], now + 1800)
    seg.step(empty, now + 1800)
    assert seg.public() is None and seg.last_hauling == now + 1800
    code, reply = seg.request({"type": "hauling"}, now + 1801)
    assert code == 409 and reply["why"] == "no hand hauling counted this shift yet", reply
    # due, a free slot and no fight: the director starts it
    t = now + 3600
    seg.step(snap, t)
    assert seg.queue and seg.queue["type"] == "hauling"
    out = seg.step(snap, t + 1)  # queued, then on air at the next second
    assert out and out["type"] == "hauling" and out["by"] == "director" and out["title"] == "Hand hauling this shift", out
    f = out["facts"]
    assert f["rows"][0] == {"rank": 1, "agent": "Gemini", "items": 2310, "calls": 412, "queued_pct": 43,
                            "tiles_carried": 900}, f["rows"][0]
    assert f["line"] == "Hand hauling this shift: 1. Gemini 2,310 items, 2. Grok 400 items" and f["minutes"] == 30, f
    assert seg.last_hauling == t
    # the hosts: the card's facts and a neutral call
    called = caster.card_facts(dict(out, started=t, ends=t + 15))
    assert called["on_screen_now"]["line"] == f["line"] and "no verdict" in called["how_to_call_it"], called
    # not over a fight: an attack cut within the minute holds it back
    seg2 = Segments(recap_every=10**9, lull_after=10**9)
    seg2.last_recap = seg2.last_end = t
    seg2.last_hauling, seg2.last_start = t - 1800, t - 1000
    seg2.attack_cut(t - 30)
    seg2.step(snap, t)
    assert seg2.public() is None and seg2.queue is None


def check_model():
    m = model.Model({"agents": {"grok": {}}})
    m.ingest({"hauling": {"rows": [{"name": "grok", "items": 5}], "since": 1, "t": 2}})
    assert m.snapshot(time.time())["hauling"]["rows"][0]["items"] == 5
    m.ingest({})
    assert m.snapshot(time.time())["hauling"]["rows"][0]["items"] == 5  # kept between reads


def check_overlay():
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert 'seg.type === "hauling"' in js and '"Hand hauling"' in js


def main():
    check_rows()
    with tempfile.TemporaryDirectory() as tmp:
        check_file(tmp)
    with tempfile.TemporaryDirectory() as tmp:
        check_live(tmp)
    check_segment()
    check_model()
    check_overlay()
    print("hauling: ok (shift rows, the run file, live reads every 5 min, the 30-min card, hosts' facts)")


if __name__ == "__main__":
    main()
