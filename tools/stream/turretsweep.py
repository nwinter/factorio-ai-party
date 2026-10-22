#!/usr/bin/env python3
"""Every turret's range for the site's map (d19 batch42 B2, viewer Aurora: "the 600-entry cap currently omits southern
defenses, so missing circles can be mistaken for real gaps").

The basemap (the harness census, census.lua; BASEMAP_LUA without it) lists at most CAP turrets, the first in its walk:
shift40's last snapshot had 600, all north of y=-82, while the score counted 1162 gun, 553 laser and 22 flamethrower
turrets on all surfaces. When a basemap reaches the cap, this sweep reads the rest where they can be: the coarse grid's
defence cells ("D": turrets; walls and gates are "W" since d22 batch75 AK4, a cell with both is D), a row's run of D cells as one area, AREAS areas a command (one find each,
turret types only), one command per stream observe (live.py), so a pass over shift40's 594 D cells (about 200 runs)
takes a few commands. A finished pass replaces the basemap's turret list until the next one finishes; a pass starts
from the newest basemap.

The list the site gets (merge()): turrets of the same range within MERGE tiles of one kept are left out (a wall of gun
turrets every 2 tiles draws the same union of circles within 2 tiles at its edge), so the state stays small, and
basemap["turrets_read"] says what was read: {turrets: the count read, drawn: the count kept, as_of: tick, complete:
true} (a pass), or {turrets: CAP, capped: true} (a capped basemap before the first pass: the site says the layer is
incomplete).
"""
import json

CAP = 600          # census.lua and BASEMAP_LUA keep this many
AREAS = 40         # areas (runs of D cells) a command
MERGE = 2          # tiles: a turret this close to a kept one of the same range or less is left out

# BODY: the areas as a JSON long string (tools/console_audit.py blanks it: the shape is the same for every batch)
SWEEP_LUA = r"""
local s = game.surfaces.nauvis
local R, out = {}, {}
for _, a in ipairs(helpers.json_to_table(BODY)) do
  for _, e in pairs(s.find_entities_filtered{area = {{a[1], a[2]}, {a[3], a[4]}}, force = "player", type = {"ammo-turret", "electric-turret", "fluid-turret"}}) do
    local r = R[e.name]
    if r == nil then
      r = 0
      pcall(function() local ap = prototypes.entity[e.name].attack_parameters r = ap and ap.range or 0 end)
      R[e.name] = r
    end
    if r > 0 then out[#out+1] = {math.floor(e.position.x), math.floor(e.position.y), r} end
  end
end
rcon.print(helpers.table_to_json{tick = game.tick, turrets = out})
"""


def sweep_lua(areas):
    text = json.dumps([[int(v) for v in a] for a in areas], separators=(",", ":"))
    level = 0
    while f"]{'=' * level}]" in text:  # (harness.lua_string: the JSON holds "]]")
        level += 1
    return SWEEP_LUA.replace("BODY", f"[{'=' * level}[{text}]{'=' * level}]")


def areas(basemap):
    """[x0, y0, x1, y1] tile areas covering the basemap's D cells: each row's runs of D cells."""
    cell, x0, y0 = basemap.get("cell"), basemap.get("x0"), basemap.get("y0")
    rows = basemap.get("rows")
    if not isinstance(cell, (int, float)) or cell <= 0 or not isinstance(rows, list):
        return []
    out = []
    for r, row in enumerate(rows):
        row = str(row)
        c = 0
        while c < len(row):
            if row[c] != "D":
                c += 1
                continue
            start = c
            while c < len(row) and row[c] == "D":
                c += 1
            out.append([x0 + start * cell, y0 + r * cell, x0 + c * cell, y0 + (r + 1) * cell])
    return out


def merge(turrets, near=MERGE):
    """The turrets the map draws: each [x, y, range] once, and none within `near` tiles of a kept one of at least its
    range (the larger ranges first)."""
    seen, kept, grid = set(), [], {}
    for t in sorted(turrets, key=lambda t: (-t[2], t[0], t[1])):
        key = (t[0], t[1])
        if key in seen:
            continue
        seen.add(key)
        gx, gy = t[0] // 8, t[1] // 8
        close = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for k in grid.get((gx + dx, gy + dy), ()):
                    if k[2] >= t[2] and abs(k[0] - t[0]) <= near and abs(k[1] - t[1]) <= near:
                        close = True
                        break
                if close:
                    break
            if close:
                break
        if not close:
            kept.append(list(t))
            grid.setdefault((gx, gy), []).append(t)
    return kept, len(seen)


class TurretSweep:
    """step(h) after a basemap read and on each observe: one command of the pass; apply(basemap) puts the last finished
    pass's turrets on a basemap (and says what was read)."""

    def __init__(self, cap=CAP, per=AREAS):
        self.cap, self.per = cap, per
        self.todo = []      # areas left in this pass
        self.found = []     # turrets read in this pass
        self.done = None    # (turrets, read count, tick) of the last finished pass
        self.capped = False

    def seen(self, basemap):
        """A new basemap: a capped one starts a pass when none runs."""
        turrets = basemap.get("turrets") if isinstance(basemap, dict) else None
        self.capped = isinstance(turrets, list) and len(turrets) >= self.cap
        if self.capped and not self.todo:
            self.todo, self.found = areas(basemap), []

    def step(self, h):
        """One command of the running pass (nothing when none runs). Returns the reply's tick, or None."""
        if not self.todo:
            return None
        batch, self.todo = self.todo[:self.per], self.todo[self.per:]
        r = h.lua(sweep_lua(batch))
        got = r.get("turrets") if isinstance(r, dict) else None
        if isinstance(got, list):  # table_to_json writes an empty table as {}
            self.found.extend(t for t in got if isinstance(t, list) and len(t) == 3)
        if not self.todo:
            kept, n = merge(self.found)
            self.done = (kept, n, r.get("tick") if isinstance(r, dict) else None)
            self.found = []
        return r.get("tick") if isinstance(r, dict) else None

    def apply(self, basemap):
        """The basemap with the last pass's turrets (a capped one), or marked capped (before a pass finished)."""
        if not isinstance(basemap, dict) or not self.capped:
            return basemap
        if self.done:
            kept, n, tick = self.done
            return dict(basemap, turrets=kept, turrets_read={"turrets": n, "drawn": len(kept), "as_of": tick, "complete": True})
        return dict(basemap, turrets_read={"turrets": len(basemap.get("turrets") or []), "capped": True})


if __name__ == "__main__":
    # python3 tools/stream/turretsweep.py runs/shift40/basemap/TICK.json: the areas a pass reads, and its commands
    import sys
    bm = json.load(open(sys.argv[1]))
    a = areas(bm)
    print(f"{len(bm.get('turrets') or [])} turrets listed, {sum(r.count('D') for r in bm.get('rows') or [])} D cells, "
          f"{len(a)} areas, {(len(a) + AREAS - 1) // AREAS} commands, longest command {max((len(sweep_lua(a[i:i + AREAS])) for i in range(0, len(a), AREAS)), default=0)} bytes")
