#!/usr/bin/env python3
"""The charted ground read for the site's map (d22 batch75 AK9, viewer Aurora site:4272): python3 tools/stream/test_terrain_grid.py

terrain_grid.py's Lua read runs under lua against a stub world (charted chunks, tiles by position, cliffs, map colours
as the game gives them, 0..1), with table_to_json writing an empty table as {} as Factorio does:
- from nothing, reads find the charted area from the origin and the agents' chunks outward, each read checking at most
  CHECK_MAX (+ REFRESH_MAX) chunks and sampling at most SAMPLE_MAX; charted ones past the cap are sampled first next read;
- ground charted later next to the known ground is found and sampled within RECHECK_S plus two reads;
- a chunk read REFRESH_S ago is read again; a failed read waits 4 reads;
- the grid: 8-tile cells, one letter a tile's map colour (#rrggbb from the game's 0..1 colour), "c" where a cliff
  stands, "." where nothing is read; x0, y0 at chunk edges; at most MAX_SIDE chunks round the origin;
- kept in the run's file and read back from a run it resumed from;
- live.py sends it after each read (and once at the start from the kept grid); the model's state carries it with its age.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
import terrain_grid as T  # noqa: E402
import harness  # noqa: E402

PRELUDE = r"""
local charted = {}
for k in (CHARTED):gmatch('[^;]+') do charted[k] = true end
local function tile(x, y) if y < -64 then return 'water' elseif x < 0 then return 'grass-1' else return 'sand-1' end end
game = {tick = 777, surfaces = {nauvis = {
  get_tile = function(x, y) return {name = tile(x, y)} end,
  find_entities_filtered = function(f) local a = f.area; if a[1][1] == 0 and a[1][2] == 0 then return {{position = {x = 13.5, y = 2.5}}} end return {} end}},
  forces = {player = {is_chunk_charted = function(s, c) return charted[c[1] .. ',' .. c[2]] == true end}}}
