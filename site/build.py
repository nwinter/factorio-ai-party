#!/usr/bin/env python3
"""Static site generator for the player-of-games companion site.

Reads the repo's run data (runs/*/scores.jsonl, notes.md, chat logs), the studies
in docs/studies/, and the curated text in site/content/site.json, and writes a
plain HTML/CSS/JS site to site/dist/. Python 3 stdlib only.

    python3 site/build.py            # build into site/dist
    python3 site/build.py --out DIR  # build somewhere else
"""

import argparse
import html
import json
import re
import shutil
import sys
import urllib.parse
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
# The art kit lives with the stream overlay; the site copies it so there is one source for both.
ART = REPO / "tools" / "stream" / "static"
sys.path.insert(0, str(ART.parent))
import avatar as avatar_art  # noqa: E402  (tools/stream/avatar.py, reads the part lists from avatar.js)

CONTENT = json.loads((SITE / "content" / "site.json").read_text())
CONFIG = json.loads((SITE / "config.json").read_text())
AGENTS = CONTENT["agents"]

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
    path = REPO / run["dir"] / "scores.jsonl"
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
    final = REPO / run["dir"] / "final-score.json"
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
    path = REPO / run["dir"] / run["chat"]
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


def line_chart(title, series, y_label, x_label="game time (minutes)", step=False, desc=""):
    """Inline SVG line chart with legend, direct end labels (<= 4 series), hover readout and a table view.

    series: [{"name": str, "points": [(x_minutes, y)]}] in fixed palette order.
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
    xticks = nice_ticks(max(xs) or 1, 8)
    yticks = nice_ticks(max(ys) or 1, 5)
    xmax, ymax = xticks[-1], yticks[-1]
    pw, ph = W - L - R, H - T - B

    def X(v):
        return L + pw * v / xmax

    def Y(v):
        return T + ph * (1 - v / ymax)

    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-labelledby="{cid}-t" class="chart-svg" preserveAspectRatio="xMidYMid meet">',
             f'<title id="{cid}-t">{esc(title)}</title>']
    for v in yticks:
        parts.append(f'<line class="grid" x1="{L}" x2="{W-R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}"/>')
        parts.append(f'<text class="tick" x="{L-6}" y="{Y(v)+4:.1f}" text-anchor="end">{fmt_num(v)}</text>')
    for v in xticks:
        parts.append(f'<text class="tick" x="{X(v):.1f}" y="{H-B+16}" text-anchor="middle">{fmt_num(v)}</text>')
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
        parts.append(f'<path class="line" style="stroke:var({var})" d="{" ".join(d)}"/>')
        ex, ey = pts[-1]
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
    data = {"L": L, "pw": pw, "xmax": xmax, "W": W, "T": T, "ph": ph, "ymax": ymax, "step": step, "y": y_label,
            "series": [{"name": s["name"], "var": s.get("var") or PALETTE[i % 8], "pts": [[round(x, 2), y] for x, y in s["points"]]}
                       for i, s in enumerate(series)]}
    # table view
    rows = []
    for s in series:
        for x, y in s["points"]:
            rows.append(f"<tr><td>{esc(s['name'])}</td><td>{x:.1f}</td><td>{fmt_num(y)}</td></tr>")
    table = (f'<details class="table-view"><summary>Show data as a table</summary><div class="table-wrap"><table>'
             f'<thead><tr><th>Series</th><th>Game minute</th><th>{esc(y_label)}</th></tr></thead>'
             f'<tbody>{"".join(rows)}</tbody></table></div></details>')
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


NAV = [("/", "Home"), ("/experiments/", "Experiments"), ("/runs/", "Runs"), ("/studies/", "Studies"), ("/live/", "Live")]


def page(title, body, active="/", description="", extra_head=""):
    site_title = CONFIG.get("site_title", "Player of Games")
    full = site_title if title == site_title else f"{title} · {site_title}"
    nav = "".join(
        f'<a href="{href}"{" aria-current=page" if href == active else ""}>{label}</a>' for href, label in NAV)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{esc(full)}</title>
<meta name="description" content="{esc(description or CONFIG.get('description', ''))}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
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
    <p>Player of Games: AI agents playing Factorio together, under the same rules as a human player.
    Built from the project's run logs. Preview build, not for sharing yet.</p>
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
        summ = notes_summary(REPO / run["dir"] / p["dir"] / "notes.md")
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


def build_runs_index(runs, all_worlds):
    body = ['<h1>Runs</h1><p class="lede">Every recorded session, newest first. Each run page has the milestone timeline, charts from the score log, and a card per agent.</p><div class="run-list">']
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
    team = []
    for k in CONTENT["team_order"]:
        a = agent(k)
        team.append(f'<li class="team-member" style="--ac:{a["color"]}">{avatar(k, "lg")}<div><a href="/agents/{k}/"><strong>{esc(a["name"])}</strong></a>'
                    f'<span>{esc(a["model"])}</span><span class="muted">{esc(a["harness"])}</span></div></li>')
    fable = agent("fable")
    sf = run_final(all_worlds["shake1"]["n"])
    cf = run_final(all_worlds["coop1"]["c"])
    body = f"""
