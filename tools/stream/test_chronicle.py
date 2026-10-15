#!/usr/bin/env python3
"""The run's chronicle in the stream (viewer Alex 22:24: the agents' own narrative history; viewer syndesis 22:24: each
platform's creation and loss with where, what destroyed it and the cargo): python3 tools/stream/test_chronicle.py

1. chronicle_log: rows appended after the cursors; a new shift starts after the shift it resumed from.
2. live.py reads the operator read every poll once describe lists it, writes runs/RUN/chronicle.jsonl, moves its
   cursors; a fresh world (cursors below the stream's) starts again from 1.
3. model.py: the entries and events in the state; a platform's loss as the harness read it fills the stream's own
   loss line (where it flew, what destroyed it, the cargo lost) and the hosts' facts.
4. caster.py: a new entry is a beat for the hosts, once, with its words; push_live sends the state's chronicle.
"""
import json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
import chronicle_log  # noqa: E402
import live  # noqa: E402
import model  # noqa: E402

ENTRY = {"seq": 3, "tick": 7200, "game_time": "0h02m", "agent": "sol", "title": "Starling falls",
         "text": "The rocks found Starling halfway to Vulcanus.", "platform": None, "planet": "nauvis",
         "refs": [{"id": 9, "kind": "platform_lost", "tick": 7100, "line": "platform Starling lost flying nauvis->vulcanus 40%"}]}
LOST = {"id": 9, "kind": "platform_lost", "tick": 7100, "game_time": "0h01m", "platform": "Starling", "force": "player",
        "where": "flying nauvis->vulcanus 40%", "from": "nauvis", "to": "vulcanus", "flown": 40, "by": "medium-metallic-asteroid",
        "hit_by": [{"name": "medium-metallic-asteroid", "count": 40}, {"name": "small-metallic-asteroid", "count": 12}],
        "cargo": [{"name": "iron-plate", "count": 450}, {"name": "rocket-fuel", "count": 20}], "cargo_items": 470, "cargo_kinds": 3,
        "line": "platform Starling lost flying nauvis->vulcanus 40% (medium-metallic-asteroid), 470 items in its hub"}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:1500]))
    if not ok:
        sys.exit(1)


def log_files():
    runs = tempfile.mkdtemp()
    a, b = os.path.join(runs, "s1"), os.path.join(runs, "s2")
    os.makedirs(a); os.makedirs(b)
    open(os.path.join(b, "resumed-from"), "w").write("s1\n")
    pa = chronicle_log.path_for(a)
    e, v = chronicle_log.append(pa, {"entries": [dict(ENTRY, seq=1), dict(ENTRY, seq=2)], "events": [LOST]}, 1, 0, now=5.0)
    check("only rows after the cursors are written", [x["seq"] for x in e] == [2] and [x["id"] for x in v] == [9]
          and e[0]["type"] == "entry" and v[0]["type"] == "event" and e[0]["t"] == 5.0, (e, v))
    check("the file's cursors", chronicle_log.last_cursors(pa) == (2, 9))
    check("a new shift starts after the shift it resumed from", chronicle_log.start_cursors(chronicle_log.path_for(b)) == (2, 9))
    check("load reads them back", [len(x) for x in chronicle_log.load(a)] == [1, 1])
    return runs


def stream_read(runs):
    run = os.path.join(runs, "s2")
    calls = []

    class H:
        def operator_read(self, action, args=None):
            calls.append((action, dict(args or {})))
            if action == "chronicle":
                if args.get("since", 0) >= 3:
                    return {"entries": [], "events": [], "cursor": 1, "events_cursor": 1}, 9000  # a fresh world
                return {"entries": [ENTRY], "events": [dict(LOST, id=10)], "cursor": 3, "events_cursor": 10}, 9000
            return {"cursor": 0}, 9000
    src = live.LiveSource.__new__(live.LiveSource)
    src.h, src.caps = H(), {"harness": True}
    src.has_board, src.next_board_probe = False, time.time() + 999
    src.has_confess = src.has_tells = src.has_operator = False
    src.has_chronicle, src.chronicle_path = True, chronicle_log.path_for(run)
    src.chronicle_seq, src.chronicle_eid = chronicle_log.start_cursors(src.chronicle_path)
    for name in ("observe_groups", "observe_hauling", "observe_efficiency", "observe_loadout", "observe_clouds"):
        setattr(src, name, lambda *a: None)
    obs, errors = {}, {}
    src.observe_board(obs, errors)
    check("the read asks after the run's cursors", calls[-1] == ("chronicle", {"since": 2, "events_since": 9, "limit": 50}), calls)
    check("new rows to obs and the run's file, cursors moved", [e["seq"] for e in obs["chronicle"]["entries"]] == [3]
          and [v["id"] for v in obs["chronicle"]["events"]] == [10] and (src.chronicle_seq, src.chronicle_eid) == (3, 10)
          and chronicle_log.last_cursors(src.chronicle_path) == (3, 10) and not errors, (obs, errors))
    src.observe_board({}, {})
    check("a fresh world (its cursors below the stream's): the stream's cursors go back to 0", (src.chronicle_seq, src.chronicle_eid) == (0, 0))
    src.observe_board({}, {})
    check("and the next read asks from the start", calls[-1][1]["since"] == 0 and calls[-1][1]["events_since"] == 0, calls[-1])
    check("harness.py allows the operator read", "chronicle" in __import__("harness").OPERATOR_READS)