prototypes = {tile = {water = {map_color = {r = 0.2, g = 0.32, b = 0.37}}, ['grass-1'] = {map_color = {r = 0.215, g = 0.208, b = 0.043}}, ['sand-1'] = {map_color = {r = 0.54, g = 0.40, b = 0.23}}}}
local function enc(v)
  local t = type(v)
  if t == 'number' then return tostring(v) elseif t == 'string' then return '"' .. v .. '"' elseif t == 'boolean' then return tostring(v) end
  if #v > 0 then local o = {} for i = 1, #v do o[i] = enc(v[i]) end return '[' .. table.concat(o, ',') .. ']' end
  local o = {} for k, x in pairs(v) do o[#o + 1] = '"' .. tostring(k) .. '":' .. enc(x) end return '{' .. table.concat(o, ',') .. '}'
end
helpers = {table_to_json = enc}
rcon = {print = function(s) io.write(s) end}
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


class World:
    """The charted chunks, and the reads made against them."""
    def __init__(self, charted):
        self.charted = set(charted)
        self.calls = []

    def lua(self, code):
        one = harness.one_line(code)
        check("one line, no comments", "\n" not in one and "--" not in one)
        prelude = PRELUDE.replace("CHARTED", '"' + ";".join(f"{x},{y}" for x, y in sorted(self.charted)) + '"')
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(prelude + "\n" + one)
        try:
            r = subprocess.run(["lua", f.name], capture_output=True, text=True, timeout=30)
        finally:
            os.unlink(f.name)
        check("lua", r.returncode == 0, r.stderr[-1500:])
        out = json.loads(r.stdout)
        self.calls.append(out)
        return out


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def main():
    if not shutil.which("lua"):
        print("terrain grid: skipped (no lua)")
        return
    rect = {(x, y) for x in range(-6, 6) for y in range(-6, 6)}           # 144 charted chunks round the origin
    island = {(20, 20), (20, 21)}                                         # charted far off, under an agent
    w = World(rect | island)
    clock = Clock()
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "terrain-grid.json")
        g = T.TerrainGrid(path, clock=clock)
        seeds = T.seeds_from([{"position": {"x": 650.0, "y": 660.0}, "surface": "nauvis"}, {"position": {"x": 5, "y": 5}, "surface": "gleba"}])
        check("seeds: Nauvis agents only", seeds == [(20, 20)], seeds)
        T_SAMPLE, T_CHECK = T.SAMPLE_MAX, T.CHECK_MAX
        T.SAMPLE_MAX, T.CHECK_MAX = 20, 60  # small caps, so the cap and the pending list show
        try:
            reads = 0
            while reads < 40:
                clock.t += T.EVERY
                g.read(w.lua, seeds)
                reads += 1
                if set(map(lambda k: tuple(map(int, k.split(","))), g.chunks)) == rect | island and not g.pending:
                    break
            for c in w.calls:
                check("a read samples at most SAMPLE_MAX", len(c["sampled"] if isinstance(c["sampled"], list) else []) <= 20, len(c["sampled"]))
            check("all the charted ground read", len(g.chunks) == len(rect | island), (len(g.chunks), reads))
            check("in a bounded number of reads", reads <= 12, reads)
            check("empty tables ({}) taken", any(isinstance(c.get("more"), dict) for c in w.calls))
            # ground charted later, north of the known ground: found within RECHECK_S plus two reads
            new = {(x, -7) for x in range(-6, 6)} | {(x, -8) for x in range(-3, 0)}
            w.charted |= new
            found_after = None
            for i in range(1, 12):
                clock.t += T.EVERY
                g.read(w.lua, seeds)
                if all(T._key(*c) in g.chunks for c in new):
                    found_after = i * T.EVERY
                    break
            check("newly charted ground read", found_after is not None and found_after <= T.RECHECK_S + 2 * T.EVERY, found_after)
        finally:
            T.SAMPLE_MAX, T.CHECK_MAX = T_SAMPLE, T_CHECK
        # the grid
        gr = g.grid()
        check("cell and edges", gr["cell"] == 8 and gr["x0"] == -6 * 32 and gr["y0"] == -8 * 32, (gr["cell"], gr["x0"], gr["y0"]))
        pal = {p[2]: (p[0], p[1]) for p in gr["palette"]}
        check("map colours from 0..1", pal["water"][1] == "#33525e" and pal["grass-1"][1] == "#37350b" and pal["cliffs"][0] == "c", pal)
        row = lambda ty: gr["rows"][(ty - gr["y0"]) // 8]  # noqa: E731
        col = lambda tx: (tx - gr["x0"]) // 8  # noqa: E731
        check("tiles: grass west, sand east", row(4)[col(-4)] == pal["grass-1"][0] and row(20)[col(20)] == pal["sand-1"][0], row(4))
        check("water north", row(-244)[col(-40)] == pal["water"][0] and row(-200)[col(100)] == pal["water"][0], row(-244))
        check("a cliff in its cell", row(2)[col(13)] == "c", row(2)[col(0):col(32)])
        check("not read: .", row(-252)[col(-190)] == ".", row(-252)[:8])
        check("ticks and chunks (the island too)", gr["tick"] == 777 and gr["chunks"] == len(g.chunks) and isinstance(gr["t"], float), (gr["tick"], gr["chunks"]))
        # a refresh: a chunk read REFRESH_S ago is read again
        k0 = T._key(0, 0)
        g.chunks[k0][2] = clock.t - T.REFRESH_S - 1
        clock.t += T.EVERY
        want = g.wanted(seeds)
        check("an old chunk read again", (0, 0) in want, want[-10:])
        # a failed read waits four reads
        def boom(_):
            raise RuntimeError("rcon down")
        g.next_read = 0
        g.read(boom, seeds)
        check("a failed read: said, and waits", "rcon down" in g.error and g.next_read == clock.t + 4 * T.EVERY, (g.error, g.next_read - clock.t))
        # kept, and read back from the run this one resumed from
        g.save(force=True)
        g2 = T.TerrainGrid(os.path.join(d, "later", "terrain-grid.json"), earlier=[path], clock=clock)
        check("read back from the earlier run", len(g2.chunks) == len(g.chunks) and g2.grid()["rows"] == gr["rows"], len(g2.chunks))
        # MAX_SIDE: chunks beyond it are left out of what is sent
        g2.chunks[T._key(500, 500)] = [["water"] * 16, 1, clock.t]
        check("at most MAX_SIDE round the origin", g2.grid()["w"] == gr["w"], g2.grid()["w"])

        # live.py: sent once at the start from the kept grid, and after each read
        import live
        src = live.LiveSource.__new__(live.LiveSource)
        src.terrain, src.terrain_sent = T.TerrainGrid(path, clock=clock), False
        src.h = type("H", (), {"lua": staticmethod(w.lua)})()
        src.terrain.next_read = clock.t + 999
        obs, errors = {"agents": []}, {}
        src.observe_terrain(obs, errors)
        check("live: the kept grid at the start", obs.get("terrain_grid", {}).get("chunks") == gr["chunks"] and not errors, errors)
        obs = {"agents": []}
        src.observe_terrain(obs, errors)
        check("live: nothing between reads", "terrain_grid" not in obs)
        src.terrain.next_read = 0
        src.observe_terrain(obs, errors)
        check("live: after a read", "terrain_grid" in obs)
        # the model's state carries it with its age
        from model import Model
        m = Model({"agents": {}})
        import time as _t
        now = _t.time()
        m.ingest(dict(obs, tick=1000), now)
        st = m.snapshot(now + 5)
        tg = (st or {}).get("terrain_grid")
        check("model: in the state with its age", isinstance(tg, dict) and isinstance(tg.get("age_s"), int), tg and sorted(tg))
    print("terrain grid: ok (the charted ground read outward from the origin and the agents, within each read's caps; "
          "newly charted ground found within RECHECK_S plus two reads; old chunks read again; a failed read waits; kept in "
          "the run and read back; the grid's letters, colours and cliffs; live.py and the model pass it on)")


if __name__ == "__main__":
    main()
