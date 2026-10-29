#!/usr/bin/env python3
"""The viewers' Ideas page (d29 batch340 ID, viewer Aurora site:5470: "a persistent viewer Ideas page with two sections
... Keep it for human/host review only, with no automatic AI relay or tasks"): python3 site/test_ideas.py

- worker.js under node:sqlite (needs node 22): an idea in either section under chat's names, links rule, limits (4 s
  apart; 6 a client an hour) and bans; a blank name is the guest name; the same cid is stored once; a bad section, an
  empty or too long idea, a reserved name are refused. The host link posts as NickWinter; a wrong host token is 403 on
  every ideas call, a viewer's change is 401. The host moves an idea to the other section (its end) and up or down,
  edits it (edited_t), hides it (kept: the host still sees it, the public list not, the export has it), pins it (first),
  highlights it, sets priority and status (others refused) and replies ("" takes the reply away). ban_idea bans the
  poster (their ideas leave the public list, the host sees banned; the host's own idea cannot be banned); ideas_close
  stops new ones; at the cap (IDEAS.keep) new ideas are refused and nothing is deleted. A new object on the same
  storage (a restart) has every idea and every host change. The top-level fetch never caches the host's view.
- Nothing on the Mac reads the ideas: no tool, stream service or relay names /v1/ideas.
- The page: /ideas/ has both sections, the idea box and the script, and the menu links it. In headless Chromium
  (Playwright from the npx cache, as test_maptoolbar.py finds it; skipped when there is none) at 400 px and 1300 px,
  against a local API: the saved chat name fills the name box, an idea's text is escaped, the reply shows under it,
  nothing is wider than the page; with ?host=TOKEN the token leaves the address bar, the hidden idea and the tools
  show, and Pin sends POST /v1/ideas/ID {pinned: true} with X-Host-Token (never in a URL).
"""
import glob, json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SITE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SITE)
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True

TOKEN = "h" * 24
PUB = "x" * 20

