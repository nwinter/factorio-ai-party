"""An agent's rest between turns (operator 17:17: Gemini plays short turns with long sleeps to pace its weekly quota).

tools/agy-quota.py writes runs/RUN/AGENT/resting.json before the agy loop sleeps: {since, until, reason (pace|quota),
sleep_s, used?, resets?}; the next turn moves it to resting-last.json. The stream service (live.py: the card says
"resting until 18:17 · pacing quota", the director skips it, the hosts hear it once), the supervisor
(tools/supervise.sh: no nudge typed into the sleeping loop) and tools/idle_nudge.py (no tell) read it here.

(d22 batch108 BR1, Grok's weekly limit at 20:04, reset Sat 15:59) Any agent can rest: tools/quota_rest.py writes the
same file for a Grok, Codex or Claude agent, and start-team does it for an agent whose account is at its limit. Those
have no loop to end the rest at their next turn (agy-quota.py --woke), so a rest is also over once the agent's journal
holds a request of its own after the rest began, as the runtime's rests.lua ends it (describe, profiles, cameras and
peeks do not count). The label names the day when the rest ends on another day than today: "out of quota until Sat
15:59". (batch115: the labels are short enough for an agent card's line at 1080p.)

  python3 tools/stream/pacing.py until AGENT_DIR    (supervise.sh: "UNTIL CLOCK" of the rest now, or nothing)
"""
import datetime
import json
import os
import sys
import time

REST = "resting.json"


def resting(agent_dir, now=None):
    """The rest an agent is in now ({since, until, reason, ...}), or None (none on record, or it has ended)."""
    if not agent_dir:
        return None
    try:
        with open(os.path.join(agent_dir, REST)) as f:
            row = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(row, dict) or not isinstance(row.get("until"), (int, float)):
        return None
    if row["until"] <= (now or time.time()):
        return None
    if isinstance(row.get("since"), (int, float)) and requested_since(agent_dir, row["since"]):
        return None
    return row


# Requests that do not end a rest: as runtime.lua's clock (call_tick) skips them (tools/launch-agent.sh calls describe
# before the agent starts).
NOT_OWN = ("describe", "profiles", "cameras")
TAIL_MAX = 4 << 20   # a journal's last 4 MB at most (a reply line can be long)


def requested_since(agent_dir, since):
    """True when the agent's journal (AGENT_DIR/journal.jsonl) has a request of its own written after `since` (epoch).
    Nothing written after it (the file's mtime, a second's slack: `since` is rounded): False without reading."""
    path = os.path.join(agent_dir, "journal.jsonl")
    try:
        if os.path.getmtime(path) < since - 1:
            return False
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - TAIL_MAX))
            lines = f.read().splitlines()
    except OSError:
        return False
    for raw in reversed(lines):
        if b'"event":"request"' not in raw:
            continue
        try:
            e = json.loads(raw)
            at = datetime.datetime.fromisoformat(e["at"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if at <= since:
            return False
        req = e.get("request") or {}
        if req.get("action") in NOT_OWN or (req.get("args") or {}).get("peek") is True:
            continue
        return True
    return False


def requests_since(agent_dir, since):
    """(d26 batch252 CA) The agent's requests of its own written after `since` (epoch), oldest first: [(at, action)],
    as requested_since counts them (describe, profiles, cameras and peeks left out; the journal's last 4 MB)."""
    path = os.path.join(agent_dir, "journal.jsonl")
    try:
        if os.path.getmtime(path) < since - 1:
            return []
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - TAIL_MAX))
            lines = f.read().splitlines()
    except OSError:
        return []
    out = []
    for raw in reversed(lines):
        if b'"event":"request"' not in raw and b'"event": "request"' not in raw:
            continue
        try:
            e = json.loads(raw)
            at = datetime.datetime.fromisoformat(e["at"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if at <= since:
            break
        req = e.get("request") or {}
        if req.get("action") in NOT_OWN or (req.get("args") or {}).get("peek") is True:
            continue
        out.append((at, req.get("action")))
    return out[::-1]


DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def clock(until, now=None):
    """'15:59' for a time later today, 'Sat 15:59' on another day (local time, the shift clock)."""
    t, n = time.localtime(until), time.localtime(now or time.time())
    hm = time.strftime("%H:%M", t)
    return hm if t[:3] == n[:3] else f"{DAYS[t.tm_wday]} {hm}"


def label(row, now=None):
    """'resting until 18:17 · pacing quota' (or 'out of quota until Sat 15:59')."""
    until = clock(row["until"], now)
    if row.get("reason") == "quota":
        return f"out of quota until {until}"
    return f"resting until {until} · pacing quota"


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "until":
        r = resting(sys.argv[2])
        if r:
            print(int(r["until"]), clock(r["until"]))
    else:
        sys.exit("usage: pacing.py until AGENT_DIR")
