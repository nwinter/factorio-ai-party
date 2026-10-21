"""Where the asteroids get dense on the legs to and from the solar system edge (d20 batch57 S3, viewer Foobator, shift48
operator inbox 17:40: "if a ship reaches the dense part of edge asteroids, can you switch to it?"). Pure; onecam.py's
maybe_edge cuts to a platform once per leg when it enters that part.

The numbers are Factorio 2.0.77 + Space Age's, read once on the private headless copy (d20 17:50, pog-b41-headless):
prototypes.space_connection[name].asteroid_spawn_definitions, the asteroids that are entities (big and huge; the chunks
are what collectors pick up), each a list of (distance from the connection's `from`, 0..1; spawn probability), and
prototypes.entity[name].get_max_health(). A leg's density at a distance is the sum over its asteroids of probability x
max health (linear between the points): the hit points the guns face per unit of travel. Its dense part is where that is
at least DENSE_FRACTION of the leg's peak:
  aquilo -> solar-system-edge (100,000 km): 5.8 at 10%, 9.3 at 30%, 10.0 at 40%, 12.5 at 90% (the peak; huge asteroids
  rise from none at 10% to 0.0025 at 90%), 0 at the end: dense from 39.7% to 91.9% of the way from Aquilo (from the
  edge: 8.1% to 60.3%).
  solar-system-edge -> shattered-planet (4,000,000 km): 12.5 at 0.1%, 243 at 20%, 928 at 40%, 1164 at 99.9% (huge
  promethium): dense from 76.5% to 99.9% of the way from the edge.
"""

DENSE_FRACTION = 0.8

HEALTH = {"big-metallic-asteroid": 2000, "big-carbonic-asteroid": 2000, "big-oxide-asteroid": 2000,
          "huge-metallic-asteroid": 5000, "huge-carbonic-asteroid": 5000, "huge-oxide-asteroid": 5000,
          "huge-promethium-asteroid": 10000}

# connection -> (from, to, {asteroid: [(distance, probability)]})
SPAWN = {
    "aquilo-solar-system-edge": ("aquilo", "solar-system-edge", {
        "big-metallic-asteroid": [(0, 0), (0.1, 0.000125), (0.2, 0.0004375), (0.3, 0.0009375), (0.4, 0.0015625), (0.5, 0.00125),
                                  (0.6, 0.0009375), (0.7, 0.000625), (0.8, 0.0001875), (0.9, 0), (1, 0)],
        "big-carbonic-asteroid": [(0, 0), (0.1, 0.00025), (0.2, 0.00065625), (0.3, 0.00046875), (0.4, 0.000260417), (0.5, 0.000555556),
                                  (0.6, 0.000520833), (0.7, 0.000138889), (0.8, 0.0003125), (0.9, 0), (1, 0)],
        "big-oxide-asteroid": [(0, 0), (0.1, 0.0025), (0.2, 0.0021875), (0.3, 0.001875), (0.4, 0.00104167), (0.5, 0.000416667),
                               (0.6, 0.000208333), (0.7, 0.000486111), (0.8, 6.25e-05), (0.9, 0), (1, 0)],
        "huge-metallic-asteroid": [(0, 0), (0.1, 0), (0.2, 3.125e-05), (0.3, 0.00015625), (0.4, 0.00046875), (0.5, 0.000625),
                                   (0.6, 0.00078125), (0.7, 0.0009375), (0.8, 0.00065625), (0.9, 0.00075), (1, 0)],
        "huge-carbonic-asteroid": [(0, 0), (0.1, 0), (0.2, 4.6875e-05), (0.3, 7.8125e-05), (0.4, 7.8125e-05), (0.5, 0.000277778),
                                   (0.6, 0.000434028), (0.7, 0.000208333), (0.8, 0.00109375), (0.9, 0.00125), (1, 0)],
        "huge-oxide-asteroid": [(0, 0), (0.1, 0), (0.2, 0.00015625), (0.3, 0.0003125), (0.4, 0.0003125), (0.5, 0.000208333),
                                (0.6, 0.000173611), (0.7, 0.000729167), (0.8, 0.00021875), (0.9, 0.0005), (1, 0)]}),
    "solar-system-edge-shattered-planet": ("solar-system-edge", "shattered-planet", {
        "huge-metallic-asteroid": [(0, 0), (0.001, 0.00075), (0.002, 0.000815982), (0.2, 0.0144588), (0.3, 0.011377), (0.4, 0.045128),
                                   (0.5, 0.0323177), (0.6, 0.00414333), (0.7, 0.0104107), (0.8, 0.00261082), (0.999, 0.00676705), (1, 0)],
        "huge-carbonic-asteroid": [(0, 0), (0.001, 0.00125), (0.002, 0.00135997), (0.2, 0.00867526), (0.3, 0.034131), (0.4, 0.0386811),
                                   (0.5, 0.0071817), (0.6, 0.01243), (0.7, 0.00260266), (0.8, 0.00783246), (0.999, 0.00135341), (1, 0)],
        "huge-oxide-asteroid": [(0, 0), (0.001, 0.0005), (0.002, 0.000543988), (0.2, 0.023134), (0.3, 0.0151693), (0.4, 0.0193406),
                                (0.5, 0.0179543), (0.6, 0.0165733), (0.7, 0.00650666), (0.8, 0.00348109), (0.999, 0.00270682), (1, 0)],
        "huge-promethium-asteroid": [(0, 0), (0.001, 0), (0.002, 6.79985e-06), (0.2, 0.0011567), (0.3, 0.00769844), (0.4, 0.0412599),
                                     (0.5, 0.056125), (0.6, 0.067122), (0.7, 0.078119), (0.8, 0.089116), (0.999, 0.111), (1, 0)]}),
}


