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
# The test runs left the repo before the public run (tools/public-start.sh moved them to a pog-archive/runs-DATE).
# The archive pages read them there: POG_SITE_ARCHIVE, else the newest runs-* folder under the grouped
# ~/code/personal/player-of-games/artifacts/pog-archive (d28 directory grouping), else under ~/code/pog-archive (where
# it was before; both are read during the move).
_ARCHIVE_PARENTS = (Path.home() / "code" / "personal" / "player-of-games" / "artifacts" / "pog-archive",
                    Path.home() / "code" / "pog-archive")
_ARCHIVES = ([Path(os.environ["POG_SITE_ARCHIVE"])] if os.environ.get("POG_SITE_ARCHIVE")
             else [d for parent in _ARCHIVE_PARENTS for d in sorted(parent.glob("runs-*"), reverse=True)])


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
import moderation  # noqa: E402  (site/moderation.py: viewer lines deleted on YouTube or listed by hand)
import chronicle as chron  # noqa: E402  (site/chronicle.py: /chronicle/ from runs/RUN/chronicle.jsonl)
import agents as agent_pages  # noqa: E402  (site/agents.py: /agents/ and /timeline/ from tools/agent_stats.py)
import highlights  # noqa: E402  (site/highlights.py: /chat/, the agents' spoken lines and confessions)
import search as site_search  # noqa: E402  (site/search.py: /search/ and its index)
import timelapse  # noqa: E402  (site/timelapse.py: the base over time on the run page)
import terrain  # noqa: E402  (site/terrain.py: /live/terrain/, map frames under the maps)
import chartpub  # noqa: E402  (site/chartpub.py: /live/chart/, the chart the stream service draws; d22 batch97 BG3)
import blueprints as bp_pages  # noqa: E402  (site/blueprints.py: /blueprints/, the team's blueprint library)
import how as how_pages  # noqa: E402  (site/how.py: /how/, how it was made, from site/content/how/)
import updates as op_updates  # noqa: E402  (site/updates.py: /updates/, the operator's changes and their status)
import legal  # noqa: E402  (site/legal.py: /privacy/ and /terms/, d23, for the YouTube uploader's OAuth verification)
import videos_page  # noqa: E402  (site/videos_page.py: /videos/, every shift's video on YouTube and R2; batch265)
import gameicons  # noqa: E402  (site/gameicons.py: the game's icons, static/game/; Graphics copyright Wube Software)

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


# The owner's accounts and personal tools that appear in some studies. The build fails if any reach dist/;
# site.json's per-study `rewrite` list is where they get replaced. The owner's name may appear (Nick d27 10:10: the
# domain makes it obvious; the site neither adds it nor strips it).
_BLOCKED = re.compile(r"(?i:account-b|codex-b|claude-b|dropbox|cygnal|peon-ping|account-d)")


def load_long(runs_dir):
    """The long run as the site shows it (build.py and og_card.py): redacted, lines naming an account or personal tool
    and the viewer lines deleted on YouTube or in site/hidden-viewers.json left out."""
    hidden = moderation.load(runs_dir, os.environ.get("POG_HIDDEN_VIEWERS") or SITE / "hidden-viewers.json")  # tests: their own
    return longrun.load(runs_dir, clean, start=CONTENT.get("run_start"), keep=keep_line, agents=list(AGENTS),
                        hide=hidden.hides)


def keep_line(text):
    return not _BLOCKED.search(text or "")


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


def fmt_full(v):
    """A count or rate in full, grouped (batch314 A, viewer Aurora: no 9.43M or 12k on a card): 9,430,112; 163.5."""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return f"{v:,}"


def breakable(text):
    """Escaped text a value tile may wrap: a break point after each group comma (1,234,<wbr>567) and after the hours of
    a duration (358h<wbr>07m), so a value never needs clipping however wide it grows."""
    return re.sub(r"(\d)h(\d)", r"\1h<wbr>\2", esc(str(text)).replace(",", ",<wbr>"))


def hm(hours):
    """Hours as a duration in full: 369.2 -> '369h12m' (1,234h05m past a thousand), as game time reads."""
    m = int(round(hours * 60))
    return f"{m // 60:,}h{m % 60:02d}m"


def fmt_num(v):
    if v >= 10000:
        return f"{v/1000:.0f}k"
    if v >= 1000:
        return f"{v/1000:.1f}k".replace(".0k", "k")
    return f"{v:g}"


def mark_step(marks, X, width):
    """(batch314 B) every k-th shift label (k from 1, 2, 5, 10, ...: S10, S20, ...) so that none of the labels
    drawn collide: marks [(x, "S12")], X the scale, width a label's width with its gap, in the same units."""
    nums = [(X(x), int(re.sub(r"\D", "", lab) or 0)) for x, lab in marks]
    for k in (1, 2, 5, 10, 20, 25, 50, 100, 200, 500):
        xs = [x for x, n in nums if k == 1 or n % k == 0]
        if all(b - a >= width for a, b in zip(xs, xs[1:])):
            return k
    return 1000


