#!/usr/bin/env python3
"""The team's blueprint library page (/blueprints/; viewer Foobator, d15 batch5 J1): python3 site/test_blueprints.py

On a made-up runs folder (test_archive's chain) whose last shift has tools/bplibrary.py's copy (blueprints/index.json
and NAME.txt): the page lists each entry with its author, footprint, entity counts, description, uses, last use,
surface and saving time, newest saved first, and the blueprint string in a read-only box with a copy button; an entry
whose string is missing says so; the nav links it; check.py passes. Without a copy there is no page and no link.
"""
import json, re, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
from test_archive import make, build  # noqa: E402


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
        home = (out / "index.html").read_text()
        nav = re.search(r'<nav class="site-nav".*?</nav>', home, re.S).group(0)
        assert re.findall(r">([^<]+)</a>", nav) == ["Live", "The run", "Agents", "Timeline", "Chronicle", "Chat", "Blueprints", "Search", "About"], nav
    print("site blueprints: ok (the library page from the newest shift's copy, strings to copy, linked from the nav)")


if __name__ == "__main__":
    main()
