"""Rocket launches for the launch shot (d26 batch257 IB, viewer Aurora site:5029/5030: 43.3% of shift83's program was a
standing character, while 1261 rockets went up, about 5 a minute across the planets, and none on air).

A launch cannot be seen coming before it is ordered: the silos stand at rocket_ready (status 7) until a platform's
request takes their cargo. From the order the silo goes through its states for about 9 s before the rocket lifts off
(world n, d26, 22 launches sampled every 0.5 s; game seconds):

  7 rocket_ready -> (8 launch_starting 0.6) -> 14 launch_started 1.6-2.3 -> 9 engine_starting 5.0-5.7 ->
  10 arms_retract 1.7-2.3 -> 11 rocket_flying 5.9-6.8 (lift-off, the rocket on screen) -> 5 rocket_rising (the next
  rocket, 9.6) -> 6 arms_advance 1.7 -> 7, or 12/13 doors closing and 0 building when no parts wait.

So the stream service's poll (every 3 s) sees each launch at least 6 s before lift-off: time to frame a standby and cut.
SiloFeed keeps the silos (surface and position; a silo has no get-by-unit-number) from the agents' journals (`silo`,
`launch` and other replies' silos lists, kept in runs/RUN/silos.json) and reads their states every poll (harness
SILOS_LUA, 0.093 ms for 15 silos on world n). When the force has more silos than the list, it sweeps one 256-tile block
of a planet a poll (SILO_SWEEP_LUA, 1.8 ms on Nauvis's core) until the list is whole. Each launching silo's row says
when it lifts off at the soonest and the latest in wall seconds (the game's speed from the reads' ticks), and where the
rocket goes when the chronicle's rocket rows of that planet name it.
"""
import json, os, time

LAUNCHING = {8, 14, 9, 10}  # ordered, not yet lifted off
FLYING = 11
# seconds of game time from a read in this state to lift-off: (soonest, latest), from the sample above
LIFT = {8: (8.3, 10.9), 14: (6.7, 10.3), 9: (1.7, 8.0), 10: (0.0, 2.3)}
SWEEP_BLOCK = 256   # tiles a block
SWEEP_REACH = 1024  # blocks out to this far from the planet's origin
MISS_DROP = 3       # a silo not found this many reads in a row is dropped (mined)
SWEEP_PAUSE = 1800.0  # seconds after a whole sweep that left the count short before the next
SWEEP_GRACE = 600.0  # seconds after the first read before a sweep: the journals' silo replies first (a new run's file
                     # is empty; Sol read silos every few minutes in shift83)
ROCKET_KEEP = 20.0  # game seconds a chronicle rocket row may be older than the read that sees its silo launching


def key(surface, x, y):
    return f"{surface}@{float(x):g},{float(y):g}"


