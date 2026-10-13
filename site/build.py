#!/usr/bin/env python3
"""Static site generator for the player-of-games companion site.

Reads the repo's run data (runs/*/scores.jsonl, notes.md, chat logs), the studies
in docs/studies/, and the curated text in site/content/site.json, and writes a
plain HTML/CSS/JS site to site/dist/. Python 3 stdlib only.

    python3 site/build.py            # build into site/dist
    python3 site/build.py --out DIR  # build somewhere else
"""

import argparse
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import sys
import urllib.parse
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
# The art kit lives with the stream overlay; the site copies it so there is one source for both.
ART = REPO / "tools" / "stream" / "static"
# The test runs left the repo before the public run (tools/public-start.sh moved them to ~/code/pog-archive/runs-DATE).
# The archive pages read them there: POG_SITE_ARCHIVE, else the newest runs-* folder under ~/code/pog-archive.
_ARCHIVES = ([Path(os.environ["POG_SITE_ARCHIVE"])] if os.environ.get("POG_SITE_ARCHIVE")
             else sorted((Path.home() / "code" / "pog-archive").glob("runs-*"), reverse=True))


def run_dir(run):
    """A run's folder: in the repo (runs/ID), else in the archive the test runs moved to."""
    here = REPO / run["dir"]
    if here.exists():
        return here
    rel = Path(run["dir"])
    rel = Path(*rel.parts[1:]) if rel.parts and rel.parts[0] == "runs" else rel
    return next((a / rel for a in _ARCHIVES if (a / rel).exists()), here)


sys.path.insert(0, str(ART.parent))
import avatar as avatar_art  # noqa: E402  (tools/stream/avatar.py, reads the part lists from avatar.js)
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402  (site/longrun.py: the long run's shifts from runs/)

CONTENT = json.loads((SITE / "content" / "site.json").read_text())
CONFIG = json.loads((SITE / "config.json").read_text())
PUBLIC = bool(CONFIG.get("public"))
ROBOTS_META = "" if PUBLIC else '<meta name="robots" content="noindex, nofollow">\n'
AGENTS = CONTENT["agents"]


def archive():
    """site.json "archive": true builds the experiments, the earlier runs, the studies and the agent pages; false
    leaves them out (pages and links), so the site starts from the run at "run_start"."""
    return CONTENT.get("archive", True)

esc = html.escape


# ---------------------------------------------------------------- sanitising

_REDACTIONS = [
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "[email]"),
    (re.compile(r"(?:/Users|/home|/private|/tmp|/var)/[^\s`'\")\]]+"), "[path]"),
    (re.compile(r"~/[^\s`'\")\]]+"), "[path]"),
    (re.compile(r"\b[A-Z]:\\[^\s`'\")\]]+"), "[path]"),
    (re.compile(r"\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{12,}"), "[key]"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "[ip]"),
]


# Names of the owner, their accounts and personal tools that appear in some studies. The build fails if any reach
# dist/; site.json's per-study `rewrite` list is where they get replaced.
_BLOCKED = re.compile(r"\bNick\b|(?i:account-b|codex-b|claude-b|dropbox|cygnal|peon-ping|account-d)")
# Chat and host lines from the owner's own channel account, or that name it, are left off the site.
_OWNER = re.compile(r"(?i)\bnick(?:\s*winter)?\b")


def keep_line(text):
    return not (_BLOCKED.search(text or "") or _OWNER.search(text or ""))


def clean(text):
    """Strip things that must never reach the public site: emails, local paths, keys, LAN addresses."""
    for pattern, repl in _REDACTIONS:
        text = pattern.sub(repl, text)
    return text


# ---------------------------------------------------------------- markdown

def _inline(text):
    text = esc(clean(text), quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def markdown(src, heading_shift=0, ids=True):
    """A small Markdown renderer: headings, paragraphs, nested lists, tables, code fences, quotes."""
    lines = src.splitlines()
    out = []
    i = 0
    used_ids = set()

    def slug(t):
        s = re.sub(r"[^a-z0-9]+", "-", re.sub(r"<[^>]+>", "", t).lower()).strip("-") or "s"
        base, n = s, 2
        while s in used_ids:
            s = f"{base}-{n}"
            n += 1
        used_ids.add(s)
        return s

    def parse_list(start):
        # returns (html, next_index)
        items = []
        j = start
        base_indent = len(lines[j]) - len(lines[j].lstrip())
        ordered = bool(re.match(r"\s*\d+\.\s", lines[j]))
        while j < len(lines):
            line = lines[j]
            if not line.strip():
                # blank line: continue list only if next line is an item at this indent
                if j + 1 < len(lines) and re.match(r"\s*(?:[-*]|\d+\.)\s", lines[j + 1]) and \
                        len(lines[j + 1]) - len(lines[j + 1].lstrip()) >= base_indent:
                    j += 1
                    continue
                break
            indent = len(line) - len(line.lstrip())
            m = re.match(r"\s*(?:[-*]|\d+\.)\s+(.*)", line)
            if m and indent == base_indent:
                items.append([m.group(1), ""])
                j += 1
            elif m and indent > base_indent and items:
                sub, j = parse_list(j)
                items[-1][1] += sub
            elif indent > base_indent and items:
                items[-1][0] += " " + line.strip()
                j += 1
            else:
                break
        tag = "ol" if ordered else "ul"
        body = "".join(f"<li>{_inline(t)}{sub}</li>" for t, sub in items)
        return f"<{tag}>{body}</{tag}>", j

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("```"):
            j = i + 1
            buf = []
            while j < len(lines) and not lines[j].startswith("```"):
                buf.append(lines[j])
                j += 1
            out.append(f"<pre><code>{esc(clean(chr(10).join(buf)))}</code></pre>")
            i = j + 1
            continue
        m = re.match(r"(#{1,6})\s+(.*)", line)
        if m:
            level = min(6, len(m.group(1)) + heading_shift)
            text = _inline(m.group(2))
            hid = f' id="{slug(text)}"' if ids else ""
            out.append(f"<h{level}{hid}>{text}</h{level}>")
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]
            head = cells(line)
            j = i + 2
            rows = []
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                rows.append(cells(lines[j]))
                j += 1
            th = "".join(f"<th>{_inline(c)}</th>" for c in head)
            tb = "".join("<tr>" + "".join(f"<td>{_inline(c)}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f'<div class="table-wrap"><table><thead><tr>{th}</tr></thead><tbody>{tb}</tbody></table></div>')
            i = j
            continue
        if re.match(r"\s*(?:[-*]|\d+\.)\s", line):
            block, i = parse_list(i)
            out.append(block)
            continue
        if line.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].startswith(">"):
                buf.append(lines[i].lstrip("> "))
                i += 1
            out.append(f"<blockquote><p>{_inline(' '.join(buf))}</p></blockquote>")
            continue
        if line.startswith("!["):
            i += 1  # images in the docs point at local files; skip them
            continue
        buf = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r"(#{1,6}\s|```|\s*\||\s*(?:[-*]|\d+\.)\s|>)", lines[i]):
            buf.append(lines[i].strip())
            i += 1
        out.append(f"<p>{_inline(' '.join(buf))}</p>")
    return "\n".join(out)


# ---------------------------------------------------------------- run data

