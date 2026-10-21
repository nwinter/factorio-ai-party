"""site/timelapse.py data(): the time-lapse in parts under the host's file size limit (Cloudflare Pages: 25 MiB a
file; the whole time-lapse passed it at shift 49), with timelapse.json the index, and the page script that joins the
parts in order. Run: python3 site/test_timelapse_parts.py"""
import json, sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
import timelapse  # noqa: E402


def frame(i, rows=4):
    return {"n": 1 + i // 10, "tick": 1000000 + i, "game": f"{i:03d}m", "base": {"cell": 8, "x0": 0, "y0": 0, "w": 3,
            "h": rows, "rows": ["ABC"] * rows}, "core": None}


def main():
    frames = [frame(i) for i in range(25)]
    one = len(json.dumps(frames[0], separators=(",", ":"))) + 1
    out = timelapse.data(frames, [{"src": "/live/terrain/t.webp"}], part_bytes=one * 10)
    index = json.loads(out["/runs/long/timelapse.json"])
    assert "frames" not in index and index["count"] == 25 and index["terrain"] == [{"src": "/live/terrain/t.webp"}], index
    assert index["parts"] == [f"/runs/long/timelapse-{i}.json" for i in (1, 2, 3)], index["parts"]
    assert set(out) == {"/runs/long/timelapse.json", *index["parts"]}, list(out)
    parts = [json.loads(out[u])["frames"] for u in index["parts"]]
    assert [len(p) for p in parts] == [10, 10, 5], [len(p) for p in parts]
    assert [f["tick"] for p in parts for f in p] == [f["tick"] for f in frames]  # in order, none lost
    assert all(len(out[u]) <= one * 10 + 20 for u in index["parts"])  # {"frames":[...]} around the frames
    assert len(index["box"]) == 4
    # a full part's text stays the same when later frames are added (browsers and the host keep it cached)
    more = timelapse.data(frames + [frame(25), frame(26)], None, part_bytes=one * 10)
    assert more["/runs/long/timelapse-1.json"] == out["/runs/long/timelapse-1.json"]
    assert "terrain" not in json.loads(more["/runs/long/timelapse.json"])
    # one frame larger than a part still gets its own part
    big = timelapse.data([frame(0, rows=200), frame(1)], None, part_bytes=one)
    assert json.loads(big["/runs/long/timelapse.json"])["parts"] == ["/runs/long/timelapse-1.json", "/runs/long/timelapse-2.json"]
    # the default part size leaves room under the host's 25 MiB
    assert timelapse.PART_BYTES <= 12 << 20
    # the page script fetches the index, then every part, and joins their frames in order
    js = timelapse.SCRIPT
    assert "d.parts" in js and "Promise.all" in js and "concat(p.frames" in js
    print("ok")


if __name__ == "__main__":
    main()
