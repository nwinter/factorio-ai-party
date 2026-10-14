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


BRIEF = os.path.expanduser(os.environ.get("POG_AGY_BRIEF", "~/.cache/ai-usage/agent-brief.json"))
PACE = os.path.expanduser(os.environ.get("POG_AGY_PACE", "~/.cache/pog/agy-pace.json"))
PACE_CAP = float(os.environ.get("POG_AGY_PACE_CAP", 97))        # % of the weekly window to reach at its reset
FULL_RATE = float(os.environ.get("POG_AGY_FULL_RATE", 1.75))    # %/h of the weekly window at full play (shift10-12)
MAX_SLEEP = int(os.environ.get("POG_AGY_PACE_MAX", 3 * 3600))


def weekly():
    """(percent used, reset epoch) of agy's Gemini weekly window from the ai-usage brief (refreshed when 20+ min old)."""
    def read():
        d = json.load(open(BRIEF))
        for a in d.get("profiles", []):
            if a.get("command") == "agy":
                for w in a.get("windows", []):
                    if w.get("key") == "agy:gemini:10080":
                        return float(w.get("percent") or 0), float(w.get("resets_at") or 0), a.get("observed_at") or 0
        return None
    try:
        got = read()
        if got and time.time() - got[2] > 1200:
            import subprocess
            subprocess.run(["/Users/owner/.local/bin/ai-usage", "agent", "--json"], capture_output=True, timeout=90)
            got = read() or got
        return got[:2] if got else None
    except Exception:
        return None


def pace(d, since, deadline):
    """Nick 15:50/16:50: pace Gemini so its weekly window lasts until its reset. After each turn, sleep so play keeps
    the duty cycle the budget allows (allowed %/h over FULL_RATE), lengthened while usage is above a straight line from
    where pacing began to PACE_CAP at the reset, shortened while below it. POG_AGY_PACE=off turns it off."""
    if os.environ.get("POG_AGY_PACE", "").lower() == "off":
        return None
    w = weekly()
    if not w or not w[1]:
        return None
    used, reset = w
    now = time.time()
    if reset <= now:
        return None
    try:
        st = json.load(open(PACE))
    except Exception:
        st = {}
    if st.get("reset") != reset:  # a new window (or first use): anchor the line here
        st = {"reset": reset, "t0": now, "u0": used}
        os.makedirs(os.path.dirname(PACE), exist_ok=True)
        json.dump(st, open(PACE, "w"))
    t0, u0 = st["t0"], st["u0"]
    line = u0 + (PACE_CAP - u0) * (now - t0) / max(reset - t0, 1)
    allowed = max(PACE_CAP - used, 0) / max((reset - now) / 3600, 0.1)   # %/h left to spend
    duty = min(max(allowed / FULL_RATE, 0.03), 1.0)
    took = max(now - since - 1, 30)
    wait = took * (1 / duty - 1)
    ahead = used - line
    if ahead > 0:
        wait += ahead / max(allowed, 0.01) * 3600 * 0.5   # catch half the excess back this sleep
    elif ahead < -1:
        wait *= 0.5
    wait = int(min(wait, MAX_SLEEP))
    if wait < 60:
        return None
    stop = now + wait >= deadline - 20
    event = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "agy-pace", "used": used, "line": round(line, 2),
             "allowed_per_h": round(allowed, 3), "duty": round(duty, 3), "turn_s": int(took),
             "sleep": 0 if stop else wait, "resets": time.strftime("%a %H:%M", time.localtime(reset))}
    with open(os.path.join(d, "context.log"), "a") as f:
        f.write(json.dumps(event) + "\n")
    return "stop" if stop else wait


def main():
    d, stamp, deadline = sys.argv[1], sys.argv[2], int(sys.argv[3])
    try:
        since = os.path.getmtime(stamp if os.path.isabs(stamp) else os.path.join(d, stamp)) - 1
    except OSError:
        since = time.time() - 3600
    hit = find(d, since)
    if not hit:
        wait = pace(d, since, deadline)
        if wait:
            print("stop" if wait == "stop" else wait)
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