WORKER_JS = r"""
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
const sql = { exec(q, ...params) {
  const st = db.prepare(q);
  let rows;
  try { rows = st.all(...params); } catch (e) { if (/does not return data|returns no data/i.test(String(e.message))) { st.run(...params); rows = []; } else throw e; }
  return { toArray: () => rows };
} };
const TOKEN = process.argv[3], PUB = process.argv[4];
let now = 1793300000000;
Date.now = () => now;
(async () => {
  const mod = await import(process.argv[2]);
  const make = () => new mod.Live({ storage: { sql }, blockConcurrencyWhile: async (f) => f() }, { PUBLISH_TOKEN: PUB, HOST_TOKEN: TOKEN });
  let live = make();
  await new Promise((r) => setTimeout(r, 10));
  const call = async (method, path, body, o = {}) => {
    const headers = { 'x-client-ip': o.ip || '1.2.3.4' };
    if (o.host != null) headers['X-Host-Token'] = o.host;
    if (o.auth) headers.Authorization = 'Bearer ' + PUB;
    const r = await live.fetch(new Request('https://api.test' + path, { method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) }));
    return { status: r.status, body: await r.json() };
  };
  const post = (body, o) => call('POST', '/v1/ideas', body, o);
  const edit = (id, body, o = { host: TOKEN }) => call('POST', '/v1/ideas/' + id, body, o);
  const pub = async () => (await call('GET', '/v1/ideas')).body;
  const hostView = async () => (await call('GET', '/v1/ideas', undefined, { host: TOKEN })).body;
  const ids = (v, s) => v.sections[s].map((i) => i.id);
  const tick = (s) => { now += s * 1000; };
  const out = {};
  out.a = await post({ name: 'Aurora', text: 'A run on a death world <b>please</b>', section: 'next_run', cid: 'a'.repeat(16) }, { ip: '192.0.2.1' });
  out.a_again = await post({ name: 'Aurora', text: 'A run on a death world <b>please</b>', section: 'next_run', cid: 'a'.repeat(16) }, { ip: '192.0.2.1' });
  out.fast = await post({ name: 'Aurora', text: 'and another one at once', section: 'general' }, { ip: '192.0.2.1' });
  tick(5);
  out.guest = await post({ name: '', text: 'Show the belts on the map', section: 'general' }, { ip: '192.0.2.2' });
  out.bad_section = await post({ name: 'Foo', text: 'x', section: 'other' }, { ip: '192.0.2.3' });
  out.link = await post({ name: 'Foo', text: 'see www.example.com', section: 'general' }, { ip: '192.0.2.4' });
  out.long = await post({ name: 'Foo', text: 'y'.repeat(1001), section: 'general' }, { ip: '192.0.2.5' });
  out.empty = await post({ name: 'Foo', text: '   ', section: 'general' }, { ip: '192.0.2.6' });
  out.reserved = await post({ name: 'N1ck W1nter', text: 'hi', section: 'general' }, { ip: '192.0.2.7' });
  // a client's sixth idea in the hour is fine, the seventh is not
  out.hour = [];
  for (let i = 0; i < 7; i++) { tick(5); out.hour.push((await post({ name: 'Busy', text: 'idea ' + i, section: 'general' }, { ip: '192.0.2.8' })).status); }
  out.host_post = await post({ name: 'whoever', text: 'Pinned: tell us what you want next run', section: 'next_run' }, { host: TOKEN });
  out.wrong_post = await post({ name: 'x', text: 'let me in', section: 'general' }, { host: 'h'.repeat(23) + 'X', ip: '192.0.2.9' });
  out.wrong_get = await call('GET', '/v1/ideas', undefined, { host: 'nope' });
  tick(5);
  out.b = await post({ name: 'Caleb', text: 'More spidertrons', section: 'next_run' }, { ip: '192.0.2.17' });
  const A = out.a.body.idea.id, B = out.b.body.idea.id, G = out.guest.body.idea.id, H = out.host_post.body.idea.id;
  out.viewer_edit = await edit(A, { pinned: true }, { ip: '192.0.2.1' });
  out.wrong_edit = await edit(A, { pinned: true }, { host: 'h'.repeat(24 - 1) + 'Y' });
  out.order0 = ids(await pub(), 'next_run');
  out.down = (await edit(A, { move: 'down' })).status;
  out.order1 = ids(await pub(), 'next_run');
  out.pin = (await edit(B, { pinned: true, highlight: true })).body.idea;
  out.order2 = ids(await pub(), 'next_run');
  out.to_general = (await edit(H, { section: 'general' })).body.idea;
  out.general = ids(await pub(), 'general');
  out.text = (await edit(G, { text: 'Show the belts and pipes on the map' })).body.idea;
  out.prio = (await edit(G, { priority: 'high', status: 'planned', reply: 'Good one: on the list for the map.' })).body.idea;
  out.bad_prio = await edit(G, { priority: 'urgent' });
  out.bad_status = await edit(G, { status: 'maybe' });
  out.hide = (await edit(A, { hidden: true })).body.idea;
  out.pub_after_hide = await pub();
  out.host_after_hide = await hostView();
  out.export = (await call('GET', '/v1/debug/export?table=ideas', undefined, { auth: true })).body;
  // a ban (chat's): the poster's ideas leave the public list, the host sees banned, the poster can't post
  out.ban = await call('POST', '/v1/mod', { action: 'ban_idea', id: B }, { auth: true });
  out.ban_host = await call('POST', '/v1/mod', { action: 'ban_idea', id: H }, { auth: true });
  out.pub_after_ban = ids(await pub(), 'next_run');
  out.host_after_ban = (await hostView()).sections.next_run.map((i) => [i.id, i.banned, i.hidden]);
  tick(5);
  out.banned_post = await post({ name: 'Caleb', text: 'again', section: 'general' }, { ip: '192.0.2.17' });
  out.reply_gone = (await edit(G, { reply: '' })).body.idea;
  // closed, then open; then the cap
  await call('POST', '/v1/mod', { action: 'ideas_close' }, { auth: true });
  tick(5);
  out.closed = await post({ name: 'Late', text: 'hello', section: 'general' }, { ip: '192.0.2.33' });
  await call('POST', '/v1/mod', { action: 'ideas_open' }, { auth: true });
  const stored = db.prepare('SELECT COUNT(*) AS n FROM ideas').get().n;
  mod.IDEAS.keep = stored;
  tick(5);
  out.full = await post({ name: 'Late', text: 'hello', section: 'general' }, { ip: '192.0.2.34' });
  out.stored = stored;
  out.after_full = db.prepare('SELECT COUNT(*) AS n FROM ideas').get().n;
  // a restart: a new object on the same storage
  live = make();
  await new Promise((r) => setTimeout(r, 10));
  out.restart = await hostView();
  // the top level: the public list cached, the host's view never
  let hits = 0;
  const env = { ALLOWED_ORIGINS: '', LIVE_OBJECT: 'main-d29', LIVE: { idFromName: (n) => n, get: () => ({ fetch: async (r) => { hits++; return live.fetch(r); } }) } };
  await mod.default.fetch(new Request('https://api.test/v1/ideas'), env);
  await mod.default.fetch(new Request('https://api.test/v1/ideas'), env);
  out.hits_public = hits;
  const hv = await mod.default.fetch(new Request('https://api.test/v1/ideas', { headers: { 'X-Host-Token': TOKEN } }), env);
  const hv2 = await (await mod.default.fetch(new Request('https://api.test/v1/ideas', { headers: { 'X-Host-Token': TOKEN } }), env)).json();
  out.hits_host = hits;
  out.host_top = (await hv.json()).host === true && hv2.host === true;
  out.public_top = (await (await mod.default.fetch(new Request('https://api.test/v1/ideas'), env)).json()).host;
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def worker():
    if not shutil.which("node") or subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True).returncode:
        print("ideas: worker part skipped (no node with node:sqlite)")
        return
    with tempfile.TemporaryDirectory() as d:
        js = os.path.join(d, "t.cjs")
        open(js, "w").write(WORKER_JS)
        r = subprocess.run(["node", "--no-warnings", js, "file://" + os.path.join(SITE, "worker", "worker.js"), TOKEN, PUB],
                           capture_output=True, text=True, timeout=60)
    check("worker ran", r.returncode == 0, r.stderr[-3000:])
    o = json.loads(r.stdout)
    a = o["a"]["body"]["idea"]
    check("an idea", o["a"]["status"] == 200 and a["name"] == "Aurora" and a["section"] == "next_run" and a["status"] == "new"
          and a["text"] == "A run on a death world <b>please</b>", o["a"])
    check("the same cid once", o["a_again"]["body"].get("repeat") and o["a_again"]["body"]["idea"]["id"] == a["id"], o["a_again"])
    check("chat's 4 s", o["fast"]["status"] == 429, o["fast"])
    check("a guest name", o["guest"]["status"] == 200 and o["guest"]["body"]["guest_name"].startswith("Guest "), o["guest"])
    for k, want in (("bad_section", 400), ("link", 400), ("long", 400), ("empty", 400), ("reserved", 400)):
        check(k, o[k]["status"] == want, o[k])
    check("reserved name", o["reserved"]["body"]["error"] == "that name is reserved", o["reserved"])
    check("6 an hour", o["hour"] == [200] * 6 + [429], o["hour"])
    hp = o["host_post"]["body"]["idea"]
    check("the host posts as NickWinter", o["host_post"]["status"] == 200 and hp["name"] == "NickWinter" and hp.get("host"), o["host_post"])
    check("a wrong host token", o["wrong_post"]["status"] == 403 and o["wrong_get"]["status"] == 403 and o["wrong_edit"]["status"] == 403,
          (o["wrong_post"], o["wrong_get"], o["wrong_edit"]))
    check("a viewer cannot change one", o["viewer_edit"]["status"] == 401, o["viewer_edit"])
    A, B, H = a["id"], o["b"]["body"]["idea"]["id"], hp["id"]
    G = o["guest"]["body"]["idea"]["id"]
    check("in order", o["order0"] == [A, H, B], o["order0"])
    check("down", o["down"] == 200 and o["order1"] == [H, A, B], o["order1"])
    check("pinned first, highlighted", o["pin"]["pinned"] and o["pin"]["highlight"] and o["order2"] == [B, H, A], (o["pin"], o["order2"]))
    check("to the other section, at its end", o["to_general"]["section"] == "general" and o["general"][-1] == H, o["general"])
    check("an edit", o["text"]["text"] == "Show the belts and pipes on the map" and o["text"]["edited_t"], o["text"])
    p = o["prio"]
    check("priority, status, reply", p["priority"] == "high" and p["status"] == "planned" and p["reply"].startswith("Good one") and p["reply_t"], p)
    check("bad priority and status", o["bad_prio"]["status"] == 400 and o["bad_status"]["status"] == 400, (o["bad_prio"], o["bad_status"]))
    pub_ids = [i["id"] for i in o["pub_after_hide"]["sections"]["next_run"]]
    host_rows = {i["id"]: i for i in o["host_after_hide"]["sections"]["next_run"]}
    check("hidden: out of the public list", A not in pub_ids and "hidden" not in json.dumps(o["pub_after_hide"]), o["pub_after_hide"])
    check("hidden: the host sees it", host_rows[A]["hidden"] is True and o["host_after_hide"]["host"] is True, host_rows)
    ex = {r["id"]: r for r in o["export"]["rows"]}
    check("the export has every idea", A in ex and ex[A]["hidden"] == 1 and o["export"]["key"] == "id", o["export"])
    check("ban_idea", o["ban"]["status"] == 200 and o["ban_host"]["status"] == 400, (o["ban"], o["ban_host"]))
    check("banned: out of the public list", B not in o["pub_after_ban"], o["pub_after_ban"])
    check("banned: the host sees it", [B, True, False] in o["host_after_ban"], o["host_after_ban"])
    check("a banned poster", o["banned_post"]["status"] == 403, o["banned_post"])
    check("a reply taken away", "reply" not in o["reply_gone"], o["reply_gone"])
    check("closed", o["closed"]["status"] == 403 and "closed" in o["closed"]["body"]["error"], o["closed"])
    check("the cap", o["full"]["status"] == 507 and o["after_full"] == o["stored"], (o["full"], o["stored"], o["after_full"]))
    rs = o["restart"]
    rg = {i["id"]: i for i in rs["sections"]["general"]}
    check("a restart keeps it all", [i["id"] for i in rs["sections"]["next_run"]] == [B, A] and rg[G]["priority"] == "high"
          and rg[G]["status"] == "planned" and H in rg and rs["stored"] == o["stored"], rs)
    check("the public list cached at the top", o["hits_public"] == 1, o)
    check("the host's view never cached", o["hits_host"] == 3 and o["host_top"] and o.get("public_top") is None, o)


def no_relay():
    """No tool, stream service, host CLI or site push names the ideas endpoint (the page, the worker, docs and tests do)."""
    hits = []
    for pat in ("tools/**/*.py", "tools/**/*.sh", "tools/**/*.js", "site/*.py", "vendor/factorio-harness/host/**/*.ts",
                "vendor/factorio-harness/mod/**/*.lua"):
        for f in glob.glob(os.path.join(REPO, pat), recursive=True):
            if os.path.basename(f).startswith("test_") or "node_modules" in f:
                continue
            try:
                if "/v1/ideas" in open(f, errors="replace").read():
                    hits.append(os.path.relpath(f, REPO))
            except OSError:
                pass
    check("nothing on the Mac reads /v1/ideas", not hits, hits)


def page_html():
    import build
    build.CONFIG["live_api_url"] = "https://api.test"
    html = build.build_ideas()
    for want in ("What would you like to see in the next run?", "General ideas", 'id="idea-form"', 'name="section" value="next_run"',
                 'name="section" value="general"', '/static/ideas.js', 'data-api="https://api.test"', "no agent or AI reads them"):
        check(f"page has {want!r}", want in html, want)
    nav = build.nav_html("/ideas/")
    check("the menu links it", '<a href="/ideas/" aria-current=page>Ideas</a>' in nav, nav)
    return build


JS = r"""
const pw = require(process.argv[2]);
const [exe, base] = process.argv.slice(3);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const b = await pw.chromium.launch(exe ? { executablePath: exe } : {});
  const out = {};
  for (const [name, w] of [['narrow', 400], ['wide', 1300]]) {
    const ctx = await b.newContext({ viewport: { width: w, height: 900 } });
    await ctx.addInitScript(() => { try { if (!sessionStorage.getItem('seeded')) { localStorage.setItem('chatName', 'Aurora'); sessionStorage.setItem('seeded', '1'); } } catch (e) {} });
    const page = await ctx.newPage();
    const errors = [], posts = [], urls = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('request', (r) => { urls.push(r.url()); if (r.method() === 'POST') posts.push({ url: r.url(), headers: r.headers(), body: r.postData() }); });
    await page.goto(base + '/ideas/');
    await page.waitForSelector('.idea-list .idea', { timeout: 20000 });
    await wait(300);
    const view = () => page.evaluate(() => ({
      name: document.querySelector('#idea-form [name=name]').value,
      texts: [...document.querySelectorAll('.idea-text')].map((e) => e.textContent),
      bold: document.querySelectorAll('.idea-text b').length,
      reply: (document.querySelector('.idea-reply') || {}).textContent || '',
      tools: document.querySelectorAll('.idea-tools').length,
      hidden: document.querySelectorAll('.idea.is-hidden').length,
      hostLine: !document.querySelector('.idea-host').hidden,
      wide: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) - window.innerWidth,
      href: location.href }));
    const r = { errors };
    r.viewer = await view();
    await page.goto(base + '/ideas/?host=' + 'h'.repeat(24));
    await page.waitForSelector('.idea-tools', { timeout: 20000 });
    await wait(300);
    r.host = await view();
    await page.click('#idea-1 [data-act=pinned]');
    await wait(500);
    r.posts = posts;
    r.tokenInUrl = urls.some((u) => u.includes('h'.repeat(24)) && !u.endsWith('/ideas/?host=' + 'h'.repeat(24)));
    out[name] = r;
    await ctx.close();
  }
  await b.close();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def serve(html):
    ideas = {"schema": 1, "open": True, "stored": 3, "cap": 2000, "sections": {
        "next_run": [{"id": 1, "t": 1793300000, "name": "Aurora", "text": "A death world <b>please</b>", "section": "next_run",
                      "pinned": False, "highlight": True, "priority": "high", "status": "planned",
                      "reply": "On the list.", "reply_t": 1793300100},
                     {"id": 2, "t": 1793300200, "name": "Caleb", "text": "x" * 300, "section": "next_run", "pinned": False,
                      "highlight": False, "priority": "", "status": "new"}],
        "general": []}}
    hidden = {"id": 3, "t": 1793300300, "name": "Spam", "text": "hidden one", "section": "general", "pinned": False,
              "highlight": False, "priority": "", "status": "new", "hidden": True, "banned": False}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def send(self, body, ctype):
            self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*"); self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            self.send(b'{"ok":true,"idea":{}}', "application/json")
        def do_GET(self):
            p = self.path.split("?")[0]
            if p == "/v1/ideas":
                v = json.loads(json.dumps(ideas))
                if self.headers.get("X-Host-Token") == TOKEN:
                    v["host"] = True
                    v["sections"]["general"] = [hidden]
                return self.send(json.dumps(v).encode(), "application/json")
            if p == "/ideas/":
                return self.send(html["page"].encode(), "text/html")
            f = os.path.join(SITE, p.lstrip("/"))
            if p.startswith("/static/") and os.path.isfile(f):
                ct = "text/css" if f.endswith(".css") else "application/javascript" if f.endswith(".js") else "application/octet-stream"
                return self.send(open(f, "rb").read(), ct)
            self.send_response(404); self.end_headers()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def browser(build):
    import test_maptoolbar
    found = test_maptoolbar.playwright()
    if not found:
        print("ideas: page part skipped (no Playwright or no cached Chromium)")
        return
    html = {"page": ""}
    httpd = serve(html)
    base = f"http://127.0.0.1:{httpd.server_address[1]}"
    build.CONFIG["live_api_url"] = base
    html["page"] = build.build_ideas()
    try:
        with tempfile.TemporaryDirectory() as d:
            js = os.path.join(d, "t.js")
            open(js, "w").write(JS)
            r = subprocess.run(["node", js, found[0], found[1], base], capture_output=True, text=True, timeout=120)
    finally:
        httpd.shutdown()
    check("browser", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    for name, x in o.items():
        v, h = x["viewer"], x["host"]
        check(f"{name}: no page error", not x["errors"], x["errors"])
        check(f"{name}: the saved chat name", v["name"] == "Aurora", v)
        check(f"{name}: text escaped", v["bold"] == 0 and "A death world <b>please</b>" in v["texts"], v)
        check(f"{name}: the reply", "Reply from the host" in v["reply"] and "On the list." in v["reply"], v)
        check(f"{name}: no tools for a viewer", v["tools"] == 0 and not v["hostLine"] and v["hidden"] == 0, v)
        check(f"{name}: nothing wider than the page", v["wide"] <= 0 and h["wide"] <= 0, (v["wide"], h["wide"]))
        check(f"{name}: the host link leaves the address bar", "host=" not in h["href"] and h["hostLine"], h)
        check(f"{name}: the host's tools and the hidden idea", h["tools"] == 3 and h["hidden"] == 1 and "hidden one" in h["texts"], h)
        pins = [p for p in x["posts"] if p["url"].endswith("/v1/ideas/1")]
        check(f"{name}: Pin sends the change", pins and json.loads(pins[0]["body"]) == {"pinned": True}
              and pins[0]["headers"].get("x-host-token") == TOKEN, x["posts"])
        check(f"{name}: the token never in a URL the page fetched", not x["tokenInUrl"], x)


def main():
    worker()
    no_relay()
    build = page_html()
    browser(build)
    print("ideas: ok (worker: posts, limits, bans, host tools, kept across a restart, export, cap; nothing on the Mac "
          "reads them; the page at 400 and 1300 px with the host link)")


if __name__ == "__main__":
    main()