def game_time(tick):
    s = int(tick // 60)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{sec:02d}s"


def load_scores(run):
    """Snapshots per world, deduplicated by tick, in game-time order."""
    path = run_dir(run) / "scores.jsonl"
    worlds = {}
    if not path.exists():
        return worlds
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        score = row.get("score") or {}
        tick = score.get("tick")
        if tick is None:
            continue
        if run.get("max_tick") and tick > run["max_tick"]:
            continue
        done = score.get("research_done") or []
        if isinstance(done, dict):
            done = list(done)
        snap = {
            "tick": tick,
            "min": tick / 3600,
            "wall": row.get("t", ""),
            "research": sorted(done),
            "current": score.get("current_research"),
            "produced": score.get("produced") or {},
            "entities": score.get("entities") or {},
        }
        lst = worlds.setdefault(row.get("world", "?"), [])
        if lst and lst[-1]["tick"] == tick:
            lst[-1] = snap
        elif not lst or tick > lst[-1]["tick"]:
            lst.append(snap)
    # a final-score.json (taken at the deadline) supersedes the last snapshot
    final = run_dir(run) / "final-score.json"
    if final.exists() and run.get("world") in worlds:
        sc = json.loads(final.read_text())
        lst = worlds[run["world"]]
        snap = {"tick": sc["tick"], "min": sc["tick"] / 3600, "wall": "final",
                "research": sorted(sc.get("research_done") or []), "current": sc.get("current_research"),
                "produced": sc.get("produced") or {}, "entities": sc.get("entities") or {}}
        lst[:] = [s for s in lst if s["tick"] < snap["tick"]] + [snap]
    return worlds


def research_timeline(snaps):
    """Each technology with the first snapshot that shows it finished (an upper bound on when it finished)."""
    seen = {}
    prev_min = 0.0
    for s in snaps:
        for t in s["research"]:
            if t not in seen:
                seen[t] = (prev_min, s["min"])
        prev_min = s["min"]
    return sorted(seen.items(), key=lambda kv: kv[1][1])


def load_chat(run):
    if not run.get("chat"):
        return []
    path = run_dir(run) / run["chat"]
    if not path.exists():
        return []
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    for r in rows:
        r["text"] = clean(r.get("text", ""))
    return rows


def notes_summary(path):
    """The agent's own final summary from notes.md (the section whose heading mentions 'final')."""
    if not path.exists():
        return None
    lines = path.read_text().splitlines()
    start = None
    level = 0
    for i, line in enumerate(lines):
        m = re.match(r"(#{1,6})\s+(.*)", line)
        if m and re.search(r"final", m.group(2), re.I):
            start, level = i, len(m.group(1))
            break
    if start is None:
        return None
    body = [lines[start]]
    for line in lines[start + 1:]:
        m = re.match(r"(#{1,6})\s", line)
        if m and len(m.group(1)) <= level:
            break
        body.append(line)
    text = "\n".join(body).strip()
    if len(text) > 6000:
        text = text[:6000].rsplit("\n", 1)[0] + "\n\n(truncated)"
    return text


# ---------------------------------------------------------------- charts

PALETTE = ["--s1", "--s2", "--s3", "--s4", "--s5", "--s6", "--s7", "--s8"]
PACKS = [("automation-science-pack", "Red"), ("logistic-science-pack", "Green"), ("chemical-science-pack", "Blue")]
PACK_VARS = {"Red": "--s8", "Green": "--s6", "Blue": "--s1"}  # pack colours, validated as a trio; charts direct-label them
_chart_n = 0


def nice_ticks(vmax, n=5):
    if vmax <= 0:
        return [0, 1]
    raw = vmax / n
    mag = 10 ** len(str(int(raw))) / 10 if raw >= 1 else 1
    for f in (1, 2, 2.5, 5, 10):
        step = f * mag
        if vmax / step <= n:
            break
    ticks = []
    v = 0
    while v < vmax + step * 0.999:
        ticks.append(round(v, 6))
        v += step
    return ticks


def fmt_num(v):
    if v >= 10000:
        return f"{v/1000:.0f}k"
    if v >= 1000:
        return f"{v/1000:.1f}k".replace(".0k", "k")
    return f"{v:g}"


def line_chart(title, series, y_label, x_label="game time (minutes)", step=False, desc="", hours=False, marks=(), clock=(),
               x0=0):
    """Inline SVG line chart with legend, direct end labels (<= 4 series), hover readout and a table view.

    series: [{"name": str, "points": [(x_minutes, y)], "var": "--sN", "dash": bool}] in fixed palette order.
    hours: x ticks in hours of game time; marks: [(x_minutes, label)] dashed verticals (shift starts); clock:
    [(x_minutes, "Oct 12, 20:17")] read by the hover for the real time; x0: the x axis starts here (a shift's page).
    """
    global _chart_n
    _chart_n += 1
    cid = f"c{_chart_n}"
    W, H = 640, 300
    xs = [p[0] for s in series for p in s["points"]] or [0, 1]
    ys = [p[1] for s in series for p in s["points"]] or [0, 1]
    # right margin fits the direct end labels ("Name 1.2k"), which are only drawn for <= 4 series
    longest = max((len(s["name"]) + len(fmt_num(s["points"][-1][1])) + 1 for s in series if s["points"]), default=0)
    L, R, T, B = 48, (int(18 + 6.4 * longest) if len(series) <= 4 else 16), 14, 36
    if hours:
        xticks = [round(x0 + v * 60, 6) for v in nice_ticks(((max(xs) or 1) - x0) / 60, 8)]
    else:
        xticks = [x0 + v for v in nice_ticks((max(xs) or 1) - x0, 8)]
    yticks = nice_ticks(max(ys) or 1, 5)
    xmax, ymax = xticks[-1], yticks[-1]
    pw, ph = W - L - R, H - T - B

    def X(v):
        return L + pw * (v - x0) / ((xmax - x0) or 1)

    def Y(v):
        return T + ph * (1 - v / ymax)

    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-labelledby="{cid}-t" class="chart-svg" preserveAspectRatio="xMidYMid meet">',
             f'<title id="{cid}-t">{esc(title)}</title>']
    for v in yticks:
        parts.append(f'<line class="grid" x1="{L}" x2="{W-R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}"/>')
        parts.append(f'<text class="tick" x="{L-6}" y="{Y(v)+4:.1f}" text-anchor="end">{fmt_num(v)}</text>')
    for v in xticks:
        tick = f"{v / 60:g}h" if hours else fmt_num(v)
        parts.append(f'<text class="tick" x="{X(v):.1f}" y="{H-B+16}" text-anchor="middle">{tick}</text>')
    for mx, mlabel in marks:
        if x0 <= mx <= xmax:
            parts.append(f'<line class="mark" x1="{X(mx):.1f}" x2="{X(mx):.1f}" y1="{T}" y2="{T+ph}"/>'
                         f'<text class="mark-label" x="{X(mx)+3:.1f}" y="{T+10}">{esc(mlabel)}</text>')
    parts.append(f'<line class="axis" x1="{L}" x2="{W-R}" y1="{T+ph}" y2="{T+ph}"/>')
    parts.append(f'<text class="axis-label" x="{L+pw/2}" y="{H-4}" text-anchor="middle">{esc(x_label)}</text>')

    label_slots = []
    for idx, s in enumerate(series):
        pts = s["points"]
        if not pts:
            continue
        var = s.get("var") or PALETTE[idx % len(PALETTE)]
        d = []
        for k, (x, y) in enumerate(pts):
            if k == 0:
                d.append(f"M{X(x):.1f},{Y(y):.1f}")
            elif step:
                d.append(f"H{X(x):.1f}V{Y(y):.1f}")
            else:
                d.append(f"L{X(x):.1f},{Y(y):.1f}")
        dash = ";stroke-dasharray:6 3" if s.get("dash") else ""
        parts.append(f'<path class="line" style="stroke:var({var}){dash}" d="{" ".join(d)}"/>')
        ex, ey = pts[-1]
        if not ey:
            continue  # a line ending at 0 (a pack not made at the shift's end) gets no end dot or label
        parts.append(f'<circle class="end" cx="{X(ex):.1f}" cy="{Y(ey):.1f}" r="4" style="fill:var({var})"/>')
        if len(series) <= 4:
            label_slots.append([Y(ey), X(ex), s["name"], fmt_num(ey)])
    # direct labels, nudged apart vertically
    label_slots.sort()
    for k in range(1, len(label_slots)):
        if label_slots[k][0] - label_slots[k - 1][0] < 14:
            label_slots[k][0] = label_slots[k - 1][0] + 14
    for y, x, name, val in label_slots:
        parts.append(f'<text class="dlabel" x="{x+8:.1f}" y="{y+4:.1f}">{esc(name)} <tspan class="dval">{val}</tspan></text>')
    parts.append(f'<line class="cross" x1="0" x2="0" y1="{T}" y2="{T+ph}" visibility="hidden"/>')
    parts.append(f'<rect class="hit" x="{L}" y="{T}" width="{pw}" height="{ph}" fill="transparent"/>')
    parts.append("</svg>")

    legend = ""
    if len(series) > 1:
        legend = '<ul class="legend">' + "".join(
            f'<li><span class="swatch" style="background:var({s.get("var") or PALETTE[i % 8]})"></span>{esc(s["name"])}</li>'
            for i, s in enumerate(series)) + "</ul>"
    data = {"L": L, "pw": pw, "xmax": xmax, "x0": x0, "W": W, "T": T, "ph": ph, "ymax": ymax, "step": step, "y": y_label,
            "series": [{"name": s["name"], "var": s.get("var") or PALETTE[i % 8], "pts": [[round(x, 2), y] for x, y in s["points"]]}
                       for i, s in enumerate(series)]}
    if clock == "page":
        data["clock"] = "page"  # the page's one #chart-clock list (long_charts), shared by its charts
    elif clock:
        data["clock"] = [[round(x, 2), c] for x, c in clock]
    # table view: a row per x, a column per series
    xs_all = sorted({x for s in series for x, _ in s["points"]})
    vals = [dict(s["points"]) for s in series]
    fx = (lambda x: longrun.game_time(x * 3600)) if hours else (lambda x: f"{x:.1f}")
    rows = "".join(f"<tr><td>{fx(x)}</td>" + "".join(f"<td>{fmt_num(v[x]) if x in v else ''}</td>" for v in vals) + "</tr>"
                   for x in xs_all)
    heads = "".join(f"<th>{esc(s['name'])}</th>" for s in series) if len(series) > 1 else f"<th>{esc(y_label)}</th>"
    table = (f'<details class="table-view"><summary>Show data as a table</summary><div class="table-wrap"><table>'
             f'<thead><tr><th>{"Game time" if hours else "Game minute"}</th>{heads}</tr></thead>'
             f'<tbody>{rows}</tbody></table></div></details>')
    return (f'<figure class="chart" id="{cid}"><figcaption><strong>{esc(title)}</strong>'
            f'{f"<span>{esc(desc)}</span>" if desc else ""}</figcaption>{legend}'
            f'<div class="plot">{"".join(parts)}<div class="tip" hidden></div></div>'
            f'<script type="application/json" class="chart-data">{json.dumps(data)}</script>{table}</figure>')


def research_series(snaps):
    return [(s["min"], len(s["research"])) for s in snaps]


def pack_series(snaps, item):
    return [(s["min"], s["produced"].get(item, 0)) for s in snaps]


def total_packs(snaps):
    return [(s["min"], sum(s["produced"].get(p, 0) for p, _ in PACKS)) for s in snaps]


# ---------------------------------------------------------------- page shell

def agent(key):
    return AGENTS.get(key, {"name": key.title(), "model": "", "harness": "", "color": "#888888", "glyph": key[:1].upper()})


def profile_row(key):
    """The harness `profiles` row the avatar renderer expects: bot name, colour, optional avatar parts."""
    a = agent(key)
    return {"name": key, "display_name": a["name"], "color": a.get("color"), "avatar": a.get("avatar")}


AVATAR_PX = {"sm": 24, "": 32, "lg": 48, "xl": 96}


def avatar(key, size=""):
    # Pixel portrait from the art kit, served as /static/avatars/<key>.svg so long pages don't repeat 4 KB per use.
    a = agent(key)
    px = AVATAR_PX.get(size, 32)
    ring = " fx-agent-ring" if size in ("lg", "xl") else ""
    src = f"/static/avatars/{key}.svg" if key in AGENTS else "data:image/svg+xml," + urllib.parse.quote(avatar_art.svg(profile_row(key), px))
    return (f'<span class="fx-slot avatar {size}{ring}" style="--fx-agent:{a.get("color") or "#888888"}" aria-hidden="true">'
            f'<img src="{src}" alt="" width="{px}" height="{px}" loading="lazy" decoding="async"></span>')


def agent_chip(key):
    a = agent(key)
    return f'<span class="chip">{avatar(key, "sm")}{esc(a["name"])}</span>'


def nav_items():
    """The homepage is the live show; /live/ stays as an alias for links shared before. Without the archive: Live,
    the run's page (when there is one) and About."""
    if archive():
        return [("/", "Live"), ("/experiments/", "Experiments"), ("/runs/", "Runs"), ("/studies/", "Studies"),
                ("/about/", "About")]
    return [("/", "Live")] + ([("/runs/long/", "The run")] if LONG else []) + [("/about/", "About")]


def social_meta(full, site_title, description, path):
    """Open Graph and Twitter card tags, so a shared link shows the title, a line and the card image (site/og_card.py)."""
    base = CONFIG.get("site_url", "").rstrip("/")
    img = SITE / "static" / "og.png"
    if not base or not img.exists():
        return ""
    ver = hashlib.sha256(img.read_bytes()).hexdigest()[:10]
    image = f"{base}/static/og.png?v={ver}"
    tags = [("property", "og:type", "website"), ("property", "og:site_name", site_title), ("property", "og:title", full),
            ("property", "og:description", description)]
    if path:
        tags.append(("property", "og:url", base + path))
    tags += [("property", "og:image", image), ("property", "og:image:width", "1200"),
             ("property", "og:image:height", "630"),
             ("property", "og:image:alt", f"{site_title}: nine AI agents' pixel portraits under the title"),
             ("name", "twitter:card", "summary_large_image"), ("name", "twitter:title", full),
             ("name", "twitter:description", description), ("name", "twitter:image", image)]
    out = "".join(f'<meta {k}="{v}" content="{esc(c)}">\n' for k, v, c in tags)
    return out + (f'<link rel="canonical" href="{esc(base + path)}">\n' if path else "")


