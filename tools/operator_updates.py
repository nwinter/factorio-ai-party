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
  tools/operator_updates.py follow ID --what T --next N --owner batch322|operator|nick --review +2d|DATE [--source S]
  tools/operator_updates.py follow-set ID/N [--what T] [--next N] [--owner O] [--review +2d|DATE] [--done|--dropped] [--note N]
  tools/operator_updates.py reviewed ID/N [--next +2d|DATE] [--note N]
  tools/operator_updates.py defer ID|ID/N --reason T
  tools/operator_updates.py follow-candidates [--runs DIR]
  tools/operator_updates.py due [--now ...] [--ready-days 2]

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

(d28 batch322 UL, viewer Aurora site:5411: "Could unfinished promises remain actionable even when their parent batch
is Live? ... Give remaining work a linked owner, next action and review point. ... Within priority, revisit older ready
work and record why it is deferred.") A row of any status, Live included, holds follow-ups (ID/1, ID/2, ...): what is
left, its owner (a batch such as batch322, which the page links to the row that batch works on; operator; nick, written
as the stream's owner), the next action and a review time. follow adds one; follow-set changes it or closes it (--done,
--dropped, with a --note); reviewed ID/N stamps a review and sets the next (--next, default +24h). due lists, after the
open rows, every open follow-up past its review whatever its row's status, and then the ready work (planned rows and
open follow-ups) waiting longer than --ready-days (default 2), by priority (a follow-up has its row's), oldest first,
each with its newest deferred reason or "no reason"; defer records one (--reason). follow-candidates lists what Live
rows promise in their own text (the note and the operator's replies to the row's messages) and the Live rows still
carrying a next review, for the operator to confirm before any becomes a follow-up.
"""
import argparse, contextlib, datetime, fcntl, glob, json, os, re, sys
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


def follow_owner(text):
    """A follow-up's owner: a batch ("batch322", "engineer batch322"), "operator", or the stream's owner (nick, owner)."""
    t = (text or "").strip()
    if t.lower() in ("nick", "stream owner", "the stream's owner", "owner"):
        return updates.STREAM_OWNER
    return owner_of(t)


def find_follow(data, ref):
    """'ID/N' -> (row, follow-up)."""
    uid, _, n = (ref or "").rpartition("/")
    if not uid or not n.isdigit():
        raise SystemExit(f"{ref!r}: write ID/N (follow-up N of row ID)")
    u = find(data, uid)
    f = next((f for f in u.get("followups") or [] if f["n"] == int(n)), None)
    if f is None:
        raise SystemExit(f"{uid} has no follow-up {n} (it has {', '.join(str(f['n']) for f in u.get('followups') or []) or 'none'})")
    return u, f


PROMISE = re.compile(r"(?i)\b(will|I'll|gets? a design|design first|waits? (for|until)|stays? open until|pending|expected|"
                     r"to follow|later batch(es)?|go(es)? into later|not (yet|done|built|started)|next \(batch\d+\))\b")


SCOPE = re.compile(r"(?i)(Taken (as|into|in)|Into batch|(Now )?(also )?in progress|Started|An engineer is on it)\b")  # the batch's own scope


def candidates(data, runs_dir):
    """(batch322) what Live rows promise in their text, one block a row: the note's and the operator's replies' sentences
    that read as a promise (each sentence once, under the first row naming its message), and the row's next review when
    it carries one. For the operator to confirm; nothing is written."""
    replies = {}
    for f in sorted(glob.glob(str(Path(runs_dir) / "*" / "operator-replies.jsonl"))):
        for line in Path(f).read_text(errors="replace").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get("to"):
                text = " ".join(x for x in r.get("parts") or [] if isinstance(x, str))
                replies.setdefault(r["to"], []).append(text)
    seen, out = set(), []
    for u in data["updates"]:
        if u["status"] != "live":
            continue
        found = []
        srcs = [("note", u.get("note") or "")]
        for ref in dict.fromkeys([r.get("ref") for r in u.get("requested_by") or []] + list(u.get("replies") or [])):
            srcs += [(f"reply {ref}", t) for t in replies.get(ref) or []]
        for where, text in srcs:
            for sent in re.split(r"(?<=[.!?])\s+", text):
                sent = re.sub(r"^@\S+ (\(\d/\d\) )?Operator: ", "", sent.strip())
                if PROMISE.search(sent) and not SCOPE.match(sent) and sent not in seen:
                    seen.add(sent)
                    found.append(f"  {where}: {sent}")
        if u.get("next_review"):
            found.append(f"  next review {u['next_review']} (owner {u.get('owner') or 'not set'}): a Live row's review, which due skips")
        if found:
            out.append(f"{u['id']} (live, {u.get('work') or 'no work'}; open follow-ups {len(updates.open_follow(u))})")
            out += found
    return out


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
    du.add_argument("--ready-days", type=float, default=2, help="ready work waiting longer than this many days (default 2)")
    fo = sub.add_parser("follow")
    fo.add_argument("id")
    fo.add_argument("--what", required=True)
    fo.add_argument("--next", required=True, help="the next action")
    fo.add_argument("--owner", required=True, help="batch322, operator or nick (the stream's owner)")
    fo.add_argument("--review", required=True, help="+4h, +2d or YYYY-MM-DD HH:MM")
    fo.add_argument("--source", help="where it was promised: \"reply site:5293\", \"note\"")
    fo.add_argument("--at")
    fs = sub.add_parser("follow-set")
    fs.add_argument("ref", help="ID/N")
    fs.add_argument("--what")
    fs.add_argument("--next")
    fs.add_argument("--owner")
    fs.add_argument("--review")
    end = fs.add_mutually_exclusive_group()
    end.add_argument("--done", action="store_true")
    end.add_argument("--dropped", action="store_true")
    fs.add_argument("--note")
    fs.add_argument("--at")
    de = sub.add_parser("defer")
    de.add_argument("ref", help="ID (a planned row) or ID/N (an open follow-up)")
    de.add_argument("--reason", required=True)
    de.add_argument("--at")
    fc = sub.add_parser("follow-candidates")
    fc.add_argument("--runs", default=str(REPO / "runs"))
    args = ap.parse_args(argv)
    if args.cmd in ("list", "due", "follow-candidates"):
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
        print("\n".join(due_lines(data, now) + follow_lines(data, now) + ready_lines(data, now, args.ready_days)))
    elif args.cmd == "reviewed" and "/" in args.id:
        u, f = find_follow(data, args.id)
        if f.get("state", "open") != "open":
            raise SystemExit(f"{args.id} is {f['state']}: a review is of an open follow-up")
        t = stamp(args.at)
        f["reviewed"], f["review"] = t, review_at(args.next or "+24h", t)
        if args.note:
            f["note"] = args.note
        write(args.file, data)
        print(f"{args.id}: reviewed {t}; next review {f['review']}" + ("; note set" if args.note else ""))
    elif args.cmd == "follow":
        u = find(data, args.id)
        t = stamp(args.at)
        fl = u.setdefault("followups", [])
        f = {"n": max([x["n"] for x in fl] or [0]) + 1, "what": args.what.strip(), "owner": follow_owner(args.owner),
             "next": args.next.strip(), "review": review_at(args.review, t), "state": "open", "opened": t}
        if args.source:
            f["source"] = args.source
        fl.append(f)
        write(args.file, data)
        print(f"{u['id']}/{f['n']}: open ({u['status']} row); owner {f['owner']}; review {f['review']}")
    elif args.cmd == "follow-set":
        u, f = find_follow(data, args.ref)
        if not (args.what or args.next or args.owner or args.review or args.done or args.dropped or args.note):
            raise SystemExit("follow-set: give --what, --next, --owner, --review, --done, --dropped or --note")
        t = stamp(args.at)
        said = []
        for k in ("what", "next"):
            if getattr(args, k):
                f[k] = getattr(args, k).strip()
                said.append(f"{k} set")
        if args.owner:
            f["owner"] = follow_owner(args.owner)
            said.append(f"owner {f['owner']}")
        if args.review:
            f["review"] = review_at(args.review, t)
            said.append(f"review {f['review']}")
        if args.note:
            f["note"] = args.note
            said.append("note set")
        if args.done or args.dropped:
            if f.get("state", "open") != "open":
                raise SystemExit(f"{args.ref} is {f['state']} already")
            f["state"], f["closed"] = ("done" if args.done else "dropped"), t
            said.append(f"{f['state']} {t}")
        write(args.file, data)
        print(f"{args.ref}: " + "; ".join(said))
    elif args.cmd == "defer":
        if "/" in args.ref:
            u, x = find_follow(data, args.ref)
            if x.get("state", "open") != "open":
                raise SystemExit(f"{args.ref} is {x['state']}: only open follow-ups wait")
        else:
            x = find(data, args.ref)
            if x["status"] != "planned":
                raise SystemExit(f"{args.ref} is {x['status']}: a deferred reason is for a planned row (or an open follow-up, ID/N)")
        t = stamp(args.at)
        x.setdefault("deferred", []).append({"at": t, "reason": args.reason.strip()})
        write(args.file, data)
        print(f"{args.ref}: deferred {t}: {args.reason.strip()}")
    elif args.cmd == "follow-candidates":
        print("\n".join(candidates(data, args.runs) or ["no Live row promises anything in its text"]))
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


def follow_lines(data, now):
    """(batch322) the open follow-ups past their review at now, whatever their row's status, oldest review first."""
    links = updates.batch_rows(data["updates"])
    fl = [(u, f) for u in data["updates"] for f in updates.open_follow(u)]
    due = sorted(((u, f) for u, f in fl if updates.follow_due(f, now)), key=lambda x: (updates.when(x[1]["review"]), x[0]["id"], x[1]["n"]))
    out = [f"follow-ups: {len(due)} of {len(fl)} open past their review (rows of any status, Live included), oldest review first"]
    for u, f in due:
        to = updates.owner_link(f["owner"], links)
        out.append(f"  {u['id']}/{f['n']}  ({u['status']} row)  owner {f['owner']}" + (f" (row {to})" if to and to != u["id"] else "")
                   + f"  next: {f['next']}  review due since {f['review']}  open {updates.ago(updates.when(f['opened']), now)}"
                   + f"  what: {f['what']}")
    return out


def ready_lines(data, now, days):
    """(batch322) ready work waiting longer than days: planned rows (since planned, or planned again) and open follow-ups
    (since opened), by priority (urgent, normal, later, not set; a follow-up has its row's), oldest first, each with its
    newest deferred reason or "no reason"."""
    order = {p: i for i, p in enumerate(updates.PRIORITIES)}
    items = []
    for u in data["updates"]:
        if u["status"] == "planned":
            items.append((u.get("priority"), updates.stage(u), u["id"], u))
        for f in updates.open_follow(u):
            items.append((u.get("priority"), updates.when(f["opened"]), f"{u['id']}/{f['n']}", f))
    limit = datetime.timedelta(days=days)
    old = sorted((x for x in items if x[1] and now - x[1] > limit), key=lambda x: (order.get(x[0], len(order)), x[1], x[2]))
    out = [f"ready longer than {days:g} d: {len(old)} of {len(items)} (planned rows and open follow-ups), by priority, oldest first"]
    for prio, since, label, x in old:
        d = updates.deferred_reason(x)
        out.append(f"  {label}  priority {prio or 'not set'}  waiting {updates.ago(since, now)}  "
                   + (f"deferred {d['at']}: {d['reason']}" if d else "no reason"))
    return out


if __name__ == "__main__":
    main()
