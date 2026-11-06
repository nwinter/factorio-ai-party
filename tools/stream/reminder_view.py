"""Reminder capacity and recorded board context, from existing reads only."""
import re
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def limits():
    """Read the harness's declarations; never substitute a second copy of its limits."""
    source = Path(__file__).resolve().parents[2] / "vendor/factorio-harness/mod/agent-harness_0.1.0/reminders.lua"
    try:
        text = source.read_text()
    except OSError:
        return None
    values = {}
    for names, numbers in re.findall(r"^\s*local ([A-Z_]+(?:\s*,\s*[A-Z_]+)*)\s*=\s*([\d, ]+)$", text, re.M):
        values.update(zip(re.split(r"\s*,\s*", names), map(int, numbers.split(","))))
    if not all(values.get(k, 0) > 0 for k in ("MAX_JOBS", "MAX_OWN")):
        return None
    return {k: values[k] for k in ("MAX_JOBS", "MAX_OWN")}


def capacity(jobs, agents):
    # reminder_add counts every stored job, even disabled/done history; ownership, not recipients.
    owners = {name: {"held": 0, "active": 0} for name in agents}
    held = active = 0
    for job in jobs:
        if not isinstance(job, dict):
            continue
        held += 1
        active += bool(job.get("enabled"))
        own = owners.setdefault(job.get("owner") or "unknown", {"held": 0, "active": 0})
        own["held"] += 1
        own["active"] += bool(job.get("enabled"))
    return {"held": held, "active": active, "owners": owners, "limits": limits()}


def board_context(job, board):
    """Only an explicitly linked, currently listed board item establishes context.

    A request's owner is not a recorded coverer. No inference from titles, notes or tells.
    """
    item_id = job.get("board_item")
    item = board["items"].get(item_id) or {}
    ids = board.get("claim_ids" if item.get("kind") == "claim" else "active_ids")
    if item_id not in (ids or set()):
        return None
    if item.get("status") not in ("open", "claimed", "doing", "blocked"):
        return None
    if item.get("kind") == "claim":
        return {"id": item_id, "kind": "claim", "covers": [c["name"] for c in item.get("covers") or []
                                                          if isinstance(c, dict) and c.get("name")]}
    if item.get("kind") == "request":
        return {"id": item_id, "kind": "request", "owner": item.get("owner"), "status": item.get("status")}
    return None
