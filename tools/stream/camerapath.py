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


def transition(a, b, seconds, easing="inout"):
    """Shared native/fallback path; zoom travels logarithmically, position eases at both ends."""
    # A rendered logarithmic interpolation can return 0.29999999999999993 at the .3 floor.
    pts = [dict(p, zoom=min(MAX_ZOOM, max(MIN_ZOOM, p["zoom"]))) for p in (a, b)]
    return check({"segments": [{"pts": pts, "t0": 0, "t1": seconds, "ease": easing}]})


def ship_survey(shot, details=()):
    """A survey from the measured hull and the current visible pane, independent of a shot's dwell.

    At each end 35% of a view height lies beyond the foundation, including the asteroid/engine space.
    Keep batch387's width fit and zoom floor. Details are supplied by the director (a future fresh-work hook).
    """
    frame = shot["platform_frame"]
    b, z = frame["bounds"], shot["zoom"]
    height = 33.75 / z
    mid = (b["top"] + b["bottom"]) / 2
    y0 = min(mid - height * .1, b["top"] + height * .15)
    y1 = max(mid + height * .1, b["bottom"] - height * .15)
    x = frame["hull_centre"]["x"]
    return {"bow": {"x": x, "y": round(y0, 2), "zoom": z},
            "stern": {"x": x, "y": round(y1, 2), "zoom": z},
            "speed": height / 18, "bounds": dict(b), "frac": frame["frac"],
            "details": list(details), "surface": shot["surface"]}


class Survey:
    """One receipt-driven survey/detail/pullback/return controller.

    Scheduling never earns coverage. Only observe() of a connected, visible camera does. Motion is issued
    by the director, using the same path for native playback and panel/old-runtime fallback. Suspension
    retains the last observed point, phase, dwell and direction until the original hold deadline.
    """
    END_S, DETAIL_S, ZOOM_S, MAX_HOLD = 6.0, 10.0, 6.0, 240.0

    def __init__(self, spec, now, until):
        import copy
        self.spec = copy.deepcopy(spec)
        self.expires = min(until, now + self.MAX_HOLD)
        self.phase, self.direction = "bow_dwell", 1
        self.pose = dict(spec["bow"])
        self.goal = dict(self.pose)
        self.anchor = None
        self.dwell = 0.0
        self.detail_index = 0
        self.detailed = False
        self.coverage = []
        self.ends = set()
        self.last_observed = None
        self.active = False
        self.interrupted = False
        self.template = None
        self.motion = None
        self.native = None
        self.sent_at = None
        self.return_phase = None

    def suspend(self):
        self.interrupted = self.interrupted or self.active
        self.active = False
        self.motion = None
        self.last_observed = None

    def arrived(self):
        return math.hypot(self.pose["x"] - self.goal["x"], self.pose["y"] - self.goal["y"]) < .5 and \
            abs(self.pose["zoom"] - self.goal["zoom"]) < .015

    def observe(self, receipt, now, visible):
        if not (visible and receipt.get("ok") and receipt.get("connected") and receipt.get("visible") and
                receipt.get("surface") == self.spec["surface"] and isinstance(receipt.get("position"), dict) and
                isinstance(receipt.get("zoom"), (float, int))):
            self.last_observed = None
            return False
        dt = now - self.last_observed if self.last_observed is not None else 0
        self.last_observed = now
        self.pose = dict(receipt["position"], zoom=receipt["zoom"])
        if self.phase in ("survey", "bow_dwell", "stern_dwell"):
            # A frame covers hull only if its width fits the visible pane and its actual zoom is the overview.
            b, p = self.spec["bounds"], self.pose
            z = max(p["zoom"], receipt.get("coverage_zoom", p["zoom"]))
            hw, hh = 30 * self.spec["frac"] / z, 16.875 / z
            if p["x"] - hw <= b["left"] and p["x"] + hw >= b["right"]:
                lo, hi = max(b["top"], p["y"] - hh), min(b["bottom"], p["y"] + hh)
                if hi > lo:
                    merged = []
                    for a, c in sorted(self.coverage + [(lo, hi)]):
                        if merged and a <= merged[-1][1]:
                            merged[-1] = (merged[-1][0], max(c, merged[-1][1]))
                        else:
                            merged.append((a, c))
                    self.coverage = merged
        if self.arrived() and self.phase.endswith("dwell") and 0 < dt <= 3:
            self.dwell += dt
        return True

    def change(self, phase, goal):
        self.phase, self.goal = phase, dict(goal)
        self.dwell, self.motion = 0.0, None

    def detail(self, beat):
        """Interrupt with a supplied section; future work-aware tours can call this without a second clock."""
        if self.phase not in ("survey", "bow_dwell", "stern_dwell"):
            return False
        self.anchor = dict(self.pose)
        self.return_phase = self.phase
        self.saved_goal = dict(self.goal)
        self.saved_dwell = self.dwell
        self.change("zoom_in", dict(beat["position"], zoom=max(.3, beat["zoom"])))
        self.detailed = True
        return True

    def advance(self):
        """Called only after a fresh visible receipt. A deadline is never an arrival."""
        at_goal = self.arrived()
        if self.phase in ("bow_dwell", "stern_dwell") and at_goal and self.dwell >= self.END_S:
            self.ends.add("bow" if self.phase == "bow_dwell" else "stern")
            self.direction = 1 if self.phase == "bow_dwell" else -1
            self.detailed = False
            self.change("survey", self.spec["stern" if self.direction == 1 else "bow"])
        elif self.phase == "survey":
            if at_goal:
                self.change("stern_dwell" if self.direction == 1 else "bow_dwell", self.goal)
            elif not self.detailed and self.spec["details"] and \
                    (self.pose["y"] - (self.spec["bow"]["y"] + self.spec["stern"]["y"]) / 2) * self.direction >= 0:
                beat = self.spec["details"][self.detail_index % len(self.spec["details"])]
                self.detail_index += 1
                self.detail(beat)
        elif self.phase == "zoom_in" and at_goal:
            self.change("detail_dwell", self.goal)
        elif self.phase == "detail_dwell" and at_goal and self.dwell >= self.DETAIL_S:
            self.change("pullback", dict(self.pose, zoom=self.spec["bow"]["zoom"]))
        elif self.phase == "pullback" and at_goal:
            self.change("return", self.anchor)
        elif self.phase == "return" and at_goal:
            self.change(self.return_phase, self.saved_goal)
            self.dwell = self.saved_dwell

    def path(self):
        distance = math.hypot(self.pose["x"] - self.goal["x"], self.pose["y"] - self.goal["y"])
        seconds = max(1, distance / self.spec["speed"]) if self.phase == "survey" else max(self.ZOOM_S, distance / 20)
        return transition(self.pose, self.goal, min(600, seconds))

    def public(self):
        return {"phase": self.phase, "direction": self.direction, "position": dict(self.pose),
                "goal": dict(self.goal), "coverage": list(self.coverage), "ends": sorted(self.ends),
                "expires": self.expires, "dwell": round(self.dwell, 2)}
