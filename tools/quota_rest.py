#!/usr/bin/env python3
"""Mark an agent resting for a run, or end its rest (d22 batch108 BR1: Grok's account hit its weekly limit at 20:04,
reset Sat Oct 24 15:59, and the rest had to be written by importing tools/agy-quota.py by hand).

  tools/quota_rest.py RUN AGENT --until "YYYY-MM-DD HH:MM" [--reason quota|pace]
  tools/quota_rest.py RUN AGENT --done
  tools/quota_rest.py --at-limit RUN TEAM_FILE [--carry PREV_RUN] [--brief FILE] [--now EPOCH] [--dry-run]

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

--carry PREV_RUN with --at-limit (d24 batch172, viewer Aurora 16:05: Muse's rest until Sun 17:00, marked by hand in
shift69, was gone in shift70 because ai-usage read its account stale, and it was nudged every 20 min): every rest of
the previous run that has not ended (its resting.json: until ahead, no request of the agent's own since it began; quota
or pace, by hand or by --at-limit) is written again in the new run, until the same time, whatever ai-usage says. Only a
fresh reading (quota_check.room: the brief under 30 min old, the profile not stale) that gives the account room ends a
quota rest there; a pace rest is the operator's or the loop's choice with room, so it is carried anyway. An account at
its limit rests until the later of its reset and the carried rest.

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
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
import pacing  # noqa: E402  (an agent's rest now: until ahead, no request of its own since)

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


def mark(d, until, reason, now=None, **extra):
    """Write and push the rest; (line, ok). extra: more fields for resting.json (carried_from)."""
    now = now or time.time()
    wait = until - now
    name = os.path.basename(d.rstrip(os.sep))
    if wait <= 0:
        return f"{name}: {time.strftime('%Y-%m-%d %H:%M', time.localtime(until))} is not ahead; nothing written", False
    if wait > MAX_S:
        return f"{name}: {round(wait / 86400, 1)} days ahead; a rest lasts at most 7 days; nothing written", False
    # (d24 batch172) the wait from the clock agy-quota writes with, so the file keeps `until` (a carried rest's own end)
    err = aq.rest(d, until - time.time(), reason, resets=when(until), **extra)
    line = f"{name}: resting until {when(until)} ({reason}), {os.path.join(d, aq.REST)}"
    return (line + ("; pushed" if err is None else f"; not pushed: {err}")), err is None or err.startswith("off")


def done(d):
    name = os.path.basename(d.rstrip(os.sep))
    row = aq.end_rest(d)
    if row is None:
        return f"{name}: no rest on record ({os.path.join(d, aq.REST)})", True
    return f"{name}: rest ended (was until {when(row['until'])}); resting-last.json", True


def previous(prev, name, now):
    """The previous run's rest of `name` that has not ended (pacing.resting: until ahead, no request of its own since
    it began), or None. (d24 batch175 QR2) A run where `name` has no resting.json and did not play (full_tools.played:
    a start killed before its rests were written) passes the question up its resumed-from chain."""
    if not prev:
        return None
    import full_tools
    for run in full_tools.chain(prev):
        d = os.path.join(run, name)
        if os.path.exists(os.path.join(d, pacing.REST)) or full_tools.played(run, name):
            return pacing.resting(d, now)
    return None


def at_limit(rd, team, brief_path=None, now=None, dry=False, prev=None):
    """Lines for start.log, and whether every push went through. prev: the previous run's directory (--carry)."""
    now = now or time.time()
    brief, note = None, None
    if brief_path and not os.path.isfile(brief_path):
        note = f"no quota data saved in {brief_path}"
    else:
        brief, note = quota_check.load_brief(brief_path)
    hits = quota_check.at_limit(brief, team, now) if brief is not None else {}
    room = quota_check.room(brief, team, now, hits) if brief is not None else {}
    names = [m[0] for m in quota_check.members(team)]
    carried = {n: r for n in names for r in [previous(prev, n, now)] if r}
    pname = os.path.basename(prev.rstrip(os.sep)) if prev else None
    lines, ok = [], True
    if not hits:
        lines.append(f"quota rests: {'none' if brief is None else 'no agent' + chr(39) + 's account at its limit'} ({note})")
    for name in names:
        h, c = hits.get(name), carried.get(name)
        if not (h or c):
            continue
        d = os.path.join(rd, name)
        if c and not h and c.get("reason") == "quota" and name in room:
            lines.append(f"quota rest: {name}: {pname}'s rest until {when(c['until'])} (quota) not carried: a fresh "
                         f"reading has room ({room[name]})")
            continue
        if h and (not c or h["reset"] >= c["until"]):
            until, reason = h["reset"], "quota"
            what = f"{h['profile']} {h['window']} {h['percent']:.0f}%, resets {when(h['reset'])}"
        else:
            until, reason = c["until"], c.get("reason") or "quota"
            what = f"carried from {pname}: its rest from {time.strftime('%a %H:%M', time.localtime(c['since']))}" \
                if isinstance(c.get("since"), (int, float)) else f"carried from {pname}"
            if h:
                what += f"; {h['profile']} {h['window']} {h['percent']:.0f}% resets sooner, {when(h['reset'])}"
            elif name not in room:
                what += "; no fresh reading of its account" if c.get("reason") == "quota" else "; a pace rest"
        if dry:
            lines.append(f"quota rest: {name} would rest until {when(until)} ({reason}; {what})")
            continue
        if not os.path.isdir(d):
            lines.append(f"quota rest: {name} has no workspace {d}; not written ({what})")
            continue
        line, good = mark(d, until, reason, now, carried_from=pname if until == (c or {}).get("until") else None)
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
        brief, now, prev = opt(args, "--brief"), opt(args, "--now"), opt(args, "--carry")
        if len(args) != 2:
            print(__doc__, file=sys.stderr)
            sys.exit(2)
        rd = run_dir(args[0]) or (args[0] if os.sep in args[0] else os.path.join(ROOT, "runs", args[0]))
        pd = prev and (run_dir(prev) or prev)
        lines, ok = at_limit(rd, args[1], brief, float(now) if now else None, dry,
                             pd if pd and os.path.isdir(pd) else None)
        if prev and not (pd and os.path.isdir(pd)):
            lines.append(f"quota rests: no previous run {prev} to carry rests from")
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
