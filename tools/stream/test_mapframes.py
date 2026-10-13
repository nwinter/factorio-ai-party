"""mapframes.py: a base-map frame placed by registering it on the basemap, its charted part cut out, kept per area.
Run: python3 tools/stream/test_mapframes.py (system python3: numpy, Pillow)."""
import io, json, os, sys, tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import mapframes as M  # noqa: E402

W, H, ZOOM = 2880, 1620, 0.03
PPT = M.px_per_tile(ZOOM, H)


def basemap():
    """A base of 8-tile cells: a block of factory, a pipeline going north-west and an outpost at its end."""
    rows = [["."] * 60 for _ in range(60)]
    for j in range(30, 42):
        for i in range(30, 44):
            rows[j][i] = "A" if (i + j) % 3 else "S"
    for k in range(20):
        rows[30 - k][30 - k // 2] = "P"
    for j in range(6, 11):
        for i in range(16, 22):
            rows[j][i] = "O"
    return {"cell": 8, "x0": -240, "y0": -240, "w": 60, "h": 60, "rows": ["".join(r) for r in rows],
            "nests": [], "tick": 1000}


def frame(bm, centre):
    """The map view centred on `centre`: noisy green terrain, the base in map cyan, uncharted grey at the edges and
    the client's hint line at the bottom."""
    rng = np.random.default_rng(1)
    img = np.zeros((H, W, 3), np.uint8)
    img[...] = (110, 120, 50)
    img += rng.integers(0, 25, (H, W, 1), dtype=np.uint8)
    left, top = centre[0] - W / 2 / PPT, centre[1] - H / 2 / PPT
    c = bm["cell"]
    for j, row in enumerate(bm["rows"]):
        for i, ch in enumerate(row):
            if ch != ".":
                ax = int((bm["x0"] + i * c - left) * PPT)
                ay = int((bm["y0"] + j * c - top) * PPT)
                img[max(0, ay):max(0, ay + int(c * PPT)), max(0, ax):max(0, ax + int(c * PPT))] = (60, 170, 210)
    img[:, :300] = M.UNCHARTED
    img[:120, :] = M.UNCHARTED
    img[int(H * 0.975):int(H * 0.99), int(W * 0.45):int(W * 0.55)] = (230, 230, 230)
    buf = io.BytesIO()
    Image.fromarray(img).save(buf, "JPEG", quality=90)
    return buf.getvalue()


def main():
    bm = basemap()
    truth = (-31.0, 17.0)  # not the director's position: the client keeps the view it had (13:07 on 2026-10-13)
    webp, meta = M.frame_record(frame(bm, truth), bm, ZOOM, 5000, now=1)
    assert webp, meta
    assert abs(meta["centre"][0] - truth[0]) <= 1.5 and abs(meta["centre"][1] - truth[1]) <= 1.5, meta
    assert meta["px_per_tile"] == 1.44 and meta["zoom"] == ZOOM and meta["score"] >= M.MIN_SCORE, meta
    # the box is the charted part (the grey left and top bands cut off), in tiles (JPEG blurs the edge a few pixels)
    left, top = truth[0] - W / 2 / PPT, truth[1] - H / 2 / PPT
    assert abs(meta["box"][0] - (left + 300 / PPT)) <= 6 and abs(meta["box"][1] - (top + 120 / PPT)) <= 6, meta
    assert abs(meta["box"][2] - (W - 300) / PPT) <= 6 and abs(meta["box"][3] - (H - 120) / PPT) <= 6, meta
    im = Image.open(io.BytesIO(webp))
    assert im.mode == "RGBA" and im.width <= M.MAX_W and [im.width, im.height] == meta["px"], (im.mode, im.size, meta)
    # the hint line is transparent
    sx = im.width / ((W - 300))
    hy = int((H * 0.98 - 120) * sx)
    assert im.getpixel((int((W * 0.5 - 300) * sx), hy))[3] == 0
    assert im.getpixel((int((W * 0.3 - 300) * sx), int((H * 0.5 - 120) * sx)))[3] == 255
    # no buildings in view: not placed
    blank = io.BytesIO()
    Image.new("RGB", (W, H), (110, 120, 50)).save(blank, "JPEG")
    none, why = M.frame_record(blank.getvalue(), bm, ZOOM, 5000)
    assert none is None and "no buildings" in why, why
    # kept per area: the newest replaces the older, at most one per area every 10 game minutes
    with tempfile.TemporaryDirectory() as d:
        assert M.save(d, webp, meta)
        assert not M.save(d, webp, dict(meta, tick=5000 + M.EVERY_TICKS - 1))
        assert M.save(d, webp, dict(meta, tick=5000 + M.EVERY_TICKS))
        key = M.area_key(*meta["centre"])
        files = sorted(os.listdir(os.path.join(d, "mapframes")))
        assert files == [key + ".json", key + ".webp"], files
        kept = json.load(open(os.path.join(d, "mapframes", key + ".json")))
        assert kept["tick"] == 5000 + M.EVERY_TICKS and kept["area"] == key, kept
        # another area: its own files
        assert M.save(d, webp, dict(meta, centre=[600.0, 17.0]))
        assert len(os.listdir(os.path.join(d, "mapframes"))) == 4
    print("mapframes: ok (placed by registration within 1.5 tiles, charted cut-out, newest per area)")


if __name__ == "__main__":
    main()
