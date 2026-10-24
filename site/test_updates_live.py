#!/usr/bin/env python3
"""The Updates page's order, filters, notices and recheck (d24 batch159 QB1, viewer Aurora 11:27-11:28: "Could Updates
sort each status group newest first by its stage date, offer acknowledged/deployed sorting, and add text search plus
status/area filters? Keep shareable links."; "Status notices still end Oct23. Could deploy/restart/outage and recovery
events update them, with event times and a checked-through timestamp separate from page-build time?"; "Could Updates
state its publish cadence and recheck for changes while visible or on return? Show new updates without moving the
page, preserving filters and open details."): python3 site/test_updates_live.py

- site/updates.py: each status group newest first by the date it reached that status; each row carries its status,
  area, stage, acknowledged, deployed and asked dates and its search words; the search and filter form (hidden without
  script); the cadence; a notice's affected part and recovery (or "Not recovered yet"); "checked through" apart from
  "this page built"; updates_json() gives each row as the page has it, with a sig;
- tools/operator_updates.py: notice --affected --recovered / --open, recover (the newest open one of that part),
  checked; recover with nothing open and a recovery before the event are refused; eight notices posted at once all land;
- static/updates.js in headless Chromium (Playwright from the npx cache, as site/test_maptoolbar.py; skipped when there
  is none) on the page served from a temp folder: ?status=&sort= applies on load and the sort orders by the date; the
  search filters and the URL keeps it; then, filtered by area, with a row's details open and the window scrolled to a
  row below, a recheck after a rebuild of the same data reads stamp.json only; after a change it reads stamp.json, then
  updates.json, and adds a new row above (marked new) and one of another area (hidden by the
  filter), replaces a changed row (marked changed, its details still open), updates the notices and the checked line,
  and leaves the row the reader was looking at where it was.
No clock: every time is given.
"""
import glob, html, json, os, shutil, socket, subprocess, sys, tempfile, threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import updates  # noqa: E402

TOOL = HERE.parent / "tools" / "operator_updates.py"


def esc(s):
    return html.escape(str(s), quote=True)


def row(uid, status, area, dates, **k):
    return dict({"id": uid, "title": f"Title {uid}", "status": status, "area": area, "dates": dates, "work": f"batch {uid}"}, **k)


def fixture():
    ups = [row("ip-old", "in progress", "site", {"asked": "2026-10-23 08:00", "in progress": "2026-10-23 09:00"},
               requested_by=[{"name": "Aurora", "ref": "site:1"}], note="Older stage."),
           row("ip-new", "in progress", "harness", {"planned": "2026-10-22 07:00", "in progress": "2026-10-24 08:00"}),
           row("live-a", "live", "site", {"in progress": "2026-10-22 10:00", "live": "2026-10-22 12:00"}),
           row("live-b", "live", "stream", {"in progress": "2026-10-21 10:00", "live": "2026-10-23 12:00"})]
    for i in range(14):  # a long verified list: the page scrolls
        ups.append(row(f"ver-{i:02d}", "verified", "site", {"live": f"2026-10-{10 + i:02d} 10:00", "verified": f"2026-10-{10 + i:02d} 11:00"},
                       note="A verified change with a note long enough to take a few lines on a narrow window. " * 3))
    notices = [{"t": "2026-10-24 09:00", "kind": "outage", "text": "Stream down.", "affected": "stream", "recovered": "2026-10-24 10:05"},
               {"t": "2026-10-24 11:00", "kind": "restart", "text": "Stream service restarting.", "affected": "stream", "recovered": None},
               {"t": "2026-10-22 20:18", "kind": "deploy", "text": "Runtime deployed."}]
    return {"updates": ups, "notices": notices, "notices_checked": "2026-10-24 11:30"}


ASKS = {"site:1": {"name": "Aurora", "text": "Please sort the groups.", "at": None}}
BUILT = updates.when("2026-10-24 11:40")


