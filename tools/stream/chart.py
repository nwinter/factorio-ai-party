"""The site's chart (d22 batch97 BG3; Nick asked for a better map, batch97's study recommends drawing it from data): each
planet and platform as 384-tile cells, one PNG a cell at 1 px a tile in the game's own map colours (tiles, then
resources, trees, rocks and cliffs, then every building at its footprint, turned by its direction), with a labels file
a cell (machine recipes and train stop names as text; no game icons or sprites) and an index with each cell's read
ticks, drawn from the harness's `chart` operator read (chart.lua) chunk by chunk.

The service asks on its own timer, one read every EVERY seconds (each under 20 ms on world n: at most 6 chunks or 1200
entities a read; on the x86 private copy the base's densest chunks read in 7.5-10.2 ms a read, outer ones 4.5-5.2):
- once: `protos` (the map colours and footprints); every SURFACES_EVERY: `surfaces` (planets and platforms);
- the first pass of a surface: `list` over 64x64-chunk blocks from the one round the origin outwards while charted chunks reach a
  block's edge, then every charted chunk not yet in the store, up to CHUNKS_READ a read, two reads in three, one every
  FIRST_EVERY seconds (Nauvis's 3,214 charted chunks in about an hour, once: the store goes on with the resumed runs);
  again every LIST_EVERY, for newly charted chunks;
- then `dirty`, the surfaces in proportion to their chunks (each one's check cycle about the same, about 10 minutes
  for world n's 8,000 or so): up to DIRTY chunks marked since their last read (built by hand, mined, died, or a
  changed entity count found by `check`, CHECK chunks a read), each at most once per MIN_AGE ticks (10 game minutes);
- chunks last read REFRESH_TICKS ago are read again (tiles laid by robots and nests the events do not mark).

The store is runs/RUN/chart/store/SURFACE/CX_CY.json (a cell's chunks, each with its read tick and rows), read back
from the runs this one resumed from (as the map memory is); a changed chunk's cell (and a neighbour cell when the chunk
is on its edge, for footprints across it) is drawn again into runs/RUN/chart/out/SURFACE/CX_CY.png and .labels.json;
out/index.json lists every cell as [version, its chunks' oldest read tick, newest, chunks, and the box round our
buildings in it x0, y0, x1, y1 in tiles when it has any] (the page frames a surface on those boxes). The site build publishes
out/ under /live/chart/ (site/build.py), and push_live sends the published index's version.
"""
import json, math, os, re, time

CHUNK, CPC = 32, 12              # tiles a chunk; chunks a cell side
CELL = CHUNK * CPC               # 384 tiles a cell side
EVERY = 5.0                      # seconds between reads (FIRST_EVERY while chunks wait to be read)
FIRST_EVERY = 3.0
SURFACES_EVERY = 300.0
LIST_EVERY = 1800.0              # seconds between a surface's lists for newly charted chunks
BLOCK = 64                       # chunks a list block side (the read takes at most 4096); block (0,0) centred on the origin
CHUNKS_READ, DIRTY, CHECK = 6, 6, 48   # chart.lua stops a read at 6 chunks or 1200 entities; a chunk counted 0.06-0.45 ms
MIN_AGE = 36000                  # ticks: a chunk read at most every 10 game minutes
REFRESH_TICKS = 6 * 216000       # ticks: a chunk read again after 6 game hours
SAVE_EVERY = 120.0
BUILD_MAX = 3                    # cells drawn a step at most (about 70 ms a cell)
LAYER = {"resource": 0, "tree": 1, "simple-entity": 1, "cliff": 1, "fish": 1, "plant": 1}  # drawn first; buildings after
_SAFE = re.compile(r"[^\w.-]")
# Rails as curves: each rail type's two ends by its direction, (dx, dy, the end's outward direction in 16ths) from the
# entity's position, read on the private copy with LuaEntity.get_rail_end (2.0.77; elevated rails the same). A rail is
# drawn as the cubic curve between its ends, leaving each along its direction, 2 px wide (a track is 2 tiles).
RAIL_ENDS = {
    "straight-rail": {0: ((0, -1, 0), (0, 1, 8)), 2: ((-1, 1, 10), (1, -1, 2)), 4: ((1, 0, 4), (-1, 0, 12)), 6: ((-1, -1, 14), (1, 1, 6))},
    "half-diagonal-rail": {0: ((1, 2, 7), (-1, -2, 15)), 2: ((-1, 2, 9), (1, -2, 1)), 4: ((-2, 1, 11), (2, -1, 3)), 6: ((-2, -1, 13), (2, 1, 5))},
    "curved-rail-a": {0: ((0, 2, 8), (-1, -3, 15)), 2: ((0, 2, 8), (1, -3, 1)), 4: ((-2, 0, 12), (3, -1, 3)), 6: ((-2, 0, 12), (3, 1, 5)),
                      8: ((0, -2, 0), (1, 3, 7)), 10: ((0, -2, 0), (-1, 3, 9)), 12: ((2, 0, 4), (-3, 1, 11)), 14: ((2, 0, 4), (-3, -1, 13))},
    "curved-rail-b": {0: ((1, 2, 7), (-2, -2, 14)), 2: ((-1, 2, 9), (2, -2, 2)), 4: ((-2, 1, 11), (2, -2, 2)), 6: ((-2, -1, 13), (2, 2, 6)),
                      8: ((-1, -2, 15), (2, 2, 6)), 10: ((1, -2, 1), (-2, 2, 10)), 12: ((2, -1, 3), (-2, 2, 10)), 14: ((2, 1, 5), (-2, -2, 14))},
}
for _t in list(RAIL_ENDS):
    RAIL_ENDS["elevated-" + _t] = RAIL_ENDS[_t]
