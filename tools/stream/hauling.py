"""Hand hauling (operator 05:00, viewer Joonazan: "a counter for how much manual hauling each bot has done"): the
harness's operator read `hauling` (hauling.lua) counts, per agent since the save began, the items moved by hand and
the calls that moved them (direct, queue step, standing order step), the carry distance and the most repeated hauls.

live.py reads it every READ_EVERY seconds and appends each read to runs/RUN/hauling.jsonl:
  {"t": unix seconds, "tick": game tick, "agents": [the read's rows]}
A shift's numbers are the last row less the first (shift_rows); tools/agent_stats.py does the same for the site.
"""
import json, os

READ_EVERY = 300.0  # seconds between reads (one small operator read: a few rows per agent)
FIELDS = ("items", "calls", "direct_items", "direct_calls", "queue_items", "queue_calls", "order_items", "order_calls",
          "carry_tiles")
FILE = "hauling.jsonl"


def path_for(run_dir):
    return os.path.join(run_dir, FILE) if run_dir else None


def append(path, res, now, feeds=None):
    """One read as a row, appended to the run's file when there is one; the row (None when the read has no rows).
    feeds: {agent: haul_feed row} for the most repeated haul's destination (D5), kept in the row."""
    agents = (res or {}).get("agents")
    if not isinstance(agents, list):
        return None
    row = {"t": round(now, 1), "tick": (res or {}).get("tick"), "agents": agents}
    if feeds:
        row["feeds"] = feeds
    if not path:
        return row
    try:
        with open(path, "a") as f:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
    except OSError:
        return row
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


def haul_key(h):
    f, t = h.get("from") or {}, h.get("to") or {}
    return (h.get("item"), h.get("surface"), f.get("x"), f.get("y"), t.get("x"), t.get("y"))


def shift_rows(first, last, team=None):
    """Per agent, the last read less the first: [{name, FIELDS..., top}] sorted by items, most first. An agent whose
    counters went down (a new save) counts from zero. top: the haul repeated most in between {item, from, to,
    surface, times, items}, or None. team: names to keep (None keeps all)."""
    base = {a.get("name"): a for a in (first or {}).get("agents") or []}
    out = []
    for a in (last or {}).get("agents") or []:
        name = a.get("name")
        if team is not None and name not in team:
            continue
        b = base.get(name) or {}
        if (a.get("items") or 0) < (b.get("items") or 0):
            b = {}
        row = {"name": name}
        for k in FIELDS:
            row[k] = max(0, (a.get(k) or 0) - (b.get(k) or 0))
        before = {haul_key(h): h for h in b.get("hauls") or []}
        hauls = []
        for h in a.get("hauls") or []:
            p = before.get(haul_key(h)) or {}
            times = (h.get("times") or 0) - (p.get("times") or 0)
            if times > 0:
                hauls.append({"item": h.get("item"), "surface": h.get("surface"), "from": h.get("from"), "to": h.get("to"),
                              "to_name": h.get("to_name"), "times": times, "items": (h.get("items") or 0) - (p.get("items") or 0)})
        hauls.sort(key=lambda h: -h["times"])  # stable: the read's order (most repeated since the save) breaks ties
        row["top"] = hauls[0] if hauls else None
        row["hauls"] = hauls[:3]  # (d17 batch35 D5) this shift's most repeated first
        if row["items"] or row["calls"]:
            out.append(row)
    out.sort(key=lambda r: (-r["items"], r["name"] or ""))
    return out


def feed_args(rows):
    """(d17 batch35 D5) the operator read haul_feed's rows: each agent's most repeated haul this shift, its destination."""
    return [{"agent": r["name"], "item": r["top"]["item"], "surface": r["top"]["surface"], "to": r["top"]["to"],
             "to_name": r["top"]["to_name"]} for r in rows if r.get("top") and r["top"].get("to") and r["top"].get("to_name")][:16]


def at(p):
    return f"({p['x']:g},{p['y']:g})" if isinstance(p, dict) and "x" in p else "?"


def haul_line(row, feed=None):
    """One line for the agent: its most repeated haul this shift, what feeds that destination the item without hands
    now (haul_feed's line), and the next two. Facts only; None without a repeated haul."""
    top = row.get("top")
    if not top or (top.get("times") or 0) < 2:
        return None
    text = (f"most repeated this shift: {top['item']} on {top.get('surface')} from {at(top.get('from')) if top.get('from') else 'your inventory'}"
            f" to {top.get('to_name') or 'a spot'} {at(top.get('to'))}, {top['times']} times ({top.get('items') or 0} items)")
    if feed and feed.get("line"):
        text += f"; there now: {feed['line']}"
    rest = [f"{h['item']} to {h.get('to_name') or 'a spot'} {at(h.get('to'))} {h['times']} times" for h in (row.get("hauls") or [])[1:3] if h.get("times", 0) > 1]
    if rest:
        text += "; next: " + ", ".join(rest)
    return text


def card_line(rows, limit=5, label=None):
    """'Hand hauling this shift: 1. gemini 2,310 items, 2. ...' (the overlay card's text, and what the hosts read)."""
    label = label or (lambda n: n)
    parts = [f"{i}. {label(r['name'])} {r['items']:,} items" for i, r in enumerate(rows[:limit], 1)]
    return "Hand hauling this shift: " + ", ".join(parts) if parts else None
