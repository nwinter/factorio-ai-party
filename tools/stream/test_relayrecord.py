#!/usr/bin/env python3
"""A relayed line keeps whom it went to across stream service restarts (d20 batch57 S5, Nick 19:05: "what's this 'relayed:
before the restart'?"): python3 tools/stream/test_relayrecord.py

viewers.py: the relay writes each relayed line's record to runs/RUN/viewer-relayed.jsonl (to, to_all, why, when sent);
a restart's re-read (backlog_status for a line past max_age, the relay's relayed_before for a newer one) shows that
record, also from the previous run's file (resumed-from); a row from before (id, t, name only) shows "relayed" with
lost; push_live publishes lost and the time sent; the site says "to Sol, Luna (sent 14:02): why" or "sent to the agents
(details lost at a stream service restart)". On d20, at each of the 11 stream service starts 17 to 46 of the 50 site
lines read again showed "relayed: before the restart" (241 lines in all; 42 after the 19:02 start).
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SITE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "site")
sys.path.insert(0, SITE)
import viewers as V  # noqa: E402

V.log = lambda msg: None
AGENTS = ["astra", "sol", "luna", "opus"]


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


def main():
    NOW = 1792540000.0
    root = tempfile.mkdtemp()
    try:
        prev, run = os.path.join(root, "shift47"), os.path.join(root, "shift48")
        os.makedirs(prev)
        os.makedirs(run)
        open(os.path.join(run, "resumed-from"), "w").write("shift47\n")
        # the previous run: one row written before this change (no record), one with its record
        with open(os.path.join(prev, V.RELAYED_FILE), "w") as f:
            f.write(json.dumps({"id": "site:3601", "t": NOW - 7200, "name": "Aurora"}) + "\n")
            f.write(json.dumps({"id": "site:3602", "t": NOW - 7100, "name": "Caleb", "to": "opus", "to_all": ["opus"],
                                "why": "about Nauvis power"}) + "\n")
        switch = os.path.join(run, "viewers-relay.on")
        open(switch, "w").close()
        h = Harness()
        relay = V.Relay(h, switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
        feed = V.Feed({}, V.Filter(AGENTS), V.Clef(AI()), relay=relay)
        feed.ingest([line(3700, "Foobator", "@Sol @Luna both of you: the hub needs cargo bays", NOW)], [], now=NOW)
        sent = relay.step(NOW + 1)
        assert sent and sent["id"] == "site:3700" and sent["to_all"] == ["sol", "luna"], sent
        rows = [json.loads(l) for l in open(os.path.join(run, V.RELAYED_FILE))]
        assert rows[-1]["id"] == "site:3700" and rows[-1]["to"] == "sol" and rows[-1]["to_all"] == ["sol", "luna"] and \
            rows[-1]["t"] == round(NOW + 1, 1), rows
        # the restart: a new service reads the backlog again (one line past max_age, one newer)
        later = NOW + 600
        h2 = Harness()
        r2 = V.Relay(h2, switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
        assert set(r2.done) == {"site:3601", "site:3602", "site:3700"}, list(r2.done)
        f2 = V.Feed({}, V.Filter(AGENTS), V.Clef(AI()), relay=r2)
        f2.ingest([line(3601, "Aurora", "@Astra hull?", NOW - 7300, backlog=True),
                   line(3602, "Caleb", "@Opus more power", NOW - 7200, backlog=True),
                   line(3700, "Foobator", "@Sol @Luna both of you: the hub needs cargo bays", NOW, backlog=True)], [], now=later)
        assert r2.step(later + 1) is None and not h2.says  # nothing sent again
        d = {r["id"]: r for r in f2.lane()[1]["delivery"]}
        a, c = d["site:3700"], d["site:3602"]
        assert a["status"] == "relayed" and a["to"] == "sol" and a["to_all"] == ["sol", "luna"] and a["sent_t"] == round(NOW + 1, 1), a
        assert c["status"] == "relayed" and c["to"] == "opus" and c["why"] == "about Nauvis power" and not c.get("lost"), c
        lost = d["site:3601"]
        assert lost["status"] == "relayed" and lost.get("lost") and not lost.get("why") and not lost.get("to"), lost
        assert not any(r.get("why") == "before the restart" for r in d.values())
        # a line the restart re-reads before it is past max_age (the relay's relayed_before) reads the same
        f3 = V.Feed({}, V.Filter(AGENTS), V.Clef(AI()), relay=r2)
        f3.ingest([line(3700, "Foobator", "@Sol @Luna both of you: the hub needs cargo bays", later - 30, backlog=True)], [], now=later)
        d3 = {r["id"]: r for r in f3.lane()[1]["delivery"]}
        assert d3["site:3700"]["to_all"] == ["sol", "luna"] and d3["site:3700"]["why"] != "relayed before", d3
        # the site's state
        import push_live
        pub = push_live.public_delivery({"delivery": list(d.values())})
        assert pub["3601"] == {"s": "relayed", "lost": 1}, pub["3601"]
        assert pub["3700"]["to_all"] == ["sol", "luna"] and pub["3700"]["at"] == round(NOW + 1), pub["3700"]
        site(pub, NOW)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("relay record: ok (whom a line went to, why and when, kept across restarts and runs; a lost record says so)")


def site(pub, NOW):
    """live.js deliveryHtml under node."""
    if not shutil.which("node"):
        print("relay record: site part skipped (no node)")
        return
    code = open(os.path.join(SITE, "static", "live.js")).read()
    fn = code[code.index("  function agentName(n)"):code.index("  function renderChat()")]
    msgs = [{"src": "site", "seq": 3601, "t": NOW - 7300}, {"src": "site", "seq": 3700, "t": NOW - 300},
            {"src": "site", "seq": 3602, "t": NOW - 7100 - 30}]
    js = ("var team = {sol: {display_name: 'Sol'}, luna: {display_name: 'Luna'}, opus: {display_name: 'Opus'}};"
          "function esc(s) { return String(s); }" + fn + "\nvar delivery = " + json.dumps(pub) + ";\n"
          "process.stdout.write(JSON.stringify(" + json.dumps(msgs) + ".map(deliveryHtml)));")
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(js)
    try:
        r = subprocess.run(["node", f.name], capture_output=True, text=True, timeout=10)
    finally:
        os.unlink(f.name)
    assert r.returncode == 0, r.stderr
    out = [re.sub(r"<[^>]+>", "", h).strip() for h in json.loads(r.stdout)]
    assert out[0] == "delivered to the agents (details lost at a stream service restart)", out
    assert re.fullmatch(r"delivered to Sol, Luna \(sent \d\d:\d\d( [AP]M)?\)", out[1]), out
    assert out[2] == "delivered to Opus: about Nauvis power", out  # sent within a minute of the line: no time


if __name__ == "__main__":
    main()
