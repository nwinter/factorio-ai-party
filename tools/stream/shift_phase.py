"""Public handover facts from existing local records; never reads the game."""
import json
from pathlib import Path
import re


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def confirmed_stop(record):
    return bool(record.get("stop_utc") and record.get("via") in ("game.server_save", "server-save"))


def agents_started(run):
    try:
        with (Path(run) / "start.log").open("rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 65536))
            log = f.read().decode(errors="replace")
    except OSError:
        log = ""
    return bool(re.search(r"\bstarted: [1-9]\d*/\d+ agents\b", log))


def facts(run, shift=None):
    run = Path(run)
    shift = shift if shift is not None else read_json(run / "stream.json").get("shift")
    if not isinstance(shift, dict):
        return None
    out = {k: shift[k] for k in ("start", "end", "next", "next_exact") if k in shift}
    if re.fullmatch(r"shift\d+", run.name):
        out["number"] = int(run.name[5:])
    out["started"] = agents_started(run)
    stop = read_json(run / "stopped.json")
    # A failed save is not a confirmed final stop. A successful stop record is
    # written only after the helpers stopped and the world was paused/saved.
    out["stopped"] = confirmed_stop(stop)
    out["save_state"] = "confirmed" if out["stopped"] else "failed" if stop.get("via") == "failed" else "unconfirmed"
    return out
