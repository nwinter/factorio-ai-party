#!/usr/bin/env python3
"""Checks a built site: HTML parses, internal links and assets resolve, every page is noindex.

    python3 site/check.py [site/dist]
"""

import sys
from html.parser import HTMLParser
from pathlib import Path

DIST = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent / "dist")
# config.json "public": the site is indexable, so no page may say noindex (and robots.txt allows crawling)
PUBLIC = bool(__import__("json").loads((Path(__file__).resolve().parent / "config.json").read_text()).get("public"))
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "path",
        "line", "circle", "rect"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.ids, self.stack, self.errors = [], set(), [], []
        self.noindex = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta" and a.get("name") == "robots" and "noindex" in (a.get("content") or ""):
            self.noindex = True
        for k in ("href", "src"):
            if a.get(k):
                self.links.append(a[k])
        if a.get("id"):
            self.ids.add(a["id"])
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
        else:
            self.errors.append(f"unexpected </{tag}> at {self.getpos()} (open: {[t for t, _ in self.stack[-3:]]})")


def resolve(href):
    path = href.split("#")[0].split("?")[0]
    if not path:
        return None
    p = DIST / path.lstrip("/")
    if path.endswith("/"):
        p = p / "index.html"
    return p


problems = []
pages = {}
for f in sorted(DIST.rglob("*.html")):
    pg = Page()
    pg.feed(f.read_text())
    pages[f] = pg
    rel = f.relative_to(DIST)
    if pg.noindex == PUBLIC:
        problems.append(f"{rel}: " + ("robots noindex on a public site" if PUBLIC else "missing robots noindex"))
    for e in pg.errors[:5]:
        problems.append(f"{rel}: {e}")
    if pg.stack:
        problems.append(f"{rel}: unclosed {[t for t, _ in pg.stack]}")
for f, pg in pages.items():
    for href in pg.links:
        if href.startswith(("http://", "https://", "mailto:", "data:")):
            continue
        target = resolve(href)
        if target is None:
            frag = href[1:]
            if frag and frag not in pg.ids:
                problems.append(f"{f.relative_to(DIST)}: broken anchor {href}")
            continue
        if not target.exists():
            problems.append(f"{f.relative_to(DIST)}: broken link {href}")
        elif "#" in href and target in pages:
            frag = href.split("#", 1)[1]
            if frag and frag not in pages[target].ids:
                problems.append(f"{f.relative_to(DIST)}: broken anchor {href}")
robots = (DIST / "robots.txt").read_text() if (DIST / "robots.txt").exists() else ""
if ("Disallow: /" in robots) == PUBLIC:
    problems.append("robots.txt disallows everything on a public site" if PUBLIC else "robots.txt does not disallow everything")
headers = (DIST / "_headers").read_text() if (DIST / "_headers").exists() else ""
if ("noindex" in headers) == PUBLIC:
    problems.append("_headers: X-Robots-Tag noindex on a public site" if PUBLIC else "_headers: no X-Robots-Tag noindex")
print(f"{len(pages)} pages checked")
for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
