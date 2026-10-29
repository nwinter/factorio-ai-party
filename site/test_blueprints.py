#!/usr/bin/env python3
"""The team's blueprint library page (/blueprints/; viewer Foobator, d15 batch5 J1): python3 site/test_blueprints.py

On a made-up runs folder (test_archive's chain) whose last shift has tools/bplibrary.py's copy (blueprints/index.json
and NAME.txt): the page lists each entry with its author, footprint, entity counts, description, uses, last use,
surface and saving time, newest saved first, and the blueprint string in a read-only box with a copy button; an entry
whose string is missing says so; the nav links it; check.py passes. Without a copy there is no page and no link.

The picture (d17 08:35): each entry with a string has "Show the picture"; in a stub DOM (needs node) a click adds
FPSR's embed iframe, the string goes to FPSR's origin only after that iframe says fpsr:ready, messages from elsewhere
are ignored, an fpsr:error is shown, and a second click removes the iframe and its listener.
"""
import json, re, shutil, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
from test_archive import make, build  # noqa: E402
import blueprints  # noqa: E402

PIC_STUB = r"""
// blueprints.PIC_JS in a stub DOM: argv[2] the script's body. Prints what happened.
const listeners = { click: [], message: [] };
const posts = [];
const mk = (attrs = {}) => ({ attrs, hidden: !!attrs.hidden, textContent: '', classList: { s: new Set(),
  toggle(c) { this.s.has(c) ? this.s.delete(c) : this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); } },
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }, setAttribute(k, v) { this.attrs[k] = v; } });
const note = mk(), large = mk({ 'data-pic': 'large', hidden: true }), show = mk({ 'data-pic': 'show' });
const box = mk({ 'data-for': 'bp-0', 'data-name': 'astra.swift.inner.v2' });
box.frame = null;
box.querySelector = (q) => (q === '.bp-pic-note' ? note : q === 'iframe' ? box.frame : q === '[data-pic=large]' ? large : null);
box.appendChild = (f) => { box.frame = f; };
show.closest = (q) => (q === '[data-pic]' ? show : q === '.bp-pic' ? box : null);
large.closest = (q) => (q === '[data-pic]' ? large : q === '.bp-pic' ? box : null);
const text = { value: '0eNqrVkrKKU0tKMrMK1GyqlYqLU4tssrMyy9KBYvUAgB/MQqf' };
const win = { postMessage: (m, o) => posts.push({ m, o }) };
global.window = { addEventListener: (t, f) => listeners[t].push(f), removeEventListener: (t, f) => { listeners[t] = listeners[t].filter((g) => g !== f); } };
global.document = { addEventListener: (t, f) => listeners[t].push(f), getElementById: (id) => (id === 'bp-0' ? text : null),
  createElement: () => { const f = mk(); f.contentWindow = win; f.remove = () => { box.frame = null; }; return f; } };
eval(process.argv[2]);
const click = (el) => listeners.click.forEach((f) => f({ target: el }));
const msg = (source, origin, data) => listeners.message.forEach((f) => f({ source, origin, data }));
const out = {};
click(show);
out.frame = box.frame && { src: box.frame.src, title: box.frame.title, ref: box.frame.attrs.referrerpolicy };
out.label = show.textContent; out.large_hidden = large.hidden; out.note = note.textContent;
msg({}, 'https://fpsr.fprints.xyz', { type: 'fpsr:ready', version: 1 });    // another window: ignored
msg(win, 'https://evil.example', { type: 'fpsr:ready', version: 1 });       // the wrong origin: ignored
out.posts_before = posts.length;
msg(win, 'https://fpsr.fprints.xyz', { type: 'fpsr:ready', version: 1 });
out.posts = posts.slice();
msg(win, 'https://fpsr.fprints.xyz', { type: 'fpsr:loaded', version: 1, kind: 'blueprint' });
out.note_loaded = note.textContent;
msg(win, 'https://fpsr.fprints.xyz', { type: 'fpsr:error', version: 1, message: 'bad <string>' });
out.note_error = note.textContent;
click(large); out.large = box.classList.contains('is-large'); out.large_label = large.textContent;
out.listeners = listeners.message.length;
click(show);
out.after_hide = { frame: box.frame, label: show.textContent, large: box.classList.contains('is-large'), large_hidden: large.hidden, listeners: listeners.message.length };
process.stdout.write(JSON.stringify(out));
"""


