#!/usr/bin/env python3
"""Which director clients a shift runs (POG_CAMS), for start-team.sh, start-cams.sh and the stream service.

  python3 tools/cams.py list       # "cam1 cam2 cam3" (POG_CAMS=1: "cam1")
  python3 tools/cams.py count      # 3 (POG_CAMS=1: 1): POG_EXPECT_CAMS, the watchdog's expected client count
  python3 tools/cams.py slots      # the stream.json "cameras" list: [{"slot": "main", "player": 1}, ...]

POG_CAMS is a count (1-3: cam1 .. camN) or names ("cam1 cam3": a subset when the box is short of memory, 2026-10-14
19:30); unset: all three. Sunday 2026-10-18 Nick plays his own Factorio on the box, so the stream runs on cam1 alone
(POG_CAMS=1): the director moves that one client between subjects instead of cutting between clients, no inset, no
trio. cam1 is always the slot "main" (OBS "stream cam1", the one with game audio); camN is the slot "camN".
"""
import json, os, sys

ALL = ("cam1", "cam2", "cam3")


def cams(value=None):
    """POG_CAMS -> the cameras in order, e.g. ["cam1"]. Anything unknown falls back to all three."""
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
    return [{"slot": slot(c), "player": int(c[3:])} for c in cams(value)]  # (no cam1: the first listed is on air)


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
    else:
        sys.exit("usage: tools/cams.py list|count|slots")
