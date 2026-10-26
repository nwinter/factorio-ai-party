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
(d26 batch224) With --fights: the attacks the team blocks of the journals' replies report ("attack #16888 at
(-865,-584): ... first 32s ago, last 29s ago"), as snapshot fights from their first to their last report. With
--shells flares: artillery_live's shells modelled from the journals' flares (use_item artillery-targeting-remote
replies: the pieces in range with shells and their distances): each flare taken by the in-range piece free soonest, a
second after it was placed, then every COOLDOWN_S; the shell read the second it leaves, landing distance / SHELL_TPS
later. Several --log files are read as one; --from/--to (HH:MM local, the first log's day) cut the span.
Not replayed: alerts, platforms, the base map, segments, cues, attention and work (the trio runs as the rules say). So
the replay compares rule sets on the same input; it is not the program that aired.
"""
import argparse, bisect, importlib, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import airtime  # noqa: E402

WALK_TPS = 13.7  # tiles a second (46 tiles in 201 ticks, Grok's ag-watch-walk, shift77 queue history)
ACT_S = 8.0
BODY = airtime.FRESH | airtime.WALKS | {"craft", "insert", "take", "transfer", "feed", "fuel", "configure", "rotate",
                                        "pickup", "gather", "research"}
SLOTS = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2}, {"slot": "cam3", "player": 3}]
COOLDOWN_S = 200 / 60.0  # artillery-wagon-cannon cooldown (2.0.77 base item.lua)
SHELL_TPS = 60.0         # a shell flies 1 tile a tick (artycam.lua)
ATTACK_RE = re.compile(r"attack #(\d+) at \((-?[\d.]+),\s*(-?[\d.]+)\)[^;\"]*?first (\d+)s ago, last (\d+)s ago")
PIECE_RE = re.compile(r"^([\w-]+) \((-?[\d.]+),(-?[\d.]+)\) ([\d.]+) tiles")


def fights_of(js):
    """[fight]: the attacks the journals' team blocks report, each {key, kind, text, first, last, position}."""
    out = {}
    for j in js.values():
        for t, action, args, res, ok in j.requests:
            team = (res or {}).get("team")
            alerts = team.get("alerts") if isinstance(team, dict) else None
            if not alerts:
                continue
            for m in ATTACK_RE.finditer(json.dumps(alerts)):
                key = "attack:" + m.group(1)
                first, last = t - int(m.group(4)), t - int(m.group(5))
                f = out.setdefault(key, {"key": key, "kind": "attack", "text": f"attack #{m.group(1)}", "first": first,
                                         "last": last, "losses": [], "agent": None,
                                         "position": {"x": float(m.group(2)), "y": float(m.group(3)), "surface": "nauvis"}})
                f["first"], f["last"] = min(f["first"], first), max(f["last"], last)
    return sorted(out.values(), key=lambda f: f["first"])


def flare_shells(js):
    """[(fire_t, shell)]: artillery_live's shells modelled from the journals' flares (module doc)."""
    flares = []
    for name, j in js.items():
        for t, action, args, res, ok in j.requests:
            if ok and action == "use_item" and args.get("item") == "artillery-targeting-remote" and res and \
                    isinstance(args.get("position"), dict):
                pieces = [m for m in (PIECE_RE.match(str(x)) for x in res.get("in_range") or []) if m]
                if pieces:
                    flares.append((t, name, args["position"], pieces))
    flares.sort(key=lambda f: f[0])
    ready, out = {}, []
    for t, name, pos, pieces in flares:
        best = None
        for m in pieces:
            k = (m.group(2), m.group(3))
            at = max(t + 1.0, ready.get(k, -1e18))
            if not best or at < best[0]:
                best = (at, m, k)
        at, m, k = best
        ready[k] = at + COOLDOWN_S
        d = float(m.group(4))
        px, py = float(m.group(2)), float(m.group(3))
        out.append((at, {"key": f"{k[0]},{k[1]}|{round(pos['x'])},{round(pos['y'])}|{int(at * 2)}", "surface": "nauvis",
                         "from": {"x": px, "y": py},
                         "piece": {"name": m.group(1), "position": {"x": px, "y": py}, "surface": "nauvis", "by": name},
                         "target": {"position": {"x": float(pos["x"]), "y": float(pos["y"])}}, "flare": {"by": name},
                         "distance": round(d), "land_t": at + d / SHELL_TPS, "by": name}))
    out.sort(key=lambda x: x[0])
    return out


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

    def __init__(self, js, log_rows, fights=None, shells=None):
        import model
        self.fights = fights or []
        self.shells = shells or []
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
        snap = {"agents": [a for a in out if a["position"]], "alerts": [], "tick": self.tick,
                "fights": [dict(f, last=min(f["last"], t)) for f in self.fights if f["first"] <= t <= f["last"] + 240]}
        i = bisect.bisect_right([x[0] for x in self.shells], t)
        new = [dict(sh, eta_ticks=round((sh["land_t"] - t) * 60)) for at, sh in self.shells[:i] if at > t - 1.0]
        if new:
            snap["artillery"] = {"shells": new, "read_at": t, "every": 0.5}
        return snap


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


def log_rows_of(paths):
    paths = [paths] if isinstance(paths, str) else list(paths)
    rows = [r for p in paths for r in airtime.rows_of(p) if isinstance(r.get("t"), (int, float))]
    return sorted(rows, key=lambda r: r["t"])


def clock_t(day_t, hhmm):
    """An HH:MM[:SS] local time on day_t's day -> epoch seconds."""
    lt = time.localtime(day_t)
    parts = [int(x) for x in hhmm.split(":")] + [0]
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, parts[0], parts[1], parts[2], 0, 0, -1))


