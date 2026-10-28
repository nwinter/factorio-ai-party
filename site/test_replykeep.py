#!/usr/bin/env python3
"""Replies kept as long as the lines they answer (d28 batch309, viewer Aurora 09:38: "Could viewer chat retain replies as
long as their prompts remain, across shifts and reloads? Preserve all parts and late answers. Test a restart with over
40 replies and no duplicates."): python3 site/test_replykeep.py

The real path, end to end, on made-up runs: 60 site lines 15 minutes apart (the page's 60 on a reload, 15 hours), each
relayed into the game chat and answered by Sol (replies_to, as chat.lua keeps it); every fifth one also by the Operator
through tools/opreply.py's record (--sent), every tenth in 3 parts. tools/stream/model.py reads the game chat as
live.py does (the first read after a start is the newest 30 lines); site/push_live.py sends what the stream service
keeps; site/worker/worker.js (node:sqlite) stores it; static/live.js (test_sitechat.py's stub page, its fetch to that
worker) shows it.
- shift90's stream service, then a restart of it (30 lines more), then shift91's (resumed from shift90; push_live
  restarted too, so it sends every row again): 86 replies, each kept once, every part; a late answer (the Operator, in
  shift91, in 2 parts, to a shift90 line 13 hours old) goes to shift91's records and threads under its line;
- push_live after the restart sends only the new replies (the kept ones come back unchanged); its loop (push_replies,
  a local /replies.json) sends each row once, a changed one again, and asks a worker without the route again in 10
  minutes;
- the worker stores each game seq once (a row sent again unchanged keeps its version), returns with the page's 60
  lines every reply to them, and the relay's read (no replies=1) none; a line the site hides since loses its words in
  the replies to it;
- the page: every reply to a line it shows, once, every part, "Operator replied" on each line the Operator answered;
  the late answer arrives at the next poll (replies_after) without a reload, and a reload shows the same.
"""
import argparse, contextlib, io, json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
sys.path[:0] = [SITE, os.path.join(ROOT, "tools", "stream"), os.path.join(ROOT, "tools")]
sys.dont_write_bytecode = True
import opreply  # noqa: E402
import push_live  # noqa: E402
import viewer_replies as V  # noqa: E402
from model import Model  # noqa: E402

TOKEN = "t" * 24
T0, TICK0 = 1793150000.0, 76000000
NAMES = ("Aurora", "Foobator", "Caleb")
PROMPTS = [{"seq": 5001 + i, "t": T0 + i * 900, "name": NAMES[i % 3],
            "text": f"Question {i}: could the line {i} be checked before the next shift?"} for i in range(60)]
LONG = " ".join(f"Sentence {k} of a long answer, with enough words in it to need a second and a third part." for k in range(14))


def tick(t):
    return TICK0 + int(round((t - T0) * 60))


class Game:
    """The game chat (one seq across shifts, as chat.lua keeps it) and the Operator's records (tools/opreply.py)."""

    def __init__(self):
        self.lines, self.seq, self.replies = [], 26000, []  # replies: (game seq, site seq, by, part)

    def line(self, t, **kw):
        self.seq += 1
        m = dict(kw, seq=self.seq, tick=tick(t))
        self.lines.append((t, m))
        return m

    def prompt(self, p):
        return self.line(p["t"] + 3, **{"from": "viewer " + p["name"], "viewer": True, "source": "site",
                                        "source_id": f"site:{p['seq']}", "text": "@sol " + p["text"]})

    def sol(self, p, v):
        m = self.line(p["t"] + 60, **{"from": "sol", "text": f"@{p['name']} line {p['seq'] - 5000} is checked; it holds.",
                                      "replies_to": [{"seq": v["seq"], "name": p["name"], "id": f"site:{p['seq']}",
                                                      "source": "site", "tick": v["tick"], "text": p["text"]}]})
        self.replies.append((m["seq"], p["seq"], "sol", None))

    def operator(self, run, p, text, at):
        """tools/opreply.py --to site:N --sent SEQ ...: the record first, the parts as the game chat has them."""
        parts = opreply.parts(p["name"], text)
        sent = [self.line(at + k, **{"from": "server", "text": part}) for k, part in enumerate(parts)]
        rec = {"t": at, "to": f"site:{p['seq']}", "name": p["name"], "question": {"text": p["text"], "t": p["t"], "source": "site"},
               "parts": parts, "world": "n"}
        a = argparse.Namespace(dry_run=False, sent=[m["seq"] for m in sent])
        with contextlib.redirect_stdout(io.StringIO()):
            opreply.deliver(a, dict(rec, sent=a.sent), parts, os.path.join(run, V.LINKS_NAME))
        for k, m in enumerate(sent, 1):
            self.replies.append((m["seq"], p["seq"], "operator", [k, len(sent)] if len(sent) > 1 else None))


