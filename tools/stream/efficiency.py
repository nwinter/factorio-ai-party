"""Production credited to the agent who built the machine (Nick 15:50; viewers Enginerd, Foobator): the harness's
operator read `efficiency` (efficiency.lua) gives, per agent and for the team, the items the machines they built made
(lifetime and this shift; drills and labs as "about" estimates), their machines and how many were working when last
read, the items they moved by hand this shift, and the share moved by machines.

live.py reads it every READ_EVERY seconds and appends each read to runs/RUN/efficiency.jsonl:
  {"t": unix seconds, "tick": game tick, "team": {...}, "agents": [the read's rows], "walk": {...}}
The shift's numbers are the runtime's own (items_shift, hand_items_shift: since the shift's start), so the last row of
a shift is that shift. The stream card shows the team's numbers and one agent's line, no ranking.
"""
import json, os

READ_EVERY = 300.0  # seconds between reads (one operator read: a row per agent)
FILE = "efficiency.jsonl"
BEFORE = "built before the count"
NEWS_WINDOW = 1800.0  # seconds: a notable change against the read this long ago


def path_for(run_dir):
    return os.path.join(run_dir, FILE) if run_dir else None


def append(path, res, now):
    """One read as a row, appended to the run's file when there is one; the row (None when the read has none)."""
    if not isinstance((res or {}).get("agents"), list):
        return None
    row = {"t": round(now, 1), "tick": res.get("tick"), "team": res.get("team") or {}, "agents": res["agents"],
           "walk": res.get("walk") or {}, "shift": res.get("shift") or {}}
    if path:
        try:
            with open(path, "a") as f:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")
        except OSError:
            pass
    return row


def read_rows(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("agents"), list):
                    rows.append(r)
    except OSError:
        pass
    return rows


def view(row, team=None):
    """The card's data from a read: {team, agents (the team's, with machines or items), before, tick, t}."""
    agents, before = [], None
    for a in (row or {}).get("agents") or []:
        if a.get("name") == BEFORE or a.get("before"):
            before = a
        elif (team is None or a.get("name") in team) and (a.get("machines") or a.get("items") or a.get("hand_items_shift")):
            agents.append(a)
    agents.sort(key=lambda a: a.get("name") or "")
    return {"team": (row or {}).get("team") or {}, "agents": agents, "before": before, "tick": (row or {}).get("tick"),
            "t": (row or {}).get("t")}


def fmt(n):
    n = int(n or 0)
    return f"{n / 1000:.1f}k".replace(".0k", "k") if n >= 10000 else f"{n:,}"


def agent_line(a, label=None):
    """'Machines Sol built made 12k items this shift; 82% of Sol's items moved by machines'."""
    name = (label or (lambda n: n))(a["name"])
    line = f"Machines {name} built made {fmt(a.get('items_shift'))} items this shift"
    if a.get("machine_share_pct") is not None:
        line += f"; {a['machine_share_pct']}% of {name}'s items moved by machines"
    return line


def pick(agents, turn):
    """The agent for this card: the turn-th of those whose machines made something this shift (else of all)."""
    made = [a for a in agents if a.get("items_shift")] or agents
    return made[turn % len(made)] if made else None


def notable(then, now):
    """A change worth a fact for the hosts, between two views NEWS_WINDOW apart: machines working up or down by a
    fifth (10 or more), or the team's share moved by machines by 10 points. {fact: value, ...} or None."""
    if not (then and now):
        return None
    a, b = then.get("team") or {}, now.get("team") or {}
    out = {}
    r0, r1 = a.get("running") or 0, b.get("running") or 0
    if abs(r1 - r0) >= 10 and abs(r1 - r0) >= 0.2 * max(r0, 1):
        out.update(machines_working_now=r1, machines_working_30_min_ago=r0)
    s0, s1 = a.get("machine_share_pct"), b.get("machine_share_pct")
    if s0 is not None and s1 is not None and abs(s1 - s0) >= 10:
        out.update(share_moved_by_machines_now_pct=s1, share_moved_by_machines_30_min_ago_pct=s0)
    return out or None
