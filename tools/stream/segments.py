"""Segments: timed shots the casters (tools/stream/caster.py) or the director start, e.g. a production analysis over
the main camera or a spotlight on one agent. API agreed with eng/audio (docs/STREAM-NOTES.md "Segments"):

  GET  /segments -> {"types": [{type, title, params, seconds: [min, max], available, why?}], "busy", "next_ok"}
  POST /segment {type, params, seconds, by, reason} -> 200 {id, state: "queued", eta, seconds, title, facts}
                                                     | 409 {error: busy|declined|unavailable, retry_after} | 400 {error}
  snapshot["segment"]: {id, type, state: starting|live|ended, started, ends, title, facts, by, reason, cut?} or None

`facts` holds every name and number the page shows for the segment, computed once when it is accepted, so what the
casters say matches the screen. The page renders a segment from its facts only.
"""
import itertools, math, threading, time
from collections import deque

from model import SCIENCE

STARTING_S = 2.5   # page fade-in; the caster writes its exchange now and speaks on "live"
ENDED_S = 5.0      # "ended" stays in the snapshot this long, then the segment is gone
URGENT = ("attack", "death", "loss")

TYPES = {
    "production": {"title": "Production analysis", "params": {}, "seconds": [20, 45]},
    "research": {"title": "Research progress", "params": {}, "seconds": [15, 30]},
    "spotlight": {"title": "Agent spotlight", "params": {"agent": "agent name (default: the most interesting)"},
                  "seconds": [20, 45]},
    "overview": {"title": "Base overview", "params": {}, "seconds": [15, 30]},
    "recap": {"title": "Recap", "params": {"minutes": "window, 5..30 (default 10)"}, "seconds": [20, 40]},
    "attack_replay": {"title": "Attack replay", "params": {"area": "alert id"}, "seconds": [15, 40]},
}
LULL_ORDER = ["production", "spotlight", "research", "overview", "recap"]


def human(item):
    return item.replace("-", " ")


