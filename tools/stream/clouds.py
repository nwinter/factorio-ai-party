"""Pollution and spores on the map (viewer Joonazan, 13:00 on 2026-10-14: "can you show a shot of Gleba's spore
cloud?"; operator task 13:05).

The harness's chart sweep (threat.lua, about once a game minute on each surface an agent is on) reads every charted
chunk's pollution, or spores on Gleba; the operator read `clouds` hands them over and live.py reads it every minute.

- normalise(rows): one row per surface with a cloud: {surface, label ("Spores on Gleba"), pollutant, color (the game's
  map colour, rgba 0..255 / 0..1), cells [[cx, cy, amount]] (32-tile chunks), chunks, max, total, tick, reached}.
- shot(cloud): where a map camera (cameras.lua `map`, the chart) frames the cloud and how far it zooms out, for the
  hole the program shows it in (mapcam.py's client and crop).
- onecam.py's cloud shot: the operator calls it (serve.py POST /cloud), and the director picks it on its own once in a
  while when the cloud reaches nests it had not reached before (pentapods on Gleba, biters on Nauvis).
- The overlay (static/overlay.js) and the site's map (site/static/mapview.js) draw the cells in the pollutant's colour.
"""
import math

from mapcam import CLIENT

# prototypes.airborne_pollutant[...].chart_color on world n (2026-10-14): the colours the read carries, for a read
# without them
COLORS = {"pollution": {"r": 0.549, "g": 0.0, "b": 0.0, "a": 0.584}, "spores": {"r": 0.549, "g": 0.549, "b": 0.0, "a": 0.584}}
NAMES = {"pollution": "Pollution", "spores": "Spores"}
CHUNK = 32


def planet(surface):
    s = str(surface or "").replace("-", " ").replace("_", " ")
    return s[:1].upper() + s[1:]


def color(pollutant):
    """The pollutant's map colour as {r, g, b, a} (0..1) and css "rgb(140, 0, 0)"."""
    c = dict(COLORS.get((pollutant or {}).get("name"), COLORS["pollution"]))
    got = (pollutant or {}).get("color")
    if isinstance(got, dict) and all(isinstance(got.get(k), (int, float)) for k in "rgb"):
        c = {k: float(got.get(k, c.get(k, 1.0))) for k in "rgba"}
        if max(c["r"], c["g"], c["b"]) > 1:  # 0..255 colours
            c = {k: v / 255.0 if k != "a" or v > 1 else v for k, v in c.items()}
    c = {k: round(v, 3) for k, v in c.items()}
    c["css"] = "rgb(%d, %d, %d)" % tuple(round(255 * c[k]) for k in "rgb")
    return c


def normalise(rows):
    """The `clouds` read's rows -> {surface: row}; a surface without a pollutant (Vulcanus, Fulgora) or without a
    polluted chunk is left out."""
    out = {}
    for r in rows or []:
        if not isinstance(r, dict) or not r.get("surface"):
            continue
        cells = [c for c in (r.get("cells") if isinstance(r.get("cells"), list) else [])
                 if isinstance(c, list) and len(c) >= 3 and all(isinstance(v, (int, float)) for v in c[:3]) and c[2] > 0]
        pol = r.get("pollutant") if isinstance(r.get("pollutant"), dict) else None
        if not cells or not pol:
            continue
        name = pol.get("name") or "pollution"
        reached = [n for n in (r.get("reached") if isinstance(r.get("reached"), list) else [])
                   if isinstance(n, dict) and isinstance(n.get("position"), dict)]
        out[r["surface"]] = {
            "surface": r["surface"], "pollutant": name,
            "label": f"{NAMES.get(name, planet(name))} on {planet(r['surface'])}",
            "color": color(pol), "cells": [[int(c[0]), int(c[1]), round(float(c[2]), 1)] for c in cells],
            "chunks": len(cells), "max": round(max(c[2] for c in cells), 1),
            "total": round(sum(c[2] for c in cells)), "tick": r.get("tick"),
            "reached": [{"x": n["position"].get("x"), "y": n["position"].get("y"), "tick": n.get("tick"),
                         "spawners": n.get("spawners")} for n in reached],
        }
    return out


def reached_keys(cloud):
    """The nests a cloud reached, as keys that stay the same between reads."""
    return {(cloud["surface"], round(n["x"] or 0), round(n["y"] or 0)) for n in cloud.get("reached") or []}


def shot(cloud, hole=(1208, 1032), frac=None, margin=1, min_zoom=0.01, max_zoom=0.5):
    """A cloud -> {"position": {x, y}, "zoom", "size": [w, h] tiles} that shows every polluted chunk and every nest it
    reached (a margin of chunks around), or None. As mapcam.map_shot: 1920 px across at zoom z show 1920 / (32 z)
    tiles, and the hole shows `frac` of the client's width."""
    cells = (cloud or {}).get("cells") or []
    if not cells:
        return None
    xs = [c[0] for c in cells] + [math.floor((n["x"] or 0) / CHUNK) for n in cloud.get("reached") or []]
    ys = [c[1] for c in cells] + [math.floor((n["y"] or 0) / CHUNK) for n in cloud.get("reached") or []]
    x0, x1 = (min(xs) - margin) * CHUNK, (max(xs) + 1 + margin) * CHUNK
    y0, y1 = (min(ys) - margin) * CHUNK, (max(ys) + 1 + margin) * CHUNK
    w, h = x1 - x0, y1 - y0
    if frac is None:
        frac = min(1.0, (hole[0] / hole[1]) / (CLIENT[0] / CLIENT[1]))
    z = min(CLIENT[0] * frac / (32.0 * w), CLIENT[1] / (32.0 * h))
    # rounded down to what director.apply sends (2 decimals): rounded up, 0.117 -> 0.12 cut the frame's edges off
    return {"position": {"x": (x0 + x1) / 2, "y": (y0 + y1) / 2},
            "zoom": max(min_zoom, min(max_zoom, math.floor(z * 100) / 100)), "size": [w, h]}