def picture_tests():
    if not shutil.which("node"):
        print("site blueprints: picture part skipped (no node)")
        return
    script = re.search(r"<script>(.*)</script>", blueprints.PIC_JS, re.S).group(1)
    with tempfile.TemporaryDirectory() as d:
        js = Path(d) / "pic.cjs"
        js.write_text(PIC_STUB)
        r = subprocess.run(["node", str(js), script], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    assert o["frame"] == {"src": "https://fpsr.fprints.xyz/?embed=1", "title": "Picture of astra.swift.inner.v2, drawn by FPSR",
                          "ref": "no-referrer"}, o
    assert o["label"] == "Hide the picture" and o["large_hidden"] is False and "Loading" in o["note"], o
    assert o["posts_before"] == 0, o  # nothing to a window or origin that is not FPSR's iframe
    assert o["posts"] == [{"m": {"type": "fpsr:load", "version": 1, "blueprint": "0eNqrVkrKKU0tKMrMK1GyqlYqLU4tssrMyy9KBYvUAgB/MQqf"},
                           "o": "https://fpsr.fprints.xyz"}], o
    assert o["note_loaded"] == "" and o["note_error"] == "FPSR could not draw it: bad <string>", o
    assert o["large"] is True and o["large_label"] == "Smaller" and o["listeners"] == 1, o
    assert o["after_hide"] == {"frame": None, "label": "Show the picture", "large": False, "large_hidden": True, "listeners": 0}, o


FILTER_STUB = r"""
// blueprints.FILTER_JS in a stub DOM: argv[2] the script, argv[3] the start URL's query. Prints what happened.
const mk = (id, value) => ({ id, value, hidden: id === 'bp-tools' || id === 'bp-shown', textContent: '', ls: [],
  addEventListener(t, f) { this.ls.push(f); }, options: [] });
const els = {};
['bp-tools', 'bp-list', 'bp-q', 'bp-place', 'bp-kind', 'bp-status', 'bp-sort', 'bp-shown'].forEach((id) => { els[id] = mk(id, ''); });
const opts = (id, vals) => { els[id].options = vals.map((v) => ({ value: v })); };
opts('bp-place', ['', 'nauvis', 'platform']); opts('bp-kind', ['', 'defence', 'rail']); opts('bp-status', ['', 'current', 'experimental', 'obsolete', 'none']);
opts('bp-sort', ['newest', 'used', 'name']); els['bp-sort'].value = 'newest';
const li = (name, saved, uses, q, place, kinds, status) => ({ hidden: false, dataset: { name, saved: String(saved), uses: String(uses), q, place, kinds, status } });
const entries = [li('c-belt', 300, 0, 'c-belt sol transport-belt nauvis not marked', 'nauvis', '', 'none'),
  li('b-wall', 200, 5, 'b-wall luna stone-wall gun-turret nauvis current', 'nauvis', 'defence', 'current'),
  li('a-rail', 100, 9, 'a-rail astra straight-rail train-stop platform 3 tern experimental', 'platform', 'rail defence', 'experimental')];
els['bp-list'].children = entries.slice();
els['bp-list'].appendChild = (x) => { const c = els['bp-list'].children; c.splice(c.indexOf(x), 1); c.push(x); };
let url = '/blueprints/' + process.argv[3];
global.location = { get search() { return url.includes('?') ? url.slice(url.indexOf('?')) : ''; }, pathname: '/blueprints/', hash: '' };
global.history = { replaceState: (a, b, u) => { url = u; } };
const loaded = [];
global.document = { readyState: 'loading', addEventListener: (t, f) => { if (t === 'DOMContentLoaded') loaded.push(f); }, getElementById: (id) => els[id] };
eval(process.argv[2]);
const before = { shown: els['bp-shown'].textContent, tools_hidden: els['bp-tools'].hidden, waiting: loaded.length };
loaded.forEach((f) => f());
const out = { before, start: { q: els['bp-q'].value, kind: els['bp-kind'].value, shown: els['bp-shown'].textContent, url, tools_hidden: els['bp-tools'].hidden,
  visible: entries.filter((e) => !e.hidden).map((e) => e.dataset.name) } };
const fire = (id, v) => { els[id].value = v; els[id].ls.forEach((f) => f()); };
fire('bp-kind', ''); fire('bp-q', 'NAUVIS  wall');
out.search = { visible: entries.filter((e) => !e.hidden).map((e) => e.dataset.name), shown: els['bp-shown'].textContent, url };
fire('bp-q', ''); fire('bp-status', 'none');
out.status = { visible: entries.filter((e) => !e.hidden).map((e) => e.dataset.name), url };
fire('bp-status', ''); fire('bp-sort', 'used');
out.used = { order: els['bp-list'].children.map((e) => e.dataset.name), shown: els['bp-shown'].textContent, url };
fire('bp-sort', 'name'); out.name = els['bp-list'].children.map((e) => e.dataset.name);
fire('bp-sort', 'newest'); out.newest = { order: els['bp-list'].children.map((e) => e.dataset.name), url };
process.stdout.write(JSON.stringify(out));
"""


def filter_tests():
    """FILTER_JS (in the page's head: it starts at DOMContentLoaded): the query in the URL applied on load; search words (all of them, any case) over the search text; a
    filter by status; sorting by uses, name and newest; the count shown; the URL keeps the view."""
    if not shutil.which("node"):
        print("site blueprints: filter part skipped (no node)")
        return
    script = re.search(r"<script>(.*)</script>", blueprints.FILTER_JS, re.S).group(1)
    with tempfile.TemporaryDirectory() as d:
        js = Path(d) / "filter.cjs"
        js.write_text(FILTER_STUB)
        r = subprocess.run(["node", str(js), script, "?q=astra&kind=defence"], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    o = json.loads(r.stdout)
    assert o["before"] == {"shown": "", "tools_hidden": True, "waiting": 1}, o  # in the head: it waits for the page
    assert o["start"] == {"q": "astra", "kind": "defence", "shown": "Showing 1 of 3 blueprints", "url": "/blueprints/?q=astra&kind=defence",
                          "tools_hidden": False, "visible": ["a-rail"]}, o
    assert o["search"] == {"visible": ["b-wall"], "shown": "Showing 1 of 3 blueprints", "url": "/blueprints/?q=NAUVIS++wall"}, o
    assert o["status"] == {"visible": ["c-belt"], "url": "/blueprints/?status=none"}, o
    assert o["used"] == {"order": ["a-rail", "b-wall", "c-belt"], "shown": "Showing all 3 blueprints", "url": "/blueprints/?sort=used"}, o
    assert o["name"] == ["a-rail", "b-wall", "c-belt"], o
    assert o["newest"] == {"order": ["c-belt", "b-wall", "a-rail"], "url": "/blueprints/"}, o


def main():
    content = json.loads((SITE / "content" / "site.json").read_text())
    with tempfile.TemporaryDirectory() as d:
        runs = Path(d) / "runs"
        runs.mkdir()
        make(runs)
        out = build(d, dict(content, archive=False, run_start="pub1"), runs)
        assert not (out / "blueprints").exists()
        home = (out / "index.html").read_text()
        assert 'href="/blueprints/"' not in home
        lib = runs / "pub2" / "blueprints"
        lib.mkdir()
        entries = [{"name": "Sol-defense-island", "author": "muse", "entities": 66, "footprint": "14x14",
                    "counts": "stone-wall*52 gun-turret*4", "saved": "14h08m ago", "last_used": "never", "uses": 0,
                    "surface": "nauvis", "description": "Four guns & four lasers <central requester>", "saved_tick": 14156795,
                    "status": "experimental", "status_by": "luna", "status_tick": 14200000, "status_note": "walls untested"},
                   {"name": "astra.tern-inner-freighter.v1", "author": "astra", "entities": 214, "tiles": 732, "footprint": "34x29",
                    "counts": "transport-belt*99 fast-inserter*33", "last_used": "1h02m ago (by sol)", "uses": 2,
                    "surface": "platform-3", "platform_name": "Tern", "saved_tick": 17100000},
                   {"name": "bad name!", "author": "x"}]
        (lib / "index.json").write_text(json.dumps({"revision": 21, "tick": 17210328, "written": "2026-10-16T05:43:36", "entries": entries}))
        (lib / "Sol-defense-island.txt").write_text("0eNqVk91ugzAMhd/F12FqCqWUV5mmKYDXWQoBJaFaVfHucxi0lfa3y+Q433dsxxeozYiDJ+ehuoAhNLA6V2Yz4N/CZ7JC9b8FlrY7YQ4N\n")
        out = build(d, dict(content, archive=False, run_start="pub1"), runs)
        page = (out / "blueprints" / "index.html").read_text()
        names = re.findall(r'<li class="bp-entry" id="([^"]+)"', page)
        assert names == ["astra.tern-inner-freighter.v1", "Sol-defense-island"], names  # newest saved first; a bad name left out
        assert "34x29 tiles" in page and '<span class="bp-n">214</span>' in page, page
        # the entities as the game's icons with their counts (batch270), the name on hover
        assert '<span class="bp-ent" title="transport belt"><img class="gi" src="/static/game/item/transport-belt.webp"' in page
        assert '<span>×99</span>' in page and '<span>×33</span>' in page
        assert "Saved on</dt><dd>platform 3" in page and "2, last 1h02m ago (by sol)" in page and "0, never placed" in page, page
        assert "Four guns &amp; four lasers &lt;central requester&gt;" in page, page
        assert '<textarea id="bp-1" readonly' in page and "0eNqVk91ugzAMhd" in page and 'data-for="bp-1"' in page, page
        assert "The string is not in this copy." in page and "shift 2, copied 2026-10-16 05:43:36" in page, page
        assert "navigator.clipboard" in page
        # the picture control: one per entry with a string, none without; nothing from FPSR loads with the page
        pics = re.findall(r'<div class="bp-pic" data-for="(bp-\d+)" data-name="([^"]+)">', page)
        assert pics == [("bp-1", "Sol-defense-island")], pics
        assert page.count('data-pic="show"') == 1 and "fpsr:load" in page and "<iframe" not in page, page
        # (d24 batch145 PQ1) status marks, kinds and places from the facts, the search text, the controls
        assert '<span class="bp-status bp-status--experimental">experimental</span>' in page, page
        assert '<span class="bp-status bp-status--none">not marked</span>' in page, page
        assert re.search(r"Status</dt><dd>experimental, marked by luna, game time [^<]+: walls untested</dd>", page), page
        assert "Status</dt><dd>not marked</dd>" in page and "Saved on</dt><dd>platform 3 (Tern)" in page, page
        assert "Kinds</dt><dd>Defence</dd>" in page and "Kinds</dt><dd>Assembly" not in page, page
        sol = re.search(r'<li class="bp-entry" id="Sol-defense-island"[^>]*>', page).group(0)
        assert 'data-place="nauvis"' in sol and 'data-kinds="defence"' in sol and 'data-status="experimental"' in sol, sol
        assert 'data-q="sol-defense-island muse four guns &amp; four lasers &lt;central requester&gt; stone-wall gun-turret nauvis nauvis experimental"' in sol, sol
        tern = re.search(r'<li class="bp-entry" id="astra.tern-inner-freighter.v1"[^>]*>', page).group(0)
        assert 'data-place="platform"' in tern and 'data-uses="2"' in tern and 'data-status="none"' in tern and " tern " in tern, tern
        assert '<option value="nauvis">Nauvis (1)</option><option value="platform">Space platform (1)</option>' in page, page
        assert '<option value="defence">Defence (1)</option>' in page and '<option value="none">Not marked (1)</option>' in page, page
        assert '<form id="bp-tools" class="bp-tools" role="search" hidden' in page and "How a kind and a status are decided" in page, page
        assert '<ul class="bp-list" id="bp-list">' in page, page
        home = (out / "index.html").read_text()
        nav = re.search(r'<nav class="site-nav".*?</nav>', home, re.S).group(0)
        assert re.findall(r">([^<]+)</a>", nav) == ["Live", "The run", "Agents", "Timeline", "Chronicle", "Chat", "Blueprints", "Search", "About", "Polls", "Ideas", "Updates", "How it was made", "GitHub"], nav
    picture_tests()
    filter_tests()
    print("site blueprints: ok (the library page from the newest shift's copy, strings to copy, linked from the nav; "
          "pictures by FPSR's embed on request, the string to FPSR's iframe only)")


if __name__ == "__main__":
    main()
