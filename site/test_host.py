#!/usr/bin/env python3
"""The host link and reserved names on the site (d16 17:12; Nick 17:11: "a host link so I can have verified comments and
disallow similar nicks"): python3 site/test_host.py

- worker.js under node:sqlite (needs node 22): X-Host-Token matching HOST_TOKEN posts as NickWinter with host: true
  whatever the name box says, past the per-client limits (a cap of 30 a minute); a wrong token, or any token while no
  HOST_TOKEN is set, is 403 and nothing is stored; without the token Nick's name, look-alikes, "Operator" and the agents
  are "that name is reserved"; GET /v1/chat carries host: true on host lines only; the CORS preflight allows the header;
  poll votes and ideas refuse reserved names too, and the host link votes and suggests as NickWinter (a wrong one 403).
- live.js in the chat test's stub DOM: ?host=TOKEN is kept in localStorage and taken out of the address bar, sent as
  X-Host-Token on chat posts and never in a GET URL, "Signed in as host" shows with Forget, which drops it; host
  lines (site and YouTube) carry a HOST badge; a refused link says so.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)

TOKEN = "h" * 24

WORKER_JS = r"""
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
// a chat table from before host (and channel)
db.exec(`CREATE TABLE chat (seq INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, who TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)`);
db.exec(`INSERT INTO chat (t, name, text, who) VALUES (1, 'NickWinter', 'an old line under his name', 'x')`);
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
const TOKEN = process.argv[3];
(async () => {
  const mod = await import(process.argv[2]);
  const make = (env) => new mod.Live({ storage: { sql }, blockConcurrencyWhile: async (f) => f() }, env);
  const live = make({ PUBLISH_TOKEN: 'x'.repeat(20), HOST_TOKEN: TOKEN });
  await new Promise((r) => setTimeout(r, 10));
  const post = async (body, opts = {}) => {
    const headers = { 'x-client-ip': opts.ip || '1.2.3.4' };
    if (opts.token != null) headers['X-Host-Token'] = opts.token;
    const r = await (opts.live || live).fetch(new Request('https://api.test/v1/chat', { method: 'POST', body: JSON.stringify(body), headers }));
    return { status: r.status, body: await r.json() };
  };
  const out = {};
  out.host = await post({ name: 'whoever', text: 'hello from Nick' }, { token: TOKEN });
  out.host2 = await post({ name: 'x', text: 'and again at once' }, { token: TOKEN });          // no 4 s gap for the host
  out.host_same = await post({ name: 'x', text: 'and again at once' }, { token: TOKEN });     // no duplicate rule either
  out.wrong = await post({ name: 'NickWinter', text: 'let me in' }, { token: 'h'.repeat(23) + 'X', ip: '6.6.6.6' });
  out.empty_token = await post({ name: 'fan', text: 'hm' }, { token: '', ip: '6.6.6.7' });
  out.unset = await post({ name: 'fan', text: 'hm' }, { token: TOKEN, ip: '6.6.6.8', live: make({ PUBLISH_TOKEN: 'x'.repeat(20) }) });
  out.reserved = {};
  let ip = 10;
  for (const n of JSON.parse(process.argv[4])) out.reserved[n] = (await post({ name: n, text: 'hi ' + n }, { ip: '9.9.9.' + (ip++) })).status + ' ' + (await Promise.resolve(''));
  out.reserved_body = await post({ name: 'N1ck W1nter', text: 'hi' }, { ip: '9.9.8.1' });
  out.viewer = await post({ name: 'Foobator', text: 'nice base' }, { ip: '9.9.8.2' });
  // the cap: 30 a minute
  out.cap = [];
  for (let i = 0; i < 30; i++) out.cap.push((await post({ text: 'line ' + i }, { token: TOKEN })).status);
  const g = await live.fetch(new Request('https://api.test/v1/chat?after=0&limit=100&channels=all'));
  out.get = await g.json();
  // the browser's preflight for the header (the top-level fetch)
  const pre = await mod.default.fetch(new Request('https://api.test/v1/chat', { method: 'OPTIONS', headers: { Origin: 'http://127.0.0.1:8765' } }),
    { ALLOWED_ORIGINS: 'http://127.0.0.1:8765' });
  out.preflight = pre.headers.get('Access-Control-Allow-Headers');
  out.rows = db.prepare('SELECT name, host FROM chat ORDER BY seq').all();
  // polls (main 9ba5c637): votes and ideas take the same names and the host link (two minutes on: the cap test above
  // used the host's 30 posts of this minute, which chat, votes and ideas share)
  const realNow = Date.now;
  const later = realNow() + 120000;
  Date.now = () => later;
  const pcall = async (path, body, opts = {}) => {
    const headers = { 'x-client-ip': opts.ip || '1.2.3.4' };
    if (opts.token != null) headers['X-Host-Token'] = opts.token;
    if (opts.auth) headers.Authorization = 'Bearer ' + 'x'.repeat(20);
    const r = await live.fetch(new Request('https://api.test' + path, { method: 'POST', body: JSON.stringify(body), headers }));
    return { status: r.status, body: await r.json() };
  };
  const poll = await pcall('/v1/polls', { question: 'Which planet next?', options: ['Vulcanus', 'Gleba'], hours: 2 }, { auth: true });
  const pid = poll.body.poll.id;
  out.vote_reserved = await pcall(`/v1/polls/${pid}/vote`, { option: 0, name: 'N1ck Winter', comment: 'me' }, { ip: '5.5.5.1' });
  out.vote_reserved2 = await pcall(`/v1/polls/${pid}/vote`, { option: 0, name: 'S0l' }, { ip: '5.5.5.2' });
  out.vote_host = await pcall(`/v1/polls/${pid}/vote`, { option: 1, name: 'anyone', comment: 'Gleba please' }, { token: TOKEN, ip: '5.5.5.3' });
  out.vote_wrong = await pcall(`/v1/polls/${pid}/vote`, { option: 1, name: 'NickWinter' }, { token: 'nope'.repeat(6), ip: '5.5.5.4' });
  out.vote_viewer = await pcall(`/v1/polls/${pid}/vote`, { option: 0, name: 'Foobator', comment: 'lava' }, { ip: '5.5.5.5' });
  out.idea_reserved = await pcall('/v1/polls/suggest', { name: 'Operat0r', question: 'More trains?', options: ['yes', 'no'] }, { ip: '5.5.5.6' });
  out.idea_host = await pcall('/v1/polls/suggest', { name: 'x', question: 'More trains?', options: ['yes', 'no'] }, { token: TOKEN, ip: '5.5.5.7' });
  out.idea_wrong = await pcall('/v1/polls/suggest', { name: 'x', question: 'Trains?', options: ['yes', 'no'] }, { token: 'n'.repeat(24), ip: '5.5.5.8' });
  out.ideas = db.prepare('SELECT name FROM poll_ideas ORDER BY id').all();
  const pv = await live.fetch(new Request('https://api.test/v1/polls'));
  out.polls = await pv.json();
  Date.now = realNow;
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""

RESERVED = ["NickWinter", "nick winter", "N1ckW1nter", "ΝickWinter", "Nick_W", "Nick", "Winter", "Operator", "0perat0r",
            "Opperator", "Sol", "luna", "Astra", "server"]


def worker():
    if not shutil.which("node") or subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True).returncode:
        print("host: worker part skipped (no node with node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "w.cjs")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(SITE, "worker", "worker.js"), TOKEN,
                            json.dumps(RESERVED)], capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    m = o["host"]["body"]["message"]
    assert o["host"]["status"] == 200 and m["name"] == "NickWinter" and m["host"] is True, o["host"]
    assert o["host2"]["status"] == 200 and o["host_same"]["status"] == 200, (o["host2"], o["host_same"])
    for k in ("wrong", "empty_token", "unset"):
        assert o[k]["status"] == 403 and o[k]["body"]["error"] == "host link not valid", (k, o[k])
    assert all(v.startswith("400") for v in o["reserved"].values()), o["reserved"]
    assert o["reserved_body"]["body"]["error"] == "that name is reserved"
    assert o["viewer"]["status"] == 200 and "host" not in o["viewer"]["body"]["message"]
    assert o["cap"].count(429) == 3 and o["cap"][:27] == [200] * 27, o["cap"]  # 3 earlier + 27 = 30 a minute
    msgs = o["get"]["messages"]
    assert msgs[0] == {"seq": 1, "t": 1, "name": "NickWinter", "text": "an old line under his name", "channel": "game"}, msgs[0]
    assert [x.get("host") for x in msgs[1:4]] == [True, True, True] and all("host" not in x for x in msgs if x["name"] != "NickWinter")
    assert "X-Host-Token" in o["preflight"], o["preflight"]
    assert ("NickWinter", 0) in [(r["name"], r["host"]) for r in o["rows"]] and len([r for r in o["rows"] if r["host"]]) == 30
    # polls: a vote or idea under a reserved name is refused; the host link votes as the host; a wrong token is 403
    for k in ("vote_reserved", "vote_reserved2", "idea_reserved"):
        assert o[k]["status"] == 400 and o[k]["body"]["error"] == "that name is reserved", (k, o[k])
    v = o["vote_host"]
    assert v["status"] == 200 and v["body"]["vote"]["name"] == "NickWinter" and v["body"]["vote"]["host"] is True, v
    for k in ("vote_wrong", "idea_wrong"):
        assert o[k]["status"] == 403 and o[k]["body"]["error"] == "host link not valid", (k, o[k])
    assert o["vote_viewer"]["status"] == 200 and "host" not in o["vote_viewer"]["body"]["vote"]
    assert o["idea_host"]["status"] == 200 and [r["name"] for r in o["ideas"]] == ["NickWinter"], (o["idea_host"], o["ideas"])
    p = next(x for x in (o["polls"].get("open") or o["polls"].get("polls") or []) if x["question"] == "Which planet next?")
    assert p["counts"] == [1, 1], p["counts"]
    com = {c["name"]: c for c in p["comments"]}
    assert com["NickWinter"].get("host") is True and "host" not in com["Foobator"], p["comments"]


def page():
    if not shutil.which("node"):
        print("host: page part skipped (no node)")
        return
    import test_sitechat
    head = test_sitechat.LIVE_CHAT_JS.split("require(process.argv[2]);")[0]
    head = head.replace("global.location = { search: '', hostname: 'localhost' };",
                        "global.location = { search: '?host=" + TOKEN + "&x=1', pathname: '/live/', hash: '', hostname: 'localhost' };\n"
                        "const replaced = [];\nglobal.history = { replaceState: (a, b, url) => replaced.push(url) };")
    assert "replaceState" in head
    js = head + r"""
require(process.argv[2]);
const sends = [], getUrls = [];
const plain = global.fetch;
let refuse = false;
global.fetch = (url, opts) => {
  if (opts && opts.method === 'POST' && url.indexOf('/v1/chat') >= 0) {
    sends.push({ headers: opts.headers, body: JSON.parse(opts.body) });
    if (refuse) return Promise.resolve({ ok: false, json: () => Promise.resolve({ error: 'host link not valid' }) });
    const b = JSON.parse(opts.body);
    const msg = { seq: 50 + sends.length, t: state.now, name: 'NickWinter', text: b.text, host: true };
    return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true, message: msg }) });
  }
  if (!opts || !opts.method || opts.method === 'GET') getUrls.push(url);
  return plain(url, opts);
};
const out = {};
setTimeout(() => {
  out.stored = stored.hostToken; out.replaced = replaced;
  out.host_line = !kids['#vchat-host'].hidden;
  out.name_disabled = kids['[name=name]'].disabled;
  kids['[name=text]'].value = 'hello from the host link';
  (kids['#vchat-form'].on.submit || []).forEach((f) => f({ preventDefault() {} }));
}, 20);
setTimeout(() => {
  out.html = kids['#vchat'].innerHTML;
  refuse = true;
  kids['[name=text]'].value = 'second line';
  (kids['#vchat-form'].on.submit || []).forEach((f) => f({ preventDefault() {} }));
}, 200);
setTimeout(() => {
  out.refused_note = kids['#vchat-note'].textContent;
  (kids['#vchat-host-forget'].on.click || []).forEach((f) => f({}));
  out.after_forget = { stored: stored.hostToken, line: !kids['#vchat-host'].hidden, disabled: kids['[name=name]'].disabled };
  out.sends = sends; out.getUrls = getUrls;
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
}, 400);
"""
    # localStorage.removeItem for Forget (the chat test's stub has get/set only)
    js = js.replace("global.localStorage = { getItem: (k) => (k in stored ? stored[k] : null), setItem: (k, v) => { stored[k] = String(v); } };",
                    "global.localStorage = { getItem: (k) => (k in stored ? stored[k] : null), setItem: (k, v) => { stored[k] = String(v); }, removeItem: (k) => { delete stored[k]; } };")
    assert "removeItem" in js
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = 1792070000.0
    s["youtube_chat"] = [{"id": "y1", "name": "NickWinter (host)", "text": "from my channel", "t": s["now"] - 50, "host": True},
                         {"id": "y2", "name": "NickWinter (viewer)", "text": "not him", "t": s["now"] - 40}]
    with tempfile.TemporaryDirectory() as d:
        jf, sf = os.path.join(d, "p.js"), os.path.join(d, "s.json")
        open(jf, "w").write(js)
        json.dump(s, open(sf, "w"))
        r = subprocess.run(["node", jf, os.path.join(SITE, "static", "live.js"), sf], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        o = json.loads(r.stdout)
    assert o["stored"] == TOKEN and o["replaced"] == ["/live/?x=1"], (o["stored"], o["replaced"])
    assert o["host_line"] is True and o["name_disabled"] is True
    assert o["sends"] and all(x["headers"].get("X-Host-Token") == TOKEN for x in o["sends"]), o["sends"]
    assert all(TOKEN not in u for u in o["getUrls"]) and o["getUrls"], o["getUrls"]  # never in a URL the page fetches
    assert all(TOKEN not in json.dumps(x["body"]) for x in o["sends"])  # nor in the body
    html = o["html"]
    assert 'c-src-host">HOST</span> <b>NickWinter</b>' in html and "hello from the host link" in html, html
    assert 'c-src-host">HOST</span> <b>NickWinter (host)</b>' in html, html  # his YouTube line
    assert 'c-src-yt">YT</span> <b>NickWinter (viewer)</b>' in html, html
    assert "not valid" in o["refused_note"], o["refused_note"]
    assert o["after_forget"].get("stored") is None and o["after_forget"]["line"] is False \
        and o["after_forget"]["disabled"] is False, o["after_forget"]


if __name__ == "__main__":
    worker()
    page()
    print("host: ok (host link posts as NickWinter with host: true, wrong or unset token refused, reserved names refused, "
          "host field on reads, preflight; page keeps the token out of URLs, badges, Forget)")
