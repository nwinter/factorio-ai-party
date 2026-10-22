"""What an agent carries, wears and builds, shown on stream when it matters (operator 08:55, from Nick: "Especially
when they are in combat, I'd like to see their guns/ammo. This can't be shown all the time, but maybe we can find good
heuristics").

live.py reads the harness's `loadout` (loadout.lua) every few seconds; model.py keeps one Loadouts. For each agent it
picks one mode, so never everything at once:
  combat    shooting, health falling in the last FALL_S seconds, in a vehicle, or a fight near it (FIGHT_TILES):
            the gun in hand with its ammo, the other guns, shield and armor equipment
  building  a build action running or the hand-craft queue busy: the craft queue with the head's progress, build x of y
  carrying  otherwise, for CARRY_S seconds every CARRY_EVERY (offset per agent): the largest stacks and the armor
  None      nothing to show
The overlay (static/overlay.js renderLoadouts) shows the agent on the main camera and the one in the inset.
"""
import math, zlib

FALL_S = 10.0          # health lower than FALL_S ago: under fire
FIGHT_TILES = 48.0     # a fight within this many tiles of the agent ...
FIGHT_RECENT_S = 30.0  # ... reported in the last 30 s
CARRY_EVERY = 180.0    # a "carrying" card every 3 minutes per agent ...
CARRY_S = 12.0         # ... for 12 s
ITEMS = 6              # stacks on the carrying card
EQUIPMENT = 6          # equipment icons


def _offset(name):
    return zlib.crc32((name or "").encode()) % int(CARRY_EVERY)


class Loadouts:
    def __init__(self):
        self.rows = {}       # name -> the latest loadout row
        self.seen_t = {}     # name -> when it was read
        self.health = {}     # name -> [(t, health)] over the last FALL_S seconds and one before

    def ingest(self, rows, now):
        for r in rows or []:
            name = r.get("name")
            if not name:
                continue
            self.rows[name], self.seen_t[name] = r, now
            h = (r.get("health") or {}).get("now")
            if h is None:
                continue
            hist = self.health.setdefault(name, [])
            hist.append((now, h))
            while len(hist) > 1 and hist[1][0] <= now - FALL_S:
                hist.pop(0)

    def falling(self, name, now):
        hist = self.health.get(name) or []
        return len(hist) >= 2 and hist[-1][1] < max(h for _, h in hist[:-1])

    @staticmethod
    def _gun(r):
        guns, ammo = r.get("guns") or [], r.get("ammo") or []
        sel = r.get("selected_gun") or 1
        out = []
        for i, g in enumerate(guns):
            if not g:
                continue
            a = ammo[i] if i < len(ammo) and ammo[i] else None
            out.append({"name": g["name"], "ammo": a["name"] if a else None, "count": a["count"] if a else 0,
                        "selected": i + 1 == sel})
        out.sort(key=lambda g: not g["selected"])
        return out

    @staticmethod
    def _armor(r):
        a = r.get("armor") or {}
        if not a.get("name"):
            return None
        # (d22 batch94 BD1) the quality above normal, of the armor and of each piece (the runtime counts by both)
        eq = [dict({"name": e["name"], "count": e.get("count", 1)}, **({"quality": e["quality"]} if e.get("quality") else {}))
              for e in (a.get("equipment") or [])[:EQUIPMENT]]
        return dict({"name": a["name"], "equipment": eq, "shield": a.get("shield"), "battery_mj": a.get("battery_mj")},
                    **({"quality": a["quality"]} if a.get("quality") else {}))

    def mode(self, name, now, fight_near=False):
        """(mode, payload) for one agent, or (None, None)."""
        r = self.rows.get(name)
        if not r or not r.get("alive"):
            return None, None
        base = {"name": name, "health": r.get("health"), "vehicle": r.get("vehicle"), "armor": self._armor(r)}
        if r.get("shooting") or r.get("vehicle") or fight_near or self.falling(name, now):
            why = ("shooting" if r.get("shooting") else "under fire" if self.falling(name, now)
                   else "in " + r["vehicle"] if r.get("vehicle") else "fight near")
            return "combat", dict(base, guns=self._gun(r), why=why)
        b, c = r.get("building"), r.get("crafting")
        if b or (c and c.get("items")):
            return "building", dict(base, building=b, crafting=c)
        if (now + _offset(name)) % CARRY_EVERY < CARRY_S:
            return "carrying", dict(base, items=(r.get("items") or [])[:ITEMS], slots=r.get("slots"))
        return None, None

    def snapshot(self, agents, fights, now):
        """{name: {mode, ...}} for the agents with something to show. agents: the snapshot's agent rows (name,
        position, surface); fights: the snapshot's fights rows (position, surface)."""
        out = {}
        for a in agents or []:
            name = a.get("name")
            pos = a.get("position") or {}
            near = bool(a.get("combat"))  # the stream's own combat flag (model.py: hits on the agent)
            for f in fights or []:
                fp = f.get("position") or {}  # model.py fights rows: position {x, y, surface?, extent?}, last
                if now - (f.get("last") or 0) > FIGHT_RECENT_S:
                    continue
                if (fp.get("surface") or "nauvis") != (a.get("surface") or "nauvis") or "x" not in fp or "x" not in pos:
                    continue
                if math.hypot(fp["x"] - pos["x"], fp["y"] - pos["y"]) <= FIGHT_TILES:
                    near = True
                    break
            m, payload = self.mode(name, now, near)
            if m:
                out[name] = dict(payload, mode=m, age_s=round(now - self.seen_t.get(name, now), 1))
        return out
