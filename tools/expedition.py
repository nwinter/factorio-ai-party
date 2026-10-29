#!/usr/bin/env python3
"""The expedition's own clock for the brief (d29 batch336 FL7; batch321: "deadline" in the agents' team text meant the
4-hour shift stop 118 times of 118, never the run's target).

tools/start-team.sh saves what the runtime's shift_start returned (its `expedition`: the world's tick, the solar system
edge's connection to the Shattered Planet and its length, each platform of ours at the edge or the Shattered Planet or
on a connection to either with the km left) as runs/RUN/expedition.json, with the wall time it was read. tools/brief.py
puts one line from it beside the deadline paragraph of every agent's AGENTS.md:

  Expedition clock, read at this shift's start (Thu Oct 29 08:58 PDT): the world's game time is 376h50m; the run's
  target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, 39 h 01 m after that; Resolute: on aquilo to
  solar-system-edge, 4,512,300 km from the Shattered Planet by the edge. `status` gives the target's time left now.

  python3 tools/expedition.py save RUN_DIR < shift_start_reply.json
  python3 tools/expedition.py line RUN_DIR
"""
import json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_target  # noqa: E402

NAME = "expedition.json"
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def game_time(tick):
    minutes = int(tick // 3600)
    return f"{minutes // 60}h{minutes % 60:02d}m"


def km(n):
    return f"{int(round(n)):,} km"


def save(run_dir, reply, now=None):
    """The shift_start reply's expedition, with the wall time; None (nothing written) without one."""
    exp = reply.get("expedition") if isinstance(reply, dict) else None
    if not isinstance(exp, dict) or not isinstance(exp.get("tick"), (int, float)):
        return None
    exp = dict(exp, read_at=time.time() if now is None else now)
    with open(os.path.join(run_dir, NAME), "w") as f:
        json.dump(exp, f)
    return exp


def platform_text(r):
    left = r.get("km_left")
    if r.get("at") == "shattered-planet":
        return f"{r['platform']}: at the Shattered Planet"
    if r.get("at"):
        return f"{r['platform']}: stopped at {r['at']}, {km(left)} from the Shattered Planet" if left is not None else f"{r['platform']}: stopped at {r['at']}"
    where = f"on {r.get('from')} to {r.get('to')}, {round(100 * (r.get('progress') or 0))}% along"
    via = "" if "shattered-planet" in (r.get("from"), r.get("to")) else " by the edge"
    return f"{r['platform']}: {where}, {km(left)} from the Shattered Planet{via}" if left is not None else f"{r['platform']}: {where}"


def line(run_dir):
    """The brief's line, or "" when no expedition was saved for this run."""
    try:
        with open(os.path.join(run_dir, NAME)) as f:
            exp = json.load(f)
    except (OSError, ValueError):
        return ""
    at = exp.get("read_at") or time.time()
    lt = time.localtime(at)
    when = f"{DAYS[lt.tm_wday]} {time.strftime('%b', lt)} {lt.tm_mday} {lt.tm_hour:02d}:{lt.tm_min:02d} {time.strftime('%Z', lt)}"
    parts = [f"the world's game time is {game_time(exp['tick'])}"]
    t = run_target.read(run_dir)
    if t:
        who = ", ".join(x for x in ((t.get("by") or "").strip() or None, "hard" if t.get("kind") == "hard" else "soft") if x)
        target_at = run_target.epoch(t["at"])
        rel = (f"{run_target.hours(target_at - at)} after that" if target_at >= at else f"passed {run_target.hours(at - target_at)} before that")
        parts.append(f"the run's target ({who}): {t['goal'].strip()} by {run_target.when_text(t['at'])}, {rel}")
    rows = exp.get("platforms") or []
    if rows:
        parts.append("; ".join(platform_text(r) for r in rows))
    else:
        leg = exp.get("edge_to_shattered_km")
        parts.append("no platform of ours is at the solar system edge, at the Shattered Planet or on a connection to either"
                     + (f" (solar-system-edge to shattered-planet: {km(leg)})" if leg else ""))
    tail = " `status` gives the target's time left now." if t else ""
    return f"Expedition clock, read at this shift's start ({when}): " + "; ".join(parts) + "." + tail


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in ("save", "line"):
        print(__doc__.strip().splitlines()[-2:][0].strip(), file=sys.stderr)
        return 2
    if argv[0] == "save":
        raw = sys.stdin.read()
        try:
            reply = json.loads(raw[raw.find("{"):]) if "{" in raw else None
        except ValueError:
            reply = None
        exp = save(argv[1], reply)
        print(f"saved {NAME}: tick {exp['tick']}, {len(exp.get('platforms') or [])} platform(s) on the route" if exp else "no expedition in the reply")
        return 0
    print(line(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