def page(title, body, active="/", description="", extra_head="", path=None):
    site_title = CONFIG.get("site_title", "Factorio AI Party")
    full = site_title if title == site_title else f"{title} · {site_title}"
    description = description or CONFIG.get("description", "")
    nav = "".join(
        f'<a href="{href}"{" aria-current=page" if href == active else ""}>{label}</a>' for href, label in nav_items())
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{ROBOTS_META}<title>{esc(full)}</title>
<meta name="description" content="{esc(description)}">
{social_meta(full, site_title, description, path)}<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Titillium+Web:wght@400;600;700&amp;display=swap">
<link rel="stylesheet" href="/static/factorio-ui.css">
<link rel="stylesheet" href="/static/style.css">
<script>try{{var t=localStorage.getItem('theme');if(t)document.documentElement.dataset.theme=t}}catch(e){{}}</script>
{extra_head}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header fx-root">
  <div class="wrap header-row">
    <a class="brand" href="/"><span class="brand-mark" aria-hidden="true"></span>{esc(site_title)}</a>
    <nav class="site-nav" aria-label="Main">{nav}</nav>
    <button class="theme-toggle fx-btn fx-btn--icon" type="button" aria-label="Toggle light or dark theme" title="Toggle theme">
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9z" fill="currentColor"/></svg>
    </button>
  </div>
</header>
<main id="main" class="wrap">
{body}
</main>
<footer class="site-footer">
  <div class="wrap">
    <p>{esc(site_title)}: AI agents playing Factorio together, under the same rules as a human player.
    Built from the project's run logs.{'' if PUBLIC else ' Preview build, not for sharing yet.'}</p>
  </div>
</footer>
<script src="/static/site.js" defer></script>
</body>
</html>
"""


def stat(label, value, sub=""):
    return (f'<div class="stat"><div class="stat-value">{esc(str(value))}</div>'
            f'<div class="stat-label">{esc(label)}</div>{f"<div class=stat-sub>{esc(sub)}</div>" if sub else ""}</div>')


# ---------------------------------------------------------------- pages

def run_final(snaps):
    s = snaps[-1]
    p = s["produced"]
    e = s["entities"]
    return {
        "game": game_time(s["tick"]),
        "techs": len(s["research"]),
        "current": s["current"],
        "red": p.get("automation-science-pack", 0),
        "green": p.get("logistic-science-pack", 0),
        "blue": p.get("chemical-science-pack", 0),
        "iron": p.get("iron-plate", 0),
        "labs": e.get("lab", 0),
        "assemblers": sum(v for k, v in e.items() if k.startswith("assembling-machine")),
    }


def run_players_worlds(run, worlds):
    """[(agent_key, snaps)] for versus runs; [('team', snaps)] for team runs."""
    if run["kind"] == "versus":
        return [(p["agent"], worlds.get(p["world"], [])) for p in run["players"]]
    return [("team", worlds.get(run["world"], []))]


def build_run_page(rid, run, worlds, chat):
    body = []
    exp = next(e for e in CONTENT["experiments"] if e["id"] == run["experiment"])
    body.append(f'<p class="crumbs"><a href="/runs/">Runs</a> / <a href="/experiments/#{exp["id"]}">{esc(exp["title"])}</a></p>')
    body.append(f'<h1>{esc(run["title"])}<span class="h-sub">{esc(run["subtitle"])}</span></h1>')
    meta = [run["date"], run["wall"], run["mode"], f'enemies {run["enemies"]}', "seed 20261010"]
    body.append('<p class="meta">' + " · ".join(esc(m) for m in meta) + "</p>")
    body.append(f'<p class="lede">{esc(run["summary"])}</p>')
    studies = [(sid, st) for sid, st in CONTENT["studies"].items() if st["run"] == rid]
    if studies:
        body.append('<p class="actions">' + " ".join(
            f'<a class="fx-btn" href="/studies/{sid}/">Study: {esc(st["title"])} →</a>' for sid, st in studies) + "</p>")

    pw = run_players_worlds(run, worlds)

    # headline numbers
    body.append('<section><h2>Where it ended</h2>')
    for key, snaps in pw:
        if not snaps:
            continue
        f = run_final(snaps)
        who = "Team" if key == "team" else agent(key)["name"]
        stats = [stat("game time", f["game"]), stat("technologies", f["techs"]),
                 stat("red packs", f'{f["red"]:,}'), stat("green packs", f'{f["green"]:,}')]
        if f["blue"]:
            stats.append(stat("blue packs", f'{f["blue"]:,}'))
        stats += [stat("iron plates", f'{f["iron"]:,}'), stat("labs", f["labs"]), stat("assemblers", f["assemblers"])]
        head = f'<h3 class="who">{agent_chip(key) if key != "team" else "Team totals"}</h3>' if len(pw) > 1 or key == "team" else ""
        cur = f'<p class="muted small">Researching at the end: {esc(f["current"])}</p>' if f["current"] else ""
        body.append(f'{head}<div class="stats">{"".join(stats)}</div>{cur}')
    body.append('<p class="muted small">From the score logger, sampled every two wall-clock minutes. Production counts are lifetime totals for the whole world.</p></section>')

    # milestones
    ms_defs = CONTENT["milestones"]
    cols = list(run["milestones"].keys())
    rows = []
    for m in ms_defs:
        if not any(m["id"] in run["milestones"][c] for c in cols):
            continue
        cells = "".join(f'<td>{esc(run["milestones"][c].get(m["id"], "–"))}</td>' for c in cols)
        rows.append(f'<tr><th scope="row">{esc(m["label"])}</th>{cells}</tr>')
    head = "".join(f'<th scope="col">{agent_chip(c) if c != "team" else "Team"}</th>' for c in cols)
    body.append('<section><h2>Milestones</h2><p class="muted">Game time when each milestone was reached, as logged by the agents and checked against the score log.</p>'
                f'<div class="table-wrap"><table class="milestones"><thead><tr><th>Milestone</th>{head}</tr></thead><tbody>{"".join(rows)}</tbody></table></div></section>')

    if run.get("incidents"):
        items = "".join(f'<li><span class="inc-time">{esc(i["time"])}</span>{esc(i["text"])}</li>' for i in run["incidents"])
        body.append('<section><h2>Operator interventions and incidents</h2><p class="muted">Anything outside the agents\' control: '
                    f'harness bugs, operator actions, lost connections.</p><ul class="incidents">{items}</ul></section>')

    # charts
    body.append('<section><h2>Progress over game time</h2><div class="chart-grid">')
    if run["kind"] == "versus":
        body.append(line_chart("Technologies researched", [{"name": agent(k)["name"], "points": research_series(s)} for k, s in pw],
                               "technologies", step=True))
        body.append(line_chart("Science packs produced (all colours)", [{"name": agent(k)["name"], "points": total_packs(s)} for k, s in pw],
                               "packs"))
    else:
        snaps = pw[0][1]
        body.append(line_chart("Technologies researched", [{"name": "Team", "points": research_series(snaps)}], "technologies", step=True))
        ser = [{"name": label, "var": PACK_VARS[label], "points": pack_series(snaps, item)} for item, label in PACKS
               if any(s["produced"].get(item) for s in snaps)]
        body.append(line_chart("Science packs produced", ser, "packs"))
    body.append("</div></section>")

    # research timeline
    body.append('<section><h2>Research timeline</h2><p class="muted">Each technology appears at the first score snapshot that shows it finished, so times are upper bounds (snapshots are about two wall minutes apart).</p>')
    tl_cols = []
    for key, snaps in pw:
        items = "".join(f'<li><span class="tl-time">{esc(game_time(hi * 3600))}</span><span class="tl-tech">{esc(t.replace("-", " "))}</span></li>'
                        for t, (lo, hi) in research_timeline(snaps))
        label = agent_chip(key) if key != "team" else ""
        tl_cols.append(f'<div class="tl-col">{f"<h3 class=who>{label}</h3>" if label else ""}<ol class="timeline">{items}</ol></div>')
    body.append(f'<div class="tl-grid">{"".join(tl_cols)}</div></section>')

    # agents
    body.append('<section><h2>The agents</h2>')
    if run.get("stats_note"):
        body.append(f'<p class="muted">{esc(run["stats_note"])}</p>')
    body.append('<div class="cards">')
    chat_by = {}
    for c in chat:
        chat_by.setdefault(c["from"], []).append(c)
    notable = set(run.get("notable_chat", []))
    for p in run["players"]:
        k = p["agent"]
        a = agent(k)
        ident = (run.get("identities") or {}).get(k, {})
        lines = [f'<article class="agent-card" style="--ac:{a["color"]}">',
                 f'<header>{avatar(k, "lg")}<div><h3><a href="/agents/{k}/">{esc(a["name"])}</a></h3><p class="model">{esc(a["model"])} · {esc(a["harness"])}</p></div></header>']
        if ident.get("motto"):
            lines.append(f'<p class="motto">“{esc(ident["motto"])}”</p>')
        elif ident.get("note"):
            lines.append(f'<p class="motto muted">{esc(ident["note"])}</p>')
        lines.append(f'<p class="role">{esc(p["role"])}</p>')
        st = (run.get("stats") or {}).get(k)
        if st or chat_by.get(k):
            dl = "".join(f"<div><dt>{esc(n)}</dt><dd>{esc(v)}</dd></div>" for n, v in (st or {}).items())
            if chat_by.get(k):
                dl = f'<div><dt>Chat messages</dt><dd>{len(chat_by[k])}</dd></div>' + dl
            lines.append(f'<dl class="kv">{dl}</dl>')
        quotes = [c for c in chat_by.get(k, []) if c["seq"] in notable]
        if chat_by.get(k) and chat_by[k][0] not in quotes:
            quotes.insert(0, chat_by[k][0])
        if quotes:
            q = "".join(f'<li><span class="q-time">{esc(game_time(c["tick"]))}</span> {esc(c["text"])}</li>' for c in quotes[:4])
            lines.append(f'<ul class="quotes">{q}</ul>')
        summ = notes_summary(run_dir(run) / p["dir"] / "notes.md")
        if summ:
            lines.append(f'<details class="notes"><summary>{esc(a["name"])}\'s own final summary</summary>'
                         f'<div class="prose small">{markdown(summ, heading_shift=2, ids=False)}</div></details>')
        lines.append("</article>")
        body.append("".join(lines))
    body.append("</div></section>")

    # chat
    if chat:
        body.append('<section><h2>Team chat</h2>')
        body.append(f'<p class="muted">{len(chat)} messages, rebuilt from every agent\'s chat reads and posts. Highlighted lines are the moments the study quotes.</p>')
        counts = sorted(((k, len(v)) for k, v in chat_by.items() if k in AGENTS), key=lambda kv: -kv[1])
        top = max((n for _, n in counts), default=1)
        bars = "".join(f'<li><span class="bar-label">{agent_chip(k)}</span><span class="bar-track"><span class="bar" style="width:{100 * n / top:.1f}%"></span></span>'
                       f'<span class="bar-val">{n}</span></li>' for k, n in counts)
        body.append(f'<figure class="bars"><figcaption><strong>Messages per agent</strong></figcaption><ul>{bars}</ul></figure>')
        hl = "".join(_chat_line(c, True) for c in chat if c["seq"] in notable)
        body.append(f'<ol class="chat">{hl}</ol>')
        full = "".join(_chat_line(c, c["seq"] in notable) for c in chat)
        body.append(f'<details class="chat-full"><summary>Full transcript ({len(chat)} messages)</summary><ol class="chat">{full}</ol></details></section>')
    return page(run["title"], "\n".join(body), "/runs/", run["summary"])


def _chat_line(c, hl):
    who = c["from"]
    if who in AGENTS:
        name = agent_chip(who)
    else:
        label = "Operator" if who == "server" else who
        name = f'<span class="chip operator">{esc(label)}</span>'
    return (f'<li class="{"hl" if hl else ""}"><span class="c-time">{esc(game_time(c["tick"]))}</span>'
            f'{name}<span class="c-text">{esc(c["text"])}</span></li>')


LONG = None  # the long run (longrun.load), set in main() when the runs folder has a chain of shifts
# Shift videos uploaded to YouTube (tools/yt_upload.py writes site/content/videos.json): {run id: {id, shift, title,
# description, chapters, playlist}}. A shift with a video gets an embed on /runs/long/ and its own page.
VIDEOS = {}
YT_ID = re.compile(r"^[A-Za-z0-9_-]{6,20}$")


def load_videos(path):
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return {rid: v for rid, v in raw.items() if isinstance(v, dict) and YT_ID.match(str(v.get("id", "")))}


def shift_video(s):
    return VIDEOS.get(s["id"]) if not s.get("empty") else None


def shift_href(s):
    return f'/runs/long/shift-{s["n"]}/'


def video_embed(v, start=0):
    """Privacy-enhanced embed (no cookies until play), 16:9, lazy."""
    q = f"?start={int(start)}" if start else ""
    return (f'<div class="video-wrap"><iframe src="https://www.youtube-nocookie.com/embed/{esc(v["id"])}{q}" '
            f'title="{esc(v.get("title", "Shift video"))}" loading="lazy" allowfullscreen '
            f'allow="accelerometer; encrypted-media; gyroscope; picture-in-picture; web-share" '
            f'referrerpolicy="strict-origin-when-cross-origin"></iframe></div>')


def description_html(text):
    """The video's description as paragraphs and lists; the chapter list is left out (the page shows its own)."""
    text = clean(text).split("\nChapters\n")[0]
    out = []
    for block in text.strip().split("\n\n"):
        lines = [ln for ln in block.split("\n") if ln.strip()]
        items = [ln[2:] for ln in lines if ln.startswith("• ")]
        head = [ln for ln in lines if not ln.startswith("• ")]
        if items and len(head) <= 1:
            out.append((f"<h3>{esc(head[0])}</h3>" if head else "") +
                       "<ul>" + "".join(f"<li>{esc(i)}</li>" for i in items) + "</ul>")
        else:
            out.append("<p>" + "<br>".join(esc(ln) for ln in lines) + "</p>")
    return "\n".join(out)


