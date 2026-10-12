#!/usr/bin/env python3
"""Agents' requests to the operator on the stream side: python3 tools/stream/test_operator_inbox.py

- operator_inbox.py appends new requests (after the cursor) to runs/RUN/operator-inbox.jsonl as {t, seq, agent, text};
  a restarted service resumes after the file's last seq, so nothing is written twice.
- live.py polls the operator read `operator_requests` once the runtime lists `operator`, with the file's cursor.
- model.py shows each on the ticker like a tell ("Astra → operator: ..."), once, and the snapshot carries the last few.
- caster.py makes a fresh one a host beat (kind operator), with how to call it.
"""
import json, os, sys, tempfile, time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import operator_inbox  # noqa: E402

fails = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    if not ok:
        fails.append(name)


# The inbox file.
run_dir = tempfile.mkdtemp()
path = operator_inbox.path_for(run_dir)
check("the inbox sits in the run directory", path == os.path.join(run_dir, "operator-inbox.jsonl"))
check("no file: cursor 0", operator_inbox.last_seq(path) == 0)
reqs = [{"seq": 1, "tick": 600, "from": "astra", "text": "a viewer asks for longer replies"},
        {"seq": 2, "tick": 900, "from": "sol", "text": "belt_route refuses a diagonal start"}]
rows = operator_inbox.append(path, reqs, 0, now=1000.0)
check("two rows written", [r["seq"] for r in rows] == [1, 2] and rows[0]["agent"] == "astra" and rows[0]["t"] == 1000.0,
      rows)
lines = [json.loads(l) for l in open(path)]
check("file rows: t, seq, agent, text", set(lines[0]) >= {"t", "seq", "agent", "text"} and lines[1]["text"] ==
      "belt_route refuses a diagonal start", lines)
check("a restart resumes after the last seq", operator_inbox.last_seq(path) == 2)
rows = operator_inbox.append(path, reqs + [{"seq": 3, "tick": 1200, "from": "grok", "text": "x"}], 2, now=1001.0)
check("only the new one is appended", [r["seq"] for r in rows] == [3] and len(open(path).readlines()) == 3)

# live.py: polled as an operator read with the cursor, rows go to obs and the file.
import live  # noqa: E402


class FakeHarness:
    def __init__(self):
        self.calls = []

    def operator_read(self, action, args=None):
        self.calls.append((action, dict(args or {})))
        if action == "operator_requests":
            since = (args or {}).get("since", 0)
            out = [r for r in reqs + [{"seq": 4, "tick": 1500, "from": "astra", "text": "fh view crops the legend"}]
                   if r["seq"] > since]
            return {"requests": out, "cursor": 4}, 1500
        return {"cursor": 0}, 1500


src = live.LiveSource.__new__(live.LiveSource)
src.h = FakeHarness()
src.caps = {"harness": True}
src.has_board, src.next_board_probe = False, time.time() + 999
src.has_confess, src.has_tells, src.has_operator = False, False, True
src.inbox_path, src.operator_seq = path, operator_inbox.last_seq(path)
obs, errors = {}, {}
src.observe_board(obs, errors)
check("live.py reads operator_requests since the file's last seq", src.h.calls == [("operator_requests",
      {"since": 3, "limit": 30})], src.h.calls)
check("live.py: the new row in obs and the file, cursor moved", [r["seq"] for r in obs.get("operator_requests") or []]
      == [4] and src.operator_seq == 4 and len(open(path).readlines()) == 4 and not errors, (obs, errors))
check("harness.py allows the operator read", "operator_requests" in __import__("harness").OPERATOR_READS)

# model.py: the ticker entry and the snapshot.
import model  # noqa: E402

m = model.Model({"agents": {"astra": {}, "sol": {}}})
now = time.time()
m.agents["astra"].display_name = "Astra"
m.ingest({"agents": [], "operator_requests": [{"t": now - 5, "seq": 4, "agent": "astra", "text": "fh view crops the legend",
                                               "tick": 1500}]}, now)
m.ingest({"agents": [], "operator_requests": [{"t": now - 5, "seq": 4, "agent": "astra", "text": "fh view crops the legend",
                                               "tick": 1500}]}, now)
snap = m.snapshot(now)
ticker = [c for c in snap["chat"] if c.get("operator")]
check("one ticker line, shown like a tell to the operator", len(ticker) == 1 and ticker[0]["tell"] and ticker[0]["lane"]
      == "tell" and ticker[0]["to_shown"] == "operator" and ticker[0]["body"] == "fh view crops the legend"
      and ticker[0]["agent"] == "astra", ticker)
check("the snapshot carries the last few", [(r["agent"], r["display_name"], r["text"]) for r in snap["operator_requests"]]
      == [("astra", "Astra", "fh view crops the legend")], snap.get("operator_requests"))

# caster.py: a fresh one is a host beat; the template names the agent and the request.
import caster  # noqa: E402

d = caster.Differ()
d.diff({"agents": [], "chat": []})
ev = d.diff({"agents": [], "chat": ticker})
op = [e for e in ev if e["kind"] == "operator_request"]
check("a fresh request is an operator beat", len(op) == 1 and op[0]["agent"] == "astra" and op[0]["text"] ==
      "fh view crops the legend" and op[0]["prio"] == caster.PRIORITY["operator_request"], ev)
check("not also a chat beat", not [e for e in ev if e["kind"] == "chat"], ev)
f = caster.facts_for(op[0], {"agents": []})
check("facts say how to call it", "operator" in f.get("how_to_call_it", ""), f)

print(f"\n{'all ok' if not fails else str(len(fails)) + ' failed: ' + '; '.join(fails)}")
sys.exit(1 if fails else 0)
