"""A camera move within a shot (d23 batch128 CK2, Nick 17:30: "some nice within-shot camera controls"): where a camera
is at a time into its move. The same math runs in the game (cameras.lua `move`, every tick), here (lookcam's checks,
the director's fallback for a game without it, tour.py's dry-run) and on the page (overlay.js, the tour's marks),
so the three agree; tests compare them on fixed points.

A move: {"segments": [{"pts": [{x, y, zoom}, ...], "t0": s, "t1": s, "ease": "inout"}, ...]}, times in seconds from
its start (the program's cut), in order, not overlapping. Before the first segment the camera is at its first point,
between segments at the last one's end, after the last at its end. Within a segment:
- f = (t - t0) / (t1 - t0), eased: inout 0.5 - 0.5 cos(pi f) (default), in 1 - cos(pi f / 2), out sin(pi f / 2),
  linear f;
- the eased f runs along the points by "length": each step between two points counts |dx, dy| + ZOOM_K * |ln z1/z0|
  tiles (a zoom-only move has length too), so the speed is even over a path whose steps differ;
- between points i and i+1 at u in 0..1: x and y by a cubic Hermite spline through the points with chordal knots
  (Catmull-Rom by length: the tangent at a point is (next - previous) / the length between them, at the ends the
  step's own direction), so a path of several points turns without a corner and a straight one runs at an even
  speed; zoom by ln z linear in u.
"""
import math

ZOOM_K = 20.0  # tiles of path "length" per e-fold of zoom
EASES = ("inout", "in", "out", "linear")
MAX_POINTS = 16  # all segments together
MAX_SECONDS = 600.0
MIN_ZOOM, MAX_ZOOM = 0.3, 3.0


def ease(f, kind="inout"):
    f = 0.0 if f <= 0 else 1.0 if f >= 1 else f
    if kind == "linear":
        return f
    if kind == "in":
        return 1 - math.cos(math.pi * f / 2)
    if kind == "out":
        return math.sin(math.pi * f / 2)
    return 0.5 - 0.5 * math.cos(math.pi * f)


def _step(a, b):
    return math.hypot(b["x"] - a["x"], b["y"] - a["y"]) + ZOOM_K * abs(math.log(b["zoom"] / a["zoom"]))


def _tangent(pts, steps, i, k):
    """d(coordinate k)/d(length) at point i."""
    n = len(pts)
    if i == 0:
        return (pts[1][k] - pts[0][k]) / steps[0] if steps[0] > 1e-9 else 0.0
    if i == n - 1:
        return (pts[i][k] - pts[i - 1][k]) / steps[i - 1] if steps[i - 1] > 1e-9 else 0.0
    h = steps[i - 1] + steps[i]
    return (pts[i + 1][k] - pts[i - 1][k]) / h if h > 1e-9 else 0.0


def _hermite(a, b, ma, mb, h, u):
    u2, u3 = u * u, u * u * u
    return (2 * u3 - 3 * u2 + 1) * a + (u3 - 2 * u2 + u) * h * ma + (-2 * u3 + 3 * u2) * b + (u3 - u2) * h * mb


def along(pts, g):
    """The point at share g (0..1) of the path's length through pts -> (x, y, zoom)."""
    if len(pts) == 1 or g <= 0:
        p = pts[0]
        return p["x"], p["y"], p["zoom"]
    if g >= 1:
        p = pts[-1]
        return p["x"], p["y"], p["zoom"]
    steps = [_step(pts[i], pts[i + 1]) for i in range(len(pts) - 1)]
    total = sum(steps)
    if total <= 1e-9:
        p = pts[-1]
        return p["x"], p["y"], p["zoom"]
    want, i = g * total, 0
    while i < len(steps) - 1 and want > steps[i]:
        want -= steps[i]
        i += 1
    h = steps[i]
    u = want / h if h > 1e-9 else 1.0
    p1, p2 = pts[i], pts[i + 1]
    x, y = (_hermite(p1[k], p2[k], _tangent(pts, steps, i, k), _tangent(pts, steps, i + 1, k), h, u) for k in ("x", "y"))
    z = math.exp(math.log(p1["zoom"]) + (math.log(p2["zoom"]) - math.log(p1["zoom"])) * u)
    return x, y, z


def at(move, t):
    """Where the move's camera is t seconds after its start -> (x, y, zoom)."""
    segs = move["segments"]
    if t <= segs[0]["t0"]:
        return along(segs[0]["pts"], 0.0)
    for s in segs:
        if t < s["t1"]:
            if t < s["t0"]:
                break
            span = s["t1"] - s["t0"]
            return along(s["pts"], ease((t - s["t0"]) / span if span > 0 else 1.0, s.get("ease", "inout")))
    # between segments (at the last one's end) or after the last
    last = [s for s in segs if s["t1"] <= t] or segs[:1]
    return along(last[-1]["pts"], 1.0)


def number(v, what):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ValueError(f"{what} must be a finite number")
    return float(v)


def point(p, what):
    if not isinstance(p, dict):
        raise ValueError(f"{what} must be an object {{x, y, zoom}}")
    z = number(p.get("zoom"), f"{what} zoom")
    if not MIN_ZOOM <= z <= MAX_ZOOM:
        raise ValueError(f"{what} zoom must be {MIN_ZOOM:g}..{MAX_ZOOM:g}")
    return {"x": round(number(p.get("x"), f"{what} x"), 2), "y": round(number(p.get("y"), f"{what} y"), 2),
            "zoom": round(z, 3)}


def check(move):
    """A move as sent to the service and the game, checked -> the move (rounded), or ValueError with why."""
    if not isinstance(move, dict) or not isinstance(move.get("segments"), list) or not move["segments"]:
        raise ValueError("move must be {segments: [{pts, t0, t1, ease}, ...]}")
    out, n, end = [], 0, 0.0
    for i, s in enumerate(move["segments"]):
        what = f"segment {i + 1}"
        if not isinstance(s, dict) or not isinstance(s.get("pts"), list) or not s["pts"]:
            raise ValueError(f"{what}: pts must be a list of {{x, y, zoom}}")
        pts = [point(p, f"{what} point {k + 1}") for k, p in enumerate(s["pts"])]
        n += len(pts)
        t0, t1 = number(s.get("t0"), f"{what} t0"), number(s.get("t1"), f"{what} t1")
        if t0 < end - 1e-6 or t1 < t0 or t1 > MAX_SECONDS:
            raise ValueError(f"{what}: times must run forward from 0, in order, up to {MAX_SECONDS:g} s")
        e = s.get("ease", "inout")
        if e not in EASES:
            raise ValueError(f"{what}: ease must be one of {', '.join(EASES)}")
        out.append({"pts": pts, "t0": round(t0, 3), "t1": round(t1, 3), "ease": e})
        end = t1
    if n > MAX_POINTS:
        raise ValueError(f"at most {MAX_POINTS} points in a move")
    return {"segments": out}


def start(move):
    x, y, z = along(move["segments"][0]["pts"], 0.0)
    return {"x": x, "y": y, "zoom": z}


def points(move):
    """Every point the move passes through (for the chart check: each frame is read)."""
    return [p for s in move["segments"] for p in s["pts"]]
