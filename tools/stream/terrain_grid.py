"""The ground under the site's map, read from the game (d22 batch75 AK9, viewer Aurora site:4272: "Terrain is blank north
of the base where Opus explored. Please trace charting, capture and publishing, then make newly charted areas appear
automatically with visible terrain freshness.").

Before this the map's terrain was only the map camera's frames (mapframes.py): an OBS screenshot of the director's base
map shot, framed on the core and its outposts (every shift58 frame: y -580 to 546) and placed by matching our buildings,
published only with a site deploy. Ground charted beyond that frame (Opus at y -790 to -990, charted to y -1024) never
reached the map, and the basemap grid covers our buildings' box only (y from -608).

This keeps a grid of every charted Nauvis chunk the stream has read: each chunk's tiles sampled 4 x 4 (one tile at the
centre of each 8-tile cell, the tile's map colour as the game's map draws it) and the cells holding a cliff. A read
every EVERY seconds (live.py, one /silent-command, read only): the chunks next to the charted ones known (and around
the agents and the origin, to start), up to CHECK_MAX of them checked with is_chunk_charted, up to SAMPLE_MAX of the
charted ones sampled, plus the REFRESH_MAX longest-unread ones once they are REFRESH_S old. Measured on world n
(2026-10-22, tick 47.95M): 33 charted checks 0.04 ms; 32 chunks sampled 1.19 ms; so a full read (512 checks, 64 samples)
about 3.3 ms. A chunk newly charted next to the known ground is found within RECHECK_S plus a read, and sampled in the
same read or the next.

The grid lives in runs/RUN/terrain-grid.json (and is read back from the runs this one resumed from, as the map memory
is), so a restart does not read it all again. grid() is the state's terrain_grid: {cell: 8, x0, y0, w, h, rows (one
letter a cell: a tile's map colour, "c" a cliff, "." not charted or not read), palette [[letter, "#rrggbb", tile]],
chunks, tick (the newest sample's), oldest_tick, t (the wall time of the newest read)}, at most MAX_SIDE chunks a side
round the origin.
"""
import json, math, os, time

CHUNK, PER = 32, 4                 # tiles a chunk; samples a chunk side (cell 8 tiles)
CELL = CHUNK // PER
EVERY = 30.0                       # seconds between reads
CHECK_MAX, SAMPLE_MAX = 512, 64    # chunks checked, chunks sampled a read
REFRESH_S, REFRESH_MAX = 6 * 3600, 8
RECHECK_S = 120.0                  # an uncharted chunk next to the ground is checked again after this
MAX_SIDE = 160                     # chunks a side in the grid sent (5120 tiles)
SAVE_EVERY = 300.0
LETTERS = "abdefghijklmnopqrstvxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"  # c: cliff; u and w kept for mapview's GROUND
CLIFF = "c"

LUA = r"""
local s = game.surfaces.nauvis
local f = game.forces.player
local want = {WANT}
local cap, names, nl, out, unch, more = SAMPLE_MAX, {}, 0, {}, {}, {}
for i = 1, #want, 2 do
  local cx, cy = want[i], want[i + 1]
  if not f.is_chunk_charted(s, {cx, cy}) then unch[#unch + 1] = {cx, cy}
  elseif cap <= 0 then more[#more + 1] = {cx, cy}
  else
    cap = cap - 1
    local r = {}
    for j = 0, PER - 1 do for k = 0, PER - 1 do
      local t = s.get_tile(cx * 32 + k * CELL + CELL / 2, cy * 32 + j * CELL + CELL / 2).name
      if not names[t] then nl = nl + 1; names[t] = nl end
      r[#r + 1] = names[t]
    end end
    local cl = {}
    for _, e in pairs(s.find_entities_filtered{area = {{cx * 32, cy * 32}, {cx * 32 + 32, cy * 32 + 32}}, type = "cliff"}) do
      local p = e.position
      cl[#cl + 1] = math.floor((p.y - cy * 32) / CELL) * PER + math.floor((p.x - cx * 32) / CELL)
    end
    out[#out + 1] = {cx, cy, r, cl}
  end
end
local list, colours = {}, {}
for n, i in pairs(names) do
  list[i] = n
  local c = prototypes.tile[n] and prototypes.tile[n].map_color
  local r, g, b = c and (c.r or c[1]) or 0, c and (c.g or c[2]) or 0, c and (c.b or c[3]) or 0
  local k = math.max(r, g, b) > 1 and 1 or 255
  colours[i] = {math.floor(r * k + 0.5), math.floor(g * k + 0.5), math.floor(b * k + 0.5)}
end
rcon.print(helpers.table_to_json{tick = game.tick, sampled = out, uncharted = unch, more = more, names = list, colours = colours})
"""


