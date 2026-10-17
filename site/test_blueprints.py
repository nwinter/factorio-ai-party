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
                    "surface": "nauvis", "description": "Four guns & four lasers <central requester>", "saved_tick": 14156795},
                   {"name": "astra.tern-inner-freighter.v1", "author": "astra", "entities": 214, "tiles": 732, "footprint": "34x29",
                    "counts": "transport-belt*99 fast-inserter*33", "last_used": "1h02m ago (by sol)", "uses": 2,
                    "surface": "platform-3", "saved_tick": 17100000},
                   {"name": "bad name!", "author": "x"}]
        (lib / "index.json").write_text(json.dumps({"revision": 21, "tick": 17210328, "written": "2026-10-16T05:43:36", "entries": entries}))
        (lib / "Sol-defense-island.txt").write_text("0eNqVk91ugzAMhd/F12FqCqWUV5mmKYDXWQoBJaFaVfHucxi0lfa3y+Q433dsxxeozYiDJ+ehuoAhNLA6V2Yz4N/CZ7JC9b8FlrY7YQ4N\n")
        out = build(d, dict(content, archive=False, run_start="pub1"), runs)
        page = (out / "blueprints" / "index.html").read_text()
        names = re.findall(r'<li class="bp-entry" id="([^"]+)"', page)
        assert names == ["astra.tern-inner-freighter.v1", "Sol-defense-island"], names  # newest saved first; a bad name left out
        assert "34x29 tiles" in page and "214: transport-belt x99, fast-inserter x33" not in page and "214: transport-belt x99 fast-inserter x33" in page, page
        assert "Saved on</dt><dd>platform 3" in page and "2, last 1h02m ago (by sol)" in page and "0, never placed" in page, page
        assert "Four guns &amp; four lasers &lt;central requester&gt;" in page, page
        assert '<textarea id="bp-1" readonly' in page and "0eNqVk91ugzAMhd" in page and 'data-for="bp-1"' in page, page
        assert "The string is not in this copy." in page and "shift 2, copied 2026-10-16 05:43:36" in page, page
        assert "navigator.clipboard" in page
        # the picture control: one per entry with a string, none without; nothing from FPSR loads with the page
        pics = re.findall(r'<div class="bp-pic" data-for="(bp-\d+)" data-name="([^"]+)">', page)
        assert pics == [("bp-1", "Sol-defense-island")], pics
        assert page.count('data-pic="show"') == 1 and "fpsr:load" in page and "<iframe" not in page, page
        home = (out / "index.html").read_text()
        nav = re.search(r'<nav class="site-nav".*?</nav>', home, re.S).group(0)
        assert re.findall(r">([^<]+)</a>", nav) == ["Live", "Polls", "The run", "Agents", "Timeline", "Chronicle", "Chat", "Blueprints", "Search", "About"], nav
    picture_tests()
    print("site blueprints: ok (the library page from the newest shift's copy, strings to copy, linked from the nav; "
          "pictures by FPSR's embed on request, the string to FPSR's iframe only)")


if __name__ == "__main__":
    main()
