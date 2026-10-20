#!/usr/bin/env python3
"""Whether each turret on the site's map can fire (d20 batch50 G1, viewer Aurora, shift46 09:09: "Could the map flag
turrets lacking ammo, fuel or energy and mark stale or unknown readings? Range circles show coverage, but viewers also
need to see whether defenses can fire.").

A pass reads every turret of ours in the basemap's defence cells (turretsweep.areas: a row's run of "D" cells as one
area), AREAS areas a command, one command per stream observe (live.py, after the range sweep's), and a new pass starts
at most EVERY seconds after the last one started. Each turret reads as what the game shows on it:
  a  armed: ammo in an ammo turret or an artillery turret, fluid in a flamethrower turret, or, for a laser or tesla
     turret, at least one shot's energy in its buffer (the prototype's attack_parameters.ammo_type.energy_consumption);
  e  empty: no ammo, shells or fluid;
  p  no power: an electric turret with less than a shot's energy.
public() is what the map gets (basemap["turret_state"]): the counts per state, every turret not armed now as [x, y,
state, name, age_s] (at most FLAG_MAX, the rest counted), the tick of the newest reading and the refresh. A turret
whose last reading is older than the start of the last finished pass (or than the pass running, before the first one
finished), or one on the map never read, is "u" (unknown) with the age of its last reading, or none.
"""
import json

import turretsweep

AREAS = 40        # areas a command at most (each one find, turret types only, then one read per turret)
MAX_TURRETS = 120  # a command stops after the area that brings it to this many turrets (about 60 us a turret on the
#                    d17 headless copy: 72 turrets 4.4 ms, so 120 about 7 ms); the rest go to the next command
WIDTH = 32        # tiles: a long run of defence cells is read in pieces this wide (at most ~64 gun turrets each)
EVERY = 60.0      # seconds between pass starts (the layer's refresh)
FLAG_MAX = 500    # turrets not armed listed on the map; the rest counted
NAMES = {"gun-turret": "Gun turret", "laser-turret": "Laser turret", "flamethrower-turret": "Flamethrower turret",
         "rocket-turret": "Rocket turret", "railgun-turret": "Railgun turret", "tesla-turret": "Tesla turret",
         "artillery-turret": "Artillery turret"}

# BODY: the areas as a JSON long string (as turretsweep.SWEEP_LUA)
STATE_LUA = r"""
local s = game.surfaces.nauvis
local need, out = {}, {}
local function shot(name)
  local v = need[name]
  if v == nil then
    v = 1
    pcall(function() local ap = prototypes.entity[name].attack_parameters v = ap.ammo_type.energy_consumption or 1 end)
    need[name] = v
  end
  return v
end
local done = 0
for i, a in ipairs(helpers.json_to_table(BODY)) do
  if #out >= 120 then break end
  done = i
  for _, e in pairs(s.find_entities_filtered{area = {{a[1], a[2]}, {a[3], a[4]}}, force = "player", type = {"ammo-turret", "electric-turret", "fluid-turret", "artillery-turret"}}) do
    local t, st = e.type, "a"
    if t == "ammo-turret" or t == "artillery-turret" then
      local inv = e.get_inventory(t == "ammo-turret" and defines.inventory.turret_ammo or defines.inventory.artillery_turret_ammo)
      if not inv or inv.is_empty() then st = "e" end
    elseif t == "fluid-turret" then
      local f = e.fluidbox[1]
      if not f or f.amount <= 0 then st = "e" end
    elseif e.energy < shot(e.name) then st = "p" end
    out[#out+1] = {math.floor(e.position.x), math.floor(e.position.y), st, e.name}
  end
end
rcon.print(helpers.table_to_json{tick = game.tick, done = done, turrets = out})
"""
assert f"#out >= {MAX_TURRETS} " in STATE_LUA  # (the literal keeps tools/console_audit.py's parse of the constant)


def state_lua(areas):
    text = json.dumps([[int(v) for v in a] for a in areas], separators=(",", ":"))
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    return STATE_LUA.replace("BODY", f"[{'=' * level}[{text}]{'=' * level}]")


def pieces(areas, width=WIDTH):
    """The areas cut to at most `width` tiles wide (a run of defence cells is one cell high)."""
    out = []
    for x0, y0, x1, y1 in areas:
        x = x0
        while x < x1:
            out.append([x, y0, min(x1, x + width), y1])
            x += width
    return out