_HEAD = [(math.sin(i * math.pi / 8), -math.cos(i * math.pi / 8)) for i in range(16)]


def rail_points(kind, d, x, y):
    """The tile points along a rail of this type and direction at (x, y) (tiles), or None for another entity."""
    ends = RAIL_ENDS.get(kind)
    if not ends:
        return None
    e = ends.get(d) or ends.get(d % 8)
    if not e:
        return None
    (ax, ay, ad), (bx, by, bd) = e
    p0, p3 = (x + ax, y + ay), (x + bx, y + by)
    k = math.hypot(bx - ax, by - ay) / 3
    p1 = (p0[0] - _HEAD[ad][0] * k, p0[1] - _HEAD[ad][1] * k)
    p2 = (p3[0] - _HEAD[bd][0] * k, p3[1] - _HEAD[bd][1] * k)
    n = max(2, int(math.hypot(bx - ax, by - ay) * 3))
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return out


def _cell_of(cx, cy):
    return cx // CPC, cy // CPC


def _rgb(h):
    if not isinstance(h, str) or len(h) != 6:
        return None
    try:
        return bytes((int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255))
    except ValueError:
        return None


def parse_protos(text):
    """chart {protos} -> ({entity: {type, w, h, f, e, m}}, {tile: rgba})."""
    ents, tiles = {}, {}
    for line in (text or "").split("\n"):
        p = line.split(" ")
        if p[0] == "E" and len(p) == 8:
            try:
                ents[p[1]] = {"type": p[2], "w": int(p[3]), "h": int(p[4]), "f": _rgb(p[5]), "e": _rgb(p[6]), "m": _rgb(p[7])}
            except ValueError:
                continue
        elif p[0] == "T" and len(p) == 3:
            tiles[p[1]] = _rgb(p[2])
    return ents, tiles


def split_rows(res):
    """A chunks or dirty read's reply -> [(cx, cy, raw)]: raw (the chunk's lines, the reply's tile names, its entity
    names) or None for a chunk not charted. A chunk is kept as its own text (a few KB a busy chunk) and parsed only to
    draw it: as Python tuples Nauvis's store took about 90 MB."""
    tn = tuple(res.get("tn").split(" ")) if res.get("tn") else ()
    en = tuple(res.get("en").split(" ")) if res.get("en") else ()
    out, cur, lines = [], None, []

    def close():
        if cur is not None:
            out.append((cur[0], cur[1], ("\n".join(lines), tn, en)))
    for line in (res.get("rows") or "").split("\n"):
        tag, _, rest = line.partition(" ")
        if tag in ("C", "U"):
            close()
            cur, lines = None, []
            try:
                cx, cy = map(int, rest.split(" "))
            except ValueError:
                continue
            if tag == "C":
                cur = (cx, cy)
            else:
                out.append((cx, cy, None))
        elif cur is not None and line:
            lines.append(line)
    close()
    return out