<section class="hero">
  <p class="eyebrow">An open experiment</p>
  <h1>AI agents playing Factorio together, by the same rules as you.</h1>
  <p class="lede">Nine models from five labs share one factory. They can't spawn items, teleport or see the
  unexplored map. They walk, mine, craft and build at the speed a person would, talk to each other in game chat,
  and try to get from a crashed ship to a rocket launch. The runs will be streamed.</p>
  <p class="actions"><a class="fx-btn" href="/experiments/">See the experiments →</a> <a class="fx-btn ghost" href="/live/">Live stream</a></p>
  <div class="stats hero-stats">
    {stat("runs so far", len(runs))}
    {stat("technologies in co-op", cf["techs"], "Astra + Opus, 2 hours")}
    {stat("agents in one world", 9, "shakedown, enemies on")}
    {stat("chat messages", "365", "in the nine-agent hour")}
  </div>
</section>

<section>
  <h2>How it works</h2>
  <div class="flow" role="list">
    <div class="flow-step" role="listitem"><span class="flow-n">1</span><h3>The agents</h3><p>Each model runs in its own coding harness
      (Codex, Claude Code, Grok Build, Antigravity, Muse Code) with the same instructions: play until the deadline,
      keep notes, write a final summary.</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">2</span><h3>The harness</h3><p>Agents act through one command-line tool,
      <code>fh</code>, with more than 70 actions: look, walk, mine, craft, build, queue a plan, chat. Long plans run inside
      the game, so the model stays out of the low-level loop.</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">3</span><h3>The game</h3><p>A Factorio 2.0.77 server with a small mod that
      carries out each action tick by tick, under survival rules, and refuses anything a player couldn't do.</p></div>
    <div class="flow-step" role="listitem"><span class="flow-n">4</span><h3>The stream</h3><p>Director cameras follow whoever is most
      interesting. An overlay shows each agent's name, colour, current action and the team chat.</p></div>
  </div>
  <p class="muted">Two clocks are in play. In <strong>real time</strong> the game runs while the agent thinks, so slow thinking costs
  game time. In <strong>turn mode</strong> the game pauses whenever the character has nothing in progress, so game time measures
  decisions, not latency.</p>
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
  <h2>The team</h2>
  <p class="muted">Names and colours are the ones each agent chose for itself in the shakedown. The pixel portraits
  come from the stream's avatar renderer, which draws a default from each name and colour; agents can now design
  their own in game, and these will change when they do.</p>
  <ul class="team">{"".join(team)}</ul>
  <p class="muted small">Earlier solo and versus runs also used <a href="/agents/fable/">{esc(fable["model"])}</a> ({esc(fable["harness"])}).</p>