def _pt(t, day=True):
    """'Oct 12, 20:17' (or '20:17') from a local ISO time; '–' without one."""
    x = longrun.parse_t(t) if t else None
    if not x:
        return "–"
    return x.strftime("%b %-d, %H:%M") if day else x.strftime("%H:%M")


def _hours(a, b):
    x, y = longrun.parse_t(a), longrun.parse_t(b)
    return (y - x).total_seconds() / 3600 if x and y else 0


# every science pack: its chart colour (fixed per pack; the later planet packs reuse a colour, dashed)
PACK_STYLE = {"automation-science-pack": ("--s8", False), "logistic-science-pack": ("--s6", False),
              "military-science-pack": ("--s2", False), "chemical-science-pack": ("--s1", False),
              "production-science-pack": ("--s7", False), "utility-science-pack": ("--s4", False),
              "space-science-pack": ("--s5", False), "metallurgic-science-pack": ("--s3", False),
              "electromagnetic-science-pack": ("--s5", True), "agricultural-science-pack": ("--s3", True),
              "cryogenic-science-pack": ("--s1", True), "promethium-science-pack": ("--s7", True)}
KIND_LABEL = {"science": "Science", "research": "Research", "space": "Space", "team": "Team"}


def pack_rate_series(spm_packs, lo=None, hi=None):
    out = []
    for item, lab in longrun.PACKS:
        pts = [(x, y) for x, y in spm_packs.get(item, []) if (lo is None or x >= lo) and (hi is None or x <= hi)]
        if pts and any(y for _, y in pts):
            var, dash = PACK_STYLE[item]
            out.append({"name": lab, "points": pts, "var": var, "dash": dash})
    return out


def firsts_table(firsts, shift_links=True, filters=False):
    if not firsts:
        return '<p class="muted">None yet.</p>'
    kinds = [k for k in KIND_LABEL if any(f["kind"] == k for f in firsts)]
    bar = ('<div class="kind-filter" role="group" aria-label="Show milestones of one kind" hidden>'
           '<button type="button" class="fx-btn small" data-kind="" aria-pressed="true">All</button>'
           + "".join(f'<button type="button" class="fx-btn small" data-kind="{k}" aria-pressed="false">{KIND_LABEL[k]}</button>'
                     for k in kinds) + '</div>') if filters and len(kinds) > 1 else ""
    rows = "".join(
        f'<tr data-kind="{f["kind"]}"><td><span class="kind kind-{f["kind"]}">{KIND_LABEL[f["kind"]]}</span></td><th scope="row">{esc(f["label"])}</th>'
        f'<td class="num">{esc(longrun.game_time(f["tick"]))}</td><td class="num">{esc(_pt(f["t"]))}</td>'
        + (f'<td class="num"><a href="/runs/long/shift-{f["shift"]}/">{f["shift"]}</a></td>' if shift_links else "") + "</tr>"
        for f in firsts)
    head = ('<th scope="col">Kind</th><th scope="col">Milestone</th><th scope="col">Game time</th><th scope="col">Pacific</th>'
            + ('<th scope="col">Shift</th>' if shift_links else ""))
    return (f'{bar}<div class="table-wrap"><table class="firsts"><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table></div>'
            '<p class="muted small">Score log every 2 minutes: a time is up to 2 minutes after the event. Deaths and '
            'losses: the stream director\'s log.</p>')


def long_charts(lr, lo=None, hi=None, x0=0):
    """Science per minute by pack, technologies and rockets on the save's game clock, shift starts marked; one list
    of Pacific times for the page's hovers."""
    marks = [(x, f"S{n}") for x, n, _ in lr["bounds"]]
    inside = (lambda pts: [(x, y) for x, y in pts if (lo is None or x >= lo) and (hi is None or x <= hi)])
    clock = "page"
    ps = pack_rate_series(lr["spm_packs"], lo, hi)
    opts = dict(x_label="game time (hours)", hours=True, marks=marks, clock=clock, x0=x0)
    charts = []
    if ps:
        charts.append(line_chart("Science packs per minute, by pack", ps, "packs per minute",
                                 desc="10-game-minute windows.", **opts))
    tot = inside(lr["spm"])
    if tot:
        charts.append(line_chart("Science packs per minute, all packs", [{"name": "All packs", "points": tot}],
                                 "packs per minute", desc="10-game-minute windows.", **opts))
    charts.append(line_chart("Technologies researched", [{"name": "Technologies", "points": inside(lr["research"])}],
                             "technologies", step=True, **opts))
    charts.append(line_chart("Rockets launched", [{"name": "Rockets", "points": inside(lr["rockets"])}], "rockets",
                             step=True, **opts))
    times = json.dumps([[x, _pt(t)] for x, t in inside(lr["clock"])]).replace("</", "<\\/")
    return (f'<script type="application/json" id="chart-clock">{times}</script>'
            f'<div class="chart-grid">{"".join(charts)}</div>')


def shift_stats(s):
    return "".join([
        stat("on stream", f'{_hours(s["started"], s["ended"]):.1f} h', _when(s["started"], s["ended"])),
        stat("game time", f'{s["game0"]} to {s["game1"]}'),
        stat("technologies", s["research"], f'+{s["research_new"]}'),
        stat("rockets", s["rockets"], f'+{s["rockets_new"]}'),
        stat("science / min", "–" if s["spm"] is None else fmt_num(s["spm"]), "shift average"),
        stat("packs made", f'{s["made_total"]:,}'),
        stat("deaths / loss alerts", f'{s["deaths"]} / {s["losses"]}'),
        stat("viewer messages", s["viewer_lines"])])


def qa_html(qa):
    items = []
    for q in qa:
        if q["kind"] == "viewer":
            who = f'<span class="chip viewer">{esc(q["who"])}</span>'
        elif q["kind"] == "agent":
            who = agent_chip(q["who"])
        else:
            who = f'<span class="chip host">{esc(q["who"])}</span>'
        items.append(f'<li class="qa-{q["kind"]}"><span class="c-time">{esc(_pt(q["t"], day=False))}</span>{who}'
                     f'<span class="c-text">{esc(q["text"])}</span></li>')
    if len(items) <= 40:
        return f'<ol class="chat qa">{"".join(items)}</ol>'
    # a long transcript: the first 30 lines, the rest one click away
    return (f'<ol class="chat qa">{"".join(items[:30])}</ol><details class="chat-full"><summary>{len(items) - 30} more lines'
            f'</summary><ol class="chat qa" start="31">{"".join(items[30:])}</ol></details>')


def shift_summary(s, firsts):
    """The page's description (search and link previews): the shift's numbers and its biggest firsts."""
    bits = [f"Shift {s['n']}: {_when(s['started'], s['ended'])} Pacific", f"+{s['research_new']} technologies",
            f"+{s['rockets_new']} rockets", f"{s['made_total']:,} science packs"]
    big = [f["label"] for f in firsts if f["kind"] in ("space", "science")][:3]
    return " · ".join(bits) + (". " + ", ".join(big) + "." if big else ".")


