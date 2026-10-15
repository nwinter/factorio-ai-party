"""An agent's rest between turns (operator 17:17: Gemini plays short turns with long sleeps to pace its weekly quota).

tools/agy-quota.py writes runs/RUN/AGENT/resting.json before the agy loop sleeps: {since, until, reason (pace|quota),
sleep_s, used?, resets?}; the next turn moves it to resting-last.json. The stream service (live.py: the card says
"resting until 18:17 · pacing its weekly quota", the director skips it, the hosts hear it once), the supervisor
(tools/supervise.sh: no nudge typed into the sleeping loop) and tools/idle_nudge.py (no tell) read it here.
"""
import json
import os
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
    return row if row["until"] > (now or time.time()) else None


def label(row):
    """'resting until 18:17 · pacing its weekly quota' (or 'waiting until 18:17 for its quota to reset')."""
    until = time.strftime("%H:%M", time.localtime(row["until"]))
    if row.get("reason") == "quota":
        return f"waiting until {until} for its quota to reset"
    return f"resting until {until} · pacing its weekly quota"
