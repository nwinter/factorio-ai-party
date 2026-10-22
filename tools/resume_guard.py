#!/usr/bin/env python3
"""The tick a resumed shift starts at against the previous run's last: tools/resume_guard.py PREV_DIR TICK [SAVE]

The previous run's last tick: its stopped.json (tools/stop_save.py: the tick of its stop save), else the last score in
its scores.jsonl. Prints one line for start.log; exits 1 when the world is behind that by more than
POG_RESUME_TICK_SLACK ticks (default 64800, 18 game minutes: world n autosaves every 15 minutes since d22 06:15, so
after a crash, with no stop save, the newest autosave is up to 15 minutes older than the last score), so
tools/start-team.sh refuses to go on (operator 17:00: shift13 started 3 game hours back from a stale save).
"""
import json
import os
import sys

SLACK = 64800  # 18 game minutes: one 15-minute autosave interval and a margin


def span(ticks):
    m = abs(int(ticks)) // 3600
    return f"{m // 60}h{m % 60:02d}m" if m >= 60 else f"{m}m"


def previous(prev_dir):
    """(tick, where it comes from) of the previous run's end, or (None, why not)."""
    p = os.path.join(prev_dir, "stopped.json")
    if os.path.exists(p):
        try:
            rec = json.load(open(p))
            if isinstance(rec.get("tick"), int):
                return rec["tick"], f"stopped.json: its stop save {rec.get('save') or '(via ' + str(rec.get('via')) + ')'}"
        except ValueError:
            pass
    best = None
    p = os.path.join(prev_dir, "scores.jsonl")
    if os.path.exists(p):
        for line in open(p):
            try:
                t = json.loads(line)["score"]["tick"]
            except (ValueError, KeyError, TypeError):
                continue
            best = t if best is None or t > best else best
    if best is not None:
        return best, "its last score in scores.jsonl"
    return None, "no stopped.json or scores.jsonl in " + prev_dir


def check(tick, prev_tick, source, save="", slack=SLACK):
    """(ok, line)."""
    at = f"resumed at tick {tick} (game {span(tick)})" + (f" from {save}" if save else "")
    if prev_tick is None:
        return True, f"{at}; the previous run's last tick is unknown ({source})"
    d = tick - prev_tick
    line = f"{at}; the previous run's last tick {prev_tick} ({source}): {'+' if d >= 0 else '-'}{abs(d)} ticks"
    if d < -slack:
        return False, (f"{line}: the world went back {span(-d)} of game time, more than {span(slack)}: an old save; "
                       "refusing to start the shift on it")
    return True, line


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    prev_tick, source = previous(sys.argv[1])
    ok, line = check(int(sys.argv[2]), prev_tick, source, sys.argv[3] if len(sys.argv) > 3 else "",
                     int(os.environ.get("POG_RESUME_TICK_SLACK", str(SLACK))))
    print(line)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
