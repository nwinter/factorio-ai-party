"""Quiet base scenes and ship-detail memory (batch406).

choose(Tours, Memory, now) ranks fresh snapshot facts and unseen chart regions at scene boundaries.
It rotates straight chart-checked compositions and remembers only confirmed on-air scenes. Trains consumes
existing journal replies; it never dispatches a game read. The original plan/get API below remains available
for callers needing a single static overview.

Base tours (d26 batch222 CD, viewer Caleb d25 09:56-11:02, site:4914 "a base cam ... does a tour of the base by
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
        self.recipe_memory = {}

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


# Quiet scenes use facts already present in the service snapshot. A plan is immutable once selected;
# these bounded memories are consulted at scene boundaries, never used to chase new work mid-shot.
def position(value):
    if isinstance(value, dict) and all(type(value.get(k)) in (int, float) and math.isfinite(value[k]) for k in ('x', 'y')):
        return {k: float(value[k]) for k in ('x', 'y')}
    return None


def region(surface, p):
    return f"{surface}:{math.floor(p['x'] / 64)}:{math.floor(p['y'] / 64)}"


class Memory:
    KEEP = 600.0

    def __init__(self):
        self.events = {}
        self.shown = {}  # region -> (time, fact identity, composition, count)
        self.observed = {}
        self.active_repairs = set()
        self.production = {}

    def note(self, surface, p, why, identity, t, now, agent=None):
        p = position(p)
        if not surface or not p or type(t) not in (int, float) or not 0 <= now - t <= self.KEEP:
            return
        key = region(surface, p)
        old = self.events.get(key)
        if old and old['identity'] == str(identity):
            return
        if old is None or t > old['t']:
            self.events[key] = dict(surface=surface, position=p, why=why + (f' by {agent}' if agent else ''),
                                    identity=str(identity), t=t, region=key, agent=agent)

    def observe(self, snapshot, now):
        ships = {p.get('name'): p for p in (snapshot.get('space') or {}).get('platforms') or []}
        for w in snapshot.get('work') or []:
            if w.get('action') not in ('place_ghosts', 'paste', 'blueprint_place', 'deconstruct', 'build',
                                        'construct', 'repair', 'configure', 'launch', 'drop'):
                continue
            view = (ships.get(w.get('platform')) or {}).get('view') or {}
            self.note(view.get('surface') or w.get('surface'), w.get('position') or view.get('hub'),
                      'recent ' + str(w.get('verb') or w.get('action') or 'work'),
                      w.get('id') or (w.get('agent'), w.get('t'), w.get('action')), w.get('t'), now, w.get('agent'))
        repairing = set()
        for a in snapshot.get('agents') or []:
            w = a.get('did') or {}
            view = (ships.get(w.get('platform')) or {}).get('view') or {}
            self.note(view.get('surface') or w.get('surface'), w.get('position') or view.get('hub'),
                      'recent ' + str(w.get('action') or 'building'), (a.get('name'), w.get('t')), w.get('t'), now, a.get('name'))
            if str(a.get('active') or '').split(':')[0] == 'repair':
                key = (a.get('name'), a.get('surface'))
                repairing.add(key)
                if key not in self.active_repairs:
                    self.note(a.get('surface'), a.get('position'), 'repairs underway', ('repair', key, now), now, now, a.get('name'))
        self.active_repairs = repairing
        for f in snapshot.get('fights') or []:
            self.note((f.get('position') or {}).get('surface') or f.get('surface'), f.get('position'),
                      'recent damage' if f.get('losses') else 'recent threat',
                      ('fight', f.get('key'), f.get('first'), len(f.get('losses') or [])),
                      max(f.get('losses') or [f.get('first') or f.get('t') or 0]), now)
        production_keys = set()
        for name, row in ships.items():
            v = row.get('view') or {}
            danger = row.get('danger') or {}
            if danger.get('kind') in ('fire', 'damage'):
                self.note(v.get('surface'), v.get('hub'), 'recent ship ' + danger['kind'],
                          (name, danger.get('last')), danger.get('last'), now)
            groups = {}
            for machine in v.get('machines') or []:
                p = position(machine)
                if p and v.get('surface'):
                    groups.setdefault(region(v['surface'], p), []).append(machine)
            for key, group in groups.items():
                production_keys.add(key)
                state_now = (len(group), sum(bool(m.get('w')) for m in group))
                old_state, pending, since = self.production.get(key, (state_now, state_now, now))
                if state_now != pending:
                    pending, since = state_now, now
                if state_now != old_state and now-since >= 30:
                    p = dict(x=sum(m['x'] for m in group)/len(group), y=sum(m['y'] for m in group)/len(group))
                    self.note(v['surface'], p, f'production changed: {state_now[1]} of {state_now[0]} machines working',
                              (key, state_now, since), now, now)
                    old_state = state_now
                self.production[key] = old_state, pending, since
            # Only structural/recipe changes and arrival transitions count; raw stock fluctuations do not.
            state = (row.get('where'), json.dumps([(m.get('x'), m.get('y'), m.get('recipe'))
                     for m in v.get('machines') or []], sort_keys=True))
            old = self.observed.get(name)
            if old and old != state:
                why = 'recent arrival' if old[0] != state[0] and not row.get('route') else 'machinery changed'
                if why != 'machinery changed' or old[1] != state[1]:
                    self.note(v.get('surface'), v.get('hub'), why, (name, state), now, now)
            self.observed[name] = state
        self.events = {k: e for k, e in self.events.items() if now - e['t'] <= self.KEEP}
        self.events = dict(sorted(self.events.items(), key=lambda kv: kv[1]['t'])[-256:])
        self.shown = dict(sorted(self.shown.items(), key=lambda kv: kv[1][0])[-512:])
        self.observed = {n: s for n, s in self.observed.items() if n in ships}
        self.production = {k: v for k, v in self.production.items() if k in production_keys}

    def score(self, candidate, now):
        old = self.shown.get(candidate['region'])
        fresh = candidate.get('identity') and (not old or old[1] != candidate['identity'])
        novelty = 4 if old is None else min(2, max(0, now - old[0]) / 900)
        return (8 * max(0, 1 - (now - candidate.get('t', now)) / self.KEEP) if fresh else 0) + novelty

    def seen(self, candidate, now):
        key = candidate.get('region')
        if key:
            old = self.shown.get(key)
            self.shown[key] = (now, candidate.get('identity'), candidate.get('composition'), (old[3] if old else 0) + 1)

    def details(self, surface, fallbacks, now):
        candidates = [dict(e, label=e['why'], zoom=.8) for e in self.events.values() if e['surface'] == surface]
        candidates += [dict(b, surface=surface, region=region(surface, b['position'])) for b in fallbacks if b and not b.get('identity')]
        unique = {}
        for c in candidates:
            old = self.shown.get(c['region'])
            count = old[3] if old else 0
            c = dict(c, seconds=(10, 12, 8)[count % 3], composition=f'detail:{count % 3}')
            c.setdefault('base_zoom', c['zoom'])
            c['zoom'] = max(.3, c['base_zoom'] * (1, 1.08, .92)[count % 3])
            unique.setdefault((c['region'], c.get('identity')), c)
        return sorted(unique.values(), key=lambda c: (-self.score(c, now), c['region']))


def varied_plan(surface, out_dir, charted, frac, pts, candidate, variant):
    """Two endpoints give a straight eased path wholly inside a chart-checked frame envelope."""
    p = candidate['position']
    near = [q for q in pts if math.hypot(q[0] - p['x'], q[1] - p['y']) <= REACH]
    ux, uy = axis(near) if len(near) >= 2 else (1, 0)
    if variant % 3 == 2:
        ux, uy = -uy, ux
    z = (.4, .5, .6)[variant % 3]
    span = (32, 24, 16)[variant % 3]
    sign = -1 if variant % 2 else 1
    stops = [dict(x=round(p['x'] + sign * s * ux, 1), y=round(p['y'] + sign * s * uy, 1), zoom=z)
             for s in (-span / 2, span / 2)]
    # Test the bounding rectangle: for two points this covers every interpolated frame, not just the knots.
    from lookcam import frame_half, chunks
    hw, hh = frame_half(z, frac)
    x0, y0 = min(s['x'] for s in stops), min(s['y'] for s in stops)
    x1, y1 = max(s['x'] for s in stops), max(s['y'] for s in stops)
    cx0, cy0, cx1, cy1 = chunks((x0+x1)/2, (y0+y1)/2, hw+(x1-x0)/2, hh+(y1-y0)/2)
    if not all(charted(surface, x, y) for x in range(cx0, cx1+1) for y in range(cy0, cy1+1)):
        return None
    rest, secs = (3, 5, 7)[variant % 3], (30, 34, 38)[variant % 3]
    move = camerapath.check({'segments': [dict(pts=stops, t0=rest, t1=rest+secs, ease='inout')]})
    why = candidate.get('why') or 'quiet machinery'
    label = f"{planet_label(surface)} · {why} near ({round(p['x'])}, {round(p['y'])})"
    return dict(surface=surface, position={k: stops[0][k] for k in ('x', 'y')}, zoom=z, move=move,
                seconds=secs+2*rest, label=label, machines=len(near),
                scene=dict(candidate, composition=f'{variant % 6}:{z}:{rest}', why=why))


def choose(tours, memory, now, frac=1.0):
    """Replan only when asked for another scene. Candidate generation never earns shown credit."""
    charted = store_charted(tours.chart, index_charted(tours.out_dir)) if tours.chart is not None else index_charted(tours.out_dir)
    choices = []
    for surface in tours.planets:
        recipes, cells, pts = {}, {}, []
        complete = True
        for path in glob.glob(os.path.join(tours.out_dir, surface, '*.labels.json')):
            try:
                with open(path) as f:
                    rows = (json.load(f) or {}).get('recipes') or []
            except (OSError, ValueError, AttributeError):
                complete = False
                break  # a partially written chart is not a change in production
            for r in rows:
                if not isinstance(r, list) or len(r) < 2 or not position(dict(x=r[0], y=r[1])):
                    continue
                key = region(surface, dict(x=r[0], y=r[1]))
                pts.append((r[0], r[1]))
                cells.setdefault(key, []).append((r[0], r[1]))
                recipes.setdefault(key, []).append(r[:3])
        if not complete or len(pts) < MIN_MACHINES:
            continue
        for key, group in cells.items():
            if len(group) < 2:
                continue
            p = dict(x=sum(x for x, y in group)/len(group), y=sum(y for x, y in group)/len(group))
            candidate = dict(surface=surface, position=p, region=key)
            fingerprint = json.dumps(sorted(recipes.get(key, []), key=str))
            previous = tours.recipe_memory.get(key)
            if previous is not None and previous != fingerprint:
                memory.note(surface, p, 'production layout changed', fingerprint, now, now)
            tours.recipe_memory[key] = fingerprint
            choices.append((memory.score(candidate, now), candidate, pts))
        for e in memory.events.values():
            if e['surface'] == surface:
                choices.append((memory.score(e, now), dict(e), pts))
    # Tie fresh/unseen regions by surface recency, so a large planet cannot crowd out the others.
    def rank(row):
        surface = row[1]['surface']
        last = max((v[0] for k, v in memory.shown.items() if k.startswith(surface + ':')), default=-1e9)
        return (-row[0], last, PLANETS.index(surface) if surface in PLANETS else 99, row[1]['region'])

    for _, c, pts in sorted(choices, key=rank):
        old = memory.shown.get(c['region'])
        variant = sum(v[3] for v in memory.shown.values()) + (old[3] if old else 0)
        # Unchanged regions rest for ten minutes even when every quiet slot is due.
        if old and now - old[0] < 600 and (not c.get('identity') or old[1] == c['identity']):
            continue
        for offset in range(3):
            shot = varied_plan(c['surface'], tours.out_dir, charted, frac, pts, c, variant+offset)
            if shot:
                return shot
    return None  # the director's calm agent/ship/map fallback remains in charge


class Trains:
    """Train receipts from WorkFeed's existing journal tail; never asks the game for another read."""
    def __init__(self):
        self.pending, self.rows = {}, {}

    def ingest(self, agent, row):
        if not isinstance(row, dict):
            return
        q = row.get('request') or {}
        if row.get('event') == 'request' and q.get('action') == 'train':
            self.pending[(agent, q.get('id'))] = True
            if len(self.pending) > 256:
                self.pending.pop(next(iter(self.pending)))
        r = row.get('response') or {}
        if row.get('event') != 'response' or not self.pending.pop((agent, r.get('id')), False) or not r.get('ok'):
            return
        from datetime import datetime
        try:
            t = datetime.fromisoformat(row['at'].replace('Z', '+00:00')).timestamp()
        except (KeyError, ValueError, TypeError, AttributeError):
            return
        res = r.get('result') or {}
        if not isinstance(res, dict):
            return
        for tr in res.get('trains', [res]):
            if not isinstance(tr, dict):
                continue
            front = tr.get('front') or {}
            p = position(front.get('position') or front)
            surface = front.get('surface') or res.get('surface')
            if not p or not surface or type(tr.get('id')) is not int:
                continue
            stop = (tr.get('heading_to') or tr.get('at_stop') or {}).get('stop') or tr.get('stop')
            cargo = ', '.join(str(tr[k]) for k in ('cargo', 'fluids') if tr.get(k) and tr[k] != 'empty')
            if not stop and not cargo:
                continue
            key = f"{surface}:{tr['id']}"
            old = self.rows.get(key)
            if old and t <= old['t']:
                continue
            preposition = 'at' if tr.get('at_stop') or tr.get('state') == 'wait_station' else 'to'
            self.rows[key] = dict(id=key, number=tr['id'], surface=surface, position=p, t=t,
                                  speed=tr.get('speed_kmh') or 0, stop=stop, cargo=cargo,
                                  label=f"Train {tr['id']} · " + (f"{preposition} {stop}" if stop else 'cargo route') +
                                        (f" · {cargo[:90]}" if cargo else ' · scheduled service'))
        self.rows = dict(sorted(self.rows.items(), key=lambda kv: kv[1]['t'])[-64:])

    def current(self, now):
        # At 100 km/h a train crosses a normal frame in seconds. Sparse journals cannot support a long follow.
        return [dict(r) for r in self.rows.values() if 0 <= now-r['t'] <= (3 if r['speed'] else 12)]
