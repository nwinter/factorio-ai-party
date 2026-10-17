#!/usr/bin/env python3
"""How it was made (/how/, site/how.py): python3 site/test_how.py

- every page in how.PAGES has its Markdown file, a "# " title and a summary paragraph, and every "## " section opens
  with a paragraph (its summary);
- the text passes the build's privacy check (no owner name, email, local path, key or address) and has no
  "[path]"/"[ip]" left by clean();
- every root-relative link names a page the site builds (a typo would otherwise turn into plain text silently);
- built into a temporary folder: each page is written, the footer and the pages link /how/, a link to a page the build
  did not write is plain text, and each section's first paragraph is the summary.
"""
import re, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import build  # noqa: E402
import how  # noqa: E402

# the site's pages a /how/ page may link (build.py main: these are written with the long run)
ROUTES = re.compile(r"/(?:|polls/|live/|runs/long/(?:shift-\d+/)?|agents/|timeline/|chronicle/|chat/|blueprints/|"
                    r"search/|about/|how/(?:" + "|".join(s + "/" for s, _ in how.PAGES if s) + r")?)(?:#[\w-]+)?")


def test_sources():
    for slug, _ in how.PAGES:
        src = how.source(slug)
        title, summary = how.title_summary(src)
        assert title and len(summary) > 40, slug
        assert "](" not in summary, f"{slug}: the summary is shown as plain text, no links"
        for m in re.finditer(r"^## .+\n\n(.)", src, re.M):
            assert m.group(1) not in "#|-*`>", f"{slug}: a section starts without a summary paragraph"
        assert not build._BLOCKED.search(src), f"{slug}: {build._BLOCKED.search(src).group(0)}"
        for pat, repl in build._REDACTIONS:
            assert not pat.search(src), f"{slug}: {pat.search(src).group(0)} (clean() would print {repl})"
        for href in re.findall(r"\]\((/[^)\s]*)\)", src):
            assert ROUTES.fullmatch(href), f"{slug}: link to {href}, a page the site does not build"


def test_build():
    with tempfile.TemporaryDirectory() as d:
        out = Path(d)
        (out / "about").mkdir()
        (out / "about" / "index.html").write_text("x")
        how.build(out, build.page, build.markdown, build.esc)
        for slug, _ in how.PAGES:
            t = (out / "how" / (slug + "/" if slug else "") / "index.html").read_text()
            assert 'href="/how/"' in t.split('<footer')[1], "footer links /how/"
            assert '<a href="/about/">' in t
            assert "](/" not in t and "](#" not in t, f"{slug}: a Markdown link left in the page"
            if "<h2 id=" in t and slug:
                assert '<p class="summary">' in t, slug
        # links between the /how/ pages land on a heading that exists
        for slug, _ in how.PAGES:
            t = (out / "how" / (slug + "/" if slug else "") / "index.html").read_text()
            for path, frag in re.findall(r'href="(/how/[^"#]*)?#([^"]+)"', t):
                target = (out / path.lstrip("/") / "index.html").read_text() if path else t
                assert f'id="{frag}"' in target, f"{slug}: link to {path}#{frag}, no such heading"
        # a build without the long run: its links show as text
        t = (out / "how" / "compare" / "index.html").read_text()
        assert 'href="/runs/long/"' not in t
        index = (out / "how" / "index.html").read_text()
        for slug, _ in how.PAGES[1:]:
            assert f'href="/how/{slug}/"' in index


if __name__ == "__main__":
    test_sources()
    test_build()
    print("ok")
