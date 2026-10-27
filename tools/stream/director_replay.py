#!/usr/bin/env python3
"""A director log's span replayed through a director's rules (d26 batch222 CD): the agents' states rebuilt from their
journals and the log, stepped through onecam.OneCam once a second on the log's own clock, its log written to --out
and measured by airtime.py.

  python3 tools/stream/director_replay.py --log tools/stream/logs/director-20261025-194343.jsonl \\
      --runs runs/shift76 runs/shift77 --chart runs/shift78/chart/out --cams 3 [--rules main] [--out FILE]

--rules main runs main's onecam.py, director.py and work.py (git show main:...; the other modules from this checkout), else
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
(-865,-584): ... first 32s ago, last 29s ago"; batch245: also shift81's "...; spidertron x11 hit 11 times, 227 damage,
first 1m41s ago, ..." and a lone hit's "..., 0s ago"), as snapshot fights from their first hit to ATTACK_RECENT_S after
their last (live.py reports the chunk that long), a chunk wide. With
--shells flares: artillery_live's shells modelled from the journals' flares (use_item artillery-targeting-remote
replies: the pieces in range with shells and their distances): each flare taken by the in-range piece free soonest, a
second after it was placed, then every COOLDOWN_S; the shell read the second it leaves, landing distance / SHELL_TPS
later. Several --log files are read as one; --from/--to (HH:MM local, the first log's day) cut the span.
(d26 batch232) With --vehicles live: the service's position reads of the agents' remote vehicles (harness
VEHICLES_LUA, every POLL_S), modelled from every vehicle reply in the journals (any agent's): from each reply's
position the vehicle walks its route at CRUISE_TPS until the next reply. vehicle_framing then says, for the program's
vehicle shots, how long the vehicle stood inside the on-air client's frame (the client moved as cameras.lua moves it).
Not replayed: alerts, platforms, the base map, segments, cues, attention and work (the trio runs as the rules say). So
the replay compares rule sets on the same input; it is not the program that aired.
(d26 batch240) With --timed: the log's own timed shots (every cut to a shot that neither follows an agent nor shows its
vehicle: platform visits, work and departures, the base map, tours, cues, segments, looks, threats) replayed at their
times for as long as they aired, as segments; its quiet views only where the replayed story is quiet too, and none of
its quiet views or tours with --chart (the replay makes its own). The agents' inputs as the service has them: positions
read once a POLL_S; a walk loop (the harness's queue) and a sleep keep no interest up; a request done within itself
(INSTANT) is no running action; a running action lasts while the replies' clocks say the character was busy;
work.DidFeed's builds (`did`) and work.ClockFeed's idle seconds (`idle_s`).
(d26 batch245) An agent on a walk loop has its status read's queues.body repeating (onecam: a loop whatever its size).
"""
import argparse, bisect, importlib, json, math, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import airtime  # noqa: E402
import work as work_here  # noqa: E402  (batch240: this checkout's DidFeed rules, the replay's input whatever --rules)

WALK_TPS = 13.7  # tiles a second (46 tiles in 201 ticks, Grok's ag-watch-walk, shift77 queue history)
ACT_S = 8.0
BODY = airtime.FRESH | airtime.WALKS | {"craft", "insert", "take", "transfer", "feed", "fuel", "configure", "rotate",
                                        "pickup", "gather", "research"}
# (batch240) requests done within the request: the live read never shows them as the character's running action
# (status replies of shifts 80-81 name only move_to, gather, wait_until, construct, clear_cliffs, pickup and mine)
INSTANT = {"build", "place", "place_ghosts", "paste", "blueprint_place", "deconstruct", "load_silo", "launch", "vehicle",
           "insert", "take", "transfer", "feed", "fuel", "configure", "rotate", "research", "craft"}
SLOTS = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2}, {"slot": "cam3", "player": 3}]
COOLDOWN_S = 200 / 60.0  # artillery-wagon-cannon cooldown (2.0.77 base item.lua)
SHELL_TPS = 60.0         # a shell flies 1 tile a tick (artycam.lua)
# (batch245) shift81's alerts: "attack #16958 at (760,-857): 10 attackers seen (...); likely from nest ...; spidertron
# x11 hit 11 times, 227 damage, first 0s ago, last 0s ago", "first 1m41s ago", or a single hit "..., 0s ago"
ATTACK_RE = re.compile(r"attack #(\d+) at \((-?[\d.]+),\s*(-?[\d.]+)\)([^\"]*?)(?:first ((?:\d+m)?\d+s) ago, last "
                       r"((?:\d+m)?\d+s) ago|, (\d+s) ago)")
