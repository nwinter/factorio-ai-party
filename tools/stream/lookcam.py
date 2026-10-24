"""Operator position shot: POST /look {surface, x, y, zoom?, seconds?, label?, by?}, DELETE /look (viewers asked twice
on d16: LimeLight555 the upcycler 11:33, the western wall 12:24).

  curl -X POST http://127.0.0.1:8788/look -d '{"surface": "nauvis", "x": -180, "y": 40, "seconds": 30,
                                              "label": "The western wall", "by": "operator"}'
  curl -X DELETE http://127.0.0.1:8788/look

The main camera shows that spot (a fixed view, exact zoom) for `seconds` (at most 60, default 30), then the director
returns to what it was doing. surface: a surface name (nauvis, vulcanus, platform-3, any case) or one of our
platforms' names. zoom: 0.3..3 (default 0.75; higher is closer).

(d23 batch128 CK1, the tour) More fields, all optional: platform (one of our ships by name, in place of surface, x
and y: the director's own framing of the whole ship at the moment of the request, no chart read; with x and y given
as well, that spot on its deck), cut_at (epoch seconds, now..now+30: a standby frames the spot at once and the
program cuts to it at that moment; one client moves then; the shot on air until then stays), id (the caller's tag,
echoed in the snapshot's look). The snapshot's look says `aired`, when the program first showed it. POST /look/extend
{seconds, id?} moves the current look's end to now + seconds (at most 60) with no chart read (the tour's renewals).

Only charted ground: before the shot, one read (CHART_LUA, a few dozen is_chunk_charted calls for the frame on air)
checks that every 32-tile chunk the on-air frame covers is charted by the team; otherwise 409 with the reason (the
spot's own chunk, or how many of the frame's chunks are not charted: a closer zoom frames fewer). An unknown surface
is 400. A hand-written file is checked the same way when it is read.

Kept in runs/RUN/director-look.json ({surface, position, zoom, until, label, by}; until is epoch seconds), so a
serve.py restart keeps it; writing or deleting the file by hand works too. Precedence: a look takes the camera from
an operator /platform hold and from an operator /follow; either one resumes when the look ends if its deadline has not
passed. Like those, other urgent events go in the inset, and segments, cues, rotation, the trio, base map, cloud and
platform shots and new replays wait; POST /cloud is refused while a look is on.
"""
import json, math, os, time

MAX_S = 60.0
DEFAULT_S = 30.0
MIN_ZOOM, MAX_ZOOM, DEFAULT_ZOOM = 0.3, 3.0, 0.75  # cameras.lua takes 0.3..4; the director caps at max_zoom 3
CHUNK = 32.0
EDGE = 2.0  # tiles at the frame's border not counted (director.in_frame's edge)


def frame_half(zoom, frac):
    """Half the on-air frame in tiles (director.CLIENT: 1920 x 1080 px, 32 px a tile at zoom 1, frac of the width)."""
    from director import CLIENT
    tile = 32.0 * zoom
    return max(1.0, CLIENT[0] / tile / 2 * frac - EDGE), max(1.0, CLIENT[1] / tile / 2 - EDGE)


def chunks(x, y, hw, hh):
    """The chunk ranges (cx0, cy0, cx1, cy1) the frame around (x, y) touches."""
    return (math.floor((x - hw) / CHUNK), math.floor((y - hh) / CHUNK),
            math.floor((x + hw) / CHUNK), math.floor((y + hh) / CHUNK))


# Read-only, operator level like harness.PLATFORM_LUA: the team's chart over the frame (at zoom 0.3 about 8 x 5 chunks)
CHART_LUA = r"""
local f = game.forces.player
local s = game.get_surface(_SURF_)
if not s then rcon.print('{"surface":false}') return end
local n, k = 0, 0
for cx = _CX0_, _CX1_ do
  for cy = _CY0_, _CY1_ do
    n = n + 1
    if f.is_chunk_charted(s, {cx, cy}) then k = k + 1 end
  end
end
local c = {math.floor(_X_ / 32), math.floor(_Y_ / 32)}
rcon.print(helpers.table_to_json{surface = true, chunks = n, charted = k, center = f.is_chunk_charted(s, c),
  visible = f.is_chunk_visible(s, c)})
"""


def chart_lua(surface, x, y, hw, hh):
    from harness import lua_string
    cx0, cy0, cx1, cy1 = chunks(x, y, hw, hh)
    out = CHART_LUA
    for k, v in (("_CX0_", cx0), ("_CX1_", cx1), ("_CY0_", cy0), ("_CY1_", cy1), ("_X_", repr(float(x))),
                 ("_Y_", repr(float(y))), ("_SURF_", lua_string(surface))):
        out = out.replace(k, str(v))
    return out


def harness_chart(h):
    """chart(surface, x, y, hw, hh) -> {surface, chunks, charted, center, visible} through a Harness (harness.py)."""
    return lambda surface, x, y, hw, hh: h.lua(chart_lua(surface, x, y, hw, hh))


