#!/usr/bin/env python3
"""Open Details and the chat's scroll kept on refresh (d22 batch75 AK8, viewer Aurora site:4250: "Put a small Details
button in each header for routing and matching info. Keep full replies visible, put reply counts inline and tighten
spacing. Preserve open details and scroll on refresh."): python3 site/test_chatkeep.py

The built /live/ page (build.build_live) with static/live.js and style.css in headless Chromium (Playwright from the npx
cache, as test_maptoolbar.py finds it; skipped when there is none), its API a local server: 60 site lines and
test_replythreads.py's kind of replies. At 1300 px and 400 px:
- a Details button opens a reply's routing and matching in place, and it stays open when the list is rebuilt (the
  replies box off and on) and after a reload;
- scrolled to the middle, the same line stays at the top, at the same offset, after a rebuild and after a reload;
- at the end, a reload shows the end;
- every reply's full text is shown (no clipping), and nothing is wider than the page.
"""
import json, os, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True

JS = r"""
const pw = require(process.argv[2]);
const [exe, url] = process.argv.slice(3);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const top = () => { const l = document.querySelector('#vchat'), t = l.getBoundingClientRect().top;
  const li = [...l.children].find((e) => e.getBoundingClientRect().bottom > t + 1); return li && [li.id, Math.round(li.getBoundingClientRect().top - t)]; };
(async () => {
  const b = await pw.chromium.launch(exe ? { executablePath: exe } : {});
  const out = {};
  for (const [name, w] of [['wide', 1300], ['narrow', 400]]) {
    const ctx = await b.newContext({ viewport: { width: w, height: 900 } });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(url);
    await page.waitForSelector('#vchat .c-details-btn', { timeout: 20000 });
    await wait(400);
    const r = { errors };
    r.atEndFirst = await page.evaluate(() => { const l = document.querySelector('#vchat'); return l.scrollHeight - l.scrollTop - l.clientHeight < 40; });
    // a reply's Details, then the list scrolled so a site line sits 20 px below its top
    const key = await page.evaluate(() => document.querySelector('#vchat li.c-thread .c-details-btn').dataset.det);
    await page.click('[data-det="' + key + '"]');
    r.open = await page.evaluate((k) => ({ hidden: document.getElementById('cd-' + k).hidden, text: document.getElementById('cd-' + k).innerText,
      expanded: document.querySelector('[data-det="' + k + '"]').getAttribute('aria-expanded') }), key);
    await page.evaluate(() => { const l = document.querySelector('#vchat'), li = document.getElementById('c-s30');
      l.scrollTop += li.getBoundingClientRect().top - l.getBoundingClientRect().top - 20; l.dispatchEvent(new Event('scroll')); });
    await wait(400);
    r.before = await page.evaluate(top);
    await page.evaluate(() => { const c = document.querySelector('#vchat-replies'); c.click(); c.click(); });
    await wait(200);
    r.rebuilt = await page.evaluate(top);
    r.rebuiltOpen = await page.evaluate((k) => !document.getElementById('cd-' + k).hidden, key);
    await page.reload();
    await page.waitForSelector('#vchat .c-details-btn', { timeout: 20000 });
    await wait(1500);
    r.reloaded = await page.evaluate(top);
    r.reloadedOpen = await page.evaluate((k) => ({ hidden: document.getElementById('cd-' + k).hidden,
      expanded: document.querySelector('[data-det="' + k + '"]').getAttribute('aria-expanded') }), key);
    // full texts: no reply text clipped; nothing wider than the page
    r.clipped = await page.evaluate(() => [...document.querySelectorAll('#vchat .c-agent .c-text')].filter((e) => e.scrollHeight > e.clientHeight + 1 || getComputedStyle(e).textOverflow === 'ellipsis').length);
    r.wide = await page.evaluate(() => document.scrollingElement.scrollWidth - document.documentElement.clientWidth);
    // to the end, then a reload: the end
    await page.evaluate(() => { const l = document.querySelector('#vchat'); l.scrollTop = l.scrollHeight; l.dispatchEvent(new Event('scroll')); });
    await wait(400);
    await page.reload();
    await page.waitForSelector('#vchat .c-details-btn', { timeout: 20000 });
    await wait(1500);
    r.endAfterReload = await page.evaluate(() => { const l = document.querySelector('#vchat'); return l.scrollHeight - l.scrollTop - l.clientHeight < 40; });
    out[name] = r;
    await ctx.close();
  }
  await b.close();
  process.stdout.write(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def fixtures(now):
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = now
    msgs = [{"seq": i, "t": now - 3600 + i * 50, "name": "Foobator" if i % 2 else "Caleb", "text": f"@muse line {i} about the south wall"} for i in range(1, 61)]
    a = lambda name, text, i: {"name": name, "text": text, "source": "site", "id": i}  # noqa: E731
    s["viewer_replies"] = [{"seq": 100 + i, "t": now - 3600 + i * 50 + 20, "by": "muse", "text": f"{'Foobator' if i % 2 else 'Caleb'}, line {i}: " + "the wall is closed. " * 6,
                            "kind": "reply", "to": ["Foobator" if i % 2 else "Caleb"], "link": "reply_to",
                            "answers": a("Foobator" if i % 2 else "Caleb", f"line {i} about the south wall", f"site:{i}")} for i in range(5, 61, 5)]
    s["youtube_chat"] = []
    return s, msgs


def serve(page, state, msgs):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def send(self, body, ctype):
            self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Cache-Control", "no-store"); self.end_headers()
            self.wfile.write(body)
        def do_POST(self): self.send(b'{"ok":true}', "application/json")
        def do_GET(self):
            p = self.path.split("?")[0]
            if p == "/v1/state":
                return self.send(json.dumps({"state": dict(state, now=time.time()), "age_s": 2, "received": time.time() - 2}).encode(), "application/json")
            if p == "/v1/chat":
                after = None
                if "after=" in self.path:
                    after = int(self.path.split("after=")[1].split("&")[0])
                out = [m for m in msgs if after is None or m["seq"] > after]
                return self.send(json.dumps({"messages": out, "last_seq": msgs[-1]["seq"], "open": True}).encode(), "application/json")
            if p.startswith("/v1/"):
                return self.send(b'{"messages":[],"polls":[]}', "application/json")
            if p in ("/live/", "/"):
                return self.send(page["html"].encode(), "text/html")
            f = os.path.join(SITE, p.lstrip("/"))
            if p.startswith("/static/") and os.path.isfile(f):
                ct = "text/css" if f.endswith(".css") else "application/javascript" if f.endswith(".js") else "application/octet-stream"
                return self.send(open(f, "rb").read(), ct)
            if p.endswith("status.json"):
                return self.send(b"{}", "application/json")
            self.send_response(404); self.end_headers()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def main():
    import test_maptoolbar
    found = test_maptoolbar.playwright()
    if not found:
        print("chat keep: skipped (no Playwright or no cached Chromium)")
        return
    import build
    state, msgs = fixtures(time.time())
    page = {"html": ""}
    httpd = serve(page, state, msgs)
    build.CONFIG["live_api_url"] = f"http://127.0.0.1:{httpd.server_address[1]}"
    build.CONFIG["live_status_url"] = "/live/status.json"
    page["html"] = build.build_live()
    try:
        with tempfile.TemporaryDirectory() as d:
            js = os.path.join(d, "t.js")
            open(js, "w").write(JS)
            r = subprocess.run(["node", js, found[0], found[1], f"http://127.0.0.1:{httpd.server_address[1]}/live/"],
                               capture_output=True, text=True, timeout=120)
    finally:
        httpd.shutdown()
    check("browser", r.returncode == 0, r.stderr[-2000:])
    o = json.loads(r.stdout)
    for name, x in o.items():
        check(f"{name}: no page error", not x["errors"], x["errors"])
        check(f"{name}: the end at first", x["atEndFirst"], x)
        check(f"{name}: Details opens", x["open"]["hidden"] is False and x["open"]["expanded"] == "true" and "answers" in x["open"]["text"]
              and "linked by the reply itself" in x["open"]["text"], x["open"])
        check(f"{name}: scrolled to c-s30", x["before"] and x["before"][0] in ("c-s30", "c-s29", "c-a125") , x["before"])
        check(f"{name}: kept on a rebuild", x["rebuilt"] == x["before"] and x["rebuiltOpen"], (x["before"], x["rebuilt"]))
        check(f"{name}: kept on a reload", x["reloaded"] == x["before"], (x["before"], x["reloaded"]))
        check(f"{name}: Details open after a reload", x["reloadedOpen"] == {"hidden": False, "expanded": "true"}, x["reloadedOpen"])
        check(f"{name}: full replies", x["clipped"] == 0, x["clipped"])
        check(f"{name}: nothing wider than the page", x["wide"] <= 0, x["wide"])
        check(f"{name}: the end kept on a reload", x["endAfterReload"], x)
    print("chat keep: ok (Details open in place and kept on a rebuild and a reload; the scroll's top line kept on both; "
          "the end kept; full replies; 1300 and 400 px)")


if __name__ == "__main__":
    main()