class SiloFeed:
    def __init__(self, path=None):
        self.path = path  # runs/RUN/silos.json
        self.silos = {}   # key -> {surface, x, y, misses}
        self.status = {}  # key -> the last read's status
        self.count = None  # the force's silos (the last read)
        self.ups = 60.0
        self.last = None   # (wall, tick) of the last read
        self.rockets = []  # chronicle rocket rows not yet matched: (tick, surface, destination)
        self.to = {}       # key -> the destination of its launch under way
        self.sweep = None  # {planets, i, blocks, j} while sweeping
        self.sweep_after = 0.0
        self.load()

    def load(self):
        try:
            with open(self.path) as f:
                for s, x, y in json.load(f).get("silos") or []:
                    self.add(s, x, y, save=False)
        except (OSError, ValueError, TypeError):
            pass

    def save(self):
        if not self.path:
            return
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"silos": [[r["surface"], r["x"], r["y"]] for r in self.silos.values()]}, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def add(self, surface, x, y, save=True):
        k = key(surface, x, y)
        if k in self.silos:
            return False
        self.silos[k] = {"surface": str(surface), "x": float(x), "y": float(y), "misses": 0}
        if save:
            self.save()
        return True

    def ingest(self, agent, r):
        """A journal row: the silos a reply lists ({silos: [{position, surface}]}, else the reply's surface or planet)."""
        if not isinstance(r, dict) or r.get("event") != "response":
            return
        res = (r.get("response") or {}).get("result")
        rows = res.get("silos") if isinstance(res, dict) else None
        if not isinstance(rows, list):
            return
        new = False
        for s in rows:
            p = s.get("position") if isinstance(s, dict) else None
            if isinstance(p, dict) and isinstance(p.get("x"), (int, float)) and isinstance(p.get("y"), (int, float)) and \
                    s.get("name", "rocket-silo") == "rocket-silo":
                surface = s.get("surface") or res.get("surface") or res.get("planet")  # (observe's silos: planet)
                if isinstance(surface, str):
                    new = self.add(surface, p["x"], p["y"], save=False) or new
        if new:
            self.save()

    def note_rockets(self, events):
        """The chronicle's new events: its rocket rows (surface, to, tick) name the launches' destinations."""
        for e in events or []:
            if isinstance(e, dict) and e.get("kind") == "rocket" and isinstance(e.get("tick"), (int, float)):
                to = str(e.get("to") or "")
                self.rockets.append((e["tick"], str(e.get("surface") or ""), to[9:] if to.startswith("platform ") else to))
        self.rockets = self.rockets[-200:]

    def read(self, h, now=None):
        """One poll: the silos' states (and a sweep block while the list lacks silos) -> the snapshot's `silos`:
        {read_at, tick, count, known, rows [{surface, x, y, status, lift (soonest, latest wall time) while launching,
        to}]}, or None with no silo known and none to find."""
        now = time.time() if now is None else now
        if self.last is None and not self.sweep_after:
            self.sweep_after = now + SWEEP_GRACE
        if self.count is not None and self.count > len(self.silos) and now >= self.sweep_after:
            self.sweep_step(h, now)
        elif self.count is not None and self.count <= len(self.silos):
            self.sweep = None
        if not self.silos and self.count == 0:
            return None
        keys = list(self.silos)
        got = h.silos([(self.silos[k]["surface"], self.silos[k]["x"], self.silos[k]["y"]) for k in keys])
        tick = got.get("tick")
        self.count = got.get("n") if isinstance(got.get("n"), int) else self.count
        if self.last and isinstance(tick, (int, float)) and now > self.last[0] + 0.5 and tick > self.last[1]:
            self.ups = max(10.0, min(60.0, 0.7 * self.ups + 0.3 * (tick - self.last[1]) / (now - self.last[0])))
        if isinstance(tick, (int, float)):
            self.last = (now, tick)
        rows, gone = [], False
        st = got.get("s") or []
        for i, k in enumerate(keys):
            s = self.silos[k]
            status = st[i] if i < len(st) and isinstance(st[i], int) else -1
            if status < 0:
                s["misses"] += 1
                if s["misses"] >= MISS_DROP:
                    self.silos.pop(k)
                    gone = True
                continue
            s["misses"] = 0
            was = self.status.get(k)
            self.status[k] = status
            row = {"surface": s["surface"], "x": s["x"], "y": s["y"], "status": status}
            if status in LAUNCHING:
                if was not in LAUNCHING:
                    self.to[k] = self.match_rocket(s["surface"], tick)
                lo, hi = LIFT[status]
                row["lift"] = (round(now + lo * 60.0 / self.ups, 1), round(now + hi * 60.0 / self.ups, 1))
            elif status != FLYING:
                self.to.pop(k, None)
            if self.to.get(k):
                row["to"] = self.to[k]
            rows.append(row)
        if gone:
            self.save()
        return {"read_at": now, "tick": tick, "count": self.count, "known": len(self.silos), "rows": rows}

    def match_rocket(self, surface, tick):
        """The destination of the oldest chronicle rocket of this planet ordered at most ROCKET_KEEP before `tick`."""
        if not isinstance(tick, (int, float)):
            return None
        for i, (t, s, to) in enumerate(self.rockets):
            if s == surface and tick - ROCKET_KEEP * 60 <= t <= tick + 60:
                self.rockets.pop(i)
                return to or None
        return None

    def sweep_step(self, h, now):
        """One block of the sweep (the planets in turn, blocks from the origin out); new silos join the list."""
        sw = self.sweep
        if sw is None:
            got = h.silo_sweep("nauvis", ((0, 0), (0, 0)))  # an empty area: the planets' names only
            n = SWEEP_REACH // SWEEP_BLOCK
            blocks = sorted(((bx, by) for bx in range(-n, n) for by in range(-n, n)),
                            key=lambda b: abs(b[0] + 0.5) + abs(b[1] + 0.5))
            self.sweep = sw = {"planets": sorted(got["planets"]) or ["nauvis"], "i": 0, "blocks": blocks, "j": 0}
            return
        surface = sw["planets"][sw["i"] % len(sw["planets"])]
        bx, by = sw["blocks"][sw["j"]]
        area = ((bx * SWEEP_BLOCK, by * SWEEP_BLOCK), ((bx + 1) * SWEEP_BLOCK, (by + 1) * SWEEP_BLOCK))
        got = h.silo_sweep(surface, area)
        if any([self.add(surface, x, y, save=False) for x, y in got["silos"]]):
            self.save()
        sw["j"] += 1
        if sw["j"] >= len(sw["blocks"]):
            sw["j"], sw["i"] = 0, sw["i"] + 1
            if sw["i"] >= len(sw["planets"]):
                self.sweep = None  # all swept: the count may hold silos beyond SWEEP_REACH; again after a pause
                self.sweep_after = now + SWEEP_PAUSE