def service(run):
    """serve.py's model for this run, as serve.py sets it up."""
    m = Model({"agents": {"sol": {}, "astra": {}}})
    m.set_inbox(os.path.join(run, "operator-inbox.jsonl"))
    m.set_reply_links(os.path.join(run, V.LINKS_NAME))
    if hasattr(m, "set_reply_store"):
        m.set_reply_store(os.path.join(run, V.ROWS_NAME))
    return m


def start(m, game, now):
    """The first chat read after a start: the newest 30 lines (live.py's limit), with the tick read now."""
    m.ingest({"tick": tick(now), "chat": [x for _, x in game.lines[-30:]]}, now=now)


def feed(m, game, upto):
    """The live reads: each line as it comes, at its own time."""
    for t, x in game.lines[upto:]:
        m.ingest({"tick": x["tick"], "chat": [x]}, now=t)
    return len(game.lines)


def push(m, sent, posts):
    """push_live: the state (its newest replies) and the reply store's posts (reply_posts, the hashes kept once sent)."""
    state = push_live.public_state(m.snapshot(game_now(m)))
    if hasattr(push_live, "reply_posts"):
        for body, hashes in push_live.reply_posts(m.replies_all(), sent):
            posts.append(body)
            sent.update(hashes)
    return state


def game_now(m):
    return m.tick_t or T0


def kept(m):
    rows = m.replies_all() if hasattr(m, "replies_all") else list(m.viewer_replies)
    return [r["seq"] for r in rows]


NODE = r"""
// the worker (node:sqlite on a file: a reload reads the same store) and the page
const { DatabaseSync } = require('node:sqlite');
const [, , livePath, statePath, mode, workerUrl, token, dbPath, dataPath] = process.argv;
const db = new DatabaseSync(dbPath);
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
const data = JSON.parse(require('fs').readFileSync(dataPath, 'utf8'));
const ready = import(workerUrl).then(async (mod) => {
  const live = new mod.Live({ storage: { sql }, blockConcurrencyWhile: async (f) => f() }, { PUBLISH_TOKEN: token });
  await new Promise((r) => setTimeout(r, 10));
  return live;
});
const call = async (method, path, body, auth) => {
  const live = await ready;
  const headers = { 'x-client-ip': '1.2.3.4' };
  if (auth) headers.Authorization = 'Bearer ' + auth;
  const r = await live.fetch(new Request('https://api.test' + path, { method, ...(body ? { body: JSON.stringify(body) } : {}), headers }));
  return { status: r.status, body: await r.json() };
};
const out = { urls: [] };
const done = () => process.stdout.write(JSON.stringify(out), () => process.exit(0));
if (mode === 'read') {
  call('GET', '/v1/chat?limit=60&channels=all&replies=1').then((r) => { out.read = r.body; done(); });
} else if (mode === 'setup') {
  (async () => {
    await ready;
    for (const p of data.prompts) db.prepare("INSERT INTO chat (seq, t, name, text, who, channel) VALUES (?, ?, ?, ?, 'w', 'game')").run(p.seq, p.t, p.name, p.text);
    out.posts = [];
    for (const b of data.posts) out.posts.push((await call('POST', '/v1/replies', b, token)).body);
    out.noauth = (await call('POST', '/v1/replies', data.posts[0] || { replies: [] })).status;
    out.again = (await call("POST", "/v1/replies", data.posts[data.posts.length - 1] || { replies: [] }, token)).body;
    out.read = (await call('GET', '/v1/chat?limit=60&channels=all&replies=1')).body;
    out.relay = (await call('GET', '/v1/chat?limit=60')).body;
    out.since = (await call('GET', '/v1/chat?after=5060&channels=all&replies=1&replies_after=' + out.read.replies_rv)).body;
    out.rows = db.prepare('SELECT COUNT(*) AS n, COUNT(DISTINCT seq) AS d FROM replies').get();
    done();
  })().catch((e) => { console.error(e); process.exit(1); });
} else {
""" + "\n"


