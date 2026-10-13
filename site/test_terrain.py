"""site/terrain.py and static/terrain.js: the newest map frame per area over the run's shifts, published as
/terrain/index.json, and the layer the map viewers draw from it. Run: python3 site/test_terrain.py"""
import json, shutil, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
import terrain  # noqa: E402


def frame(d, area, tick, box, surface="nauvis"):
    m = d / "mapframes"
    m.mkdir(parents=True, exist_ok=True)
    (m / f"{area}.webp").write_bytes(b"RIFF....WEBP" + area.encode() + str(tick).encode())
    (m / f"{area}.json").write_text(json.dumps({"tick": tick, "surface": surface, "box": box, "px": [2048, 1431], "area": area}))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runs, out = Path(tmp) / "runs", Path(tmp) / "dist"
        a, b = runs / "s1", runs / "s2"
        frame(a, "-1_-1", 1000, [-646.4, -549.3, 1577.8, 1102.8])
        frame(a, "2_0", 1500, [400, -100, 500, 300])
        frame(b, "-1_-1", 9000, [-650, -550, 1580, 1100])           # newer: replaces s1's
        frame(b, "0_0", 9100, [0, 0, 100, 100], surface="vulcanus")
        (b / "mapframes" / "bad.json").write_text(json.dumps({"tick": 5, "box": [0, 0, 0, 0]}))
        (b / "mapframes" / "bad.webp").write_bytes(b"x")
        (b / "mapframes" / "nofile.json").write_text(json.dumps({"tick": 5, "box": [0, 0, 9, 9]}))
        long = {"shifts": [{"id": "s1", "n": 1}, {"id": "s2", "n": 2}, {"id": "s3", "n": 3, "empty": True}]}
        rows = terrain.frames(long, runs)
        assert [(r["shift"], r["area"]) for r in rows] == [("s1", "2_0"), ("s2", "-1_-1"), ("s2", "0_0")], rows
        index = terrain.publish(out, rows)
        assert [f["src"] for f in index["frames"]] == ["/terrain/s1-2_0-1500.webp", "/terrain/s2--1_-1-9000.webp",
                                                      "/terrain/s2-0_0-9100.webp"], index
        f = index["frames"][1]
        assert (f["x"], f["y"], f["w"], f["h"], f["tick"], f["shift"], f["surface"]) == (-650, -550, 1580, 1100, 9000, 2, "nauvis")
        assert json.loads((out / "terrain" / "index.json").read_text()) == index
        assert (out / "terrain" / "s2--1_-1-9000.webp").read_bytes().endswith(b"-1_-19000")
        assert terrain.publish(Path(tmp) / "none", []) is None and not (Path(tmp) / "none").exists()

        # terrain.js in node: newest per area at or before a tick, placed with the viewer's transform
        js = (SITE / "static" / "terrain.js").read_text()
        idx = json.dumps({"frames": index["frames"] + [{"src": "/terrain/old.webp", "x": -646, "y": -549, "w": 1577, "h": 1102,
                                                         "tick": 1000, "surface": "nauvis"}]})
        test = js.replace("(function () {", "var window = {}; (function () {", 1) + """
var T = window.PogTerrain, I = %s;
var now = T.pick(I, null).map(function (f) { return f.src; });
var then = T.pick(I, 2000).map(function (f) { return f.src; });
var vul = T.pick(I, null, 'vulcanus').map(function (f) { return f.src; });
var s = T.svg(I, { x: function (x) { return 200 + (x - 0) * 0.5; }, y: function (y) { return 200 + (y - 0) * 0.5; }, k: 0.5 });
console.log(JSON.stringify({ now: now, then: then, vul: vul, svg: s, none: T.svg(null, {}) }));
""" % idx
        p = Path(tmp) / "t.js"
        p.write_text(test)
        if shutil.which("node"):
            r = json.loads(subprocess.run(["node", str(p)], capture_output=True, text=True, check=True).stdout)
            assert r["now"] == ["/terrain/s1-2_0-1500.webp", "/terrain/s2--1_-1-9000.webp"], r
            assert r["then"] == ["/terrain/old.webp", "/terrain/s1-2_0-1500.webp"], r
            assert r["vul"] == ["/terrain/s2-0_0-9100.webp"] and r["none"] == "", r
            assert r["svg"].startswith('<g class="terrain" aria-hidden="true"><image href="/terrain/s1-2_0-1500.webp" x="400.00" y="150.00" '
                                       'width="250.00" height="150.00" preserveAspectRatio="none"'), r["svg"]
        else:
            print("terrain: node not found, terrain.js not run")
    print("terrain: ok (newest frame per area over the shifts, /terrain/index.json, the layer at a tick)")


if __name__ == "__main__":
    main()
