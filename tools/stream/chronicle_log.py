"""The run's chronicle (viewer Alex 22:24: the agents' own narrative history; viewer syndesis 22:24: each platform's
creation and loss on the timeline): the harness's operator read `chronicle` (chronicle.lua), appended by the stream
service to runs/RUN/chronicle.jsonl, one JSON object a line:
- {"type": "entry", "t", "seq", "tick", "game_time", "agent", "title", "text", "surface", "planet", "platform",
  "position", "refs": [{id, kind, tick, line}]}: an agent's entry and the harness events it is filed beside;
- {"type": "event", "t", "id", "kind", "tick", "game_time", "line", ...}: an event the harness saw (research, rocket,
  death, platform_created, platform_arrived, platform_left, platform_lost with where, by, hit_by, cargo, cargo_items,
  cargo_kinds, platform_deleted).
The site's Chronicle page and timeline read the files along the run chain (site/chronicle.py). A restarted service
resumes after the last seq and id in the file; a new shift (runs/RUN/resumed-from) after the last of the shifts before
it, so nothing is written twice: the game keeps the last 300 of each in the save."""
import json
import os
import time

NAME = "chronicle.jsonl"


def path_for(run_dir):
    return os.path.join(run_dir, NAME) if run_dir else None


def last_cursors(path):
    """(highest entry seq, highest event id) in the file ((0, 0) when there is none)."""
    seq = eid = 0
    try:
        with open(path) as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                if row.get("type") == "entry":
                    seq = max(seq, int(row.get("seq") or 0))
                elif row.get("type") == "event":
                    eid = max(eid, int(row.get("id") or 0))
    except OSError:
        pass
    return seq, eid


def start_cursors(path):
    """Where the service starts reading: the file's cursors; for a file with no rows (a new shift), those of the shift
    it resumed from, and so on back."""
    seen = set()
    while path and path not in seen:
        seen.add(path)
        cur = last_cursors(path)
        if cur != (0, 0):
            return cur
        run_dir = os.path.dirname(path)
        try:
            with open(os.path.join(run_dir, "resumed-from")) as f:
                parent = f.read().strip()
        except OSError:
            return 0, 0
        if not parent or os.sep in parent or parent in (".", ".."):
            return 0, 0
        path = os.path.join(os.path.dirname(run_dir), parent, NAME)
    return 0, 0


def append(path, reply, since, events_since, now=None):
    """Append the read's entries after `since` and events after `events_since`; returns (entries, events) written."""
    t = round(now if now is not None else time.time(), 1)
    entries, events = [], []
    for e in (reply or {}).get("entries") or []:
        if isinstance(e, dict) and int(e.get("seq") or 0) > since:
            entries.append(dict(e, type="entry", t=t))
    for ev in (reply or {}).get("events") or []:
        if isinstance(ev, dict) and int(ev.get("id") or 0) > events_since:
            events.append(dict(ev, type="event", t=t))
    if path and (entries or events):
        with open(path, "a") as f:
            for row in entries + events:
                f.write(json.dumps(row) + "\n")
    return entries, events


def load(run_dir):
    """Every row of a run's file, in order: (entries, events)."""
    entries, events = [], []
    try:
        with open(os.path.join(run_dir, NAME)) as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("type") == "entry":
                    entries.append(row)
                elif isinstance(row, dict) and row.get("type") == "event":
                    events.append(row)
    except OSError:
        pass
    return entries, events