def build_shift_page(s, v, lr):
    done = [x for x in lr["shifts"] if not x.get("empty")]
    i = done.index(s)
    prev_l = f'<a href="{shift_href(done[i - 1])}">← Shift {done[i - 1]["n"]}</a>' if i else ""
    next_l = f'<a href="{shift_href(done[i + 1])}">Shift {done[i + 1]["n"]} →</a>' if i + 1 < len(done) else ""
    nav = f'<p class="shift-nav">{prev_l}<a href="/runs/long/">All shifts</a>{next_l}</p>'
    now = ""
    video = ""
    if v:
        watch = f"https://www.youtube.com/watch?v={esc(v['id'])}"
        chapters = "".join(f'<li><a href="{watch}&amp;t={int(c["at"])}s">{esc(c["time"])}</a> {esc(clean(c["title"]))}</li>'
                           for c in v.get("chapters") or [])
        playlist = (f' · <a href="https://www.youtube.com/playlist?list={esc(v["playlist"])}">every shift</a>'
                    if v.get("playlist") else "")
        video = (f'{video_embed(v)}<p class="muted small"><a href="{watch}">Watch on YouTube</a>{playlist}</p>'
                 f'<div class="shift-text">{description_html(v.get("description", ""))}</div>'
                 + (f'<h2>Chapters</h2><ol class="chapters">{chapters}</ol>' if chapters else ""))
    mine = [f for f in lr["firsts"] if f["shift"] == s["n"]]
    packs = "".join(f'<tr><th scope="row">{esc(lab)}</th><td class="num">{s["made"].get(item, 0):,}</td></tr>'
                    for item, lab in longrun.PACKS if s["made"].get(item))
    lo, hi = s["tick0"] / 3600, s["tick1"] / 3600
    who = lambda w: agent(w.lower())["name"] if w.lower() in AGENTS else w  # noqa: E731  (the log's spelling varies)
    deaths = "".join(f'<li><span class="c-time">{esc(_pt(d["t"], day=False))}</span>'
                     f'{agent_chip(d["who"].lower()) if d["who"].lower() in AGENTS else esc(d["who"])}</li>' for d in s["died"])
    by = {}
    for d in s["died"]:
        by[who(d["who"])] = by.get(who(d["who"]), 0) + 1
    calls = "".join(f'<li><span class="c-time">{esc(_pt(c["t"], day=False))}</span><span class="chip host">{esc(c["who"])}</span>'
                    f'<span class="c-text">{esc(c["text"])}</span></li>' for c in s["calls"])
    plat = (f'<p class="muted small">Platforms built: {esc(", ".join(s["platforms_built"]) or "none")} · '
            f'lost: {esc(", ".join(s["platforms_lost"]) or "none")}</p>') if s["platforms_built"] or s["platforms_lost"] else ""
    body = f"""
{live_banner()}
<p class="crumbs"><a href="/runs/long/">The long run</a> / Shift {s["n"]}</p>
<h1>Shift {s["n"]}{now}</h1>
<p class="meta">{esc(_when(s["started"], s["ended"]))} Pacific · game time {esc(s["game0"])} to {esc(s["game1"])}</p>
{nav}
<div class="stats">{shift_stats(s)}</div>
{video}
<h2>Milestones</h2>
{firsts_table(mine, shift_links=False)}
{f'<h2>The hosts\' calls</h2><p class="muted small">Space Age moments, and research, attacks and losses that matter, as the hosts called them. Times Pacific.</p><ol class="chat calls">{calls}</ol>' if calls else ""}
{f'<h2>Technologies researched ({len(s["techs"])})</h2><ol class="techs">' + "".join(f'<li><span class="c-time">{esc(longrun.game_time(t["tick"]))}</span>{esc(t["label"])}</li>' for t in s["techs"]) + '</ol><p class="muted small">Game time of the first score row that shows each one.</p>' if s["techs"] else ""}
{long_charts(lr, lo - 1, hi + 1, x0=max(0, int(lo // 60) * 60))}
<div class="two-col shift-cols">
<section><h2>Packs made</h2>{f'<div class="table-wrap"><table class="packs"><tbody>{packs}</tbody></table></div>' if packs else '<p class="muted">None.</p>'}
{plat}</section>
<section><h2>Deaths</h2>{f'<p class="muted small">{", ".join(f"{esc(k)} {n}" for k, n in sorted(by.items(), key=lambda kv: -kv[1]))}</p><ol class="deaths">{deaths}</ol>' if deaths else '<p class="muted">None.</p>'}</section>
</div>
{f'<h2>Viewers</h2><p class="muted small">Viewer messages that reached the game, the agents\' answers that name the viewer, and the hosts\' answers. Times Pacific.</p>{qa_html(s["qa"])}' if s["qa"] else ""}
{nav}
"""
    return page(f"Shift {s['n']}", body, "/runs/" if archive() else "/runs/long/",
                shift_summary(s, mine), path=shift_href(s))


def _when(a, b):
    """'Oct 11, 02:52 to 04:53' from two local ISO times (scores.jsonl's `t`)."""
    try:
        x, y = datetime.datetime.fromisoformat(a), datetime.datetime.fromisoformat(b)
    except (TypeError, ValueError):
        return "–"
    end = y.strftime("%H:%M") if y.date() == x.date() else y.strftime("%b %-d, %H:%M")
    return f"{x.strftime('%b %-d, %H:%M')} to {end}"


def long_run_row(lr):
    """The long run's entry in the Runs list."""
    done = [s for s in lr["shifts"] if not s.get("empty")]
    last = done[-1]
    return (f'<a class="run-row featured" href="/runs/long/"><div><h2>The long run</h2><p class="muted">One world in '
            f'{len(done)} shifts so far, {esc(_when(done[0]["started"], last["ended"]))}</p></div>'
            f'<p class="run-final">{last["research"]} techs, {last["rockets"]} rockets by {esc(last["game1"])}</p></a>')


def platforms_table(plats):
    if not plats:
        return ""
    rows = "".join(
        f'<tr><th scope="row">{esc(p["name"])}</th>'
        f'<td data-l="Built">{esc(_pt(p["built"]))} <span class="muted">({esc(longrun.game_time(p["built_tick"]))}, '
        f'<a href="/runs/long/shift-{p["built_shift"]}/">shift {p["built_shift"]}</a>)</span></td>'
        f'<td data-l="Stopped at">{esc(", ".join(x.capitalize() for x in p["places"]) or "–")}</td>'
        f'<td data-l="Lost">' + (f'{esc(_pt(p["lost"]))} <span class="muted">({esc(longrun.game_time(p["lost_tick"]))}, '
                                 f'<a href="/runs/long/shift-{p["lost_shift"]}/">shift {p["lost_shift"]}</a>)</span>'
                                 if p["lost"] else f'active{", at " + esc(p["at"].capitalize()) if p["at"] else ""}') + '</td></tr>'
        for p in plats)
    return (f'<h2 id="platforms">Space platforms</h2><div class="table-wrap"><table class="long-run platforms"><thead><tr>'
            f'<th scope="col">Platform</th><th scope="col">Built (Pacific)</th><th scope="col">Stopped at</th>'
            f'<th scope="col">Lost</th></tr></thead><tbody>{rows}</tbody></table></div>'
            f'<p class="muted small">From the score log every 2 minutes. Lost: gone from the game\'s platform list.</p>')


def live_banner():
    """Shown by site.js only while the live API has a fresh state (the pages are built at shift changes)."""
    api = CONFIG.get("live_api_url") or ""
    return (f'<p class="live-banner" data-api="{esc(api)}" hidden><span class="fx-chip fx-chip--red">Live</span> '
            f'A shift is on now. <a href="/">Watch</a></p>') if api else ""


# the firsts worth a headline: (key, label); a "planet:" key takes the first planet reached
KEY_TIMES = [("pack:chemical-science-pack", "Blue science"), ("tech:rocket-silo", "Rocket silo"),
             ("rockets:1", "First rocket"), ("pack:space-science-pack", "Space science"), ("planet:", "First planet"),
             ("rockets:100", "100 rockets"), ("pack:promethium-science-pack", "Promethium science")]


def key_times(lr):
    """The big firsts with game time, hours on stream to get there (the shifts' own time, breaks left out) and the
    Pacific time."""
    done = [s for s in lr["shifts"] if not s.get("empty")]
    tiles = []
    for key, lab in KEY_TIMES:
        f = next((f for f in lr["firsts"] if f["key"] == key or (key.endswith(":") and f["key"].startswith(key))), None)
        if not f:
            continue
        before = sum(_hours(s["started"], s["ended"]) for s in done if s["n"] < f["shift"])
        cur = next((s for s in done if s["n"] == f["shift"]), None)
        on_air = before + (_hours(cur["started"], f["t"]) if cur else 0)
        name = lab if key != "planet:" else f["label"].replace(" reached", "")
        tiles.append(f'<a class="keytime" href="/runs/long/shift-{f["shift"]}/"><span class="k-label">{esc(name)}</span>'
                     f'<span class="k-val">{esc(longrun.game_time(f["tick"]))}</span>'
                     f'<span class="k-sub">game time · {on_air:.1f} h on stream · {esc(_pt(f["t"]))}</span></a>')
    return (f'<h2 id="key-times">Key times</h2><div class="keytimes">{"".join(tiles)}</div>') if tiles else ""


def records(done):
    """Bests over the shifts (a shift still on counts with what it has so far)."""
    def best(key, fmt, low=False):
        have = [s for s in done if s.get(key) is not None]
        if not have:
            return None
        s = (min if low else max)(have, key=lambda x: x[key])
        return fmt(s[key]), s
    out = []
    for lab, key, fmt, low in [("Most rockets in a shift", "rockets_new", str, False),
                               ("Most technologies in a shift", "research_new", str, False),
                               ("Best science / min (shift average)", "spm", fmt_num, False),
                               ("Most packs made in a shift", "made_total", lambda v: f"{v:,}", False),
                               ("Most viewer messages in a shift", "viewer_lines", str, False),
                               ("Fewest deaths in a shift", "deaths", str, True)]:
        b = best(key, fmt, low)
        if b and (low or b[1][key]):
            out.append(f'<a class="record" href="{shift_href(b[1])}"><span class="r-val">{esc(b[0])}</span>'
                       f'<span class="r-label">{esc(lab)}</span><span class="r-shift">Shift {b[1]["n"]}</span></a>')
    return f'<div class="records">{"".join(out)}</div>' if out else ""


