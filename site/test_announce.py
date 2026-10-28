#!/usr/bin/env python3
"""The Operator's announcements in the site chat (batch293, Nick d27 19:26: "announce shift changes in the site chat as
they happen"): python3 site/test_announce.py

- worker.js under node:sqlite (needs node 22): POST /v1/announce without the publish token is 401 and stores nothing;
  with it, one line as "Operator" on the viewers' channel with op: true; the same cid again is the first line (one per
  event); an empty line or a link is refused; at most 20 an hour; GET /v1/chat (the relay's: game lines only) leaves it
  out, channels=all (the page's) has it with op: true; a viewer still cannot post as "Operator".
- live.js in the chat test's stub DOM: an op line shows with an OPERATOR badge, a viewer's viewers-only line with VIEWERS.
- tools/announce.py against a local stub API: the line, the bearer token and a cid made from the event (the same for
  the same event, none for a manual line); a dry run sends nothing; a test run (POG_TEST=1) without POG_ANNOUNCE_API is
  refused, and so is a line naming a host, a path or an address; a refused post is not retried, a 5xx is (3 tries),
  then exit 1; --log keeps the lines; the usual change time from made-up runs.
"""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
sys.path.insert(0, SITE)
TOKEN = "x" * 20

WORKER_JS = r"""
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
(async () => {
  const mod = await import(process.argv[2]);
  const live = new mod.Live({ storage: { sql }, blockConcurrencyWhile: async (f) => f() }, { PUBLISH_TOKEN: process.argv[3] });
  await new Promise((r) => setTimeout(r, 10));
  const call = async (method, path, body, auth) => {
    const headers = { 'x-client-ip': '1.2.3.4' };
    if (auth) headers.Authorization = 'Bearer ' + auth;
    const r = await live.fetch(new Request('https://api.test' + path, { method, ...(body ? { body: JSON.stringify(body) } : {}), headers }));
    return { status: r.status, body: await r.json() };
  };
  const out = {};
  out.noauth = await call('POST', '/v1/announce', { text: 'Shift 88 is over' });
  out.wrong = await call('POST', '/v1/announce', { text: 'Shift 88 is over' }, 'y'.repeat(20));
  out.ok = await call('POST', '/v1/announce', { text: '  Shift 88 is over;   shift 89 starts in about 7 minutes. ', cid: 'ab'.repeat(12) }, process.argv[3]);
  out.again = await call('POST', '/v1/announce', { text: 'something else', cid: 'ab'.repeat(12) }, process.argv[3]);
  out.empty = await call('POST', '/v1/announce', { text: '  ' }, process.argv[3]);
  out.link = await call('POST', '/v1/announce', { text: 'see https://example.com' }, process.argv[3]);
  out.badcid = await call('POST', '/v1/announce', { text: 'x', cid: 'nothex' }, process.argv[3]);
  out.viewer = await call('POST', '/v1/chat', { name: 'Operator', text: 'I am the operator' });
  out.viewer2 = await call('POST', '/v1/chat', { name: 'Foobator', text: 'hello' });
  out.cap = [];
  for (let i = 0; i < 20; i++) out.cap.push((await call('POST', '/v1/announce', { text: 'line ' + i }, process.argv[3])).status);
  out.relay = (await call('GET', '/v1/chat?after=0&limit=100')).body;
  out.page = (await call('GET', '/v1/chat?after=0&limit=100&channels=all')).body;
  out.rows = db.prepare('SELECT name, channel, op, who FROM chat ORDER BY seq').all();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def node_sqlite():
    return shutil.which("node") and subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True).returncode == 0


def worker():
    if not node_sqlite():
        print("announce: worker part skipped (no node with node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "w.cjs")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(SITE, "worker", "worker.js"), TOKEN],
                           capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    assert o["noauth"]["status"] == 401 and o["wrong"]["status"] == 401, (o["noauth"], o["wrong"])
    m = o["ok"]["body"]["message"]
    assert o["ok"]["status"] == 200 and m["name"] == "Operator" and m["channel"] == "viewers" and m["op"] is True, o["ok"]
    assert m["text"] == "Shift 88 is over; shift 89 starts in about 7 minutes.", m
    assert o["again"]["status"] == 200 and o["again"]["body"]["repeat"] is True and o["again"]["body"]["message"]["text"] == m["text"], o["again"]
    assert o["empty"]["status"] == 400 and o["link"]["body"]["error"] == "links are not allowed" and o["badcid"]["status"] == 400
    assert o["viewer"]["status"] == 400 and o["viewer"]["body"]["error"] == "that name is reserved", o["viewer"]
    assert o["cap"][:19] == [200] * 19 and o["cap"][19] == 429, o["cap"]   # the first line + 19 = 20 an hour
    assert all(x["name"] != "Operator" for x in o["relay"]["messages"]), o["relay"]   # never relayed into the game
    ops = [x for x in o["page"]["messages"] if x.get("op")]
    assert len(ops) == 20 and ops[0]["text"] == m["text"] and all(x["channel"] == "viewers" for x in ops), ops[:2]
    assert all("op" not in x for x in o["page"]["messages"] if x["name"] == "Foobator"), o["page"]
    assert [r["name"] for r in o["rows"]].count("Operator") == 20 and {r["who"] for r in o["rows"] if r["op"]} == {"operator"}
    print("announce worker: ok")


def page():
    if not shutil.which("node"):
        print("announce: page part skipped (no node)")
        return
    import test_sitechat
    head = test_sitechat.LIVE_CHAT_JS.split("require(process.argv[2]);")[0]
    old = "const server = [{ seq: 1, t: state.now - 120, name: 'Foobator', text: 'hello from the site' }];"
    assert old in head
    head = head.replace(old, "const server = [{ seq: 1, t: state.now - 120, name: 'Foobator', text: 'hello from the site' },\n"
                             "  { seq: 2, t: state.now - 60, name: 'Operator', text: 'Shift 88 is over; shift 89 starts in about 7 minutes.', channel: 'viewers', op: true },\n"
                             "  { seq: 3, t: state.now - 30, name: 'fan', text: 'between us', channel: 'viewers' }];")
    js = head + r"""