class TurretState:
    """seen(basemap) on each basemap read; step(h, now) on an observe with nothing else to read: one command of a pass
    (a pass starts at most every EVERY s); public(tick) the map's turret_state."""

    def __init__(self, per=AREAS, every=EVERY):
        self.per, self.every = per, every
        self.areas = []        # the newest basemap's defence areas
        self.drawn = set()     # (x, y) of the turrets the newest basemap lists (never read: unknown)
        self.todo = []         # areas left in this pass
        self.next_pass = 0.0   # wall time the next pass may start
        self.readings = {}     # (x, y) -> (state, name, tick)
        self.pass_tick = None  # the first reply's tick of the pass running
        self.done_tick = None  # the first reply's tick of the last finished pass
        self.newest = None     # the newest reply's tick

    def seen(self, basemap):
        if not isinstance(basemap, dict):
            return
        self.areas = pieces(turretsweep.areas(basemap))
        self.drawn = {(t[0], t[1]) for t in basemap.get("turrets") or [] if isinstance(t, list) and len(t) >= 2}

    def due(self, now):
        return bool(self.todo) or (bool(self.areas) and now >= self.next_pass)

    def step(self, h, now):
        """One command of the pass (a new pass when due). Returns the reply's tick, or None."""
        if not self.todo:
            if not self.areas or now < self.next_pass:
                return None
            self.todo, self.next_pass, self.pass_tick = list(self.areas), now + self.every, None
        batch = self.todo[:self.per]
        r = h.lua(state_lua(batch))
        tick = r.get("tick") if isinstance(r, dict) else None
        got = r.get("turrets") if isinstance(r, dict) else None
        done = r.get("done") if isinstance(r, dict) else None
        # the areas the command finished (it stops at MAX_TURRETS); none on a bad reply: the batch counts as read
        n = done if isinstance(done, int) and 1 <= done <= len(batch) else len(batch)
        self.todo = self.todo[n:]
        if isinstance(tick, int):
            if self.pass_tick is None:
                self.pass_tick = tick
            self.newest = tick
            for t in got if isinstance(got, list) else []:  # table_to_json writes an empty table as {}
                if isinstance(t, list) and len(t) == 4 and t[2] in ("a", "e", "p"):
                    self.readings[(t[0], t[1])] = (t[2], t[3], tick)
        if not self.todo:
            self.done_tick = self.pass_tick
            # a turret gone since (not read in this whole pass) is dropped, unless the map still draws it
            self.readings = {k: v for k, v in self.readings.items() if v[2] >= (self.done_tick or 0) or k in self.drawn}
        return tick

    def public(self, tick=None):
        """{as_of, every_s, counts {armed, empty, no_power, unknown}, flagged [[x, y, state, name, age_s]], more?}, or
        None before the first reading."""
        if self.newest is None:
            return None
        now = tick if isinstance(tick, int) else self.newest
        fresh = self.done_tick if self.done_tick is not None else self.pass_tick or 0
        counts = {"armed": 0, "empty": 0, "no_power": 0, "unknown": 0}
        flagged = []
        word = {"a": "armed", "e": "empty", "p": "no_power"}
        for key in set(self.readings) | self.drawn:
            r = self.readings.get(key)
            if r is None or r[2] < fresh:
                counts["unknown"] += 1
                flagged.append([key[0], key[1], "u", r[1] if r else None, round((now - r[2]) / 60) if r else None])
                continue
            counts[word[r[0]]] += 1
            if r[0] != "a":
                flagged.append([key[0], key[1], r[0], r[1], round((now - r[2]) / 60)])
        # empty and unpowered first, then unknown; nearest the base's middle is not known here: by position
        flagged.sort(key=lambda f: (f[2] == "u", f[1], f[0]))
        out = {"as_of": self.newest, "every_s": int(self.every), "counts": counts, "flagged": flagged[:FLAG_MAX]}
        if len(flagged) > FLAG_MAX:
            out["more"] = len(flagged) - FLAG_MAX
        return out


if __name__ == "__main__":
    # python3 tools/stream/turretstate.py runs/shiftNN/basemap/TICK.json: the areas a pass reads and its commands
    import sys
    bm = json.load(open(sys.argv[1]))
    a = pieces(turretsweep.areas(bm))
    print(f"{len(a)} areas, at least {(len(a) + AREAS - 1) // AREAS} commands a pass, longest command "
          f"{max((len(state_lua(a[i:i + AREAS])) for i in range(0, len(a), AREAS)), default=0)} bytes")
