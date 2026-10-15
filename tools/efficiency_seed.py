#!/usr/bin/env python3
"""Who built the machines already standing (efficiency.lua credits production to the agent who built the machine;
LuaEntity.last_user is nil for the agents' builds, and the harness's build log starts with its deploy). From the
agents' journals of every shift in a world's chain, oldest first: a hand build's reply names the machine
(unit_number, name, position), a batch build's reply its spots (in the order built), a ghost placement's request its
machines and spots (robots built them: the planner's). A later row wins.

  python3 tools/efficiency_seed.py --run shift12                 # summary: rows per agent and kind
  python3 tools/efficiency_seed.py --run shift12 --out seed.jsonl
  python3 tools/efficiency_seed.py --run shift12 --send --world n  # the operator seed (efficiency_seed), 1000 a call

Not covered: paste and blueprint_place (their replies count ghosts and bounds, not spots), and builds before the
journals kept replies. Machines: the types efficiency.lua credits (assemblers, furnaces, rocket silos, drills, labs),
from tools/analyst/kb/space-age-2.0.77/entities.json.
"""
import argparse, collections, gzip, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUNS = [os.path.join(ROOT, "runs"), os.path.expanduser("~/code/player-of-games/runs")]
TYPES = {"assembling-machine", "furnace", "rocket-silo", "mining-drill", "lab"}
CHUNK = 1000


def machine_names(kb=os.path.join(HERE, "analyst", "kb", "space-age-2.0.77", "entities.json")):
    try:
        return {e["name"] for e in json.load(open(kb)) if e.get("type") in TYPES}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def run_dir(name, roots=RUNS):
    for root in roots:
        d = os.path.join(root, name)
        if os.path.isdir(d):
            return d
    return None


def chain(name, roots=RUNS):
    """The run and the runs it resumed from (runs/RUN/resumed-from), oldest first."""
    out, seen = [], set()
    while name and name not in seen:
        seen.add(name)
        d = run_dir(name, roots)
        if not d:
            break
        out.append(d)
        try:
            name = open(os.path.join(d, "resumed-from")).read().strip()
        except OSError:
            name = None
    return out[::-1]


def journals(d):
    for agent in sorted(os.listdir(d)):
        for fn in ("journal.jsonl.gz", "journal.jsonl"):
            p = os.path.join(d, agent, fn)
            if os.path.exists(p):
                yield agent, p
                break


def rows_from_journal(agent, path, names=None):
    """Seed rows from one journal: {by, tick, unit?, name, x, y, surface?, how}."""
    opener = gzip.open if path.endswith(".gz") else open
    reqs, out = {}, []
    keep = (lambda n: n in names) if names is not None else (lambda n: True)
    with opener(path, "rt", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("event") == "request":
                q = r.get("request") or {}
                if q.get("action") in ("build", "place_ghosts"):
                    reqs[q.get("id")] = q
                continue
            body = r.get("response") or {}
            q = reqs.pop(body.get("id"), None)
            if not q or not body.get("ok"):
                continue
            res, a, tick = body.get("result") or {}, q.get("args") or {}, body.get("tick")
            by = q.get("bot") or agent
            if not isinstance(tick, int) or res.get("dry_run"):
                continue
            surface = a.get("surface") if isinstance(a.get("surface"), str) else None
            if q["action"] == "build":
                e = res.get("entity")
                if isinstance(e, dict) and e.get("name") and keep(e["name"]):
                    pos = e.get("position") or {}
                    out.append({"by": by, "tick": tick, "unit": e.get("unit_number"), "name": e["name"],
                                "x": pos.get("x"), "y": pos.get("y"), "surface": surface, "how": "build"})
                builds = a.get("builds")
                placed = res.get("placed")
                if isinstance(builds, list) and isinstance(placed, list) and not res.get("failed"):
                    for b, spot in zip(builds, placed):
                        name = (b or {}).get("item") or a.get("item")
                        if name and keep(name) and isinstance(spot, dict):
                            out.append({"by": by, "tick": tick, "name": name, "x": spot.get("x"), "y": spot.get("y"),
                                        "surface": surface, "how": "build batch"})
            else:
                for e in a.get("entities") or []:
                    pos = (e or {}).get("position") or {}
                    name = (e or {}).get("name")
                    if name and keep(name) and "x" in pos and "y" in pos:
                        # a platform's own surface name is not in the request: no surface (any)
                        out.append({"by": by, "tick": tick, "name": name, "x": pos["x"], "y": pos["y"],
                                    "surface": None if a.get("platform") else surface, "how": "ghost"})
    return out


def collect(run, roots=RUNS, names=None):
    rows = []
    for d in chain(run, roots):
        for agent, p in journals(d):
            rows.extend(rows_from_journal(agent, p, names))
    rows.sort(key=lambda r: r["tick"])
    return rows


def summary(rows):
    by = collections.Counter((r["by"], r["how"]) for r in rows)
    agents = sorted({r["by"] for r in rows})
    lines = [f"{len(rows)} rows, {sum(1 for r in rows if r.get('unit'))} with a unit number"]
    for a in agents:
        lines.append(f"  {a}: " + ", ".join(f"{how} {by[(a, how)]}" for how in ("build", "build batch", "ghost") if by[(a, how)]))
    return "\n".join(lines)


def lua_string(text):
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[{text}]{eq}]"


def seed_commands(rows, chunk=CHUNK):
    """The operator dispatch commands that send the rows (efficiency_seed), chunk rows a call."""
    out = []
    for i in range(0, len(rows), chunk):
        part = [{k: v for k, v in r.items() if v is not None and k != "how"} for r in rows[i:i + chunk]]
        req = {"id": f"seed-{i // chunk}", "action": "efficiency_seed", "args": {"rows": part}, "operator": True}
        out.append('/silent-command rcon.print(remote.call("agent_harness", "dispatch", '
                   + lua_string(json.dumps(req, separators=(",", ":"))) + "))")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--out")
    ap.add_argument("--send", action="store_true")
    ap.add_argument("--world", default="live")
    a = ap.parse_args()
    rows = collect(a.run, names=machine_names())
    print(summary(rows))
    if a.out:
        with open(a.out, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    if a.send:
        sys.path.insert(0, HERE)
        import pog
        pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
        r = pog.Rcon("127.0.0.1", pog.PORTS[a.world], pw)
        for cmd in seed_commands(rows):
            print(r.command(cmd)[:300])


if __name__ == "__main__":
    main()
