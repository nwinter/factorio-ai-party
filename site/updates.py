"""Operator updates on the site (d23 batch119 CB4, viewer Aurora site:4349: "Could the site have an Operator updates
section with a permanent history of harness and site changes, their current status, and links to the original
messages?" and site:4350: "Please distinguish planned, in progress, live and verified updates, keep unresolved items
visible, and separate automatic status notices from change announcements.").

The data is site/content/operator-updates.json (tools/operator_updates.py adds rows and moves them on, or edit it by
hand): each change with who asked (a site message id, site:NNNN, or a board item, #NNNN), its status, when it reached
each status, and a note; and the notices (deploys, restarts, rests, outages) apart from the changes. At build time the
asking message's text and the operator's replies come from the run folders (runs/*/operator-inbox.jsonl by id,
runs/*/operator-replies.jsonl by `to`), through the site's redaction and filters, so the page keeps them after the
chat has moved on. For build.py:
- load(): the rows, checked (a bad row stops the build with its id);
- messages(): the asks and the replies the rows name;
- build_page(): the /updates/ page: the counts, then everything not yet verified (in progress, planned, live), then
  the verified ones, newest first, then the notices.
"""
import datetime
import json
from pathlib import Path

STATUSES = ("planned", "in progress", "live", "verified")
OPEN_ORDER = ("in progress", "planned", "live")  # not yet verified: the work under way first
CHIP = {"planned": "fx-chip--grey", "in progress": "fx-chip--orange", "live": "fx-chip--blue", "verified": "fx-chip--green"}
WHAT = {"planned": "accepted, not started", "in progress": "an engineer is on it, or it waits for the merge gate",
        "live": "merged and deployed", "verified": "checked working in the game or on the site after it went live"}
AREAS = ("harness", "stream", "site")
NOTICE_KINDS = ("deploy", "restart", "rest", "outage", "shift")
DATE_KEYS = ("asked",) + STATUSES
FMT = "%Y-%m-%d %H:%M"
try:
    from zoneinfo import ZoneInfo
    PACIFIC = ZoneInfo("America/Los_Angeles")
except Exception:  # no tz database: the build machine's local time (the Mac runs on Pacific time)
    PACIFIC = None


def when(text):
    """'2026-10-22 20:18' -> a datetime, or None (the page leaves it out)."""
    try:
        return datetime.datetime.strptime(str(text), FMT)
    except (TypeError, ValueError):
        return None


def load(path):
    """{updates, notices} from the JSON; a row without an id, a title or a known status, a repeated id, a status or date
    key outside STATUSES, or a date not written YYYY-MM-DD HH:MM raises ValueError naming it."""
    data = json.loads(Path(path).read_text())
    seen, rows = set(), []
    for u in data.get("updates") or []:
        uid = u.get("id")
        if not uid or not u.get("title") or u.get("status") not in STATUSES:
            raise ValueError(f"operator update {uid or u.get('title') or '?'}: needs an id, a title and a status in {STATUSES}")
        if uid in seen:
            raise ValueError(f"operator update {uid}: the id is used twice")
        seen.add(uid)
        dates = u.get("dates") or {}
        for k, v in dates.items():
            if k not in DATE_KEYS or (v is not None and when(v) is None):
                raise ValueError(f"operator update {uid}: date {k!r} {v!r} (keys {DATE_KEYS}, YYYY-MM-DD HH:MM)")
        if u.get("area") and u["area"] not in AREAS:
            raise ValueError(f"operator update {uid}: area {u['area']!r} not in {AREAS}")
        rows.append(u)
    notices = []
    for n in data.get("notices") or []:
        if when(n.get("t")) is None or not n.get("text") or n.get("kind") not in NOTICE_KINDS:
            raise ValueError(f"operator notice {n!r}: needs t (YYYY-MM-DD HH:MM), a kind in {NOTICE_KINDS} and text")
        notices.append(n)
    return {"updates": rows, "notices": notices}


