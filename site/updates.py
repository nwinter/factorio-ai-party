"""Operator updates on the site (d23 batch119 CB4, viewer Aurora site:4349: "Could the site have an Operator updates
section with a permanent history of harness and site changes, their current status, and links to the original
messages?" and site:4350: "Please distinguish planned, in progress, live and verified updates, keep unresolved items
visible, and separate automatic status notices from change announcements.").

The data is site/content/operator-updates.json (tools/operator_updates.py adds rows and moves them on, or edit it by
hand): each change with who asked (a site message id, site:NNNN, or a board item, #NNNN), its status, when it reached
each status, its batch (work), and a note with its earlier notes kept as dated history; and the notices (deploys, restarts, rests, outages) apart from the changes. At build time the
asking message's text and the operator's replies come from the run folders (runs/*/operator-inbox.jsonl by id,
runs/*/operator-replies.jsonl by `to`), through the site's redaction and filters, so the page keeps them after the
chat has moved on. For build.py:
- load(): the rows, checked (a bad row stops the build with its id);
- problems(): rows to look at, which the build prints and builds anyway (a status past planned with no work);
- messages(): the asks and the replies the rows name;
- build_page(): the /updates/ page: the counts, then everything not yet verified (in progress, planned, live), then
  the verified ones, newest first, then the notices.
"""
import datetime
import hashlib
import json
import re
from pathlib import Path

STATUSES = ("planned", "in progress", "live", "verified")
ACCEPTED = ("in progress", "planned")  # (d24 batch180) accepted, not live yet: a section of its own
CHIP = {"planned": "fx-chip--grey", "in progress": "fx-chip--orange", "live": "fx-chip--blue", "verified": "fx-chip--green"}
WHAT = {"planned": "accepted, not started", "in progress": "an engineer is on it, or it waits for the merge gate",
        "live": "merged and deployed", "verified": "checked working in the game or on the site after it went live"}
