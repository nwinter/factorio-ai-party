"""What the tour shows over the camera (d23 batch128 CK3-CK5, Nick 17:30: "controls for annotating the screen, show the
narration subtitles on the screen as we go"): marks at map positions, the narration's captions, an old clip. tour.py
posts one entry a stop ahead of its cut; the page (static/tourlay.js) draws the entry whose time it is, in the camera
hole, from the snapshot's `tour`.

POST /tour/overlay {id, cut, until, length, view {surface, position {x, y}, zoom, move?}, marks?, subs?, subs_at?,
subs_pos?, clip?} (subs: the narration's captions [{t0, t1, text}], seconds from subs_at, the narration's moment;
subs_pos bottom or top):
times are epoch seconds (until: the entry's last moment; the next stop's entry takes over at its own cut), length the
stop's seconds ("end" in a mark's times); marks' and subs' from_s/to_s are seconds from the cut (the page takes the look's `aired` for the cut
when the look on air has this id). DELETE /tour/overlay ends them all. At most KEEP entries, each gone at its until.

A mark (MARKS): {type: arrow | circle | box | label, at {x, y}, text?, from_s?, to_s?, color?} plus, by type:
arrow `from` (a compass point n, ne, e, se, s, sw, w, nw for the tail's side, default nw, or a map spot {x, y}) and
`length` (px, default 110); circle `radius` (tiles, default 6); box `w`, `h` (tiles, default 12). Map positions are
on the stop's surface (a ship's: platform tiles).
"""
import math

import camerapath

KEEP = 3
MAX_MARKS = 12
MARKS = ("arrow", "circle", "box", "label")
COLORS = {"orange": "#ff9f1c", "yellow": "#ffe14d", "red": "#ff5a44", "green": "#7bd389", "blue": "#58a6ff",
          "white": "#f2f2f2"}
COMPASS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
MAX_TEXT = 60


def _num(v, what, lo=None, hi=None):
    v = camerapath.number(v, what)
    if (lo is not None and v < lo) or (hi is not None and v > hi):
        raise ValueError(f"{what} must be {lo:g}..{hi:g}")
    return v


def _spot(p, what):
    if not isinstance(p, dict):
        raise ValueError(f"{what} must be a map spot {{x, y}}")
    return {"x": round(_num(p.get("x"), f"{what} x"), 2), "y": round(_num(p.get("y"), f"{what} y"), 2)}


def check_mark(m, i=0):
    """A mark checked -> the mark (normalised), or ValueError with why."""
    what = f"mark {i + 1}"
    if not isinstance(m, dict) or m.get("type") not in MARKS:
        raise ValueError(f"{what}: type must be one of {', '.join(MARKS)}")
    out = {"type": m["type"], "at": _spot(m.get("at"), f"{what} at")}
    text = " ".join(str(m.get("text") or "").split())
    if len(text) > MAX_TEXT:
        raise ValueError(f"{what}: text is at most {MAX_TEXT} characters")
    if m["type"] == "label" and not text:
        raise ValueError(f"{what}: a label needs text")
    if text:
        out["text"] = text
    for k in ("from_s", "to_s"):
        if m.get(k) is not None:
            out[k] = "end" if m[k] == "end" else round(_num(m[k], f"{what} {k}"), 2)
    c = m.get("color", "orange")
    if c not in COLORS and not (isinstance(c, str) and len(c) == 7 and c.startswith("#")):
        raise ValueError(f"{what}: color is {', '.join(COLORS)} or #rrggbb")
    out["color"] = COLORS.get(c, c)
    if m["type"] == "arrow":
        f = m.get("from", "nw")
        out["from"] = f if f in COMPASS else _spot(f, f"{what} from")
        out["length"] = round(_num(m.get("length", 110), f"{what} length", 30, 400))
    elif m["type"] == "circle":
        out["radius"] = round(_num(m.get("radius", 6), f"{what} radius", 0.5, 200), 2)
    elif m["type"] == "box":
        out["w"] = round(_num(m.get("w", 12), f"{what} w", 1, 400), 2)
        out["h"] = round(_num(m.get("h", 12), f"{what} h", 1, 400), 2)
    return out


def check_marks(marks):
    if marks is None:
        return []
    if not isinstance(marks, list) or len(marks) > MAX_MARKS:
        raise ValueError(f"marks is a list of at most {MAX_MARKS}")
    return [check_mark(m, i) for i, m in enumerate(marks)]


