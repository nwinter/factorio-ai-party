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
4. (d24 batch175 QR1, viewer Aurora 17:02: "Around shift 69, project 1816 showed done 5/5, then doing 1/5, then done
   again while its completion notes stayed") the board through a restart, as the site gets it: #1816's own events
   (world n's kept events, seq 22024..22343) replayed 100 a poll after the first `board` read had it done 5/5, with a
   `board` read every 15 s. In the model's board, the full board document (serve.py /board.json) and push_live's
   state and board document, #1816 stays done 5/5 with its handoff at every poll; a finished project no read listed
   never shows as being worked on; after the backlog a fresh event moves its item as before.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
import caster  # noqa: E402
import push_live  # noqa: E402
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


# #1816's events as world n kept them (board_events, read d24 17:20): seq, tick, change, status, steps done of 5
EVENTS_1816 = [(22024, 55835391, "handoff", "doing", 0), (22026, 55848278, "step_done", "doing", 1),
               (22027, 55848278, "note", "doing", 1), (22032, 55861694, "step_edited", "doing", 1),
               (22042, 55880519, "handoff", "doing", 1), (22052, 55893296, "step_done", "doing", 2),
               (22058, 55900563, "step_done", "doing", 3), (22114, 56070998, "note", "doing", 3),
               (22218, 56398774, "note", "doing", 3), (22253, 56493641, "step_done", "doing", 4),
               (22300, 56637663, "note", "doing", 4), (22338, 56773129, "step_done", "doing", 5),
               (22341, 56773895, "done", "done", 5), (22342, 56774122, "note", "done", 5),
               (22343, 56774930, "handoff", "done", 5)]
TITLE_1816 = "Direct-insertion EM circuit blueprint set"
HANDOFF = "Goal: integrated green/red/blue foundry-to-EM draft set; all5 steps done at tick56773895."


def kept_events():
    """1000 kept events from seq 22022: #1816's, an older finished project no read lists (#1700, done in a later poll
    than its first step), and teammates' finished tasks between them."""
    own = {s: {"seq": s, "tick": t, "by": "luna", "id": 1816, "change": c, "title": TITLE_1816, "kind": "project",
               "owner": "luna", "status": st, "progress": f"{n} of 5 steps", "steps_done": n, "steps_total": 5}
           for s, t, c, st, n in EVENTS_1816}
    old = {22030: ("step_done", "doing", 1), 22150: ("step_done", "doing", 2), 22390: ("done", "done", 3)}
    for s, (c, st, n) in old.items():
        own[s] = {"seq": s, "tick": 55840000 + (s - 22022) * 3000, "by": "sol", "id": 1700, "change": c,
                  "title": "Old cell", "kind": "project", "owner": "sol", "status": st, "progress": f"{n} of 3 steps",
                  "steps_done": n, "steps_total": 3}
    return [own.get(s) or {"seq": s, "tick": 55840000 + (s - 22022) * 3000, "by": "opus", "id": 3000 + s % 50,
                           "change": "done", "title": f"Task {s % 50}", "kind": "task", "owner": "opus", "status": "done"}
            for s in range(22022, 23022)]


def board_read(tick):
    """A `board` read as live.py makes it: #1816 among the finished projects (it was done at 56774930), #2186 open."""
    done = {"id": 1816, "kind": "project", "title": TITLE_1816, "owner": "luna", "status": "done",
            "progress": "5 of 5 steps", "updated_tick": 56774930, "handoff": HANDOFF,
            "steps": [f"[x] {n}. step {n} (done by luna, 3h ago)" for n in range(1, 6)]}
    rollout = {"id": 2186, "kind": "project", "title": "Phased foundry-to-EM circuit rollout across planets",
               "owner": "luna", "status": "blocked", "progress": "1 of 5 steps", "updated_tick": 57462121}
    return {"items": [done, rollout], "open_unowned": 0, "active_ids": [], "finished_ids": [], "plan": None,
            "tick": tick}


def board_restart():
    m = Model({"agents": AGENTS})
    now, tick = time.time(), 57_500_000
    events = kept_events()
    m.ingest({"tick": tick, "agents": agents()}, now=now)
    for poll in range(13):  # a poll every 3 s; the backlog's ten reads, then empty ones
        now, tick = now + 3, tick + 180
        obs = {"tick": tick, "agents": agents(), "board_events": events[poll * 100:(poll + 1) * 100]}
        if poll % 5 == 0:  # live.py's `board` read every 15 s, after the events
            obs["board"] = board_read(tick)
        m.ingest(obs, now=now)
        snap = m.snapshot(now)
        board, doc = snap["board"], m.board_all_snapshot()
        site, site_doc = push_live.public_state(snap)["board"], push_live.public_board_all(doc)
        for where, rows in (("model", board["projects"] + board["projects_done"]), ("document", doc["projects"]),
                            ("site", site["projects"] + site["projects_done"]), ("site document", site_doc["projects"])):
            row = next(r for r in rows if r["id"] == 1816)
            assert (row["status"], row["progress"], row["done"], row["handoff"]) == ("done", "5 of 5 steps", 5, HANDOFF), \
                (poll, where, row)
            assert not any(r["id"] == 1700 for r in rows), (poll, where)  # #1700: no read lists it
        assert [r["id"] for r in site["projects"]] == [2186], (poll, site["projects"])
    # live now: a fresh step on #2186 moves its row as before
    now, tick = now + 3, tick + 180
    m.ingest({"tick": tick, "agents": agents(), "board_events": [
        {"seq": 23022, "tick": tick - 10, "by": "luna", "id": 2186, "change": "step_done", "kind": "project",
         "title": "Phased foundry-to-EM circuit rollout across planets", "owner": "luna", "status": "doing",
         "progress": "2 of 5 steps", "steps_done": 2, "steps_total": 5}]}, now=now)
    row = next(r for r in push_live.public_state(m.snapshot(now))["board"]["projects"] if r["id"] == 2186)
    assert (row["status"], row["progress"]) == ("doing", "2 of 5 steps"), row
    print("board: ok (#1816 stays done 5/5 with its handoff through a restart's replay, on the model's and the site's board)")


if __name__ == "__main__":
    confessions()
    other_feeds()
    board_restart()
    print("test_backlog: ok")
