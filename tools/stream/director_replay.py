#!/usr/bin/env python3
"""A director log's span replayed through a director's rules (d26 batch222 CD): the agents' states rebuilt from their
journals and the log, stepped through onecam.OneCam once a second on the log's own clock, its log written to --out
and measured by airtime.py.

  python3 tools/stream/director_replay.py --log tools/stream/logs/director-20261025-194343.jsonl \\
      --runs runs/shift76 runs/shift77 --chart runs/shift78/chart/out --cams 3 [--rules main] [--out FILE]

--rules main runs main's onecam.py and director.py (git show main:...; the other modules from this checkout), else
this checkout's. What each agent is, at each second (from its journal unless said):
- position and surface: its latest status reply, else the log's camera result while a camera followed it; on a walk
  loop (queue_repeat of walks, airtime.Journal) it walks the loop's steps in turn at WALK_TPS (Grok's 46-tile leg took
  201 ticks) and rests the loop's interval_ticks after each round; a move_to or walk goes to its target at WALK_TPS;
- active: the loop's move_to; else a body request (BODY) for ACT_S after it, a sleep for its seconds; else none;
- activity: acting while active, thinking for model.THINK_WINDOW after a request, else idle;
- interest: model.Agent's bump and decay (model.ACTION_WEIGHT when its action changes, 0.04 of it a second while it
  acts, 2 for a say or chat);
- remote_vehicle: work.VehicleFeed over its journal rows.
Not replayed: alerts, fights, platforms, segments, cues, attention, work, trio picks need nothing more but run as the
rules say. So the replay compares rule sets on the same input; it is not the program that aired.
"""
import argparse, bisect, importlib, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import airtime  # noqa: E402

WALK_TPS = 13.7  # tiles a second (46 tiles in 201 ticks, Grok's ag-watch-walk, shift77 queue history)
ACT_S = 8.0
BODY = airtime.FRESH | airtime.WALKS | {"craft", "insert", "take", "transfer", "feed", "fuel", "configure", "rotate",
                                        "pickup", "gather", "research"}
SLOTS = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2}, {"slot": "cam3", "player": 3}]


class Track:
    """[(t, value)] in time order; at(t): the latest at or before t."""

    def __init__(self):
        self.ts, self.vs = [], []

    def add(self, t, v):
        i = bisect.bisect_right(self.ts, t)
        self.ts.insert(i, t)
        self.vs.insert(i, v)

    def at(self, t):
        i = bisect.bisect_right(self.ts, t)
        return self.vs[i - 1] if i else None


def loop_pos(lp, t, start):
    """Where a walk loop has the character at t: legs between its steps (round trip), then its rest."""
    pts = [s["args"].get("position") for s in lp[2]["steps"] if isinstance((s.get("args") or {}).get("position"), dict)]
    if not pts:
        return start
    here = start or pts[-1]
    legs, cur = [], here
    for p in pts:
        legs.append((cur, p, max(0.5, ((p["x"] - cur["x"]) ** 2 + (p["y"] - cur["y"]) ** 2) ** 0.5 / WALK_TPS)))
        cur = p
    rest = (lp[2].get("interval_ticks") or 0) / 60.0
    first = sum(d for _, _, d in legs) + rest
    # after the first round the loop starts from its last step
    round_legs = []
    cur = pts[-1]
    for p in pts:
        round_legs.append((cur, p, max(0.5, ((p["x"] - cur["x"]) ** 2 + (p["y"] - cur["y"]) ** 2) ** 0.5 / WALK_TPS)))
        cur = p
    cycle = sum(d for _, _, d in round_legs) + rest
    x = t - lp[0]
    seq = legs
    if x >= first:
        x, seq = (x - first) % cycle, round_legs
    for a, b, d in seq:
        if x < d:
            f = x / d
            return {"x": round(a["x"] + (b["x"] - a["x"]) * f, 2), "y": round(a["y"] + (b["y"] - a["y"]) * f, 2)}
        x -= d
    return dict(seq[-1][1])