def refs(rows):
    """The site message ids the rows name (who asked, and replies)."""
    out = set()
    for u in rows:
        for r in u.get("requested_by") or []:
            if str(r.get("ref") or "").startswith("site:"):
                out.add(r["ref"])
        out |= {x for x in u.get("replies") or [] if str(x).startswith("site:")}
    return out


def _local(t):
    return datetime.datetime.fromtimestamp(t, PACIFIC).replace(tzinfo=None)


def messages(runs_dir, wanted, clean, keep, hidden=None):
    """({id: {name, text, at}}, {id: [{text, at}]}): each wanted site message as the operator inbox holds it (the first
    copy), and the operator's replies to it, oldest first. Text through clean (redaction); a message keep refuses or a
    hidden viewer's (site/moderation.py) is left out, and so are the replies that quote nothing else."""
    asks, replies = {}, {}
    root = Path(runs_dir)
    for f in sorted(root.glob("*/operator-inbox.jsonl")):
        for line in f.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            mid = row.get("id") if isinstance(row, dict) else None
            if mid not in wanted or mid in asks or not isinstance(row.get("text"), str):
                continue
            name = str(row.get("agent") or "").removeprefix("viewer ").strip() or "?"
            if not keep(row["text"]) or (hidden and hidden.hides(name, row["text"])):
                continue
            asks[mid] = {"name": name, "text": clean(row["text"]), "at": _local(row["t"]) if isinstance(row.get("t"), (int, float)) else None}
    for f in sorted(root.glob("*/operator-replies.jsonl")):
        for line in f.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            to = row.get("to") if isinstance(row, dict) else None
            if to not in wanted:
                continue
            text = " ".join(p for p in row.get("parts") or [] if isinstance(p, str))
            if not text or not keep(text):
                continue
            replies.setdefault(to, []).append({"text": clean(text), "at": _local(row["t"]) if isinstance(row.get("t"), (int, float)) else None})
    for v in replies.values():
        v.sort(key=lambda r: r["at"] or datetime.datetime.min)
    return asks, replies


def _day(d):
    return d.strftime("%a %d %b %H:%M") if d else ""


def _asked(u, asks):
    """When it was asked: its own date, else the earliest asking message's time."""
    d = when((u.get("dates") or {}).get("asked"))
    if d:
        return d
    times = [asks[r["ref"]]["at"] for r in u.get("requested_by") or [] if r.get("ref") in asks and asks[r["ref"]]["at"]]
    return min(times) if times else None


def _first(u, asks):
    """The earliest date it has (the order within a status)."""
    dates = [d for d in [when(v) for v in (u.get("dates") or {}).values()] + [_asked(u, asks)] if d]
    return min(dates) if dates else datetime.datetime.max


def _latest(u, asks):
    """The newest date it has (the order of the verified list)."""
    dates = [when(v) for v in (u.get("dates") or {}).values()]
    dates = [d for d in dates if d] + ([_asked(u, asks)] if _asked(u, asks) else [])
    return max(dates) if dates else datetime.datetime.min