def replay(log_path, runs, out_path, cams=3, rules="here", chart=None, step=1.0, t0=None, t1=None, fights=False,
           shells=None):
    log_rows = log_rows_of(log_path)
    t0 = log_rows[0]["t"] if t0 is None else t0
    t1 = log_rows[-1]["t"] if t1 is None else t1
    js = airtime.journals(runs)
    js = {n: j for n, j in js.items() if any(t0 - 3600 <= q[0] <= t1 for q in j.requests)}
    with tempfile.TemporaryDirectory() as tmp:
        onecam = load_rules(rules, tmp)
        world = World(js, log_rows, fights_of(js) if fights else None, flare_shells(js) if shells == "flares" else None)

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
    ap.add_argument("--log", nargs="+", required=True)
    ap.add_argument("--runs", nargs="+", required=True)
    ap.add_argument("--chart", help="runs/RUN/chart/out: base tours (rules that have them)")
    ap.add_argument("--cams", type=int, default=3, choices=(1, 2, 3))
    ap.add_argument("--rules", default="here", choices=("here", "main"))
    ap.add_argument("--out", help="the replay's director log (default: a temporary file)")
    ap.add_argument("--fights", action="store_true", help="the journals' attack alerts as fights")
    ap.add_argument("--shells", choices=("none", "flares"), default="none", help="artillery shells modelled from flares")
    ap.add_argument("--from", dest="t_from", help="HH:MM local (the first log's day)")
    ap.add_argument("--to", dest="t_to", help="HH:MM local")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(tempfile.gettempdir(), f"director-replay-{os.getpid()}.jsonl")
    first = log_rows_of(a.log)[0]["t"]
    t0 = clock_t(first, a.t_from) if a.t_from else None
    t1 = clock_t(first, a.t_to) if a.t_to else None
    _, js, (t0, t1) = replay(a.log, a.runs, out, a.cams, a.rules, a.chart, t0=t0, t1=t1, fights=a.fights,
                             shells=a.shells)
    rows = list(airtime.rows_of(out))
    m = airtime.measure(rows, js, t0, t1)
    m.update(log=" ".join(os.path.basename(x) for x in a.log), rules=a.rules, cams=a.cams, replay_log=out,
             fights=a.fights, shells=a.shells,
             on_air_min={k: round(v / 60, 1) for k, v in sorted(airtime.on_air_by(rows, t0, t1).items(), key=lambda kv: -kv[1])})
    if a.json:
        print(json.dumps(m))
    else:
        print(f"{m['log']} replayed ({a.rules}, {a.cams} cameras): idle or walk loop on air {100 * m['idle_loop_share']:.1f}% "
              f"(idle {100 * m['idle_share']:.1f}%, loop {100 * m['loop_share']:.1f}%); fresh events {m['fresh_events']}, "
              f"median {m['fresh_delay_median_s']} s to air, {m['fresh_missed']} missed; cuts {m['cuts_per_min']}/min; "
              f"on air (min) {m['on_air_min']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
