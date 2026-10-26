#!/usr/bin/env python3
"""The site's Operator updates (site/content/operator-updates.json, the /updates/ page; d23 batch119 CB4, viewer
Aurora site:4349, site:4350): add a change, move it to its next status, add a status notice, list what is open.

  tools/operator_updates.py add ID --title T --by NAME [--ref site:4386|#1925] [--by NAME --ref REF ...]
                                (a board --ref '#1925' with no --by of its own: the asker from the board)
                                [--status planned] [--area harness|stream|site] [--work "batch119 CB1"] [--note N]
                                [--reply site:4407] [--at "YYYY-MM-DD HH:MM"]
  tools/operator_updates.py set ID [--status in\\ progress|live|verified] [--note N] [--work W] [--reply REF] [--at ...]
  tools/operator_updates.py notice --kind deploy|restart|rest|outage|shift --text T [--at ...] [--affected WHAT]
                                   [--recovered [TIME]] [--open]
  tools/operator_updates.py recover [--affected WHAT] [--kind K] [--at ...]
  tools/operator_updates.py checked [--at ...]
  tools/operator_updates.py list [--all]
  tools/operator_updates.py due [--now "YYYY-MM-DD HH:MM"]
  tools/operator_updates.py reviewed ID [--next +4h|+2d|"YYYY-MM-DD HH:MM"] [--note N] [--at ...]
  add and set also take --priority urgent|normal|later, --owner ROLE ("engineer batch233", "operator") and
  --next-review +4h|DATE.

--at is Pacific time (the default: now). add records the status's date, and "asked" when --asked is given; set
records the new status's date and keeps the earlier ones. A note is kept with when it was written and under which
status (note_at, note_status); set --note moves the note it replaces into the row's history, dated, and the page shows
that history folded under the current note (viewer Aurora 18:46: live rows still said "not yet given to an engineer").
A status past planned needs the work (batch) that did it: add and set refuse one without --work when the row has none,
and list marks such rows ("no work") as the build does. The page is rebuilt with the site (site/build.py), which
quotes each site:NNNN message and the operator's replies to it from the run folders. --file names another JSON (tests).

Status notices from the operator's scripts, one command each (d24 batch159 QB1, viewer Aurora 11:27: "Status notices
still end Oct23. Could deploy/restart/outage and recovery events update them, with event times and a checked-through
timestamp separate from page-build time?"): notice posts the event at its time (--at, default now) with what it
affected (--affected "stream", "harness runtime", ...); --recovered [TIME] says it is over (no TIME: now), --open says
it is still on (the page reads "Not recovered yet") until recover closes the newest open notice (of that --affected
and --kind when given). checked records that the operator's checks looked at the notices through now (or --at), and
every notice and recover records it too; the page shows it apart from when the page was built. One writer at a time
(a lock beside the file): two scripts posting at once both land.

(d24 batch180 QW1, viewer Aurora 17:32, site:4789: "Could chat acknowledgements and Updates share one batch record?
Show accepted work as Planned, then In progress when started.") tools/opreply.py --update ID answers a viewer and adds
or moves that row in one call (upsert() here, under the same lock): the viewer and the line it answers (site:N) as who
asked, the planned date recorded, the reply shown under the row; a status that would go backwards, or one past planned
with no work, is refused before anything is sent. add --ref '#NNNN' with no --by of its own takes the asker from the
board (the item's requested_by, else its owner; an operator read of the world, --world, default POG_WORLD or n).

(d26 batch235 UR, viewer Aurora site:5022: "Could accepted work get regular backlog reviews after recovery and long
jobs? Keep its original ID, priority, owner and next review so older requests need no repeat viewer nudge.") A row
has a priority, an owner (a role, never a person's name: updates.owner_ok) and a next_review. set --owner keeps the
owner it replaces in owner_history (until when); set --status planned on a row planned before keeps its first planned
date and records replanned; the id, the asked date and who asked never change. due lists the open rows (planned, in
progress) whose next review has passed at --now (default now) or that have none, oldest asked first, each with its id,
who asked, priority, owner, status and how long since it last changed; reviewed stamps a review (the row's reviewed
and the file's backlog_reviewed) and sets the next one: --next +4h / +2d / +30m from the review's time, or a date;
without it, by priority: urgent 4 h, normal 24 h, later 72 h.
"""
import argparse, contextlib, datetime, fcntl, json, os, re, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "site"))
import updates  # noqa: E402  (site/updates.py: the statuses and the checks the build makes)

