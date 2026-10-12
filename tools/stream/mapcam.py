"""The base on Factorio's own map (operator task 2026-10-12; a viewer: "kind wish there was a map in one of them at times
to see the overall base layout"): where to centre a map camera and how far to zoom out.

The framing comes from the snapshot's `basemap` (harness.BASEMAP_LUA, read every few minutes for the site's live map):
a coarse grid of the team's buildings, each cell its most notable kind. Lines (belts, inserters, pipes: B, P) alone
do not count, so a 500-tile oil pipeline (shift01) does not stretch the frame on its own, but the outpost at its end
does: every group of building cells counts, the dense core and the outposts. The map camera (cameras.lua `map`) is
the remote controller, which renders the chart below its chart-mode cutoff: 1920 px across at zoom z show
1920 / (32 z) tiles, as in the world view.
"""

LINES = set("BP.")  # belts and inserters, pipes; empty
CLIENT = (1920, 1080)


def map_shot(basemap, hole=(1208, 1032), frac=None, margin=1, min_zoom=0.02, max_zoom=0.5):
    """basemap -> {"position": {x, y}, "zoom", "size": [w, h] tiles, "groups"} or None (no buildings yet).
    hole: the program's hole the client is shown in (its crop: the share of the client's width shown, `frac`)."""
    if not basemap or not basemap.get("rows"):
        return None
    c, x0, y0 = basemap.get("cell") or 8, basemap.get("x0") or 0, basemap.get("y0") or 0
    cells = {(i, j) for j, row in enumerate(basemap["rows"]) for i, ch in enumerate(row) if ch not in LINES}
    if not cells:
        return None
    # groups of building cells (8-neighbours), so the outposts are known; a single stray cell is no outpost unless it
    # is a drill or an oil building
    groups, seen = [], set()
    for start in cells:
        if start in seen:
            continue
        stack, g = [start], []
        seen.add(start)
        while stack:
            i, j = stack.pop()
            g.append((i, j))
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    n = (i + di, j + dj)
                    if n in cells and n not in seen:
                        seen.add(n)
                        stack.append(n)
        groups.append(g)
    keep = [g for g in groups if len(g) > 1 or basemap["rows"][g[0][1]][g[0][0]] in "MO"]
    keep = keep or groups
    pts = [p for g in keep for p in g]
    i0, i1 = min(p[0] for p in pts) - margin, max(p[0] for p in pts) + 1 + margin
    j0, j1 = min(p[1] for p in pts) - margin, max(p[1] for p in pts) + 1 + margin
    w, h = (i1 - i0) * c, (j1 - j0) * c
    cx, cy = x0 + (i0 + i1) / 2 * c, y0 + (j0 + j1) / 2 * c
    if frac is None:  # the share of the client's width the hole shows after its centre crop (cuts.view_frac)
        frac = min(1.0, (hole[0] / hole[1]) / (CLIENT[0] / CLIENT[1]))
    z = min(CLIENT[0] * frac / (32.0 * w), CLIENT[1] / (32.0 * h))
    return {"position": {"x": round(cx, 1), "y": round(cy, 1)}, "zoom": round(max(min_zoom, min(max_zoom, z)), 3),
            "size": [w, h], "groups": len(keep)}
