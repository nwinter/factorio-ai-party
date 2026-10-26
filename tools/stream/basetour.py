"""Base tours (d26 batch222 CD, viewer Caleb d25 09:56-11:02, site:4914 "a base cam ... does a tour of the base by
panning around", site:4915 "base tour cams for all planets"): a slow pan over one planet's factory, planned from the
site's chart (chart.py: runs/RUN/chart/out/SURFACE/*.labels.json, a label at each machine with a recipe, and
out/index.json), shot as the operator's POST /look moves were that morning (lookcam.py: a fixed spot with a camera move
at zoom 0.35-0.4, three or four points over 44-50 s; Nauvis (-90,-20) to (90,40), Vulcanus (30,120) to (110,150)).

plan(surface, ...) -> a shot {surface, position, zoom, move, seconds, label, machines} or None:
- the machines: the labelled machines on the surface (at least MIN_MACHINES);
- the core: the machine with the most others within CORE_R tiles, and the machines within REACH of it;
- the line: their main axis (the covariance's first eigenvector) through the core, from the 10th to the 90th
  percentile of the machines along it, at most PAN_MAX tiles; 3 points (4 over 140 tiles), each moved half way to the
  machines within SNAP_R of it, west to east (or north to south for a line that runs so);
- chart-checked: every 32-tile chunk the on-air frame covers at each point (director.CLIENT at the zoom and view
  frac, lookcam.frame_half) is charted (charted(surface, cx, cy): the chart store's charted chunks, chart.Chart.known;
  without a store, the chart index's cell holds all its 144 chunks); a point that fails is left out, and a pan needs
  2 points;
- the move: camerapath segments from the cut, SPEED tiles a second within SECONDS_MIN..SECONDS_MAX, a rest of
  REST_S at each end.
Stdlib only; one plan reads the surface's labels files (Nauvis's 40 cells: about 0.2 MB).
"""
import glob, json, math, os

import camerapath

PLANETS = ("nauvis", "vulcanus", "gleba", "fulgora", "aquilo")
MIN_MACHINES = 8
CORE_R = 48.0
REACH = 120.0
PAN_MAX = 200.0
SNAP_R = 40.0
ZOOM = 0.4
SPEED = 3.5
SECONDS_MIN, SECONDS_MAX = 30.0, 50.0
REST_S = 2.0
CHUNK, CELL, CELL_CHUNKS = 32, 384, 144


def planet_label(surface):
    return str(surface)[:1].upper() + str(surface)[1:]


def machines(out_dir, surface):
    """[(x, y)] of the labelled machines on the surface (chart.py labels files)."""
    pts = []
    for path in glob.glob(os.path.join(out_dir, surface, "*.labels.json")):
        try:
            with open(path) as f:
                rows = (json.load(f) or {}).get("recipes") or []
        except (OSError, ValueError, AttributeError):
            continue
        for r in rows:
            if isinstance(r, list) and len(r) >= 2 and all(isinstance(v, (int, float)) for v in r[:2]):
                pts.append((float(r[0]), float(r[1])))
    return pts


def index_charted(out_dir):
    """charted(surface, cx, cy) from out/index.json alone: the chunk's cell holds all its chunks."""
    try:
        with open(os.path.join(out_dir, "index.json")) as f:
            surfaces = (json.load(f) or {}).get("surfaces") or {}
    except (OSError, ValueError, AttributeError):
        surfaces = {}

    def charted(surface, cx, cy):
        c = ((surfaces.get(surface) or {}).get("cells") or {}).get(f"{cx // 12},{cy // 12}")
        return isinstance(c, list) and len(c) >= 4 and c[3] >= CELL_CHUNKS
    return charted


def store_charted(chart, fallback=None):
    """charted(surface, cx, cy) from a chart.Chart: its store's charted chunks (read once a surface per plan). The
    service's poller thread adds chunks while the director plans (serve.py steps the director outside its lock): a read
    that meets a change is tried again, then the chart index answers (fallback)."""
    cache = {}

    def charted(surface, cx, cy):
        if surface not in cache:
            for _ in range(3):
                try:
                    cache[surface] = set(chart.known(surface))
                    break
                except RuntimeError:  # dictionary changed size during iteration
                    continue
            else:
                cache[surface] = None
        if cache[surface] is None:
            return bool(fallback and fallback(surface, cx, cy))
        return (cx, cy) in cache[surface]
    return charted


def frame_ok(surface, x, y, zoom, frac, charted):
    from lookcam import chunks, frame_half
    hw, hh = frame_half(zoom, frac)
    cx0, cy0, cx1, cy1 = chunks(x, y, hw, hh)
    return all(charted(surface, cx, cy) for cx in range(cx0, cx1 + 1) for cy in range(cy0, cy1 + 1))


