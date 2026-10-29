#!/usr/bin/env python3
"""(d28 batch317) Replay agents' journals through the habit counters of progressive disclosure (disclosure.lua M.count):
when each habit threshold of tools/disclosure/rules.py would have been met by the team, and, per action whose rule is
habits only, the team's first call of it against the time it would have opened (and how many calls the gate would have
refused before then).

    python3 tools/disclosure/replay.py RUNS_DIR SHIFT [SHIFT ...]     # e.g. runs shift01 shift02 shift03

Research, buildings, events and scale are not in the journals: actions that wait on them are listed with their first
call only. walked is not replayed (a journal has no position before the walk).
"""
import gzip, json, os, re, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules  # noqa: E402

ACTS = {"craft", "build", "mine", "transfer", "collect", "feed", "refuel", "move_to", "walk", "pickup", "rotate",
        "deconstruct", "configure", "place_ghosts"}


def journal(path):
    f = gzip.open(path, "rt") if path.endswith(".gz") else open(path)
    for line in f:
        try:
            yield json.loads(line)
        except ValueError:
            pass


def calls(runs, shifts):
    """[(at, agent, action, args, ok, error text)] of every agent request of the shifts, in time order."""
    out = []
    for shift in shifts:
        d = os.path.join(runs, shift)
        for agent in sorted(os.listdir(d)):
            path = next((os.path.join(d, agent, n) for n in ("journal.jsonl", "journal.jsonl.gz")
                         if os.path.exists(os.path.join(d, agent, n))), None)
            if not path:
                continue
            pend = {}
            for e in journal(path):
                if e.get("event") == "request":
                    r = e.get("request") or {}
                    pend[r.get("id")] = (e.get("at"), r)
                elif e.get("event") == "response":
                    r = e.get("response") or {}
                    q = pend.pop(r.get("id"), None)
                    if q and isinstance(q[1].get("action"), str):
                        err = (r.get("error") or {}).get("message", "") if not r.get("ok", True) else ""
                        out.append((q[0] or "", agent, q[1]["action"], q[1].get("args") or {}, r.get("ok", True), err))
    out.sort(key=lambda c: c[0])
    return out


def replay(cs):
    counts, keys, repeats, met = defaultdict(int), defaultdict(lambda: defaultdict(int)), {}, {}
    thresholds = defaultdict(set)
    for conds in list(rules.ACTIONS.values()) + list(rules.ARGS.values()) + [a for t in rules.ARGS_OF.values() for a in t.values()]:
        for a in conds:
            m = re.match(r"^(habit:[a-z_]+):(\d+)$", a)
            if m:
                thresholds[m.group(1)].add(int(m.group(2)))

    def setc(key, value, at, tkey=None):
        if value <= counts[key]:
            return
        old, counts[key] = counts[key], value
        for n in thresholds.get(tkey or key, ()):
            if old < n <= value and f"{key}:{n}" not in met:
                met[f"{key}:{n}"] = at

    for at, agent, action, args, ok, err in cs:
        if not ok:
            setc(f"habit:refused:{action}", counts[f"habit:refused:{action}"] + 1, at, "habit:refused")
            if action in ("build", "place_ghosts", "mine"):
                setc("habit:refused_builds", counts["habit:refused_builds"] + 1, at)
            continue
        if action == "craft" and isinstance(args.get("recipe"), str):
            keys["hand_crafts"][args["recipe"]] += int(args.get("count") or 1) if str(args.get("count") or 1).isdigit() else 1
            setc("habit:hand_crafts", keys["hand_crafts"][args["recipe"]], at)
        elif action == "build":
            entries = args.get("builds") if isinstance(args.get("builds"), list) else [{"item": args.get("item")}]
            for e in entries:
                item = (e.get("item") or e.get("entity") or e.get("name") or args.get("item")) if isinstance(e, dict) else None
                if isinstance(item, str) and item.endswith("transport-belt"):
                    setc("habit:hand_belts", counts["habit:hand_belts"] + 1, at)
                if isinstance(item, str) and (item.endswith("electric-pole") or item == "substation"):
                    setc("habit:hand_poles", counts["habit:hand_poles"] + 1, at)
        elif action in ("feed", "refuel"):
            setc("habit:hand_feeds", counts["habit:hand_feeds"] + 1, at)
        elif action == "transfer" and isinstance(args.get("position"), dict):
            p = args["position"]
            try:
                k = f"{int(float(p.get('x')))},{int(float(p.get('y')))}"
            except (TypeError, ValueError):
                k = None
            if k:
                keys["chest_moves"][k] += 1
                setc("habit:chest_moves", keys["chest_moves"][k], at)
        elif action in ("sleep", "wait_ticks", "wait_until"):
            setc("habit:sleeps", counts["habit:sleeps"] + 1, at)
        elif action == "board_post":
            setc("habit:board_items", counts["habit:board_items"] + 1, at)
        if action in ACTS:
            shape = action + "|" + ",".join(sorted(k for k in args if k not in ("peek", "helper")))
            r = repeats.get(shape)
            # 10 game minutes: real time here (the runs are real time)
            if r and minutes(r[1], at) <= 10:
                r[0] += 1
                r[1] = at
            else:
                r = repeats[shape] = [1, at]
            setc("habit:repeat_calls", r[0], at)
    return met


def minutes(a, b):
    from datetime import datetime
    f = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
    return (f(b) - f(a)).total_seconds() / 60


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    runs, shifts = argv[0], argv[1:]
    cs = calls(runs, shifts)
    if not cs:
        print("no calls")
        return 1
    t0 = cs[0][0]
    met = replay(cs)
    print(f"{len(cs)} calls by the team in {', '.join(shifts)}; times in minutes from the first ({t0})")
    print("habit thresholds met:")
    for key in sorted(met, key=lambda k: met[k]):
        if not key.startswith("habit:refused:") or key.endswith(":1"):
            print(f"  {key}: {minutes(t0, met[key]):.0f} min")
    first = {}
    count_before = defaultdict(int)
    for at, agent, action, args, ok, err in cs:
        first.setdefault(action, at)
    print("actions opened by habits only: first call, opens at, calls before it opens")
    for name, conds in sorted(rules.ACTIONS.items()):
        hab = [a for a in conds if a.startswith("habit:")]
        if not hab or any(not (a.startswith("habit:") or a.startswith("scale:game_hours")) for a in conds):
            continue
        opens = min((met[a] for a in hab if a in met), default=None)
        hours = [int(a.rsplit(":", 1)[1]) for a in conds if a.startswith("scale:game_hours")]
        for at, agent, action, args, ok, err in cs:
            if action == name and (opens is None or at < opens):
                count_before[name] += 1
        fc = f"{minutes(t0, first[name]):.0f} min" if name in first else "never called"
        op = f"{minutes(t0, opens):.0f} min" if opens else "not by habits"
        hr = f" (or game hour {min(hours)})" if hours else ""
        print(f"  {name}: first call {fc}; opens {op}{hr}; calls before: {count_before[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