def page_js():
    import test_sitechat
    head = test_sitechat.LIVE_CHAT_JS.split("// The worker: messages by seq")[0]
    head = head.replace("const fs = require('fs');\nconst state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));\n",
                        "const state = JSON.parse(require('fs').readFileSync(statePath, 'utf8'));\n")
    return NODE + head + r"""
global.fetch = (url, opts) => {
  if (url.indexOf('/v1/chat') >= 0 && !(opts && opts.method === 'POST')) {
    out.urls.push(url.replace('https://api.test', ''));
    return call('GET', url.replace('https://api.test', '')).then((r) => ({ ok: true, json: () => Promise.resolve(r.body) }));
  }
  if (url.indexOf('/v1/state') >= 0) return Promise.resolve({ ok: true, json: () => Promise.resolve({ schema: 1, received: Date.now() / 1000, age_s: 4, state, site_watching: 1 }) });
  return Promise.resolve({ ok: true, json: () => Promise.resolve({ schema: 1 }) });
};
ready.then(() => {
  require(livePath);
  setTimeout(async () => {
    out.first = kids['#vchat'].innerHTML;
    if (!data.late.length) { done(); return; }
    // push_live sends the late answer while the page is open: the next poll (4 s) brings it
    out.late = [];
    for (const b of data.late) out.late.push((await call('POST', '/v1/replies', b, token)).body);
    setTimeout(() => { out.html = kids['#vchat'].innerHTML; done(); }, 4600);
  }, 400);
});
}
"""


def items(html):
    return re.findall(r"<li class=\"([^\"]+)\" id=\"c-([\w-]+)\"[^>]*>(.*?)</li>", html)


def check_page(html, game, prompts, late_seqs, label):
    it = items(html)
    ids = [k for _, k, _ in it]
    assert len(ids) == len(set(ids)), (label, "a line twice", [k for k in ids if ids.count(k) > 1][:5])
    where = {k: i for i, k in enumerate(ids)}
    shown = {p["seq"] for p in prompts if f"s{p['seq']}" in where}
    assert len(shown) == 60, (label, len(shown))
    want = [(g, s, by, part) for g, s, by, part in game.replies if s in shown]
    missing = [g for g, *_ in want if f"a{g}" not in where]
    assert not missing, (label, f"{len(missing)} of {len(want)} replies to shown lines missing", missing[:8])
    for g, s, by, part in want:
        cls, _, body = it[where[f"a{g}"]]
        text = re.sub(r"<[^>]+>", "", body)
        if part:
            assert f"{part[0]}/{part[1]}" in text, (label, g, text[:160])
        if g in late_seqs:  # 13 hours after its line: in time order, its quote a button to that line
            assert "c-alone" in cls and f'data-jump="s{s}"' in body, (label, cls, body[:300])
        else:  # under the line it answers (after the replies before it)
            assert "c-thread" in cls and where[f"s{s}"] < where[f"a{g}"], (label, g, cls)
    for p in prompts:
        if any(s == p["seq"] and by == "operator" for _, s, by, _ in game.replies):
            assert "Operator replied" in it[where[f"s{p['seq']}"]][2], (label, p["seq"])
    return len(want)


