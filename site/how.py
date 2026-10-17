"""How it was made (/how/): a small set of long pages for viewers who want the depth, from the Markdown in
site/content/how/ (one file a page, PAGES order). Each file starts with "# Title" and a one-paragraph summary; each
"## " section opens with its own summary paragraph, which the page sets apart (class "summary").

Links in the text: https links, and root-relative links to the site's own pages ([the run](/runs/long/)). A link to
a page this build did not write (a build without the long run's shifts) is shown as plain text, so check.py passes
either way. Asked for by the project's owner in YouTube chat (d14 22:02) and again on d17 08:38.
"""

import re
from pathlib import Path

CONTENT = Path(__file__).resolve().parent / "content" / "how"
# slug, nav label; "" is the overview at /how/
PAGES = [("", "Overview"), ("setup", "The machines"), ("harness", "The harness"), ("agents", "The agents"),
         ("operations", "The operator and the engineers"), ("lessons", "What we learned"),
         ("compare", "Comparing harnesses")]


def source(slug):
    return (CONTENT / f"{slug or 'index'}.md").read_text()


def title_summary(src):
    """The page's title (its "# " line) and its first paragraph."""
    m = re.match(r"# (.+)\n+((?:.+\n?)+)", src)
    return m.group(1).strip(), " ".join(m.group(2).split())


def _exists(out, href):
    path = href.split("#")[0]
    if not path:
        return True
    p = out / path.lstrip("/")
    return (p / "index.html").exists() if path.endswith("/") else p.exists()


def local_links(html_body, out, esc):
    """Root-relative Markdown links the site's markdown() leaves as text: an <a> when the page was built, else the
    link's text alone."""
    def link(m):
        text, href = m.group(1), m.group(2)
        return f'<a href="{esc(href)}">{text}</a>' if _exists(out, href) else text
    return re.sub(r"\[([^\]]+)\]\(((?:/|#)[^)\s]*)\)", link, html_body)


def render(slug, out, markdown, esc):
    src = source(slug)
    title, summary = title_summary(src)
    body = markdown(re.sub(r"\A# .*\n+(?:.+\n?)+", "", src, count=1))
    body = local_links(body, out, esc)
    body = re.sub(r"(</h2>\n)<p>", r'\1<p class="summary">', body)
    return title, summary, body


def build(out, page, markdown, esc):
    """Write every /how/ page into out (after the rest of the site, so links resolve against what was built)."""
    rendered = {slug: render(slug, out, markdown, esc) for slug, _ in PAGES}
    tabs = "".join(f'<a href="/how/{slug + "/" if slug else ""}">{esc(label)}</a>' for slug, label in PAGES)
    for slug, label in PAGES:
        title, summary, body = rendered[slug]
        path = f"/how/{slug + '/' if slug else ''}"
        tabs_here = tabs.replace(f'<a href="{path}">', f'<a href="{path}" aria-current="page">')
        toc = "".join(f'<li><a href="#{m.group(1)}">{m.group(2)}</a></li>'
                      for m in re.finditer(r'<h2 id="([^"]+)">(.*?)</h2>', body))
        if not slug:
            cards = "".join(
                f'<a class="run-row" href="/how/{s}/"><div><h2>{esc(rendered[s][0])}</h2><p>{esc(rendered[s][1])}</p></div></a>'
                for s, _ in PAGES if s)
            body += f'<h2 id="pages">The pages</h2><div class="run-list">{cards}</div>'
            toc += '<li><a href="#pages">The pages</a></li>'
        html_body = (f'<p class="crumbs"><a href="/about/">About</a> / <a href="/how/">How it was made</a></p>'
                     f'<h1>{esc(title)}</h1><p class="lede">{esc(summary)}</p>'
                     f'<nav class="how-tabs" aria-label="How it was made">{tabs_here}</nav>'
                     f'<div class="study-layout"><nav class="toc" aria-label="Contents"><p>Contents</p><ol>{toc}</ol></nav>'
                     f'<article class="prose how">{body}</article></div>')
        p = out / path.lstrip("/") / "index.html"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(page(title, html_body, "/about/", summary, path=path))