PRIO_CHIP = {"urgent": "fx-chip--orange", "normal": "fx-chip--blue", "later": "fx-chip--grey"}
AREAS = ("harness", "stream", "site")
NOTICE_KINDS = ("deploy", "restart", "rest", "outage", "shift")
# (d26 batch235 UR, viewer Aurora site:5022: "Could accepted work get regular backlog reviews after recovery and long
# jobs? Keep its original ID, priority, owner and next review so older requests need no repeat viewer nudge.") a row's
# priority, owner (a role: "engineer batch233", "operator"), next_review and reviewed (when it was last reviewed); a
# re-plan keeps the first planned date and adds replanned; an owner handed on stays in owner_history.
PRIORITIES = ("urgent", "normal", "later")
DATE_KEYS = ("asked",) + STATUSES + ("replanned",)
FMT = "%Y-%m-%d %H:%M"
OWNER_LEN = 80
# the owner is a role, never a person: the names build.py's _BLOCKED keeps off the site, and an email
OWNER_BLOCKED = re.compile(r"(?i)\bnick\b|\bwinter\b|account-b|codex-b|claude-b|dropbox|cygnal|peon-ping|account-d|@")
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
    key outside STATUSES, or a date not written YYYY-MM-DD HH:MM raises ValueError naming it; so do note_at, note_status
    and history entries ({until, note, status, from}) written otherwise."""
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
        if (u.get("note_at") is not None and when(u["note_at"]) is None) or u.get("note_status", "planned") not in STATUSES:
            raise ValueError(f"operator update {uid}: note_at {u.get('note_at')!r} (YYYY-MM-DD HH:MM) or note_status {u.get('note_status')!r} (one of {STATUSES})")
        for k in ("next_review", "reviewed"):
            if u.get(k) is not None and when(u[k]) is None:
                raise ValueError(f"operator update {uid}: {k} {u[k]!r} (YYYY-MM-DD HH:MM)")
        if u.get("priority") is not None and u["priority"] not in PRIORITIES:
            raise ValueError(f"operator update {uid}: priority {u['priority']!r} not in {PRIORITIES}")
        if u.get("owner") is not None and not owner_ok(u["owner"]):
            raise ValueError(f"operator update {uid}: owner {u['owner']!r}: a role up to {OWNER_LEN} characters "
                             "(\"engineer batch233\", \"operator\"), no person's name or account")
        oh = u.get("owner_history")
        if oh is not None and not (isinstance(oh, list) and all(isinstance(h, dict) and owner_ok(h.get("owner")) and when(h.get("until")) for h in oh)):
            raise ValueError(f"operator update {uid}: owner_history is a list of {{owner, until: YYYY-MM-DD HH:MM}}")
        hist = u.get("history")
        if hist is not None and (not isinstance(hist, list) or not all(
                isinstance(h, dict) and isinstance(h.get("note"), str) and h["note"] and when(h.get("until"))
                and h.get("status", "planned") in STATUSES and (h.get("from") is None or when(h["from"])) for h in hist)):
            raise ValueError(f"operator update {uid}: history is a list of {{until: YYYY-MM-DD HH:MM, note, status, from}}")
        rows.append(u)
    notices = []
    for n in data.get("notices") or []:
        if when(n.get("t")) is None or not n.get("text") or n.get("kind") not in NOTICE_KINDS:
            raise ValueError(f"operator notice {n!r}: needs t (YYYY-MM-DD HH:MM), a kind in {NOTICE_KINDS} and text")
        if (n.get("recovered") is not None and when(n["recovered"]) is None) or (
                n.get("affected") is not None and not (isinstance(n["affected"], str) and n["affected"].strip())):
            raise ValueError(f"operator notice {n!r}: recovered is YYYY-MM-DD HH:MM (or null while it lasts), affected a text")
        notices.append(n)
    checked = data.get("notices_checked")
    if checked is not None and when(checked) is None:
        raise ValueError(f"notices_checked {checked!r}: YYYY-MM-DD HH:MM")
    reviewed = data.get("backlog_reviewed")
    if reviewed is not None and when(reviewed) is None:
        raise ValueError(f"backlog_reviewed {reviewed!r}: YYYY-MM-DD HH:MM")
    return {"updates": rows, "notices": notices, "notices_checked": checked, "backlog_reviewed": reviewed}


def owner_ok(o):
    """An owner is a role (free text up to OWNER_LEN characters), never a person's name or account."""
    return isinstance(o, str) and 0 < len(o.strip()) <= OWNER_LEN and not OWNER_BLOCKED.search(o)


def is_open(u):
    """Accepted and not live yet: planned or in progress (the rows a backlog review looks at)."""
    return u.get("status") in ACCEPTED


def last_change(u):
    """When the row last changed: its newest status date, note, or owner handed on (a review alone is no change)."""
    times = [when(v) for v in (u.get("dates") or {}).values()] + [when(u.get("note_at"))] + [when(h.get("until")) for h in u.get("owner_history") or []]
    times = [t for t in times if t]
    return max(times) if times else None


def is_due(u, now):
    """An open row whose next review has passed at now, or that has none."""
    nr = when(u.get("next_review"))
    return is_open(u) and (nr is None or nr <= now)