def page_checks():
    data = fixture()
    body, head = updates.build_page(data, ASKS, {}, esc, built=BUILT)
    ip = body.split('<h3 id="in-progress"', 1)[1].split("</ul>", 1)[0]
    assert ip.index('id="u-ip-new"') < ip.index('id="u-ip-old"'), "in progress: the newest stage first"
    live = body.split('<h3 id="live"', 1)[1].split("</ul>", 1)[0]
    assert live.index('id="u-live-b"') < live.index('id="u-live-a"'), "live: the newest live date first"
    li = body.split('<li class="upd" ', 1)[1]
    for attr in ('data-sig="', 'data-status="in progress"', 'data-area="harness"', 'data-stage="202610240800"',
                 'data-ack="202610220700"', 'data-live="0"', 'data-q="title ip-new ip-new in progress harness batch ip-new"'):
        assert attr in li.split(">", 1)[0], (attr, li[:400])
    old = body.split('id="u-ip-old"', 1)[0].rsplit("<li", 1)[1] + body.split('id="u-ip-old"', 1)[1].split(">", 1)[0]
    assert 'data-asked="202610230800"' in old and "please sort the groups." in old, old  # the asking message is searchable
    assert '<form id="upd-tools" class="upd-tools" role="search" hidden' in body and 'id="upd-checked"' in body
    assert all(f'<option value="{k}">' in body for k in ("stage", "ack", "live", "asked"))
    assert "rebuilt every hour and whenever the operator refreshes the site" in body and "every 3 minutes" in body
    assert "Status data last changed Sat 24 Oct 11:00; this page built Sat 24 Oct 11:40." in body, body[:1500]
    notices = body.split('<h2 id="notices">', 1)[1]
    assert "Status notices checked through Sat 24 Oct 11:30." in notices, notices
    assert ('<span class="fx-chip fx-chip--grey upd-affected">stream</span> Stream down. '
            '<span class="muted upd-recovered">Recovered Sat 24 Oct 10:05 (1 h 05 min later).</span>') in notices, notices
    assert "Stream service restarting. <span class=\"upd-flag upd-recovered\">Not recovered yet.</span>" in notices, notices
    assert "Runtime deployed.</li>" in notices  # an old notice: no recovery said either way
    assert head == '<script src="/static/updates.js" defer></script>'
    j = updates.updates_json(data, ASKS, {}, esc, built=BUILT)
    assert j["built"] == "2026-10-24 11:40" and j["checked"] == "Status notices checked through Sat 24 Oct 11:30."
    for r in j["rows"]:
        assert r["html"] in body and f'data-sig="{r["sig"]}"' in r["html"], r["id"]
    # a group with no rows: a hidden heading without an id (no link may point at it), its list there for new rows
    b, _ = updates.build_page({"updates": [u for u in data["updates"] if u["status"] != "planned"], "notices": []}, {}, {}, esc)
    assert '<h3 data-group-head="planned" hidden>' in b and '<ul class="upd-list" data-group="planned"></ul>' in b
    # notices: recovered is a time or null, affected a text
    for bad in ({"t": "2026-10-24 09:00", "kind": "outage", "text": "x", "recovered": "soon"},
                {"t": "2026-10-24 09:00", "kind": "outage", "text": "x", "affected": ""}):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"updates": [], "notices": [bad]}, f)
        try:
            updates.load(f.name)
            raise AssertionError(f"accepted {bad}")
        except ValueError:
            pass
        finally:
            os.unlink(f.name)
    return data


