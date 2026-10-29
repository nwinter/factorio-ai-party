#!/usr/bin/env python3
"""Delivery receipts only after a durable inbox write; replies saved before they are sent (d28 batch323 DR, viewer
Aurora 16:19, site:5413: "Could delivery receipts require a successful durable inbox write? ... Keep request IDs through
durable pending delivery and safe retries, then test write failure, a crash between save/send and restart.
Acknowledgements and Updates should agree without losing or duplicating work."): python3 tools/stream/test_durable_delivery.py

1. operator_inbox.write_rows: whole lines, fsynced; a cut last line gets its newline first; agents' requests retried
   after a write that landed are not written twice.
2. Viewer routing (viewers.Feed): a failed inbox write gives no "operator" receipt (held, not in the inbox), keeps the
   site cursor before the line, and the next pass writes it once and gives the receipt; a write that landed and then
   failed is not written twice; a restart reads the line again and delivers it once.
3. The polls relay: a suggestion whose inbox write fails gets no reply and stays; the next pass files it once and
   answers once; a crash after the inbox write and before the reply files nothing twice.
4. tools/opreply.py: the record (pending) before the send, the Updates row before the send, the sent mark after; a
   crash between save and send, a crash mid-send and a crash between send and mark: the restart sends each part
   once; the same reply run again sends nothing; the Updates page shows the reply only once it is marked sent.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(os.path.dirname(TOOLS), "site"))
sys.dont_write_bytecode = True
import operator_inbox as OI  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    failures += 0 if ok else 1


def rows(path):
    try:
        return [json.loads(x) for x in open(path) if x.strip()]
    except OSError:
        return []


class Faults:
    """write_rows that fails the next `fail` calls (OSError before writing), or `land` calls (written, then OSError:
    an fsync that failed after the bytes reached the file)."""

    def __init__(self, real):
        self.real, self.fail, self.land, self.only = real, 0, 0, None

    def __call__(self, path, rs):
        if self.only and not str(path).endswith(self.only):
            return self.real(path, rs)
        if self.fail:
            self.fail -= 1
            raise OSError(28, "No space left on device")
        self.real(path, rs)
        if self.land:
            self.land -= 1
            raise OSError(5, "Input/output error")


def durable():
    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "x.jsonl")
    synced = []
    real = os.fsync
    os.fsync = lambda fd: synced.append(fd) or real(fd)
    try:
        OI.write_rows(p, [{"a": 1}, {"a": 2}])
    finally:
        os.fsync = real
    check("1. rows written whole and fsynced", rows(p) == [{"a": 1}, {"a": 2}] and len(synced) == 1, synced)
    with open(p, "a") as f:
        f.write('{"a": 3, "cut')  # a write cut short
    OI.write_rows(p, [{"a": 4}])
    check("1. a cut last line spoils no other", [r for r in rows_loose(p)] == [{"a": 1}, {"a": 2}, {"a": 4}], open(p).read())
    # agents' requests: the write lands and fails, the caller retries the same requests: written once
    q = os.path.join(tmp, "operator-inbox.jsonl")
    reqs = [{"seq": 1, "tick": 10, "from": "sol", "text": "a"}, {"seq": 2, "tick": 11, "from": "sol", "text": "b"}]
    f = Faults(OI.write_rows)
    OI.write_rows, f.land = f, 1
    try:
        try:
            OI.append(q, reqs, 0, now=5)
        except OSError:
            pass
        OI.append(q, reqs, 0, now=6)
    finally:
        OI.write_rows = f.real
    check("1. agents' requests retried after a landed write: once each", [r["seq"] for r in rows(q)] == [1, 2], rows(q))


def rows_loose(p):
    out = []
    for x in open(p):
        try:
            out.append(json.loads(x))
        except ValueError:
            pass
    return out


def viewers():
    import viewers as V
    V.log = lambda msg: None
    AGENTS = ["astra", "sol"]
    tmp = tempfile.mkdtemp()
    inbox = os.path.join(tmp, "operator-inbox.jsonl")

    class Src:
        after = 200  # the site source has read past these lines

        def status(self):
            return {"ok": True}

    class AI:
        def run(self, model, body):
            return {"answers": {k: {"choice": "fine"} for k in body["questions"]}}

    def feed():
        f = V.Feed({"site": Src()}, V.Filter(AGENTS), V.Clef(AI()), inbox=inbox)
        return f

    def line(i, text, t, **kw):
        return dict({"id": f"site:{i}", "source": "site", "author": "site:Aurora", "name": "Aurora", "text": text, "t": t}, **kw)

    def delivery(f, ident):
        return {r["id"]: r for r in f.lane()[1]["delivery"]}.get(ident) or {}
    T = 1793230000.0
    faults = Faults(V.operator_inbox.write_rows)
    V.operator_inbox.write_rows = faults
    try:
        f = feed()
        faults.fail = 1
        f.ingest([line(100, "operator: could receipts wait for the inbox write?", T)], [], now=T)
        d = delivery(f, "site:100")
        check("2. a failed inbox write: no operator receipt (held), not in the inbox",
              d.get("status") == "held" and not d.get("inbox") and not os.path.exists(inbox), d)
        check("2. the site cursor stays before it", f.site_cursor() == 99, f.site_cursor())
        f.ingest([], [], now=T + 5)
        d = delivery(f, "site:100")
        check("2. the next pass writes it once, then the receipt", [r["id"] for r in rows(inbox)] == ["site:100"]
              and d.get("status") == "operator" and d.get("inbox"), (rows(inbox), d))
        f.ingest([], [], now=T + 10)
        check("2. and never again", len(rows(inbox)) == 1 and not f.inbox_retry)
        # a write that landed, then failed (fsync): no receipt; the retry finds its id and writes nothing more
        faults.land = 1
        f.ingest([line(101, "operator: second", T + 20)], [], now=T + 20)
        check("2. landed but failed: no receipt yet", delivery(f, "site:101").get("status") == "held", delivery(f, "site:101"))
        f.ingest([], [], now=T + 25)
        ids = [r["id"] for r in rows(inbox)]
        check("2. its retry: delivered, written once", ids == ["site:100", "site:101"] and delivery(f, "site:101").get("status") == "operator", ids)
        # a crash before the retry: the restart reads the line again (backlog, after the saved cursor) and delivers it once
        faults.fail = 1
        f.ingest([line(102, "operator: third", T + 30)], [], now=T + 30)
        check("2. third: held, cursor before it", delivery(f, "site:102").get("status") == "held" and f.site_cursor() == 101, f.site_cursor())
        g = feed()  # restart
        g.ingest([line(102, "operator: third", T + 30, backlog=True, queued=True)], [], now=T + 40)
        g.ingest([line(102, "operator: third", T + 30, backlog=True, queued=True)], [], now=T + 45)
        ids = [r["id"] for r in rows(inbox)]
        check("2. after a restart: delivered once", ids == ["site:100", "site:101", "site:102"]
              and delivery(g, "site:102").get("status") == "operator", (ids, delivery(g, "site:102")))
    finally:
        V.operator_inbox.write_rows = faults.real


def polls():
    import polls_relay as P
    tmp = tempfile.mkdtemp()
    run = os.path.join(tmp, "shift99")
    os.makedirs(os.path.join(run, "sol"))
    req = os.path.join(run, "sol", P.REQUESTS)
    with open(req, "w") as f:
        f.write(json.dumps({"rid": "r1", "kind": "suggest", "question": "Next planet?", "options": ["Aquilo", "Gleba"]}) + "\n")
    r = P.Relay(run, "http://x", "tok", fetch=lambda *a, **k: (500, {}), clock=lambda: 1000.0, names={})
    replies = os.path.join(run, "sol", P.REPLIES)
    inbox = os.path.join(run, "operator-inbox.jsonl")
    faults = Faults(OI.write_rows)
    P.operator_inbox.write_rows = faults
    try:
        faults.fail = 1
        r.requests()
        check("3. a failed inbox write: no reply, the request kept", not rows(replies) and not rows(inbox)
              and not P.read_json(r.state_path, {}).get("sol"), rows(replies))
        r.requests()
        check("3. the next pass: filed once, answered once", len(rows(inbox)) == 1 and [x["rid"] for x in rows(replies)] == ["r1"]
              and rows(replies)[0]["ok"], (rows(inbox), rows(replies)))
        # a crash after the inbox write, before the reply: the restart files nothing twice and answers once
        with open(req, "a") as f:
            f.write(json.dumps({"rid": "r2", "kind": "suggest", "question": "Rail or bots?", "options": ["Rail", "Bots"]}) + "\n")
        faults.only, faults.fail = P.REPLIES, 1
        try:
            r.requests()
        except OSError:
            pass  # the crash
        faults.only = None
        P.Relay(run, "http://x", "tok", fetch=lambda *a, **k: (500, {}), clock=lambda: 1001.0, names={}).requests()
        check("3. a crash between filing and answering: filed once, answered once",
              len(rows(inbox)) == 2 and [x["rid"] for x in rows(replies)] == ["r1", "r2"], (rows(inbox), rows(replies)))
    finally:
        P.operator_inbox.write_rows = faults.real


def opreply_tests():
    import opreply as O
    import operator_updates as ou
    import updates
    tmp = tempfile.mkdtemp()
    run = os.path.join(tmp, "shift99")
    os.makedirs(run)
    chat = os.path.join(run, "chat.jsonl")
    open(chat, "w").close()
    upath = os.path.join(tmp, "operator-updates.json")
    ou.write(upath, {"updates": [], "notices": []})
    O.site_line = lambda seq, api=None, fetch=None: {"name": "Aurora", "text": "Could delivery receipts require a durable write?",
                                                     "t": 1793230000.0}
    O.CHAT_SETTLE_S = 0.0
    sent, crash = [], {"after": None}

    def send(lines, world, port=None):  # the game chat, as chat-log.py logs it
        for line in lines:
            if crash["after"] == 0:
                crash["after"] = None
                raise ConnectionError("rcon closed")
            sent.append(line)
            n = len(rows(chat)) + 1
            with open(chat, "a") as f:
                f.write(json.dumps({"seq": n, "from": "server", "text": line}) + "\n")
            if crash["after"] is not None:
                crash["after"] -= 1
    O.send = send

    def call(*extra):
        return O.main(["--run", run, "--updates-file", upath, "--to", "site:5413", *extra])

    def shown():
        _, rep = updates.messages(tmp, {"site:5413"}, lambda s: s, lambda s: True)
        return [r["text"] for r in rep.get("site:5413", [])]
    recs = os.path.join(run, "operator-replies.jsonl")
    marks = os.path.join(run, O.SENT_NAME)
    # a crash between save and send: the record and the Updates row are saved, nothing sent, nothing shown
    crash["after"] = 0
    try:
        call("--update", "durable-receipts", "--title", "Receipts after a durable write", "--area", "stream", "accepted")
    except ConnectionError:
        pass
    u = {x["id"]: x for x in updates.load(upath)["updates"]}
    check("4. crash between save and send: pending saved, Updates row saved, nothing sent or shown",
          len(rows(recs)) == 1 and rows(recs)[0]["rid"] and not rows(marks) and not sent and "durable-receipts" in u
          and shown() == [], (rows(recs), rows(marks), sent))
    # the restart (the next call): sent once, marked; the Updates page shows it
    check("4. --resume sends it once", O.main(["--run", run, "--resume"]) == 0 and sent == ["@Aurora Operator: accepted"], sent)
    check("4. marked sent, shown under the row", [m["rid"] for m in rows(marks)] == [rows(recs)[0]["rid"]]
          and shown() == ["@Aurora Operator: accepted"], (rows(marks), shown()))
    O.main(["--run", run, "--resume"])
    check("4. a second resume sends nothing", sent == ["@Aurora Operator: accepted"], sent)
    # the same reply run again: already sent, nothing sent
    call("accepted")
    check("4. the same reply again: nothing sent twice", sent == ["@Aurora Operator: accepted"] and len(rows(recs)) == 1, sent)
    # a two-part reply, a crash after its first part: the restart sends only the second
    long = "started: " + " ".join(["Receipts now wait for the inbox write to be flushed and synced."] * 9)
    crash["after"] = 1
    try:
        call(long)
    except ConnectionError:
        pass
    parts = rows(recs)[-1]["parts"]
    check("4. two parts, crash after the first: one sent, pending", len(parts) == 2 and sent[-1] == parts[0]
          and len(rows(marks)) == 1, (len(parts), sent[-1:]))
    call("a later reply")  # the next call finishes the pending one first, then its own
    check("4. the next call: the pending reply's second part once, then its own", sent[-3:] == [parts[0], parts[1], "@Aurora Operator: a later reply"]
          and sent.count(parts[0]) == 1 and sent.count(parts[1]) == 1 and len(rows(marks)) == 3, sent[-3:])
    # a crash between send and mark: the restart finds the lines in the chat, sends nothing, marks it
    faults = Faults(O.operator_inbox.write_rows)
    faults.only, faults.fail = O.SENT_NAME, 1
    O.operator_inbox.write_rows = faults
    try:
        try:
            call("done: live")
        except OSError:
            pass
    finally:
        O.operator_inbox.write_rows = faults.real
    n = len(sent)
    O.main(["--run", run, "--resume"])
    check("4. crash between send and mark: nothing sent again, marked", len(sent) == n and sent.count("@Aurora Operator: done: live") == 1
          and len(rows(marks)) == 4, sent[-2:])
    check("4. Updates and the chat agree: every reply shown once, in order",
          shown() == ["@Aurora Operator: accepted", " ".join(parts), "@Aurora Operator: a later reply", "@Aurora Operator: done: live"], shown())
    # the settle wait: a pending reply judged no sooner than CHAT_SETTLE_S after its record
    O.CHAT_SETTLE_S = 20.0
    waited = []
    rec = dict(rows(recs)[0], rid="op-test", t=100.0)
    O.operator_inbox.write_rows(recs, [rec])
    O.resume(run, "n", clock=lambda: 105.0, wait=waited.append)
    check("4. a fresh pending reply waits for the chat log", waited == [15.0], waited)


def main():
    durable()
    viewers()
    polls()
    opreply_tests()
    print("durable delivery: " + ("ok" if not failures else f"{failures} failed"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