def pusher(rows):
    """push_live.push_replies against a local serve.py stand-in (/replies.json): every row once, nothing again while
    unchanged, a changed row again, a worker without the route asked again in 10 minutes, an older serve.py nothing."""
    import http.server, threading, urllib.error

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps(rows if self.path == "/replies.json" else {}).encode()
            self.send_response(200 if self.path == "/replies.json" else 404)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        a = argparse.Namespace(source=f"http://127.0.0.1:{srv.server_port}/state.json", api="http://unused.test", print=False)
        rs, got = {"sent": {}, "at": 0.0, "off_until": 0.0, "kept": 0}, []
        assert push_live.push_replies(a, TOKEN, rs, now=1000, post=lambda d: got.append(json.loads(d))) == len(rows)
        assert sum(len(b["replies"]) for b in got) == len(rows) and all(len(b["replies"]) <= push_live.REPLIES_POST for b in got), [len(b["replies"]) for b in got]
        assert push_live.push_replies(a, TOKEN, rs, now=1005, post=lambda d: got.append(1)) is None  # within REPLIES_EVERY
        assert push_live.push_replies(a, TOKEN, rs, now=1020, post=lambda d: got.append(1)) == 0
        rows[0] = dict(rows[0], text=rows[0]["text"] + " (edited)")
        again = []
        assert push_live.push_replies(a, TOKEN, rs, now=1040, post=lambda d: again.append(json.loads(d))) == 1
        assert [r["seq"] for b in again for r in b["replies"]] == [rows[0]["seq"]], again

        def gone(d):
            raise urllib.error.HTTPError("http://unused.test/v1/replies", 404, "not found", {}, None)
        rows[1] = dict(rows[1], text=rows[1]["text"] + " (edited)")
        with contextlib.redirect_stdout(io.StringIO()) as out:
            assert push_live.push_replies(a, TOKEN, rs, now=1060, post=gone) is None
        assert rs["off_until"] == 1660 and "no /v1/replies yet" in out.getvalue(), (rs, out.getvalue())
        assert push_live.push_replies(a, TOKEN, rs, now=1100, post=gone) is None  # not asked again yet
        old = argparse.Namespace(**dict(vars(a), source=f"http://127.0.0.1:{srv.server_port}/old/state.json"))
        assert push_live.push_replies(old, TOKEN, {"sent": {}, "at": 0.0, "off_until": 0.0, "kept": 0}, now=1000, post=gone) is None
    finally:
        srv.shutdown()