def ago(then, now):
    """'3 d 4 h', '5 h 20 min', '12 min' from then to now ('?' with no time)."""
    if not then:
        return "?"
    mins = max(0, int((now - then).total_seconds() // 60))
    d, h, m = mins // 1440, mins % 1440 // 60, mins % 60
    return f"{d} d {h} h" if d else f"{h} h {m:02d} min" if h else f"{m} min"


def problems(data):
    """Rows to look at, one line each; the build prints them and builds anyway (d23, viewer Aurora 18:46: three live rows
    still read "not yet given to an engineer", with no batch): a status past planned with no work."""
    return [f"operator update {u['id']}: {u['status']} with no work (batch)" for u in data["updates"]
            if u["status"] != "planned" and not u.get("work")]


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


def stage(u, asks=None):
    """When it reached its current status (the order within a status group, newest first); its newest date without one."""
    dates = u.get("dates") or {}
    d = when(dates.get(u["status"]))
    r = when(dates.get("replanned")) if u["status"] == "planned" else None  # (batch235) planned again: since then
    return max(x for x in (d, r) if x) if d or r else _latest(u, asks or {})


def acknowledged(u):
    """When the operator first put it on the list: its earliest status date (None when it has none)."""
    dates = [when((u.get("dates") or {}).get(k)) for k in STATUSES]
    dates = [d for d in dates if d]
    return min(dates) if dates else None


def deployed(u):
    """When it went live (None before it did)."""
    return when((u.get("dates") or {}).get("live"))


def _key(d):
    """A datetime as a number the page's script sorts by (YYYYMMDDHHMM; 0 for none)."""
    return int(d.strftime("%Y%m%d%H%M")) if d and d not in (datetime.datetime.min, datetime.datetime.max) else 0


def _search(u, asks):
    """The words the page's search box matches: title, id, status, area, batch, who asked and their refs, the notes and
    the asking messages."""
    bits = [u.get("title"), u.get("id"), u.get("status"), u.get("area"), u.get("work"), u.get("note"), u.get("priority"), u.get("owner")]
    for r in u.get("requested_by") or []:
        bits += [r.get("name"), r.get("ref"), (asks.get(r.get("ref")) or {}).get("text")]
    bits += [h.get("note") for h in u.get("history") or []]
    return " ".join(" ".join(str(b).split()) for b in bits if b).lower()


def _review(u, esc, now):
    """(batch235) an open row's priority, owner (and those before), next review (due at now, the build's time) and when it
    was last reviewed; nothing for a row past in progress."""
    if not is_open(u):
        return ""
    pr, owner, nr, rv = u.get("priority"), u.get("owner"), when(u.get("next_review")), when(u.get("reviewed"))
    before = [h["owner"] for h in u.get("owner_history") or []]
    bits = [f'<span class="fx-chip {PRIO_CHIP[pr]} upd-priority">{esc(pr)}</span>' if pr else '<span class="muted">no priority set</span>',
            ("Owner " + esc(owner) + (f' <span class="muted">(before: {esc(", ".join(before))})</span>' if before else ""))
            if owner else '<span class="muted">no owner set</span>',
            ("Next review " + esc(_day(nr)) + (' <span class="upd-flag upd-due">due</span>' if now and nr <= now else ""))
            if nr else '<span class="muted">no review set</span>']
    if rv:
        bits.append(f'<span class="muted">last reviewed {esc(_day(rv))}</span>')
    return '<p class="small upd-review">' + " · ".join(bits) + "</p>"


def _row(u, asks, replies, esc, now=None):
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
    if when(dates.get("replanned")):
        steps.append(("planned again", when(dates["replanned"])))
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
    work = esc(u["work"]) if u.get("work") else '<span class="upd-flag">no batch recorded</span>' if st != "planned" else ""
    meta = ("Asked by " + ", ".join(who) if who else "") + (" · " if who and work else "") + work
    # (d23, viewer Aurora 18:46: "Could superseded queue notes become dated history, so each card's current status and
    # note agree?") the current note says when it was written, and under which status when that is not the current one;
    # the notes it replaced are folded under it, newest first
    note = ""
    if u.get("note"):
        ns, na = u.get("note_status"), when(u.get("note_at"))
        lead = (f'<span class="muted">Note from when it was {esc(ns)}{", " + esc(_day(na)) if na else ""}:</span> ' if ns and ns != st else "")
        tail = f' <span class="muted">({esc(_day(na))})</span>' if na and not lead else ""
        note = f'<p class="small upd-note">{lead}{esc(u["note"])}{tail}</p>'
    hist = list(reversed(u.get("history") or []))
    if hist:
        items = "".join(f'<li><span class="muted">{esc(_day(when(h.get("from"))) + " to " if h.get("from") else "until ")}{esc(_day(when(h["until"])))}'
                        f'{", while " + esc(h["status"]) if h.get("status") else ""}:</span> {esc(h["note"])}</li>' for h in hist)
        note += (f'<details class="upd-history"><summary>{"Earlier notes" if len(hist) > 1 else "Earlier note"} ({len(hist)})</summary>'
                 f'<ul>{items}</ul></details>')
    anchor = esc(u["id"])
    attrs = (f' data-status="{esc(st)}" data-area="{esc(u.get("area") or "")}" data-stage="{_key(stage(u, asks))}"'
             f' data-ack="{_key(acknowledged(u))}" data-live="{_key(deployed(u))}" data-asked="{_key(_asked(u, asks))}"'
             f' data-q="{esc(_search(u, asks))}"')
    return (f'<li class="upd" id="u-{anchor}"{attrs}><div class="upd-head"><span class="fx-chip {CHIP[st]} upd-status">{esc(st)}</span>'
            f'{area} <a class="upd-title" href="#u-{anchor}">{esc(u["title"])}</a></div>'
            + (f'<p class="small upd-meta">{meta}</p>' if meta else "")
            + _review(u, esc, now)
            + (f'<p class="small muted upd-dates">{timeline}</p>' if timeline else "")
            + note
            + msgs + "</li>")


def newest(data):
    """The newest time the data holds: a status date of any row, or a notice's (None when it has none)."""
    times = [when(v) for u in data["updates"] for v in (u.get("dates") or {}).values()] + [when(n["t"]) for n in data["notices"]]
    times = [t for t in times if t]
    return max(times) if times else None


SORTS = (("stage", "Stage date"), ("ack", "Acknowledged"), ("live", "Deployed"), ("asked", "Asked"))
CADENCE = ("This page is rebuilt every hour and whenever the operator refreshes the site. While it is open it checks for "
           "new updates every 3 minutes and when you come back to it, and adds them in place.")


def rows_html(data, asks, replies, esc, built=None):
    """{id: (status, the row's li)}: the rows as the page and updates.json give them, each with a sig (a hash of its
    li) that the page compares to see a row changed. built: the build's time, which a next review is due against."""
    out = {}
    for u in data["updates"]:
        li = _row(u, asks, replies, esc, built)
        sig = hashlib.sha1(li.encode()).hexdigest()[:12]
        out[u["id"]] = (u["status"], li.replace('<li class="upd" ', f'<li class="upd" data-sig="{sig}" ', 1), sig)
    return out


def _counts(rows, esc):
    counts = {s: sum(1 for u in rows if u["status"] == s) for s in STATUSES}
    # a status with rows links to its section; one with none is a plain chip (its section is not rendered: site/check.py
    # failed the 09:18 refresh on a broken #planned once every planned row had moved on)
    return " ".join(f'<a class="fx-chip {CHIP[s]} upd-count" href="#{s.replace(" ", "-")}">{esc(s)}: {counts[s]}</a>' if counts[s]
                    else f'<span class="fx-chip {CHIP[s]} upd-count">{esc(s)}: 0</span>' for s in STATUSES)


def _updated(data, built):
    stamp = newest(data)
    return ("Status data last changed " + _day(stamp) if stamp else "No status dates yet") + \
        (f"; this page built {_day(built)}" if built else "") + "."


def _backlog(data, built):
    """(batch235) when the backlog was last reviewed (operator_updates.py reviewed) and how many rows are open; with the
    build's time, how many are due."""
    rows = [u for u in data["updates"] if is_open(u)]
    rv = when(data.get("backlog_reviewed"))
    due = sum(1 for u in rows if is_due(u, built)) if built else None
    return ((f"Backlog last reviewed {_day(rv)}" if rv else "The backlog has no review yet") +
            f"; {len(rows)} row{'' if len(rows) == 1 else 's'} open (planned or in progress)" +
            (f", {due} due for review at this build" if due is not None else "") + ".")


def _checked(data):
    """When the operator's checks last looked at the notices (tools/operator_updates.py checked, notice, recover)."""
    c = when(data.get("notices_checked"))
    return (f"Status notices checked through {_day(c)}." if c else "Status notices have no check time yet.")


def _notices(data, esc):
    out = []
    for n in sorted(data["notices"], key=lambda n: when(n["t"]), reverse=True):
        aff = f' <span class="fx-chip fx-chip--grey upd-affected">{esc(n["affected"])}</span>' if n.get("affected") else ""
        rec = ""
        if "recovered" in n:
            r = when(n["recovered"]) if n["recovered"] else None
            if r:
                mins = int((r - when(n["t"])).total_seconds() // 60)
                rec = (f' <span class="muted upd-recovered">Recovered {esc(_day(r))}'
                       + (f" ({mins // 60} h {mins % 60:02d} min later)" if mins >= 60 else f" ({mins} min later)" if mins > 0 else "")
                       + ".</span>")
            else:
                rec = ' <span class="upd-flag upd-recovered">Not recovered yet.</span>'
        out.append(f'<li><span class="muted">{esc(_day(when(n["t"])))}</span> <span class="fx-chip fx-chip--grey upd-kind">'
                   f'{esc(n["kind"])}</span>{aff} {esc(n["text"])}{rec}</li>')
    return f'<ul class="upd-notices" id="upd-notices">{"".join(out)}</ul>' if out else '<p class="muted" id="upd-notices">None.</p>'


def _tools(rows, esc):
    """The search box, status and area filters and the sort; hidden until the page's script runs (without it every row
    shows, newest first in its group)."""
    st = "".join(f'<option value="{esc(s)}">{esc(s.capitalize())} ({sum(1 for u in rows if u["status"] == s)})</option>' for s in STATUSES)
    ar = "".join(f'<option value="{a}">{a.capitalize()} ({sum(1 for u in rows if u.get("area") == a)})</option>' for a in AREAS)
    so = "".join(f'<option value="{k}">{label} (newest first)</option>' for k, label in SORTS)
    return ('<form id="upd-tools" class="upd-tools" role="search" hidden onsubmit="return false">'
            '<label class="upd-search">Search<input type="search" id="upd-q" placeholder="title, note, batch, who asked" autocomplete="off" '
            'aria-describedby="upd-shown"></label>'
            f'<label>Status<select id="upd-status"><option value="">Any status</option>{st}</select></label>'
            f'<label>Area<select id="upd-area"><option value="">Any area</option>{ar}</select></label>'
            f'<label>Sort<select id="upd-sort">{so}</select></label></form>'
            '<p id="upd-shown" class="upd-shown muted small" aria-live="polite" hidden></p>')


def build_page(data, asks, replies, esc, built=None):
    """(body, extra_head) of /updates/. built: when the site was built (Pacific, naive), said with the data's newest
    time under the heading (d23 batch124b, viewer Aurora 10:13: "Could deploys be overwriting newer status data?
    Please ... add a last-updated time": the 09:59 hourly refresh built from the committed file while the operator's
    newer edits sat in a patch, 09:44-10:18).
    (d24 batch159 QB1, viewer Aurora 11:27-11:28) each status group newest first by the date it reached that status;
    search, status and area filters and sorts by stage date, acknowledged, deployed or asked (static/updates.js; the URL
    keeps the view); the notices with what they affected and when it recovered, and when they were last checked apart
    from the build; the publish cadence; the page polls stamp.json and fetches updates.json when it changed (updates_json(),
    stamp_json()) while open."""
    rows = data["updates"]
    lis = rows_html(data, asks, replies, esc, built)
    legend = "".join(f'<li><span class="fx-chip {CHIP[s]} upd-status">{esc(s)}</span> {esc(WHAT[s])}</li>' for s in STATUSES)

    def group(s):
        """(heading, list, count) of one status: newest first by the date it reached that status. A status with no rows
        keeps its list and a hidden heading without an id (new rows can come in; no link points at it)."""
        g = sorted((u for u in rows if u["status"] == s), key=lambda u: (stage(u, asks), u["id"]), reverse=True)
        head = (f'<h3 id="{s.replace(" ", "-")}" data-group-head="{esc(s)}">' if g else f'<h3 data-group-head="{esc(s)}" hidden>')
        head += f'{esc(s.capitalize())} (<span class="upd-n">{len(g)}</span>)</h3>'
        return head, f'<ul class="upd-list" data-group="{esc(s)}">' + "".join(lis[u["id"]][1] for u in g) + "</ul>", len(g)
    # (d24 batch180 QW1, viewer Aurora 17:32: "Show accepted work as Planned, then In progress when started") accepted
    # work (in progress, planned) apart from what is live and not verified yet, each with its dates
    accepted = [group(s) for s in ACCEPTED]
    accepted_html = "".join(h + ul for h, ul, _ in accepted)
    live_head, live_ul, n_live = group("live")
    _, done_ul, n_done = group("verified")
    none_open = f'<p class="muted" id="upd-none-open"{" hidden" if any(n for _, _, n in accepted) else ""}>Nothing accepted waits.</p>'
    none_live = f'<p class="muted" id="upd-none-live"{" hidden" if n_live else ""}>Nothing live waits to be verified.</p>'
    body = f"""
<h1>Operator updates</h1>
<p class="lede">Changes to the harness, the stream and this site that viewers and agents asked for, and where each one
stands. Accepted work comes first (planned, then in progress once an engineer has it), then what is live and not
verified yet, then what is verified; each group lists the newest first, by the date it reached its status. Times are
Pacific.</p>
<p class="small upd-backlog" id="upd-backlog">{esc(_backlog(data, built))}</p>
<p class="muted small upd-updated" id="upd-updated">{esc(_updated(data, built))}</p>
<p class="muted small upd-cadence">{esc(CADENCE)} <span id="upd-live-note" aria-live="polite"></span></p>
<p class="upd-counts" id="upd-counts">{_counts(rows, esc)}</p>
<ul class="upd-legend small">{legend}</ul>
{_tools(rows, esc)}
<div id="upd-root" data-built="{esc(built.strftime(FMT) if built else '')}" data-stamp="{data_stamp(data, asks, replies, esc, built)}">
<h2 id="open">Accepted: planned and in progress</h2>
{accepted_html}{none_open}
<h2 id="live-unverified">Live, not verified yet</h2>
{live_head}{live_ul}{none_live}
<h2 id="verified" data-group-head="verified">Verified (<span class="upd-n">{n_done}</span>)</h2>
{done_ul}<p class="muted" id="upd-none-verified"{" hidden" if n_done else ""}>None yet.</p>
</div>
<h2 id="notices">Status notices</h2>
<p class="muted small">Deploys, restarts, rests and outages, kept apart from the change announcements above.</p>
<p class="small upd-checked" id="upd-checked">{esc(_checked(data))}</p>
{_notices(data, esc)}
"""
    return body, '<script src="/static/updates.js" defer></script>'


def data_stamp(data, asks, replies, esc, built=None):
    """A hash of what the page shows apart from its build time: the page polls /updates/stamp.json (a few dozen bytes)
    and fetches updates.json only when this changed (a review falling due at a build changes it too)."""
    lis = rows_html(data, asks, replies, esc, built)
    text = json.dumps([sorted((k, v[2]) for k, v in lis.items()), _notices(data, esc), _checked(data), str(newest(data)), _backlog(data, built)])
    return hashlib.sha1(text.encode()).hexdigest()[:16]


def updates_json(data, asks, replies, esc, built=None):
    """/updates/updates.json, published with the page: what the page's script needs to add new rows in place (each row's
    status, sig and li), the counts, the two time lines and the notices; and its stamp (stamp_json(): what the page
    polls)."""
    lis = rows_html(data, asks, replies, esc, built)
    return {"stamp": data_stamp(data, asks, replies, esc, built), "built": built.strftime(FMT) if built else "",
            "updated": _updated(data, built), "checked": _checked(data), "backlog": _backlog(data, built),
            "counts": _counts(data["updates"], esc), "notices": _notices(data, esc),
            "rows": [{"id": uid, "status": st, "sig": sig, "html": li} for uid, (st, li, sig) in lis.items()]}


def stamp_json(full):
    """/updates/stamp.json: the stamp and the build time of updates.json (full)."""
    return {"stamp": full["stamp"], "built": full["built"]}