def parse_chunk(raw):
    """A chunk's raw (text, tile names, entity names) -> {tiles: [32 rows of [(name, run)]], ents: [(name, x2, y2, dir,
    force)], recipes: [(x2, y2, name)], stops: [(x2, y2, name)]}."""
    text, tn, en = raw
    rec = {"tiles": [], "ents": [], "recipes": [], "stops": []}
    for line in text.split("\n"):
        tag, _, rest = line.partition(" ")
        try:
            if tag == "T":
                rec["tiles"] = [[(tn[int(i) - 1], int(n)) for i, n in (p.split(",") for p in row.split(" ") if p)]
                                for row in rest.split("|")]
            elif tag == "E":
                i, x2, y2, d, f = map(int, rest.split(" "))
                rec["ents"].append((en[i - 1], x2, y2, d, f))
            elif tag in ("R", "S"):
                x2, y2, name = rest.split(" ", 2)
                rec["recipes" if tag == "R" else "stops"].append((int(x2), int(y2), name))
        except (ValueError, IndexError):
            continue
    return rec


def parse_rows(res):
    """A reply -> [(cx, cy, record or None)] (parse_chunk's records)."""
    return [(cx, cy, parse_chunk(raw) if raw else None) for cx, cy, raw in split_rows(res)]


class Cell:
    """A cell's chunks: (cx, cy) -> [read tick, raw (text, tile names, entity names) or None (not charted)]; on disk
    the name tables once each."""

    def __init__(self):
        self.chunks = {}
        self.dirty = False   # to save
        self.draw = False    # to draw

    def to_json(self):
        tables, at = [], {}
        chunks = {}
        for (cx, cy), (tick, raw) in self.chunks.items():
            if raw is None:
                chunks[f"{cx},{cy}"] = [tick, None]
                continue
            key = (raw[1], raw[2])
            if key not in at:
                at[key] = len(tables)
                tables.append([list(raw[1]), list(raw[2])])
            chunks[f"{cx},{cy}"] = [tick, raw[0], at[key]]
        return {"tables": tables, "chunks": chunks}

    @classmethod
    def from_json(cls, d):
        c = cls()
        tables = [(tuple(t[0]), tuple(t[1])) for t in d.get("tables") or [] if isinstance(t, list) and len(t) == 2]
        for k, v in (d.get("chunks") or {}).items():
            try:
                cx, cy = map(int, k.split(","))
                if v[1] is None:
                    c.chunks[(cx, cy)] = [v[0], None]
                else:
                    tn, en = tables[v[2]]
                    c.chunks[(cx, cy)] = [v[0], (v[1], tn, en)]
            except (ValueError, TypeError, IndexError, KeyError):
                continue
        return c