def main():
    node = shutil.which("node")
    if not node or subprocess.run([node, "-e", "require('node:sqlite')"], capture_output=True).returncode:
        print("replykeep: skipped (no node with node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        runs = {n: os.path.join(d, "runs", n) for n in ("shift90", "shift91")}
        for n, r in runs.items():
            os.makedirs(r)
        open(os.path.join(runs["shift91"], "resumed-from"), "w").write("shift90\n")
        game, posts, sent = Game(), [], {}

        def answer(run, i):
            p = PROMPTS[i]
            v = game.prompt(p)
            game.sol(p, v)
            if i % 5 == 0:
                game.operator(run, p, LONG if i % 10 == 0 else f"line {i} is on the list for the next batch.", p["t"] + 120)

        # shift90's stream service: lines 0-29
        m = service(runs["shift90"])
        for i in range(30):
            answer(runs["shift90"], i)
        feed(m, game, 0)
        push(m, sent, posts)
        n90 = len(game.replies)
        # a restart of it: the game's newest 30 lines, then lines 30-44
        m = service(runs["shift90"])
        upto = len(game.lines)
        start(m, game, PROMPTS[29]["t"] + 600)
        got = kept(m)
        assert len(got) == len(set(got)), "a reply kept twice after the restart"
        lost = [g for g, *_ in game.replies if g not in got]
        assert not lost, f"restart: {len(lost)} of {n90} replies gone from the stream service (only the newest 30 game lines read back)"
        for i in range(30, 45):
            answer(runs["shift90"], i)
        feed(m, game, upto)
        k = len(posts)
        push(m, sent, posts)
        # the restart read its rows back unchanged: push_live sends only lines 30-44's replies
        if hasattr(push_live, "reply_posts"):
            assert sum(len(b["replies"]) for b in posts[k:]) == len(game.replies) - n90, (sum(len(b["replies"]) for b in posts[k:]), len(game.replies) - n90)
        # shift91's service (resumed from shift90) and a new push_live: lines 45-59
        m, sent = service(runs["shift91"]), {}
        upto = len(game.lines)
        start(m, game, PROMPTS[44]["t"] + 1200)
        for i in range(45, 60):
            answer(runs["shift91"], i)
        feed(m, game, upto)
        state = push(m, sent, posts)
        got = kept(m)
        assert len(got) == len(set(got)) and not [g for g, *_ in game.replies if g not in got], "shift91 lost or doubled replies"
        before = len(game.replies)
        # the late answer: the Operator, in shift91, to line 3 (13 hours before), in 2 parts
        late_at = PROMPTS[59]["t"] + 300
        upto = len(game.lines)
        game.operator(runs["shift91"], PROMPTS[3], LONG[:700], late_at)
        late_seqs = {g for g, *_ in game.replies[before:]}
        assert len(late_seqs) == 2, game.replies[before:]
        feed(m, game, upto)
        late = []
        if hasattr(push_live, "reply_posts"):
            for body, hashes in push_live.reply_posts(m.replies_all(), sent):
                late.append(body)
                sent.update(hashes)
        state_late = push_live.public_state(m.snapshot(game_now(m)))
        assert len(game.replies) == 86 and len(game.replies) > 40, len(game.replies)
        rows = {r["seq"]: r for r in m.replies_all()}
        for g in late_seqs:
            assert rows[g]["answers"]["id"] == "site:5004" and rows[g]["link"] == "reply_to", rows[g]
        # what the run files hold: each reply once (a restart's backlog did not add them again)
        on_disk = [r["seq"] for p in (runs["shift90"], runs["shift91"]) for r in V.read_rows(os.path.join(p, V.ROWS_NAME))]
        assert sorted(on_disk) == sorted(g for g, *_ in game.replies), (len(on_disk), len(game.replies))
        assert len(state["viewer_replies"]) == push_live.REPLY_MAX, len(state["viewer_replies"])
        if hasattr(push_live, "push_replies"):
            pusher(m.replies_all())

        # the worker and the page
        work = os.path.join(d, "w")
        os.makedirs(work)
        js, db, data = os.path.join(work, "page.cjs"), os.path.join(work, "live.db"), os.path.join(work, "data.json")
        open(js, "w").write(page_js())
        json.dump({"prompts": PROMPTS, "posts": posts, "late": late}, open(data, "w"))
        st = json.load(open(os.path.join(SITE, "live", "state.example.json")))
        st.update(now=late_at, viewer_replies=state["viewer_replies"])
        sp = os.path.join(work, "state.json")
        json.dump(st, open(sp, "w"))
        worker = "file://" + os.path.join(SITE, "worker", "worker.js")
        live = os.path.join(SITE, "static", "live.js")

        def run(mode, state_path=sp):
            r = subprocess.run([node, "--no-warnings", js, live, state_path, mode, worker, TOKEN, db, data],
                               capture_output=True, text=True, timeout=60)
            assert r.returncode == 0, r.stderr[-2000:]
            return json.loads(r.stdout)

        o = run("setup")
        assert o["noauth"] == 401, o["noauth"]
        assert o["rows"]["n"] == o["rows"]["d"] == before, (o["rows"], before)  # each game seq once
        assert o["again"]["stored"] == 0 and o["again"]["same"] == len(posts[-1]["replies"]), o["again"]
        rd = o["read"]
        seqs = [r["seq"] for r in rd["replies"]]
        assert len(rd["messages"]) == 60 and len(seqs) == len(set(seqs)) == before, (len(rd["messages"]), len(seqs))
        assert "replies" not in o["relay"], sorted(o["relay"])
        assert o["since"]["replies"] == [] and o["since"]["replies_rv"] == rd["replies_rv"], o["since"]
        p = run("page")
        n = check_page(p["html"], game, PROMPTS, late_seqs, "open page")
        first = items(p["first"])
        assert not [k for _, k, _ in first if k[1:].isdigit() and int(k[1:]) in late_seqs], "the late answer before it was sent"
        assert any("replies_after=" in u for u in p["urls"]), p["urls"]
        # a reload, with the state as it is after the late answer
        st.update(viewer_replies=state_late["viewer_replies"])
        json.dump(st, open(sp, "w"))
        json.dump({"prompts": PROMPTS, "posts": [], "late": []}, open(data, "w"))
        r = run("page")
        n2 = check_page(r["first"], game, PROMPTS, late_seqs, "reload")
        assert n == n2 == 86, (n, n2)
        # a line the site hides since: the replies to it keep their own words, not that line's
        db_ = __import__("sqlite3").connect(db)
        db_.execute("UPDATE chat SET hidden = 1 WHERE seq = 5004")
        db_.commit()
        db_.close()
        o = run("read")["read"]
        to_it = {g for g, s, *_ in game.replies if s == 5004}  # Sol's and the late answer's 2 parts
        hid = [r for r in o["replies"] if r["seq"] in to_it]
        assert len(o["messages"]) == 59 and len(hid) == len(to_it) == 3, (len(o["messages"]), len(hid))
        for r in hid:
            assert "answers" not in r and "Aurora" not in r["to"] and r["text"].startswith("@Aurora"), r
        assert sum(1 for r in o["replies"] if "answers" in r) == len(o["replies"]) - 3, "other replies keep their lines"
    print(f"replykeep: ok ({len(game.replies)} replies to 60 site lines across a restart and a shift change, "
          f"{sum(1 for *_, part in game.replies if part)} of them parts, a late answer; each shown once on the open page and after a reload)")


if __name__ == "__main__":
    main()