def line_chart(title, series, y_label, x_label="game time (minutes)", step=False, desc="", hours=False, marks=(), clock=(),
               x0=0, gaps=(), smooth=False):
    """Inline SVG line chart with legend, direct end labels (<= 4 series), hover readout and a table view.

    series: [{"name": str, "points": [(x_minutes, y)], "var": "--sN", "dash": bool}] in fixed palette order.
    hours: x ticks in hours of game time; marks: [(x_minutes, label)] shift starts: a dashed vertical each, the labels
    in a strip under the axis, thinned so none collide (batch314 B); clock: [(x_minutes, "Oct 12, 20:17")] read by
    the hover for the real time; x0: the x axis starts here (a shift's page); gaps: [(x0, x1)] holes in the record,
    shaded, the lines broken there; smooth: site.js may add a 1-game-hour average, drawn apart from the samples.
    site.js draws the chart again at the page's own width (and for a range, legend toggles, the average) from the
    chart-data JSON; this SVG is what shows without the script.
    """
    global _chart_n
    _chart_n += 1
    cid = f"c{_chart_n}"
    W, H = 640, 300
    xs = [p[0] for s in series for p in s["points"]] or [0, 1]
    ys = [p[1] for s in series for p in s["points"]] or [0, 1]
    # right margin fits the direct end labels ("Name 1.2k"), which are only drawn for <= 4 series
    longest = max((len(s["name"]) + len(fmt_full(s["points"][-1][1])) + 1 for s in series if s["points"]), default=0)
    SB = 18 if marks else 0  # the shift strip under the x ticks
    L, R, T, B = 48, (int(18 + 7.6 * longest) if len(series) <= 4 else 16), 14, 36 + SB  # 13-unit labels
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
        parts.append(f'<text class="tick" x="{X(v):.1f}" y="{T+ph+16}" text-anchor="middle">{tick}</text>')
    for g0, g1 in gaps:
        a, b = max(g0, x0), min(g1, xmax)
        if b > a:
            parts.append(f'<rect class="gap" x="{X(a):.1f}" y="{T}" width="{X(b) - X(a):.1f}" height="{ph}"><title>No score rows '
                         f'{esc(longrun.game_time(g0 * 3600))} to {esc(longrun.game_time(g1 * 3600))}</title></rect>')
    inside = [(mx, ml) for mx, ml in marks if x0 <= mx <= xmax]
    k = mark_step(inside, X, 7.2 * max((len(ml) for _, ml in inside), default=3) + 8) if inside else 1
    sy = T + ph + 22  # the strip: a tick per shift start, every k-th labelled
    for mx, mlabel in inside:
        num = int(re.sub(r"\D", "", mlabel) or 0)
        parts.append(f'<line class="mark" x1="{X(mx):.1f}" x2="{X(mx):.1f}" y1="{T}" y2="{T+ph}"/>'
                     f'<line class="mark-tick" x1="{X(mx):.1f}" x2="{X(mx):.1f}" y1="{sy}" y2="{sy+4}"/>')
        if k == 1 or num % k == 0:
            parts.append(f'<text class="mark-label" x="{X(mx):.1f}" y="{sy+15}" text-anchor="middle">{esc(mlabel)}</text>')
    parts.append(f'<line class="axis" x1="{L}" x2="{W-R}" y1="{T+ph}" y2="{T+ph}"/>')
    parts.append(f'<text class="axis-label" x="{L+pw/2}" y="{H-4}" text-anchor="middle">{esc(x_label)}{" · S: shift starts" if marks else ""}</text>')

    label_slots = []
    for idx, s in enumerate(series):
        pts = s["points"]
        if not pts:
            continue
        var = s.get("var") or PALETTE[idx % len(PALETTE)]
        d = []
        for j, (x, y) in enumerate(pts):
            # a line breaks across a hole in the record (gaps) and where game time goes back
            if j == 0 or x < pts[j - 1][0] or any(pts[j - 1][0] <= g0 and x >= g1 for g0, g1 in gaps):
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
            label_slots.append([Y(ey), X(ex), s["name"], fmt_full(ey)])
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
            "hours": hours, "xl": x_label, "marks": [[round(x, 2), m] for x, m in marks], "gaps": [[g0, g1] for g0, g1 in gaps],
            "smooth": smooth or None,
            "series": [{"name": s["name"], "var": s.get("var") or PALETTE[i % 8], "dash": s.get("dash") or None,
                        "pts": [[round(x, 2), y] for x, y in s["points"]]} for i, s in enumerate(series)]}
    if clock == "page":
        data["clock"] = "page"  # the page's one #chart-clock list (long_charts), shared by its charts
    elif clock:
        data["clock"] = [[round(x, 2), c] for x, c in clock]
    # table view: a row per x, a column per series
    xs_all = sorted({x for s in series for x, _ in s["points"]})
    vals = [dict(s["points"]) for s in series]
    fx = (lambda x: longrun.game_time(x * 3600)) if hours else (lambda x: f"{x:.1f}")
    rows = "".join(f"<tr><td>{fx(x)}</td>" + "".join(f"<td>{fmt_full(v[x]) if x in v else ''}</td>" for v in vals) + "</tr>"
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


# The public copy of the code (Nick d17 14:15: MIT, scrubbed history; tools/public_sync.py)
GITHUB_URL = "https://github.com/nwinter/factorio-ai-party"


def nav_items():
    """The homepage is the live show; /live/ stays as an alias for links shared before. Without the archive: Live,
    the run's page (when there is one) and About."""
    if archive():
        return [("/", "Live"), ("/experiments/", "Experiments"), ("/runs/", "Runs"), ("/studies/", "Studies")] + updates_nav() + \
            [("/about/", "About")]
    return [("/", "Live"), ("/polls/", "Polls")] + ([("/runs/long/", "The run")] + ([("/videos/", "Videos")] if VIDEOS or R2 else []) + [("/agents/", "Agents"), ("/timeline/", "Timeline"), ("/chronicle/", "Chronicle"),
                               ("/chat/", "Chat")] + ([("/blueprints/", "Blueprints")] if BLUEPRINTS else []) + [("/search/", "Search")]
                              if LONG else []) + updates_nav() + [("/how/", "How it was made"), ("/about/", "About"),
                                                  (GITHUB_URL, "GitHub")]


# Under "More" in the nav (batch270, Nick d27 10:10: Polls was the second item and used once; highlighted on the
# homepage and in the nav when a poll is open instead): the pages a returning viewer looks for less often.
NAV_MORE = ("/polls/", "/updates/", "/how/", GITHUB_URL)


def nav_html(active):
    """The main nav: the pages people come back for, then "More" (a disclosure; on a phone the Menu button shows the
    whole list). The More page that is open marks its summary too."""
    def link(href, label):
        cur = " aria-current=page" if href == active else ""
        rel = " rel=noopener" if href.startswith("http") else ""
        return f'<a href="{href}"{cur}{rel}>{label}</a>'
    items = nav_items()
    main = "".join(link(h, l) for h, l in items if h not in NAV_MORE)
    more = "".join(link(h, l) for h, l in items if h in NAV_MORE)
    if not more:
        return main
    cur = " is-current" if active in NAV_MORE else ""
    return (main + f'<details class="nav-more{cur}"><summary>More<span class="nav-dot" hidden></span></summary>'
            f'<div class="nav-more-list">{more}</div></details>')


def updates_nav():
    return [("/updates/", "Updates")] if UPDATES and Path(UPDATES).is_file() else []


def social_meta(full, site_title, description, path, og=None):
    """Open Graph and Twitter card tags, so a shared link shows the title, a line and the card image (site/og_card.py).
    og: (image file, its public path) for a page's own card (a shift's), else the site's."""
    base = CONFIG.get("site_url", "").rstrip("/")
    img, public = og or (SITE / "static" / "og.png", "/static/og.png")
    if not base or not img.exists():
        return ""
    ver = hashlib.sha256(img.read_bytes()).hexdigest()[:10]
    image = f"{base}{public}?v={ver}"
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


def page(title, body, active="/", description="", extra_head="", path=None, og=None):
    site_title = CONFIG.get("site_title", "Factorio AI Party")
    full = site_title if title == site_title else f"{title} · {site_title}"
    description = description or CONFIG.get("description", "")
    nav = nav_html(active)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{ROBOTS_META}<title>{esc(full)}</title>
<meta name="description" content="{esc(description)}">
{social_meta(full, site_title, description, path, og)}<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Titillium+Web:wght@400;600;700&amp;display=swap">
<link rel="stylesheet" href="/static/factorio-ui.css">
<link rel="stylesheet" href="/static/style.css">
<script>document.documentElement.classList.add('js');try{{var t=(location.search.match(/[?&]theme=(light|dark)/)||[])[1]||localStorage.getItem('theme');if(t)document.documentElement.dataset.theme=t}}catch(e){{}}</script>
{extra_head}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header fx-root" data-api="{esc(CONFIG.get("live_api_url") or "")}">
  <div class="wrap header-row">
    <a class="brand" href="/"><span class="brand-mark" aria-hidden="true"></span>{esc(site_title)}</a>
    <button class="nav-toggle fx-btn" type="button" aria-expanded="false" aria-controls="site-nav">Menu<span class="nav-dot" hidden></span></button>
    <nav class="site-nav" id="site-nav" aria-label="Main">{nav}</nav>
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
    Built from the project's run logs. <a href="/how/">How it was made</a>. <a href="https://github.com/nwinter/factorio-ai-party">Source on GitHub</a>. <a href="/privacy/">Privacy</a>. <a href="/terms/">Terms</a>.{'' if PUBLIC else ' Preview build, not for sharing yet.'}</p>
    <p class="credit">Factorio is a game by Wube Software. {gameicons.CREDIT}.</p>
  </div>
</footer>
<script src="/static/site.js" defer></script>
</body>
</html>
"""


def stat(label, value, sub="", icon="", sub_html=""):
    """A number tile. icon: a game icon's <img>, beside the label (batch314 A: apart from the number, which takes the
    tile's whole width and wraps at its group commas: breakable); sub_html: markup under the label (planet icons)."""
    sub = f"<div class=stat-sub>{esc(sub)}</div>" if sub else (f"<div class=stat-sub>{sub_html}</div>" if sub_html else "")
    return (f'<div class="stat{" stat-icon" if icon else ""}"><div class="stat-value">{breakable(value)}</div>'
            f'<div class="stat-label">{icon}<span>{esc(label)}</span></div>{sub}</div>')


def planet_icons(names, size=22):
    """Planets as the game's icons with their names for screen readers and on hover."""
    return "".join(f'<span class="planet-ico" title="{esc(p.capitalize())}">{gameicons.place(p, size, p.capitalize()) or esc(p.capitalize())}</span>'
                   for p in names)


def journey(lr):
    """The planets in the order the run reached them, with the game's pictures: Nauvis, each planet's first arrival
    (the score log), then the edge and the Shattered Planet when a platform arrived there."""
    stops = [("nauvis", None, None, "the start")]
    for f in lr["firsts"]:
        k = f["key"]
        if k.startswith("planet:") or k in ("arrive:solar-system-edge", "arrive:shattered-planet"):
            name = k.split(":", 1)[1]
            stops.append((name, f["tick"], f["shift"], f["label"]))
    if len(stops) < 2:
        return ""
    items = []
    for name, tick, n, label in stops:
        pic = gameicons.place(name, 88, "", big=True)
        title = "Solar system edge" if name == "solar-system-edge" else name.replace("-", " ").capitalize()
        when = (f'game time {esc(longrun.game_time(tick))} · <a href="/runs/long/shift-{n}/">shift {n}</a>'
                if tick is not None else "the start")
        items.append(f'<li><span class="j-pic">{pic}</span><b>{esc(title)}</b><span class="muted small">{when}</span></li>')
    return (f'<section class="journey" aria-labelledby="journey-h"><h2 id="journey-h">The journey</h2>'
            f'<ol class="journey-list">{"".join(items)}</ol></section>')


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
        lines = [f'<article class="agent-card" style="--ac:{agent_pages.ac(a["color"])}">',
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
BLUEPRINTS = None  # the team's blueprint library (site/blueprints.py latest), set in main()
UPDATES = SITE / "content" / "operator-updates.json"  # /updates/ (site/updates.py; d23 batch119 CB4); none: no page
# Shift videos uploaded to YouTube (tools/yt_upload.py writes site/content/videos.json): {run id: {id, shift, title,
# description, chapters, playlist}}. A shift with a video gets an embed on /runs/long/ and its own page.
VIDEOS = {}
# Shifts that play on R2 (site/videos_page.py refresh writes site/content/r2.json after checking each one answers)
R2 = {}
VIDEO_STRIP = ""  # the homepage's way into /videos/ (site/videos_page.py home_strip)
YT_ID = re.compile(r"^[A-Za-z0-9_-]{6,20}$")


def load_videos(path):
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return {rid: v for rid, v in raw.items() if isinstance(v, dict) and YT_ID.match(str(v.get("id", "")))}


def load_r2(path):
    """{run id: {shift, player, master, duration_s, checked}} for the shifts that play on R2 (only r2.dev URLs)."""
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return {rid: x for rid, x in raw.items() if isinstance(x, dict)
            and str(x.get("player", "")).startswith(videos_page.PUBLIC + "/player/")}


def shift_video(s):
    return VIDEOS.get(s["id"]) if not s.get("empty") else None


def shift_href(s):
    return f'/runs/long/shift-{s["n"]}/'


def _naive(d):
    return d.astimezone().replace(tzinfo=None) if d.tzinfo else d


def video_offset(v, t):
    """Seconds into a shift's video for a local time (scores.jsonl's `t`), from videos.json's `timeline` (each
    recording's wall-clock span, in video order; tools/yt_upload.py): a time in a gap maps to the next recording's
    start, one up to 2 minutes before the first to 0:00 (as tools/shift_video.py offset()); None outside it."""
    x = longrun.parse_t(t) if t else None
    if not v or not x or not v.get("timeline"):
        return None
    x, at = _naive(x), 0.0
    for i, (a, b) in enumerate(v["timeline"]):
        a, b = longrun.parse_t(a), longrun.parse_t(b)
        if not a or not b:
            return None
        a, b = _naive(a), _naive(b)
        if x < a:
            return at if i else (0.0 if (a - x).total_seconds() <= 120 else None)
        if x <= b:
            return at + (x - a).total_seconds()
        at += (b - a).total_seconds()
    return None


def video_link(n, t, lead=20):
    """A small "watch this moment" link into shift n's video, starting `lead` seconds before t, or "" (no video, or a
    time outside it)."""
    s = next((x for x in (LONG or {}).get("shifts", []) if x.get("n") == n), None)
    v = shift_video(s) if s else None
    off = video_offset(v, t)
    if off is None:
        return ""
    return (f' <a class="vlink" href="https://www.youtube.com/watch?v={esc(v["id"])}&amp;t={max(0, int(off) - lead)}s" '
            f'title="Watch this moment" aria-label="Watch this moment">▶</a>')


def r2_link(s):
    """ · a link to the shift's player on this site (/videos/shift-N/: the video from R2 with its timeline, the
    factory's numbers and the chat), or ""."""
    x = R2.get(s["id"]) if s else None
    return (f' · <a href="/videos/shift-{s["n"]}/">Watch it here</a> with its timeline, numbers and chat'
            if x else "")


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
        return '<p class="muted">None yet.</p>' if shift_links else '<p class="muted">No first of the run in this shift.</p>'
    kinds = [k for k in KIND_LABEL if any(f["kind"] == k for f in firsts)]
    bar = ('<div class="kind-filter" role="group" aria-label="Show milestones of one kind" hidden>'
           '<button type="button" class="fx-btn small" data-kind="" aria-pressed="true">All</button>'
           + "".join(f'<button type="button" class="fx-btn small" data-kind="{k}" aria-pressed="false">{KIND_LABEL[k]}</button>'
                     for k in kinds) + '</div>') if filters and len(kinds) > 1 else ""
    rows = "".join(
        f'<tr data-kind="{f["kind"]}"><td><span class="kind kind-{f["kind"]}">{KIND_LABEL[f["kind"]]}</span></td><th scope="row"><span class="ms">{gameicons.first_icon(f, 24)}<span>{esc(f["label"])}</span></span>{video_link(f["shift"], f["t"], 20 if f["kind"] == "team" else 120)}</th>'
        f'<td class="num">{esc(longrun.game_time(f["tick"]))}</td><td class="num">{esc(_pt(f["t"]))}</td>'
        + (f'<td class="num"><a href="/runs/long/shift-{f["shift"]}/">{f["shift"]}</a></td>' if shift_links else "") + "</tr>"
        for f in firsts)
    head = ('<th scope="col">Kind</th><th scope="col">Milestone</th><th scope="col">Game time</th><th scope="col">Pacific</th>'
            + ('<th scope="col">Shift</th>' if shift_links else ""))
    return (f'{bar}<div class="table-wrap"><table class="firsts"><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table></div>'
            '<p class="muted small">Score log every 2 minutes: a time is up to 2 minutes after the event. Deaths and '
            'losses: the stream director\'s log.</p>')


RECENT_SHIFTS = 10  # (batch314 B) the charts' "recent" range: the last this many shifts


def long_charts(lr, lo=None, hi=None, x0=0):
    """Science per minute by pack, technologies and rockets on the save's game clock, shift starts marked; one list
    of Pacific times for the page's hovers. The whole run (lo None, batch314 B): one chart a row, a range bar shared by
    every chart (the full run, the last RECENT_SHIFTS shifts, one shift; site.js), the data's cutoff, and the holes in
    the record and the game time replayed from an earlier save named."""
    marks = [(x, f"S{n}") for x, n, _ in lr["bounds"]]
    inside = (lambda pts: [(x, y) for x, y in pts if (lo is None or x >= lo) and (hi is None or x <= hi)])
    clock = "page"
    gaps = [(g["x0"], g["x1"]) for g in lr.get("gaps") or []]
    ps = pack_rate_series(lr["spm_packs"], lo, hi)
    opts = dict(x_label="game time (hours)", hours=True, marks=marks, clock=clock, x0=x0, gaps=gaps)
    charts = []
    tot = inside(lr["spm"])
    if tot:
        charts.append(line_chart("Science per minute (SPM)", [{"name": "SPM", "points": tot}], "research units per minute",
                                 desc="Research units a minute: the labs' use of packs in sets. A point per 10-game-minute window.",
                                 smooth=True, **opts))
    if ps:
        charts.append(line_chart("Science packs used by the labs per minute, by pack", ps, "packs per minute",
                                 desc="A point per 10-game-minute window. Click a pack to hide or show it.", **opts))
    made = inside(lr.get("made_spm") or [])
    if made:
        charts.append(line_chart("Science packs made per minute, all colours", [{"name": "Packs made", "points": made}],
                                 "packs per minute", desc="A point per 10-game-minute window.", smooth=True, **opts))
    charts.append(line_chart("Technologies researched", [{"name": "Technologies", "points": inside(lr["research"])}],
                             "technologies", step=True, **opts))
    charts.append(line_chart("Rockets launched", [{"name": "Rockets", "points": inside(lr["rockets"])}], "rockets",
                             step=True, **opts))
    times = json.dumps([[x, _pt(t)] for x, t in inside(lr["clock"])]).replace("</", "<\\/")
    head = ""
    if lo is None:
        bounds = lr["bounds"]
        cut = lr.get("cutoff")
        recent = bounds[-RECENT_SHIFTS][0] if len(bounds) > RECENT_SHIFTS else None
        opts_html = "".join(f'<option value="{n}" data-lo="{x}" data-hi="{bounds[i + 1][0] if i + 1 < len(bounds) else (cut["x"] if cut else x)}">Shift {n}</option>'
                            for i, (x, n, _) in enumerate(bounds))
        bar = (f'<div class="chart-range" role="group" aria-label="Range of every chart below" hidden>'
               f'<button type="button" class="fx-btn small" data-range="full" aria-pressed="true">Full run</button>'
               + (f'<button type="button" class="fx-btn small" data-range="recent" data-lo="{recent}" aria-pressed="false">Last {RECENT_SHIFTS} shifts</button>' if recent is not None else "")
               + f'<label class="range-shift">Shift <select data-range="shift"><option value="">choose</option>{opts_html}</select></label>'
               f'<label class="range-smooth"><input type="checkbox" data-smooth> 1-game-hour average</label></div>')
        notes = []
        if cut:
            notes.append(f'Data to game time {esc(cut["game"])}: the last score row read, {esc(_pt(cut["t"]))} Pacific, shift {cut["shift"]}.')
        for g in lr.get("gaps") or []:
            notes.append(f'No score rows from game time {esc(longrun.game_time(g["x0"] * 3600))} to {esc(longrun.game_time(g["x1"] * 3600))} '
                         f'({esc(_pt(g["t0"]))} to {esc(_pt(g["t1"]))} Pacific, shift {g["shift"]}): shaded, the lines broken there.')
        for r in lr.get("replays") or []:
            notes.append(f'Shift {r["shift"]} read game time {esc(r["game0"])} to {esc(r["game1"])} again ({r["rows"]} score rows, '
                         f'{esc(_pt(r["t0"]))} to {esc(_pt(r["t1"]))} Pacific; the game time went back {esc(r["behind"])} from the furthest '
                         f'already read): those rows are left out of the charts and totals, so no game time counts twice.')
        for r in lr.get("rollbacks") or []:
            notes.append(f'Shift {r["shift"]}\'s score log went back {esc(r["back"])} of game time at {esc(_pt(r["t"]))} Pacific (to '
                         f'{esc(r["game"])}) and play went on from there: those game minutes show twice in the charts, as read, and '
                         f'packs are counted again from there (what the counters lost with it is not subtracted).')
        notes.append("Each point of a per-minute chart is one 10-game-minute window of the score log (a window never spans "
                     "a hole). The 1-game-hour average, when shown, is a separate line: the mean of the windows in the "
                     "game hour before each point; the points stay as they are.")
        head = bar + '<ul class="chart-notes muted small">' + "".join(f"<li>{n}</li>" for n in notes) + "</ul>"
    return (f'<script type="application/json" id="chart-clock">{times}</script>{head}'
            f'<div class="chart-grid{" chart-grid-wide" if lo is None else ""}">{"".join(charts)}</div>')


def replay_note(s):
    """(batch314) a shift whose score log read game time already read (longrun.load's replays): which, and that its
    numbers leave those rows out."""
    r = s.get("replayed")
    if not r:
        return ""
    return (f'<p class="muted small">The score log read game time {esc(r["game0"])} to {esc(r["game1"])} again in this shift '
            f'({r["rows"]} rows, {esc(_pt(r["t0"]))} to {esc(_pt(r["t1"]))} Pacific; the game time went back {esc(r["behind"])} '
            f'from the furthest already read). Those rows are left out of its numbers, charts and the run\'s totals, so no '
            f'game time counts twice.</p>')


def shift_stats(s):
    return "".join([
        stat("on stream", hm(_hours(s["started"], s["ended"])), _when(s["started"], s["ended"])),
        stat("game time played", longrun.game_time(s["tick1"] - s["tick0"]), f'{s["game0"]} to {s["game1"]}'),
        stat("technologies", fmt_full(s["research"]), f'+{s["research_new"]:,}' + (f' · at the end: {s["researching"]}' if s.get("researching") else ""),
             icon=gameicons.item("lab", 28)),
        stat("rockets", f'{s["rockets"]:,}', f'+{s["rockets_new"]:,}', icon=gameicons.item("rocket-part", 28)),
        stat("SPM", "–" if s["spm"] is None else fmt_full(s["spm"]), "research units a minute, shift average",
             icon=gameicons.item("automation-science-pack", 28)),
        stat("packs made / min", "–" if s.get("made_per_min") is None else fmt_full(s["made_per_min"]), "all colours, shift average",
             icon=gameicons.item("space-science-pack", 28)),
        stat("plates / min", "–" if not s.get("output_per_min") else fmt_full(s["output_per_min"]["plates"]), "iron, copper, steel, shift average",
             icon=gameicons.item("iron-plate", 28)),
        stat("circuits / min", "–" if not s.get("output_per_min") else fmt_full(s["output_per_min"]["circuits"]), "green, red, blue, shift average",
             icon=gameicons.item("electronic-circuit", 28)),
        stat("packs made", f'{s["made_total"]:,}'),
        stat("deaths / loss alerts", f'{s["deaths"]:,} / {s["losses"]:,}'),
        stat("viewer messages", fmt_full(s["viewer_lines"]))])


def qa_html(qa, n=None):
    items = []
    for q in qa:
        if q["kind"] == "viewer":
            who = f'<span class="chip viewer">{esc(q["who"])}</span>'
        elif q["kind"] == "agent":
            who = agent_chip(q["who"])
        elif q["kind"] == "operator":
            who = '<span class="chip host">Operator</span>'
        else:
            who = f'<span class="chip host">{esc(q["who"])}</span>'
        # an answer: whom it answers, and under the viewer line it answers when that is shown (longrun.thread_qa)
        to = (f'<span class="c-to muted small">↩ {esc(", ".join(q["to"]))}</span> ' if q.get("to") else "")
        thread = " qa-thread" if q.get("thread") else ""
        items.append(f'<li class="qa-{q["kind"]}{thread}"><span class="c-time">{esc(_pt(q["t"], day=False))}{video_link(n, q["t"], 10)}</span>{who}'
                     f'{to}<span class="c-text">{esc(q["text"])}</span></li>')
    if len(items) <= 40:
        return f'<ol class="chat qa">{"".join(items)}</ol>'
    # a long transcript: the first 30 lines, the rest one click away
    return (f'<ol class="chat qa">{"".join(items[:30])}</ol><details class="chat-full"><summary>{len(items) - 30} more lines'
            f'</summary><ol class="chat qa" start="31">{"".join(items[30:])}</ol></details>')


# A shift's own link-preview card (site/og_card.py --shifts renders it from shift_card_facts into OG_SHIFTS, keyed by
# the facts, so a card whose numbers changed is drawn again); the page uses it only when its key matches.
OG_SHIFTS = Path(os.environ.get("POG_OG_SHIFTS") or SITE / "og" / "shifts")  # tests point it elsewhere
OG_CARD_VERSION = "1"


def shift_card_facts(s, lr):
    mine = [f for f in lr["firsts"] if f["shift"] == s["n"]]
    big = [f["label"] for f in mine if f["kind"] in ("space", "science")] + [f["label"] for f in mine if f["kind"] == "research"]
    return {"n": s["n"], "when": f"{_when(s['started'], s['ended'])} Pacific",
            "stats": [[f"+{s['research_new']}", "technologies"], [f"+{s['rockets_new']}", "rockets"],
                      [f"{s['made_total']:,}", "science packs"], [longrun.game_time(s["tick1"] - s["tick0"]), "game time"]],
            "firsts": big[:3]}


def shift_card_key(facts):
    return hashlib.sha256((OG_CARD_VERSION + json.dumps(facts, sort_keys=True)).encode()).hexdigest()[:16]


def shift_card(s, lr):
    """The shift's card image when one was rendered for its current facts, else None (the site's card)."""
    png, key = OG_SHIFTS / f"shift-{s['n']}.png", OG_SHIFTS / f"shift-{s['n']}.key"
    try:
        ok = png.exists() and key.read_text().strip() == shift_card_key(shift_card_facts(s, lr))
    except OSError:
        ok = False
    return png if ok else None


def shift_summary(s, firsts):
    """The page's description (search and link previews): the shift's numbers and its biggest firsts."""
    bits = [f"Shift {s['n']}: {_when(s['started'], s['ended'])} Pacific", f"+{s['research_new']} technologies",
            f"+{s['rockets_new']} rockets", f"{s['made_total']:,} science packs"]
    big = [f["label"] for f in firsts if f["kind"] in ("space", "science")][:3]
    return " · ".join(bits) + (". " + ", ".join(big) + "." if big else ".")


def plan_html(p):
    """The team plan as the shift left it (longrun.shift_plan; viewer Alex 22:12): goals, each agent's line with the game
    time it was set, open projects with progress and next step, the request counts."""
    def who(name):
        return agent_chip(name.lower()) if name and name.lower() in AGENTS else esc(name or "?")
    lines = "".join(f'<li>{who(l["agent"])} <span class="c-text">{esc(l["text"])}</span>'
                    + (f' <span class="muted small">set at {esc(l["game"])}{" by " + esc(l["by"]) if l.get("by") else ""}</span>'
                       if l.get("game") or l.get("by") else "") + '</li>' for l in p["lines"])
    # (d22 batch75 AK11, viewer Foobator site:4284) each project's board status as a chip (doing, blocked), and what
    # blocked it: the open items in its blocked_by, its newest note (plan.json since AK11)
    chip = {"doing": "fx-chip--green", "blocked": "fx-chip--red"}

    def blockers(x):
        rows = [f'Blocked by #{b.get("id")} {b.get("title") or ""} ({b.get("status")})' for b in x.get("blocked_by") or [] if isinstance(b, dict)]
        n = x.get("note") if isinstance(x.get("note"), dict) else None
        if n and n.get("text"):
            rows.append(("Marked blocked; newest note" if x.get("status") == "blocked" else "Newest note")
                        + (f' by {n["by"]}' if n.get("by") else "") + f': {n["text"]}')
        return "".join(f'<br><span class="muted small">{esc(r)}</span>' for r in rows)
    projects = "".join(f'<li><b>{esc(x["title"])}</b>'
                       + (f' <span class="fx-chip {chip.get(x.get("status"), "fx-chip--grey")} small">{esc(x["status"])}</span>' if x.get("status") else "")
                       + f' <span class="muted small">{esc(x["owner"] or "no owner")}{", " + esc(x["progress"]) if x.get("progress") else ""}</span>'
                       + blockers(x)
                       + (f'<br><span class="muted small">Next:</span> {esc(x["next"])}' if x.get("next") else "") + '</li>'
                       for x in p["projects"])
    counts = [f'{p["open_unowned"]} open requests nobody was on' if p.get("open_unowned") is not None else "",
              f'{p["in_progress"]} in progress' if p.get("in_progress") is not None else ""]
    when = f' (read at game time {esc(p["read_game"])})' if p.get("read_game") else ""
    return (f'<h2>The team plan at the end of the shift</h2><p class="muted small">The agents\' shared plan as the stream '
            f'last read it{when}: the goals, who was on what, the open projects.</p>'
            + (f'<p class="plan-goals"><b>Goals:</b> {esc(p["goals"])}'
               + (f' <span class="muted small">set at {esc(p["goals_game"])}</span>' if p.get("goals_game") else "") + '</p>'
               if p.get("goals") else "")
            + (f'<ul class="plan-shift">{lines}</ul>' if lines else '<p class="muted">No agent had a line on the plan.</p>')
            + (f'<h3>Open projects</h3><ul class="plan-shift">{projects}</ul>' if projects else "")
            + (f'<p class="muted small">{esc(" · ".join(c for c in counts if c))}</p>' if any(counts) else ""))


def build_shift_page(s, v, lr):
    done = [x for x in lr["shifts"] if not x.get("empty")]
    i = done.index(s)
    prev_l = f'<a href="{shift_href(done[i - 1])}">← Shift {done[i - 1]["n"]}</a>' if i else ""
    next_l = f'<a href="{shift_href(done[i + 1])}">Shift {done[i + 1]["n"]} →</a>' if i + 1 < len(done) else ""
    nav = f'<p class="shift-nav">{prev_l}<a href="/runs/long/">All shifts</a>{next_l}</p>'
    now = ""
    watch = (f'<p class="shift-watch"><a class="fx-btn" href="/videos/shift-{s["n"]}/">▶ Watch shift {s["n"]}</a> '
             f'<span class="muted small">{"with its timeline, the factory&#x27;s numbers and the chat beside the video" if R2.get(s["id"]) else "on this site"}</span></p>'
             if v or R2.get(s["id"]) else "")
    video = ""
    if v:
        watch = f"https://www.youtube.com/watch?v={esc(v['id'])}"
        chapters = "".join(f'<li><a href="{watch}&amp;t={int(c["at"])}s">{esc(c["time"])}</a> {esc(clean(c["title"]))}</li>'
                           for c in v.get("chapters") or [] if keep_line(c.get("title", "")))
        playlist = (f' · <a href="https://www.youtube.com/playlist?list={esc(v["playlist"])}">every shift</a>'
                    if v.get("playlist") else "")
        video = (f'{video_embed(v)}<p class="muted small"><a href="{watch}">Watch on YouTube</a>{playlist}{r2_link(s)}</p>'
                 f'<div class="shift-text">{description_html(v.get("description", ""))}</div>'
                 + (f'<h2>Chapters</h2><ol class="chapters">{chapters}</ol>' if chapters else ""))
    elif r2_link(s):
        video = f'<p class="muted small">{r2_link(s)[3:]}</p>'
    mine = [f for f in lr["firsts"] if f["shift"] == s["n"]]
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
{watch}
<div class="stats">{shift_stats(s)}</div>{replay_note(s)}
{video}
<h2>Milestones</h2>
{firsts_table(mine, shift_links=False)}
{f'<p><a href="/chronicle/#shift-{s["n"]}">This shift in the Chronicle</a>: the agents\' own account, beside the platforms built and lost.</p>' if s["n"] in lr.get("chronicle_shifts", ()) else ""}
{f'<h2>The hosts\' calls</h2><p class="muted small">Space Age moments, and research, attacks and losses that matter, as the hosts called them. Times Pacific.</p><ol class="chat calls">{calls}</ol>' if calls else ""}
{plan_html(s["plan"]) if s.get("plan") else ""}
{f'<h2>Technologies researched ({len(s["techs"])})</h2><ol class="techs">' + "".join(f'<li><span class="c-time">{esc(longrun.game_time(t["tick"]))}</span>{gameicons.tech(t["name"], 22)}{esc(t["label"])}</li>' for t in s["techs"]) + '</ol><p class="muted small">Game time of the first score row that shows each one.</p>' if s["techs"] else ""}
{long_charts(lr, lo - 1, hi + 1, x0=max(0, int(lo // 60) * 60))}
<div class="two-col shift-cols">
<section>{packs_bars(s["made"], "Packs made") or '<h2>Packs made</h2><p class="muted">None.</p>'}
{plat}</section>
<section><h2>Deaths</h2>{f'<p class="muted small">{", ".join(f"{esc(k)} {n}" for k, n in sorted(by.items(), key=lambda kv: -kv[1]))}</p><ol class="deaths">{deaths}</ol>' if deaths else '<p class="muted">None.</p>'}</section>
</div>
{f'<h2>Viewers</h2><p class="muted small">Viewer messages that reached the game, the agents\' answers that name the viewer, and the hosts\' answers. Times Pacific.</p>{qa_html(s["qa"], s["n"])}' if s["qa"] else ""}
{nav}
"""
    card = shift_card(s, lr)
    return page(f"Shift {s['n']}", body, "/runs/" if archive() else "/runs/long/",
                shift_summary(s, mine), path=shift_href(s), og=(card, f"/static/og/shift-{s['n']}.png") if card else None)


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


def platforms_table(plats, losses=None):
    """losses: {name: the harness's loss line} (site/chronicle.py platform_losses: where, what destroyed it, cargo)."""
    if not plats:
        return ""
    losses = losses or {}
    rows = "".join(
        f'<tr><th scope="row">{esc(p["name"])}</th>'
        f'<td data-l="Built">{esc(_pt(p["built"]))} <span class="muted">({esc(longrun.game_time(p["built_tick"]))}, '
        f'<a href="/runs/long/shift-{p["built_shift"]}/">shift {p["built_shift"]}</a>)</span></td>'
        f'<td data-l="Stopped at">{planet_icons(p["places"], 20) or "–"}</td>'
        f'<td data-l="Lost">' + (f'{esc(_pt(p["lost"]))} <span class="muted">({esc(longrun.game_time(p["lost_tick"]))}, '
                                 f'<a href="/runs/long/shift-{p["lost_shift"]}/">shift {p["lost_shift"]}</a>)</span>'
                                 + (f'<br><span class="small">{esc(clean(losses[p["name"]]))}</span>' if losses.get(p["name"]) else "")
                                 if p["lost"] else f'active{", at " + esc(p["at"].capitalize()) if p["at"] else ""}') + '</td></tr>'
        for p in plats)
    return (f'<h2 id="platforms">Space platforms</h2><div class="table-wrap"><table class="long-run platforms"><thead><tr>'
            f'<th scope="col">Platform</th><th scope="col">Built (Pacific)</th><th scope="col">Stopped at</th>'
            f'<th scope="col">Lost</th></tr></thead><tbody>{rows}</tbody></table></div>'
            f'<p class="muted small">From the score log every 2 minutes. Lost: gone from the game\'s platform list; where it '
            f'was, what destroyed it and the cargo lost as the harness read them at its hub\'s death (the '
            f'<a href="/chronicle/">Chronicle</a>).</p>')


def live_banner():
    """Shown by site.js only while the live API has a fresh state (the pages are built at shift changes)."""
    api = CONFIG.get("live_api_url") or ""
    return (f'<p class="live-banner" data-api="{esc(api)}" hidden><span class="fx-chip fx-chip--red">Live</span> '
            f'A shift is on now. <a href="/">Watch</a></p>') if api else ""


# the firsts worth a headline: (key, label); a "planet:" key takes the first planet reached
KEY_TIMES = [("pack:chemical-science-pack", "Blue science"), ("tech:rocket-silo", "Rocket silo"),
             ("rockets:1", "First rocket"), ("pack:space-science-pack", "Space science"), ("planet:", "First planet"),
             ("rockets:100", "100 rockets"), ("pack:promethium-science-pack", "Promethium science")]


def key_times(lr, heading='<h2 id="key-times">Key times</h2>'):
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
        tiles.append(f'<a class="keytime" href="/runs/long/shift-{f["shift"]}/"><span class="k-label">{gameicons.first_icon(f, 24)}{esc(name)}</span>'
                     f'<span class="k-val">{breakable(longrun.game_time(f["tick"]))}</span>'
                     f'<span class="k-sub">game time · {hm(on_air)} on stream · {esc(_pt(f["t"]))}</span></a>')
    return (f'{heading}<div class="keytimes">{"".join(tiles)}</div>') if tiles else ""


def packs_bars(made, title="Science packs made"):
    """Each pack's total as a bar (the pack's chart colour; the number in ink)."""
    have = [(item, lab, made.get(item, 0)) for item, lab in longrun.PACKS if made.get(item)]
    if not have:
        return ""
    top = max(v for _, _, v in have)
    items = "".join(f'<li><span class="bar-label">{gameicons.item(item, 22)}{esc(lab)}</span><span class="bar-track"><span class="bar" '
                    f'style="width:{100 * v / top:.1f}%;background:var({PACK_STYLE[item][0]})"></span></span>'
                    f'<span class="bar-val">{breakable(fmt_full(v))}</span></li>' for item, lab, v in have)
    return f'<figure class="bars packs-bars"><figcaption><strong>{esc(title)}</strong></figcaption><ul>{items}</ul></figure>'


def run_summary(lr):
    """The homepage's run so far (site.js / live.js put it under the heading while no shift is live): totals, key
    times, the latest milestones and the latest shift."""
    done = [s for s in lr["shifts"] if not s.get("empty")]
    last = done[-1]
    planets = sorted({p for s in done for p in s["planets"] if p != "nauvis"})
    stats = "".join([stat("shifts", fmt_full(len(done))), stat("game time", last["game1"]),
                     stat("technologies", fmt_full(last["research"]), icon=gameicons.item("lab", 28)),
                     stat("rockets", f'{last["rockets"]:,}', icon=gameicons.item("rocket-part", 28)),
                     stat("science packs", f'{sum(lr["made"].values()):,}', icon=gameicons.item("automation-science-pack", 28)),
                     stat("planets reached", len(planets), sub_html=planet_icons(planets))])
    latest = list(reversed(lr["firsts"][-6:]))
    items = "".join(f'<li>{gameicons.first_icon(f, 28)}<span><a href="/runs/long/shift-{f["shift"]}/">{esc(f["label"])}</a>'
                    f'<span class="muted small">{esc(longrun.game_time(f["tick"]))} · {esc(_pt(f["t"]))} · shift {f["shift"]}</span></span></li>'
                    for f in latest)
    return f"""
<section id="run-summary" class="run-summary" aria-labelledby="sum-h">
  <h2 id="sum-h">The run so far</h2>
  <p class="meta">Up to <a href="{shift_href(last)}">shift {last["n"]}</a>, {esc(_pt(last["ended"]))} Pacific</p>
  <div class="stats stats-compact">{stats}</div>
  <div class="sum-cols">
    <div>{key_times(lr, '<h3>Key times</h3>')}</div>
    <div><h3>Latest milestones</h3><ul class="latest">{items}</ul>
      <p><a class="fx-btn" href="/runs/long/">The whole run →</a> <a class="fx-btn ghost" href="{shift_href(last)}">Shift {last["n"]} →</a>{' <a class="fx-btn ghost" href="/videos/">Every shift on video →</a>' if VIDEOS or R2 else ""}</p></div>
  </div>
</section>"""


def records(done):
    """Bests over the shifts (a shift still on counts with what it has so far)."""
    def best(key, fmt, low=False):
        have = [s for s in done if s.get(key) is not None]
        if not have:
            return None
        s = (min if low else max)(have, key=lambda x: x[key])
        return fmt(s[key]), s
    out = []
    for lab, key, fmt, low, ico in [("Most rockets in a shift", "rockets_new", lambda v: f"{v:,}", False, "rocket-part"),
                                    ("Most technologies in a shift", "research_new", fmt_full, False, "lab"),
                                    ("Best SPM (shift average)", "spm", fmt_full, False, "automation-science-pack"),
                                    ("Most packs made in a shift", "made_total", lambda v: f"{v:,}", False, "space-science-pack"),
                                    ("Most viewer messages in a shift", "viewer_lines", fmt_full, False, ""),
                                    ("Fewest deaths in a shift", "deaths", fmt_full, True, "")]:
        b = best(key, fmt, low)
        if b and (low or b[1][key]):
            out.append(f'<a class="record" href="{shift_href(b[1])}"><span class="r-val">{breakable(b[0])}</span>'
                       f'<span class="r-label">{gameicons.item(ico, 24) if ico else ""}<span>{esc(lab)}</span></span><span class="r-shift">Shift {b[1]["n"]}</span></a>')
    return f'<div class="records">{"".join(out)}</div>' if out else ""


def build_long_run(lr):
    shifts = lr["shifts"]
    done = [s for s in shifts if not s.get("empty")]
    first, last = done[0], done[-1]
    planets = sorted({p for s in done for p in s["planets"] if p != "nauvis"})
    active = [p for p in lr["platforms"] if not p["lost"]]
    lost_p = [p for p in lr["platforms"] if p["lost"]]
    on_air = sum(_hours(s["started"], s["ended"]) for s in done)
    stats = "".join([stat("shift" if len(done) == 1 else "shifts", fmt_full(len(done))),
                     stat("on stream", hm(on_air)),
                     stat("game time", last["game1"]),
                     stat("technologies", fmt_full(last["research"]), f'researching {last["researching"]}' if last.get("researching") else "",
                          icon=gameicons.item("lab", 28)),
                     stat("rockets", f'{last["rockets"]:,}', icon=gameicons.item("rocket-part", 28)),
                     stat("science packs", f'{sum(lr["made"].values()):,}', icon=gameicons.item("automation-science-pack", 28)),
                     stat("platforms built", fmt_full(len(lr["platforms"])), f'{len(lost_p):,} lost · {len(active):,} active',
                          icon=gameicons.item("space-platform-hub", 28)),
                     stat("planets reached", len(planets), sub_html=planet_icons(planets)),
                     stat("agent deaths", fmt_full(sum(s["deaths"] for s in done))),
                     stat("viewer messages", f'{sum(s["viewer_lines"] for s in done):,}')])
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
        ms = "".join(f"<li>{gameicons.first_icon(f, 18)}{esc(f['label'])}</li>" for f in notable[:5])
        more = f'<li class="muted"><a href="{shift_href(s)}">+{len(firsts) - len(notable[:5])} more</a></li>' if len(firsts) > len(notable[:5]) else ""
        video = (f' <a class="fx-chip" href="/videos/shift-{s["n"]}/" title="Watch shift {s["n"]}">▶ video</a>'
                 if shift_video(s) or R2.get(s["id"]) else "")
        now = ""
        rows.append(
            f'<tr><th scope="row"><a href="{shift_href(s)}">Shift {s["n"]}</a>{rid}{now}{video}</th>'
            f'<td data-l="When">{esc(_when(s["started"], s["ended"]))}</td>'
            f'<td data-l="Game time">{esc(s["game0"])} to {esc(s["game1"])}</td>'
            f'<td data-l="Technologies" class="num">{s["research"]} <span class="muted">+{s["research_new"]}</span></td>'
            f'<td data-l="SPM" class="num">{"–" if s["spm"] is None else fmt_num(s["spm"])}</td>'
            f'<td data-l="Packs made" class="num">{s["made_total"]:,}</td>'
            f'<td data-l="Rockets" class="num">{s["rockets"]} <span class="muted">+{s["rockets_new"]}</span></td>'
            f'<td data-l="Deaths / losses" class="num">{s["deaths"]} / {s["losses"]}</td>'
            f'<td data-l="Viewers" class="num">{s["viewer_lines"]}</td>'
            f'<td data-l="Milestones">{f"<ul class=moments>{ms}{more}</ul>" if ms or more else ""}</td></tr>')
    crumbs = '<p class="crumbs"><a href="/runs/">Runs</a> / The long run</p>' if archive() else ""
    vids = [(s, shift_video(s)) for s in shifts if shift_video(s)]
    if len(vids) > 3:  # every shift's embed is too many for one page: the public ones, and /videos/ for the rest
        pub = videos_page.public_shifts(VIDEOS)
        vids = [(s, v) for s, v in vids if s["n"] in pub]
    videos = "".join(
        f'<article class="shift-video"><h3><a href="{shift_href(s)}">Shift {s["n"]}</a></h3>{video_embed(v)}'
        f'<p class="muted small">{esc(clean(v.get("title", "")))}</p></article>' for s, v in vids)
    videos = (f'<h2 id="videos">Shift videos</h2><p><a class="fx-btn" href="/videos/">Every shift on video →</a></p>'
              f'<div class="shift-videos">{videos}</div>') if vids else ""
    body = f"""
{crumbs}
{live_banner()}
<h1>The long run</h1>
<p class="meta">One save · started {esc(_pt(first["started"]))} Pacific · game clock paused between shifts</p>
<nav class="jump" aria-label="On this page">{'<a href="#key-times">Key times</a>' if key_times(lr) else ""}<a href="#records">Records</a><a href="#milestones">Milestones</a>{'<a href="#platforms">Platforms</a>' if lr["platforms"] else ""}<a href="#charts">Charts</a><a href="#shifts">Shifts</a>{'<a href="#videos">Videos</a>' if vids else ""}</nav>
<div class="stats stats-compact">{stats}</div>
{journey(lr)}
{key_times(lr)}
<h2 id="records">Records</h2>
{records(done)}
<h2 id="milestones">Milestones</h2>
{firsts_table(lr["firsts"], filters=True)}
{platforms_table(lr["platforms"], lr.get("platform_losses"))}
<h2 id="charts">Charts</h2>
<p class="muted small">Game time on the x axis; the strip under it marks shift starts (S1, S2 ...). Hover or tap a chart for exact values and the Pacific time; each one has its data as a table.</p>
{long_charts(lr)}
{packs_bars(lr["made"])}
<h2 id="shifts">Shifts</h2>
<div class="table-wrap"><table class="long-run wide"><thead><tr><th scope="col">Shift</th><th scope="col">When (Pacific)</th>
<th scope="col">Game time</th><th scope="col">Technologies</th><th scope="col">SPM</th><th scope="col">Packs made</th>
<th scope="col">Rockets</th><th scope="col">Deaths / losses</th><th scope="col">Viewers</th><th scope="col">Milestones</th>
</tr></thead><tbody>{"".join(rows)}</tbody></table></div>
<p class="muted small">SPM: research units a minute (the labs' use of packs in sets) over the shift's game time. Packs made: each counter's rises between score rows; a fall (a lost platform's counts) is not subtracted. Deaths and loss alerts: the ones the stream's director cut to.</p>
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
    links = "".join(f'<a class="home-card" href="{href}"><h3>{esc(t)}</h3><p class="muted">{esc(d)}</p></a>'
                    for href, t, d in cards)
    body = live_app(CONFIG.get("site_title", "Player of Games"), "/?demo=1", VIDEO_STRIP) + (run_summary(LONG) if LONG else "") + f"""
<section class="home-more" aria-labelledby="more-h">
  <h2 id="more-h">The project</h2>
  <p class="lede">AI agents playing Factorio together, by the same rules as you: no spawned items, no teleporting,
  walking and building at a player's speed, talking in game chat. Shifts run through the night on one world.</p>
  <div class="home-cards">{links}</div>
</section>
"""
    return page(CONFIG.get("site_title", "Factorio AI Party"), body, "/", CONFIG.get("description", ""), extra_head=LIVE_HEAD, path="/")


RULES_ALLOWED = ["Walking at character speed", "Mining and crafting at real speed, with a real inventory",
                 "Placing, inserting and taking within reach", "Setting the research queue", "Blueprints the team designed itself",
                 "Construction robots, once researched", "Writing their own scripts on top of the honest actions"]
RULES_BANNED = ["Creating items or buildings from nothing", "Teleporting", "Seeing map areas nobody has explored",
                "Changing the game speed of the live world", "Console commands, Lua, or talking to the server directly",
                "Modifying the harness or the mod"]


def build_about_compact():
    """The public About: numbers, how it works as labelled facts, the rules, the team. Present tense, no history."""
    team = "".join(f'<li class="team-member" style="--ac:{agent_pages.ac(agent(k)["color"])}">{avatar(k, "lg")}<div><strong>{esc(agent(k)["name"])}</strong>'
                   f'<span>{esc(agent(k)["model"])}</span><span class="muted">{esc(agent(k)["harness"])}</span></div></li>'
                   for k in CONTENT["team_order"])
    labs = sorted({agent(k)["maker"] for k in CONTENT["team_order"] if agent(k).get("maker")})
    nums = [stat("agents", len(CONTENT["team_order"])), stat("labs", len(labs), ", ".join(labs))]
    if LONG:
        done = [x for x in LONG["shifts"] if not x.get("empty")]
        last = done[-1]
        nums += [stat("shifts", fmt_full(len(done))), stat("on stream", hm(sum(_hours(x["started"], x["ended"]) for x in done))),
                 stat("game time", last["game1"]), stat("technologies", fmt_full(last["research"])), stat("rockets", fmt_full(last["rockets"])),
                 stat("viewer messages", fmt_full(sum(x["viewer_lines"] for x in done)))]
    facts = [
        ("Players", "9 models from 5 labs, each in its own coding harness (Codex, Claude Code, Grok Build, Antigravity, "
                    "Muse Code). Same instructions apart from name and model."),
        ("Controls", "One command-line tool, fh: more than 180 actions (look, walk, mine, craft, build, queue a plan, chat)."),
        ("Game", "Factorio 2.0.77 with Space Age, Quality and Elevated Rails. A small mod runs each action tick by tick, "
                 "under survival rules."),
        ("Clock", "Real time: the game runs while the agents think. Shifts of about 4 hours; the game is paused between "
                  "shifts."),
        ("Goal", "The Shattered Planet, at the far end of the Space Age tree. The agents set their own milestones."),
        ("Teamwork", "Game chat, and a shared board of claims, requests and the team plan. No assigned leader or roles."),
        ("Stream", "Director cameras follow the action; two AI hosts call the game; agents speak some lines aloud."),
        ("Viewers", "YouTube chat or the site chat on the live page, no account. Moderated, then into the game chat, "
                    "marked as a viewer. @name gets an agent's attention. The agents can vote to mute a viewer."),
    ]
    dl = "".join(f'<div><dt{' id="talk"' if k == "Viewers" else ""}>{esc(k)}</dt><dd>{esc(v)}</dd></div>' for k, v in facts)
    run_btn = ' <a class="fx-btn ghost" href="/runs/long/">The run so far</a>' if LONG else ""
    body = f"""
<section class="hero">
  <p class="eyebrow">Live on YouTube</p>
  <h1>AI agents playing Factorio together, by the same rules as you.</h1>
  <p class="actions"><a class="fx-btn" href="/">Watch live →</a>{run_btn}</p>
  <div class="stats stats-compact">{"".join(nums)}</div>
</section>
<section>
  <h2>How it works</h2>
  <dl class="facts">{dl}</dl>
  <p><a href="/how/">How it was made →</a> The machines, the harness, the agents, how the project is run, what we
  learned and how it compares with other Factorio harnesses, in depth.</p>
  <p><a href="https://github.com/nwinter/factorio-ai-party">Source on GitHub →</a> The harness, the stream, this site and the
  operator's scripts, MIT licensed, with account details and run logs left out.</p>
</section>
<section class="fair">
  <h2>Fair-play rules</h2>
  <div class="two-col">
    <div><h3>Allowed</h3><ul class="ticks">{"".join(f"<li>{esc(r)}</li>" for r in RULES_ALLOWED)}</ul></div>
    <div><h3>Not allowed</h3><ul class="crosses">{"".join(f"<li>{esc(r)}</li>" for r in RULES_BANNED)}</ul></div>
  </div>
  <p class="muted small">Enforced in the mod, audited from the logs. An operator fix for a harness bug is announced in chat and logged.</p>
</section>
<section>
  <h2 id="team">The team</h2>
  <p class="muted small">Names and colours chosen by each agent.</p>
  <ul class="team">{team}</ul>
</section>
<section id="credits">
  <h2>Credits</h2>
  <p>Factorio and Factorio: Space Age are games by <a href="https://factorio.com/" rel="noopener">Wube Software</a>.
  {gameicons.CREDIT}: the game's icons and pictures on this site are used with Wube's permission for a free,
  non-commercial project.</p>
</section>
"""
    return page("About", body, "/about/", CONFIG.get("description", ""), path="/about/")


def build_about(runs, all_worlds):
    """What the show is, how it works, the rules, the team, how to talk to the agents. With the archive it also has
    the test history (results, the latest run, links to the experiments); without it, the compact present-tense
    page (build_about_compact)."""
    arch = archive()
    if not arch:
        return build_about_compact()
    team = []
    for k in CONTENT["team_order"]:
        a = agent(k)
        name = f'<a href="/agents/{k}/"><strong>{esc(a["name"])}</strong></a>' if arch else f'<strong>{esc(a["name"])}</strong>'
        team.append(f'<li class="team-member" style="--ac:{agent_pages.ac(a["color"])}">{avatar(k, "lg")}<div>{name}'
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
  <p class="actions"><a class="fx-btn" href="/">Watch live →</a>{run_btn} <a class="fx-btn ghost" href="/how/">How it was made</a> <a class="fx-btn ghost" href="{GITHUB_URL}">Source on GitHub</a></p>"""
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
{history}
<section id="credits">
  <h2>Credits</h2>
  <p>Factorio and Factorio: Space Age are games by <a href="https://factorio.com/" rel="noopener">Wube Software</a>.
  {gameicons.CREDIT}: the game's icons and pictures on this site are used with Wube's permission for a free,
  non-commercial project.</p>
</section>
"""
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
            f'<div class="agent-head" style="--ac:{agent_pages.ac(a["color"])}">{avatar(key, "xl")}<div><h1>{esc(a["name"])}</h1>'
            f'<p class="model">{esc(a["model"])} · {esc(a["harness"])}</p>'
            f'{f"<p class=motto>“{esc(motto)}”</p>" if motto else ""}</div></div>')
    # active=None: agent pages belong to no nav section, so nothing is highlighted
    return page(a["name"], head + '<div class="agent-runs" style="--ac:' + agent_pages.ac(a["color"]) + '">' + "".join(rows) + "</div>", None,
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


LIVE_HEAD = ('<script src="/static/avatar.js" defer></script>\n<script src="/static/mapview.js" defer></script>\n'
             '<script src="/static/live.js" defer></script>\n<script src="/static/polls.js" defer></script>')


def live_app(heading, sample_href, below_player=""):
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
  <p class="live-head-meta"><span id="live-badge" class="fx-chip fx-chip--grey">Offline</span> <span id="watching" class="small" hidden></span> <span id="updated" class="muted small"></span></p>
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
      <button class="fx-tab is-selected" role="tab" aria-selected="true" data-tab="site" type="button">Chat</button>
      <button class="fx-tab" role="tab" aria-selected="false" data-tab="yt" type="button">YouTube</button>
    </div>
    <div class="fx-tab-body">
      <div data-pane="site" class="vchat-pane">
        <div class="vchat-filter fx-muted small"><label><input type="checkbox" id="vchat-replies" checked> Show agents' replies to viewers</label>
          <span id="vchat-host" class="vchat-host" hidden>Signed in as host <button class="fx-btn fx-btn--small" type="button" id="vchat-host-forget">Forget</button></span></div>
        <ol id="vchat" class="vchat" aria-live="polite"></ol>
        <form id="vchat-form" class="vchat-form" autocomplete="off">
          <input class="fx-textfield" name="name" maxlength="20" placeholder="Name" aria-label="Your name (blank: a guest name)" title="Blank: you post as Guest and four letters or digits, the same each time">
          <input class="fx-textfield" name="text" maxlength="500" placeholder="Say something" aria-label="Message" required>
          <button class="fx-btn" type="submit">Send</button>
          <label class="vchat-viewers fx-muted small"><input type="checkbox" name="viewers"> Viewers only: not sent to the agents</label>
        </form>
        <p id="vchat-note" class="fx-muted small" aria-live="polite"></p>
        <details class="vchat-help fx-muted small">
          <summary>How chat works</summary>
          <dl class="vchat-tips fx-muted small">
            <div><dt>@astra</dt><dd>that agent answers (any agent's name)</dd></div>
            <div><dt>No name</dt><dd>the next agent in turn</dd></div>
            <div><dt>@operator</dt><dd>harness suggestions: read, maybe built; your line says "delivered to the Operator" once it is in the Operator's inbox and "Operator replied" when they answer (click it for the reply)</dd></div>
            <div><dt>Labels</dt><dd>"queued": not read yet (between shifts it waits for the next one); "delivered to" the agents or the Operator; "expired": waited over 30 minutes for the agents (a line to the Operator still reaches them), with why</dd></div>
            <div><dt>Several</dt><dd>one per person into the game at a time, up to 3 wait their turn</dd></div>
            <div><dt>Rules</dt><dd>no account, no links, be kind</dd></div>
            <div><dt>HOST</dt><dd>the stream's host, from their own YouTube channel or the site's host link</dd></div>
            <div><dt>VIEWERS</dt><dd>a viewers-only line: here on the site only, never sent to the agents or shown on the stream; tick "Viewers only" to write one</dd></div>
            <div><dt>YT · SITE</dt><dd>YouTube and site comments in one list, in time order; you write as a site comment</dd></div>
            <div><dt>REPLY</dt><dd>an agent or the Operator answering a viewer in the game chat, in its colour, under the line it answers; untick above to hide</dd></div>
          </dl>
        </details>
      </div>
      <div data-pane="yt" class="yt-pane" hidden>
        <p class="fx-muted">YouTube chat appears here once the stream is set up.</p>
      </div>
    </div>
  </aside>
</div>
<section id="polls" class="polls-card fx-root fx-panel live-panel" data-mode="card" data-api="{esc(api)}" aria-label="Poll" hidden><div class="polls-list"></div></section>
{below_player}
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


def build_polls():
    """/polls/: the open and closed polls with their comments, and a form for a viewer's poll idea (static/polls.js,
    the live API's /v1/polls; Nick, d16 17:15)."""
    api = CONFIG.get("live_api_url") or ""
    opts = "".join(f'<input class="fx-textfield" name="option{i}" maxlength="100" placeholder="Option {i}"'
                   f'{" required" if i <= 2 else ""} aria-label="Option {i}">' for i in range(1, 7))
    body = f"""
<h1>Polls</h1>
<p class="lede">The operator opens polls on questions about the run; anyone can vote here, once per poll (a later vote
replaces the earlier one), with an optional comment. Results show after you vote and when a poll closes.</p>
<section id="polls" class="polls-page" data-mode="page" data-api="{esc(api)}"><div class="polls-list"><p class="muted">Loading the polls…</p></div></section>
<section class="poll-idea-box">
<h2>Suggest a poll</h2>
<p class="muted small">A question and 2 to 6 answers. Ideas go to the operator only, who decides whether to run them.
No links; chat's rules apply.</p>
<form id="poll-idea" class="poll-idea" autocomplete="off">
  <input class="fx-textfield" name="name" maxlength="20" placeholder="Name" aria-label="Your name (blank: a guest name)" title="Blank: you post as Guest and four letters or digits, the same each time">
  <input class="fx-textfield" name="question" maxlength="200" placeholder="Question" aria-label="Question" required>
  <div class="poll-idea-opts">{opts}</div>
  <input class="fx-textfield" name="hours" type="number" min="1" max="72" step="1" placeholder="Hours open (optional)" aria-label="Hours open">
  <button class="fx-btn" type="submit">Send the idea</button>
  <p class="poll-idea-note small muted" aria-live="polite"></p>
</form>
</section>
"""
    return page("Polls", body, "/polls/", "Vote on questions about the run, and suggest a poll.",
                extra_head='<script src="/static/polls.js" defer></script>', path="/polls/")


def build_live():
    return page("Live", live_app("Live", "/live/?demo=1"), "/", "Watch the run: stream, chat and the team's live status.",
                extra_head=LIVE_HEAD, path="/live/")


FAVICON = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#e39827"/>
<path d="M16 7l2.2 3.1 3.7-.9.4 3.8 3.5 1.5-1.9 3.3 1.9 3.3-3.5 1.5-.4 3.8-3.7-.9L16 28l-2.2-3.1-3.7.9-.4-3.8-3.5-1.5L8.1 17.2 6.2 13.9l3.5-1.5.4-3.8 3.7.9z" fill="#1d1a16"/>
<circle cx="16" cy="17.5" r="4" fill="#e39827"/></svg>"""


ASSET_REF = re.compile(r'((?:src|href)=")(/static/[\w./-]+\.(?:js|css))(")')


def version_assets(out):
    """Stamp every page's local script and stylesheet links with a hash of the built file (`/static/live.js?v=1a2b3c4d5e`).
    The host serves /static/ with a 4-hour browser cache, so after a deploy a plain reload kept the old live.js (viewer
    joonazan, 2026-10-15 09:17: the double-post fix had not reached him); a new hash is a new URL."""
    import hashlib
    stamps = {}

    def stamp(m):
        path = m.group(2)
        if path not in stamps:
            f = out / path.lstrip("/")
            stamps[path] = hashlib.sha1(f.read_bytes()).hexdigest()[:10] if f.is_file() else None
        v = stamps[path]
        return m.group(1) + (f"{path}?v={v}" if v else path) + m.group(3)

    for p in out.rglob("*.html"):
        t = p.read_text()
        n = ASSET_REF.sub(stamp, t)
        if n != t:
            p.write_text(n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(SITE / "dist"))
    ap.add_argument("--runs-dir", default=str(REPO / "runs"),
                    help="where the long run's shift folders are (default: the repo's runs/; read-only)")
    ap.add_argument("--content", default=os.environ.get("POG_SITE_CONTENT"),
                    help="another site.json (tests: the archive switch and run_start; default $POG_SITE_CONTENT)")
    # (batch265) the video data only when named (tools/site-refresh.sh names site/content/videos.json, r2.json and
    # site/og/thumbs): a test's build never picks up the files the live checkout has
    ap.add_argument("--videos", help="the shifts' YouTube videos (site/content/videos.json: tools/yt_archive.py; "
                    "none: no videos)")
    ap.add_argument("--r2",
                    help="the shifts that play on R2 (site/content/r2.json: site/videos_page.py refresh; none: none)")
    ap.add_argument("--public-status", help="the public repo sync's status.json (tools/public-push.sh; the Updates page "
                    "shows it; none: not shown)")
    ap.add_argument("--thumbs", help="the shifts' thumbnails, shift-N.jpg (site/og/thumbs: site/videos_page.py refresh)")
    ap.add_argument("--stats-cache", help="where tools/agent_stats.py caches each shift (default: the shift's folder)")
    args = ap.parse_args()
    # (d24 batch186) a test run (POG_TEST=1) builds from its own runs folder: the gate runs the tests in the live
    # checkout, where the repo's runs/ is the live run's and the stats caches land in its shift folders
    if os.environ.get("POG_TEST") == "1" and os.path.realpath(args.runs_dir) == os.path.realpath(REPO / "runs"):
        raise SystemExit("POG_TEST=1: build.py needs --runs-dir (not the repo's runs/) in a test run")
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
    LONG = load_long(args.runs_dir)
    # the team's blueprint library, as the newest shift's copy holds it (tools/bplibrary.py; viewer Foobator)
    global BLUEPRINTS
    BLUEPRINTS = bp_pages.latest(LONG, args.runs_dir) if LONG else None
    if CONTENT.get("run_start") and not LONG:
        print(f"note: run_start {CONTENT['run_start']} not found in {args.runs_dir}: no run page", file=sys.stderr)

    def write(rel, text):
        p = out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    thumbs, helpers = {}, {"esc": esc, "clean": clean, "keep_line": keep_line, "pt": _pt, "hours": _hours,
                            "shift_href": shift_href, "video_offset": video_offset, "game_time": longrun.game_time,
                            "live_banner": live_banner}
    if LONG:
        global VIDEOS, R2, VIDEO_STRIP
        VIDEOS = load_videos(args.videos) if args.videos else {}
        R2 = load_r2(args.r2) if args.r2 else {}
        for s in LONG["shifts"]:  # the shift thumbnails (site/videos_page.py refresh), for /videos/ and the homepage
            jpg = Path(args.thumbs or "/nonexistent") / f"shift-{s['n']}.jpg"
            if args.thumbs and not s.get("empty") and jpg.is_file():
                (out / "static" / "thumbs").mkdir(parents=True, exist_ok=True)
                shutil.copy(jpg, out / "static" / "thumbs" / jpg.name)
                thumbs[s["n"]] = jpg.name
        if VIDEOS or R2:
            VIDEO_STRIP = videos_page.home_strip(LONG, VIDEOS, R2, thumbs, helpers)
    write("index.html", build_home(runs, all_worlds))
    if LONG:
        LONG["platform_losses"] = chron.platform_losses(LONG, args.runs_dir)  # the platform table's loss details
        LONG["chronicle_shifts"] = {c["n"] for c in chron.by_shift(LONG, args.runs_dir, clean, keep_line)}  # shift pages link it
        lapse = timelapse.frames(LONG, args.runs_dir, game_time)  # site/timelapse.py: the base over time
        if lapse:
            # with the terrain frames (site/terrain.py): each snapshot draws those up to its tick
            for src, text in timelapse.data(lapse, terrain.terrain_frames(args.runs_dir, LONG)).items():
                write(src.lstrip("/"), text)
        write("runs/long/index.html", timelapse.inject(build_long_run(LONG), timelapse.section(lapse, esc)))
        terrain.publish(out, args.runs_dir, LONG)
        chartpub.publish(out, args.runs_dir, LONG)
        for s in LONG["shifts"]:
            if not s.get("empty"):
                write(f"runs/long/shift-{s['n']}/index.html", build_shift_page(s, shift_video(s), LONG))
                card = shift_card(s, LONG)
                if card:
                    (out / "static" / "og").mkdir(parents=True, exist_ok=True)
                    shutil.copy(card, out / "static" / "og" / f"shift-{s['n']}.png")
        team =[k for k in AGENTS if not AGENTS[k].get("earlier")]
        stats = agent_pages.collect(LONG, args.runs_dir, team, args.stats_cache, [agent(k)["name"] for k in AGENTS])
        body, head = agent_pages.build_agents(stats, agent, avatar, esc, CONFIG.get("live_api_url"))
        write("agents/index.html", page("Agents", body, "/agents/", "Each agent's numbers across the run's shifts.",
                                        extra_head=head, path="/agents/"))
        events = agent_pages.timeline_events(LONG, args.runs_dir, team,
                                             lambda t: longrun.MILESTONES.get(t, t.replace("-", " ")).capitalize(), stats,
                                             platforms=chron.timeline_rows(LONG, args.runs_dir))
        body, head = agent_pages.build_timeline(events, agent, avatar, esc, game_time)
        write("timeline/index.html", page("Timeline", body, "/timeline/", "The run's events in game time.",
                                          extra_head=head, path="/timeline/"))
        if VIDEOS or R2:  # /videos/ and a player page per shift with a video (site/videos_page.py)
            write("videos/index.html", page("Every shift on video", videos_page.build_page(LONG, VIDEOS, R2, thumbs, helpers),
                                            "/videos/", "Every shift of the run on video, in order, with chapters and "
                                            "the moments to watch.", path="/videos/"))
            # the timeline's rows by shift, with their /timeline/#eN anchors, for the player's events card
            rows = {}
            for i, (tick, n, kind, text, who) in enumerate(events):
                rows.setdefault(n, []).append((tick, kind, f"{agent(who)['name']} died" if who else text, i, who))
            shelf = videos_page.Shelf(LONG, VIDEOS, R2, thumbs, helpers)
            for n in shelf.watchable:
                body, head = videos_page.build_watch(n, LONG, VIDEOS, R2, thumbs, helpers, rows.get(n, []), video_embed)
                write(f"videos/shift-{n}/index.html",
                      page(f"Shift {n} on video", body, "/videos/", f"Shift {n} of the run on video: "
                           f"{shelf.title(n) or 'four hours of nine AI agents building one factory'}.", extra_head=head,
                           path=f"/videos/shift-{n}/", og=(lambda c: (c, f"/static/og/shift-{n}.png") if c else None)(
                               shift_card(shelf.by_n[n], LONG))).replace("<body>", '<body class="watch">', 1))
        # the run's chronicle: the agents' entries beside the harness's record (viewers Alex and syndesis 22:24)
        body, head = chron.build_page(chron.by_shift(LONG, args.runs_dir, clean, keep_line), agent, avatar, esc, game_time, team)
        write("chronicle/index.html", page("Chronicle", body, "/chronicle/",
                                           "The run's story in the agents' own words, beside the platforms built and lost.",
                                           extra_head=head, path="/chronicle/"))
        chat_lines = highlights.lines(stats, team, clean, keep_line)
        body, head = highlights.build_chat(chat_lines, agent, avatar, esc, game_time, team, highlights.load_moments(clean))
        write("chat/index.html", page("Chat highlights", body, "/chat/", "The agents' lines on stream and their confessions.",
                                      extra_head=head, path="/chat/"))
        if BLUEPRINTS:
            body, head = bp_pages.build_page(BLUEPRINTS, agent, avatar, esc, game_time, team, CONFIG.get("live_api_url") or "")
            write("blueprints/index.html", page("Blueprints", body, "/blueprints/",
                                                "The team's shared blueprint library, with each blueprint string to import.",
                                                extra_head=head, path="/blueprints/"))
        entries = site_search.index(LONG, stats, events, chat_lines, agent, game_time, team)
        write("search/index.json", json.dumps(entries, ensure_ascii=False, separators=(",", ":")))
        body, head = site_search.build_search(entries, esc)
        write("search/index.html", page("Search", body, "/search/", "Search the agents, shifts, events and chat.",
                                        extra_head=head, path="/search/"))
    write("about/index.html", build_about(runs, all_worlds))
    _title = CONFIG.get("site_title", "Factorio AI Party")  # the privacy policy and terms (site/legal.py, d23)
    write("privacy/index.html", page("Privacy policy", legal.privacy_body(esc(_title)), "/privacy/",
                                     "What the Factorio AI Party site collects (very little) and how it is used.", path="/privacy/"))
    write("terms/index.html", page("Terms of service", legal.terms_body(esc(_title)), "/terms/",
                                   "The terms for using the Factorio AI Party site, chat and stream.", path="/terms/"))
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
    write("polls/index.html", build_polls())
    if updates_nav():  # the operator's changes, what each asking message said and the operator's replies (CB4)
        data = op_updates.load(UPDATES)
        for line in op_updates.problems(data):  # built anyway: the operator's live data
            print("updates:", line, file=sys.stderr)
        hidden = moderation.load(args.runs_dir, os.environ.get("POG_HIDDEN_VIEWERS") or SITE / "hidden-viewers.json")
        asks, replies = op_updates.messages(args.runs_dir, op_updates.refs(data["updates"]), clean, keep_line, hidden)
        built = datetime.datetime.now(op_updates.PACIFIC).replace(tzinfo=None)
        public = None   # (batch290) tools/public-push.sh's status.json, only when named (tools/site-refresh.sh)
        if args.public_status:
            try:
                public = json.loads(Path(args.public_status).read_text())
            except (OSError, ValueError) as e:
                print(f"updates: public status {args.public_status}: {e}", file=sys.stderr)
        body, head = op_updates.build_page(data, asks, replies, esc, built=built, public=public, github=GITHUB_URL)
        write("updates/index.html", page("Operator updates", body, "/updates/",
                                         "Changes viewers and agents asked for, and whether each is planned, in progress, live or verified.",
                                         extra_head=head, path="/updates/"))
        # (d24 batch159 QB1) what the open page rechecks every few minutes (static/updates.js)
        full = op_updates.updates_json(data, asks, replies, esc, built=built)
        write("updates/updates.json", json.dumps(full, ensure_ascii=False))
        write("updates/stamp.json", json.dumps(op_updates.stamp_json(full)))
    shutil.copy(SITE / "live" / "state.example.json", out / "live" / "state.example.json")
    write("live/status.json", public_status(json.loads((SITE / "live" / "status.json").read_text())))
    how_pages.build(out, page, markdown, esc)  # after the rest, so its links to the site's pages resolve
    lost = [("/", "The live show"), ("/runs/long/", "The run so far"), ("/videos/", "Every shift on video"),
            ("/search/", "Search"), ("/about/", "About the project")]
    have = {h for h, _ in nav_items()} | {"/"}
    write("404.html", page("Not found", '<h1>Not found</h1><p class="lede">That page doesn\'t exist, or it moved.</p><ul class="lost">'
                           + "".join(f'<li><a href="{h}">{esc(t)}</a></li>' for h, t in lost if h in have) + "</ul>", None))
    for f in (SITE / "static").iterdir():
        if not f.is_file() or f.name.startswith("."):
            continue  # only the site's own files (not editor or tool folders)
        (out / "static").mkdir(exist_ok=True)
        shutil.copy(f, out / "static" / f.name)
    if gameicons.GAME.is_dir():  # the game's icons (tools/game_icons.py)
        shutil.copytree(gameicons.GAME, out / "static" / "game", dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".*", "README.md"))
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
    version_assets(out)

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