DEFAULT = REPO / "site" / "content" / "operator-updates.json"


def now_text():
    return datetime.datetime.now(updates.PACIFIC).strftime(updates.FMT)


def stamp(text):
    if text is None:
        return now_text()
    if updates.when(text) is None:
        raise SystemExit(f"--at {text!r}: write YYYY-MM-DD HH:MM (Pacific)")
    return text


def read(path):
    p = Path(path)
    return json.loads(p.read_text()) if p.exists() else {"updates": [], "notices": []}


def write(path, data):
    """One row a line inside the lists, so a hand edit or a diff stays readable; checked by the build's own load()."""
    head = {k: v for k, v in data.items() if k not in ("updates", "notices")}
    lines = ["{"] + [f" {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}," for k, v in head.items()]
    for key in ("updates", "notices"):
        rows = data.get(key) or []
        lines.append(f' "{key}": [')
        lines += [f"  {json.dumps(r, ensure_ascii=False)}{',' if i < len(rows) - 1 else ''}" for i, r in enumerate(rows)]
        lines.append(" ]," if key == "updates" else " ]")
    lines.append("}")
    tmp = Path(str(path) + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    updates.load(tmp)  # refuse to write what the build would refuse
    os.replace(tmp, path)


def find(data, uid):
    for u in data.get("updates") or []:
        if u.get("id") == uid:
            return u
    raise SystemExit(f"no update {uid!r} (list --all shows them)")


def set_note(u, note, t, status):
    """The row's note becomes note, written at t under status; the note it replaces goes into history (oldest first) with
    when it was written (from, when known), when it was replaced (until) and its status then."""
    old = u.get("note")
    if old == note:
        return False
    if old:
        h = {"until": t, "note": old, "status": u.get("note_status") or u.get("status") or "planned"}
        if u.get("note_at"):
            h["from"] = u["note_at"]
        u.setdefault("history", []).append(h)
    u["note"], u["note_at"], u["note_status"] = note, t, status
    return True


NEXT = {"urgent": 4 * 60, "normal": 24 * 60, "later": 72 * 60}  # (batch235) minutes to the next review, by priority


def review_at(text, base):
    """--next / --next-review: '+4h', '+2d', '+30m' after base (a 'YYYY-MM-DD HH:MM'), or a date as written."""
    m = re.fullmatch(r"\+(\d+)([mhd])", (text or "").strip())
    if m:
        mins = int(m.group(1)) * {"m": 1, "h": 60, "d": 1440}[m.group(2)]
        return (updates.when(base) + datetime.timedelta(minutes=mins)).strftime(updates.FMT)
    if updates.when(text) is None:
        raise SystemExit(f"next review {text!r}: write +4h, +2d, +30m or YYYY-MM-DD HH:MM (Pacific)")
    return text


def owner_of(text):
    if not updates.owner_ok(text):
        raise SystemExit(f"--owner {text!r}: a role up to {updates.OWNER_LEN} characters (\"engineer batch233\", \"operator\"), "
                         "no person's name or account")
    return text.strip()


def plan_fields(u, args, t):
    """--priority, --owner and --next-review onto row u at time t; an owner handed on is kept in owner_history.
    Returns what changed, as words."""
    said = []
    if args.priority and args.priority != u.get("priority"):
        u["priority"] = args.priority
        said.append(f"priority {args.priority}")
    if args.owner:
        o = owner_of(args.owner)
        if o != u.get("owner"):
            if u.get("owner"):
                u.setdefault("owner_history", []).append({"owner": u["owner"], "until": t})
            u["owner"] = o
            said.append(f"owner {o}")
    if args.next_review:
        u["next_review"] = review_at(args.next_review, t)
        said.append(f"next review {u['next_review']}")
    return said


def needs_work(uid, status, work):
    if status != "planned" and not work:
        raise SystemExit(f"{uid}: {status} needs --work, the batch that did it (the row has none)")


@contextlib.contextmanager
def locked(path):
    """One writer at a time: the lock beside the file, held while the caller reads, changes and writes it."""
    with open(str(path) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def upsert(data, uid, status, *, title=None, area=None, work=None, name=None, ref=None, asked=None, at=None):
    """(d24 batch180 QW1) add row uid or move it on: status planned or in progress, who asked (name, ref) added when new,
    the status's date recorded when it changes (planned too). Refused (SystemExit naming why) when the row is missing
    and no title is given, when the status would go backwards, or when a status past planned has no work. Returns what
    it did, as a line; changes data only (the caller writes it)."""
    if status not in updates.STATUSES:
        raise SystemExit(f"{uid}: status {status!r} is not one of {', '.join(updates.STATUSES)}")
    if area is not None and area not in updates.AREAS:
        raise SystemExit(f"{uid}: area {area!r} is not one of {', '.join(updates.AREAS)}")
    t = stamp(at)
    rows = data.setdefault("updates", [])
    u = next((x for x in rows if x.get("id") == uid), None)
    said = []
    if u is None:
        if not title:
            raise SystemExit(f"{uid}: no such update yet: give --title (and --area) to add it")
        needs_work(uid, status, work)
        u = {"id": uid, "title": title}
        if area:
            u["area"] = area
        u["requested_by"] = []
        u["status"] = status
        u["dates"] = dict(({"asked": asked} if asked else {}), **{status: t})
        if work:
            u["work"] = work
        rows.append(u)
        said.append(f"added {uid}: {status} {t}")
    else:
        was = u["status"]
        if updates.STATUSES.index(status) < updates.STATUSES.index(was):
            raise SystemExit(f"{uid} is {was} (since {(u.get('dates') or {}).get(was) or '?'}): {status} would go backwards; "
                             "set it with operator_updates.py set if that is meant")
        needs_work(uid, status, work or u.get("work"))
        if title and title != u.get("title"):
            u["title"] = title
            said.append("title set")
        if area and area != u.get("area"):
            u["area"] = area
        if work and work != u.get("work"):
            u["work"] = work
            said.append(f"work {work}")
        if status != was:
            u["status"] = status
            u.setdefault("dates", {})[status] = t
            said.append(f"{was} -> {status} {t}")
        else:
            said.append(f"still {status}")
        if asked and not (u.get("dates") or {}).get("asked"):
            u.setdefault("dates", {})["asked"] = asked
    if name and not any(r.get("ref") == ref and r.get("name") == name for r in u.setdefault("requested_by", [])):
        u["requested_by"].append(dict({"name": name}, **({"ref": ref} if ref else {})))
        said.append(f"asked by {name}" + (f" ({ref})" if ref else ""))
    return f"{uid}: " + "; ".join(said)


def board_asker(ref, world=None, dispatch=None):
    """The asker of board item '#NNNN': its requested_by, else its owner (an operator board read of the world)."""
    m = re.fullmatch(r"#(\d+)", ref or "")
    if not m:
        return None
    if dispatch is None:
        sys.path.insert(0, str(REPO / "tools"))
        from idle_nudge import Harness  # the operator's own dispatch over RCON (read only here)
        dispatch = Harness(world or os.environ.get("POG_WORLD", "n")).dispatch
    res = dispatch("board", {"id": int(m.group(1))})
    item = (res.get("item") if isinstance(res, dict) else None) or next(iter((res or {}).get("items") or []), None) or res
    who = isinstance(item, dict) and (item.get("requested_by") or item.get("owner"))
    if not who:
        raise SystemExit(f"--ref {ref}: the board read gave no requested_by or owner (give --by)")
    return who


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--file", default=str(DEFAULT))
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("id")
    a.add_argument("--title", required=True)
    a.add_argument("--by", action="append", default=[], help="who asked (repeat with --ref for each message)")
    a.add_argument("--ref", action="append", default=[], help="site:NNNN or #NNNN, in the order of --by")
    a.add_argument("--status", default="planned", choices=updates.STATUSES)
    a.add_argument("--area", choices=updates.AREAS)
    a.add_argument("--work")
    a.add_argument("--note")
    a.add_argument("--reply", action="append", default=[])
    a.add_argument("--asked", help="when it was asked (YYYY-MM-DD HH:MM; a site message's own time is used without it)")
    a.add_argument("--at")
    a.add_argument("--world", help="the world a board --ref is read from (default POG_WORLD or n)")
    a.add_argument("--priority", choices=updates.PRIORITIES)
    a.add_argument("--owner", help="a role: \"engineer batch233\", \"operator\"")
    a.add_argument("--next-review", help="+4h, +2d, +30m or YYYY-MM-DD HH:MM")
    s = sub.add_parser("set")
    s.add_argument("id")
    s.add_argument("--status", choices=updates.STATUSES)
    s.add_argument("--note")
    s.add_argument("--work")
    s.add_argument("--reply", action="append", default=[])
    s.add_argument("--at")
    s.add_argument("--priority", choices=updates.PRIORITIES)
    s.add_argument("--owner", help="a role: \"engineer batch233\", \"operator\"")
    s.add_argument("--next-review", help="+4h, +2d, +30m or YYYY-MM-DD HH:MM")
    n = sub.add_parser("notice")
    n.add_argument("--kind", required=True, choices=updates.NOTICE_KINDS)
    n.add_argument("--text", required=True)
    n.add_argument("--at")
    n.add_argument("--affected", help="what it affected: stream, harness runtime, site, an agent, ...")
    when = n.add_mutually_exclusive_group()
    when.add_argument("--recovered", nargs="?", const="now", help="over at TIME (YYYY-MM-DD HH:MM; no TIME: now)")
    when.add_argument("--open", action="store_true", help="still on: recover closes it")
    r = sub.add_parser("recover")
    r.add_argument("--affected")
    r.add_argument("--kind", choices=updates.NOTICE_KINDS)
    r.add_argument("--at")
    c = sub.add_parser("checked")
    c.add_argument("--at")
    ls = sub.add_parser("list")
    ls.add_argument("--all", action="store_true")
    du = sub.add_parser("due")
    du.add_argument("--now", help="YYYY-MM-DD HH:MM (Pacific; default now)")
    rv = sub.add_parser("reviewed")
    rv.add_argument("id")
    rv.add_argument("--next", help="+4h, +2d, +30m or YYYY-MM-DD HH:MM (default by priority: urgent 4 h, normal 24 h, later 72 h)")
    rv.add_argument("--note")
    rv.add_argument("--at")
    args = ap.parse_args(argv)
    if args.cmd in ("list", "due"):
        return run(args)
    with locked(args.file):  # one writer at a time: read, change and write under the lock
        return run(args)


def run(args, board=None):
    data = read(args.file)
    data.setdefault("updates", [])
    data.setdefault("notices", [])

    if args.cmd == "add":
        if any(u.get("id") == args.id for u in data["updates"]):
            raise SystemExit(f"update {args.id!r} exists: use set")
        # (d24 batch180) a board ref with no --by of its own: the asker from the board
        for ref in args.ref[len(args.by):]:
            if not re.fullmatch(r"#\d+", ref):
                raise SystemExit(f"--ref {ref} needs its --by (only a board ref '#NNNN' takes the asker from the board)")
            who = board_asker(ref, args.world, board)
            args.by.append(who)
            print(f"--ref {ref}: asked by {who} (the board)")
        row = {"id": args.id, "title": args.title}
        if args.area:
            row["area"] = args.area
        row["requested_by"] = [dict({"name": b}, **({"ref": args.ref[i]} if i < len(args.ref) else {})) for i, b in enumerate(args.by)]
        row["status"] = args.status
        if args.reply:
            row["replies"] = args.reply
        needs_work(args.id, args.status, args.work)
        t = stamp(args.at)
        row["dates"] = dict(({"asked": stamp(args.asked)} if args.asked else {}),
                            **({args.status: t} if args.status != "planned" or args.at else {}))
        if args.work:
            row["work"] = args.work
        if args.note:
            set_note(row, args.note, t, args.status)
        plan_fields(row, args, t)
        data["updates"].append(row)
        write(args.file, data)
        print(f"added {args.id}: {args.status}")
    elif args.cmd == "set":
        u = find(data, args.id)
        if not (args.status or args.note or args.work or args.reply or args.priority or args.owner or args.next_review):
            raise SystemExit("set: give --status, --note, --work, --reply, --priority, --owner or --next-review")
        t = stamp(args.at)
        status = args.status or u["status"]
        needs_work(args.id, status, args.work or u.get("work"))
        said = []
        if args.status:
            dates = u.setdefault("dates", {})
            if args.status == "planned" and u["status"] != "planned" and dates.get("planned"):
                dates["replanned"] = t  # (batch235) planned again: the first planned date stays
                said.append(f"planned again {t} (first planned {dates['planned']})")
            else:
                dates[args.status] = t
                said.append(f"{args.status} {t}")
            u["status"] = args.status
        if args.work:
            u["work"] = args.work
        if args.note:
            moved = len(u.get("history") or [])
            if set_note(u, args.note, t, status):
                said.append("note set" + (f"; the one it replaced is in history ({len(u['history'])})" if len(u.get("history") or []) > moved else ""))
        elif args.status and u.get("note") and (u.get("note_status") or "") != status:
            said.append(f"note kept, written {'while ' + u['note_status'] if u.get('note_status') else 'before this status'}")
        if args.reply:
            u["replies"] = list(dict.fromkeys((u.get("replies") or []) + args.reply))
        said += plan_fields(u, args, t)
        write(args.file, data)
        print(f"{args.id}: " + ("; ".join(said) or "updated"))
    elif args.cmd == "notice":
        row = {"t": stamp(args.at), "kind": args.kind, "text": args.text}
        if args.affected:
            row["affected"] = args.affected
        if args.recovered:
            row["recovered"] = stamp(None if args.recovered == "now" else args.recovered)
            if updates.when(row["recovered"]) < updates.when(row["t"]):
                raise SystemExit(f"--recovered {row['recovered']} is before the event ({row['t']})")
        elif args.open:
            row["recovered"] = None
        data["notices"].append(row)
        data["notices_checked"] = now_text()
        write(args.file, data)
        print(f"notice: {args.kind} {row['t']}" + (f" ({args.affected})" if args.affected else "")
              + ("; open until recover" if args.open else f"; recovered {row['recovered']}" if row.get("recovered") else ""))
    elif args.cmd == "recover":
        t = stamp(args.at)
        open_ = [x for x in data["notices"] if "recovered" in x and x["recovered"] is None
                 and (not args.affected or x.get("affected") == args.affected) and (not args.kind or x["kind"] == args.kind)]
        if not open_:
            raise SystemExit("recover: no open notice" + (f" for {args.affected}" if args.affected else "")
                             + " (notice --open makes one)")
        x = max(open_, key=lambda x: updates.when(x["t"]))
        if updates.when(t) < updates.when(x["t"]):
            raise SystemExit(f"recover: {t} is before the event ({x['t']})")
        x["recovered"] = t
        data["notices_checked"] = now_text()
        write(args.file, data)
        print(f"recovered: {x['kind']} {x['t']} -> {t}")
    elif args.cmd == "checked":
        data["notices_checked"] = stamp(args.at)
        write(args.file, data)
        print(f"notices checked through {data['notices_checked']}")
    elif args.cmd == "due":
        now = updates.when(stamp(args.now))
        print("\n".join(due_lines(data, now)))
    elif args.cmd == "reviewed":
        u = find(data, args.id)
        if not updates.is_open(u):
            raise SystemExit(f"{args.id} is {u['status']}: a review is of a planned or in progress row")
        t = stamp(args.at)
        nxt = review_at(args.next, t) if args.next else review_at(f"+{NEXT[u.get('priority') or 'normal']}m", t)
        u["reviewed"], u["next_review"] = t, nxt
        if args.note:
            set_note(u, args.note, t, u["status"])
        data["backlog_reviewed"] = t
        write(args.file, data)
        print(f"{args.id}: reviewed {t}; next review {nxt}" + ("; note set" if args.note else ""))
    else:
        for u in data["updates"]:
            if args.all or u.get("status") != "verified":
                refs = ", ".join(f"{r.get('name')} {r.get('ref') or ''}".strip() for r in u.get("requested_by") or [])
                flag = "  (no work)" if u.get("status") != "planned" and not u.get("work") else ""
                print(f"{u['status']:<12} {u['id']:<28} {u['title']}" + (f"  [{refs}]" if refs else "") + flag)


def due_lines(data, now):
    """(batch235) the open rows due for review at now (next_review passed, or none), oldest asked first: a count line,
    then one line a row."""
    rows = [u for u in data["updates"] if updates.is_open(u)]
    due = [u for u in rows if updates.is_due(u, now)]

    def asked(u):
        return updates.when((u.get("dates") or {}).get("asked")) or updates.acknowledged(u) or datetime.datetime.max
    due.sort(key=lambda u: (asked(u), u["id"]))
    out = [f"due: {len(due)} of {len(rows)} open rows at {now.strftime(updates.FMT)} (next review passed or none), oldest asked first"]
    for u in due:
        refs = ", ".join(f"{r.get('name')} {r.get('ref') or ''}".strip() for r in u.get("requested_by") or []) or "no asker"
        a = asked(u)
        nr = u.get("next_review")
        out.append(f"  {u['id']}  [{refs}]  priority {u.get('priority') or 'not set'}  owner {u.get('owner') or 'not set'}  {u['status']}"
                   f"  changed {updates.ago(updates.last_change(u), now)} ago"
                   f"  review {'due since ' + nr if nr else 'never set'}"
                   + (f"  asked {a.strftime(updates.FMT)}" if a != datetime.datetime.max else ""))
    return out


if __name__ == "__main__":
    main()