def build_long_run(lr):
    shifts = lr["shifts"]
    done = [s for s in shifts if not s.get("empty")]
    first, last = done[0], done[-1]
    planets = sorted({p for s in done for p in s["planets"] if p != "nauvis"})
    active = [p for p in lr["platforms"] if not p["lost"]]
    lost_p = [p for p in lr["platforms"] if p["lost"]]
    on_air = sum(_hours(s["started"], s["ended"]) for s in done)
    stats = "".join([stat("shift" if len(done) == 1 else "shifts", len(done)),
                     stat("on stream", f"{on_air:.0f} h"),
                     stat("game time", last["game1"]),
                     stat("technologies", last["research"]),
                     stat("rockets", last["rockets"]),
                     stat("science packs", f'{sum(lr["made"].values()):,}'),
                     stat("platforms", f'{len(lr["platforms"])} built', f'{len(lost_p)} lost · {len(active)} active'
                          + (f' ({", ".join(p["name"] for p in active)})' if active else "")),
                     stat("planets reached", len(planets), ", ".join(p.capitalize() for p in planets)),
                     stat("agent deaths", sum(s["deaths"] for s in done)),
                     stat("viewer messages", sum(s["viewer_lines"] for s in done))])
    rows = []
    # Run ids (shakeN) name the test history; without the archive the shift number is enough.
    ids = archive()
    by_shift = {}
    for f in lr["firsts"]:
        by_shift.setdefault(f["shift"], []).append(f)
    for s in shifts:
        rid = f'<span class="muted small">{esc(s["id"])}</span>' if ids else ""
        if s.get("empty"):
            note = s["note"]
            if ids and s.get("resumed_as"):
                note = note.rstrip(")") + f'; resumed as {s["resumed_as"]})'
            rows.append(f'<tr class="empty"><th scope="row">–{rid}</th>'
                        f'<td data-l="When">{esc(_when(s["started"], s["ended"]))}</td><td colspan="8" class="muted">{esc(note)}</td></tr>')
            continue
        firsts = by_shift.get(s["n"], [])
        notable = [f for f in firsts if f["kind"] != "research" or f["key"].startswith("tech:planet") or f["key"] in
                   ("tech:rocket-silo", "tech:space-science-pack", "tech:oil-processing")]
        ms = "".join(f"<li>{esc(f['label'])}</li>" for f in notable[:5])
        more = f'<li class="muted"><a href="{shift_href(s)}">+{len(firsts) - len(notable[:5])} more</a></li>' if len(firsts) > len(notable[:5]) else ""
        video = ' <span class="fx-chip">video</span>' if shift_video(s) else ""
        now = ""
        rows.append(
            f'<tr><th scope="row"><a href="{shift_href(s)}">Shift {s["n"]}</a>{rid}{now}{video}</th>'
            f'<td data-l="When">{esc(_when(s["started"], s["ended"]))}</td>'
            f'<td data-l="Game time">{esc(s["game0"])} to {esc(s["game1"])}</td>'
            f'<td data-l="Technologies" class="num">{s["research"]} <span class="muted">+{s["research_new"]}</span></td>'
            f'<td data-l="Science / min" class="num">{"–" if s["spm"] is None else fmt_num(s["spm"])}</td>'
            f'<td data-l="Packs made" class="num">{s["made_total"]:,}</td>'
            f'<td data-l="Rockets" class="num">{s["rockets"]} <span class="muted">+{s["rockets_new"]}</span></td>'
            f'<td data-l="Deaths / losses" class="num">{s["deaths"]} / {s["losses"]}</td>'
            f'<td data-l="Viewers" class="num">{s["viewer_lines"]}</td>'
            f'<td data-l="Milestones">{f"<ul class=moments>{ms}{more}</ul>" if ms or more else ""}</td></tr>')
    crumbs = '<p class="crumbs"><a href="/runs/">Runs</a> / The long run</p>' if archive() else ""
    vids = [(s, shift_video(s)) for s in shifts if shift_video(s)]
    videos = "".join(
        f'<article class="shift-video"><h3><a href="{shift_href(s)}">Shift {s["n"]}</a></h3>{video_embed(v)}'
        f'<p class="muted small">{esc(clean(v.get("title", "")))}</p></article>' for s, v in vids)
    videos = f'<h2 id="videos">Shift videos</h2><div class="shift-videos">{videos}</div>' if vids else ""
    body = f"""
{crumbs}
{live_banner()}
<h1>The long run</h1>
<p class="meta">One save · started {esc(_pt(first["started"]))} Pacific · game clock paused between shifts</p>
<nav class="jump" aria-label="On this page"><a href="#key-times">Key times</a><a href="#records">Records</a><a href="#milestones">Milestones</a>{'<a href="#platforms">Platforms</a>' if lr["platforms"] else ""}<a href="#charts">Charts</a><a href="#shifts">Shifts</a>{'<a href="#videos">Videos</a>' if vids else ""}</nav>
<div class="stats stats-compact">{stats}</div>
{key_times(lr)}
<h2 id="records">Records</h2>
{records(done)}
<h2 id="milestones">Milestones</h2>
{firsts_table(lr["firsts"], filters=True)}
{platforms_table(lr["platforms"])}
<h2 id="charts">Charts</h2>
<p class="muted small">Game time on the x axis; S1, S2 ...: shift starts. Hover for the Pacific time.</p>
{long_charts(lr)}
<h2 id="shifts">Shifts</h2>
<div class="table-wrap"><table class="long-run wide"><thead><tr><th scope="col">Shift</th><th scope="col">When (Pacific)</th>
<th scope="col">Game time</th><th scope="col">Technologies</th><th scope="col">Science / min</th><th scope="col">Packs made</th>
<th scope="col">Rockets</th><th scope="col">Deaths / losses</th><th scope="col">Viewers</th><th scope="col">Milestones</th>
</tr></thead><tbody>{"".join(rows)}</tbody></table></div>
<p class="muted small">Science / min: packs made over the shift's game time. Packs made: each counter's rises between score rows; a fall (a lost platform's counts) is not subtracted. Deaths and loss alerts: the ones the stream's director cut to.</p>
{videos}
"""
    return page("The long run", body, "/runs/" if archive() else "/runs/long/",
                "One world over many shifts: milestones, records, charts and every shift.", path="/runs/long/")


def build_runs_index(runs, all_worlds):
    body = ['<h1>Runs</h1><p class="lede">Every recorded session, newest first. Each run page has the milestone timeline, charts from the score log, and a card per agent.</p><div class="run-list">']
    if LONG:
        body.append(long_run_row(LONG))
    for rid in reversed(list(runs)):
        run = runs[rid]
        pw = run_players_worlds(run, all_worlds[rid])
        chips = "".join(agent_chip(p["agent"]) for p in run["players"])
        finals = []
        for key, snaps in pw:
            if snaps:
                f = run_final(snaps)
                who = "" if key == "team" else agent(key)["name"] + ": "
                finals.append(f'{who}{f["techs"]} techs by {f["game"]}')
        body.append(f'<a class="run-row" href="/runs/{rid}/"><div><h2>{esc(run["title"])}</h2><p class="muted">{esc(run["subtitle"])} · {esc(run["mode"])} · enemies {esc(run["enemies"])}</p>'
                    f'<p class="chips">{chips}</p></div><p class="run-final">{"<br>".join(esc(x) for x in finals)}</p></a>')
    body.append("</div>")
    return page("Runs", "\n".join(body), "/runs/")


def comparison_chart(runs, all_worlds):
    series = []
    for rid, label in [("baseline1", "Astra, real time"), ("turns1", "Astra, turn mode"), ("turns3h", "Astra, turns 3h"),
                       ("coop1", "Astra + Opus"), ("shake1", "Nine agents")]:
        run = runs[rid]
        w = run["players"][0]["world"] if run["kind"] == "versus" else run["world"]
        series.append({"name": label, "points": research_series(all_worlds[rid].get(w, []))})
    return line_chart("Technologies researched vs game time, across runs", series, "technologies", step=True,
                      desc="One line per run. Solo runs show Astra's world. Turn mode pauses while the agent thinks.")


def build_experiments(runs, all_worlds):
    body = ['<h1>Experiments</h1>',
            '<p class="lede">What we tried, in order, and what each round taught us. All runs so far use the same map: seed 20261010, base game, Factorio 2.0.77.</p>']
    body.append(comparison_chart(runs, all_worlds))
    # milestone comparison
    cols = [("baseline1", "astra", "Astra, real time"), ("turns1", "astra", "Astra, turns"), ("turns3h", "astra", "Astra, turns 3h"),
            ("baseline1", "fable", "Fable, real time"), ("turns1", "fable", "Fable, turns"), ("turns3h", "fable", "Fable, turns 3h"),
            ("coop1", "team", "Co-op"), ("shake1", "team", "Nine agents")]
    head = "".join(f'<th scope="col">{esc(l)}</th>' for _, _, l in cols)
    rows = []
    for m in CONTENT["milestones"]:
        cells = "".join(f'<td>{esc(runs[r]["milestones"].get(k, {}).get(m["id"], "–"))}</td>' for r, k, _ in cols)
        rows.append(f'<tr><th scope="row">{esc(m["label"])}</th>{cells}</tr>')
    body.append('<h2>Milestones at a glance</h2><p class="muted">Game time to each milestone. Turn mode pauses the game while the agent thinks, so its times are not comparable one-to-one with real time.</p>'
                f'<div class="table-wrap"><table class="milestones wide"><thead><tr><th>Milestone</th>{head}</tr></thead><tbody>{"".join(rows)}</tbody></table></div>')

    for n, e in enumerate(CONTENT["experiments"], 1):
        run_links = " ".join(f'<a class="fx-btn small" href="/runs/{r}/">{esc(runs[r]["title"])} →</a>' for r in e["runs"])
        lessons = "".join(f"<li>{esc(l)}</li>" for l in e["lessons"])
        study = "".join(f' <a class="fx-btn small" href="/studies/{sid}/">{esc(st.get("short", "Study"))} →</a>'
                        for sid, st in CONTENT["studies"].items() if st["run"] in e["runs"])
        # a small chart per experiment
        ser = []
        for r in e["runs"]:
            run = runs[r]
            for key, snaps in run_players_worlds(run, all_worlds[r]):
                nm = ("Team" if key == "team" else agent(key)["name"]) + (f" ({run['title']})" if len(e["runs"]) > 1 else "")
                ser.append({"name": nm, "points": total_packs(snaps)})
        chart = line_chart("Science packs produced", ser, "packs")
        body.append(f'<article class="experiment" id="{e["id"]}"><p class="exp-num">Experiment {n} · {esc(e["date"])}</p><h2>{esc(e["title"])}</h2>'
                    f'<div class="exp-grid"><div><h3>Question</h3><p>{esc(e["question"])}</p><h3>Setup</h3><p>{esc(e["setup"])}</p>'
                    f'<h3>Result</h3><p>{esc(e["result"])}</p><h3>What we learned</h3><ul>{lessons}</ul><p class="actions">{run_links}{study}</p></div>'
                    f'<div>{chart}</div></div></article>')
    changes = "".join(f"<li>{esc(c)}</li>" for c in CONTENT["harness_changes"])
    body.append(f'<article class="experiment" id="harness"><p class="exp-num">Between rounds</p><h2>Harness changes</h2>'
                f'<p>After each round a separate engineer agent read the players\' notes, fixed what they reported, and tested the fixes on a disposable world. What changed:</p><ul>{changes}</ul></article>')
    return page("Experiments", "\n".join(body), "/experiments/", "The experiments log: baseline, turn mode, co-op and the nine-agent shakedown.")


def build_home(runs, all_worlds):
    """The homepage is the live show (Nick: "just drop people right into it"), then a compact way into the rest."""
    cards = [("/about/", "About the project", "Nine models from five labs share one Factorio factory, by the same rules as a "
              "player. How it works, the fair-play rules, the team.")]
    if archive():
        sf = run_final(all_worlds["shake1"]["n"])
        cards += [("/experiments/", "Experiments", "What each run tested and what it found."),
                  ("/runs/", "Runs", f"Every run with its charts and chat; the latest, {runs['shake1']['title']}, reached "
                   f"{sf['techs']} technologies by {sf['game']}."),
                  ("/studies/", "Studies", "Write-ups of the runs: what went wrong, what changed.")]
    if LONG:
        done = [s for s in LONG["shifts"] if not s.get("empty")]
        last = done[-1]
        latest = LONG["firsts"][-1] if LONG["firsts"] else None
        cards.insert(1, ("/runs/long/", "The long run",
                         f"{len(done)} shifts · {last['game1']} game time · {last['research']} technologies · "
                         f"{last['rockets']} rockets" + (f". Latest milestone: {latest['label']}, shift {latest['shift']}." if latest else ".")))
        cards.insert(2, (shift_href(last), f"Latest shift: {last['n']}",
                         f"{_when(last['started'], last['ended'])} · +{last['research_new']} technologies · "
                         f"+{last['rockets_new']} rockets · {last['viewer_lines']} viewer messages"))
    links = "".join(f'<a class="home-card" href="{href}"><h3>{esc(t)}</h3><p class="muted">{esc(d)}</p></a>'
                    for href, t, d in cards)
    body = live_app(CONFIG.get("site_title", "Player of Games"), "/?demo=1") + f"""
<section class="home-more" aria-labelledby="more-h">
  <h2 id="more-h">The project</h2>
  <p class="lede">AI agents playing Factorio together, by the same rules as you: no spawned items, no teleporting,
  walking and building at a player's speed, talking in game chat. Shifts run through the night on one world.</p>
  <div class="home-cards">{links}</div>
</section>
"""
    return page(CONFIG.get("site_title", "Factorio AI Party"), body, "/", CONFIG.get("description", ""), extra_head=LIVE_HEAD, path="/")


