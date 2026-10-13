#!/usr/bin/env python3
"""How agents use queues, repeats, guards and plans, how long their characters sit idle, and what hand work repeats,
from the shifts' journals (docs/STANDING-ORDERS.md):

    python3 tools/idle_report.py [SHIFT ...]        # default shift04 shift05 shift06; POG_RUNS=DIR for another runs/

Idle: every reply's clock line says how long the character has had no action ("character idle Ns"); those spans are
merged, so tools polling in between do not count twice."""
import datetime, gzip, json, os, re, collections, sys
from pathlib import Path

R = Path(os.environ.get("POG_RUNS") or Path(__file__).resolve().parent.parent / "runs")
if not any(R.glob("shift*/journal*")) and not any(R.glob("shift*/*/journal*")):
    R = Path.home() / "code" / "player-of-games" / "runs"  # a worktree without the shift folders
SHIFTS = sys.argv[1:] or ['shift04', 'shift05', 'shift06']
CLOCK = re.compile(r"\+([\dhms]+) since your last request, character idle ([\dhms]+) of it")
DUR = re.compile(r"(\d+)([hms])")
READS = {"observe", "inspect", "sleep", "chat", "inventory", "inv", "tells", "board", "recipes", "placements",
         "wait_until", "wait_ticks", "describe", "technologies", "requests", "queue", "profiles", "research_done",
         "plans", "screenshot", "view", "clock", "callstatus", "status", "queue_status", "players", "scan", "research",
         "craftable", "nearest", "map", "platforms", "where", "plan_list"}
TALK = {"say", "tell", "confess", "board_plan", "board_update", "board_post", "board_claim", "operator",
        "harness_request", "plan_save", "profile", "vote"}
HAND = {"insert", "take", "transfer", "feed", "craft", "collect", "drop", "refuel", "put"}


def secs(s):
    return sum(int(n) * {"h": 3600, "m": 60, "s": 1}[u] for n, u in DUR.findall(s))


def item_class(name):
    n = str(name or "")
    if "magazine" in n or "ammo" in n or "rounds" in n or "shell" in n or "rocket" == n:
        return "ammo"
    if n in ("coal", "wood", "solid-fuel", "rocket-fuel", "nuclear-fuel", "uranium-fuel-cell"):
        return "fuel"
    if "science-pack" in n:
        return "science"
    if n.endswith("-plate") or n.endswith("-ore") or n in ("stone", "steel-plate", "copper-cable", "iron-gear-wheel",
                                                           "electronic-circuit", "advanced-circuit", "stone-brick"):
        return "materials"
    return "other" if n else "none"


def items_of(args):
    out = []
    for k in ("item", "name", "items"):
        v = args.get(k)
        if isinstance(v, str):
            out.append(v)
        elif isinstance(v, dict):
            out += list(v)
        elif isinstance(v, list):
            out += [x.get("name") if isinstance(x, dict) else x for x in v]
    return out or [None]


