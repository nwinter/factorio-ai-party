#!/usr/bin/env python3
"""The live page's site chat: agents' replies to viewers, the hide filter, and no double messages: python3 site/test_sitechat.py

- push_live.public_replies: the state's viewer_replies (tools/stream/viewer_replies.py via model.py), newest 40, a hidden
  viewer line's words left out;
- static/live.js in a stub DOM (needs node): a reply sits under the YouTube or site line it answers in the agent's colour
  with a REPLY tag, a viewer-addressed line in time order, the box hides them and remembers it; one /v1/chat poll at a
  time even when a send and the timer meet (joonazan, d15 08:05: "the site sends messages twice quite often": two polls
  in flight both appended the new messages, and each started its own timer), each message once; one send at a time,
  with a message id that a retry of the same text reuses;
- worker.js's chat under node's SQLite (needs node 22): the same cid from the same client is stored once (a second
  press inside the 4 s gap gets the first message back, not "slow down"), another client's cid is its own, a bad cid
  is refused, and a table from before cid gains the column.
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
import push_live  # noqa: E402


def payload_tests():
    class Hide:
        def hides(self, name, text):
            return name == "Troll42"
    rows = [{"seq": i, "t": 1000.0 + i, "tick": 60 * i, "by": "grok", "text": f"Foobator, line {i}", "kind": "reply", "to": ["Foobator"],
             "answers": {"name": "Foobator", "text": "q", "t": 999.0, "tick": 1, "source": "YouTube"}} for i in range(45)]
    rows.append({"seq": 99, "t": 2000.0, "by": "operator", "text": "@Troll42 Operator: no", "kind": "reply", "to": ["Troll42"],
                 "answers": {"name": "Troll42", "text": "rude words", "t": 1999.0, "source": "site"}})
    rows.append({"seq": 100, "t": None, "by": "grok", "text": "no time"})
    out = push_live.public_replies(rows, Hide())
    assert len(out) == push_live.REPLY_MAX and out[0]["seq"] == 6 and out[-1]["seq"] == 99, [r["seq"] for r in out]
    assert out[-1]["answers"] == {"name": "Troll42", "t": 1999.0, "source": "site"}, out[-1]  # the hidden line's words left out
    assert out[-2]["answers"]["text"] == "q"
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["viewer_replies"] = rows[:2]
    pub = push_live.public_state(s)
    assert [r["seq"] for r in pub["viewer_replies"]] == [0, 1], pub.get("viewer_replies")
    assert "viewer_replies" not in push_live.public_state({k: v for k, v in s.items() if k != "viewer_replies"})


LIVE_CHAT_JS = r"""
// static/live.js's site chat in a stub DOM: argv[2] live.js, argv[3] the state. Prints what happened.
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function cls() { const s = new Set(); return { add: (c) => s.add(c), remove: (c) => s.delete(c), toggle: (c, on) => (on ? s.add(c) : s.delete(c)), contains: (c) => s.has(c) }; }
const kids = {};
const find = (s) => kids[s] || (/^#(cb-|map-|mm)/.test(s) ? null : (kids[s] = el(s)));
function el(name) {
  const e = { name, dataset: {}, textContent: '', value: '', hidden: false, checked: false, disabled: false, classList: cls(), attrs: {}, _html: '', style: {}, on: {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; },
    addEventListener(t, f) { (this.on[t] = this.on[t] || []).push(f); }, appendChild() {},
    querySelector: (s) => find(s), querySelectorAll: () => [], scrollTop: 0, scrollHeight: 0, clientHeight: 0 };
  Object.defineProperty(e, 'innerHTML', { get() { return this._html; }, set(v) { this._html = v; for (const m of String(v).matchAll(/id="([\w-]+)"/g)) kids['#' + m[1]] = kids['#' + m[1]] || el(m[1]); } });
  return e;
}
for (const id of ['dash', 'strip', 'alerts', 'run-title', 'run-sub', 'updated', 'next-shift', 'offline', 'live-badge', 'watching']) kids['#' + id] = el(id);
const app = el('app');
app.querySelector = find;
app.dataset = { api: 'https://api.test', status: '/live/status.json', poll: '10', video: '', channel: '' };
global.window = global;
global.addEventListener = () => {};
global.requestAnimationFrame = (f) => setImmediate(f);
global.document = { getElementById: (id) => (id === 'live-app' ? app : kids['#' + id] || null), hidden: false, documentElement: { dataset: {} },
  addEventListener() {}, querySelector: () => null, createElement: (t) => (kids['new:' + t] = el(t)) };
global.matchMedia = () => ({ matches: true });
global.location = { search: '', hostname: 'localhost' };
const stored = {};
global.localStorage = { getItem: (k) => (k in stored ? stored[k] : null), setItem: (k, v) => { stored[k] = String(v); } };
global.PogAvatar = { svg: () => '<svg/>' };
global.PogMap = { create: () => ({ set: () => {} }) };
// The worker: messages by seq; a GET answers after 40 ms, so a send lands while a poll is in flight.
const server = [{ seq: 1, t: state.now - 120, name: 'Foobator', text: 'hello from the site' }];
let inflight = 0, maxInflight = 0, gets = 0;
const posts = [];
let failNext = false;
const reply = (body, ok = true) => Promise.resolve({ ok, json: () => Promise.resolve(body) });
const later = (ms, f) => new Promise((res) => setTimeout(() => res(f()), ms));
global.fetch = (url, opts) => {
  if (opts && opts.method === 'POST' && url.indexOf('/v1/chat') >= 0) {
    const body = JSON.parse(opts.body);
    posts.push(body);
    if (failNext) { failNext = false; return later(5, () => ({ ok: false, json: () => Promise.resolve({ error: 'slow_down', retry_after_s: 3 }) })); }
    const msg = { seq: server.length + 1, t: state.now, name: body.name || 'viewer', text: body.text };
    server.push(msg);
    return later(5, () => ({ ok: true, json: () => Promise.resolve({ ok: true, message: msg }) }));
  }
  if (opts && opts.method === 'POST') return reply({ ok: true });
  if (url.indexOf('/v1/chat') >= 0) {
    gets++; inflight++; maxInflight = Math.max(maxInflight, inflight);
    const m = /after=(\d+)/.exec(url), after = m ? Number(m[1]) : null;
    return later(40, () => { inflight--; const rows = server.filter((r) => after == null || r.seq > after);
      return { ok: true, json: () => Promise.resolve({ schema: 1, open: true, messages: rows, last_seq: server.length, hidden: [] }) }; });
  }
  if (url.indexOf('/v1/state') >= 0) return reply({ schema: 1, received: Date.now() / 1000, age_s: 4, state, site_watching: 1 });
  return reply({ schema: 1 });
};
require(process.argv[2]);
const form = kids['#vchat-form'], text = kids['[name=text]'], name = kids['[name=name]'], btn = kids['[type=submit]'];
const submit = () => (form.on.submit || []).forEach((f) => f({ preventDefault() {} }));
const out = {};
setTimeout(() => {
  // a send while the first poll is in flight, and a second press before the reply
  name.value = 'fan_1'; text.value = 'first message'; submit(); submit();
  out.disabled_while_sending = btn.disabled;
}, 10);
setTimeout(() => {
  out.after_send = kids['#vchat'].innerHTML;
  // a refused send, then the same text again: the same id; then another text: a new id
  failNext = true; text.value = 'retry me'; submit();
}, 300);
setTimeout(() => { text.value = 'retry me'; submit(); }, 340);
setTimeout(() => { text.value = 'something else'; submit(); }, 380);
setTimeout(() => {
  out.html = kids['#vchat'].innerHTML;
  const box = kids['#vchat-replies'];
  box.checked = false; (box.on.change || []).forEach((f) => f({}));
  out.hidden_html = kids['#vchat'].innerHTML;
  out.stored = stored;
  out.posts = posts; out.maxInflight = maxInflight; out.gets = gets;
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
}, 600);
"""


def live_tests():
    if not shutil.which("node"):
        print("site chat: live.js part skipped (no node)")
        return
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    now = 1792070000.0
    s["now"] = now
    grok = next((x for x in s["agents"] if x.get("name") == "grok"), None) or s["agents"][0]
    grok.update(name="grok", display_name="Grok", color="#3fa7ff")
    s["youtube_chat"] = [{"id": "y1", "name": "Foobator", "text": "@grok why is steel stopped?", "t": now - 100},
                         {"id": "y2", "name": "joonazan", "text": "nice base", "t": now - 90}]
    s["viewer_replies"] = [
        {"seq": 10, "t": now - 30, "by": "grok", "text": "Foobator, the steel line is stopped.", "kind": "reply", "to": ["Foobator"],
         "answers": {"name": "Foobator", "text": "why is steel stopped?", "t": now - 100, "source": "YouTube"}},
        {"seq": 11, "t": now - 20, "by": "haiku", "text": "Viewers, fair point.", "kind": "to_viewers", "to": []},
        {"seq": 12, "t": now - 10, "by": "operator", "text": "@joonazan Operator: thanks", "kind": "reply", "to": ["joonazan"]}]
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "chat.js"), os.path.join(d, "state.json")
        open(js, "w").write(LIVE_CHAT_JS)
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    # one poll at a time, each message once
    assert o["maxInflight"] == 1, o["maxInflight"]
    for html in (o["after_send"], o["html"]):
        assert html.count("first message") == 1 and html.count("hello from the site") == 1, html
    assert o["html"].count("something else") == 1, o["html"]
    # one send per press while one is in flight; a message id, reused by the retry of the same text
    posts = o["posts"]
    assert [p["text"] for p in posts] == ["first message", "retry me", "retry me", "something else"], posts
    assert all(re.fullmatch(r"[0-9a-f]{24}", p["cid"]) for p in posts), posts
    assert posts[1]["cid"] == posts[2]["cid"] and posts[0]["cid"] != posts[1]["cid"] != posts[3]["cid"], posts
    assert o["disabled_while_sending"] is True
    # replies: under the line they answer, in the agent's colour, tagged; a viewer-addressed line in time order
    html = o["html"]
    items = re.findall(r"<li class=\"([^\"]+)\"[^>]*>(.*?)</li>", html)
    texts = [(c, re.sub(r"<[^>]+>", "", body)) for c, body in items]
    i_q = next(i for i, (_, t) in enumerate(texts) if "why is steel stopped?" in t)
    assert "c-agent c-thread" in texts[i_q + 1][0] and "Foobator, the steel line is stopped." in texts[i_q + 1][1], texts
    assert "--ac:#3fa7ff" in html and "REPLY" in texts[i_q + 1][1] and "Grok" in texts[i_q + 1][1] and "↩ Foobator" in texts[i_q + 1][1]
    i_v = next(i for i, (_, t) in enumerate(texts) if "Viewers, fair point." in t)
    assert "TO VIEWERS" in texts[i_v][1] and "c-thread" not in texts[i_v][0], texts[i_v]
    i_op = next(i for i, (_, t) in enumerate(texts) if "Operator: thanks" in t)
    assert "Operator" in texts[i_op][1] and i_op > i_v, texts  # its line ("nice base") is not the one it answers: time order
    # the box hides them, and the choice is kept
    assert "c-agent" not in o["hidden_html"] and "first message" in o["hidden_html"]
    assert o["stored"].get("chatReplies") == "0", o["stored"]


WORKER_JS = r"""
// worker.js's Live chat under node:sqlite (argv[2]: worker.js). Prints the results.
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
// a chat table from before cid
db.exec(`CREATE TABLE chat (seq INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, who TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)`);
db.exec(`INSERT INTO chat (t, name, text, who) VALUES (1, 'old', 'from before', 'x')`);
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
(async () => {
  const { Live } = await import(process.argv[2]);
  const ctx = { storage: { sql }, blockConcurrencyWhile: async (f) => f() };
  const live = new Live(ctx, { PUBLISH_TOKEN: 'x'.repeat(20) });
  await new Promise((r) => setTimeout(r, 10));
  const post = async (body, ip) => {
    const r = await live.fetch(new Request('https://api.test/v1/chat', { method: 'POST', body: JSON.stringify(body), headers: { 'x-client-ip': ip || '1.2.3.4' } }));
    return { status: r.status, body: await r.json() };
  };
  const out = {};
  out.first = await post({ name: 'fan', text: 'hello', cid: 'a'.repeat(24) });
  out.again = await post({ name: 'fan', text: 'hello', cid: 'a'.repeat(24) });          // a second press: the same message
  out.other_client = await post({ name: 'fan', text: 'hi there', cid: 'a'.repeat(24) }, '5.6.7.8');
  out.no_cid_gap = await post({ name: 'fan', text: 'third' });                           // inside the 4 s gap: slow down
  out.bad = await post({ name: 'fan', text: 'x', cid: 'nothex!' });
  out.rows = db.prepare('SELECT seq, text, cid FROM chat ORDER BY seq').all();
  const g = await live.fetch(new Request('https://api.test/v1/chat?limit=10'));
  out.get = await g.json();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def worker_tests():
    if not shutil.which("node"):
        print("site chat: worker part skipped (no node)")
        return
    probe = subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True, text=True)
    if probe.returncode != 0:
        print("site chat: worker part skipped (node without node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "worker_chat.cjs")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(SITE, "worker", "worker.js")],
                           capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    assert o["first"]["status"] == 200 and o["first"]["body"]["message"]["text"] == "hello", o["first"]
    seq = o["first"]["body"]["message"]["seq"]
    assert o["again"]["status"] == 200 and o["again"]["body"]["repeat"] is True and o["again"]["body"]["message"]["seq"] == seq, o["again"]
    assert o["other_client"]["status"] == 200 and o["other_client"]["body"]["message"]["seq"] == seq + 1, o["other_client"]
    assert o["no_cid_gap"]["status"] == 429, o["no_cid_gap"]
    assert o["bad"]["status"] == 400 and "cid" in o["bad"]["body"]["error"], o["bad"]
    assert [(x["text"], x["cid"]) for x in o["rows"]] == [("from before", None), ("hello", "a" * 24), ("hi there", "a" * 24)], o["rows"]
    assert [m["text"] for m in o["get"]["messages"]] == ["from before", "hello", "hi there"] and "cid" not in o["get"]["messages"][1]


def main():
    payload_tests()
    live_tests()
    worker_tests()
    print("site chat: ok (replies in the state, under the line they answer, hide box kept; one poll at a time, each message"
          " once; one send at a time with a message id; the worker stores a cid once)")


if __name__ == "__main__":
    main()
