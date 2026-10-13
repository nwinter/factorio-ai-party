"""site/terrain.py and push_live.py's basemap.terrain: the newest map frame per area over the run's shifts, in the
map viewer's shape ({src, x0, y0, x1, y1, tick, w, h}), published under /live/terrain/ and read back into the live
state. Run: python3 site/test_terrain.py"""
import io, json, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
import terrain  # noqa: E402
import push_live  # noqa: E402


def frame(d, area, tick, box, surface="nauvis", px=(2048, 1432)):
    m = d / "mapframes"
    m.mkdir(parents=True, exist_ok=True)
    (m / f"{area}.webp").write_bytes(b"RIFF....WEBP" + area.encode() + str(tick).encode())
    (m / f"{area}.json").write_text(json.dumps({"tick": tick, "surface": surface, "box": box, "px": list(px), "area": area}))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runs, out = Path(tmp) / "runs", Path(tmp) / "dist"
        a, b = runs / "s1", runs / "s2"
        frame(a, "-1_-1", 1000, [-646.4, -549.3, 1577.8, 1102.8])
        frame(a, "2_0", 1500, [400, -100, 500, 300])
        frame(b, "-1_-1", 9000, [-641.5, -544.5, 1570.1, 1097.9])  # newer: replaces s1's
        frame(b, "0_0", 9100, [0, 0, 100, 100], surface="vulcanus")  # not Nauvis: left out
        (b / "mapframes" / "bad.json").write_text(json.dumps({"tick": 5, "box": [0, 0, 0, 0], "px": [1, 1]}))
        (b / "mapframes" / "bad.webp").write_bytes(b"x")
        (b / "mapframes" / "nofile.json").write_text(json.dumps({"tick": 5, "box": [0, 0, 9, 9], "px": [1, 1]}))
        long = {"shifts": [{"id": "s1", "n": 1}, {"id": "s2", "n": 2}, {"id": "s3", "n": 3, "empty": True}]}
        want = [{"src": "/live/terrain/s1-2_0-1500.webp", "x0": 400, "y0": -100, "x1": 900, "y1": 200, "tick": 1500, "w": 2048, "h": 1432},
                {"src": "/live/terrain/s2--1_-1-9000.webp", "x0": -641.5, "y0": -544.5, "x1": 928.6, "y1": 553.4, "tick": 9000,
                 "w": 2048, "h": 1432}]
        assert terrain.terrain_frames(runs, long) == want, terrain.terrain_frames(runs, long)
        assert terrain.publish(out, runs, long) == want
        assert json.loads((out / "live" / "terrain" / "index.json").read_text()) == {"terrain": want}
        assert (out / "live" / "terrain" / "s2--1_-1-9000.webp").read_bytes().endswith(b"-1_-19000")
        assert terrain.publish(Path(tmp) / "none", Path(tmp) / "empty", long) == [] and not (Path(tmp) / "none").exists()

        # the live state: basemap.terrain from the deployed site's index, read at most every 5 minutes, kept on a failure
        index = json.dumps({"terrain": want + [{"src": "https://elsewhere/x.webp", "x0": 0, "y0": 0, "x1": 1, "y1": 1, "w": 1, "h": 1}]})
        calls = []

        def opener(url, timeout):
            calls.append(url)
            if len(calls) > 1:
                raise OSError("site down")
            return io.BytesIO(index.encode())
        rows = push_live.site_terrain("https://factorio.example", now=1000, opener=opener)
        assert calls == ["https://factorio.example/live/terrain/index.json"] and rows == want, (calls, rows)
        assert push_live.site_terrain("https://factorio.example", now=1100, opener=opener) == want and len(calls) == 1
        assert push_live.site_terrain("https://factorio.example", now=1400, opener=opener) == want and len(calls) == 2
        state = push_live.with_terrain({"basemap": {"cell": 8, "rows": ["A"]}, "tick": 5}, rows)
        assert state["basemap"]["terrain"] == want and state["basemap"]["rows"] == ["A"]
        assert "basemap" not in push_live.with_terrain({"tick": 5}, rows)
        many = [dict(want[0], tick=t, src=f"/live/terrain/{t}.webp") for t in range(30, 0, -1)]
        assert [e["tick"] for e in terrain.live({"terrain": many})] == list(range(15, 31))
    print("terrain: ok (newest frame per area over the shifts in the viewer's shape, /live/terrain/, basemap.terrain)")


if __name__ == "__main__":
    main()
