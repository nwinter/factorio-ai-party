#!/usr/bin/env python3
"""How much of the on-air time showed a character standing still, from a run's records (operator task 2026-10-12):
  python3 tools/stream/still_report.py --run ~/code/player-of-games/runs/shift01 \
      --logs ~/code/player-of-games/tools/stream/logs/director-20261012-*.jsonl

- Real: who was on air each second (the director logs: program cuts and each client's follow target) and when each
  character last moved or visibly acted (the agents' journals: every `status` the agent asked for has its position
  and the action running). A still stretch: the subject on air has not moved 0.5 tiles nor run a visible action for
  `--still` (20) s.
- Replayed: the same journals as the stream service's inputs (model.py fed a status row per agent every 3 s), the
  director (onecam.py) stepped every second, once with the stand-still and look-ahead rules off (before) and once on
  (after); the same measure on its on-air subject, and how many cuts each rule picked. The journals have the status
  `active` record of the old runtime (no bounds); a construct's bounds come from its request's `area`.
"""
import argparse, glob, json, os, statistics, sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from director import FIGHT, BUILD, WALK  # noqa: E402

VISIBLE = FIGHT | BUILD | WALK | {"mine", "gather", "craft", "construct", "kite", "repair", "pickup", "drive", "shoot"}


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def journals(run):
    """-> {agent: [(t, status result, construct bounds or None)]} sorted by t."""
    out = {}
    for path in sorted(glob.glob(os.path.join(run, "*", "journal.jsonl"))):
        name = os.path.basename(os.path.dirname(path))
        want, rows, area = {}, [], None
        for line in open(path):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") == "request":
                r = e["request"]
                want[r["id"]] = r.get("action")
                if r.get("action") == "construct" and isinstance((r.get("args") or {}).get("area"), dict):
                    a = r["args"]["area"]
                    try:
                        area = {"left": a["left_top"]["x"], "top": a["left_top"]["y"], "right": a["right_bottom"]["x"],
                                "bottom": a["right_bottom"]["y"]}
                    except (KeyError, TypeError):
                        area = None
            elif e.get("event") == "response":
                r = e["response"]
                if want.pop(r.get("id"), None) == "status" and r.get("ok") and isinstance(r.get("result"), dict):
                    rows.append((ts(e["at"]), r["result"], area))
        if rows:
            out[name] = rows
    return out


def kind_of(st):
    act = st.get("active")
    return act.get("kind") if isinstance(act, dict) else (act or "")


def motion(rows, still_moved=0.5):
    """-> [(t, moved_t)]: per status sample, when the character last moved or visibly acted."""
    out, last_pos, moved = [], None, None
    for t, st, _ in rows:
        p = st.get("position")
        if moved is None:
            moved = t
        if p and last_pos and ((p["x"] - last_pos["x"]) ** 2 + (p["y"] - last_pos["y"]) ** 2) ** 0.5 >= still_moved:
            moved = t
        if p and (not last_pos or moved == t):
            last_pos = p
        if st.get("combat") or kind_of(st).split(":")[0] in VISIBLE:
            moved = t
        out.append((t, moved))
    return out


def at(series, t):
    """The latest (t, ...) entry at or before t (series sorted), else None."""
    lo, hi = 0, len(series)
    while lo < hi:
        mid = (lo + hi) // 2
        if series[mid][0] <= t:
            lo = mid + 1
        else:
            hi = mid
    return series[lo - 1] if lo else None


def onair_real(logs, t0, t1):
    """-> [(t, subject or None)] each second from the director logs (program cuts and client targets)."""
    entries = []
    for p in logs:
        for line in open(p):
            try:
                entries.append(json.loads(line))
            except ValueError:
                pass
    entries.sort(key=lambda e: e["t"])
    onair, target, out, i = "main", {}, [], 0
    for t in range(int(t0), int(t1)):
        while i < len(entries) and entries[i]["t"] <= t:
            e = entries[i]
            i += 1
            r = e.get("reason") or ""
            if e.get("slot") == "program" and r.startswith("cut to "):
                onair = r[7:].split(":")[0]
            elif e.get("slot") != "program" and e.get("target"):
                target[e["slot"]] = e["target"].get("agents") or []
        ag = target.get(onair) or []
        out.append((t, ag[0] if len(ag) == 1 else None))
    return out