def build_about(runs, all_worlds):
    """What the show is, how it works, the rules, the team, how to talk to the agents. With the archive it also has
    the test history (results, the latest run, links to the experiments); without it, present tense only."""
    arch = archive()
    team = []
    for k in CONTENT["team_order"]:
        a = agent(k)
        name = f'<a href="/agents/{k}/"><strong>{esc(a["name"])}</strong></a>' if arch else f'<strong>{esc(a["name"])}</strong>'
        team.append(f'<li class="team-member" style="--ac:{a["color"]}">{avatar(k, "lg")}<div>{name}'
                    f'<span>{esc(a["model"])}</span><span class="muted">{esc(a["harness"])}</span></div></li>')
    if arch:
        fable = agent("fable")
        sf = run_final(all_worlds["shake1"]["n"])
        cf = run_final(all_worlds["coop1"]["c"])
        hero = f"""
  <p class="eyebrow">An open experiment</p>
  <h1>AI agents playing Factorio together, by the same rules as you.</h1>
  <p class="lede">Nine models from five labs share one factory. They can't spawn items, teleport or see the
  unexplored map. They walk, mine, craft and build at the speed a person would, talk to each other in game chat,
  and work up the Space Age tree toward the Shattered Planet. The runs are streamed.</p>
  <p class="actions"><a class="fx-btn" href="/experiments/">See the experiments →</a> <a class="fx-btn ghost" href="/">Live stream</a></p>
  <div class="stats hero-stats">
    {stat("runs so far", len(runs))}
    {stat("technologies in co-op", cf["techs"], "Astra + Opus, 2 hours")}
    {stat("agents in one world", 9, "shakedown, enemies on")}
    {stat("chat messages", "365", "in the nine-agent hour")}
  </div>"""
        step1 = """with the same instructions: play until the deadline,
      keep notes, write a final summary."""
        clocks = """<p class="muted">Two clocks are in play. In <strong>real time</strong> the game runs while the agent thinks, so slow thinking costs
  game time. In <strong>turn mode</strong> the game pauses whenever the character has nothing in progress, so game time measures
  decisions, not latency.</p>"""
        team_note = """Names and colours are the ones each agent chose for itself in the shakedown. The pixel portraits
  come from the stream's avatar renderer, which draws a default from each name and colour; agents can now design
  their own in game, and these will change when they do."""
        team_extra = (f'<p class="muted small">Earlier solo and versus runs also used <a href="/agents/fable/">{esc(fable["model"])}</a> '
                      f'({esc(fable["harness"])}).</p>')
        history = f"""
<section>
  <h2>Results so far</h2>
  <p class="muted">Five runs on the same map, 10 October 2026. Turn mode reached every early milestone sooner in game
  time; the two-agent co-op researched the most, {cf["techs"]} technologies in two hours.
  <a href="/experiments/">The experiments log</a> has the details.</p>
  {comparison_chart(runs, all_worlds)}
</section>

<section>
  <h2>Latest</h2>
  <a class="run-row" href="/runs/shake1/"><div><h3>{esc(runs["shake1"]["title"])}: {esc(runs["shake1"]["subtitle"])}</h3>
  <p class="muted">{esc(runs["shake1"]["summary"])}</p></div><p class="run-final">{sf["techs"]} techs by {sf["game"]}</p></a>
</section>
"""
    else:
        run_btn = ' <a class="fx-btn ghost" href="/runs/long/">The run so far</a>' if LONG else ""
        hero = f"""
  <p class="eyebrow">Live on stream</p>
  <h1>AI agents playing Factorio together, by the same rules as you.</h1>
  <p class="lede">Nine models from five labs share one factory in Factorio: Space Age. They can't spawn items,
  teleport or see the unexplored map. They walk, mine, craft and build at the speed a person would, and talk to each
  other in game chat. The goal is the far end of the Space Age tree, the Shattered Planet; the agents set their own
  milestones on the way.</p>
  <p class="actions"><a class="fx-btn" href="/">Watch live →</a>{run_btn}</p>"""
        step1 = """with the same instructions apart from name and
      model. Each shift they pick up where the last one stopped, from their own notes and the team's board."""
        clocks = """<p class="muted">The game runs in <strong>real time</strong> while the agents think, so slow thinking costs game time.
  It plays in shifts of about four hours, and the game is paused between shifts.</p>"""
        team_note = """Each agent chose its own name and colour. The pixel portraits come from the stream's avatar
  renderer, and change when an agent designs its own in game."""
        team_extra = ""
        history = ""
    body = f"""
<section class="hero">{hero}
</section>

<section>
  <h2>How it works</h2>
  <div class="flow" role="list">
    <div class="flow-step" role="listitem"><span class="flow-n">1</span><h3>The agents</h3><p>Each model runs in its own coding harness
      (Codex, Claude Code, Grok Build, Antigravity, Muse Code) {step1}</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">2</span><h3>The harness</h3><p>Agents act through one command-line tool,
      <code>fh</code>, with more than 70 actions: look, walk, mine, craft, build, queue a plan, chat. Long plans run inside
      the game, so the model stays out of the low-level loop.</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">3</span><h3>The game</h3><p>A Factorio 2.0.77 server with Space Age,
      Quality and Elevated Rails, and a small mod that carries out each action tick by tick, under survival rules, and
      refuses anything a player couldn't do.</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">4</span><h3>The stream</h3><p>Director cameras follow whoever is most
      interesting. An overlay shows each agent's name, colour, current action and the team chat.</p></div>
  </div>
  {clocks}
</section>

<section class="fair">
  <h2>Fair-play rules</h2>
  <div class="two-col">
    <div>
      <h3>Allowed</h3>
      <ul class="ticks">
        <li>Walking at character speed</li>
        <li>Mining and crafting at real speed, with a real inventory</li>
        <li>Placing, inserting and taking within reach</li>
        <li>Setting the research queue</li>
        <li>Importing blueprint strings</li>
        <li>Construction robots, once researched</li>
        <li>Writing their own scripts on top of the honest actions</li>
      </ul>
    </div>
    <div>
      <h3>Not allowed</h3>
      <ul class="crosses">
        <li>Creating items or buildings from nothing</li>
        <li>Teleporting</li>
        <li>Seeing map areas nobody has explored</li>
        <li>Changing the game speed of the live world</li>
        <li>Console commands, Lua, or talking to the server directly</li>
        <li>Modifying the harness or the mod</li>
      </ul>
    </div>
  </div>
  <p class="muted">The rules are enforced in the mod and audited from the logs. When a harness bug blocks something
  a player could do, the operator steps in and says so in chat; every intervention is logged.</p>
</section>

<section>
  <h2 id="team">The team</h2>
  <p class="muted">{team_note}</p>
  <ul class="team">{"".join(team)}</ul>
  {team_extra}
</section>

<section>
  <h2 id="talk">Talk to the agents</h2>
  <p>Write in the YouTube chat or the site chat on the <a href="/">live page</a>. Messages pass a moderation filter,
  then show on the stream and reach the agents in the game chat, marked as from a viewer. Put <code>@</code> before an
  agent's name to get its attention; other messages wait until the agents next read their chat. They may answer
  briefly and keep playing, and they can vote to mute a viewer. The site chat needs no account: pick any name, no
  links.</p>
</section>
{history}"""
    return page("About", body, "/about/", CONFIG.get("description", ""), path="/about/")


def build_agent_page(key, runs, all_worlds, chats):
    a = agent(key)
    rows = []
    motto = None
    for rid, run in runs.items():
        p = next((p for p in run["players"] if p["agent"] == key), None)
        if not p:
            continue
        ident = (run.get("identities") or {}).get(key, {})
        motto = ident.get("motto") or motto
        if run["kind"] == "versus":
            snaps = all_worlds[rid].get(p["world"], [])
            mates = "alone in its own world"
        else:
            snaps = all_worlds[rid].get(run["world"], [])
            others = [agent(q["agent"])["name"] for q in run["players"] if q["agent"] != key]
            mates = f"with {len(others)} other agents" if len(others) > 2 else "with " + " and ".join(others)
        f = run_final(snaps) if snaps else None
        outcome = f'{f["techs"]} technologies by {f["game"]}' + (" (team)" if run["kind"] == "team" else "") if f else ""
        st = (run.get("stats") or {}).get(key)
        dl = "".join(f"<div><dt>{esc(n)}</dt><dd>{esc(v)}</dd></div>" for n, v in (st or {}).items())
        mine = [c for c in chats.get(rid, []) if c["from"] == key]
        notable = set(run.get("notable_chat", []))
        quotes = [c for c in mine if c["seq"] in notable]
        if mine and mine[0] not in quotes:
            quotes.insert(0, mine[0])
        q = "".join(f'<li><span class="q-time">{esc(game_time(c["tick"]))}</span> {esc(c["text"])}</li>' for c in quotes[:5])
        rows.append(f'<article class="agent-run"><h2><a href="/runs/{rid}/">{esc(run["title"])}</a><span class="h-sub">{esc(run["date"])} · {esc(run["mode"])}, {esc(mates)}</span></h2>'
                    f'<p class="role">{esc(p["role"])}</p>{f"<p>{esc(outcome)}</p>" if outcome else ""}'
                    f'{f"<dl class=kv>{dl}</dl>" if dl else ""}'
                    f'{f"<p class={chr(34)}muted small{chr(34)}>{len(mine)} chat messages</p>" if mine else ""}'
                    f'{f"<ul class=quotes>{q}</ul>" if q else ""}</article>')
    head = (f'<p class="crumbs"><a href="/about/">About</a> / <a href="/about/#team">The team</a></p>'
            f'<div class="agent-head" style="--ac:{a["color"]}">{avatar(key, "xl")}<div><h1>{esc(a["name"])}</h1>'
            f'<p class="model">{esc(a["model"])} · {esc(a["harness"])}</p>'
            f'{f"<p class=motto>“{esc(motto)}”</p>" if motto else ""}</div></div>')
    # active=None: agent pages belong to no nav section, so nothing is highlighted
    return page(a["name"], head + '<div class="agent-runs" style="--ac:' + a["color"] + '">' + "".join(rows) + "</div>", None,
                f'{a["name"]} ({a["model"]}) in Player of Games.')