HIT_RE = re.compile(r"; ([\w-]+) x\d+ hit")
ATTACK_RECENT_S = 30.0   # live.py ATTACK_RECENT_TICKS: an attacked area is reported while its last hit is this recent
CRUISE_TPS = 47.5 / 3.6  # a spidertron walking: spidertron 27069154's reads in shifts 79-80, 46-50 km/h, median 47.5
POLL_S = 3.0             # the service's poll (serve.py --poll): the live vehicle read
PIECE_RE = re.compile(r"^([\w-]+) \((-?[\d.]+),(-?[\d.]+)\) ([\d.]+) tiles")


def vehicle_paths(js):
    """{unit: [(t, {x, y}, [targets])]}: every vehicle reply with a unit number and a position (any agent's), with its
    route then (go_to, else route), in time order."""
    ev = {}
    for j in js.values():
        pend = {}
        for t, r in j.vehicle_rows:
            if r.get("event") == "request":
                q = r.get("request") or {}
                pend[q.get("id")] = q.get("args") if isinstance(q.get("args"), dict) else {}
                continue
            resp = r.get("response") or {}
            args = pend.pop(resp.get("id"), None)
            res = resp.get("result") if isinstance(resp.get("result"), dict) else None
            p = (res or {}).get("position")
            unit = (res or {}).get("unit_number")
            unit = unit if isinstance(unit, int) else (args or {}).get("vehicle")
            if args is None or not resp.get("ok") or not isinstance(unit, int) or not isinstance(p, dict):
                continue
            go = res.get("go_to")
            route = [go] if isinstance(go, dict) else go if isinstance(go, list) else res.get("route")
            route = [q for q in (route if isinstance(route, list) else []) if isinstance(q, dict) and "x" in q]
            ev.setdefault(unit, []).append((t, {"x": float(p["x"]), "y": float(p["y"])}, route))
    return {u: sorted(v, key=lambda e: e[0]) for u, v in ev.items()}


def along(here, route, q):
    """How far along the route from here the point nearest q lies, and how near it is: (tiles, tiles)."""
    best, done = (0.0, 1e9), 0.0
    for p in route:
        dx, dy = p["x"] - here["x"], p["y"] - here["y"]
        d = (dx * dx + dy * dy) ** 0.5
        f = max(0.0, min(1.0, ((q["x"] - here["x"]) * dx + (q["y"] - here["y"]) * dy) / (d * d))) if d > 0 else 0.0
        off = ((here["x"] + dx * f - q["x"]) ** 2 + (here["y"] + dy * f - q["y"]) ** 2) ** 0.5
        if off < best[1]:
            best = (done + d * f, off)
        done += d
        here = p
    return best


def path_at(events, t):
    """({x, y}, tiles/s, next target or None) of a vehicle at t, from its latest reply walking its route at CRUISE_TPS,
    never past where the next reply found it on that route (within 16 tiles of it: Astra's spidertron, sent at 09:23:26,
    stood at (-329,-450) when Opus took it at 09:26:23, 192 tiles along); None before its first reply."""
    ts = [e[0] for e in events]
    i = bisect.bisect_right(ts, t)
    if not i:
        return None
    t0, here, route = events[i - 1]
    left = CRUISE_TPS * (t - t0)
    stood = False
    if i < len(events):
        s_next, off = along(here, route, events[i][1])
        if off <= 16.0 and s_next < left:
            left, stood = s_next, True
    for q in route:
        d = ((q["x"] - here["x"]) ** 2 + (q["y"] - here["y"]) ** 2) ** 0.5
        if left < d:
            f = left / d
            return {"x": here["x"] + (q["x"] - here["x"]) * f, "y": here["y"] + (q["y"] - here["y"]) * f}, \
                (0.0 if stood else CRUISE_TPS), q
        left -= d
        here = {"x": float(q["x"]), "y": float(q["y"])}
    return dict(here), 0.0, None


