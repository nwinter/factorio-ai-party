#!/usr/bin/env python3
"""Site lines written while no stream service reads them stay queued and are read when one starts, no network:
python3 tools/stream/test_site_queue.py

d20 batch65 AA5 (viewer Aurora 09:46 PDT: "Could messages sent between shifts stay queued until delivery, with
queued/delivered/expired labels? My 18:33 request remained in chat without an inbox label"). Her 18:33 (her clock;
09:33:53 PDT) line site:3946 "@operator Could installed blueprint areas track their tested revision ..." came after
shift51's service stopped (09:31:40) and before shift52's started (09:36:05); the new service's first read took the
last 50 lines as backlog and dropped every one older than 120 s with no label. Checks: the cursor file along
resumed-from; SiteChat reads every line after it as queued (the gap before the last 50 too); a queued line to the
operator reaches the inbox, one to an agent is relayed (its wait counted from the read), one over 30 min old expires
with why; one handled before the stop is not handled twice; the cursor stays before a line still waiting; a backlog line
no service ever read is labelled expired; push_live sends expired and the read cursor; the page's labels.
"""
import json, os, re, shutil, subprocess, sys, tempfile, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path[:0] = [HERE, os.path.join(ROOT, "site")]
import viewers as V  # noqa: E402
from test_operator_receipt import AGENTS, AI, Harness  # noqa: E402

V.log = lambda msg: None
T = 1792600433.282  # site:3946, 09:33:53 PDT
BLUEPRINTS = ("@operator Could installed blueprint areas track their tested revision, required hookups and last check, "
              "with failed or unverified hookups visible on every planet's map?")


class Store:
    """The Worker's /v1/chat: the last `limit` lines, or those after `after`."""

    def __init__(self, rows):
        self.rows = sorted(rows, key=lambda r: r["seq"])
        self.urls = []

    def fetch(self, url):
        self.urls.append(url)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        limit = int(q.get("limit", ["50"])[0])
        if "after" in q:
            page = [r for r in self.rows if r["seq"] > int(q["after"][0])][:limit]
        else:
            page = self.rows[-limit:]
        return json.dumps({"schema": 1, "messages": page, "last_seq": self.rows[-1]["seq"] if self.rows else 0})


def row(seq, t, name="Foobator", text=None):
    return {"seq": seq, "t": t, "name": name, "text": text or f"line {seq}", "channel": "game"}


def cursor_tests(tmp):
    r1, r2, r3 = (os.path.join(tmp, n) for n in ("shift51", "shift52", "shift53"))
    for d in (r1, r2, r3):
        os.makedirs(d)
    with open(os.path.join(r1, V.CURSOR_NAME), "w") as f:
        json.dump({"after": 3945, "t": T - 140}, f)
    open(os.path.join(r2, "resumed-from"), "w").write("shift51")
    open(os.path.join(r3, "resumed-from"), "w").write("shift52")
    assert V.load_cursor(r1) == 3945 and V.load_cursor(r2) == 3945 and V.load_cursor(r3) == 3945  # an empty shift between
    assert V.load_cursor(os.path.join(tmp, "nowhere")) is None
    return r1, r2


def sitechat_tests():
    store = Store([row(s, T - 4000 + s) for s in range(1, 201)])
    flags = lambda msgs: {(("q" if m.get("queued") else "") + ("b" if m["backlog"] else "")) for m in msgs}  # noqa: E731
    msgs, _, _ = V.SiteChat("https://x", fetch=store.fetch).poll()  # no cursor: the last 50, backlog, as before
    assert [m["id"] for m in msgs] == [f"site:{s}" for s in range(151, 201)] and flags(msgs) == {"b"}
    sc = V.SiteChat("https://x", fetch=store.fetch, resume=120)  # 80 lines since: the last 50 and the 30 before them
    msgs, _, _ = sc.poll()
    assert [m["id"] for m in msgs] == [f"site:{s}" for s in range(121, 201)] and flags(msgs) == {"q"}, [m["id"] for m in msgs][:3]
    assert sc.after == 200
    msgs, _, _ = V.SiteChat("https://x", fetch=store.fetch, resume=180).poll()
    assert [m["id"] for m in msgs if m["backlog"]] == [f"site:{s}" for s in range(151, 181)]
    assert [m["id"] for m in msgs if m.get("queued")] == [f"site:{s}" for s in range(181, 201)]
    msgs, _, _ = V.SiteChat("https://x", fetch=store.fetch, resume=10).poll()  # far back: pages of 100 to the last 50
    assert [m["id"] for m in msgs] == [f"site:{s}" for s in range(11, 201)] and flags(msgs) == {"q"}
    # later reads as before
    store.rows.append(row(201, T))
    msgs, _, _ = sc.poll()
    assert [(m["id"], m["backlog"], m.get("queued")) for m in msgs] == [("site:201", False, None)], msgs