def build_studies_index():
    items = []
    for sid, st in CONTENT["studies"].items():
        summary = f'<p>{esc(st["summary"])}</p>' if st.get("summary") else ""
        items.append(f'<a class="run-row" href="/studies/{sid}/"><div><h2>{esc(st["title"])}</h2><p class="muted">{esc(st["date"])} · '
                     f'from <span>{esc(CONTENT["runs"][st["run"]]["title"])}</span></p>{summary}</div></a>')
    body = '<h1>Studies</h1><p class="lede">Close readings of individual runs: who did what, how the team talked, and what to change next.</p><div class="run-list">' + "".join(items) + "</div>"
    return page("Studies", body, "/studies/")


def build_study(sid, st):
    src = (REPO / st["file"]).read_text()
    # drop the first H1; we render our own title
    src = re.sub(r"\A# .*\n", "", src)
    # Per-study rewrites from site.json (personal setup details the site must not repeat). Each must still match,
    # so an edit to the study that moves the text fails the build instead of leaking it.
    for pattern, repl in st.get("rewrite", []):
        src, n = re.subn(pattern, repl, src, flags=re.M)
        if not n:
            raise SystemExit(f"study {sid}: rewrite pattern no longer matches: {pattern}")
    html_body = markdown(src, heading_shift=0)
    toc = "".join(f'<li><a href="#{m.group(1)}">{m.group(2)}</a></li>'
                  for m in re.finditer(r'<h2 id="([^"]+)">(.*?)</h2>', html_body))
    body = (f'<p class="crumbs"><a href="/studies/">Studies</a> / <a href="/runs/{st["run"]}/">{esc(CONTENT["runs"][st["run"]]["title"])}</a></p>'
            f'<h1>{esc(st["title"])}</h1>'
            f'<div class="study-layout"><nav class="toc" aria-label="Contents"><p>Contents</p><ol>{toc}</ol></nav>'
            f'<article class="prose">{html_body}</article></div>')
    return page(st["title"], body, "/studies/")


def public_status(st):
    """status.json for dist/. Without the archive the last run is shown only when it is a shift of the run (from
    run_start on), and without its id."""
    if not archive() and st.get("last_run"):
        shifts = {s["id"] for s in (LONG or {}).get("shifts", [])}
        lr = st["last_run"]
        st = dict(st, last_run={k: v for k, v in lr.items() if k != "id"} if lr.get("id") in shifts else None)
    return json.dumps(st, indent=2, ensure_ascii=False) + "\n"


LIVE_HEAD = '<script src="/static/avatar.js" defer></script>\n<script src="/static/live.js" defer></script>'


def live_app(heading, sample_href):
    """The live show: player, chat, status strip and dashboard (static/live.js fills it from the live API). The
    homepage and /live/ both use it."""
    vid = CONFIG.get("youtube_video_id") or ""
    chan = CONFIG.get("youtube_channel_id") or ""
    api = CONFIG.get("live_api_url") or ""
    status = CONFIG.get("live_status_url", "/live/status.json")
    poll = int(CONFIG.get("live_poll_seconds", 10))
    return f"""
<div id="live-app" class="live-app" data-api="{esc(api)}" data-status="{esc(status)}" data-poll="{poll}" data-video="{esc(vid)}" data-channel="{esc(chan)}">
<div class="live-head-row">
  <h1>{esc(heading)}</h1>
  <p class="live-head-meta"><span id="live-badge" class="fx-chip fx-chip--grey">Offline</span> <span id="updated" class="muted small"></span></p>
</div>
<div class="live-top">
  <div class="player-wrap" id="player">
    <div class="player-placeholder">
      <span class="ph-dot" aria-hidden="true"></span>
      <p><strong>Not live right now.</strong></p>
      <p class="muted">The player appears here when the next shift starts. Below: the last state of the factory.</p>
    </div>
  </div>
  <aside class="chat-panel live-panel fx-root fx-panel" aria-label="Chat">
    <div class="fx-tabs chat-tabs" role="tablist">
      <button class="fx-tab is-selected" role="tab" aria-selected="true" data-tab="site" type="button">Site chat</button>
      <button class="fx-tab" role="tab" aria-selected="false" data-tab="yt" type="button">YouTube chat</button>
    </div>
    <div class="fx-tab-body">
      <div data-pane="site" class="vchat-pane">
        <ol id="vchat" class="vchat" aria-live="polite"></ol>
        <form id="vchat-form" class="vchat-form" autocomplete="off">
          <input class="fx-textfield" name="name" maxlength="20" placeholder="Name" aria-label="Your name">
          <input class="fx-textfield" name="text" maxlength="200" placeholder="Say something" aria-label="Message" required>
          <button class="fx-btn" type="submit">Send</button>
        </form>
        <p id="vchat-note" class="fx-muted small" aria-live="polite"></p>
        <p class="fx-muted small">No accounts: pick any name. No links; one message every few seconds. Be kind, the agents may read it.</p>
      </div>
      <div data-pane="yt" class="yt-pane" hidden>
        <p class="fx-muted">YouTube chat appears here once the stream is set up.</p>
      </div>
    </div>
  </aside>
</div>
<section class="live-run-head"><h2 id="run-title">Waiting for the next run</h2><p id="run-sub" class="muted"></p>
<p id="next-shift" class="live-next" hidden></p></section>
<div id="offline" class="live-offline"></div>
<div id="strip" class="live-strip fx-root fx-panel live-panel"></div>
<ul id="alerts" class="live-alerts"></ul>
<div id="dash" class="live-dash"></div>
<p class="muted small">The dashboard refreshes every {poll} seconds from the stream service on the game host.
<a href="{sample_href}">Sample view</a>.</p>
</div>
"""


def build_live():
    return page("Live", live_app("Live", "/live/?demo=1"), "/", "Watch the run: stream, chat and the team's live status.",
                extra_head=LIVE_HEAD, path="/live/")


FAVICON = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#e39827"/>
<path d="M16 7l2.2 3.1 3.7-.9.4 3.8 3.5 1.5-1.9 3.3 1.9 3.3-3.5 1.5-.4 3.8-3.7-.9L16 28l-2.2-3.1-3.7.9-.4-3.8-3.5-1.5L8.1 17.2 6.2 13.9l3.5-1.5.4-3.8 3.7.9z" fill="#1d1a16"/>
<circle cx="16" cy="17.5" r="4" fill="#e39827"/></svg>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(SITE / "dist"))
    ap.add_argument("--runs-dir", default=str(REPO / "runs"),
                    help="where the long run's shift folders are (default: the repo's runs/; read-only)")
    ap.add_argument("--content", default=os.environ.get("POG_SITE_CONTENT"),
                    help="another site.json (tests: the archive switch and run_start; default $POG_SITE_CONTENT)")
    ap.add_argument("--videos", default=str(SITE / "content" / "videos.json"),
                    help="the shifts' YouTube videos (tools/yt_upload.py writes it; missing: no videos)")
    args = ap.parse_args()
    if args.content:
        global CONTENT, AGENTS
        CONTENT = json.loads(Path(args.content).read_text())
        AGENTS = CONTENT["agents"]
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    runs = CONTENT["runs"]
    all_worlds = {rid: load_scores(r) for rid, r in runs.items()}
    global LONG
    # None without a chain of shifts (or without run_start's folder): no page, no links to it
    LONG = longrun.load(args.runs_dir, clean, start=CONTENT.get("run_start"), keep=keep_line, agents=list(AGENTS))
    if CONTENT.get("run_start") and not LONG:
        print(f"note: run_start {CONTENT['run_start']} not found in {args.runs_dir}: no run page", file=sys.stderr)

    def write(rel, text):
        p = out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    write("index.html", build_home(runs, all_worlds))
    if LONG:
        global VIDEOS
        VIDEOS = load_videos(args.videos)
        write("runs/long/index.html", build_long_run(LONG))
        for s in LONG["shifts"]:
            if not s.get("empty"):
                write(f"runs/long/shift-{s['n']}/index.html", build_shift_page(s, shift_video(s), LONG))
    write("about/index.html", build_about(runs, all_worlds))
    if archive():  # the test history: experiments, earlier runs, agent pages (made of those runs), studies
        write("experiments/index.html", build_experiments(runs, all_worlds))
        write("runs/index.html", build_runs_index(runs, all_worlds))
        chats = {rid: load_chat(run) for rid, run in runs.items()}
        for rid, run in runs.items():
            write(f"runs/{rid}/index.html", build_run_page(rid, run, all_worlds[rid], chats[rid]))
        for key in AGENTS:
            write(f"agents/{key}/index.html", build_agent_page(key, runs, all_worlds, chats))
        write("studies/index.html", build_studies_index())
        for sid, st in CONTENT["studies"].items():
            write(f"studies/{sid}/index.html", build_study(sid, st))
    write("live/index.html", build_live())
    shutil.copy(SITE / "live" / "state.example.json", out / "live" / "state.example.json")
    write("live/status.json", public_status(json.loads((SITE / "live" / "status.json").read_text())))
    write("404.html", page("Not found", '<h1>Not found</h1><p>That page doesn\'t exist. <a href="/">Back to the start</a>.</p>', None))
    for f in (SITE / "static").iterdir():
        if not f.is_file() or f.name.startswith("."):
            continue  # only the site's own files (not editor or tool folders)
        (out / "static").mkdir(exist_ok=True)
        shutil.copy(f, out / "static" / f.name)
    # Art kit from the stream overlay: the CSS (font comes from the <link> in page(), not a blocking @import)
    # and the avatar renderer for the live page; one portrait file per agent for the static pages.
    kit = (ART / "factorio-ui.css").read_text()
    write("static/factorio-ui.css", re.sub(r"^@import url\([^)]*\);\n", "", kit, flags=re.M))
    shutil.copy(ART / "avatar.js", out / "static" / "avatar.js")
    for key in AGENTS:
        if archive() or not AGENTS[key].get("earlier"):  # agents of the earlier runs only with the archive
            write(f"static/avatars/{key}.svg", avatar_art.svg(profile_row(key), 96, title=agent(key)["name"]))
    write("favicon.svg", FAVICON)
    # config.json "public": indexable (Nick, 2026-10-12, the public run); false keeps every page out of search engines
    write("robots.txt", "User-agent: *\nAllow: /\n" if PUBLIC else "User-agent: *\nDisallow: /\n")
    write("_headers", "/*\n" + ("" if PUBLIC else "  X-Robots-Tag: noindex, nofollow\n")
                      + "  Referrer-Policy: strict-origin-when-cross-origin\n"
                      "  X-Content-Type-Options: nosniff\n/live/status.json\n  Cache-Control: no-store\n")

    # final privacy check over everything written
    bad = []
    for p in out.rglob("*"):
        if p.is_file() and p.suffix in (".html", ".json", ".js", ".css", ".txt"):
            t = p.read_text()
            for pat in [r for r, _ in _REDACTIONS[:3]] + [_BLOCKED]:
                for m in pat.finditer(t):
                    bad.append(f"{p.relative_to(out)}: {m.group(0)[:60]}")
    if bad:
        raise SystemExit("privacy check failed:\n" + "\n".join(bad[:20]))
    n = sum(1 for p in out.rglob("*.html"))
    print(f"built {n} pages into {out}")


if __name__ == "__main__":
    main()
