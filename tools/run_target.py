#!/usr/bin/env python3
"""The run's target, a fact every agent sees across shifts (d27 batch277 RT, Nick d27 11:25: "a soft deadline, so the
agents keep being reminded they are trying to reach the Shattered Planet by Friday night; the run's end is not
decided").

  python3 tools/run_target.py set RUN --goal "the Shattered Planet" --at "2026-10-30 23:59 PDT" [--by Nick]
                                       [--kind soft|hard] [--note "the run's end is not fixed"]
  python3 tools/run_target.py show RUN      the line an agent's status shows now
  python3 tools/run_target.py clear RUN     no target from now on (this run and the shifts after it)
  python3 tools/run_target.py carry PREV_DIR NEXT_DIR   (start-team, POG_RESUME) PREV's target to NEXT unless NEXT has one

runs/RUN/target.json holds it. fh puts its line first in every status reply (factorio-harness host/target.ts; the run
folder is the journal's parent's parent), the time left computed at each read: "Target (Nick, soft): the Shattered
Planet by Fri Oct 30 23:59 PDT, 81 h 30 m from now; the run's end is not fixed." A soft target's note defaults to
"the run's end is not fixed". start-team carries it to each next shift until the operator changes or clears it. The
casters get it as a fact (caster.py run_target). Facts only.
"""
import argparse, datetime, json, os, re, shutil, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = "target.json"
SOFT_NOTE = "the run's end is not fixed"
ZONES = {"UTC": 0, "GMT": 0, "Z": 0, "PST": -8, "PDT": -7, "MST": -7, "MDT": -6, "CST": -6, "CDT": -5, "EST": -5,
         "EDT": -4}  # (host/deadline.ts has the same and more)
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
AT_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*([A-Za-z]{1,5}|[+-]\d{2}:?\d{2})?$")


def epoch(at):
    """"2026-10-30 23:59 PDT" (or an ISO time with an offset) -> Unix seconds, or None."""
    m = AT_RE.match(str(at).strip())
    if m:
        y, mo, d, h, mi, s, zone = m.groups()
        if zone and zone[0] in "+-":
            digits = zone.replace(":", "")
            off = (-1 if zone[0] == "-" else 1) * (int(digits[1:3]) + int(digits[3:5]) / 60)
        elif zone:
            off = ZONES.get(zone.upper())
            if off is None:
                return None
        else:
            return time.mktime((int(y), int(mo), int(d), int(h), int(mi), int(s or 0), 0, 0, -1))
        dt = datetime.datetime(int(y), int(mo), int(d), int(h), int(mi), int(s or 0), tzinfo=datetime.timezone.utc)
        return dt.timestamp() - off * 3600
    try:
        return datetime.datetime.fromisoformat(str(at).strip().replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def when_text(at):
    m = AT_RE.match(str(at).strip())
    if not m:
        return str(at).strip()
    y, mo, d, h, mi, _, zone = m.groups()
    day = DAYS[datetime.date(int(y), int(mo), int(d)).weekday()]
    return f"{day} {MONTHS[int(mo) - 1]} {int(d)} {int(h):02d}:{mi}" + (f" {zone}" if zone else "")


def hours(seconds):
    minutes = int(seconds // 60)
    return f"{minutes // 60} h {minutes % 60} m" if minutes >= 60 else f"{minutes} m"


def read(run_dir):
    try:
        with open(os.path.join(run_dir, NAME)) as f:
            t = json.load(f)
    except (OSError, ValueError):
        return None
    return t if isinstance(t, dict) and isinstance(t.get("goal"), str) and t["goal"].strip() and epoch(t.get("at")) else None


def line(t, now=None):
    """The status line (as host/target.ts writes it), or None."""
    if not t:
        return None
    now = time.time() if now is None else now
    at = epoch(t["at"])
    who = ", ".join(x for x in ((t.get("by") or "").strip() or None, "hard" if t.get("kind") == "hard" else "soft") if x)
    left = f"{hours(at - now)} from now" if at >= now else f"passed {hours(now - at)} ago"
    note = f"; {t['note'].strip().rstrip('.')}" if isinstance(t.get("note"), str) and t["note"].strip() else ""
    return f"Target ({who}): {t['goal'].strip()} by {when_text(t['at'])}, {left}{note}."


def fact(run_dir, now=None):
    """For the casters: {goal, by, kind, when, hours_left (or hours_past), note} or None."""
    t = read(run_dir) if run_dir else None
    if not t:
        return None
    now = time.time() if now is None else now
    left = (epoch(t["at"]) - now) / 3600
    out = {"goal": t["goal"].strip(), "set_by": t.get("by"), "kind": "hard" if t.get("kind") == "hard" else "soft",
           "when": when_text(t["at"])}
    out.update({"hours_left": round(left, 1)} if left >= 0 else {"hours_past": round(-left, 1)})
    if t.get("note"):
        out["note"] = t["note"]
    return {k: v for k, v in out.items() if v is not None}


def carry(prev_dir, next_dir):
    """PREV's target to NEXT (a shift change), unless NEXT has its own: True when copied."""
    src, dst = os.path.join(prev_dir, NAME), os.path.join(next_dir, NAME)
    if os.path.exists(dst) or not read(prev_dir):
        return False
    shutil.copyfile(src, dst)
    return True


def run_dir_of(run):
    """RUN (runs/RUN in this checkout) or a path."""
    return run if os.sep in run else os.path.join(ROOT, "runs", run)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set")
    s.add_argument("run")
    s.add_argument("--goal", required=True)
    s.add_argument("--at", required=True, help='"2026-10-30 23:59 PDT"')
    s.add_argument("--by")
    s.add_argument("--kind", choices=("soft", "hard"), default="soft")
    s.add_argument("--note", help=f'default for soft: "{SOFT_NOTE}"; "" for none')
    for name in ("show", "clear"):
        sub.add_parser(name).add_argument("run")
    c = sub.add_parser("carry")
    c.add_argument("prev_dir")
    c.add_argument("next_dir")
    a = ap.parse_args(argv)
    if a.cmd == "carry":
        print(f"target carried from {a.prev_dir}" if carry(a.prev_dir, a.next_dir) else "no target to carry")
        return 0
    d = run_dir_of(a.run)
    if not os.path.isdir(d):
        print(f"no run directory {d}", file=sys.stderr)
        return 2
    if a.cmd == "set":
        if epoch(a.at) is None:
            print(f'--at {a.at!r}: write "YYYY-MM-DD HH:MM ZONE" (PDT, PST, UTC...) or an ISO time', file=sys.stderr)
            return 2
        t = {"goal": a.goal, "at": a.at, "by": a.by, "kind": a.kind,
             "note": a.note if a.note is not None else (SOFT_NOTE if a.kind == "soft" else None)}
        t = {k: v for k, v in t.items() if v}
        tmp = os.path.join(d, NAME + ".tmp")
        with open(tmp, "w") as f:
            json.dump(t, f, indent=1)
        os.replace(tmp, os.path.join(d, NAME))
    elif a.cmd == "clear":
        try:
            os.remove(os.path.join(d, NAME))
        except FileNotFoundError:
            pass
        print("cleared: no target line from the next status on")
        return 0
    print(line(read(d)) or "no target set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
