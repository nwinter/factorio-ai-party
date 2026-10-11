#!/usr/bin/env python3
"""After an agy turn: did it end on a quota error? For the loop in .agy-loop.sh (tools/launch-agent.sh).

  tools/agy-quota.py DIR STAMP DEADLINE_EPOCH

Looks through agy's logs written since STAMP's mtime (agy writes one ~/.gemini/antigravity-cli/log/cli-*.log per run,
naming its workspace) for "RESOURCE_EXHAUSTED (code 429) ... Resets in 1h7m24s" from this workspace. If there is one,
appends an agy-quota event to DIR/context.log and prints the seconds to sleep until the reset, or "stop" (and an
agy-quota-stop event) when the reset comes after the deadline. Prints nothing otherwise. shake5: agy relaunched every
2.5 s, 277 times, on the same 429 (docs/studies/shake5.md, P1 item 6).
"""
import glob
import json
import os
import re
import sys
import time

LOGS = os.path.expanduser(os.environ.get("POG_AGY_LOGS", "~/.gemini/antigravity-cli/log"))
UNKNOWN_WAIT = 300   # a 429 without "Resets in": try again in 5 minutes
SLACK = int(os.environ.get("POG_AGY_SLACK", 30))       # past the stated reset, so the next try is not a second early
MIN_WAIT = int(os.environ.get("POG_AGY_MIN_WAIT", 10))


def find(d, since):
    """(log line time, reset seconds or None, message) of the latest quota error from workspace d, or None."""
    real = os.path.realpath(d)
    hit = None
    for path in glob.glob(os.path.join(LOGS, "cli-*.log")):
        try:
            if os.path.getmtime(path) < since:
                continue
            text = open(path, errors="replace").read()
        except OSError:
            continue
        if f"workspaceDirs=[{real}]" not in text and f"workspaceDirs=[{d}]" not in text:
            continue
        for line in text.splitlines():
            # A quota stop names its reset ("Individual quota reached ... Resets in"); a passing rate limit does not.
            if "RESOURCE_EXHAUSTED" not in line or not ("Resets in" in line or "quota" in line.lower()):
                continue
            m = re.match(r"[EWI](\d\d)(\d\d) (\d\d):(\d\d):(\d\d)", line)
            at = os.path.getmtime(path)
            if m:
                mon, day, hh, mm, ss = map(int, m.groups())
                at = time.mktime((time.localtime().tm_year, mon, day, hh, mm, ss, 0, 0, -1))
            r = re.search(r"Resets in (?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", line)
            reset = (int(r.group(1) or 0) * 3600 + int(r.group(2) or 0) * 60 + int(r.group(3) or 0)) if r else None
            msg = line[line.index("RESOURCE_EXHAUSTED"):][:200]
            if hit is None or at >= hit[0]:
                hit = (at, reset, msg)
    return hit


def main():
    d, stamp, deadline = sys.argv[1], sys.argv[2], int(sys.argv[3])
    try:
        since = os.path.getmtime(stamp if os.path.isabs(stamp) else os.path.join(d, stamp)) - 1
    except OSError:
        since = time.time() - 3600
    hit = find(d, since)
    if not hit:
        return
    at, reset, msg = hit
    now = time.time()
    until = (at + reset + SLACK) if reset is not None else now + UNKNOWN_WAIT
    wait = max(int(until - now), MIN_WAIT)
    stop = now + wait >= deadline - 20
    event = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "agy-quota-stop" if stop else "agy-quota",
             "resets": time.strftime("%H:%M:%S", time.localtime(until)), "sleep": 0 if stop else wait, "error": msg}
    with open(os.path.join(d, "context.log"), "a") as f:
        f.write(json.dumps(event) + "\n")
    print("stop" if stop else wait)


if __name__ == "__main__":
    main()