def percentile(vals, q):
    s = sorted(vals)
    if not s:
        return 0.0
    k = (len(s) - 1) * q
    lo, hi = int(math.floor(k)), int(math.ceil(k))
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def axis(pts):
    """The unit vector of the points' main axis (2x2 covariance, its larger eigenvalue's eigenvector)."""
    n = len(pts)
    mx, my = sum(p[0] for p in pts) / n, sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts) / n
    syy = sum((p[1] - my) ** 2 for p in pts) / n
    sxy = sum((p[0] - mx) * (p[1] - my) for p in pts) / n
    ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
    ux, uy = math.cos(ang), math.sin(ang)
    if abs(ux) >= abs(uy):
        return (ux, uy) if ux >= 0 else (-ux, -uy)  # west to east
    return (ux, uy) if uy >= 0 else (-ux, -uy)      # north to south


def plan(surface, out_dir, charted=None, frac=1.0, zoom=ZOOM, pts=None):
    """The base tour of one planet (module doc), or None."""
    pts = machines(out_dir, surface) if pts is None else pts
    if len(pts) < MIN_MACHINES:
        return None
    charted = charted or index_charted(out_dir)
    r2 = CORE_R * CORE_R
    grid = {}
    for p in pts:
        grid.setdefault((int(p[0] // CORE_R), int(p[1] // CORE_R)), []).append(p)

    def around(p):
        gx, gy = int(p[0] // CORE_R), int(p[1] // CORE_R)
        return sum(1 for dx in (-1, 0, 1) for dy in (-1, 0, 1) for q in grid.get((gx + dx, gy + dy), ())
                   if (q[0] - p[0]) ** 2 + (q[1] - p[1]) ** 2 <= r2)
    core = max(pts, key=lambda p: (around(p), -abs(p[0]) - abs(p[1])))
    near = [q for q in pts if math.hypot(q[0] - core[0], q[1] - core[1]) <= REACH]
    ux, uy = axis(near)
    proj = [(q[0] - core[0]) * ux + (q[1] - core[1]) * uy for q in near]
    a, b = percentile(proj, 0.1), percentile(proj, 0.9)
    if b - a > PAN_MAX:
        mid = max(a + PAN_MAX / 2, min(b - PAN_MAX / 2, 0.0))
        a, b = mid - PAN_MAX / 2, mid + PAN_MAX / 2
    n = 4 if b - a > 140 else 3
    stops = []
    for i in range(n):
        s = a + (b - a) * i / (n - 1)
        x, y = core[0] + ux * s, core[1] + uy * s
        close = [q for q in near if math.hypot(q[0] - x, q[1] - y) <= SNAP_R]
        if close:
            x = (x + sum(q[0] for q in close) / len(close)) / 2
            y = (y + sum(q[1] for q in close) / len(close)) / 2
        x, y = round(x), round(y)
        if frame_ok(surface, x, y, zoom, frac, charted):
            stops.append({"x": float(x), "y": float(y), "zoom": zoom})
    if len(stops) < 2:
        return None
    length = sum(math.hypot(q["x"] - p["x"], q["y"] - p["y"]) for p, q in zip(stops, stops[1:]))
    secs = round(max(SECONDS_MIN, min(SECONDS_MAX, length / SPEED)), 1)
    move = camerapath.check({"segments": [{"pts": stops, "t0": REST_S, "t1": REST_S + secs, "ease": "inout"}]})
    return {"surface": surface, "position": {"x": stops[0]["x"], "y": stops[0]["y"]}, "zoom": zoom, "move": move,
            "seconds": round(secs + 2 * REST_S, 1), "label": f"{planet_label(surface)} base · a slow pan",
            "machines": len(near), "length": round(length)}


class Tours:
    """The director's source of base tours (onecam.maybe_tour): plans from the run's chart, kept until its index
    changes. out_dir: runs/RUN/chart/out; chart: the service's chart.Chart (its store's charted chunks), or None."""

    def __init__(self, out_dir, chart=None, planets=PLANETS):
        self.out_dir, self.chart, self.planets = out_dir, chart, tuple(planets)
        self.plans, self.stamp = {}, None

    def get(self, surface, frac=1.0):
        try:
            stamp = os.stat(os.path.join(self.out_dir, "index.json")).st_mtime_ns
        except OSError:
            stamp = None
        if stamp != self.stamp:
            self.plans, self.stamp = {}, stamp
        key = (surface, round(frac, 3))
        if key not in self.plans:
            charted = store_charted(self.chart, index_charted(self.out_dir)) if self.chart is not None else None
            self.plans[key] = plan(surface, self.out_dir, charted, frac)
        return self.plans[key]
