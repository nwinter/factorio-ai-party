#!/usr/bin/env python3
"""The site's nav (batch270, Nick d27 10:10: Polls de-emphasised, highlighted when a poll is open): python3 site/test_nav.py

On a fixture build (test_archive.make, the archive off):
- the nav's links: Live, The run, Agents, Timeline, Chronicle, Chat, Search, About, then "More" (a disclosure) with
  Polls, Updates, How it was made, GitHub; a page under More marks its link and the summary (is-current);
- a Menu button for phones (aria-controls the nav) and the `js` class set in the head (with no script every link shows);
- the header carries the live API's URL for site.js's poll check, the homepage's poll card sits right under the player
  (before the archive strip), and polls.js reports the open polls to the nav (PogNav.polls);
- site.js: one /v1/polls call at most every 10 minutes per tab (sessionStorage), none on a page with its own poll script;
  "open" beside Polls and a dot on More and Menu.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
from test_archive import make  # noqa: E402


def main():
    content = dict(json.loads((SITE / "content" / "site.json").read_text()), archive=False, run_start="pub1")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        runs = d / "runs"
        runs.mkdir()
        make(runs)
        (d / "site.json").write_text(json.dumps(content))
        out = d / "dist"
        r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                            "--content", str(d / "site.json")], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]
        home = (out / "index.html").read_text()
        nav = re.search(r'<nav class="site-nav" id="site-nav" aria-label="Main">(.*?)</nav>', home, re.S).group(1)
        main_part, more = nav.split('<details class="nav-more">')
        assert re.findall(r">([^<]+)</a>", main_part) == ["Live", "The run", "Agents", "Timeline", "Chronicle", "Chat",
                                                          "Search", "About"], main_part
        assert re.findall(r">([^<]+)</a>", more) == ["Polls", "Updates", "How it was made", "GitHub"], more
        assert '<summary>More<span class="nav-dot" hidden></span></summary>' in more
        assert '<button class="nav-toggle fx-btn" type="button" aria-expanded="false" aria-controls="site-nav">Menu' in home
        assert "document.documentElement.classList.add('js')" in home
        cfg = json.loads((SITE / "config.json").read_text())
        assert f'<header class="site-header fx-root" data-api="{cfg["live_api_url"]}">' in home
        assert home.index('id="polls" class="polls-card') < home.index('id="run-title"'), "the poll card under the player"
        polls = (out / "polls" / "index.html").read_text()
        assert '<details class="nav-more is-current">' in polls and '<a href="/polls/" aria-current=page>Polls</a>' in polls
        about = (out / "about" / "index.html").read_text()
        assert '<details class="nav-more">' in about and '<a href="/about/" aria-current=page>About</a>' in about
    js = (SITE / "static" / "site.js").read_text()
    assert "window.PogNav = { polls: polls }" in js and "sessionStorage.getItem('pollsOpen')" in js and "600000" in js
    assert "!document.getElementById('polls')" in js, "no second poll call where polls.js runs"
    assert "window.PogNav.polls(open.length)" in (SITE / "static" / "polls.js").read_text()
    print("test_nav: ok (More holds Polls, Updates, How it was made, GitHub; Menu on phones; the poll card under the "
          "player; an open poll marks the nav)")


if __name__ == "__main__":
    main()
