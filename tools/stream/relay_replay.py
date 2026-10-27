#!/usr/bin/env python3
"""Replay a shift's viewer lines through the relay rules, before and after a change, and count what reaches the agents.

  python3 tools/stream/relay_replay.py [--before REV] [--from T --to T] [--show] LOG.jsonl ...
  python3 tools/stream/relay_replay.py ~/code/player-of-games/tools/stream/logs/viewers-20261012-1*.jsonl

LOG files are viewers.py verdict logs (tools/stream/logs/viewers-*.jsonl). Replayed in time order (each id once: a
restart writes a new log): the lines that passed the filters, and (d27 batch263 VR) the lines whose only reasons were
the lane's rate limits ("rate", "busy"), which go through that revision's own Filter Limiter again. They go through
viewers.Feed + Relay with the shift01 roster, into a harness that keeps that revision's viewer_say limits (audience.lua
VIEWER_GAP, VIEWER_MAX and the 10 s part rule; it refuses with viewer_rate or global_rate as the game does).
"Before" is viewers.py and audience.lua at REV (default main), "after" the working tree. Counted per line: delivered,
addressed (the posted line @-mentions an agent, which wakes it), rate (dropped by the lane's limits), not sent (the
viewer's author gap, or stale behind others), chatter (shown, not relayed). --show prints, per line, when it was
written and when it reached the game (seconds after it was written), or why not.
"""
import argparse, collections, glob, importlib.util, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))  # tools/ (viewers.py's toolcall), for a copy of viewers.py elsewhere
sys.dont_write_bytecode = True
OWNERS = {"NickWinter"}  # YouTube channel owner (staff in the lane)
ROSTER = [(n, None) for n in ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]]
AUDIENCE = "vendor/factorio-harness/mod/agent-harness_0.1.0/audience.lua"
LIMIT_ONLY = {"rate", "busy"}


def viewer_limits(lua):
    """(gap s, lines a minute, part window s) from audience.lua's text."""
    consts = {}
    for names, vals in re.findall(r"^\s*local\s+([A-Z_][A-Z_0-9, ]*?)\s*=\s*([0-9*+ ,]+?)\s*(?:--.*)?$", lua, re.M):
        for k, v in zip([x.strip() for x in names.split(",")], [x.strip() for x in vals.split(",")]):
            p = 1
            for f in v.split("*"):
                p *= int(f)
            consts[k] = p  # "20 * 60" -> 1200
    return consts.get("VIEWER_GAP", 1200) / 60.0, consts.get("VIEWER_MAX", 6), consts.get("PART_TICKS", 600) / 60.0


class Harness:
    """viewer_say as audience.lua limits it: one line per viewer every gap s, max lines a minute in all; a part 2.. of
    a line posted within part_s is no new line. now: set by the replay before each relay step."""

    def __init__(self, gap=None, per_min=None, part_s=10.0):
        self.says, self.now = [], 0.0
        self.gap, self.per_min, self.part_s = gap, per_min, part_s
        self.recent, self.by_name = [], {}

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd, re.S).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": []}})
        a, now = req["args"], self.now
        if self.gap is not None:
            key = a["name"].lower()
            last = self.by_name.get(key)
            cont = (a.get("part") or 1) > 1 and last is not None and now - last <= self.part_s
            if not cont:
                self.recent = [t for t in self.recent if now - t < 60]
                if last is not None and now - last < self.gap:
                    return json.dumps({"ok": True, "result": {"posted": False, "dropped": "viewer_rate",
                                                              "retry_after_s": int(self.gap - (now - last)) + 1}})
                if len(self.recent) >= self.per_min:
                    return json.dumps({"ok": True, "result": {"posted": False, "dropped": "global_rate",
                                                              "retry_after_s": int(60 - (now - self.recent[0])) + 1}})
                self.recent.append(now)
                self.by_name[key] = now
        self.says.append(dict(a, at=now))
        return json.dumps({"ok": True, "result": {"posted": True}})


def show(rev, path):
    return subprocess.run(["git", "-C", HERE, "show", f"{rev}:{path}"], capture_output=True, text=True, check=True).stdout