class Chart:
    def __init__(self, root, earlier=(), clock=time.time):
        self.root, self.clock = root, clock
        self.cells = {}          # surface -> {(cellx, celly): Cell}
        self.surfaces = {}       # surface -> {index, platform}
        self.ents, self.tiles = {}, {}
        self.lists = {}          # surface -> {"todo": [(bx, by)], "done": set(), "t": wall time of the last list}
        self.queue = {}          # surface -> [(cx, cy)] chunks to read (charted, not in the store or past refresh)
        self.turn = 0
        self.pass_ = {}          # surface -> its stride pass: dirty reads go to the surfaces in proportion to their chunks
        self.next_read = 0.0
        self.next_surfaces = 0.0
        self.saved = 0.0
        self.version = 0
        self.index = {}          # surface -> {"cx,cy": [version, oldest tick, newest tick, chunks]}
        self.tick = None
        self.error = None
        self.reads = 0
        self._load(root, earlier)

    # ------------------------------------------------------------------ keeping
    def _load(self, root, earlier):
        for d in [root] + list(earlier or ()):
            sd = os.path.join(d, "store") if d else None
            if not sd or not os.path.isdir(sd):
                continue
            for surface in sorted(os.listdir(sd)):
                if surface in self.cells or not os.path.isdir(os.path.join(sd, surface)):
                    continue
                cells = {}
                for fn in os.listdir(os.path.join(sd, surface)):
                    m = re.fullmatch(r"(-?\d+)_(-?\d+)\.json", fn)
                    if not m:
                        continue
                    try:
                        with open(os.path.join(sd, surface, fn)) as fh:
                            c = Cell.from_json(json.load(fh))
                    except (OSError, ValueError):
                        continue
                    c.draw = d != root or not os.path.exists(os.path.join(root, "out", surface, fn[:-5] + ".png"))
                    c.dirty = d != root
                    cells[(int(m.group(1)), int(m.group(2)))] = c
                if cells:
                    self.cells[surface] = cells
        try:
            with open(os.path.join(root, "out", "index.json")) as fh:
                idx = json.load(fh)
            self.version = int(idx.get("v") or 0)
            self.index = {s: dict(v.get("cells") or {}) for s, v in (idx.get("surfaces") or {}).items() if s in self.cells}
        except (OSError, ValueError, TypeError, AttributeError):
            pass

    def save(self, force=False):
        now = self.clock()
        if not force and now - self.saved < SAVE_EVERY:
            return
        self.saved = now
        for surface, cells in self.cells.items():
            for (x, y), c in cells.items():
                if not c.dirty:
                    continue
                d = os.path.join(self.root, "store", _SAFE.sub("_", surface))
                try:
                    os.makedirs(d, exist_ok=True)
                    tmp = os.path.join(d, f"{x}_{y}.json.tmp")
                    with open(tmp, "w") as fh:
                        json.dump(c.to_json(), fh, separators=(",", ":"))
                    os.replace(tmp, os.path.join(d, f"{x}_{y}.json"))
                    c.dirty = False
                except OSError as e:
                    self.error = f"save: {e}"[:160]

    # ------------------------------------------------------------------ taking reads
    def take_protos(self, res):
        self.ents, self.tiles = parse_protos(res.get("protos"))

    def take_surfaces(self, res):
        rows = res.get("surfaces") if isinstance(res.get("surfaces"), list) else []
        self.surfaces = {r["name"]: {"index": r.get("index"), "platform": r.get("platform")} for r in rows
                         if isinstance(r, dict) and isinstance(r.get("name"), str)}
        for s in self.surfaces:
            if s not in self.lists:
                self.lists[s] = {"todo": [(0, 0)], "done": set(), "t": None}

    def take_list(self, surface, res):
        box = res.get("box") or []
        rows = res.get("rows") or []
        if len(box) != 4 or not isinstance(rows, list):
            return
        cx0, cy0, cx1, cy1 = box
        known = self.known(surface)
        q = self.queue.setdefault(surface, [])
        queued = set(q)
        edge = {"n": False, "s": False, "w": False, "e": False}
        for j, row in enumerate(rows):
            for i, ch in enumerate(str(row)):
                if ch != "1":
                    continue
                c = (cx0 + i, cy0 + j)
                if c not in known and c not in queued:
                    q.append(c)
                    queued.add(c)
                edge["n"] |= j == 0
                edge["s"] |= j == len(rows) - 1
                edge["w"] |= i == 0
                edge["e"] |= i == cx1 - cx0
        L = self.lists[surface]
        bx, by = (cx0 + BLOCK // 2) // BLOCK, (cy0 + BLOCK // 2) // BLOCK
        L["done"].add((bx, by))
        for side, (dx, dy) in (("n", (0, -1)), ("s", (0, 1)), ("w", (-1, 0)), ("e", (1, 0))):
            nb = (bx + dx, by + dy)
            if edge[side] and nb not in L["done"] and nb not in L["todo"]:
                L["todo"].append(nb)
        # nearest the origin first (the base), then outwards
        q.sort(key=lambda c: max(abs(c[0]), abs(c[1])))

    def known(self, surface):
        out = {}
        for cell in (self.cells.get(surface) or {}).values():
            for c, (tick, rec) in cell.chunks.items():
                if rec is not None:
                    out[c] = tick
        return out

    def take_rows(self, surface, res):
        """A chunks or dirty read: each chunk into its cell; its cell, and the neighbour across an edge it is on, to
        draw again."""
        tick = res.get("tick")
        if isinstance(tick, int):
            self.tick = tick
        cells = self.cells.setdefault(surface, {})
        n = 0
        rows = split_rows(res)
        for cx, cy, rec in rows:
            k = _cell_of(cx, cy)
            cell = cells.get(k)
            if cell is None:
                cell = cells[k] = Cell()
            if rec is None:
                if (cx, cy) not in cell.chunks:
                    continue
                cell.chunks.pop((cx, cy), None)
            else:
                cell.chunks[(cx, cy)] = [tick, rec]
            cell.dirty = cell.draw = True
            n += 1
            lx, ly = cx - k[0] * CPC, cy - k[1] * CPC
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if (dx or dy) and (dx == 0 or lx == (0 if dx < 0 else CPC - 1)) and (dy == 0 or ly == (0 if dy < 0 else CPC - 1)):
                        nb = cells.get((k[0] + dx, k[1] + dy))
                        if nb is not None:
                            nb.draw = True
        q = self.queue.get(surface)
        if q:
            done = {(cx, cy) for cx, cy, _ in rows}
            self.queue[surface] = [c for c in q if c not in done]
        return n

    # ------------------------------------------------------------------ what to read
    def due(self):
        return self.clock() >= self.next_read

    def next_call(self):
        """(args, what) for the next read, or None: protos once, the surfaces listing, a list block, chunks to read
        (first pass and refresh), else a surface's dirty chunks in turn."""
        now = self.clock()
        if not self.ents:
            return {"protos": True}, ("protos", None)
        if not self.surfaces or now >= self.next_surfaces:
            return {"surfaces": True}, ("surfaces", None)
        names = sorted(self.surfaces)
        for s in names:
            L = self.lists.get(s)
            if L and L["t"] is not None and now - L["t"] >= LIST_EVERY and not L["todo"]:
                L["todo"] = sorted(L["done"]) or [(0, 0)]
                L["done"] = set()
            if L and L["todo"]:
                bx, by = L["todo"][0]
                x0, y0 = bx * BLOCK - BLOCK // 2, by * BLOCK - BLOCK // 2
                return {"surface": s, "list": [x0, y0, x0 + BLOCK - 1, y0 + BLOCK - 1]}, ("list", s)
        # two turns in three: chunks to read (first pass, refresh), the surfaces in turn; the third: a surface's dirty chunks
        queued = [names[(self.turn + i) % len(names)] for i in range(len(names))]
        for s in queued:
            self._refresh(s)
        queued = [s for s in queued if self.queue.get(s)]
        known = [s for s in names if self.known(s)]
        if queued and (self.turn % 3 or not known):
            s = queued[0]
            return {"surface": s, "chunks": [v for c in self.queue[s][:CHUNKS_READ] for v in c]}, ("chunks", s)
        if known:
            s = min(known, key=lambda n: (self.pass_.get(n, 0.0), n))
            return {"surface": s, "dirty": DIRTY, "check": CHECK, "min_age": MIN_AGE}, ("dirty", s)
        return None

    def _refresh(self, surface):
        """Chunks read REFRESH_TICKS ago or more go to the queue's end (once)."""
        if self.tick is None:
            return
        q = self.queue.setdefault(surface, [])
        if len(q) >= CHUNKS_READ:
            return
        queued = set(q)
        old = sorted((t, c) for c, t in self.known(surface).items() if isinstance(t, int) and self.tick - t >= REFRESH_TICKS and c not in queued)
        q.extend(c for _, c in old[:CHUNKS_READ])

    def step(self, call):
        """One read through call(args) -> the operator read's result, then the cells it changed drawn (at most
        BUILD_MAX); True when a read ran."""
        now = self.clock()
        self.next_read = now + (FIRST_EVERY if any(self.queue.values()) else EVERY)
        nxt = self.next_call()
        if not nxt:
            self.build()
            return False
        args, (what, surface) = nxt
        self.turn += 1
        try:
            res = call(args)
        except Exception as e:  # noqa: BLE001 - a failed read waits for the next
            self.error = f"{what}: {type(e).__name__}: {e}"[:200]
            self.next_read = now + 4 * EVERY
            if what == "list" and surface in self.lists and self.lists[surface]["todo"]:
                self.lists[surface]["done"].add(self.lists[surface]["todo"].pop(0))
            return False
        self.error = None
        self.reads += 1
        if not isinstance(res, dict):
            return True
        if what == "protos":
            self.take_protos(res)
        elif what == "surfaces":
            self.take_surfaces(res)
            self.next_surfaces = now + SURFACES_EVERY
        elif what == "list":
            L = self.lists[surface]
            L["todo"].pop(0)
            self.take_list(surface, res)
            if not L["todo"]:
                L["t"] = now
        else:
            if what == "dirty":
                # stride scheduling: a surface with n chunks comes round n times as often as one with 1 (its check
                # cycle about the same length on every surface)
                lo = min(self.pass_.values(), default=0.0)
                self.pass_[surface] = max(self.pass_.get(surface, lo), lo) + 1.0 / max(1, len(self.known(surface)))
            self.take_rows(surface, res)
        self.build()
        self.save()
        return True

    # ------------------------------------------------------------------ drawing
    def _entities_near(self, surface, k):
        """The entities of a cell's chunks and of the chunks round it (footprints across its edge)."""
        cells = self.cells.get(surface) or {}
        out = []
        cx0, cy0 = k[0] * CPC - 1, k[1] * CPC - 1
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                cell = cells.get((k[0] + dx, k[1] + dy))
                if not cell:
                    continue
                for (cx, cy), (_, raw) in cell.chunks.items():
                    if raw is not None and cx0 <= cx <= cx0 + CPC + 1 and cy0 <= cy <= cy0 + CPC + 1:
                        out.extend(parse_chunk(raw)["ents"])
        return out

    def draw(self, surface, k):
        """A cell's PNG (bytes) and labels {recipes, stops}: tiles, then resources and nature, then buildings."""
        from PIL import Image  # noqa: PLC0415 - only the stream service draws
        cell = self.cells[surface][k]
        buf = bytearray(CELL * CELL * 4)
        X0, Y0 = k[0] * CELL, k[1] * CELL
        recipes, stops = [], []
        for (cx, cy), (_, raw) in cell.chunks.items():
            if raw is None:
                continue
            rec = parse_chunk(raw)
            ox, oy = cx * CHUNK - X0, cy * CHUNK - Y0
            for j, row in enumerate(rec["tiles"][:CHUNK]):
                x = ox
                at = ((oy + j) * CELL) * 4
                for name, n in row:
                    c = self.tiles.get(name)
                    if c and n > 0:
                        buf[at + x * 4: at + (x + n) * 4] = c * n
                    x += n
            recipes += [[x2 / 2, y2 / 2, name] for x2, y2, name in rec["recipes"]]
            stops += [[x2 / 2, y2 / 2, name] for x2, y2, name in rec["stops"]]
        ents = sorted(self._entities_near(surface, k), key=lambda e: LAYER.get((self.ents.get(e[0]) or {}).get("type"), 2))
        for name, x2, y2, d, force in ents:
            p = self.ents.get(name)
            if not p or p["type"] == "fish":
                continue
            c = p["f"] if force == 1 else p["e"] if force == 2 else (p["m"] or p["f"])
            pts = rail_points(p["type"], d, x2 / 2, y2 / 2)
            if pts:
                c = p["m"] or c
                # a track is 2 tiles wide: the tiles half a tile either side of the line, across its heading
                done = set()
                for i in range(len(pts) - 1):
                    (ax, ay), (bx, by) = pts[i], pts[i + 1]
                    L = math.hypot(bx - ax, by - ay) or 1
                    qx, qy, nx, ny = (ax + bx) / 2, (ay + by) / 2, -(by - ay) / L * 0.5, (bx - ax) / L * 0.5
                    for X, Y in ((math.floor(qx + nx) - X0, math.floor(qy + ny) - Y0), (math.floor(qx - nx) - X0, math.floor(qy - ny) - Y0)):
                        if (X, Y) not in done and 0 <= X < CELL and 0 <= Y < CELL:
                            done.add((X, Y))
                            buf[(Y * CELL + X) * 4:(Y * CELL + X) * 4 + 4] = c
                continue
            if not c:
                continue
            w, h = (p["h"], p["w"]) if d in (4, 12) else (p["w"], p["h"])
            left = math.floor(x2 / 2 - w / 2 + 0.5) - X0
            top = math.floor(y2 / 2 - h / 2 + 0.5) - Y0
            l0, l1 = max(0, left), min(CELL, left + w)
            if l1 <= l0:
                continue
            for yy in range(max(0, top), min(CELL, top + h)):
                at = yy * CELL * 4
                buf[at + l0 * 4: at + l1 * 4] = c * (l1 - l0)
        img = Image.frombytes("RGBA", (CELL, CELL), bytes(buf))
        import io  # noqa: PLC0415
        out = io.BytesIO()
        img.save(out, format="PNG", optimize=True)
        return out.getvalue(), {"recipes": recipes, "stops": stops}

    def build(self, limit=BUILD_MAX):
        """Draws up to limit cells marked to draw, writes them and the index; returns how many."""
        if not self.tiles:
            return 0
        n = 0
        for surface in sorted(self.cells):
            for k in sorted(self.cells[surface]):
                cell = self.cells[surface][k]
                if not cell.draw or n >= limit:
                    continue
                cell.draw = False
                key = f"{k[0]},{k[1]}"
                ticks = [t for t, rec in cell.chunks.values() if rec is not None and isinstance(t, int)]
                if not ticks:
                    self.index.get(surface, {}).pop(key, None)
                    continue
                try:
                    png, labels = self.draw(surface, k)
                    d = os.path.join(self.root, "out", _SAFE.sub("_", surface))
                    os.makedirs(d, exist_ok=True)
                    for name, data in ((f"{k[0]}_{k[1]}.png", png),
                                       (f"{k[0]}_{k[1]}.labels.json", json.dumps(labels, separators=(",", ":")).encode())):
                        with open(os.path.join(d, name + ".tmp"), "wb") as fh:
                            fh.write(data)
                        os.replace(os.path.join(d, name + ".tmp"), os.path.join(d, name))
                except (OSError, ValueError, ImportError) as e:
                    self.error = f"draw: {type(e).__name__}: {e}"[:200]
                    continue
                self.version += 1
                ours = [(x2 / 2, y2 / 2) for t, raw in cell.chunks.values() if raw is not None for _, x2, y2, _, f in parse_chunk(raw)["ents"] if f == 1]
                box = [math.floor(min(x for x, _ in ours)), math.floor(min(y for _, y in ours)), math.ceil(max(x for x, _ in ours)),
                       math.ceil(max(y for _, y in ours))] if ours else []
                self.index.setdefault(surface, {})[key] = [self.version, min(ticks), max(ticks), len(ticks)] + box
                n += 1
        if n:
            self.write_index()
        return n

    def write_index(self):
        out = {"v": self.version, "cell": CELL, "tick": self.tick, "surfaces": {}}
        for s, cells in sorted(self.index.items()):
            if cells:
                meta = self.surfaces.get(s) or {}
                out["surfaces"][s] = {"platform": meta.get("platform"), "cells": cells}
        try:
            os.makedirs(os.path.join(self.root, "out"), exist_ok=True)
            p = os.path.join(self.root, "out", "index.json")
            with open(p + ".tmp", "w") as fh:
                json.dump(out, fh, separators=(",", ":"))
            os.replace(p + ".tmp", p)
        except OSError as e:
            self.error = f"index: {e}"[:160]
        return out

    def status(self):
        """For the state: {v, reads, chunks per surface, queued, error}."""
        return {"v": self.version, "reads": self.reads, "tick": self.tick, "error": self.error,
                "surfaces": {s: {"chunks": len(self.known(s)), "queued": len(self.queue.get(s) or [])} for s in sorted(self.cells)}}