def mock_chart(surface, x, y, hw, hh):
    """serve.py --mock: no game, so every spot counts as charted."""
    cx0, cy0, cx1, cy1 = chunks(x, y, hw, hh)
    n = (cx1 - cx0 + 1) * (cy1 - cy0 + 1)
    return {"surface": True, "chunks": n, "charted": n, "center": True, "visible": True}


def number(v):
    if isinstance(v, bool):
        raise ValueError()
    v = float(v)
    if not math.isfinite(v):
        raise ValueError()
    return v


class LookControl:
    def __init__(self, director, path=None, chart=None):
        """chart: (surface, x, y, half_w, half_h) -> {surface, chunks, charted, center, visible}; None: no game to
        ask (every look is refused)."""
        self.director, self.path, self.chart, self.mtime = director, path, chart, None

    def surface_of(self, name):
        """A surface name as given (planets lower-case), or the surface of one of our platforms named so."""
        n = str(name or "").strip()
        rows = getattr(self.director, "plat_rows", {}) or {}
        for pname, row in rows.items():
            if pname.casefold() == n.casefold() and ((row.get("view") or {}).get("surface")):
                return row["view"]["surface"], pname
        return (n.lower() if n.lower() in ("nauvis", "vulcanus", "gleba", "fulgora", "aquilo") else n), None

    def check(self, surface, x, y, zoom):
        """-> (None, chart reply) when the whole on-air frame is charted, else ((http code, reply), None)."""
        if not self.chart:
            return (409, {"error": "no game read for the chart check (look needs the live service)"}), None
        hw, hh = frame_half(zoom, self.director.cfg["view_frac"])
        try:
            c = self.chart(surface, x, y, hw, hh)
        except Exception as e:
            return (503, {"error": f"chart check failed: {type(e).__name__}: {e}"}), None
        if not isinstance(c, dict) or not c.get("surface"):
            return (400, {"error": f"no surface {surface!r}"}), None
        where = f"({round(x)}, {round(y)}) on {surface}"
        if not c.get("center"):
            return (409, {"error": f"{where} is not charted: the team has not seen that ground"}), None
        n, k = int(c.get("chunks") or 0), int(c.get("charted") or 0)
        if k < n:
            return (409, {"error": f"{n - k} of the {n} chunks the frame at zoom {zoom:g} covers around {where} are "
                                   f"not charted: the team has not seen that ground (a closer zoom frames less)",
                          "chunks": n, "charted": k}), None
        return None, c

    def apply(self, data, now):
        try:
            p, until = data["position"], float(data["until"])
            ok = isinstance(data.get("surface"), str) and data["surface"] and math.isfinite(until) and until > now
            look = {"surface": data["surface"], "position": {"x": number(p["x"]), "y": number(p["y"])},
                    "zoom": max(MIN_ZOOM, min(MAX_ZOOM, number(data.get("zoom") or DEFAULT_ZOOM))), "until": until,
                    "label": str(data.get("label") or "").strip()[:80] or None,
                    "by": str(data.get("by") or "operator")[:40]} if ok else None
            if look:
                for k in ("cut_at", "id", "platform"):  # (CK1)
                    if data.get(k) is not None:
                        look[k] = number(data[k]) if k == "cut_at" else str(data[k])[:80]
        except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
            look = None
        self.director.set_look(look, now)
        return look

    def write(self, data):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)
        self.mtime = os.stat(self.path).st_mtime_ns

    def request(self, body, now=None):
        """POST /look -> (http code, reply)."""
        now = time.time() if now is None else now
        if not isinstance(body, dict):
            return 400, {"error": "expected an object with surface, x, y (or platform) and optional zoom, seconds, "
                                  "label, by, cut_at, id"}
        ship = str(body.get("platform") or "").strip()
        if not ship and not str(body.get("surface") or "").strip():
            return 400, {"error": "surface missing (nauvis, vulcanus, platform-3, or a platform's name), or platform"}
        try:
            zoom = number(body["zoom"]) if body.get("zoom") is not None else None
            secs = number(body["seconds"]) if body.get("seconds") is not None else DEFAULT_S
            cut_at = number(body["cut_at"]) if body.get("cut_at") is not None else None
        except (TypeError, ValueError, OverflowError):
            return 400, {"error": "zoom, seconds and cut_at must be finite numbers"}
        if cut_at is not None and not now - 1 <= cut_at <= now + 30:
            return 400, {"error": "cut_at is epoch seconds, from now to 30 s ahead"}
        secs = max(1.0, min(MAX_S, secs))
        start = max(now, cut_at or now)
        c = {}
        if ship and body.get("x") is None and body.get("y") is None:
            # (CK1) a whole ship as the director frames it now (model.platform_shot), held fixed: no chart read
            frame = self.ship_frame(ship)
            if not frame:
                return 409, {"error": f"no camera view for a platform named {ship!r}", "platforms":
                             list(getattr(self.director, "plat_rows", {}) or {})}
            surface, platform, x, y = frame["surface"], frame["platform"], frame["position"]["x"], frame["position"]["y"]
            zoom = round(max(MIN_ZOOM, min(MAX_ZOOM, zoom if zoom is not None else frame["zoom"])), 2)
        else:
            try:
                x, y = number(body.get("x")), number(body.get("y"))
            except (TypeError, ValueError, OverflowError):
                return 400, {"error": "x and y must be finite numbers (map tiles)"}
            zoom = round(max(MIN_ZOOM, min(MAX_ZOOM, zoom if zoom is not None else DEFAULT_ZOOM)), 2)
            surface, platform = self.surface_of(ship or body["surface"])
            if ship and not platform:
                return 409, {"error": f"no camera view for a platform named {ship!r}"}
            refused, c = self.check(surface, x, y, zoom)
            if refused:
                print(f"[look] {str(body.get('by') or 'operator')[:40]}: refused ({refused[1]['error']})", flush=True)
                return refused
        data = {"surface": surface, "position": {"x": round(x, 1), "y": round(y, 1)}, "zoom": zoom,
                "until": round(start + secs, 1), "label": str(body.get("label") or "").strip()[:80] or None,
                "by": str(body.get("by") or "operator")[:40]}
        if cut_at is not None:
            data["cut_at"] = round(cut_at, 3)
        if body.get("id") is not None:
            data["id"] = str(body["id"])[:80]
        if platform:
            data["platform"] = platform
        self.write(data)
        self.apply(data, now)
        print(f"[look] {data['by']}: ({round(x)}, {round(y)}) on {surface} at zoom {zoom:g} for {int(secs)} s"
              + (f" ({data['label']})" if data["label"] else ""), flush=True)
        return 200, dict(data, seconds=int(secs), platform=platform, chunks=c.get("chunks"),
                         visible=bool(c.get("visible")) if c else True)

    def ship_frame(self, name):
        """{surface, position, zoom, platform} for one of our ships as the director frames it (onecam.platform_target:
        the whole ship at the zoom that fits; a tall ship's pan starts at its bow), or None."""
        rows = getattr(self.director, "plat_rows", {}) or {}
        pname = next((n for n in rows if n.casefold() == name.casefold()), None)
        target = getattr(self.director, "platform_target", None)
        t = target(pname, "look", 0) if pname and target else None
        if not t or not t.get("position") or not t.get("surface"):
            return None
        return {"surface": t["surface"], "position": dict(t["position"]), "zoom": t["zoom"], "platform": pname,
                "pan": t.get("pan")}

    def extend(self, body, now=None):
        """POST /look/extend {seconds, id?}: the current look ends at now + seconds (at most 60); no chart read."""
        now = time.time() if now is None else now
        lk = getattr(self.director, "look_hold", None)
        if not lk or now >= lk["until"]:
            return 409, {"error": "no look on"}
        if isinstance(body, dict) and body.get("id") is not None and str(body["id"]) != str(lk.get("id")):
            return 409, {"error": f"the look on is {lk.get('id')!r}, not {body['id']!r}"}
        try:
            secs = max(1.0, min(MAX_S, number((body or {}).get("seconds", DEFAULT_S))))
        except (TypeError, ValueError, OverflowError):
            return 400, {"error": "seconds must be a finite number"}
        lk["until"] = round(max(now, lk.get("cut_at") or now) + secs, 1)
        if self.path:
            try:
                with open(self.path) as f:
                    data = json.load(f)
                data["until"] = lk["until"]
                self.write(data)
            except (OSError, ValueError):
                pass
        return 200, {"until": lk["until"], "id": lk.get("id")}

    def clear(self, now=None):
        """DELETE /look."""
        if self.path:
            try:
                os.remove(self.path)
            except FileNotFoundError:
                pass
        self.mtime = None
        self.apply(None, time.time() if now is None else now)
        print("[look] off", flush=True)
        return 200, {"look": None}

    def sync(self, now=None):
        """Each tick: read the file again when it appeared, changed or went away (a restart, or a hand edit)."""
        if not self.path:
            return
        now = time.time() if now is None else now
        try:
            m = os.stat(self.path).st_mtime_ns
        except OSError:
            m = None
        if m == self.mtime:
            return
        self.mtime = m
        data = None
        if m is not None:
            try:
                with open(self.path) as f:
                    data = json.load(f)
            except (OSError, ValueError):
                pass
        look = self.apply(data, now)
        if look and not look.get("platform"):  # a hand-written spot gets the same chart check (a ship's frame: none)
            refused, _ = self.check(look["surface"], look["position"]["x"], look["position"]["y"], look["zoom"])
            if refused:
                print(f"[look] read {self.path}: refused ({refused[1]['error']})", flush=True)
                self.director.set_look(None, now)
