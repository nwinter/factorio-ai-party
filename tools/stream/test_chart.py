#!/usr/bin/env python3
"""The site's chart in the stream service (d22 batch97 BG3, tools/stream/chart.py) against a fake `chart` operator read
that answers as chart.lua does: python3 tools/stream/test_chart.py

- the reads in order: protos once, surfaces, list blocks from the origin outwards while charted chunks reach an edge,
  the charted chunks not in the store (nearest the origin first, 8 a read), then dirty reads in turn per surface;
- a cell drawn at 1 px a tile: tiles in their map colours, resources over them, buildings over both at their footprint
  (east and west turn it), a footprint across a cell edge drawn in both cells, a chunk not charted transparent;
- labels (recipes, stops) in tiles; the index with each cell's version and oldest and newest read ticks;
- a changed chunk on a cell's edge draws the neighbour again; one inside does not;
- the store saved and read back from a run this one resumed from (its cells drawn again there).
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import chart  # noqa: E402

try:
    from PIL import Image
except ImportError:  # the stream service draws with PIL; without it there is nothing to check
    print("chart: skipped (no PIL)")
    sys.exit(0)

PROTOS = "\n".join([
    "E stone-furnace furnace 2 2 006091 ff0000 -",
    "E iron-ore resource 1 1 006091 ff0000 69879e",
    "E boiler boiler 3 2 006091 ff0000 -",
    "E big-thing assembling-machine 4 4 006091 ff0000 -",
    "E straight-rail straight-rail 2 2 006091 ff0000 8c8c8c",
    "E curved-rail-a curved-rail-a 2 2 006091 ff0000 8c8c8c",
    "T grass-1 37350b", "T water 33535f"])


class FakeGame:
    """Chunks (cx, cy) -> {tiles: name or callable(x, y), ents: [(name, x, y, dir, force)], recipes, stops}; charted set."""

    def __init__(self):
        self.tick = 1000
        self.chunks = {}
        self.dirty = []
        self.calls = []

    def add(self, cx, cy, tile="grass-1", ents=(), recipes=(), stops=()):
        self.chunks[(cx, cy)] = {"tile": tile, "ents": list(ents), "recipes": list(recipes), "stops": list(stops)}

    def rows(self, list_):
        tn, en, out = [], [], []

        def idx(names, n):
            if n not in names:
                names.append(n)
            return names.index(n) + 1
        for cx, cy in list_:
            c = self.chunks.get((cx, cy))
            if c is None:
                out.append(f"U {cx} {cy}")
                continue
            out.append(f"C {cx} {cy}")
            rows = []
            for y in range(32):
                runs, last, n = [], None, 0
                for x in range(32):
                    t = c["tile"](cx * 32 + x, cy * 32 + y) if callable(c["tile"]) else c["tile"]
                    v = idx(tn, t)
                    if v == last:
                        n += 1
                    else:
                        if last:
                            runs.append(f"{last},{n}")
                        last, n = v, 1
                runs.append(f"{last},{n}")
                rows.append(" ".join(runs))
            out.append("T " + "|".join(rows))
            for name, x, y, d, f in c["ents"]:
                out.append(f"E {idx(en, name)} {round(x * 2)} {round(y * 2)} {d} {f}")
            for x, y, r in c["recipes"]:
                out.append(f"R {round(x * 2)} {round(y * 2)} {r}")
            for x, y, s in c["stops"]:
                out.append(f"S {round(x * 2)} {round(y * 2)} {s}")
        return {"tick": self.tick, "tn": " ".join(tn), "en": " ".join(en), "rows": "\n".join(out), "chunks": len(list_), "rest": 0}

    def __call__(self, args):
        self.calls.append(args)
        if args.get("protos"):
            return {"protos": PROTOS}
        if args.get("surfaces"):
            return {"surfaces": [{"name": "nauvis", "index": 1}, {"name": "platform-3", "index": 5, "platform": "Asterion"}]}
        s = args["surface"]
        if args.get("list"):
            cx0, cy0, cx1, cy1 = args["list"]
            have = self.chunks if s == "nauvis" else {}
            rows = ["".join("1" if (cx, cy) in have else "0" for cx in range(cx0, cx1 + 1)) for cy in range(cy0, cy1 + 1)]
            return {"box": [cx0, cy0, cx1, cy1], "rows": rows}
        if args.get("chunks"):
            c = args["chunks"]
            return self.rows([(c[i], c[i + 1]) for i in range(0, len(c), 2)])
        if args.get("dirty"):
            want = self.dirty[:args["dirty"]] if s == "nauvis" else []
            self.dirty = self.dirty[len(want):]
            return dict(self.rows(want), waiting=0, checked=0, marked=0)
        raise AssertionError(args)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + str(detail)[:2000]))
    if not ok:
        sys.exit(1)


def px(img, x, y):
    return img.getpixel((x, y))


def main():
    g = FakeGame()
    # the base round the origin: chunk (0,0) half water, a furnace (recipe), an ore tile, a boiler turned east;
    # chunk (11,0) on cell (0,0)'s east edge with a big thing across it into cell (1,0); chunk (12,0) in cell (1,0);
    # chunk (31,0): on list block (0,0)'s east edge (chunks -32 to 31), so block (1,0) is listed too, with chunk (32,0)
    g.add(0, 0, tile=lambda x, y: "water" if x < 8 else "grass-1",
          ents=[("iron-ore", 12.5, 3.5, 0, 0), ("stone-furnace", 12, 3, 0, 1), ("boiler", 20, 10.5, 4, 1),
                ("straight-rail", 25, 25, 0, 1), ("curved-rail-a", 29, 25, 0, 1)],
          recipes=[(12, 3, "iron-plate")], stops=[(16, 16, "Ore north")])
    g.add(11, 0, ents=[("big-thing", 383, 10, 0, 1)])
    g.add(12, 0)
    g.add(31, 0)
    g.add(32, 0)
    clock = [0.0]
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "run2", "chart")
        c = chart.Chart(root, clock=lambda: clock[0])
        whats = []
        for _ in range(12):
            nxt = c.next_call()
            whats.append(nxt and nxt[1][0])
            c.step(g)
            clock[0] += chart.EVERY
        check("protos once, then surfaces, then the list blocks", whats[:2] == ["protos", "surfaces"] and whats[2:5] == ["list", "list", "list"],
              whats)
        lists = [a["list"] for a in g.calls if a.get("list")]
        check("block (0,0) first; its east edge has a charted chunk, so block (1,0) next; the platform's block (0,0)",
              lists == [[-32, -32, 31, 31], [32, -32, 95, 31], [-32, -32, 31, 31]], lists)
        first = next(a for a in g.calls if a.get("chunks"))
        check("the charted chunks read nearest the origin first", first["chunks"][:4] == [0, 0, 11, 0], first)
        check("every charted chunk read once", c.known("nauvis").keys() == {(0, 0), (11, 0), (12, 0), (31, 0), (32, 0)}, c.known("nauvis"))
        check("then dirty reads, a surface in turn", any(a.get("dirty") for a in g.calls[-4:]), g.calls[-4:])
        out = os.path.join(root, "out")
        idx = json.load(open(os.path.join(out, "index.json")))
        cells = idx["surfaces"]["nauvis"]["cells"]
        check("the index lists the cells with chunks: (0,0), (1,0), (2,0)", set(cells) == {"0,0", "1,0", "2,0"}, cells)
        check("each with its version, its chunks' oldest and newest read tick and count, and the box round our buildings",
              cells["0,0"][1:] == [1000, 1000, 2, 12, 3, 383, 25], cells["0,0"])
        # (cp7) push_live leaves out a surface's coarse grids only once its published chart is complete
        check("the index: chunks stored and charted, and the first pass complete once every charted chunk is read and drawn",
              idx["surfaces"]["nauvis"]["chunks"] == [5, 5] and idx["surfaces"]["nauvis"]["complete"] is True, idx["surfaces"]["nauvis"])
        c.queue["nauvis"].append((40, 40))
        check("a charted chunk waiting for its first read: not complete", c.first_pass("nauvis") == (5, 6, False), c.first_pass("nauvis"))
        c.queue["nauvis"].remove((40, 40))
        c.lists["nauvis"]["todo"].append((1, 1))
        check("a list block still to read: not complete", c.first_pass("nauvis")[2] is False)
        c.lists["nauvis"]["todo"].pop()
        c.save(force=True)
        again = chart.Chart(root, clock=lambda: clock[0])
        check("complete kept from the index at a restart, before this run's lists", "nauvis" in again.complete
              and again.write_index()["surfaces"]["nauvis"]["complete"] is True, again.complete)
        img = Image.open(os.path.join(out, "nauvis", "0_0.png")).convert("RGBA")
        check("a cell is 384 x 384 px", img.size == (384, 384), img.size)
        check("water in its map colour", px(img, 2, 2) == (0x33, 0x53, 0x5f, 255), px(img, 2, 2))
        check("grass in its map colour", px(img, 30, 30) == (0x37, 0x35, 0x0b, 255), px(img, 30, 30))
        check("the furnace over the ore at its 2 x 2 footprint, in the friendly colour", px(img, 11, 2) == (0, 0x60, 0x91, 255)
              and px(img, 12, 3) == (0, 0x60, 0x91, 255) and px(img, 13, 3) == (0x37, 0x35, 0x0b, 255), [px(img, x, 3) for x in range(10, 15)])
        check("the boiler (3 x 2) turned east is 2 wide, 3 tall", px(img, 19, 9) == (0, 0x60, 0x91, 255) and px(img, 20, 11) == (0, 0x60, 0x91, 255)
              and px(img, 21, 10) != (0, 0x60, 0x91, 255) and px(img, 19, 8) != (0, 0x60, 0x91, 255),
              [[px(img, x, y)[:3] for x in range(18, 23)] for y in range(7, 13)])
        rail = (0x8c, 0x8c, 0x8c, 255)
        check("a straight rail: 2 px wide, 2 long, in the rail's map colour", [px(img, x, y) == rail for x in (24, 25) for y in (24, 25)] == [True] * 4
              and px(img, 23, 24) != rail and px(img, 26, 24) != rail and px(img, 24, 23) != rail and px(img, 24, 26) != rail,
              [[px(img, x, y)[:3] for x in range(22, 28)] for y in range(22, 28)])
        cur = [(x, y) for x in range(24, 34) for y in range(18, 30) if px(img, x, y) == rail and x >= 27]
        check("a curved rail: from (29,27) south end bending to (28,22) north-north-west, as a curve (not its 2 x 2 box)",
              (28, 26) in cur and (29, 26) in cur and any(y <= 23 for _, y in cur) and len(cur) > 8, sorted(cur))
        check("a chunk not read is transparent", px(img, 100, 100)[3] == 0, px(img, 100, 100))
        img1 = Image.open(os.path.join(out, "nauvis", "1_0.png")).convert("RGBA")
        check("a footprint across the edge: drawn in both cells", px(img, 382, 10) == (0, 0x60, 0x91, 255) and px(img1, 0, 10) == (0, 0x60, 0x91, 255),
              (px(img, 382, 10), px(img1, 0, 10)))
        lab = json.load(open(os.path.join(out, "nauvis", "0_0.labels.json")))
        check("labels in tiles: recipes and stops", lab == {"recipes": [[12, 3, "iron-plate"]], "stops": [[16, 16, "Ore north"]]}, lab)
        # a change inside a cell draws that cell only; on its edge, the neighbour too
        v0 = dict(cells)
        g.tick = 50000
        g.chunks[(0, 0)]["ents"].append(("stone-furnace", 5, 20, 0, 1))
        g.dirty = [(0, 0)]
        c.take_rows("nauvis", g.rows(g.dirty))
        c.build()
        cells = json.load(open(os.path.join(out, "index.json")))["surfaces"]["nauvis"]["cells"]
        check("a chunk inside: its cell drawn again with the newer tick, the neighbour not",
              cells["0,0"][0] > v0["0,0"][0] and cells["0,0"][2] == 50000 and cells["1,0"] == v0["1,0"], (v0, cells))
        g.chunks[(11, 0)]["ents"] = []
        c.take_rows("nauvis", g.rows([(11, 0)]))
        c.build()
        cells2 = json.load(open(os.path.join(out, "index.json")))["surfaces"]["nauvis"]["cells"]
        check("a chunk on the east edge: the neighbour drawn again too", cells2["1,0"][0] > cells["1,0"][0], (cells, cells2))
        img1 = Image.open(os.path.join(out, "nauvis", "1_0.png")).convert("RGBA")
        check("the thing across the edge is gone from the neighbour (its grass shows)", px(img1, 0, 10) == (0x37, 0x35, 0x0b, 255), px(img1, 0, 10))
        # a chunk no longer charted (U) leaves the store
        del g.chunks[(32, 0)]
        c.take_rows("nauvis", g.rows([(32, 0)]))
        check("a chunk read as not charted leaves the store", (32, 0) not in c.known("nauvis"))
        # saved and read back from the run this one resumed from
        c.save(force=True)
        clock[0] += 1
        c2 = chart.Chart(os.path.join(tmp, "run3", "chart"), earlier=[root], clock=lambda: clock[0])
        check("read back from the earlier run", c2.known("nauvis") == c.known("nauvis"), (c2.known("nauvis"), c.known("nauvis")))
        c2.tiles, c2.ents = c.tiles, c.ents
        n = c2.build(limit=99)
        check("and drawn again into this run's out/ (its index from 1)", n == 3 and os.path.exists(os.path.join(tmp, "run3", "chart", "out", "nauvis", "0_0.png")), n)
        idx3 = json.load(open(os.path.join(tmp, "run3", "chart", "out", "index.json")))
        check("a new run's index: not complete until its own lists are read", idx3["surfaces"]["nauvis"]["complete"] is False
              and idx3["surfaces"]["nauvis"]["chunks"] == [4, 4], idx3["surfaces"]["nauvis"])
        rec = chart.parse_chunk(c2.cells["nauvis"][(0, 0)].chunks[(0, 0)][1])
        check("a chunk's rows survive the round trip", rec["recipes"] == [(24, 6, "iron-plate")] and ("stone-furnace", 10, 40, 0, 1) in rec["ents"]
              and rec["tiles"][0][0] == ("water", 8), rec["tiles"][0])
    # dirty reads go to the surfaces in proportion to their chunks: Nauvis (4 chunks) 4 times as often as a 1-chunk one
    c3 = chart.Chart(os.path.join(tempfile.mkdtemp(), "chart"), clock=lambda: clock[0])
    c3.ents, c3.tiles, c3.surfaces, c3.next_surfaces = {"x": {}}, {}, {"nauvis": {}, "platform-3": {}}, 1e18
    c3.lists = {"nauvis": {"todo": [], "done": set(), "t": 0}, "platform-3": {"todo": [], "done": set(), "t": 0}}
    g4 = FakeGame()
    for i in range(4):
        g4.add(i, 0)
    c3.take_rows("nauvis", g4.rows([(i, 0) for i in range(4)]))
    c3.take_rows("platform-3", dict(g4.rows([(0, 0)])))
    picks = []
    for _ in range(20):
        a, (what, s) = c3.next_call()
        picks.append(s)
        c3.step(lambda args: {"tick": 1, "rows": "", "tn": "", "en": ""})
    check("dirty reads in proportion to chunks (4 to 1)", picks.count("nauvis") == 16 and picks.count("platform-3") == 4, picks)
    # the stream service's turn: live.py observe_chart, one operator read through the harness client when due
    import live  # noqa: PLC0415
    asked = []

    class H:
        def operator_read(self, action, args):
            asked.append((action, args))
            return g(args), 1

    class Src:
        chart, has_chart, h = chart.Chart(os.path.join(tempfile.mkdtemp(), "chart"), clock=lambda: clock[0]), True, H()
    obs, errors = {}, {}
    live.LiveSource.observe_chart(Src, obs, errors)
    check("live.py: one `chart` operator read when due, its status in the observation", asked == [("chart", {"protos": True})]
          and obs["chart"]["reads"] == 1 and not errors, (asked, obs, errors))
    obs = {}
    live.LiveSource.observe_chart(Src, obs, errors)
    check("live.py: none before chart.EVERY", len(asked) == 1 and "chart" not in obs, asked)
    Src.has_chart = False
    clock[0] += 100
    live.LiveSource.observe_chart(Src, obs, errors)
    check("live.py: a runtime without the read (describe) is not asked", len(asked) == 1, asked)
    check("the service log: a chart line at the first read", Src.chart.logged is not None)
    line = Src.chart.log_line()
    check("the log line: none again before LOG_EVERY", line is None, line)
    clock[0] += chart.LOG_EVERY
    line = Src.chart.log_line()
    check("the log line: again after LOG_EVERY, with the reads and chunks", line and line.startswith("[chart] ")
          and "1 reads" in line and "chunks stored 0, queued 0" in line, line)
    Src.chart.error = "chunks: TimeoutError: x"
    line = Src.chart.log_line()
    check("the log line: a new read error at once", line and line.endswith("read failed: chunks: TimeoutError: x"), line)
    check("the log line: the same error not again", Src.chart.log_line() is None)
    Src.chart.error = None
    print("chart: ok (reads in order, cells drawn in map colours with footprints across edges, labels, index, store kept)")


if __name__ == "__main__":
    main()