require(process.argv[2]);
setTimeout(() => { process.stdout.write(JSON.stringify({ html: kids['#vchat'].innerHTML }), () => process.exit(0)); }, 300);
"""
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = 1792070000.0
    with tempfile.TemporaryDirectory() as d:
        jf, sf = os.path.join(d, "p.js"), os.path.join(d, "s.json")
        open(jf, "w").write(js)
        json.dump(s, open(sf, "w"))
        r = subprocess.run(["node", jf, os.path.join(SITE, "static", "live.js"), sf], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        html = json.loads(r.stdout)["html"]
    op = html.split('id="c-s2"', 1)[1].split("</li>", 1)[0]
    assert 'c-src-op">OPERATOR</span> <b>Operator</b>' in op and "starts in about 7 minutes" in op, op
    assert 'c-src-viewers">VIEWERS</span> <b>fan</b>' in html and "delivered" not in op, html
    print("announce page: ok")


class Stub(http.server.BaseHTTPRequestHandler):
    posts, status = [], [200]

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Stub.posts.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        code = Stub.status[0]
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        out = {"ok": True, "message": {"seq": len(Stub.posts)}} if code == 200 else {"error": "no"}
        self.wfile.write(json.dumps(out).encode())

    def log_message(self, *a):
        pass


def tool():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    api = f"http://127.0.0.1:{srv.server_address[1]}"
    tmp = tempfile.mkdtemp()
    try:
        runs = os.path.join(tmp, "runs")
        for n, stop, last in ((10, None, None), (11, "2026-10-26T13:06:24.523Z", "06:12:49"), (12, "2026-10-26T17:15:45.919Z", "10:21:24")):
            d = os.path.join(runs, f"shift{n}")
            os.makedirs(d)
            if n > 10:
                open(os.path.join(d, "resumed-from"), "w").write(f"shift{n - 1}\n")
            if stop:
                json.dump({"stop_utc": stop}, open(os.path.join(runs, f"shift{n - 1}", "stopped.json"), "w"))
                open(os.path.join(d, "start.log"), "w").write(f"{last} agent sol (GPT, codex) in pane w:p tab w:t\n")
        log = os.path.join(tmp, "announce.log")
        env = {k: v for k, v in os.environ.items() if not k.startswith("POG_")}
        env.update(POG_TEST="1", POG_LIVE_TOKEN="t" * 20, POG_ANNOUNCE_WAIT="0", TZ="America/Los_Angeles")

        def run(*args, **over):
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "announce.py"), "--runs", runs, "--log", log, *args],
                               env=dict(env, **over), capture_output=True, text=True, timeout=60)
            return r.returncode, r.stdout.strip()

        assert run("usual")[1] == "8", run("usual")   # 385 and 339 s after the stop save: median 362 s + a minute, rounded up
        rc, out = run("change-begin", "shift12", "shift13")
        assert rc == 2 and "refused: a test run (POG_TEST=1) posts only to POG_ANNOUNCE_API" in out, out
        assert not Stub.posts
        rc, out = run("--dry-run", "change-begin", "shift12", "shift13")
        assert rc == 0 and out.endswith("would post: Shift 3 is over; shift 4 starts in about 8 minutes."), out   # the chain's count
        assert not Stub.posts
        for _ in range(2):
            rc, out = run("change-begin", "shift12", "shift13", POG_ANNOUNCE_API=api)
            assert rc == 0 and "announce: posted (seq " in out, out
        a, b = Stub.posts
        assert a["path"] == "/v1/announce" and a["auth"] == "Bearer " + "t" * 20, a
        assert a["body"]["text"] == "Shift 3 is over; shift 4 starts in about 8 minutes." and a["body"] == b["body"], (a, b)
        assert len(a["body"]["cid"]) == 24, a   # the same event, the same cid: the Worker keeps one line
        os.makedirs(os.path.join(runs, "shift13"))   # start-team made NEXT, resumed from PREV
        open(os.path.join(runs, "shift13", "resumed-from"), "w").write("shift12\n")
        rc, out = run("change-live", "shift13", "--agents", "9", POG_ANNOUNCE_API=api)
        assert Stub.posts[-1]["body"]["text"] == "Shift 4 is live: 9 agents playing." and Stub.posts[-1]["body"]["cid"] != a["body"]["cid"]
        run("change-failed", "shift13", POG_ANNOUNCE_API=api)
        assert Stub.posts[-1]["body"]["text"] == ("The start of shift 4 has hit a problem; the operator is on it, and the stream "
                                                 "stays off until it is fixed.")
        run("change-stalled", "shift13", POG_ANNOUNCE_API=api)
        assert Stub.posts[-1]["body"]["text"] == "The start of shift 4 is taking longer than usual; the operator is on it."
        rc, out = run("stop", "--minutes", "15", "--what", "a restart of the game machine", POG_ANNOUNCE_API=api)
        assert rc == 0 and Stub.posts[-1]["body"] == {"text": "The stream stops now for a restart of the game machine; it should "
                                                              "be back in about 15 minutes."}, Stub.posts[-1]
        n = len(Stub.posts)
        for text in ("pogwin restarts now", "see /Users/owner/x", "mail a@b.c", "at <lan-ip>", "the codex-b quota"):
            rc, out = run("say", text, POG_ANNOUNCE_API=api)
            assert rc == 2 and "refused: the line names" in out, (text, out)
        assert len(Stub.posts) == n
        Stub.status[0] = 403
        rc, out = run("say", "A short pause.", POG_ANNOUNCE_API=api)
        assert rc == 1 and "FAILED (HTTP 403" in out and len(Stub.posts) == n + 1, out   # refused: not tried again
        Stub.status[0] = 503
        rc, out = run("say", "A short pause.", POG_ANNOUNCE_API=api)
        assert rc == 1 and "FAILED (HTTP 503" in out and len(Stub.posts) == n + 4, out   # 3 tries
        Stub.status[0] = 200
        lines = open(log).read().splitlines()
        assert all(" announce: " in l for l in lines) and any("posted (seq" in l for l in lines), lines
    finally:
        srv.shutdown()
        shutil.rmtree(tmp)
    print("announce tool: ok")


if __name__ == "__main__":
    worker()
    page()
    tool()