def feed(run, store, clock):
    switch = os.path.join(run, "relay.on")
    open(switch, "w").close()
    h = Harness()
    relay = V.Relay(h, switch, gap=0, author_gap=0, roster=[(a, None) for a in AGENTS])
    site = V.SiteChat("https://x", fetch=store.fetch, resume=V.load_cursor(run))
    f = V.Feed({"site": site}, V.Filter(AGENTS), V.Clef(AI()), relay=relay, inbox=os.path.join(run, "operator-inbox.jsonl"),
               cursor=os.path.join(run, V.CURSOR_NAME))
    return f, h


def flow_tests(r1, r2):
    """Aurora's case: shift51's service read up to 3945 and stopped; 3946 to 3948 came before shift52's started."""
    lines = [row(3944, T - 3000, "Foobator", "astra: how is the ore?"), row(3945, T - 2600, "Foobator", "sol: keep the edge ship parked")]
    store = Store(lines)
    f1, _ = feed(r1, store, None)
    msgs, dels, _ = f1.sources["site"].poll()
    f1.ingest(msgs, dels, now=T - 2590)
    f1.save_cursor()  # 3945 (to Sol, 10 s old) waits in the relay's queue: the cursor stays before it
    assert json.load(open(os.path.join(r1, V.CURSOR_NAME)))["after"] == 3944
    assert f1.relay.step(T - 2588)["id"] == "site:3945"
    f1.save_cursor()
    assert json.load(open(os.path.join(r1, V.CURSOR_NAME)))["after"] == 3945
    # while no service runs: Aurora's request (3946) and a line to Astra (3947)
    store.rows += [row(3946, T, "Aurora", BLUEPRINTS), row(3947, T + 10, "Foobator", "astra: could you check the drills on the east field?")]
    os.remove(os.path.join(r1, "relay.on"))
    now = T + 132  # shift52's service starts at 09:36:05
    f2, h2 = feed(r2, store, None)
    msgs, dels, _ = f2.sources["site"].poll()
    assert [(m["id"], bool(m.get("queued")), m["backlog"]) for m in msgs] == [
        ("site:3944", False, True), ("site:3945", False, True), ("site:3946", True, False), ("site:3947", True, False)], msgs
    f2.ingest(msgs, dels, now=now)
    sent = f2.relay.step(now)
    assert sent and sent["id"] == "site:3947" and h2.says[0]["text"].endswith("could you check the drills on the east field?"), (sent, h2.says)
    d = {r["id"]: r for r in f2.lane()[1]["delivery"]}
    assert d["site:3946"]["status"] == "operator" and d["site:3946"]["inbox"], d.get("site:3946")
    assert d["site:3947"]["status"] == "relayed" and d["site:3947"]["to"] == "astra", d.get("site:3947")
    # read by shift51's service: 3945 relayed there (its record in the relayed files), 3944 (no verdict logs here) as before
    assert "site:3944" not in d and d["site:3945"]["status"] == "relayed" and d["site:3945"]["to"] == "sol", d.get("site:3945")
    inbox = [json.loads(l) for l in open(os.path.join(r2, "operator-inbox.jsonl"))]
    assert [(r["agent"], r["id"]) for r in inbox] == [("viewer Aurora", "site:3946")], inbox
    f2.save_cursor()
    assert json.load(open(os.path.join(r2, V.CURSOR_NAME)))["after"] == 3947
    return store


def expiry_and_again_tests(r2, store):
    """A line 40 min old when read expires (to the agents); to the operator it still reaches the inbox. Read again
    after a restart, a line already in the inbox is not written twice."""
    run = os.path.join(os.path.dirname(r2), "shift52b")
    os.makedirs(run)
    open(os.path.join(run, "resumed-from"), "w").write("shift52")
    shutil.copy(os.path.join(r2, "operator-inbox.jsonl"), run)
    with open(os.path.join(run, V.CURSOR_NAME), "w") as f:
        json.dump({"after": 3945}, f)  # as if 3946 and 3947 had waited in the relay's queue at the stop
    store.rows += [row(3948, T + 20, "Foobator", "sol: put the edge ship on hold"),
                   row(3949, T + 30, "Aurora", "@operator Resending: blueprint areas with tested revision, please")]
    now = T + 30 + 2400  # read 40 minutes later
    f, h = feed(run, store, None)
    msgs, dels, _ = f.sources["site"].poll()
    f.ingest(msgs, dels, now=now)
    while f.relay.step(now):
        pass
    d = {r["id"]: r for r in f.lane()[1]["delivery"]}
    assert d["site:3946"]["status"] == "operator" and d["site:3946"]["inbox"], d["site:3946"]  # its receipt, not again
    assert d["site:3948"]["status"] == "expired" and d["site:3948"]["why"].startswith("waited 40 min for the stream service"), d["site:3948"]
    assert "a line to the agents waits at most 30 min" in d["site:3948"]["why"]
    assert d["site:3949"]["status"] == "operator", d["site:3949"]  # the operator's inbox takes any age
    inbox = [json.loads(l) for l in open(os.path.join(run, "operator-inbox.jsonl"))]
    assert [r["id"] for r in inbox] == ["site:3946", "site:3949"], inbox
    assert not any("put the edge ship on hold" in s["text"] for s in h.says), h.says
    assert d["site:3947"]["status"] == "relayed" and not any("east field" in s["text"] for s in h.says), (d["site:3947"], h.says)  # once
    # the cursor stays before a line still waiting in the relay's queue
    f.relay.gap = 1e9
    f.relay.last = now
    store.rows += [row(3950, now, "Foobator", "astra: what is the iron stock?"), row(3951, now + 1, "Foobator", "lol")]
    msgs, dels, _ = f.sources["site"].poll()
    f.ingest(msgs, dels, now=now + 2)
    assert f.site_cursor() == 3949, (f.site_cursor(), [m["id"] for m, _ in f.relay.q])
    f.save_cursor()
    assert json.load(open(os.path.join(run, V.CURSOR_NAME)))["after"] == 3949


