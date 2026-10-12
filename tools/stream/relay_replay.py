#!/usr/bin/env python3
"""Replay a shift's viewer lines through the relay rules, before and after a change, and count what reaches the agents.

  python3 tools/stream/relay_replay.py [--before REV] LOG.jsonl ...
  python3 tools/stream/relay_replay.py ~/code/player-of-games/tools/stream/logs/viewers-20261012-1*.jsonl

LOG files are viewers.py verdict logs (tools/stream/logs/viewers-*.jsonl); the lines that passed the filters are
replayed in time order (each id once: a restart writes a new log) through viewers.Feed + Relay with the shift01 roster
and a harness that posts everything (the harness's own limits, 20 s per viewer and 6 a minute, are not modelled).
"Before" is viewers.py at REV (default 5b0c948, the relay before eng/relay2), "after" the working tree. Counted per
line: delivered, addressed (the posted line @-mentions an agent, which wakes it), not sent (the viewer's author gap,
or stale behind others), chatter (shown, not relayed).
"""
import argparse, collections, glob, importlib.util, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
OWNERS = {"NickWinter"}  # YouTube channel owner (staff in the lane)
ROSTER = [(n, None) for n in ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]]


class Harness:
    def __init__(self):
        self.says = []

    def command(self, cmd):
        import re
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd, re.S).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": []}})
        self.says.append(req["args"])
        return json.dumps({"ok": True, "result": {"posted": True}})


def load(rev):
    if rev is None:
        import viewers
        return viewers
    src = subprocess.run(["git", "-C", HERE, "show", f"{rev}:tools/stream/viewers.py"], capture_output=True,
                         text=True, check=True).stdout
    path = os.path.join(tempfile.mkdtemp(), "viewers_before.py")
    open(path, "w").write(src)
    spec = importlib.util.spec_from_file_location("viewers_before", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def rows_of(paths):
    seen, rows = set(), []
    for p in paths:
        for line in open(p):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("pass") and r.get("text") and r.get("id") not in seen:
                seen.add(r["id"])
                rows.append(r)
    return sorted(rows, key=lambda r: r["t"])


def replay(V, rows):
    sw = os.path.join(tempfile.mkdtemp(), "relay.on")
    open(sw, "w").close()
    h = Harness()
    relay = V.Relay(h, sw, roster=ROSTER)
    feed = V.Feed({}, V.Filter([n for n, _ in ROSTER]), relay=relay)
    feed.filt.check = lambda m, now: (dict(id=m["id"], source=m["source"], name=m["name"], text=m["text"], t=m["t"],
                                           order=False, **({"staff": m["staff"]} if m.get("staff") else {})), [])
    # (these lines passed the filters live)
    sent = {}
    t_prev = None
    for r in rows + [None]:
        t = r["t"] if r else (t_prev or 0) + 300
        k = (t_prev or t)
        while k < t:  # the relay thread steps every 2 s
            m = relay.step(k)
            if m:
                sent[m["id"]] = h.says[-1]["text"]
            k += 2
        if r:
            # the verdict log has no staff field: the channel owner's lines are marked as the lane marks them
            feed.ingest([{"id": r["id"], "source": r.get("source", "youtube"), "author": r.get("name"),
                          "name": r.get("name"), "text": r["text"], "t": r["t"],
                          "staff": "owner" if r.get("name") in OWNERS else None}], [], now=r["t"])
        t_prev = t
    lane = {m["id"]: m for m in feed.lane_msgs}
    names = [n for n, _ in ROSTER]
    import re
    addressed = [i for i, txt in sent.items() if any(re.search(r"@" + n + r"\b", txt.lower()) for n in names)]
    chatter = [r["id"] for r in rows if getattr(V, "is_chatter", None) and V.is_chatter(r["text"])]
    return {"lines": len(rows), "delivered": len(sent), "addressed": len(addressed),
            "not_sent": len(rows) - len(sent) - len(chatter), "chatter": len(chatter),
            "dropped": dict(relay.dropped)}, sent


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--before", default="5b0c948")
    ap.add_argument("--show", action="store_true", help="print each delivered line as posted (after)")
    a = ap.parse_args()
    rows = rows_of([p for g in a.logs for p in glob.glob(os.path.expanduser(g))])
    before, _ = replay(load(a.before), rows)
    after, sent = replay(load(None), rows)
    print(f"{len(rows)} viewer lines that passed the filters")
    print("before", json.dumps(before))
    print("after ", json.dumps(after))
    if a.show:
        for r in rows:
            print(("SENT " + sent[r["id"]]) if r["id"] in sent else ("---- " + r["text"]))


if __name__ == "__main__":
    main()
