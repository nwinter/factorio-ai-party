#!/usr/bin/env python3
"""Each chronicle row once, under the shift it happened in, no network: python3 tools/stream/test_chronicle_once.py

d20 batch65 AA3 (viewer Aurora 08:29: "Could Chronicle show each entry once under its original shift? 'Oxidizer kit
launched' at 58h34m appears 21 times, including under Shift 51"). That entry (seq 21, tick 12652195, by grok) was in
the files of shift16 and of the 20 shifts after it: a stream service restarted while its run's file had events but no
entries took its entry cursor as 0 and wrote the save's last 50 entries again (shift51 at 06:14), and the reverse for
events. Checks: start_cursors takes each cursor on its own; the model leaves out rows earlier shifts wrote; the
platform history counts a departure once; site/chronicle.py keeps each row once under the shift whose tick window
holds it (else the first file with it), for the Chronicle page, the timeline and the platform table.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path[:0] = [HERE, os.path.join(ROOT, "site")]
import chronicle_log  # noqa: E402

OX = {"seq": 21, "tick": 12652195, "game_time": "58h34m", "agent": "grok", "title": "Oxidizer kit launched",
      "text": "At 58h33 the Nauvis rocket carried the Starling oxidizer kit.", "planet": "nauvis"}


def entry(seq, tick, **kw):
    return dict({"type": "entry", "seq": seq, "tick": tick, "agent": "luna", "text": f"entry {seq}", "t": 1}, **kw)


def event(eid, tick, kind="rocket", **kw):
    return dict({"type": "event", "id": eid, "tick": tick, "kind": kind, "line": f"event {eid}", "t": 1}, **kw)


def write_run(root, name, rows, parent=None):
    d = os.path.join(root, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, chronicle_log.NAME), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    if parent:
        with open(os.path.join(d, "resumed-from"), "w") as f:
            f.write(parent)
    return os.path.join(d, chronicle_log.NAME)


def cursor_tests(root):
    write_run(root, "s1", [entry(69, 100), entry(70, 200), event(3000, 150), event(3001, 210)])
    # a new shift's file with events but no entry yet (shift51 at 06:14): entries go on after the shift before
    p2 = write_run(root, "s2", [event(3002, 300), event(3003, 310)], parent="s1")
    assert chronicle_log.start_cursors(p2) == (70, 3003), chronicle_log.start_cursors(p2)
    # the reverse: entries but no event yet
    p3 = write_run(root, "s3", [entry(71, 400)], parent="s2")
    assert chronicle_log.start_cursors(p3) == (71, 3003), chronicle_log.start_cursors(p3)
    # a new shift's empty file, and a fresh chain
    assert chronicle_log.start_cursors(write_run(root, "s4", [], parent="s3")) == (71, 3003)
    assert chronicle_log.start_cursors(write_run(root, "lone", [])) == (0, 0)
    # the save's read (its last 50 of each) after those cursors writes nothing again
    seq, eid = chronicle_log.start_cursors(p2)
    reply = {"entries": [dict(entry(s, s * 2), type=None) for s in range(21, 71)], "events": [event(3002, 300)]}
    out = tempfile.mktemp()
    assert chronicle_log.append(out, reply, seq, eid) == ([], []) and not os.path.exists(out)


def model_tests(root):
    """A file that carries an earlier shift's rows (written before the fix): the live card leaves them out."""
    import model
    write_run(root, "m1", [entry(70, 200), event(3001, 210, kind="platform_left", platform="Swift"),
                           event(3000, 150, kind="platform_created", platform="Swift")])
    p = write_run(root, "m2", [event(3002, 300), entry(70, 200), event(3001, 210, kind="platform_left", platform="Swift")],
                  parent="m1")
    m = model.Model({"agents": {n: {} for n in ("luna", "grok")}})
    m.set_platform_history(p)
    assert m.platform_history["Swift"]["left"] == [210], m.platform_history  # once, though m2 carries it again
    m._ingest_chronicle_entry(entry(70, 200), 1.0)
    m._ingest_chronicle_event(event(3001, 210, kind="platform_left", platform="Swift"), 1.0)
    assert not m.chronicle_entries and not m.chronicle_events, (m.chronicle_entries, m.chronicle_events)
    m._ingest_chronicle_entry(entry(71, 400), 1.0)
    m._ingest_chronicle_event(event(3003, 410), 1.0)
    assert [e["seq"] for e in m.chronicle_entries] == [71] and [e["id"] for e in m.chronicle_events] == [3003]
    # the same seq at another tick (a fresh world counting from 1 again) is a new entry
    m._ingest_chronicle_entry(entry(70, 500), 1.0)
    assert [e["seq"] for e in m.chronicle_entries] == [71, 70]


def site_tests(root):
    import chronicle
    runs = os.path.join(root, "runs")
    ox = dict(OX, type="entry", t=1)
    lost = event(134, 12700000, kind="platform_lost", platform="Starling", where="at Nauvis")
    # A: before the chronicle (no file); B wrote the entry in its own window, C and D carried it and the loss again;
    # a row between B's and C's windows, first in C's file, stays under C; one in A's window, first in C's, goes to A
    write_run(runs, "A", [])
    os.remove(os.path.join(runs, "A", chronicle_log.NAME))
    write_run(runs, "B", [ox, entry(22, 12676980), lost], parent="A")
    write_run(runs, "C", [ox, entry(22, 12676980), entry(23, 12740000), entry(5, 11000000), lost, event(140, 12800000)], parent="B")
    write_run(runs, "D", [ox, entry(22, 12676980), entry(23, 12740000), lost, event(140, 12800000), event(150, 13700000)],
              parent="C")
    long = {"shifts": [{"id": "A", "n": 1, "raw0": 10900000, "raw1": 11800000},
                       {"id": "B", "n": 2, "raw0": 11866018, "raw1": 12734937},
                       {"id": "E", "n": None, "empty": True},
                       {"id": "C", "n": 3, "raw0": 12750298, "raw1": 13615884},
                       {"id": "D", "n": 4, "raw0": 13630086, "raw1": 14475436}]}
    shifts = chronicle.by_shift(long, runs)
    got = {s["n"]: ([e["tick"] for e in s["entries"]], [e["tick"] for e in s["events"]]) for s in shifts}
    assert got == {1: ([11000000], []), 2: ([12652195, 12676980], [12700000]), 3: ([12740000], [12800000]),
                   4: ([], [13700000])}, got
    body, _ = chronicle.build_page(shifts, lambda k: {"name": k}, lambda k, s: "", lambda s: str(s), lambda t: f"t{t}")
    assert body.count("Oxidizer kit launched") == 1 and body.count("Platform Starling lost") == 1, body
    assert 'Shift 2</a> <span class="muted small">2 entries · 1 event</span>' in body, body
    assert 'Shift 4</a> <span class="muted small">0 entries · 1 event</span>' in body
    assert "The agents' entries (4)" in body and "The harness's record (3)" in body
    rows, covered = chronicle.timeline_rows(long, runs)
    assert [r[:2] for r in rows] == [(12700000, 2)] and covered == {"B": {("lost", "Starling")}}, (rows, covered)
    assert list(chronicle.platform_losses(long, runs)) == ["Starling"]


def main():
    root = tempfile.mkdtemp()
    cursor_tests(root)
    model_tests(root)
    site_tests(root)
    print("chronicle once: ok (each cursor on its own at a restart; the live card leaves out earlier shifts' rows; "
          "the site keeps each row once under the shift whose tick window holds it, with its counts)")


if __name__ == "__main__":
    main()
