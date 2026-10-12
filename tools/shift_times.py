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


if __name__ == "__main__":
    print(json.dumps(shift(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.environ.get("POG_NEXT_SHIFT", ""))))