def never_read_tests(tmp):
    """Before the cursor: a backlog line in no verdict log, the inbox or the relayed files was never read."""
    f = V.Feed({}, V.Filter(AGENTS), None, inbox=os.path.join(tmp, "none-inbox.jsonl"))
    f.preloaded, f.logged = True, {"site:3945": (True, [])}
    now = T + 132
    f.ingest([dict(id="site:3945", source="site", author="site:foobator", name="Foobator", text="sol: keep it parked", t=T - 2600, backlog=True),
              dict(id="site:3946", source="site", author="site:aurora", name="Aurora", text=BLUEPRINTS, t=T, backlog=True)], [], now=now)
    d = {r["id"]: r for r in f.lane()[1]["delivery"]}
    assert "site:3945" not in d and d["site:3946"]["status"] == "expired", d
    assert d["site:3946"]["why"].startswith("the stream service was not running when it came"), d["site:3946"]
    f2 = V.Feed({}, V.Filter(AGENTS), None)  # no verdict logs read: nothing claimed
    f2.ingest([dict(id="site:3946", source="site", author="site:aurora", name="Aurora", text=BLUEPRINTS, t=T, backlog=True)], [], now=now)
    assert not f2.lane()[1]["delivery"]


def push_tests():
    import push_live
    st = {"delivery": [{"id": "site:3948", "status": "expired", "why": "waited 40 min for the stream service"},
                       {"id": "site:3946", "status": "operator", "why": "to the operator's inbox", "inbox": True}], "site": {"after": 3947}}
    assert push_live.public_delivery(st) == {"3948": {"s": "expired", "why": "waited 40 min for the stream service"},
                                             "3946": {"s": "operator", "why": "to the operator's inbox", "op": 1}}
    out = push_live.public_state({"viewers_status": st, "agents": []})
    assert out["viewer_read"] == {"after": 3947}, out.get("viewer_read")


def page_tests():
    if not shutil.which("node"):
        print("site queue: live.js part skipped (no node)")
        return
    code = open(os.path.join(ROOT, "site", "static", "live.js")).read()
    fn = code[code.index("  function operatorHtml(m, d) {"):code.index("  function renderChat() {")]
    stub = ("function esc(s) { return String(s == null ? '' : s); } function hm(t) { return 'HH:MM'; } "
            "function agentName(n) { return n.charAt(0).toUpperCase() + n.slice(1); } var delivery = {};")
    js = stub + fn + """
var out = [];
delivery = { 3946: { s: 'operator', why: "to the operator's inbox", op: 1 }, 3947: { s: 'relayed', to: 'astra' },
  3948: { s: 'expired', why: 'waited 40 min for the stream service' } };
readUpTo = 3949; serviceLive = true;
[3946, 3947, 3948, 3950].forEach(function (s) { out.push(deliveryHtml({ src: 'site', seq: s, t: 1 })); });
serviceLive = false;
out.push(deliveryHtml({ src: 'site', seq: 3950, t: 1 }));
readUpTo = null;
out.push(deliveryHtml({ src: 'site', seq: 3950, t: 1 }));
process.stdout.write(JSON.stringify(out));
"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    o = [re.sub(r"<[^>]+>", "", h).strip() for h in json.loads(r.stdout)]
    assert o[0] == "delivered to the Operator" and o[1] == "delivered to Astra", o
    assert o[2] == "expired: waited 40 min for the stream service" and o[3] == "queued", o
    assert o[4] == "queued: the stream service is not running (between shifts or restarting); it reads this line when it starts", o
    assert o[5] == "", o  # an older service sends no read cursor: no label, as before


def main():
    tmp = tempfile.mkdtemp()
    r1, r2 = cursor_tests(tmp)
    sitechat_tests()
    store = flow_tests(r1, r2)
    expiry_and_again_tests(r2, store)
    never_read_tests(tmp)
    push_tests()
    page_tests()
    print("site queue: ok (the cursor along resumed-from; lines since it read as queued; to the inbox, relayed, expired "
          "with why; not handled twice; the cursor before a waiting line; never-read lines labelled; queued on the page)")


if __name__ == "__main__":
    main()
