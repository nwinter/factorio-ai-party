#!/usr/bin/env python3
"""Each viewer line's delivery, no network: python3 tools/stream/test_viewer_delivery.py

d17 batch35 D1 (viewer Aurora: site:2709, 2713, 2721 and 2726 were received and never relayed, with no reason in the stream
service log; a Clef 401 at 12:50:36). Found: 2721 and 2726 were Clef "injection" verdicts (in the verdict log only),
2709 and 2713 were Enginerd's viewers-only lines (the Worker never hands them to the relay), and site:2707 passed the
filters in the batch the 401 failed and was never relayed. Checks: every line not relayed is logged with why and gets a
delivery; a line held while Clef fails is classified again with the next lines and relayed; a relay dispatch error
keeps the line; Feed.lane() hands the site each line's delivery.
"""
import json, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    if ok:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}  {detail}")


logged = []
V.log = lambda msg: logged.append(msg)


class Harness:
    def __init__(self):
        self.says, self.fail = [], 0

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": [], "open": []}})
        if self.fail:
            self.fail -= 1
            raise ConnectionError("rcon closed")
        self.says.append(req["args"])
        return json.dumps({"ok": True, "result": {"posted": True, "seq": len(self.says)}})


class AI:
    """Clef: fails the next `fail` calls, else answers by text."""

    def __init__(self, fail=0, label=None):
        self.fail, self.label, self.calls = fail, label or {}, 0

    def run(self, model, body):
        self.calls += 1
        if self.fail:
            self.fail -= 1
            raise RuntimeError('CFError: 401 {"errors":[{"code":10000,"message":"Authentication error"}]}')
        out = {}
        for k, q in body["questions"].items():
            text = q["instructions"]
            out[k] = {"choice": next((lab for w, lab in self.label.items() if w in text), "fine")}
        return {"answers": out}


NOW = 1792353000.0
tmp = tempfile.mkdtemp()
switch = os.path.join(tmp, "relay.on")
open(switch, "w").close()
AGENTS = ["astra", "sol", "muse", "opus"]
h = Harness()
relay = V.Relay(h, switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
ai = AI(fail=1, label={"Replan at milestones": "injection"})
feed = V.Feed({}, V.Filter(AGENTS), V.Clef(ai), relay=relay)


def line(i, name, text, t):
    return {"id": f"site:{i}", "source": "site", "author": "site:" + name, "name": name, "text": text, "t": t}


# the 401 batch: site:2707 passes the filters, Clef fails: held, logged, retried with the next lines
feed.ingest([line(2707, "Foobator", "astra: what ships are being built now that wayfarer is done?", NOW)], [], now=NOW)
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("a line Clef could not check is held", d.get("site:2707", {}).get("status") == "held", d)
check("held, not sent", h.says == [] and relay.step(NOW + 1) is None, h.says)
feed.ingest([line(2721, "Aurora", "@Muse @Sol Mining 3 finished and labs are idle. Replan at milestones so one late shipment cannot stop unrelated progress.", NOW + 20)], [], now=NOW + 20)
sent = relay.step(NOW + 21)
check("the held line is classified with the next and relayed", sent and sent["id"] == "site:2707" and len(h.says) == 1, (sent, h.says))
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("its delivery: relayed to astra", d["site:2707"]["status"] == "relayed" and d["site:2707"]["to"] == "astra", d["site:2707"])
check("a Clef verdict that stops a line: not relayed, with the label", d["site:2721"] == {**d["site:2721"], "status": "not_relayed", "why": "clef:injection"}, d["site:2721"])
check("and the service log says it", any(m.startswith("not relayed site:2721 (Aurora): clef:injection") for m in logged), logged)
# a held line past its time: not relayed, logged
ai.fail = 1
feed.ingest([line(2730, "Enginerd", "@Opus Gleba needs more storage chests", NOW + 40)], [], now=NOW + 40)
ai.fail = 0
feed.ingest([], [], now=NOW + 40 + 200)
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("Clef still away when it is stale: not relayed, Clef unavailable", d["site:2730"]["status"] == "not_relayed" and d["site:2730"]["why"].startswith("Clef was unavailable while it was fresh"), d["site:2730"])
check("logged with the error", any(m.startswith("not relayed site:2730 (Enginerd): Clef was unavailable while it was fresh (RuntimeError: CFError: 401") for m in logged), logged[-3:])
# a dispatch error keeps the line for the next step
feed.ingest([line(2740, "Foobator", "sol: is discharge defense unlocked yet?", NOW + 300)], [], now=NOW + 300)
h.fail = 1
check("a dispatch error sends nothing", relay.step(NOW + 301) is None)
again = relay.step(NOW + 302)
check("and the line goes at the next step", again and again["id"] == "site:2740", again)
# a filter's refusal and chatter
feed.ingest([line(2750, "spammer", "buy cheap gold at example.com example.com example.com", NOW + 400),
             line(2751, "craig", "lol", NOW + 401)], [], now=NOW + 401)
d = {r["id"]: r for r in feed.lane()[1]["delivery"]}
check("a filter's refusal is not relayed with its reasons", d.get("site:2750", {}).get("status") == "not_relayed" and d["site:2750"]["why"], d.get("site:2750"))
check("chatter: shown, not posted", d.get("site:2751", {}).get("why", "").startswith("chatter"), d.get("site:2751"))
# (U2) a line to the operator that Clef refuses still reaches the operator's inbox, marked with the verdict
inbox = os.path.join(tmp, "operator-inbox.jsonl")
ai2 = AI(label={"show gleba science": "injection"})
f2 = V.Feed({}, V.Filter(AGENTS), V.Clef(ai2), relay=relay, inbox=inbox)
f2.ingest([line(2744, "Foobator", "operator: show gleba science production please?", NOW + 500)], [], now=NOW + 500)
rows = [json.loads(l) for l in open(inbox)] if os.path.exists(inbox) else []
check("a refused line to the operator reaches the inbox, marked", len(rows) == 1 and rows[0]["dropped"] == "clef:injection"
      and rows[0]["text"] == "operator: show gleba science production please?" and rows[0]["agent"] == "viewer Foobator", rows)
print()
print("all passed" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