def tool_checks():
    with tempfile.TemporaryDirectory() as d:
        f = str(Path(d) / "u.json")
        run = lambda *a: subprocess.run([sys.executable, str(TOOL), "--file", f, *a], capture_output=True, text=True)  # noqa: E731
        r = run("notice", "--kind", "outage", "--text", "OBS stopped; stream down.", "--affected", "stream", "--open", "--at", "2026-10-24 09:00")
        assert r.returncode == 0 and r.stdout.strip() == "notice: outage 2026-10-24 09:00 (stream); open until recover", r
        r = run("notice", "--kind", "deploy", "--text", "Runtime deployed (abc).", "--affected", "harness runtime",
                "--at", "2026-10-24 09:10", "--recovered", "2026-10-24 09:12")
        assert r.returncode == 0, r
        assert run("recover", "--affected", "stream", "--at", "2026-10-24 08:00").returncode != 0  # before the event
        r = run("recover", "--affected", "stream", "--at", "2026-10-24 09:40")
        assert r.returncode == 0 and r.stdout.strip() == "recovered: outage 2026-10-24 09:00 -> 2026-10-24 09:40", r
        r = run("recover", "--affected", "stream", "--at", "2026-10-24 09:50")
        assert r.returncode != 0 and "no open notice for stream" in r.stderr, r
        assert run("notice", "--kind", "deploy", "--text", "x", "--at", "2026-10-24 09:10", "--recovered", "2026-10-24 09:00").returncode != 0
        r = run("checked", "--at", "2026-10-24 10:00")
        assert r.returncode == 0 and r.stdout.strip() == "notices checked through 2026-10-24 10:00", r
        data = updates.load(f)
        assert data["notices"] == [
            {"t": "2026-10-24 09:00", "kind": "outage", "text": "OBS stopped; stream down.", "affected": "stream", "recovered": "2026-10-24 09:40"},
            {"t": "2026-10-24 09:10", "kind": "deploy", "text": "Runtime deployed (abc).", "affected": "harness runtime", "recovered": "2026-10-24 09:12"}], data
        assert data["notices_checked"] == "2026-10-24 10:00"
        # eight scripts at once: each notice lands (one writer at a time)
        procs = [subprocess.Popen([sys.executable, str(TOOL), "--file", f, "notice", "--kind", "restart", "--text", f"r{i}",
                                   "--at", "2026-10-24 10:30"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for i in range(8)]
        assert all(p.wait() == 0 for p in procs)
        assert sorted(n["text"] for n in updates.load(f)["notices"] if n["kind"] == "restart") == [f"r{i}" for i in range(8)]


def playwright():
    """(playwright module dir, a Chromium the cache has) or None."""
    mods = [os.environ.get("PLAYWRIGHT")] + glob.glob(os.path.expanduser("~/.npm/_npx/*/node_modules/playwright"))
    mod = next((m for m in mods if m and os.path.isdir(m)), None)
    exes = sorted(glob.glob(os.path.expanduser("~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"))
                  + glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")))
    return (mod, exes[-1]) if mod and exes and shutil.which("node") else None


JS = r"""
const pw = require(process.argv[2]);
const [exe, base, dir] = process.argv.slice(3);
const fs = require('fs');
(async () => {
  const b = await pw.chromium.launch({ executablePath: exe });
  const out = {};
  try {
    const page = await b.newPage({ viewport: { width: 390, height: 500 } });
    page.on('pageerror', (e) => { out.error = String(e); });
    // the URL's view applies on load: in progress only, sorted by the date it was acknowledged
    await page.goto(base + '/updates/?status=in+progress&sort=ack');
    await page.waitForFunction(() => !document.getElementById('upd-tools').hidden);
    out.load = await page.evaluate(() => ({
      shown: document.getElementById('upd-shown').textContent,
      visible: [...document.querySelectorAll('li.upd')].filter((li) => !li.hidden).map((li) => li.id),
      liveHead: document.querySelector('[data-group-head="live"]').hidden, sort: document.getElementById('upd-sort').value }));
    await page.fill('#upd-q', 'sort the groups');
    out.search = await page.evaluate(() => ({ url: location.search,
      visible: [...document.querySelectorAll('li.upd')].filter((li) => !li.hidden).map((li) => li.id) }));
    // filtered by area, a row's details open, the window scrolled to a verified row
    await page.goto(base + '/updates/?area=site');
    await page.waitForFunction(() => !document.getElementById('upd-tools').hidden);
    await page.evaluate(() => { document.querySelector('#u-ip-old details').open = true; document.getElementById('u-ver-05').scrollIntoView(); });
    out.before = await page.evaluate(() => ({ top: document.getElementById('u-ver-05').getBoundingClientRect().top, y: scrollY }));
    // the same data rebuilt: the stamp is unchanged, so updates.json is not fetched
    const asked = [];
    page.on('request', (r) => asked.push(new URL(r.url()).pathname));
    await page.evaluate(() => window.PogUpdates.check());
    await page.waitForFunction(() => /no change/.test(document.getElementById('upd-live-note').textContent));
    out.same = asked.slice();
    asked.length = 0;
    fs.copyFileSync(dir + '/next.json', dir + '/updates/updates.json');  // the next build's
    fs.copyFileSync(dir + '/next-stamp.json', dir + '/updates/stamp.json');
    await page.evaluate(() => window.PogUpdates.check());
    await page.waitForFunction(() => /new/.test(document.getElementById('upd-live-note').textContent));
    out.next = asked.slice();
    out.after = await page.evaluate(() => {
      const li = (id) => document.getElementById(id);
      const chip = (id) => li(id) && li(id).querySelector('.upd-new') ? li(id).querySelector('.upd-new').textContent : null;
      return { top: li('u-ver-05').getBoundingClientRect().top, y: scrollY, url: location.search,
        note: document.getElementById('upd-live-note').textContent,
        added: !!li('u-ip-added'), addedHidden: li('u-ip-added') && li('u-ip-added').hidden, addedChip: chip('u-ip-added'),
        otherHidden: li('u-ip-harness2') && li('u-ip-harness2').hidden,
        changedChip: chip('u-ip-old'), changedNote: li('u-ip-old').querySelector('.upd-note').textContent,
        detailsOpen: li('u-ip-old').querySelector('details').open,
        firstInProgress: [...document.querySelector('ul[data-group="in progress"]').children].filter((x) => !x.hidden)[0].id,
        count: document.querySelector('[data-group-head="in progress"] .upd-n').textContent,
        liveCount: document.querySelector('[data-group-head="live"] .upd-n').textContent,
        checked: document.getElementById('upd-checked').textContent,
        notices: document.getElementById('upd-notices').textContent };
    });
  } finally { await b.close(); }
  console.log(JSON.stringify(out));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def browser_checks(data):
    found = playwright()
    if not found:
        print("updates live: browser part skipped (no Playwright or no cached Chromium)")
        return
    css = (HERE / "static" / "style.css").read_text()
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "updates").mkdir()
        (root / "static").mkdir()
        shutil.copy(HERE / "static" / "updates.js", root / "static" / "updates.js")
        body, head = updates.build_page(data, ASKS, {}, esc, built=BUILT)
        (root / "updates" / "index.html").write_text(f'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                                                     f'<style>{css}</style>{head}<body><main>{body}</main></body>')
        full = updates.updates_json(data, ASKS, {}, esc, built=BUILT)
        (root / "updates" / "updates.json").write_text(json.dumps(full))
        # rebuilt an hour later from the same data: a new build time, the same stamp
        (root / "updates" / "stamp.json").write_text(json.dumps(dict(updates.stamp_json(full), built="2026-10-24 12:40")))
        nxt = json.loads(json.dumps(data))
        nxt["updates"].append(row("ip-added", "in progress", "site", {"in progress": "2026-10-24 11:45"}))
        nxt["updates"].append(row("ip-harness2", "in progress", "harness", {"in progress": "2026-10-24 11:46"}))
        nxt["updates"][0]["note"] = "Now the newest note."
        nxt["notices"].append({"t": "2026-10-24 11:44", "kind": "deploy", "text": "Runtime deployed (def).", "affected": "harness runtime"})
        nxt["notices_checked"] = "2026-10-24 11:50"
        nfull = updates.updates_json(nxt, ASKS, {}, esc, built=updates.when("2026-10-24 11:55"))
        assert nfull["stamp"] != full["stamp"]
        (root / "next.json").write_text(json.dumps(nfull))
        (root / "next-stamp.json").write_text(json.dumps(updates.stamp_json(nfull)))
        js = root / "t.js"
        js.write_text(JS)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        srv = ThreadingHTTPServer(("127.0.0.1", port), partial(QuietHandler, directory=str(root)))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            r = subprocess.run(["node", str(js), found[0], found[1], f"http://127.0.0.1:{port}", str(root)],
                               capture_output=True, text=True, timeout=90)
        finally:
            srv.shutdown()
            srv.server_close()
    assert r.returncode == 0, r.stderr[-2000:]
    o = json.loads(r.stdout)
    assert "error" not in o, o["error"]
    assert o["load"]["visible"] == ["u-ip-old", "u-ip-new"], o["load"]  # acknowledged: ip-old 10-23 09:00, ip-new 10-22 07:00
    assert o["load"]["shown"] == "Showing 2 of 18 updates" and o["load"]["liveHead"] and o["load"]["sort"] == "ack", o["load"]
    assert o["search"]["visible"] == ["u-ip-old"] and o["search"]["url"] == "?q=sort+the+groups&status=in+progress&sort=ack", o["search"]
    assert o["same"] == ["/updates/stamp.json"] and o["next"] == ["/updates/stamp.json", "/updates/updates.json"], (o["same"], o["next"])
    a, bf = o["after"], o["before"]
    assert a["added"] and not a["addedHidden"] and a["addedChip"] == "new", a
    assert a["otherHidden"], a  # another area: in the page, hidden by the filter
    assert a["changedChip"] == "changed" and "Now the newest note." in a["changedNote"] and a["detailsOpen"], a
    assert a["firstInProgress"] == "u-ip-added" and a["count"] == "2 of 4" and a["liveCount"] == "1 of 2", a  # area site
    assert abs(a["top"] - bf["top"]) <= 2 and a["y"] > bf["y"], (bf, a)  # the row stays put: the window moved down with the rows added
    assert a["url"] == "?area=site", a
    assert a["checked"] == "Status notices checked through Sat 24 Oct 11:50." and "Runtime deployed (def)." in a["notices"], a
    assert a["note"].startswith("Rechecked ") and a["note"].endswith(": 2 new, 1 changed (marked)."), a


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


def main():
    data = page_checks()
    tool_checks()
    browser_checks(data)
    print("updates live: ok (groups newest first by stage, row data and filters, notices with recovery and checked-through, "
          "the tool's notice/recover/checked under a lock, the page's filters, URL and in-place recheck)")


if __name__ == "__main__":
    main()
