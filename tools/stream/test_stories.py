#!/usr/bin/env python3
"""Operation stories carried to their results (d28 batch312 B, viewer Aurora 10:48): python3 tools/stream/test_stories.py

1. stories.py on model.py: an agent's flight watch armed on Resolute opens a story: the question (the board item whose
   title names the ship), the handoff (asked by Sol, taken by Astra), one "story" alert and one open beat; a watch
   running long before the service saw it is followed but not opened on air.
2. One story across the legs' replaced watches and a restart (a new model on the same runs/RUN/stories.json); the
   result waits for the agent's read: passed (ended at an arrival, nothing lost), failed (lost during it: the read's
   count, else the loss alerts), pending (time limit, no read); the item marked done passes it; the spot last built on
   is revisited; the platform's next story within REPEAT_S is quiet and only a failure airs; each beat once.
   2b. work.WatchReads: the agents' reads from their journals, not a restart's tail.
3. caster.py: a story beat's facts and how to call it, facts only.
4. onecam.py maybe_story: the ship on air with the question as its caption, the agent who set the watch in the inset
   once the ship is up (a camera panel with one client), a result at the repaired spot at the build close-up's zoom;
   it waits while a fight or a build is on air; each beat once.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stories as S  # noqa: E402
from model import Model  # noqa: E402
from onecam import OneCam  # noqa: E402
from test_onecam import agent  # noqa: E402
from test_platformcam import plat, snap, main_row  # noqa: E402

T = 1793200000.0
TICK = 77000000
VIEW = {"surface": "platform-7", "hub": {"x": 0, "y": 0}, "bounds": {"left": -30, "top": -100, "right": 30, "bottom": 100},
        "hub_health": 100}
ITEMS = {2601: {"id": 2601, "title": "Resolute V-N flight watch: hull, repair, turrets and losses", "kind": "task",
                "owner": "astra", "agent": "astra", "status": "doing", "requested_by": "sol", "updated_tick": TICK},
         2584: {"id": 2584, "title": "Some other work", "kind": "task", "owner": "astra", "status": "doing"}}


def watch(state, wid=1584, start=TICK, line=None):
    return {"id": f"flight#{wid}", "kind": "flight_watch", "scope": "Resolute", "state": state, "start_tick": start,
            "end_tick": start + 7200, "line": line or f"flight watch #{wid} on Resolute: {state}"}


def model(path=None):
    m = Model({"agents": {"astra": {"display_name": "Astra"}, "sol": {"display_name": "Sol"}}})
    if path:
        m.set_story_store(path)
    m.board["items"] = {k: dict(v) for k, v in ITEMS.items()}  # (the board read's items, as model.py keeps them)
    return m


def feed(m, now, watches, tick=None):
    m.ingest({"tick": tick or TICK + int((now - T) * 60), "agents": [
        {"name": "astra", "display_name": "Astra", "watches": watches}, {"name": "sol", "display_name": "Sol"}]}, now=now)


def alerts(m, beat=None):
    return [a for a in m.alerts if a["kind"] == "story" and (beat is None or a["facts"]["beat"] == beat)]


def opened():
    m = model()
    feed(m, T, [watch("armed")])
    a = alerts(m)
    assert len(a) == 1 and a[0]["facts"]["beat"] == "open", a
    f = a[0]["facts"]
    assert f["question"] == "#2601: Resolute V-N flight watch: hull, repair, turrets and losses" and f["handoff"] == "asked by Sol, taken by Astra", f
    assert a[0]["text"] == ("Astra set a flight watch on Resolute · the question: #2601 Resolute V-N flight watch: hull, "
                            "repair, turrets and losses · asked by Sol, taken by Astra"), a[0]["text"]
    snap_ = m.snapshot(T + 1)["stories"]
    assert [b["beat"] for b in snap_] == ["open"] and snap_[0]["platform"] == "Resolute" and snap_[0]["agent"] == "astra", snap_
    for k in range(1, 4):
        feed(m, T + k, [watch("running")])
    assert len(alerts(m)) == 1
    # a watch running for 20 min when first seen: followed, not opened on air
    m2 = model()
    feed(m2, T, [watch("running", wid=99, start=TICK - 20 * 60 * 60)], tick=TICK)
    assert not alerts(m2) and m2.stories.stories["astra:flight#99"]["late"], m2.stories.stories
    # without an item: what the watch measures; the setter not the owner: said
    assert S.handoff(ITEMS[2601], {"astra": "Astra", "sol": "Sol", "luna": "Luna"}, "luna") == \
        "asked by Sol, taken by Astra; Astra's item, the watch set by Luna"
    print("1. a flight watch armed: one story alert and one open beat, with the board's question and handoff; a watch "
          "running long before: followed, not opened: ok")


def results():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "stories.json")
        # passed: the build before it is the spot; legs replaced on the way; ended at an arrival, nothing lost
        build = {"agent": "sol", "action": "place_ghosts", "verb": "building", "t": T - 600, "platform": "Resolute",
                 "position": {"x": 20.0, "y": 70.0}, "extent": {"left": 15, "top": 68, "right": 25, "bottom": 72},
                 "what": [["repair-pack", 1]]}
        m = model(path)
        m.work.append(dict(build))
        feed(m, T, [watch("armed")])
        feed(m, T + 5, [watch("running")])
        # the next leg: #1584 replaced by #1585 (Astra's every 5-13 min): the same story, no new beat
        feed(m, T + 300, [watch("done", line="flight watch #1584 on Resolute: ended (replaced by #1585), its result not read yet"),
                          watch("running", wid=1585)])
        # a restart mid-flight: a new model on the same store carries it
        m = model(path)
        m.work.append(dict(build))
        feed(m, T + 360, [watch("running", wid=1585)])
        assert len(alerts(m)) == 0 and len(m.stories.stories) == 1, m.stories.stories
        feed(m, T + 905, [watch("done", wid=1585, line="flight watch #1585 on Resolute: ended (arrived at aquilo), its result not read yet")])
        assert not alerts(m, "result"), "waits for the agent's read"
        m.stories.on_read({"agent": "astra", "id": "flight#1585", "platform": "Resolute", "ended_by": "arrived at aquilo",
                           "lost_count": 0, "line": "flight watch #1585 on Resolute ..."}, T + 920)
        feed(m, T + 921, [watch("done", wid=1585, line="flight watch #1585 on Resolute: ended (arrived at aquilo), its result not read yet")])
        r = alerts(m, "result")
        assert len(r) == 1 and r[0]["facts"]["result"] == "passed", r
        assert r[0]["text"].startswith("Resolute flight watch · Passed: arrived at aquilo, nothing lost during the watch (Astra's read of the watch)"), r[0]["text"]
        assert r[0]["facts"]["revisits"] == "the spot where Sol last built on it" and r[0]["facts"]["ended"] == "arrived at aquilo", r[0]["facts"]
        b = [x for x in m.snapshot(T + 922)["stories"] if x["beat"] == "result"]
        assert b and b[0]["spot"]["position"] == {"x": 20.0, "y": 70.0} and b[0]["verdict"] == "passed", b
        feed(m, T + 930, [])
        assert len(alerts(m, "result")) == 1, "one result"
        kept = json.load(open(path))
        assert kept["stories"][0]["state"] == "closed" and kept["stories"][0]["watches"] == ["flight#1584", "flight#1585"], kept
        # the next story on Resolute within REPEAT_S: followed quietly; a pass stays off air, a failure airs
        feed(m, T + 1000, [watch("running", wid=1586)])
        assert not alerts(m, "open") and m.stories.open_for("astra", "Resolute")["quiet"]  # (the first open beat: before the restart)
        m.stories.on_read({"agent": "astra", "id": "flight#1586", "platform": "Resolute", "ended_by": "arrived at nauvis", "lost_count": 2}, T + 1100)
        feed(m, T + 1101, [watch("done", wid=1586, line="flight watch #1586 on Resolute: ended (arrived at nauvis), its result not read yet")])
        r = alerts(m, "result")
        assert len(r) == 2 and r[1]["facts"]["result"] == "failed" and "2 lost during the watch (Astra's read of the watch)" in r[1]["text"], r
    # failed from the stream's own loss alerts (no read: READ_WAIT runs out)
    m = model()
    feed(m, T, [watch("running", wid=7)])
    m._ingest_event({"kind": "loss", "text": "2 lost: gun-turret x2", "platform": "Resolute", "key": "loss:r1"}, T + 30)
    m._ingest_event({"kind": "loss", "text": "3 lost: gun-turret x3", "platform": "Resolute", "key": "loss:r1"}, T + 40)
    m._ingest_event({"kind": "loss", "text": "1 lost: wall", "platform": "Other", "key": "loss:o"}, T + 40)
    done7 = watch("done", wid=7, line="flight watch #7 on Resolute: ended (arrived at aquilo), its result not read yet")
    feed(m, T + 100, [done7])
    feed(m, T + 100 + 120, [done7])
    r = alerts(m, "result")[0]
    assert r["facts"]["result"] == "failed" and r["facts"]["lost_during_watch"] == 3 and "Failed: 3 lost during the watch" in r["text"], r
    # pending: ended by its time limit, no arrival, no read
    m = model()
    feed(m, T, [watch("running", wid=8)])
    done8 = watch("done", wid=8, line="flight watch #8 on Resolute: ended (time limit), its result not read yet")
    feed(m, T + 100, [done8])
    feed(m, T + 230, [done8])
    r = alerts(m, "result")[0]
    assert r["facts"]["result"] == "pending" and "Still pending: the watch ended (time limit), no arrival seen" in r["text"], r
    # the team marks the item done: passed whatever else
    m = model()
    feed(m, T, [watch("running", wid=9)])
    m.board["items"][2601]["status"] = "done"
    feed(m, T + 100, [])
    r = alerts(m, "result")[0]
    assert r["facts"]["result"] == "passed" and "#2601 marked done" in r["text"] and r["facts"]["ended"] == "it left the agent's card", r
    # armed and dropped before its flight: no result
    m = model()
    feed(m, T, [watch("armed", wid=10)])
    feed(m, T + 50, [])
    assert not alerts(m, "result"), alerts(m)
    print("2. results: one story across replaced legs and a restart, passed on the agent's read (arrived, 0 lost) at the "
          "repaired spot; a quiet repeat airs only its failure; failed (3 lost, the loss alerts), pending (time limit), "
          "the item done; each beat once: ok")


def reads():
    import work as W
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "astra"))
        j = os.path.join(d, "astra", "journal.jsonl")
        open(j, "w").write(json.dumps({"event": "request", "request": {"id": 1, "action": "flight_watch", "args": {"id": 1}}}) + "\n")
        feed_ = W.WorkFeed(d, ["astra"])
        feed_.poll()
        assert feed_.watch_reads.take() == [], "a restart's tail: no old reads"
        with open(j, "a") as f:
            f.write(json.dumps({"event": "request", "request": {"id": 7, "action": "flight_watch", "args": {"platform": "Resolute", "read": True}}}) + "\n")
            f.write(json.dumps({"event": "response", "response": {"id": 7, "ok": True, "result": {"watch": {
                "line": "flight watch #1583 on Resolute, solar-system-edge->aquilo: watched for 11m10s, ended: arrived at aquilo",
                "ended_by": "arrived at aquilo", "lost_count": 0}}}}) + "\n")
        feed_.poll()
        got = feed_.watch_reads.take()
        assert got == [{"agent": "astra", "id": "flight#1583", "platform": "Resolute", "ended_by": "arrived at aquilo", "lost_count": 0,
                        "line": "flight watch #1583 on Resolute, solar-system-edge->aquilo: watched for 11m10s, ended: arrived at aquilo"}], got
    print("2b. the agents' reads of their flight watches from their journals (work.WatchReads), not a restart's tail: ok")


def hosts():
    import caster
    e = {"kind": "story", "facts": {"story": "a ship trial (flight watch)", "beat": "result", "platform": "Resolute",
                                    "result": "failed", "why": "3 lost during the watch", "lost_during_watch": 3}}
    f = caster.facts_for(e, {"game_time": "1000h00m", "agents": []})
    assert f["story"]["result"] == "failed" and "no verdict of your own" in f["how_to_call_it"], f
    assert caster.PRIORITY["story"] < caster.PRIORITY["attack"], "below battles"
    print("3. the hosts: the story's facts and how to call it (facts only), below battles: ok")


def director():
    slots = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 1, "panel": 1, "rect": [0, 0, 10, 10], "scale": 0.2},
             {"slot": "cam3", "player": 1, "panel": 2, "rect": [0, 0, 10, 10], "scale": 0.2}]
    sent = []
    d = OneCam(slots, lambda body: sent.append(body) or {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d.started = 0
    a = [agent("astra", 0, 0, 5), agent("sol", 300, 0, 1)]
    p = plat("Resolute", view=VIEW)
    for k in range(0, 70):
        d.step(snap(a, [p]), 1000 + k)
    beat = {"key": "astra:flight#1584:open", "beat": "open", "platform": "Resolute", "agent": "astra", "t": 1070,
            "caption": "Astra set a flight watch on Resolute · the question: #2601 ... · asked by Sol, taken by Astra"}
    s = dict(snap(a, [p]), stories=[beat])
    rows, insets = [], []
    for k in range(70, 110):
        d.step(s, 1000 + k)
        r = main_row(d, 1000 + k)
        if (r.get("platform") or {}).get("why") == "story":
            rows.append(k)
        if d.inset and d.inset.get("why") == "story":
            insets.append((k, d.inset["slot"]))
    assert rows and rows[0] <= 71 and main_row(d, 1000 + rows[0]) is not None, d.cuts[-3:]
    assert insets and insets[0][1] in ("cam2", "cam3") and insets[0][0] - rows[0] <= 2, (rows[:2], insets[:2])
    r0 = [c for c in d.cuts if c[2].startswith("platform story")]
    assert len(r0) == 1, r0
    assert len(rows) >= 20 and len(rows) <= 20 + d.cfg["ready_s"] + 3, len(rows)
    # the same beat again: not shown again; a result with a spot: the spot at the build close-up's zoom
    res = {"key": "astra:flight#1584:result", "beat": "result", "platform": "Resolute", "agent": "astra", "t": 1200,
           "verdict": "passed", "caption": "Resolute flight watch · Passed: arrived at Aquilo with nothing lost during the watch",
           "spot": {"agent": "sol", "action": "place_ghosts", "verb": "building", "position": {"x": 20.0, "y": 70.0},
                    "extent": {"left": 15, "top": 68, "right": 25, "bottom": 72}}}
    s = dict(snap(a, [p]), stories=[beat, res])
    got = None
    for k in range(110, 260):
        d.step(s, 1000 + k)
        r = main_row(d, 1000 + k)
        if (r.get("platform") or {}).get("story") == res["key"] and got is None:
            got = (k, d.state[d.onair])
    assert got and got[0] - rows[0] >= d.cfg["story_gap"], (got and got[0], rows[0])
    t = got[1]
    assert t["position"] == {"x": 20.0, "y": 70.0} and t["zoom"] == d.cfg["work_spot_zoom"] and t["work"].startswith("Resolute flight watch · Passed"), t
    assert len([c for c in d.cuts if c[2].startswith("platform story")]) == 2
    # a fight on air: it waits
    d2 = OneCam(slots, lambda body: {"ok": True}, None, trio=False, map_every=0, platform_every=0)
    d2.started = 0
    for k in range(0, 70):
        d2.step(snap(a, [p]), 1000 + k)
    d2.fighting = lambda n, by, now: True
    for k in range(70, 90):
        d2.step(dict(snap(a, [p]), stories=[beat]), 1000 + k)
    assert not any(c[2].startswith("platform story") for c in d2.cuts), d2.cuts[-2:]
    print(f"4. the director: the ship {len(rows)} s with the question, the agent in a panel inset, the result at the "
          f"repaired spot (zoom {t['zoom']}) {got[0] - rows[0]} s later; a fight holds it back; each beat once: ok")


if __name__ == "__main__":
    opened()
    results()
    reads()
    hosts()
    director()
    print("stories: ok")