rows = []
for sh in SHIFTS:
    d = R / sh
    team = [l.split("|")[0].strip() for l in (d / "team.txt").read_text().splitlines() if l.strip()] if (d / "team.txt").exists() else []
    for ag in team:
        j = d / ag / "journal.jsonl.gz"
        if not j.exists():
            j = d / ag / "journal.jsonl"
        if not j.exists():
            continue
        st = collections.Counter()
        hand = collections.Counter()      # (where, action, class)
        steps_by = collections.Counter()  # step actions inside queues
        gap_total = idle_total = 0
        long_idle = []                    # idle stretches of 2 minutes or more
        spans = []                        # (from, to): the character idle, from each reply's clock line
        sleep_s = 0
        first = last = None
        op = gzip.open if j.suffix == ".gz" else open
        reqs = {}
        for line in op(j, "rt", errors="replace"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("event") == "request":
                q = r.get("request") or {}
                a, args = q.get("action"), q.get("args") or {}
                reqs[q.get("id")] = (a, args)
                first = first or r.get("at")
                last = r.get("at")
                st["requests"] += 1
                if a in READS:
                    st["reads"] += 1
                elif a in TALK:
                    st["talk"] += 1
                else:
                    st["game"] += 1
                if a in ("queue_submit", "queue_repeat", "queue_append", "queue_insert", "plan_run", "plan_save",
                         "wait_until", "sleep", "queue_cancel", "queue_pause", "queue_resume", "queue_clear"):
                    st[a] += 1
                if a == "sleep":
                    sleep_s += float(args.get("seconds") or 0)
                if isinstance(args.get("guards"), list) and args["guards"]:
                    st["with_guards"] += 1
                if a in ("queue_submit", "queue_repeat", "queue_append"):
                    steps = args.get("steps") or []
                    st["queued_steps"] += len(steps)
                    for s in steps:
                        if isinstance(s, dict):
                            sa = s.get("action")
                            steps_by[sa] += 1
                            if sa in HAND:
                                for it in items_of(s.get("args") or {}):
                                    hand[("queued", sa, item_class(it))] += 1
                if a in HAND:
                    for it in items_of(args):
                        hand[("direct", a, item_class(it))] += 1
                continue
            resp = r.get("response") or {}
            res = resp.get("result")
            if isinstance(res, dict) and isinstance(res.get("clock"), str) and r.get("at"):
                m = CLOCK.search(res["clock"])
                if m:
                    t = datetime.datetime.fromisoformat(r["at"].replace("Z", "+00:00")).timestamp()
                    i = secs(m.group(2))
                    if i:
                        spans.append((t - i, t))
        spans.sort()
        merged = []
        for a0, b0 in spans:
            if merged and a0 <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], b0)
            else:
                merged.append([a0, b0])
        idle_total = sum(b0 - a0 for a0, b0 in merged)
        long_idle = [b0 - a0 for a0, b0 in merged if b0 - a0 >= 120]
        if first and last:
            gap_total = (datetime.datetime.fromisoformat(last.replace("Z", "+00:00")) -
                         datetime.datetime.fromisoformat(first.replace("Z", "+00:00"))).total_seconds()
        rows.append({"shift": sh, "agent": ag, "st": st, "hand": hand, "steps": steps_by, "gap": gap_total,
                     "idle": idle_total, "long": long_idle, "sleep_s": sleep_s})

print(f"{'shift':7} {'agent':7} {'req':>5} {'game':>5} {'qsub':>5} {'qrep':>5} {'steps':>6} {'guard':>5} {'plan':>5} {'wait':>5} "
      f"{'sleep':>5} {'idle%':>5} {'idle2m+':>12}")
for r in rows:
    st = r["st"]
    idle_pct = 100 * r["idle"] / r["gap"] if r["gap"] else 0
    print(f"{r['shift']:7} {r['agent']:7} {st['requests']:5} {st['game']:5} {st['queue_submit']:5} {st['queue_repeat']:5} "
          f"{st['queued_steps']:6} {st['with_guards']:5} {st['plan_run']:5} {st['wait_until']:5} {st['sleep']:5} "
          f"{idle_pct:5.0f} {len(r['long']):3}x {sum(r['long'])/60:5.0f}m")

print("\nhand work by item class (direct requests / queued steps), all agents, per shift:")
for sh in SHIFTS:
    tot = collections.Counter()
    for r in rows:
        if r["shift"] == sh:
            for (where, a, c), n in r["hand"].items():
                tot[(where, c)] += n
    print(sh, {f"{w}:{c}": n for (w, c), n in sorted(tot.items(), key=lambda kv: -kv[1])[:14]})

print("\nhand work per agent (all shifts), top classes:")
per = collections.defaultdict(collections.Counter)
for r in rows:
    for (where, a, c), n in r["hand"].items():
        per[r["agent"]][f"{where[0]}:{a}:{c}"] += n
for ag, c in sorted(per.items()):
    print(ag, c.most_common(8))

print("\nqueued step actions (all):", sum((r["steps"] for r in rows), collections.Counter()).most_common(15))
print("\nlongest idle stretches (min):")
for r in rows:
    if r["long"]:
        print(r["shift"], r["agent"], sorted((round(x / 60) for x in r["long"]), reverse=True)[:8])
