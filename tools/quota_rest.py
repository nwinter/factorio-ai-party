#!/usr/bin/env python3
"""Mark an agent resting for a run, or end its rest (d22 batch108 BR1: Grok's account hit its weekly limit at 20:04,
reset Sat Oct 24 15:59, and the rest had to be written by importing tools/agy-quota.py by hand).

  tools/quota_rest.py RUN AGENT --until "YYYY-MM-DD HH:MM" [--reason quota|pace]
  tools/quota_rest.py RUN AGENT --done
  tools/quota_rest.py --at-limit RUN TEAM_FILE [--brief FILE] [--now EPOCH] [--dry-run]

RUN is a run id (runs/RUN here, else in ~/code/player-of-games) or a run directory; --until is this Mac's local time,
at most 7 days ahead. The first form writes runs/RUN/AGENT/resting.json {since, until, reason, sleep_s, resets}, as
tools/agy-quota.py does before the agy loop sleeps, and pushes the rest to the world and bot the workspace's ./fh names
(an operator `rest` request, rests.lua: "resting until Sat 15:59 (quota)" on the teammates line and in tell replies).
The stream's agent card, tools/supervise.sh and tools/idle_nudge.py read resting.json (tools/stream/pacing.py). --done
moves resting.json to resting-last.json and pushes the end. The rest also ends at its time, and at the agent's own next
request (the runtime and pacing.py both).

--at-limit (tools/start-team.sh, once the agents' workspaces exist and the runtime is deployed): each team member whose
account tools/quota_check.py reads at its limit now (a window at 99% or more with its reset ahead) gets a quota rest
until that reset; the others nothing. One line per rest; --dry-run writes and pushes nothing.

Exit 1 when a push failed (resting.json is written; the line says why), 2 on a bad argument.
"""
import importlib.util
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import quota_check  # noqa: E402

_spec = importlib.util.spec_from_file_location("agy_quota", os.path.join(ROOT, "tools", "agy-quota.py"))
aq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aq)

MAX_S = 7 * 86400   # rests.lua's limit
REASONS = ("quota", "pace")


def run_dir(run):
    """A run directory given as a path, else runs/RUN here, else in the main checkout; None."""
    if os.sep in run:
        return run if os.path.isdir(run) else None
    for d in (os.path.join(ROOT, "runs", run), os.path.expanduser(f"~/code/player-of-games/runs/{run}")):
        if os.path.isdir(d):
            return d
    return None


def when(t):
    """'Sat 15:59' (the resets field and the lines here)."""
    return f"{aq.DAYS[time.localtime(t).tm_wday]} {time.strftime('%H:%M', time.localtime(t))}"


def mark(d, until, reason, now=None):
    """Write and push the rest; (line, ok)."""
    now = now or time.time()
    wait = until - now
    name = os.path.basename(d.rstrip(os.sep))
    if wait <= 0:
        return f"{name}: {time.strftime('%Y-%m-%d %H:%M', time.localtime(until))} is not ahead; nothing written", False
    if wait > MAX_S:
        return f"{name}: {round(wait / 86400, 1)} days ahead; a rest lasts at most 7 days; nothing written", False
    err = aq.rest(d, wait, reason, resets=when(until))
    line = f"{name}: resting until {when(until)} ({reason}), {os.path.join(d, aq.REST)}"
    return (line + ("; pushed" if err is None else f"; not pushed: {err}")), err is None or err.startswith("off")


def done(d):
    name = os.path.basename(d.rstrip(os.sep))
    row = aq.end_rest(d)
    if row is None:
        return f"{name}: no rest on record ({os.path.join(d, aq.REST)})", True
    return f"{name}: rest ended (was until {when(row['until'])}); resting-last.json", True


def at_limit(rd, team, brief_path=None, now=None, dry=False):
    """Lines for start.log, and whether every push went through."""
    if brief_path and not os.path.isfile(brief_path):
        return [f"quota rests: none (no quota data saved in {brief_path})"], True
    brief, note = quota_check.load_brief(brief_path)
    if brief is None:
        return [f"quota rests: none ({note})"], True
    hits = quota_check.at_limit(brief, team, now)
    if not hits:
        return [f"quota rests: no agent's account at its limit ({note})"], True
    lines, ok = [], True
    for name, h in sorted(hits.items()):
        d = os.path.join(rd, name)
        what = f"{h['profile']} {h['window']} {h['percent']:.0f}%, resets {when(h['reset'])}"
        if dry:
            lines.append(f"quota rest: {name} would rest until {when(h['reset'])} ({what})")
            continue
        if not os.path.isdir(d):
            lines.append(f"quota rest: {name} has no workspace {d}; not written ({what})")
            continue
        line, good = mark(d, h["reset"], "quota", now)
        lines.append(f"quota rest: {line} ({what})")
        ok = ok and good
    return lines, ok


def opt(args, flag, default=None):
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args):
            sys.exit(2)
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


def main():
    args = sys.argv[1:]
    if "--at-limit" in args:
        args.remove("--at-limit")
        dry = "--dry-run" in args
        if dry:
            args.remove("--dry-run")
        brief, now = opt(args, "--brief"), opt(args, "--now")
        if len(args) != 2:
            print(__doc__, file=sys.stderr)
            sys.exit(2)
        rd = run_dir(args[0]) or (args[0] if os.sep in args[0] else os.path.join(ROOT, "runs", args[0]))
        lines, ok = at_limit(rd, args[1], brief, float(now) if now else None, dry)
        print("\n".join(lines))
        sys.exit(0 if ok else 1)
    until, reason = opt(args, "--until"), opt(args, "--reason", "quota")
    end = "--done" in args
    if end:
        args.remove("--done")
    if len(args) != 2 or (until is None) == (not end) or reason not in REASONS:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    rd = run_dir(args[0])
    d = rd and os.path.join(rd, args[1])
    if not d or not os.path.isdir(d):
        print(f"no workspace {args[1]} in run {args[0]}", file=sys.stderr)
        sys.exit(2)
    if end:
        line, ok = done(d)
    else:
        try:
            t = time.mktime(time.strptime(until, "%Y-%m-%d %H:%M"))
        except ValueError:
            print(f'--until must be "YYYY-MM-DD HH:MM" (local time): {until}', file=sys.stderr)
            sys.exit(2)
        line, ok = mark(d, t, reason)
    print(line)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