def lua_for(chunks):
    """The read for these chunks [(cx, cy), ...]: each checked, the charted ones sampled (at most SAMPLE_MAX)."""
    want = ",".join(f"{int(cx)},{int(cy)}" for cx, cy in chunks)
    return (LUA.replace("{WANT}", "{" + want + "}").replace("SAMPLE_MAX", str(SAMPLE_MAX)).replace("PER", str(PER))
            .replace("CELL", str(CELL)))


def _key(cx, cy):
    return f"{cx},{cy}"


class TerrainGrid:
    def __init__(self, path=None, earlier=(), clock=time.time):
        self.path, self.clock = path, clock
        self.chunks = {}      # "cx,cy" -> [cells (PER*PER tile names, "" a cliff... as names list), tick, wall time]
        self.unch = {}        # "cx,cy" -> wall time it was last found uncharted
        self.pending = []     # charted, not yet sampled (a read's cap)
        self.colours = {}     # tile name -> "#rrggbb"
        self.letters = {}     # tile name -> letter
        self.next_read = 0.0
        self.saved = 0.0
        self.last_t = None
        self.error = None
        for p in [path] + list(earlier or ()):
            if p and self.load(p):
                break

    # ------------------------------------------------------------------ keeping
    def load(self, path):
        try:
            with open(path) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            return False
        if not isinstance(d, dict) or not isinstance(d.get("chunks"), dict):
            return False
        for k, v in d["chunks"].items():
            if isinstance(v, list) and len(v) == 3 and isinstance(v[0], list) and len(v[0]) == PER * PER:
                self.chunks[k] = v
        self.colours.update({k: v for k, v in (d.get("colours") or {}).items() if isinstance(v, str)})
        self.last_t = d.get("t")
        return bool(self.chunks)

    def save(self, force=False):
        now = self.clock()
        if not self.path or (not force and now - self.saved < SAVE_EVERY):
            return
        self.saved = now
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as fh:
                json.dump({"chunks": self.chunks, "colours": self.colours, "t": self.last_t}, fh, separators=(",", ":"))
            os.replace(tmp, self.path)
        except OSError as e:
            self.error = f"save: {e}"[:120]

    # ------------------------------------------------------------------ what to read
    def due(self):
        return self.clock() >= self.next_read

    def wanted(self, seeds=()):
        """The chunks to read now: the charted ones not yet sampled, the unread neighbours of the known ground (an
        uncharted one again after RECHECK_S), nearest a seed first; the seeds themselves when unknown; at most
        CHECK_MAX, then the REFRESH_MAX longest-unread chunks past REFRESH_S."""
        now = self.clock()
        seeds = [(0, 0)] + [tuple(s) for s in seeds]
        out, seen = [], set()

        def add(c):
            k = _key(*c)
            if k in seen:
                return
            seen.add(k)
            out.append(c)
        for c in self.pending:
            add(tuple(c))
        cand = set()
        for s in seeds:
            if _key(*s) not in self.chunks:
                cand.add(s)
        for k in self.chunks:
            cx, cy = map(int, k.split(","))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    n = (cx + dx, cy + dy)
                    nk = _key(*n)
                    if nk in self.chunks:
                        continue
                    t = self.unch.get(nk)
                    if t is None or now - t >= RECHECK_S:
                        cand.add(n)

        def dist(c):
            return min(abs(c[0] - s[0]) + abs(c[1] - s[1]) for s in seeds)
        for c in sorted(cand, key=lambda c: (dist(c), c)):
            if len(out) >= CHECK_MAX:
                break
            add(c)
        old = sorted((v[2], k) for k, v in self.chunks.items() if now - (v[2] or 0) >= REFRESH_S)
        for _, k in old[:REFRESH_MAX]:
            add(tuple(map(int, k.split(","))))
        return out[:CHECK_MAX + REFRESH_MAX]

    def read(self, lua_call, seeds=()):
        """One read through lua_call(lua) -> the decoded reply; True when it ran."""
        now = self.clock()
        self.next_read = now + EVERY
        want = self.wanted(seeds)
        if not want:
            return False
        try:
            res = lua_call(lua_for(want))
        except Exception as e:  # noqa: BLE001 - a failed read waits for the next
            self.error = f"{type(e).__name__}: {e}"[:160]
            self.next_read = now + 4 * EVERY
            return False
        self.take(res, now)
        self.save()
        return True

    def take(self, res, now=None):
        now = self.clock() if now is None else now
        if not isinstance(res, dict):
            self.error = "the read gave no table"
            return
        self.error = None
        lst = lambda v: v if isinstance(v, list) else []  # noqa: E731 - table_to_json writes an empty table as {}
        names = res.get("names") or []
        colours = res.get("colours") or []
        if isinstance(names, dict):  # table_to_json writes a list with holes as an object
            names = [names[k] for k in sorted(names, key=int)]
        if isinstance(colours, dict):
            colours = [colours[k] for k in sorted(colours, key=int)]
        for n, c in zip(names, colours):
            if isinstance(n, str) and isinstance(c, list) and len(c) == 3:
                self.colours[n] = "#%02x%02x%02x" % tuple(max(0, min(255, int(v))) for v in c)
        tick = res.get("tick")
        done = set()
        for row in lst(res.get("sampled")):
            try:
                cx, cy, cells, cliffs = row
                tiles = [names[int(i) - 1] for i in lst(cells)]
            except (ValueError, TypeError, IndexError):
                continue
            if len(tiles) != PER * PER:
                continue
            for i in (cliffs if isinstance(cliffs, list) else []):
                if isinstance(i, int) and 0 <= i < PER * PER:
                    tiles[i] = ""  # a cliff in that cell
            k = _key(cx, cy)
            self.chunks[k] = [tiles, tick, now]
            self.unch.pop(k, None)
            done.add(k)
        for c in lst(res.get("uncharted")):
            if isinstance(c, list) and len(c) == 2:
                self.unch[_key(*c)] = now
        self.pending = [c for c in lst(res.get("more")) if isinstance(c, list) and len(c) == 2 and _key(*c) not in done]
        if done:
            self.last_t = now

    # ------------------------------------------------------------------ what the map gets
    def grid(self):
        """The state's terrain_grid, or None before any chunk was read."""
        if not self.chunks:
            return None
        keys = [tuple(map(int, k.split(","))) for k in self.chunks]
        # at most MAX_SIDE chunks a side, round the origin
        half = MAX_SIDE // 2
        keys = [c for c in keys if -half <= c[0] < half and -half <= c[1] < half]
        if not keys:
            return None
        x0c, x1c = min(c[0] for c in keys), max(c[0] for c in keys)
        y0c, y1c = min(c[1] for c in keys), max(c[1] for c in keys)
        w, h = (x1c - x0c + 1) * PER, (y1c - y0c + 1) * PER
        rows = [["."] * w for _ in range(h)]
        for n in sorted(self.colours):
            if n not in self.letters and len(self.letters) < len(LETTERS):
                self.letters[n] = LETTERS[len(self.letters)]
        used, ticks = set(), []
        for cx, cy in keys:
            tiles, tick, _ = self.chunks[_key(cx, cy)]
            if isinstance(tick, int):
                ticks.append(tick)
            for i, name in enumerate(tiles):
                ch = CLIFF if name == "" else self.letters.get(name)
                if not ch:
                    continue
                used.add(ch if ch == CLIFF else name)
                rows[(cy - y0c) * PER + i // PER][(cx - x0c) * PER + i % PER] = ch
        palette = [[self.letters[n], self.colours[n], n] for n in sorted(used - {CLIFF}) if n in self.letters]
        if CLIFF in used:
            palette.append([CLIFF, "#5b4a36", "cliffs"])
        return {"cell": CELL, "x0": x0c * CHUNK, "y0": y0c * CHUNK, "w": w, "h": h, "rows": ["".join(r) for r in rows],
                "palette": palette, "chunks": len(keys), "tick": max(ticks) if ticks else None,
                "oldest_tick": min(ticks) if ticks else None, "t": self.last_t}


def seeds_from(agents):
    """Chunks under the agents on Nauvis ([{position, surface}, ...] as the state has them)."""
    out = []
    for a in agents or []:
        p = a.get("position") if isinstance(a, dict) else None
        if isinstance(p, dict) and (a.get("surface") or "nauvis") == "nauvis" and isinstance(p.get("x"), (int, float)):
            out.append((math.floor(p["x"] / CHUNK), math.floor(p["y"] / CHUNK)))
    return out