class World:
    """The agents' states at each second (module doc)."""

    def __init__(self, js, log_rows):
        import model
        self.model = model
        self.js = js
        self.pos, self.surf, self.walks = {}, {}, {}
        for name, j in js.items():
            self.pos[name], self.surf[name], self.walks[name] = Track(), Track(), []
            for t, p, s in j.status:
                self.pos[name].add(t, {"x": p["x"], "y": p["y"]})
                if s:
                    self.surf[name].add(t, str(s))
            for t, action, args, res, ok in j.requests:
                if ok and action in airtime.WALKS and isinstance(args.get("position"), dict):
                    self.walks[name].append((t, {"x": float(args["position"]["x"]), "y": float(args["position"]["y"])}))
        for r in log_rows:
            cam = ((r.get("result") or {}).get("camera")) or {}
            who = cam.get("follow")
            if who in self.pos and isinstance(cam.get("position"), dict):
                self.pos[who].add(r["t"], {"x": cam["position"]["x"], "y": cam["position"]["y"]})
                if cam.get("surface"):
                    self.surf[who].add(r["t"], str(cam["surface"]))
        self.agents = {n: model.Agent(n, {}) for n in js}
        self.idx = {n: 0 for n in js}
        self.active, self.act_until, self.last_req = {}, {}, {}
        import work
        self.vehicles = work.VehicleFeed()
        self.rows = {n: j.vehicle_rows for n, j in js.items()}
        self.row_i = {n: 0 for n in js}
        self.tick = None

    def position(self, name, t):
        j = self.js[name]
        for lp in j.loops:
            if lp[0] <= t < lp[1]:
                return loop_pos(lp, t, self.pos[name].at(lp[0])), "move_to"
        p = self.pos[name].at(t)
        walks = [w for w in self.walks[name] if w[0] <= t]
        if walks:
            wt, goal = walks[-1]
            tr = self.pos[name]
            i = bisect.bisect_right(tr.ts, t)
            if not (i and tr.ts[i - 1] > wt):  # no read since the walk began: on its way to the target
                here = tr.at(wt) or goal
                d = ((goal["x"] - here["x"]) ** 2 + (goal["y"] - here["y"]) ** 2) ** 0.5
                f = min(1.0, (t - wt) * WALK_TPS / d) if d > 0 else 1.0
                return {"x": here["x"] + (goal["x"] - here["x"]) * f, "y": here["y"] + (goal["y"] - here["y"]) * f}, \
                    ("move_to" if f < 1.0 else None)
        return p, None

    def snapshot(self, t):
        out = []
        for name, j in self.js.items():
            ag = self.agents[name]
            reqs = j.requests
            i = self.idx[name]
            while i < len(reqs) and reqs[i][0] <= t:
                rt, action, args, res, ok = reqs[i]
                self.last_req[name] = rt
                if action in ("say", "chat"):
                    ag.bump(2.0, rt)
                if ok and action in BODY:
                    self.active[name], self.act_until[name] = action, rt + ACT_S
                elif ok and action == "sleep":
                    secs = args.get("seconds") if isinstance(args.get("seconds"), (int, float)) else 30
                    self.active[name], self.act_until[name] = "sleep", rt + min(600, secs)
                i += 1
            self.idx[name] = i
            k = self.row_i[name]
            rows = self.rows[name]
            while k < len(rows) and rows[k][0] <= t:
                self.vehicles.ingest(name, rows[k][1])
                k += 1
            self.row_i[name] = k
            pos, walking = self.position(name, t)
            active = walking or (self.active.get(name) if t < self.act_until.get(name, 0) else False)
            if active and active != ag.active:
                ag.bump(self.model.ACTION_WEIGHT.get(active, 1.0), t)
            if active:
                ag.bump(0.04 * self.model.ACTION_WEIGHT.get(active, 1.0), t)
            ag.active = active
            ag.decay(t)
            thinking = t - self.last_req.get(name, -1e9) < self.model.THINK_WINDOW
            out.append({"name": name, "display_name": name.capitalize(), "alive": True, "seen": True,
                        "position": pos, "surface": self.surf[name].at(t) or "nauvis",
                        "activity": "acting" if active else "thinking" if thinking else "idle",
                        "active": active, "interest": round(ag.interest, 2),
                        "plan": {"kind": active} if active else None, "combat": False, "travel": None,
                        "remote_vehicle": self.vehicles.current(name, t)})
        return {"agents": [a for a in out if a["position"]], "alerts": [], "tick": self.tick}


