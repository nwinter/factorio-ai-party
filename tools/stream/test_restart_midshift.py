#!/usr/bin/env python3
"""A mid-shift stream service restart (d22 batch89 AY3, review AU1 finding 4): python3 tools/stream/test_restart_midshift.py

1. model.py: the shift's rocket count at its first service start is kept in space-memory.json, so after a restart the
   next rocket is not "the first this shift" (shift57 09:02: "Rocket 20001 is up. First launch…", the shift's first at
   06:21); a new run's first start seeds its own.
2. viewers.py: a backlog line read again at a restart that was relayed already keeps its record instead of going
   through the per-author rate filter again ("not relayed: rate", site:4142 and site:4181 in shift57).
"""
import json, os, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model  # noqa: E402
import viewers as V  # noqa: E402

V.log = lambda msg: None
AGENTS = ["astra", "sol", "haiku"]


def rockets(root):
    run = os.path.join(root, "shift57")
    os.makedirs(run)
    mem = os.path.join(run, "space-memory.json")
    m = Model({})
    m.set_space_memory(mem)
    m.space = {"rockets": 19247}
    m._space_moments(1000.0)              # the shift's first start: seeded, kept
    assert m.rockets_at_start == 19247 and json.load(open(mem))["rockets_at_start"] == 19247
    m.space = {"rockets": 19248}
    m._space_moments(1010.0)
    assert [x["kind"] for x in m.moments] == ["shift_rocket"], m.moments
    # the restart, 750 rockets later: the first-this-shift moment does not fire again
    m2 = Model({})
    m2.set_space_memory(mem)
    assert m2.rockets_at_start == 19247
    m2.space = {"rockets": 20000}
    m2._space_moments(2000.0)
    m2.space = {"rockets": 20001}
    m2._space_moments(2010.0)
    assert not [x for x in m2.moments if x["kind"] == "shift_rocket"], m2.moments
    # the next run: its own count (the earlier run's file gives stops only)
    run2 = os.path.join(root, "shift58")
    os.makedirs(run2)
    m3 = Model({})
    m3.set_space_memory(os.path.join(run2, "space-memory.json"), [mem])
    assert m3.rockets_at_start is None
    m3.space = {"rockets": 20336}
    m3._space_moments(3000.0)
    assert m3.rockets_at_start == 20336


class Harness:
    def __init__(self):
        self.says = []

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": [], "open": []}})
        self.says.append(req["args"])
        return json.dumps({"ok": True, "result": {"posted": True, "seq": len(self.says)}})


class AI:
    def run(self, model, body):
        return {"answers": {k: {"choice": "fine"} for k in body["questions"]}}


def line(i, name, text, t, **kw):
    return dict({"id": f"site:{i}", "source": "site", "author": "site:" + name, "name": name, "text": text, "t": t}, **kw)


def backlog(root):
    NOW = 1792680000.0
    run = os.path.join(root, "shift57b")
    os.makedirs(run)
    switch = os.path.join(run, "viewers-relay.on")
    open(switch, "w").close()
    with open(os.path.join(run, V.RELAYED_FILE), "w") as f:  # relayed before the restart
        f.write(json.dumps({"id": "site:4142", "t": NOW - 40, "name": "Foobator", "to": "haiku", "to_all": ["haiku"],
                            "why": "addressed"}) + "\n")
    relay = V.Relay(Harness(), switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
    feed = V.Feed({}, V.Filter(AGENTS), V.Clef(AI()), relay=relay)
    # the restart re-reads Foobator's newer line and the one already relayed, seconds apart
    feed.ingest([line(4143, "Foobator", "haiku: and the second one?", NOW - 20, backlog=True),
                 line(4142, "Foobator", "haiku: how many cargo bays?", NOW - 15, backlog=True)], [], now=NOW)
    d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
    assert d["site:4142"]["status"] == "relayed" and d["site:4142"]["to"] == "haiku", d["site:4142"]
    assert not any("rate" in str(r.get("why")) and r["id"] == "site:4142" for r in d.values()), d


def main():
    root = tempfile.mkdtemp()
    try:
        rockets(root)
        backlog(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("mid-shift restart: ok (the shift's rocket count kept across a restart; a relayed backlog line keeps its record)")


if __name__ == "__main__":
    main()
