#!/usr/bin/env python3
"""Which director clients a shift runs (POG_CAMS), for start-team.sh, start-cams.sh and the stream service.

  python3 tools/cams.py list       # "cam1 cam2 cam3" (POG_CAMS=1: "cam1")
  python3 tools/cams.py count      # 3 (POG_CAMS=1: 1): POG_EXPECT_CAMS, the watchdog's expected client count
  python3 tools/cams.py panels     # POG_CAM_PANELS as a count: 0 (off), 1 or 2
  python3 tools/cams.py slots      # the stream.json "cameras" list: [{"slot": "main", "player": 1}, ...]
                                   # (POG_CAM_PANELS=2: main, then cam2 and cam3 as panels of player 1)

POG_CAMS is a count (1-3: cam1 .. camN) or names ("cam1 cam3": a subset when the box is short of memory, 2026-10-14
19:30); unset: all three. Sunday 2026-10-18 Nick plays his own Factorio on the box, so the stream runs on cam1 alone
(POG_CAMS=1): the director moves that one client between subjects instead of cutting between clients, no inset, no
trio. cam1 is always the slot "main" (OBS "stream cam1", the one with game audio); camN is the slot "camN".

POG_CAM_PANELS (d27 batch285 B, off by default): 1 or 2 camera panels, GUI camera elements in cam1's own client
(cameras.lua), instead of the clients cam2 and cam3: the shift runs cam1 alone (a second client took 4-5.5 GB and slowed
world n, batch285 A) and the slots cam2 (panel 1) and cam3 (panel 2) are views drawn by cam1. Each panel sits in a strip
that OBS crops off cam1's on-air picture (the right strip, then the left), 16:9 at the strip's width, and OBS captures
it from cam1's window into the inset. The director uses panels for insets only, never on air (onecam.py).
"""
import json, os, sys

ALL = ("cam1", "cam2", "cam3")
HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = os.path.join(HERE, "stream", "static", "layout.json")
CLIENT = (2880, 1620)  # cam1's window in pixels (its display_resolution in world n, d27; display scale 1.5)


def panels(value=None):
    """POG_CAM_PANELS -> how many camera panels (0-2; anything else 0)."""
    v = str(os.environ.get("POG_CAM_PANELS", "") if value is None else value).strip()
    return int(v) if v in ("1", "2") else 0


def panel_rects(n, client=CLIENT, layout=None):
    """[x, y, w, h] in cam1's window pixels for panels 1..n: 16:9 across the strips the main hole's crop leaves off
    (the right strip, then the left), at the top."""
    lay = layout or json.load(open(LAYOUT))
    _, _, hw, hh = lay["cams"]["main"]
    cw, ch = client
    strip = int(round((cw - ch * hw / hh) / 2))
    assert strip >= 160, f"the main hole leaves {strip} px strips: too narrow for a panel"
    w, h = strip, int(round(strip * 9 / 16))
    return [[cw - w, 0, w, h], [0, 0, w, h]][:n]


def cams(value=None):
    """POG_CAMS -> the cameras in order, e.g. ["cam1"]. Anything unknown falls back to all three."""
    if panels():
        return ["cam1"]  # the panels are drawn by cam1: no other client
    v = str(os.environ.get("POG_CAMS", "") if value is None else value).strip()
    if not v:
        return list(ALL)
    if v.isdigit():
        n = int(v)
        return list(ALL[:n]) if 1 <= n <= len(ALL) else list(ALL)
    out = [c for c in ALL if c in v.replace(",", " ").split()]
    return out or list(ALL)


def slot(cam):
    return "main" if cam == "cam1" else cam


def slots(value=None):
    """The director's slots, main first: [{"slot": "main", "player": 1}, {"slot": "cam3", "player": 3}, ...]. The
    player index is the camera's number (pog-camN is player N to the harness camera function)."""
    out = [{"slot": slot(c), "player": int(c[3:])} for c in cams(value)]  # (no cam1: the first listed is on air)
    n = panels()
    if n:  # cam2 and cam3 are panels drawn by cam1 (player 1)
        # scale: the panel's width over the window's, the factor that makes a panel show what a whole client shows at
        # a zoom (if a GUI camera's zoom means what the player's does: to check on a client)
        out += [{"slot": f"cam{i + 2}", "player": 1, "panel": i + 1, "rect": r, "scale": round(r[2] / CLIENT[0], 3)}
                for i, r in enumerate(panel_rects(n))]
    return out


def panel_sources(value=None):
    """{OBS capture: [x, y, w, h]} of the camera panels (POG_CAM_PANELS), e.g. {"stream cam2": [2388, 0, 492, 277]}."""
    return {source(s["slot"]): s["rect"] for s in slots(value) if s.get("panel")}


def source(slot_name):
    """The OBS capture of a director slot: main -> "stream cam1", camN -> "stream camN"."""
    return "stream cam1" if slot_name == "main" else f"stream {slot_name}"


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "list"
    if what == "list":
        print(" ".join(cams()))
    elif what == "count":
        print(len(cams()))
    elif what == "slots":
        print(json.dumps(slots()))
    elif what == "panels":
        print(panels())
    else:
        sys.exit("usage: tools/cams.py list|count|slots|panels")