</section>

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
    return page(CONFIG.get("site_title", "Player of Games"), body, "/", CONFIG.get("description", ""))


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
    head = (f'<p class="crumbs"><a href="/">Home</a> / The team</p>'
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


def build_live():
    vid = CONFIG.get("youtube_video_id") or ""
    chan = CONFIG.get("youtube_channel_id") or ""
    body = f"""
<h1>Live</h1>
<p class="lede">When a run is on, the stream plays here with the team's status beside it.</p>
<div class="live-grid">
  <div class="player-wrap" id="player" data-video="{esc(vid)}" data-channel="{esc(chan)}">
    <div class="player-placeholder">
      <span class="ph-dot" aria-hidden="true"></span>
      <p><strong>No stream yet.</strong></p>
      <p class="muted">The first public run hasn't been scheduled. This space will hold the YouTube player.</p>
    </div>
  </div>
  <aside class="live-panel fx-root fx-panel" id="live" data-src="{esc(CONFIG.get('live_status_url', '/live/status.json'))}" data-poll="{int(CONFIG.get('live_poll_seconds', 15))}" aria-live="polite">
    <header class="fx-panel-title">Team status<span class="fx-panel-actions"><span class="live-badge fx-chip fx-chip--grey">Offline</span></span></header>
    <p class="live-updated fx-muted small"></p>
    <div class="live-body fx-inset"><p class="fx-muted">Waiting for status…</p></div>
  </aside>
</div>
<p class="muted small">Status refreshes every {int(CONFIG.get('live_poll_seconds', 15))} seconds. <a href="/live/?demo=1">See it with sample data</a>.</p>
"""
    return page("Live", body, "/live/", "Live stream and team status.",
                extra_head='<script src="/static/avatar.js" defer></script>\n<script src="/static/live.js" defer></script>')


FAVICON = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#e39827"/>
<path d="M16 7l2.2 3.1 3.7-.9.4 3.8 3.5 1.5-1.9 3.3 1.9 3.3-3.5 1.5-.4 3.8-3.7-.9L16 28l-2.2-3.1-3.7.9-.4-3.8-3.5-1.5L8.1 17.2 6.2 13.9l3.5-1.5.4-3.8 3.7.9z" fill="#1d1a16"/>
<circle cx="16" cy="17.5" r="4" fill="#e39827"/></svg>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(SITE / "dist"))
    args = ap.parse_args()
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    runs = CONTENT["runs"]
    all_worlds = {rid: load_scores(r) for rid, r in runs.items()}

    def write(rel, text):
        p = out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    write("index.html", build_home(runs, all_worlds))
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
    shutil.copy(SITE / "live" / "status.example.json", out / "live" / "status.example.json")
    shutil.copy(SITE / "live" / "status.json", out / "live" / "status.json")
    write("404.html", page("Not found", '<h1>Not found</h1><p>That page doesn\'t exist. <a href="/">Back to the start</a>.</p>', None))
    for f in (SITE / "static").iterdir():
        (out / "static").mkdir(exist_ok=True)
        shutil.copy(f, out / "static" / f.name)
    # Art kit from the stream overlay: the CSS (font comes from the <link> in page(), not a blocking @import)
    # and the avatar renderer for the live page; one portrait file per agent for the static pages.
    kit = (ART / "factorio-ui.css").read_text()
    write("static/factorio-ui.css", re.sub(r"^@import url\([^)]*\);\n", "", kit, flags=re.M))
    shutil.copy(ART / "avatar.js", out / "static" / "avatar.js")
    for key in AGENTS:
        write(f"static/avatars/{key}.svg", avatar_art.svg(profile_row(key), 96, title=agent(key)["name"]))
    write("favicon.svg", FAVICON)
    write("robots.txt", "User-agent: *\nDisallow: /\n")
    # Cloudflare Pages: keep everything out of search engines while unlisted; no caching of live status
    write("_headers", "/*\n  X-Robots-Tag: noindex, nofollow\n  Referrer-Policy: strict-origin-when-cross-origin\n"
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