def _row(u, asks, replies, esc):
    st = u["status"]
    who = []
    for r in u.get("requested_by") or []:
        ref = r.get("ref") or ""
        who.append(esc(r.get("name") or "?") + (f' <span class="muted">({esc(ref)})</span>' if ref else ""))
    dates = u.get("dates") or {}
    steps = []
    asked = _asked(u, asks)
    if asked:
        steps.append(("asked", asked))
    for k in STATUSES:
        d = when(dates.get(k))
        if d:
            steps.append((k, d))
    timeline = " · ".join(f"{esc(k)} {esc(_day(d))}" for k, d in steps)
    quotes = []
    for r in u.get("requested_by") or []:
        a = asks.get(r.get("ref"))
        if a:
            quotes.append(f'<blockquote class="upd-ask"><p class="small muted">{esc(r["ref"])}, {esc(a["name"])}'
                          f'{", " + esc(_day(a["at"])) if a["at"] else ""}</p><p>{esc(a["text"])}</p></blockquote>')
    said, shown = [], set()
    for ref in [r.get("ref") for r in u.get("requested_by") or []] + list(u.get("replies") or []):
        if ref in shown:
            continue
        shown.add(ref)
        for rep in replies.get(ref) or []:
            said.append(f'<blockquote class="upd-reply"><p class="small muted">Operator to {esc(ref)}'
                        f'{", " + esc(_day(rep["at"])) if rep["at"] else ""}</p><p>{esc(rep["text"])}</p></blockquote>')
    msgs = ""
    if quotes or said:
        label = " and ".join(([("The original messages" if len(quotes) > 1 else "The original message")] if quotes else []) +
                             ([("the operator's replies" if len(said) > 1 else "the operator's reply")] if said else []))
        label = label[:1].upper() + label[1:]
        msgs = f'<details class="upd-msgs"><summary>{esc(label)}</summary>' + "".join(quotes) + "".join(said) + "</details>"
    area = f' <span class="fx-chip fx-chip--grey upd-area">{esc(u["area"])}</span>' if u.get("area") else ""
    meta = ("Asked by " + ", ".join(who) if who else "") + (" · " if who and u.get("work") else "") + esc(u.get("work") or "")
    anchor = esc(u["id"])
    return (f'<li class="upd" id="u-{anchor}"><div class="upd-head"><span class="fx-chip {CHIP[st]} upd-status">{esc(st)}</span>'
            f'{area} <a class="upd-title" href="#u-{anchor}">{esc(u["title"])}</a></div>'
            + (f'<p class="small upd-meta">{meta}</p>' if meta else "")
            + (f'<p class="small muted upd-dates">{timeline}</p>' if timeline else "")
            + (f'<p class="small upd-note">{esc(u["note"])}</p>' if u.get("note") else "")
            + msgs + "</li>")


def build_page(data, asks, replies, esc):
    """(body, extra_head) of /updates/."""
    rows = data["updates"]
    counts = {s: sum(1 for u in rows if u["status"] == s) for s in STATUSES}
    chips = " ".join(f'<a class="fx-chip {CHIP[s]} upd-count" href="#{s.replace(" ", "-")}">{esc(s)}: {counts[s]}</a>' for s in STATUSES)
    legend = "".join(f'<li><span class="fx-chip {CHIP[s]} upd-status">{esc(s)}</span> {esc(WHAT[s])}</li>' for s in STATUSES)
    open_parts = []
    for s in OPEN_ORDER:
        group = sorted((u for u in rows if u["status"] == s), key=lambda u: _first(u, asks))
        if group:
            open_parts.append(f'<h3 id="{s.replace(" ", "-")}">{esc(s.capitalize())} ({len(group)})</h3><ul class="upd-list">'
                              + "".join(_row(u, asks, replies, esc) for u in group) + "</ul>")
    done = sorted((u for u in rows if u["status"] == "verified"), key=lambda u: _latest(u, asks), reverse=True)
    done_html = ('<ul class="upd-list">' + "".join(_row(u, asks, replies, esc) for u in done) + "</ul>") if done else '<p class="muted">None yet.</p>'
    notices = sorted(data["notices"], key=lambda n: when(n["t"]), reverse=True)
    notice_rows = "".join(f'<li><span class="muted">{esc(_day(when(n["t"])))}</span> <span class="fx-chip fx-chip--grey upd-kind">'
                          f'{esc(n["kind"])}</span> {esc(n["text"])}</li>' for n in notices)
    notices_html = f'<ul class="upd-notices">{notice_rows}</ul>' if notices else '<p class="muted">None.</p>'
    open_html = "".join(open_parts) or '<p class="muted">Nothing open.</p>'
    body = f"""
<h1>Operator updates</h1>
<p class="lede">Changes to the harness, the stream and this site that viewers and agents asked for, and where each one
stands. Unresolved ones stay at the top until they are verified. Times are Pacific.</p>
<p class="upd-counts">{chips}</p>
<ul class="upd-legend small">{legend}</ul>
<h2 id="open">Not verified yet</h2>
{open_html}
<h2 id="verified">Verified ({len(done)})</h2>
{done_html}
<h2 id="notices">Status notices</h2>
<p class="muted small">Deploys, restarts, rests and outages, kept apart from the change announcements above.</p>
{notices_html}
"""
    return body, ""
