#!/usr/bin/env python3
"""After an agy turn: did it end on a quota error? For the loop in .agy-loop.sh (tools/launch-agent.sh).

  tools/agy-quota.py DIR STAMP DEADLINE_EPOCH
  tools/agy-quota.py --woke DIR      (after the loop's sleep: the line for the next turn, and the rest is over)

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
PACE = os.path.expanduser(os.environ.get("POG_AGY_PACE_FILE", "~/.cache/pog/agy-pace.json"))
PACE_CAP = float(os.environ.get("POG_AGY_PACE_CAP", 97))        # % of the weekly window to reach at its reset
FULL_RATE = float(os.environ.get("POG_AGY_FULL_RATE", 1.75))    # %/h of the weekly window at full play (shift10-12)
MAX_SLEEP = int(os.environ.get("POG_AGY_PACE_MAX", 3 * 3600))


# The rest the loop is in, for the stream service and the supervisor (operator 17:17: "resting until 18:17 · pacing its
# weekly quota", not idle or offline): DIR/resting.json {since, until, reason (pace|quota), sleep_s, used?, resets?},
# written before the loop sleeps; --woke moves it to DIR/resting-last.json when the next turn starts.
REST = "resting.json"


def rest(d, wait, reason, **extra):
    now = time.time()
    row = dict({"since": round(now), "until": round(now + wait), "reason": reason, "sleep_s": int(wait)},
               **{k: v for k, v in extra.items() if v is not None})
    tmp = os.path.join(d, REST + ".tmp")
    with open(tmp, "w") as f:
        json.dump(row, f)
    os.replace(tmp, os.path.join(d, REST))
    return push(d, dict(clock_args(row["until"], now), until_s=max(1, int(wait)), reason=reason,
                        ticks_per_s=ticks_per_s(d)))


DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def clock_args(until, now=None):
    """The rest's end for rests.lua: until_clock HH:MM, and until_day (Mon..Sun) when it falls on another date than
    `now` on this Mac's clock, the shift clock (d22 batch108 BR1: a weekly limit at 20:04 Thursday, reset Sat 15:59)."""
    t, n = time.localtime(until), time.localtime(now or time.time())
    a = {"until_clock": time.strftime("%H:%M", t)}
    if t[:3] != n[:3]:
        a["until_day"] = DAYS[t.tm_wday]
    return a


# (d20 batch50 B1, viewer Aurora: "Could quota rests appear in team status and tell replies, with a return time") The
# rest also goes to the runtime (rests.lua) as an operator `rest` request, so teammates see "resting until 07:34 (pace)"
# on their teammates line and in a tell's reply; the next turn ends it (done). The world and the agent are the ones the
# workspace's ./fh names (POG_WORLD, --bot); POG_REST_PUSH=off or no such fh: nothing is sent. Best effort: a failure
# is a context.log line and the loop goes on.
def agent_of(d):
    """(world, bot name) from DIR/fh, or None."""
    try:
        text = open(os.path.join(d, "fh")).read()
    except OSError:
        return None
    w, b = re.search(r"POG_WORLD=([\w-]+)", text), re.search(r"--bot ([\w-]+)", text)
    return (w.group(1), b.group(1)) if w and b else None


def ticks_per_s(d):
    """The game's speed as fh last measured it (DIR/.fh-pace.json, within 10 min), else None (the runtime takes 60)."""
    try:
        path = os.path.join(d, ".fh-pace.json")
        if time.time() - os.path.getmtime(path) > 600:
            return None
        v = float(json.load(open(path)).get("speed") or 0)
        return round(v, 2) if 1 <= v <= 600 else None
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def send_operator(world, req):
    """One operator dispatch over RCON (the operator's password, as tools/pog.py)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pog
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
    body = json.dumps(req)
    level = 0
    while f"]{'=' * level}]" in body:
        level += 1
    cmd = ('/silent-command rcon.print(remote.call("agent_harness","dispatch",[' + "=" * level + "[" + body + "]"
           + "=" * level + "]))")
    reply = json.loads(pog.Rcon("127.0.0.1", pog.PORTS[world], pw, timeout=5).command(cmd) or "{}")
    if not reply.get("ok"):
        raise RuntimeError(str(reply.get("error") or reply)[:200])
    return reply.get("result")


def push(d, args):
    """None when sent; else why not ("off", "no ./fh", or the failure, which is also a context.log line)."""
    if os.environ.get("POG_REST_PUSH", "").lower() == "off":
        return "off (POG_REST_PUSH)"
    who = agent_of(d)
    if not who:
        return f"no ./fh naming a world and bot in {d}"
    req = {"id": f"rest-{who[1]}-{time.time_ns()}", "operator": True, "action": "rest",
           "args": dict({k: v for k, v in args.items() if v is not None}, agent=who[1])}
    try:
        send_operator(who[0], req)
    except Exception as e:
        err = f"{type(e).__name__}: {e}"[:200]
        with open(os.path.join(d, "context.log"), "a") as f:
            f.write(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "rest-push-failed",
                                "done": bool(args.get("done")), "error": err}) + "\n")
        return err
    return None


def end_rest(d):
    """The rest is over: resting.json becomes resting-last.json and the runtime hears done. The row ended, or None."""
    path = os.path.join(d, REST)
    try:
        row = json.load(open(path))
    except (OSError, ValueError):
        return None
    os.replace(path, os.path.join(d, "resting-last.json"))
    push(d, {"done": True})
    return row


def woke(d, now=None):
    """The sentence the turn after a rest starts with (the agent slept through the world going on), or "" with no rest
    on record. The rest ends here: resting.json becomes resting-last.json."""
    row = end_rest(d)
    if row is None:
        return ""
    now = now or time.time()
    mins = max(1, round((min(now, row.get("until") or now) - (row.get("since") or now)) / 60))
    if row.get("reason") == "quota":
        return (f"You waited {mins} min for your quota to reset; the game went on meanwhile: check what changed "
                f"(./fh call status, chat, board) before acting.")
    when = f" (it resets {row['resets']})" if row.get("resets") else ""
    return (f"You rested {mins} min to pace your weekly quota{when}; the game went on meanwhile: check what changed "
            f"(./fh call status, chat, board) before acting.")


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
    # The window reads in whole percent, so a turn can show up to 1 point ahead of the line from rounding alone
    # (20:12: 88 against 87.35 gave a 3 h sleep): only what is beyond that point counts as ahead.
    ahead = used - line - 1.0
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
    # A stop rests until the shift's end, so the card says so instead of idle (23:17: the loop ended 50 min early).
    rest(d, max(deadline - now, 60) if stop else wait, "pace", used=used, resets=event["resets"])
    return "stop" if stop else wait


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--woke":
        line = woke(sys.argv[2])
        if line:
            print(line)
        return
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
    if not stop:
        rest(d, wait, "quota", resets=event["resets"])
    print("stop" if stop else wait)


if __name__ == "__main__":
    main()
