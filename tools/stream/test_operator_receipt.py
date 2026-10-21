#!/usr/bin/env python3
"""A viewer line that reached the operator's inbox, apart from the relay's refusals, no network:
python3 tools/stream/test_operator_receipt.py

d20 batch65 AA1 (viewer Aurora 04:06 PDT: "Could chat show confirmed Operator inbox delivery separately from game relay
rejection? The artillery report still says not relayed despite your reply"). Her 03:51 site line "@operator Could
artillery remote results use manual range? ..." (site:3817) was refused by Clef as clef:injection, written to
runs/shift50/operator-inbox.jsonl with dropped, and the site showed "not relayed: clef:injection" beside a small "to the
operator". Checks: a refused line to the operator alone is delivered to the operator with the refusal as its reason; one
that addresses an agent too stays not relayed with the inbox receipt; a passed one is to the operator; at a restart a
backlog line in the inbox (this run's or the one it resumed from) keeps that receipt, and one not in it keeps its verdict.
"""
import json, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402

V.log = lambda msg: None
AGENTS = ["astra", "sol", "muse", "opus"]
NOW = 1792579908.741
ARTILLERY = ("@operator Could artillery remote results use manual range? Public code creates a flare but checks automatic "
             "reach, which can wrongly report that no loaded gun can hit a target.")


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
    """Clef: "injection" for a line holding one of `bad`, else fine."""

    def __init__(self, bad=()):
        self.bad = bad

    def run(self, model, body):
        return {"answers": {k: {"choice": "injection" if any(b in q["instructions"] for b in self.bad) else "fine"}
                            for k, q in body["questions"].items()}}


def line(i, name, text, t, **kw):
    return dict({"id": f"site:{i}", "source": "site", "author": "site:" + name, "name": name, "text": text, "t": t}, **kw)


def setup(tmp, bad=()):
    switch = os.path.join(tmp, "relay.on")
    open(switch, "w").close()
    h = Harness()
    relay = V.Relay(h, switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
    inbox = os.path.join(tmp, "operator-inbox.jsonl")
    return V.Feed({}, V.Filter(AGENTS), V.Clef(AI(bad)), relay=relay, inbox=inbox), h, inbox


def deliveries(feed):
    return {r["id"]: r for r in feed.lane()[1]["delivery"]}


def main():
    tmp = tempfile.mkdtemp()
    feed, h, inbox = setup(tmp, bad=("manual range", "stop building"))
    feed.ingest([line(3817, "Aurora", ARTILLERY, NOW), line(3818, "Foobator", "@operator @astra stop building turrets now", NOW + 5)], [], now=NOW + 5)
    feed.ingest([line(3824, "Aurora", "@operator Could chat show confirmed Operator inbox delivery separately?", NOW + 900)], [], now=NOW + 900)
    rows = [json.loads(l) for l in open(inbox)]
    assert [r["dropped"] for r in rows if r.get("dropped")] == ["clef:injection", "clef:injection"], rows
    d = deliveries(feed)
    # Aurora's 03:51 line: in the inbox, to the operator alone: delivered, Clef's refusal as its reason
    assert d["site:3817"]["status"] == "operator" and d["site:3817"]["inbox"] is True, d["site:3817"]
    assert d["site:3817"]["why"] == "kept off the stream: clef:injection", d["site:3817"]
    # to the operator and an agent, refused: not relayed (the agents' copy), the inbox receipt beside it
    assert d["site:3818"]["status"] == "not_relayed" and d["site:3818"]["why"] == "clef:injection" and d["site:3818"]["inbox"], d["site:3818"]
    # a passed line to the operator: to the operator
    assert d["site:3824"]["status"] == "operator" and d["site:3824"]["why"] == "to the operator's inbox", d["site:3824"]
    assert not h.says, h.says
    # the payload the site reads (push_live.public_delivery)
    sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
    import push_live
    pub = push_live.public_delivery(feed.lane()[1])
    assert pub["3817"] == {"s": "operator", "op": 1, "why": "kept off the stream: clef:injection"}, pub["3817"]
    assert pub["3818"] == {"s": "not_relayed", "op": 1, "why": "clef:injection"}, pub["3818"]

    # a restart: the backlog read again; the inbox rows of this run and the one it resumed from keep the receipt
    base = tempfile.mkdtemp()
    prev, cur = os.path.join(base, "shift49"), os.path.join(base, "shift50")
    os.makedirs(prev), os.makedirs(cur)
    open(os.path.join(cur, "resumed-from"), "w").write("shift49\n")
    old = NOW - 3600
    with open(os.path.join(prev, "operator-inbox.jsonl"), "w") as f:
        f.write(json.dumps({"t": round(old - 50, 1), "agent": "viewer Aurora", "text": "@operator earlier", "viewer": True, "source": "site"}) + "\n")
    with open(os.path.join(cur, "operator-inbox.jsonl"), "w") as f:
        f.write(json.dumps({"t": round(old, 1), "agent": "viewer Aurora", "text": ARTILLERY, "viewer": True, "source": "site", "dropped": "clef:injection"}) + "\n")
        f.write(json.dumps({"t": old + 10, "agent": "astra", "text": "an agent's request", "seq": 4}) + "\n")
    logs = os.path.join(base, "logs")
    os.makedirs(logs)
    with open(os.path.join(logs, "viewers-1.jsonl"), "w") as f:
        for i, ok, why in ((3817, False, ["clef:injection"]), (3700, True, []), (3760, False, ["clef:injection"])):
            f.write(json.dumps({"id": f"site:{i}", "source": "site", "name": "x", "text": "x", "pass": ok, "reasons": why}) + "\n")
    switch = os.path.join(base, "relay.on")
    open(switch, "w").close()
    r3 = V.Relay(Harness(), switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
    f3 = V.Feed({}, V.Filter(AGENTS), V.Clef(AI()), relay=r3, inbox=os.path.join(cur, "operator-inbox.jsonl"))
    f3.preload(logs)
    f3.ingest([line(3817, "Aurora", ARTILLERY, old, backlog=True),
               line(3700, "Aurora", "@operator earlier", old - 50, backlog=True),
               line(3760, "Foobator", "operator: something", old, backlog=True)], [], now=NOW)
    d = deliveries(f3)
    assert d["site:3817"]["status"] == "operator" and d["site:3817"]["why"] == "kept off the stream: clef:injection" and d["site:3817"]["inbox"], d["site:3817"]
    assert d["site:3700"]["status"] == "operator" and d["site:3700"]["why"] == "to the operator's inbox", d["site:3700"]
    # not in the inbox (another viewer at that time): its verdict, as before
    assert d["site:3760"]["status"] == "not_relayed" and d["site:3760"]["why"] == "clef:injection" and "inbox" not in d["site:3760"], d["site:3760"]
    print("operator receipt: ok (a refused line to the operator alone reads to the operator with the refusal; one to an agent "
          "too stays not relayed beside the receipt; a restart keeps the receipt from the inbox files)")


if __name__ == "__main__":
    main()
