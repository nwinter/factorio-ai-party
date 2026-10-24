#!/usr/bin/env python3
"""The site's Operator updates (site/content/operator-updates.json, the /updates/ page; d23 batch119 CB4, viewer
Aurora site:4349, site:4350): add a change, move it to its next status, add a status notice, list what is open.

  tools/operator_updates.py add ID --title T --by NAME [--ref site:4386|#1925] [--by NAME --ref REF ...]
                                [--status planned] [--area harness|stream|site] [--work "batch119 CB1"] [--note N]
                                [--reply site:4407] [--at "YYYY-MM-DD HH:MM"]
  tools/operator_updates.py set ID [--status in\\ progress|live|verified] [--note N] [--work W] [--reply REF] [--at ...]
  tools/operator_updates.py notice --kind deploy|restart|rest|outage|shift --text T [--at ...]
  tools/operator_updates.py list [--all]

--at is Pacific time (the default: now). add records the status's date, and "asked" when --asked is given; set
records the new status's date and keeps the earlier ones. A note is kept with when it was written and under which
status (note_at, note_status); set --note moves the note it replaces into the row's history, dated, and the page shows
that history folded under the current note (viewer Aurora 18:46: live rows still said "not yet given to an engineer").
A status past planned needs the work (batch) that did it: add and set refuse one without --work when the row has none,
and list marks such rows ("no work") as the build does. The page is rebuilt with the site (site/build.py), which
quotes each site:NNNN message and the operator's replies to it from the run folders. --file names another JSON (tests).
"""
import argparse, datetime, json, os, sys
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


def needs_work(uid, status, work):
    if status != "planned" and not work:
        raise SystemExit(f"{uid}: {status} needs --work, the batch that did it (the row has none)")


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
    s = sub.add_parser("set")
    s.add_argument("id")
    s.add_argument("--status", choices=updates.STATUSES)
    s.add_argument("--note")
    s.add_argument("--work")
    s.add_argument("--reply", action="append", default=[])
    s.add_argument("--at")
    n = sub.add_parser("notice")
    n.add_argument("--kind", required=True, choices=updates.NOTICE_KINDS)
    n.add_argument("--text", required=True)
    n.add_argument("--at")
    ls = sub.add_parser("list")
    ls.add_argument("--all", action="store_true")
    args = ap.parse_args(argv)
    data = read(args.file)
    data.setdefault("updates", [])
    data.setdefault("notices", [])

    if args.cmd == "add":
        if any(u.get("id") == args.id for u in data["updates"]):
            raise SystemExit(f"update {args.id!r} exists: use set")
        if len(args.ref) > len(args.by):
            raise SystemExit("each --ref needs its --by")
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
        data["updates"].append(row)
        write(args.file, data)
        print(f"added {args.id}: {args.status}")
    elif args.cmd == "set":
        u = find(data, args.id)
        if not (args.status or args.note or args.work or args.reply):
            raise SystemExit("set: give --status, --note, --work or --reply")
        t = stamp(args.at)
        status = args.status or u["status"]
        needs_work(args.id, status, args.work or u.get("work"))
        said = []
        if args.status:
            u["status"] = args.status
            u.setdefault("dates", {})[args.status] = t
            said.append(f"{args.status} {t}")
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
        write(args.file, data)
        print(f"{args.id}: " + ("; ".join(said) or "updated"))
    elif args.cmd == "notice":
        data["notices"].append({"t": stamp(args.at), "kind": args.kind, "text": args.text})
        write(args.file, data)
        print(f"notice: {args.kind}")
    else:
        for u in data["updates"]:
            if args.all or u.get("status") != "verified":
                refs = ", ".join(f"{r.get('name')} {r.get('ref') or ''}".strip() for r in u.get("requested_by") or [])
                flag = "  (no work)" if u.get("status") != "planned" and not u.get("work") else ""
                print(f"{u['status']:<12} {u['id']:<28} {u['title']}" + (f"  [{refs}]" if refs else "") + flag)


if __name__ == "__main__":
    main()