def load_rules(rules, tmp):
    if rules == "main":
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=HERE, capture_output=True, text=True).stdout.strip()
        for f in ("onecam.py", "director.py"):
            src = subprocess.run(["git", "show", f"main:tools/stream/{f}"], cwd=root, capture_output=True, text=True,
                                 check=True).stdout
            with open(os.path.join(tmp, f), "w") as out:
                out.write(src)
        sys.path.insert(0, tmp)
    return importlib.import_module("onecam")


def replay(log_path, runs, out_path, cams=3, rules="here", chart=None, step=1.0, t0=None, t1=None):
    log_rows = [r for r in airtime.rows_of(log_path) if isinstance(r.get("t"), (int, float))]
    t0 = log_rows[0]["t"] if t0 is None else t0
    t1 = log_rows[-1]["t"] if t1 is None else t1
    js = airtime.journals(runs)
    js = {n: j for n, j in js.items() if any(t0 - 3600 <= q[0] <= t1 for q in j.requests)}
    with tempfile.TemporaryDirectory() as tmp:
        onecam = load_rules(rules, tmp)
        world = World(js, log_rows)

        def send(body):
            return {"ok": True, "camera": {"move": {"start_tick": 0}} if body.get("move") else {}}
        if os.path.exists(out_path):
            os.remove(out_path)
        d = onecam.OneCam(SLOTS[:cams], send, out_path)
        d.started = d.onair_since = t0
        for run in reversed(runs):  # the planets the run reached (space-memory.json): not new; nothing written back
            if os.path.isdir(run):
                d.set_surface_memory(os.path.join(run, "surface-seen.json"))
                d.surface_memory = None
                break
        if chart and hasattr(d, "set_tours"):
            import basetour
            d.set_tours(basetour.Tours(chart))
        t = t0
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            while t < t1:
                d.step(world.snapshot(t), now=t)
                t += step
    return log_rows, js, (t0, t1)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--log", required=True)
    ap.add_argument("--runs", nargs="+", required=True)
    ap.add_argument("--chart", help="runs/RUN/chart/out: base tours (rules that have them)")
    ap.add_argument("--cams", type=int, default=3, choices=(1, 2, 3))
    ap.add_argument("--rules", default="here", choices=("here", "main"))
    ap.add_argument("--out", help="the replay's director log (default: a temporary file)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(tempfile.gettempdir(), f"director-replay-{os.getpid()}.jsonl")
    _, js, (t0, t1) = replay(a.log, a.runs, out, a.cams, a.rules, a.chart)
    m = airtime.measure(list(airtime.rows_of(out)), js, t0, t1)
    m.update(log=os.path.basename(a.log), rules=a.rules, cams=a.cams, replay_log=out)
    if a.json:
        print(json.dumps(m))
    else:
        print(f"{m['log']} replayed ({a.rules}, {a.cams} cameras): idle or walk loop on air {100 * m['idle_loop_share']:.1f}% "
              f"(idle {100 * m['idle_share']:.1f}%, loop {100 * m['loop_share']:.1f}%); fresh events {m['fresh_events']}, "
              f"median {m['fresh_delay_median_s']} s to air, {m['fresh_missed']} missed; cuts {m['cuts_per_min']}/min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