def load(rev):
    root = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    if rev is None:
        import viewers
        lua = open(os.path.join(root, AUDIENCE)).read() if os.path.exists(os.path.join(root, AUDIENCE)) else ""
        return viewers, lua
    src = show(rev, "tools/stream/viewers.py")
    path = os.path.join(tempfile.mkdtemp(), "viewers_before.py")
    open(path, "w").write(src)
    spec = importlib.util.spec_from_file_location("viewers_before", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    try:
        lua = show(rev, AUDIENCE)
    except subprocess.CalledProcessError:
        lua = ""
    return mod, lua


def rows_of(paths, t0=None, t1=None):
    seen, rows = set(), []
    for p in paths:
        for line in open(p):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            ok = r.get("pass") or (r.get("reasons") and set(r["reasons"]) <= LIMIT_ONLY)
            if ok and r.get("text") and r.get("id") not in seen and (t0 is None or r["t"] >= t0) and (t1 is None or r["t"] <= t1):
                seen.add(r["id"])
                rows.append(r)
    return sorted(rows, key=lambda r: r["t"])


def replay(V, lua, rows):
    sw = os.path.join(tempfile.mkdtemp(), "relay.on")
    open(sw, "w").close()
    gap, per_min, part_s = viewer_limits(lua) if lua else (None, None, 10.0)
    h = Harness(gap, per_min, part_s)
    relay = V.Relay(h, sw, roster=ROSTER)
    filt = V.Filter([n for n, _ in ROSTER])
    feed = V.Feed({}, filt, relay=relay)
    rated = {}

    def check(m, now):
        # these lines passed the content filters live; the lane's rate limits are this revision's own
        out = dict(id=m["id"], source=m["source"], name=m["name"], text=m["text"], t=m["t"], order=False,
                   **({"staff": m["staff"]} if m.get("staff") else {}))
        r = None if m.get("staff") else filt.limit.check(m["author"], now)
        if r:
            rated[m["id"]] = r
        return out, [r] if r else []
    feed.filt.check = check
    sent, at = {}, {}
    t_prev = None
    for r in rows + [None]:
        t = r["t"] if r else (t_prev or 0) + 300
        k = (t_prev or t)
        while k < t:  # the relay thread steps every 2 s
            h.now = k
            n = len(h.says)
            m = relay.step(k)
            if m:
                sent[m["id"]] = h.says[n]["text"] if len(h.says) > n else ""
                at[m["id"]] = [s["at"] for s in h.says[n:]]
            k += 2
        if r:
            # the verdict log has no staff field: the channel owner's lines are marked as the lane marks them
            feed.ingest([{"id": r["id"], "source": r.get("source", "youtube"), "author": r.get("author") or r.get("name"),
                          "name": r.get("name"), "text": r["text"], "t": r["t"],
                          "staff": "owner" if r.get("name") in OWNERS else None}], [], now=r["t"])
        t_prev = t
    names = [n for n, _ in ROSTER]
    addressed = [i for i, txt in sent.items() if any(re.search(r"@" + n + r"\b", txt.lower()) for n in names)]
    chatter = [r["id"] for r in rows if getattr(V, "is_chatter", None) and V.is_chatter(r["text"]) and r["id"] not in sent]
    lane = {m["id"]: m for m in feed.lane_msgs}
    fate = {}
    for r in rows:
        if r["id"] in sent:
            fate[r["id"]] = ("sent", at[r["id"]][0] - r["t"], len(at[r["id"]]))
        elif r["id"] in rated:
            fate[r["id"]] = ("dropped: " + rated[r["id"]], None, 0)
        else:
            m = lane.get(r["id"]) or {}
            fate[r["id"]] = ("not sent: " + str(m.get("delivery_why") or m.get("delivery") or "?"), None, 0)
    return {"lines": len(rows), "delivered": len(sent), "addressed": len(addressed), "rate": len(rated),
            "not_sent": len(rows) - len(sent) - len(chatter) - len(rated), "chatter": len(chatter),
            "dropped": dict(relay.dropped)}, fate


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--before", default="main")
    ap.add_argument("--from", dest="t0", type=float, help="first line's time (unix s)")
    ap.add_argument("--to", dest="t1", type=float, help="last line's time (unix s)")
    ap.add_argument("--show", action="store_true", help="each line: written, and when it reached the game, before and after")
    a = ap.parse_args()
    rows = rows_of([p for g in a.logs for p in glob.glob(os.path.expanduser(g))], a.t0, a.t1)
    before, fb = replay(*load(a.before), rows)
    after, fa = replay(*load(None), rows)
    print(f"{len(rows)} viewer lines that passed the filters (or were dropped only by the lane's rate limits)")
    print("before", json.dumps(before))
    print("after ", json.dumps(after))
    if a.show:
        import time as _t
        for r in rows:
            def fmt(f):
                return f"+{f[1]:.0f} s" + (f" ({f[2]} game lines)" if f[2] > 1 else "") if f[0] == "sent" else f[0]
            print(f"{_t.strftime('%H:%M:%S', _t.localtime(r['t']))} {r['id']} {r.get('name')}: before {fmt(fb[r['id']])};"
                  f" after {fmt(fa[r['id']])} | {r['text'][:60]}")


if __name__ == "__main__":
    main()
