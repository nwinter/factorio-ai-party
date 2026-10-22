#!/usr/bin/env python3
"""A shift's times for the stream state and the site (start-team.sh writes them into the run's stream.json):

    python3 tools/shift_times.py MINUTES [NEXT]    # prints {"start", "end", "next", "next_exact"} as JSON

Shifts run back to back, so the next is expected when this one ends. NEXT (or $POG_NEXT_SHIFT) sets it: "02:47" (the
next such time, today or tomorrow), an ISO time ("2026-10-12T02:47:00-07:00"), or "none" (no next shift).
"""
import datetime, json, os, sys, time


def shift(minutes, next_spec="", now=None):
    start = time.time() if now is None else now
    end = start + float(minutes) * 60
    spec = (next_spec or "").strip()
    if spec.lower() == "none":
        return {"start": round(start), "end": round(end), "next": None, "next_exact": True}
    nxt, exact = end, False
    if spec:
        try:
            if len(spec) <= 5:
                h, m = map(int, spec.split(":"))
                t = datetime.datetime.fromtimestamp(start).replace(hour=h, minute=m, second=0, microsecond=0)
                if t.timestamp() < start:
                    t += datetime.timedelta(days=1)
                nxt = t.timestamp()
            else:
                nxt = datetime.datetime.fromisoformat(spec).timestamp()
            exact = True
        except ValueError:
            print(f"next shift {spec!r} is not HH:MM, an ISO time or none: expected at this shift's end", file=sys.stderr)
    return {"start": round(start), "end": round(end), "next": round(nxt), "next_exact": exact}


def earlier_runs(run_dir):
    """The earlier shifts of a resumed run's world, newest first, along runs/RUN/resumed-from (written by
    tools/start-team.sh with POG_RESUME); [] for a first shift. No cap on its length (d22 batch89 AY1: a 50 cap made every
    shift from 52 on read as shift 51 to the harness, the hosts and the video titles); a run already in the chain ends it."""
    root, chain = os.path.dirname(os.path.normpath(run_dir)), []
    path = os.path.join(run_dir, "resumed-from")
    while True:
        try:
            run = open(path).read().strip()
        except OSError:
            break
        if not run or run in chain:
            break
        chain.append(run)
        path = os.path.join(root, run, "resumed-from")
    return chain


def shift_number(run_dir):
    """This run's shift number in its world: 1 + the earlier shifts (the stream hosts' count, tools/stream/caster.py,
    and the harness's shift block, tools/start-team.sh)."""
    return len(earlier_runs(run_dir)) + 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["number"]:   # python3 tools/shift_times.py number RUN_DIR
        print(shift_number(sys.argv[2]))
    else:
        print(json.dumps(shift(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.environ.get("POG_NEXT_SHIFT", ""))))