def model_state():
    m = model.Model({"agents": {"sol": {}, "luna": {}}})
    now = time.time()
    m.ingest({"agents": [], "chronicle": {"entries": [ENTRY], "events": [LOST]}}, now)
    ch = m.snapshot(now)["chronicle"]
    e = ch["entries"][0]
    check("the entry in the state: its words, title, where, what it is filed beside", (e["agent"], e["title"], e["where"], e["about"][0][:17])
          == ("sol", "Starling falls", "nauvis", "platform Starling"), e)
    check("the event in the state with its details", ch["events"][0]["kind"] == "platform_lost" and ch["events"][0]["cargo_items"] == 470, ch["events"])
    # the stream sees Starling gone from two space reads: its loss line takes the harness's facts
    m._platform_destroyed({"name": "Starling", "at": None}, now + 5)
    lost = m.platforms_lost[-1]
    check("the stream's loss line: where it flew, what destroyed it, the cargo lost, the asteroids that hit it most",
          (lost["where"], lost["cause"], lost["cargo"], lost["hit_by"]) == ("flying nauvis->vulcanus 40%", "medium-metallic-asteroid",
                                                                           "450 iron-plate, 20 rocket-fuel, +1 kinds",
                                                                           "medium-metallic-asteroid, small-metallic-asteroid"), lost)
    alert = [a for a in m.alerts if (a.get("facts") or {}).get("headline") == "platform_destroyed"][-1]
    check("the hosts' facts carry the cargo lost", alert["facts"]["cargo_lost"] == "450 iron-plate, 20 rocket-fuel, +1 kinds", alert["facts"])
    # the other order: the stream saw it go before the harness's event came
    m2 = model.Model({"agents": {"sol": {}}})
    m2._platform_destroyed({"name": "Starling", "at": None}, now)
    m2.ingest({"agents": [], "chronicle": {"entries": [], "events": [LOST]}}, now + 3)
    check("a loss line the stream made first gets the harness's facts when they come", m2.platforms_lost[-1].get("cargo_items") == 470,
          m2.platforms_lost[-1])
    return m.snapshot(now)


def hosts_and_site(snap):
    import caster
    d = caster.Differ()
    d.diff({"agents": [], "chronicle": {"entries": []}})
    entry = dict(snap["chronicle"]["entries"][0], seq=4, t=time.time())
    ev = [e for e in d.diff({"agents": [], "chronicle": {"entries": [entry]}}) if e["kind"] == "chronicle"]
    check("a new entry is a beat for the hosts, with its words", len(ev) == 1 and ev[0]["text"].startswith("The rocks found Starling")
          and ev[0]["title"] == "Starling falls", ev)
    check("once", [e for e in d.diff({"agents": [], "chronicle": {"entries": [entry]}}) if e["kind"] == "chronicle"] == [])
    f = caster.facts_for(ev[0], {"game_time": "0h02m", "agents": []})
    check("its facts: the entry and how to call it", f["chronicle_entry"]["title"] == "Starling falls" and "chronicle" in f["how_to_call_it"], f)
    import push_live
    out = push_live.public_state(dict(json.load(open(os.path.join(HERE, "..", "..", "site", "live", "state.example.json"))),
                                      chronicle=snap["chronicle"]))
    check("push_live sends the state's chronicle", out["chronicle"]["entries"][0]["text"].startswith("The rocks found Starling")
          and out["chronicle"]["events"][0]["cargo_items"] == 470, out.get("chronicle"))


def main():
    runs = log_files()
    stream_read(runs)
    snap = model_state()
    hosts_and_site(snap)
    print("chronicle: ok (the run file and its cursors, the read every poll, the state, the loss line's facts, the hosts' "
          "beat, push_live)")


if __name__ == "__main__":
    main()