def measure(timeline, moves, still=20.0):
    """Share of the seconds with a character on air in which it had been still `still` s, and the stretches."""
    on = stillsec = 0
    stretches, run = [], None
    for t, subj in timeline:
        m = at(moves.get(subj) or [], t) if subj else None
        s = (t - m[1]) if m else 0
        if subj:
            on += 1
        if subj and s >= still:
            stillsec += 1
            if run and run[0] == subj and t - run[2] <= 1:
                run[2] = t
            else:
                if run:
                    stretches.append(run[2] - run[1] + still)
                run = [subj, t, t]
        elif run:
            stretches.append(run[2] - run[1] + still)
            run = None
    if run:
        stretches.append(run[2] - run[1] + still)
    st = sorted(stretches)
    return {"onair_s": on, "still_s": stillsec, "share": round(stillsec / on, 3) if on else None,
            "stretches": len(st), "median_s": round(statistics.median(st)) if st else 0,
            "p90_s": round(st[int(0.9 * (len(st) - 1))]) if st else 0, "max_s": round(st[-1]) if st else 0}


def replay(run_cfg, js, t0, t1, rules, poll=3.0):
    """The director on the journals' inputs: -> (timeline, cut reasons)."""
    from model import Model
    from onecam import OneCam
    off = {} if rules else {"still_cut": 1e9, "plan_after": 1e9, "plan_boost": 1.0, "move_boost": 1.0, "dull": 1.0,
                            "still_factor": 1.0, "plan_hold": 0.0}
    d = OneCam([{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4}, {"slot": "cam3", "player": 5}],
               lambda body: {"ok": True}, None, view_frac=0.658, **off)
    d.started = t0
    d.last_trio = t0
    m = Model(run_cfg)
    timeline, cams, next_poll = [], {}, t0
    for t in range(int(t0), int(t1)):
        if t >= next_poll:
            next_poll = t + poll
            rows = []
            for name, series in js.items():
                e = at(series, t)
                if not e:
                    continue
                _, st, area = e
                act = st.get("active")
                k = kind_of(st)
                plan = dict(act) if isinstance(act, dict) else None
                if plan and k == "construct" and area:
                    plan["bounds"] = area
                rows.append({"name": name, "position": st.get("position"), "alive": st.get("alive", True),
                             "active": k or False, "combat": bool(st.get("combat")), "surface": st.get("surface"),
                             "plan": plan})
            m.ingest({"agents": rows, "tick": 0}, t)
        snap = m.snapshot(t, cams)
        cams = d.step(snap, t)
        main = cams.get("main") or {}
        ag = main.get("agents") or []
        timeline.append((t, ag[0] if len(ag) == 1 and not main.get("attack") else None))
    return timeline, [c[2] for c in d.cuts]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--logs", nargs="+", required=True)
    ap.add_argument("--still", type=float, default=20.0)
    ap.add_argument("--minutes", type=float, help="replay only this many minutes (from the start)")
    a = ap.parse_args()
    js = journals(a.run)
    moves = {n: motion(r) for n, r in js.items()}
    run_cfg = json.load(open(os.path.join(a.run, "stream.json")))
    logs = [p for p in a.logs if os.path.getsize(p)]
    t_logs = [json.loads(l)["t"] for p in logs for l in open(p) if l.strip()]
    t0 = max(min(r[0][0] for r in js.values()), min(t_logs))
    t1 = min(max(r[-1][0] for r in js.values()), max(t_logs))
    if a.minutes:
        t1 = min(t1, t0 + a.minutes * 60)
    out = {"from": datetime.fromtimestamp(t0).strftime("%H:%M:%S"), "to": datetime.fromtimestamp(t1).strftime("%H:%M:%S"),
           "real": measure(onair_real(logs, t0, t1), moves, a.still)}
    for label, rules in (("replay_before", False), ("replay_after", True)):
        tl, reasons = replay(run_cfg, js, t0, t1, rules)
        r = measure(tl, moves, a.still)
        r["cuts"] = len(reasons)
        r["still_cuts"] = sum(" still " in x for x in reasons)
        r["lookahead_cuts"] = sum(" ahead" in x for x in reasons) if rules else 0  # picked with a big action ahead
        out[label] = r
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