def check_subs(subs, at, pos, cut):
    """(CK4) The narration's captions: [{t0, t1, text}] in seconds from `at` (the narration's moment, epoch)."""
    if not isinstance(subs, list) or len(subs) > 300:
        raise ValueError("subs is a list of at most 300 {t0, t1, text}")
    out = []
    for i, c in enumerate(subs):
        if not isinstance(c, dict) or not str(c.get("text") or "").strip():
            raise ValueError(f"subs {i + 1}: {{t0, t1, text}}")
        t0, t1 = _num(c.get("t0"), f"subs {i + 1} t0", 0, 900), _num(c.get("t1"), f"subs {i + 1} t1", 0, 900)
        out.append({"t0": round(t0, 2), "t1": round(max(t0, t1), 2), "text": " ".join(str(c["text"]).split())[:200]})
    at = _num(at, "subs_at")
    if not cut - 5 <= at <= cut + 60:
        raise ValueError("subs_at is the narration's moment, epoch seconds near the cut")
    if pos not in ("bottom", "top"):
        raise ValueError("subs_pos is bottom or top")
    return {"subs": out, "subs_at": round(at, 3), "subs_pos": pos}


def mark_times(m, length):
    """(from, to) in seconds from the cut over a stop of `length` s ("end" and negatives count from its end)."""
    def when(v, default):
        if v is None:
            return default
        if v == "end":
            return length
        return length + v if v < 0 else v
    return when(m.get("from_s"), 0.0), when(m.get("to_s"), length)


class TourOverlay:
    def __init__(self):
        self.entries = []

    def post(self, body, now):
        """-> (http code, reply)."""
        if not isinstance(body, dict) or not str(body.get("id") or "").strip():
            return 400, {"error": "expected {id, cut, until, view, marks?, subs?, clip?}"}
        try:
            cut, until = _num(body.get("cut"), "cut"), _num(body.get("until"), "until")
            if not now - 60 <= cut <= now + 60 or not cut < until <= cut + 900:
                raise ValueError("cut is epoch seconds within a minute of now, until after it (at most 15 min)")
            v = body.get("view") or {}
            view = {"surface": str(v.get("surface") or ""), "position": _spot(v.get("position"), "view position"),
                    "zoom": _num(v.get("zoom"), "view zoom", 0.05, 4)}
            if v.get("move"):
                view["move"] = camerapath.check(v["move"])
            length = _num(body.get("length", until - cut), "length", 0, 900)
            entry = {"id": str(body["id"])[:80], "cut": round(cut, 3), "until": round(until, 3),
                     "length": round(length, 3), "view": view, "marks": check_marks(body.get("marks"))}
            if body.get("subs"):
                entry.update(check_subs(body["subs"], body.get("subs_at"), body.get("subs_pos", "bottom"), cut))
            if body.get("clip") is not None:  # (CK5: tour.py checks it)
                entry["clip"] = body["clip"]
        except ValueError as x:
            return 400, {"error": str(x)}
        self.entries = [e for e in self.entries if e["id"] != entry["id"] and e["until"] > now][-(KEEP - 1):] + [entry]
        return 200, {"id": entry["id"], "marks": len(entry["marks"])}

    def clear(self):
        self.entries = []
        return 200, {"tour": None}

    def public(self, now):
        self.entries = [e for e in self.entries if e["until"] > now]
        return list(self.entries) or None


def frame_check(view, mark, t, frac):
    """Whether a mark's spot is in the on-air frame at t seconds from the cut (the view moving with its move); the
    frame as lookcam.frame_half sees it."""
    from lookcam import frame_half
    if view.get("move"):
        x, y, z = camerapath.at(view["move"], t)
    else:
        x, y, z = view["position"]["x"], view["position"]["y"], view["zoom"]
    hw, hh = frame_half(z, frac)
    a = mark["at"]
    return abs(a["x"] - x) <= hw and abs(a["y"] - y) <= hh


def offscreen(view, marks, length, frac):
    """[(mark index, seconds from the cut)] for marks whose spot is out of the frame while they show (sampled)."""
    out = []
    for i, m in enumerate(marks):
        t0, t1 = mark_times(m, length)
        n = max(1, int(math.ceil((t1 - t0) / 2.0)))
        for k in range(n + 1):
            t = t0 + (t1 - t0) * k / n
            if not frame_check(view, m, t, frac):
                out.append((i, round(t, 1)))
                break
    return out
