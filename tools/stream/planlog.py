"""The team plan as the stream last read it, kept in runs/RUN/plan.json for the site's shift page (viewer Alex 22:12:
"the current shared plan the agents are using"; site/longrun.py reads the file a finished shift left).

One JSON object, replaced (atomically) when the plan, the open projects or the counts change: the board read's plan
(goals, goals_tick, lines [{agent, text, by, tick}], edited, updated_tick), the open projects (title, owner, status,
progress, next step, goal), open_unowned (open tasks and requests nobody owns), in_progress (tasks and requests
someone is on), and the game tick and time it was read at (`tick`, `t`). Only what the board read already returned:
no game read of its own."""
import json, os, re, time

NAME = "plan.json"
ACTIVE = ("open", "claimed", "doing", "blocked")


def _next(steps):
    if not isinstance(steps, list) or not steps:
        return None
    return re.sub(r"^\[[ x]\]\s*", "", str(steps[0])) or None


def record(plan, items, open_unowned, tick, now=None):
    """The file's object from a `board` read's plan and the items the stream holds (rows of every kind)."""
    plan = plan if isinstance(plan, dict) else {}
    lines = [{"agent": l.get("agent"), "text": l.get("text"), "by": l.get("by"), "tick": l.get("tick")}
             for l in plan.get("lines") or [] if isinstance(l, dict)]
    if not lines:  # an older runtime gives the lines as "agent: text" only
        for line in plan.get("doing") or []:
            name, _, text = str(line).partition(": ")
            lines.append({"agent": name, "text": re.sub(r" \(set by [^)]*\)$", "", text), "by": None, "tick": None})
    projects = []
    for it in sorted((it for it in items if it.get("kind") == "project" and it.get("status") in ACTIVE),
                     key=lambda it: -(it.get("updated_tick") or 0)):
        projects.append({"id": it.get("id"), "title": it.get("title"), "owner": it.get("owner"), "status": it.get("status"),
                         "progress": it.get("progress"), "next": _next(it.get("next_steps")), "goal": it.get("goal")})
    in_progress = sum(1 for it in items if it.get("kind") in ("task", "request") and it.get("status") in ("claimed", "doing"))
    return {"goals": plan.get("goals"), "goals_tick": plan.get("goals_tick"), "lines": lines, "edited": plan.get("edited"),
            "updated_tick": plan.get("updated_tick"), "projects": projects, "open_unowned": open_unowned,
            "in_progress": in_progress, "tick": tick, "t": round(now if now is not None else time.time(), 1)}


def save(run_dir, rec):
    """Writes rec to run_dir/plan.json when it differs from the file in more than its read time; True when written."""
    if not run_dir or not rec:
        return False
    path = os.path.join(run_dir, NAME)
    same = lambda r: {k: v for k, v in r.items() if k not in ("t", "tick")}  # noqa: E731
    try:
        with open(path) as f:
            if same(json.load(f)) == same(rec):
                return False
    except (OSError, ValueError):
        pass
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, path)
    return True


def load(run_dir):
    """The plan a run left (its file), or None."""
    try:
        with open(os.path.join(run_dir, NAME)) as f:
            rec = json.load(f)
        return rec if isinstance(rec, dict) else None
    except (OSError, ValueError):
        return None