class Segments:
    def __init__(self, spacing=180.0, lull_after=360.0, urgent_quiet=20.0, overview_zoom=0.2, spotlight_zoom=0.9):
        self.spacing = spacing            # seconds between segment starts, whoever asks
        self.lull_after = lull_after      # the director fills a lull this long after the last segment ended
        self.urgent_quiet = urgent_quiet  # no segment within this long of an attack cut on the main camera
        self.overview_zoom = overview_zoom
        self.spotlight_zoom = spotlight_zoom
        self.lock = threading.Lock()
        self.ids = itertools.count(1)
        self.queue = None   # accepted, not yet started
        self.cur = None     # starting / live / ended
        self.last_start = -1e9
        self.last_attack_cut = -math.inf  # set by attack_cut() when the director cuts main to a fight
        self.last_end = time.time()
        self.lull_rr = 0
        self.snap = None
        self.history = deque(maxlen=200)  # (t, kind, text) of alerts seen, for recaps
        self.seen = set()
        self.replays = None  # replays.Replays sets itself here

    # ---- availability ------------------------------------------------------------------------------------------
    def why_unavailable(self, kind, snap):
        if kind == "attack_replay":
            return self.replays.why() if self.replays else "replays are off (serve.py --no-replays, or the mock)"
        if snap is None:
            return "no game state yet"
        if kind == "production" and not (snap.get("production") or (snap.get("science") or {}).get("packs")):
            return "nothing produced yet"
        if kind == "research" and not (snap.get("research") or {}).get("current") and \
                not (snap.get("research") or {}).get("done_count"):
            return "no research yet"
        if kind in ("spotlight", "overview") and not self.live_agents(snap):
            return "no agent in the world"
        return None

    @staticmethod
    def live_agents(snap):
        return [a for a in snap.get("agents") or [] if a.get("alive") and a.get("position") and a.get("seen", True)]

    def types(self, now=None):
        now = now or time.time()
        with self.lock:
            out = []
            for kind, t in TYPES.items():
                why = self.why_unavailable(kind, self.snap)
                row = dict(t, type=kind, available=why is None)
                if why:
                    row["why"] = why
                out.append(row)
            return {"types": out, "busy": self.busy(), "next_ok": round(max(now, self.last_start + self.spacing), 1)}

    def busy(self):
        return self.queue is not None or (self.cur is not None and self.cur["state"] != "ended")

    def urgent_since(self, snap, now):
        """Seconds since the director last cut the main camera to a fight, death, attack or loss (inf when never).
        Alerts the director lets pass (inside its attack spacing, or attack_cut off) neither decline nor cut."""
        return now - self.last_attack_cut

    def attack_cut(self, now=None):
        """The director just cut the main camera to an attack or death: a running segment gives way."""
        now = now or time.time()
        with self.lock:
            self.last_attack_cut = now
            cur = self.cur
            if cur and cur["state"] in ("starting", "live"):
                cur.update(state="ended", cut="attack", ends=now)
                self.last_end = now
            self.queue = None

    # ---- requests ----------------------------------------------------------------------------------------------
    def request(self, body, now=None, ignore_spacing=False):
        """-> (http status, reply dict). ignore_spacing: replays.py's own clips skip the 180 s segment spacing."""
        now = now or time.time()
        kind = body.get("type")
        if kind not in TYPES:
            return 400, {"error": "bad type", "types": list(TYPES)}
        params = body.get("params") or {}
        if not isinstance(params, dict):
            return 400, {"error": "bad params"}
        with self.lock:
            snap = self.snap
            why = self.why_unavailable(kind, snap)
            if why:
                return 409, {"error": "unavailable", "why": why, "retry_after": 60}
            if self.busy():
                end = self.cur["ends"] if self.cur else now + 30
                return 409, {"error": "busy", "retry_after": round(max(5, end - now + self.spacing), 1)}
            if now - self.last_start < self.spacing and not ignore_spacing:
                return 409, {"error": "busy", "retry_after": round(self.last_start + self.spacing - now, 1)}
            if self.urgent_since(snap, now) < self.urgent_quiet:
                return 409, {"error": "declined", "why": "urgent event on screen", "retry_after": 30}
            lo, hi = TYPES[kind]["seconds"]
            try:
                seconds = float(body.get("seconds") or (lo + hi) / 2)
            except (TypeError, ValueError):
                return 400, {"error": "bad params", "why": "seconds"}
            seconds = max(lo, min(hi, seconds))
            try:
                title, facts, camera = self.build(kind, params, snap, now)
            except ValueError as e:
                return 400, {"error": "bad params", "why": str(e)}
            clip = None
            if kind == "attack_replay":
                facts, clip = self.replays.facts(now)
                title = "Replay: " + facts["event"]
            seg = {"id": f"seg-{next(self.ids)}", "type": kind, "clip": clip, "state": "queued", "seconds": seconds, "title": title,
                   "facts": facts, "by": str(body.get("by") or "caster"), "reason": str(body.get("reason") or ""),
                   "camera": camera, "queued": now}
            self.queue = seg
            return 200, {k: seg[k] for k in ("id", "state", "seconds", "title", "facts")} | {"eta": STARTING_S}

    # ---- the clock (called once a second with the latest snapshot) ---------------------------------------------
    def step(self, snap, now=None):
        now = now or time.time()
        with self.lock:
            self.snap = snap
            for a in snap.get("alerts") or []:
                if a["id"] not in self.seen:
                    self.seen.add(a["id"])
                    self.history.append((a["t"], a["kind"], a["text"]))
            cur = self.cur
            if cur and cur["state"] in ("starting", "live"):
                if cur["state"] == "starting" and now >= cur["started"] + STARTING_S:
                    cur["state"] = "live"
                elif now >= cur["ends"]:
                    cur["state"] = "ended"
                if cur["state"] == "ended":
                    self.last_end = now
            elif cur and cur["state"] == "ended" and now >= cur["ends"] + ENDED_S:
                self.cur = None
            if self.queue and (self.cur is None or self.cur["state"] == "ended"):
                seg, self.queue = self.queue, None
                seg.update(state="starting", started=now, ends=now + STARTING_S + seg["seconds"])
                self.cur = seg
                self.last_start = now
        if self.cur is None and self.queue is None and now - self.last_end >= self.lull_after:
            self.lull(snap, now)
        return self.public()

    def lull(self, snap, now):
        """Nothing for a while and nothing urgent: the director starts the next type in rotation itself."""
        if self.urgent_since(snap, now) < 60:
            return
        for i in range(len(LULL_ORDER)):
            kind = LULL_ORDER[(self.lull_rr + i) % len(LULL_ORDER)]
            code, _ = self.request({"type": kind, "by": "director", "reason": "lull"}, now)
            if code == 200:
                self.lull_rr = (self.lull_rr + i + 1) % len(LULL_ORDER)
                return

    def public(self):
        cur = self.cur
        if not cur:
            return None
        out = {k: cur[k] for k in ("id", "type", "state", "started", "ends", "title", "facts", "by", "reason")}
        if cur.get("cut"):
            out["cut"] = cur["cut"]
        return out

    def camera(self):
        """What the main camera should show while a segment runs: {"follow": agent} or {"position": {x, y}},
        with zoom and until; None when the segment leaves the cameras alone."""
        cur = self.cur
        if not cur or cur["state"] == "ended" or not cur.get("camera"):
            return None
        return dict(cur["camera"], until=cur["ends"], label=cur["title"], id=cur["id"])

    # ---- facts per type ----------------------------------------------------------------------------------------
    def build(self, kind, params, snap, now):
        return getattr(self, "build_" + kind)(params, snap, now)

    def build_attack_replay(self, params, snap, now):
        return "Replay", {}, None  # filled in request() from the saved clip (replays.py)

    def build_production(self, params, snap, now):
        sci = snap.get("science") or {}
        items = []
        for p in (snap.get("production") or [])[:6]:
            series = p.get("series") or []
            ago = round(series[-6], 1) if len(series) >= 6 else None  # 2-minute buckets: 10 minutes back
            items.append({"item": human(p["item"]), "id": p["item"], "rate_now": p.get("rate"), "rate_10min_ago": ago})
        moved = [(i["rate_now"] - i["rate_10min_ago"], i["item"]) for i in items
                 if i["rate_now"] is not None and i["rate_10min_ago"]]
        facts = {"science_per_min": sci.get("spm"), "stage": sci.get("stage_label"),
                 "packs": {human(p["item"]).replace(" pack", ""): p.get("rate") for p in sci.get("packs") or []},
                 "items": items,
                 "biggest_gain": max(moved)[1] if moved and max(moved)[0] > 0 else None,
                 "biggest_drop": min(moved)[1] if moved and min(moved)[0] < 0 else None}
        title = f"Production: {sci['spm']:g} science/min" if sci.get("spm") else "Production"
        return title, facts, None

    def build_research(self, params, snap, now):
        r = snap.get("research") or {}
        pct = round(r["progress"] * 100) if r.get("progress") is not None else None
        facts = {"current": r.get("label"), "progress_pct": pct, "done_count": r.get("done_count") or 0,
                 "recent": [x["label"] for x in (r.get("recent") or [])[:4]]}
        title = f"Research: {r['label']}" + (f" {pct}%" if pct is not None else "") if r.get("label") else "Research"
        return title, facts, None

    def build_spotlight(self, params, snap, now):
        live = self.live_agents(snap)
        name = params.get("agent")
        if name:
            ag = next((a for a in live if name in (a["name"], a.get("display_name"))), None)
            if not ag:
                raise ValueError(f"agent {name} is not in the world")
        else:  # the most interesting agent no camera is showing, else the most interesting
            ag = max(live, key=lambda a: (not a.get("camera"), a.get("interest") or 0))
        said = [m["text"] for m in snap.get("chat") or [] if m.get("agent") == ag["name"]][-2:]
        board = snap.get("board") or {}
        owned = [c["title"] for c in board.get("claims") or [] if c.get("agent") == ag["name"]][:3]
        facts = {"agent": ag.get("display_name") or ag["name"], "model": ag.get("model"), "harness": ag.get("harness"),
                 "motto": ag.get("motto") or None, "doing": ag.get("action") or ag.get("activity"),
                 "location": ag.get("location"), "said": said, "claims": owned}
        camera = {"follow": ag["name"], "zoom": self.spotlight_zoom}
        return f"Spotlight: {facts['agent']}", dict(facts, name=ag["name"]), camera

    def build_overview(self, params, snap, now):
        live = self.live_agents(snap)
        xs = [a["position"]["x"] for a in live]
        ys = [a["position"]["y"] for a in live]
        cx, cy = round((min(xs) + max(xs)) / 2, 1), round((min(ys) + max(ys)) / 2, 1)
        spread = max(math.hypot(x - cx, y - cy) for x, y in zip(xs, ys))
        # ~60 tiles across at zoom 1 on a 1080p client: fit the spread plus margin, but never closer than overview_zoom.
        # The game camera refuses zoom below 0.3 (cameras.lua MIN_ZOOM; shake3's 0.129 was refused), so a wider spread
        # than ~200 tiles shows only the middle.
        zoom = round(max(0.3, min(self.overview_zoom, 60.0 / (2 * spread + 60))), 3)
        facts = {"agents_in_world": len(live), "agents_total": len(snap.get("agents") or []),
                 "centre": [cx, cy], "spread_tiles": round(spread), "locations": sorted({a["location"] for a in live
                                                                                        if a.get("location")})[:6]}
        return "Base overview", facts, {"position": {"x": cx, "y": cy}, "zoom": zoom}

    def build_recap(self, params, snap, now):
        try:
            minutes = max(5, min(30, int(params.get("minutes") or 10)))
        except (TypeError, ValueError):
            raise ValueError("minutes")
        since = now - minutes * 60
        hist = [(t, k, txt) for t, k, txt in self.history if t >= since]
        research = [x["label"] for x in (snap.get("research") or {}).get("recent") or [] if (x.get("t") or 0) >= since]
        done = [e["title"] for e in (snap.get("board") or {}).get("events") or []
                if e.get("verb") == "done" and (e.get("t") or 0) >= since]
        facts = {"minutes": minutes, "research_done": research,
                 "deaths": [txt for t, k, txt in hist if k == "death"],
                 "attacks": sum(1 for t, k, txt in hist if k in ("attack", "loss")),
                 "board_done": done[-4:], "science_per_min": (snap.get("science") or {}).get("spm")}
        return f"Last {minutes} minutes", facts, None