def vehicle_where(js, paths):
    """where(agent, t) -> {x, y} of the vehicle the agent called last by t (its modelled path), or None."""
    calls = {}
    for name, j in js.items():
        asked = {}
        for t, r in j.vehicle_rows:
            if r.get("event") == "request":
                q = r.get("request") or {}
                asked[q.get("id")] = (q.get("args") or {}).get("vehicle")
                continue
            resp = r.get("response") or {}
            res = resp.get("result")
            u = res.get("unit_number") if isinstance(res, dict) else None
            u = u if isinstance(u, int) else asked.pop(resp.get("id"), None)
            if isinstance(res, dict) and isinstance(u, int):
                calls.setdefault(name, []).append((t, u))

    def where(agent, t):
        c = [u for ct, u in calls.get(agent, []) if ct <= t]
        got = path_at(paths.get(c[-1]) or [], t) if c else None
        return got[0] if got else None
    return where


def vehicle_framing(log_rows, where, t0, t1, step=0.25, ease=0.08, jump=200.0):
    """(batch232) The program's vehicle shots (a client's shot labelled "by remote view", its agent the target's first)
    over [t0, t1]: {on_air_s, in_frame_s, by_agent {agent: [on_air_s, in_frame_s]}}. Each client is moved as cameras.lua
    moves it: a jump on a shot sent unsmoothed or farther than `jump` tiles, else toward its latest position at most
    `speed` tiles/s (cmd speed: a glide), or by `ease` a tick. In frame: within half the 1920x1080 view at its zoom."""
    rows = sorted((r for r in log_rows if isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    cams, onair, i = {}, None, 0
    out = {"on_air_s": 0.0, "in_frame_s": 0.0, "by_agent": {}}
    t = rows[0]["t"] if rows else t0
    while t < t1 and rows:
        while i < len(rows) and rows[i]["t"] <= t:
            r = rows[i]
            i += 1
            slot, reason = r.get("slot"), str(r.get("reason") or "")
            if slot == "program":
                m = re.match(r"(cut to|move) (\S+?):", reason)
                if m:
                    onair = m.group(2)
                continue
            cmd = r.get("cmd") or {}
            c = cams.setdefault(slot, {"cam": None, "goal": None, "speed": None, "zoom": 1.0, "vehicle": None})
            onair = onair or slot
            if cmd.get("zoom"):
                c["zoom"] = float(cmd["zoom"])
            if reason != "reframe":
                tgt = r.get("target") or {}
                agents = tgt.get("agents") or []
                # (the row's target names its vehicle since batch232; older logs say it in the reason)
                c["vehicle"] = agents[0] if agents and ("by remote view" in str(tgt.get("vehicle") or "") or
                                                        "by remote view" in reason) else None
            p = cmd.get("position")
            if isinstance(p, dict) and not cmd.get("follow"):
                goal = [float(p["x"]), float(p["y"])]
                if c["cam"] is None or not cmd.get("smooth") or math.dist(c["cam"], goal) > jump:
                    c["cam"] = list(goal)
                c["goal"], c["speed"] = goal, cmd.get("speed")
            elif cmd.get("follow"):
                c["cam"], c["goal"], c["vehicle"] = None, None, None
        for c in cams.values():  # the clients move
            if c["cam"] is None or c["goal"] is None:
                continue
            d = math.dist(c["cam"], c["goal"])
            if d <= 0.02:
                continue
            go = min(d, c["speed"] * step) if c["speed"] else d * (1 - (1 - ease) ** (60 * step))
            c["cam"][0] += (c["goal"][0] - c["cam"][0]) * go / d
            c["cam"][1] += (c["goal"][1] - c["cam"][1]) * go / d
        c = cams.get(onair)
        if t >= t0 and c and c["vehicle"] and c["cam"] is not None:
            v = where(c["vehicle"], t)
            row = out["by_agent"].setdefault(c["vehicle"], [0.0, 0.0])
            out["on_air_s"] += step
            row[0] += step
            hw, hh = 960 / (32 * c["zoom"]), 540 / (32 * c["zoom"])
            if v and abs(v["x"] - c["cam"][0]) <= hw and abs(v["y"] - c["cam"][1]) <= hh:
                out["in_frame_s"] += step
                row[1] += step
        t += step
    return out


def surface_air_of(log_rows, t0, t1):
    """[(t, surface, 1.0)] each second of [t0, t1] the program showed a surface (its on-air client's latest camera
    surface): what surface-air.json would have held for a replay that starts at t1 (batch232 --surface-from)."""
    rows = sorted((r for r in log_rows if isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    onair, surf, out, i, t = None, {}, [], 0, t0
    while t < t1:
        while i < len(rows) and rows[i]["t"] <= t:
            r = rows[i]
            i += 1
            m = re.match(r"(cut to|move) (\S+?):", str(r.get("reason") or "")) if r.get("slot") == "program" else None
            if m:
                onair = m.group(2)
            elif r.get("slot") != "program":
                cam = ((r.get("result") or {}).get("camera")) or {}
                s = cam.get("surface") or (r.get("cmd") or {}).get("surface")
                if s:
                    surf[r["slot"]] = str(s)
                onair = onair or r.get("slot")
        if surf.get(onair):
            out.append((t, surf[onair], 1.0))
        t += 1.0
    return out


CUT_RE = re.compile(r"(cut to|move) (\S+?): (.*)")
TIMED_MAX = 180.0  # s: a timed shot replayed at most this long (the log's next cut ends it sooner)


def timed_shots(log_rows, t0, t1, own_quiet=False):
    """(batch240) The log's timed shots in [t0, t1]: every program cut to a shot that neither follows an agent nor shows
    its vehicle (platform visits, work, departures and bows, the base map, tours, cues, segments, looks, threats), from
    the cut to the next one: [{t, until, label, position, surface, zoom, quiet}]. quiet: the director's own quiet view
    (a "quiet KIND: ..." row just before it). own_quiet (the replay has the run's chart: its own tours and quiet
    views): the log's quiet views and tours are left out."""
    rows = sorted((r for r in log_rows if isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    last, quiet_t, cuts = {}, -1e9, []
    for r in rows:
        slot, reason = r.get("slot"), str(r.get("reason") or "")
        if slot == "program":
            if reason.startswith("quiet "):
                quiet_t = r["t"]
            m = CUT_RE.match(reason)
            if m:
                cuts.append((r["t"], last.get(m.group(2)), m.group(3), r["t"] - quiet_t <= 3.0))
        elif reason != "reframe" and not reason.startswith("zoom"):
            last[slot] = r
    out = []
    for i, (t, row, label, quiet) in enumerate(cuts):
        end = cuts[i + 1][0] if i + 1 < len(cuts) else t1
        cmd, tgt = (row or {}).get("cmd") or {}, (row or {}).get("target") or {}
        if not (t0 <= t < t1) or cmd.get("follow") or tgt.get("vehicle") or not isinstance(cmd.get("position"), dict):
            continue
        if own_quiet and (quiet or label.startswith("tour:")):
            continue
        out.append({"t": t, "until": min(end, t + TIMED_MAX), "label": label, "position": cmd["position"],
                    "surface": cmd.get("surface") or "nauvis", "zoom": float(cmd.get("zoom") or 1.0), "quiet": quiet})
    return out


def quiet_story(d, snap, now):
    """(batch240) The replay's story is quiet as onecam.quiet_now says (its subject still or looping quiet_story on air,
    nobody else newsworthy or moving), the platform and map guards aside."""
    cur = d.state.get(d.onair) or {}
    subj, cfg = cur.get("subject"), d.cfg
    names = [a["name"] for a in snap["agents"]]
    if subj not in names or now - d.onair_since < cfg["quiet_story"] or d.stale_s(subj, now) < cfg["quiet_story"]:
        return False
    return not any(n != subj and (d.newsworthy(n, now) or d.stale_s(n, now) < cfg["moving_s"]) for n in names)


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
                first = t - airtime.seconds(m.group(5) or m.group(7))
                last = t - airtime.seconds(m.group(6) or m.group(7))
                hit = HIT_RE.search(m.group(4) or "")
                last += ATTACK_RECENT_S  # (batch245) live.py reports the area while its last hit is this recent
                f = out.setdefault(key, {"key": key, "kind": "attack", "first": first, "last": last, "losses": [],
                                         "agent": None, "text": f"attack #{m.group(1)}" + (f": {hit.group(1)}" if hit else ""),
                                         "position": {"x": float(m.group(2)), "y": float(m.group(3)), "surface": "nauvis",
                                                      "extent": 32.0}})
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

    def __init__(self, js, log_rows, fights=None, shells=None, live=False, vehicle_interest=False, launches=None):
        import model
        self.launches, self.last_silos, self.silo_snap = launches, -1e9, None  # (batch257) the silos read, a poll
        self.vehicle_interest = vehicle_interest  # (batch232 VC2: rules that bump interest for a vehicle's new target)
        self.paths = vehicle_paths(js) if live else None  # (batch232) the live vehicle reads, modelled
        self.last_live = -1e9
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
        # (batch240) a running action lasts while the replies' clocks say the character was busy (not idle): the live
        # read shows it all that time; ACT_S after the request when no clock covers it
        self.busy = {}
        for name, j in js.items():
            spans = []
            for rt, action, args, res, ok in j.requests:
                c = work_here.CLOCK_RE.search((res or {}).get("clock") or "") if isinstance((res or {}).get("clock"), str) else None
                if c:
                    span, idle = work_here.seconds(c.group(1)), work_here.seconds(c.group(2))
                    if span > 0 and idle < work_here.IDLE_FRAC * span:
                        spans.append((rt - span, rt))
            self.busy[name] = airtime.merge(spans)
        import work
        self.vehicles = work.VehicleFeed()
        self.rows = {n: j.vehicle_rows for n, j in js.items()}
        self.row_i = {n: 0 for n in js}
        self.tick = None
        self.polled = {}  # (batch240) name -> (t, position, walking): the latest poll's read
        self.work, self.did = work_here, {}  # (batch240) name -> its latest build-like request (work.DidFeed's row)
        self.work_did_keep = work_here.DID_KEEP
        self.clocks = work_here.ClockFeed()  # (batch240) the replies' clocks, as live.py's WorkFeed reads them

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
        if self.paths is not None and t - self.last_live >= POLL_S:  # (batch232) the service's vehicle read
            self.last_live = t
            reads = {}
            for u in self.vehicles.units(t):
                got = path_at(self.paths.get(u) or [], t)
                if got:
                    reads[u] = {"unit": u, "name": "spidertron", "x": got[0]["x"], "y": got[0]["y"], "speed": got[1] / 60.0,
                                "dest": got[2]}
            self.vehicles.apply_live(reads, t)
        for name, j in self.js.items():
            ag = self.agents[name]
            reqs = j.requests
            i = self.idx[name]
            while i < len(reqs) and reqs[i][0] <= t:
                rt, action, args, res, ok = reqs[i]
                self.last_req[name] = rt
                if action in ("say", "chat"):
                    ag.bump(2.0, rt)
                c = self.work.CLOCK_RE.search((res or {}).get("clock") or "") if isinstance((res or {}).get("clock"), str) else None
                if c:  # (batch240) what live.py's ClockFeed reads (the reply comes with the request here)
                    self.clocks.note(name, rt, self.work.seconds(c.group(1)), self.work.seconds(c.group(2)))
                if ok and self.work.did_kind(action, args, res):  # (batch240) what live.py's DidFeed reads
                    plat, where = self.work.target_of(args)
                    self.did[name] = {"action": action, "t": rt, "position": where,
                                      "platform": plat if isinstance(plat, str) else None}
                if ok and action in BODY and action not in INSTANT:
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
            vehicle = self.vehicles.current(name, t)
            did = self.did.get(name)
            did = did if did and t - did["t"] <= self.work_did_keep else None
            if self.vehicle_interest:
                was, ag.remote_vehicle = ag.remote_vehicle, vehicle
                self.model.vehicle_interest(ag, was, t)
                if hasattr(self.model, "did_interest"):  # (batch240)
                    was, ag.did = ag.did, did
                    self.model.did_interest(ag, was, t)
            got = self.polled.get(name)
            if not got or t - got[0] >= POLL_S:  # (batch240) positions as the service reads them, once a poll
                got = self.polled[name] = (t,) + tuple(self.position(name, t))
            pos, walking = got[1], got[2]
            running = self.active.get(name) if self.active.get(name) not in (None, "sleep") else None
            active = walking or (self.active.get(name) if t < self.act_until.get(name, 0) else False) or \
                (running if running and airtime.in_spans(self.busy[name], t) else False)
            # (batch240) a walk loop runs in the harness's queue, no request of the agent's, and a sleep is no action:
            # they keep no interest up (Grok's 4 h loop of shift80, with 58 sleeps, scored 1.7 on average live, 7.0
            # here with the bumps; batch232: Opus's interest decayed live while it slept between its vehicle calls)
            looped = (any(a <= t < b for a, b, _ in j.loops) and not t < self.act_until.get(name, 0)) or active == "sleep"
            if active and active != ag.active and not looped:
                ag.bump(self.model.ACTION_WEIGHT.get(active, 1.0), t)
            if active and not looped:
                ag.bump(0.04 * self.model.ACTION_WEIGHT.get(active, 1.0), t)
            ag.active = active
            ag.decay(t)
            thinking = t - self.last_req.get(name, -1e9) < self.model.THINK_WINDOW
            out.append({"name": name, "display_name": name.capitalize(), "alive": True, "seen": True,
                        "position": pos, "surface": self.surf[name].at(t) or "nauvis",
                        "activity": "acting" if active else "thinking" if thinking else "idle",
                        "active": active, "interest": round(ag.interest, 2),
                        "plan": {"kind": active} if active else None, "combat": False, "travel": None,
                        "remote_vehicle": vehicle, "did": did, "idle_s": self.clocks.current(name, t),
                        # (batch245) the status read's queue lanes: a walk loop's queue repeats
                        "queues": {"body": {"repeating": True, "paused": False, "active": {"action": "move_to"}}}
                        if any(a <= t < b for a, b, _ in j.loops) else None})
        if self.launches and t - self.last_silos >= POLL_S:  # (batch257) the service's silos read (launches.py)
            self.last_silos = t
            self.silo_snap = self.launches.read(t)
        snap = {"agents": [a for a in out if a["position"]], "alerts": [], "tick": self.tick, "silos": self.silo_snap,
                "fights": [dict(f, last=min(f["last"], t)) for f in self.fights if f["first"] <= t <= f["last"] + 240]}
        i = bisect.bisect_right([x[0] for x in self.shells], t)
        new = [dict(sh, eta_ticks=round((sh["land_t"] - t) * 60)) for at, sh in self.shells[:i] if at > t - 1.0]
        if new:
            snap["artillery"] = {"shells": new, "read_at": t, "every": 0.5}
        return snap


# (d26 batch257) A launch's silo states from its order, game seconds (launches.py, world n d26): 8 launch_starting,
# 14 launch_started, 9 engine_starting, 10 arms_retract, 11 rocket_flying, 5 the next rocket rising, 6 arms_advance, then
# 7 rocket_ready until the next order
LAUNCH_STEPS = [(8, 0.6), (14, 2.0), (9, 5.6), (10, 1.7), (11, 6.3), (5, 9.6), (6, 1.7)]
LAUNCH_CYCLE = sum(d for _, d in LAUNCH_STEPS)


def silo_positions(js):
    """{surface: [(x, y)]}: every silo the journals' replies list (the replay's launches.SiloFeed list)."""
    out = {}
    for j in js.values():
        for _, _, args, res, ok in j.requests:
            rows = (res or {}).get("silos") if isinstance(res, dict) else None
            for r in rows if isinstance(rows, list) else []:
                p = r.get("position") if isinstance(r, dict) else None
                if isinstance(p, dict) and isinstance(p.get("x"), (int, float)) and isinstance(p.get("y"), (int, float)):
                    surf = r.get("surface") or res.get("surface") or res.get("planet")
                    if isinstance(surf, str) and (p["x"], p["y"]) not in out.setdefault(surf, []):
                        out[surf].append((float(p["x"]), float(p["y"])))
    return out


def chronicle_rows(runs):
    out = []
    for run in runs:
        try:
            with open(os.path.join(run, "chronicle.jsonl")) as f:
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
    return out


class Launches:
    """(batch257) The silos' states as the service's SILOS_LUA would read them, from the chronicle's rockets: each
    rocket given to a silo of its planet that is free (its last launch's cycle over; else the one free soonest), its
    states from LAUNCH_STEPS. read(t) is launches.SiloFeed's read at t, with this as its harness."""

    def __init__(self, runs, js):
        import launches
        self.rockets, events = airtime.chronicle_rockets(chronicle_rows(runs))
        self.events = sorted(events, key=lambda r: r["t"])  # as the service reads them: by when they were appended
        self.positions = silo_positions(js)
        self.plan = {}  # (surface, x, y) -> [order wall times]
        free = {(s, x, y): -1e18 for s, ps in self.positions.items() for x, y in ps}
        used = {k: -1e18 for k in free}
        for wt, _, surf, _ in self.rockets:
            mine = [k for k in free if k[0] == surf]
            if not mine:
                continue
            ready = [k for k in mine if free[k] <= wt]
            k = min(ready, key=lambda k: used[k]) if ready else min(mine, key=lambda k: free[k])
            free[k], used[k] = max(free[k], wt) + LAUNCH_CYCLE, wt
            self.plan.setdefault(k, []).append(max(wt, free[k] - LAUNCH_CYCLE))
        self.feed = launches.SiloFeed(None)
        for (surf, x, y) in free:
            self.feed.add(surf, x, y, save=False)
        self.t = None
        self.k_ev = 0
        self.wall = [r[0] for r in self.rockets]

    def status(self, k, t):
        orders = self.plan.get(k) or []
        i = bisect.bisect_right(orders, t) - 1
        if i < 0:
            return 7
        dt = t - orders[i]
        for st, d in LAUNCH_STEPS:
            if dt < d:
                return st
            dt -= d
        return 7

    def tick_at(self, t):
        if not self.rockets:
            return None
        i = min(max(bisect.bisect_right(self.wall, t) - 1, 0), len(self.rockets) - 1)
        wt, tick = self.rockets[i][0], self.rockets[i][1]
        return int(tick + (t - wt) * 60)


    def read(self, t):
        self.t = t
        new = []
        while self.k_ev < len(self.events) and self.events[self.k_ev]["t"] <= t:
            new.append(self.events[self.k_ev])
            self.k_ev += 1
        self.feed.note_rockets(new)
        return self.feed.read(self, t)

    def silos(self, silos):  # the harness's silos() for the feed
        return {"tick": self.tick_at(self.t), "n": len(self.feed.silos),
                "s": [self.status((s, float(x), float(y)), self.t) for s, x, y in silos]}


def load_rules(rules, tmp):
    if rules == "main":
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=HERE, capture_output=True, text=True).stdout.strip()
        for f in ("onecam.py", "director.py", "work.py"):
            src = subprocess.run(["git", "show", f"main:tools/stream/{f}"], cwd=root, capture_output=True, text=True,
                                 check=True).stdout
            with open(os.path.join(tmp, f), "w") as out:
                out.write(src)
        sys.path.insert(0, tmp)
        sys.modules.pop("work", None)  # (batch240: airtime loaded this checkout's; World takes main's VehicleFeed)
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
           shells=None, vehicles="journal", surface_from=None, timed=False, launches=True, tuning=None):
    log_rows = log_rows_of(log_path)
    t0 = log_rows[0]["t"] if t0 is None else t0
    t1 = log_rows[-1]["t"] if t1 is None else t1
    shots = timed_shots(log_rows, t0, t1, own_quiet=bool(chart)) if timed else []
    js = airtime.journals(runs)
    js = {n: j for n, j in js.items() if any(t0 - 3600 <= q[0] <= t1 for q in j.requests)}
    with tempfile.TemporaryDirectory() as tmp:
        onecam = load_rules(rules, tmp)
        world = World(js, log_rows, fights_of(js) if fights else None, flare_shells(js) if shells == "flares" else None,
                      live=vehicles == "live", vehicle_interest=True, launches=Launches(runs, js) if launches else None)  # (batch245: main has model.py's bumps since
        # batch232 and 240; "here" only gave main's replays no vehicle or build interest, shift81: 26.4% vs 21.5% idle)

        def send(body):
            return {"ok": True, "camera": {"move": {"start_tick": 0}} if body.get("move") else {}}
        if os.path.exists(out_path):
            os.remove(out_path)
        d = onecam.OneCam(SLOTS[:cams], send, out_path, **(tuning or {}))
        d.started = d.onair_since = t0
        for run in reversed(runs):  # the planets the run reached (space-memory.json): not new; nothing written back
            if os.path.isdir(run):
                d.set_surface_memory(os.path.join(run, "surface-seen.json"))
                d.surface_memory = None
                d.surface_air = []  # (a run's surface-air.json is wall-clock; the replay seeds its own below)
                break
        if surface_from:
            d.surface_air = surface_air_of(log_rows_of(surface_from), t0 - d.cfg["surface_window"], t0)
        if chart and hasattr(d, "set_tours"):
            import basetour
            d.set_tours(basetour.Tours(chart))
        t = t0
        import contextlib, io
        k, seg = 0, None
        with contextlib.redirect_stdout(io.StringIO()):
            while t < t1:
                snap = world.snapshot(t)
                while k < len(shots) and shots[k]["t"] <= t:  # (batch240) the log's timed shot starts: a segment
                    sh, k = shots[k], k + 1
                    if sh["quiet"] and not quiet_story(d, snap, t):
                        continue  # a quiet view only where the replayed story is quiet too
                    seg = {"id": f"timed-{k}", "label": sh["label"], "zoom": sh["zoom"], "until": sh["until"],
                           "position": sh["position"], "surface": sh["surface"], "exact_zoom": True}
                    if sh["quiet"]:
                        d.last_quiet, d.after_quiet = t, True
                if seg and t >= seg["until"]:
                    seg = None
                d.step(snap, now=t, segment=seg)
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
    ap.add_argument("--vehicles", choices=("journal", "live"), default="journal",
                    help="live: the service's vehicle position reads, modelled from the journals' replies (batch232)")
    ap.add_argument("--surface-from", nargs="+", help="director logs before --from: the planets' air time a restart "
                    "now keeps (surface-air.json), seeded from their last surface_window (batch232)")
    ap.add_argument("--timed", action="store_true", help="the log's timed shots (platforms, map, tours, cues, segments, "
                    "looks, threats) replayed at their times as segments; its quiet views where the replay is quiet too")
    ap.add_argument("--from", dest="t_from", help="HH:MM local (the first log's day)")
    ap.add_argument("--to", dest="t_to", help="HH:MM local")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="(batch257) a director setting for this replay (onecam's config), e.g. launch_gap=10")
    ap.add_argument("--no-launches", action="store_true", help="no silos read (batch257: by default the chronicle's "
                    "rockets on the journals' silos, as launches.SiloFeed reads them)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(tempfile.gettempdir(), f"director-replay-{os.getpid()}.jsonl")
    first = log_rows_of(a.log)[0]["t"]
    t0 = clock_t(first, a.t_from) if a.t_from else None
    t1 = clock_t(first, a.t_to) if a.t_to else None
    _, js, (t0, t1) = replay(a.log, a.runs, out, a.cams, a.rules, a.chart, t0=t0, t1=t1, fights=a.fights,
                             shells=a.shells, vehicles=a.vehicles, surface_from=a.surface_from, timed=a.timed,
                             launches=not a.no_launches, tuning={k: json.loads(v) for k, v in (x.split("=", 1) for x in a.set)})
    rows = list(airtime.rows_of(out))
    m = airtime.measure(rows, js, t0, t1)
    m.update(log=" ".join(os.path.basename(x) for x in a.log), rules=a.rules, cams=a.cams, replay_log=out,
             fights=a.fights, shells=a.shells, vehicles=a.vehicles,
             vehicle_framing=vehicle_framing(rows, vehicle_where(js, vehicle_paths(js)), t0, t1),
             launches=airtime.launches_on_air(rows, airtime.chronicle_rockets(chronicle_rows(a.runs))[0], t0, t1),
             on_air_min={k: round(v / 60, 1) for k, v in sorted(airtime.on_air_by(rows, t0, t1).items(), key=lambda kv: -kv[1])})
    if a.json:
        print(json.dumps(m))
    else:
        print(f"{m['log']} replayed ({a.rules}, {a.cams} cameras): idle or walk loop on air {100 * m['idle_loop_share']:.1f}% "
              f"(idle {100 * m['idle_share']:.1f}%, loop {100 * m['loop_share']:.1f}%); fresh events {m['fresh_events']}, "
              f"median {m['fresh_delay_median_s']} s to air, {m['fresh_missed']} missed; cuts {m['cuts_per_min']}/min; "
              f"on air (min) {m['on_air_min']}; vehicle shots {m['vehicle_framing']}; launches {m['launches']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
