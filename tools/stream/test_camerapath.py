#!/usr/bin/env python3
"""A camera move within a shot (camerapath.py, d23 batch128 CK2). Offline: python3 tools/stream/test_camerapath.py

1. Easing: inout, in, out, linear from 0 to 1, clamped.
2. A path passes through its points; its speed follows length (a zoom-only step has length); zoom by ln z.
3. A move: at its first point before it starts, at a segment's end between segments, at the end after.
4. The same points as the game's (cameras.lua; vendor/factorio-harness/mod/tests/cameras_test.lua has these values).
5. check() refuses bad zooms, times out of order, unknown eases, too many points.
"""
import math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import camerapath as C  # noqa: E402

MOVE = {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 0.5}, {"x": 40, "y": 10, "zoom": 0.8},
                              {"x": 60, "y": -20, "zoom": 0.8}], "t0": 1, "t1": 11, "ease": "inout"},
                     {"pts": [{"x": 60, "y": -20, "zoom": 0.8}, {"x": 60, "y": -20, "zoom": 1.6}], "t0": 12, "t1": 16,
                      "ease": "out"}]}
# (t, x, y, zoom) as cameras_test.lua checks them in the game's Lua
GAME = [(3.5, 10.262814, 3.528639, 0.562535), (6, 34.765184, 10.847659, 0.747669), (9, 55.609527, -12.231978, 0.8),
        (13, 60, -20, 1.043012), (16, 60, -20, 1.6)]


def near(a, b, eps=1e-5):
    assert abs(a - b) < eps, (a, b)


def easing():
    for k in C.EASES:
        assert C.ease(0, k) == 0 and abs(C.ease(1, k) - 1) < 1e-12 and C.ease(-1, k) == 0 and abs(C.ease(2, k) - 1) < 1e-12
    near(C.ease(0.5, "inout"), 0.5)
    assert C.ease(0.25, "in") < 0.25 < C.ease(0.25, "out") and C.ease(0.3, "linear") == 0.3


def paths():
    pts = MOVE["segments"][0]["pts"]
    assert C.along(pts, 0) == (0, 0, 0.5) and C.along(pts, 1) == (60, -20, 0.8)
    steps = [C._step(pts[0], pts[1]), C._step(pts[1], pts[2])]
    x, y, z = C.along(pts, steps[0] / sum(steps))  # the middle point, at its share of the length
    near(x, 40) and near(y, 10) and near(z, 0.8)
    zoom_only = [{"x": 0, "y": 0, "zoom": 0.5}, {"x": 0, "y": 0, "zoom": 2.0}]
    x, y, z = C.along(zoom_only, 0.5)
    assert (x, y) == (0, 0)
    near(z, 1.0)  # half way in ln z: the geometric mean


def moves():
    assert C.at(MOVE, 0) == (0, 0, 0.5) and C.at(MOVE, 1) == (0, 0, 0.5)
    assert C.at(MOVE, 11.5) == (60, -20, 0.8), "between segments: the first one's end"
    assert C.at(MOVE, 30) == (60, -20, 1.6)
    for t, x, y, z in GAME:
        gx, gy, gz = C.at(MOVE, t)
        near(gx, x), near(gy, y), near(gz, z)
    # even speed along a straight line with linear easing
    line = {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}, {"x": 10, "y": 0, "zoom": 1}, {"x": 30, "y": 0, "zoom": 1}],
                          "t0": 0, "t1": 30, "ease": "linear"}]}
    for t in (5, 10, 20, 25):
        near(C.at(line, t)[0], t, 1e-6)
    assert C.start(MOVE) == {"x": 0, "y": 0, "zoom": 0.5} and len(C.points(MOVE)) == 5


def checks():
    assert C.check(MOVE)["segments"][1]["ease"] == "out"
    bad = [{"segments": []}, {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 9}], "t0": 0, "t1": 1}]},
           {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}], "t0": 5, "t1": 1}]},
           {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}], "t0": 0, "t1": 1, "ease": "bounce"}]},
           {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}] * 17, "t0": 0, "t1": 1}]},
           {"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}], "t0": 0, "t1": 5},
                         {"pts": [{"x": 0, "y": 0, "zoom": 1}], "t0": 4, "t1": 6}]},
           {"segments": [{"pts": [{"x": "a", "y": 0, "zoom": 1}], "t0": 0, "t1": 1}]}, "pan"]
    for b in bad:
        try:
            C.check(b)
            raise AssertionError(f"accepted {b}")
        except ValueError:
            pass


if __name__ == "__main__":
    for f in (easing, paths, moves, checks):
        f()
        print("ok", f.__name__)
    print("test_camerapath: all ok")