def _at(points, d):
    for (d0, p0), (d1, p1) in zip(points, points[1:]):
        if d0 <= d <= d1:
            return p0 if d1 == d0 else p0 + (p1 - p0) * (d - d0) / (d1 - d0)
    return 0.0


def density(conn, d):
    """Hit points of big and huge asteroids spawned per unit of travel at distance d (0..1 from the connection's from)."""
    return sum(_at(pts, d) * HEALTH[name] for name, pts in SPAWN[conn][2].items())


def dense_span(conn, step=0.001):
    """(d0, d1): the first and last distance (from the connection's from) where density >= DENSE_FRACTION of its peak."""
    ds = [round(k * step, 6) for k in range(int(round(1 / step)) + 1)]
    vals = [density(conn, d) for d in ds]
    cut = DENSE_FRACTION * max(vals)
    inside = [d for d, v in zip(ds, vals) if v >= cut]
    return inside[0], inside[-1]


SPANS = {conn: dense_span(conn) for conn in SPAWN}


def trip_span(origin, dest):
    """The dense part of the leg from origin to dest as percent of the way from origin (lo, hi), or None (no edge leg)."""
    for conn, (a, b, _) in SPAWN.items():
        d0, d1 = SPANS[conn]
        if (origin, dest) == (a, b):
            return 100 * d0, 100 * d1
        if (origin, dest) == (b, a):
            return 100 * (1 - d1), 100 * (1 - d0)
    return None


def leg(row):
    """(origin, dest) of a platform row (model.platform_where: route_ids, route pct) on an edge leg, else None."""
    ids = (row or {}).get("route_ids") if (row or {}).get("route") else None
    if not ids or len(ids) != 2 or trip_span(ids[0], ids[1]) is None:
        return None
    return ids[0], ids[1]


def in_dense(row):
    """The platform row's progress is in its edge leg's dense part."""
    lg = leg(row)
    pct = ((row or {}).get("route") or {}).get("pct")
    if not lg or not isinstance(pct, (int, float)):
        return False
    lo, hi = trip_span(*lg)
    return lo <= pct <= hi
