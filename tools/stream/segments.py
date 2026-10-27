"""Segments: timed shots the casters (tools/stream/caster.py) or the director start, e.g. a production analysis over
the main camera or a spotlight on one agent. API agreed with eng/audio (docs/STREAM-NOTES.md "Segments"):

  GET  /segments -> {"types": [{type, title, params, seconds: [min, max], available, why?}], "busy", "next_ok"}
  POST /segment {type, params, seconds, by, reason} -> 200 {id, state: "queued", eta, seconds, title, facts}
                                                     | 409 {error: busy|declined|unavailable, retry_after} | 400 {error}
  snapshot["segment"]: {id, type, state: starting|live|ended, started, ends, title, facts, by, reason, cut?} or None

`facts` holds every name and number the page shows for the segment, computed once when it is accepted, so what the
casters say matches the screen. The page renders a segment from its facts only.
"""
import itertools, math, re, threading, time
from collections import deque

import efficiency
import hauling
import tokens
from model import SCIENCE, platform_shot

STARTING_S = 2.5   # page fade-in; the caster writes its exchange now and speaks on "live"
ENDED_S = 5.0      # "ended" stays in the snapshot this long, then the segment is gone
URGENT = ("attack", "death", "loss")
# The site's address on a share of segment cards (Nick, YouTube chat Oct 14 22:02; d17): a small line at the card's
# foot, every site_every-th segment that is not a replay (about 4-5 an hour in shift28, so about two lines an hour).
# It is not in "facts": the casters read those; this is the page's alone.
SITE = "factorio.nickwinter.net"

TYPES = {
    # Analysis segments are a small card on the main camera, up for about as long as it takes to read (Nick on shake7:
    # the old full panel covered the camera far longer than that and said little); production and recap only run
    # when they have news (why_unavailable).
    "production": {"title": "Production analysis", "params": {}, "seconds": [10, 20]},
    "research": {"title": "Research progress", "params": {}, "seconds": [10, 18]},
    "spotlight": {"title": "Agent spotlight", "params": {"agent": "agent name (default: the most interesting)"},
                  "seconds": [20, 45]},
    "overview": {"title": "Base overview", "params": {}, "seconds": [15, 30]},
    "recap": {"title": "Recap", "params": {"minutes": "window, 5..30 (default 10)"}, "seconds": [10, 20]},
    "attack_replay": {"title": "Attack replay", "params": {"area": "alert id"}, "seconds": [15, 40]},
    # Space Age: progress (planets, platforms, space science), and the moments model.py detects (first rocket,
    # first platform, a platform reaching a new planet, the first landing there, a platform's maiden flight: its first
    # departure since it was built, viewer Foobator d17 14:24); the director starts a moment's
    # segment itself within MOMENT_FRESH_S, skipping the spacing, and casters may ask for one too.
    "space": {"title": "Space Age progress", "params": {}, "seconds": [10, 18]},
    "space_moment": {"title": "Space Age moment", "params": {"moment": "moment id (default: the newest not yet shown)"},
                     "seconds": [12, 25]},
    # Items each agent moved by hand this shift (operator 05:00, viewer Joonazan); the director shows it every
    # hauling_every, ranked, numbers only.
    "hauling": {"title": "Hand hauling this shift", "params": {}, "seconds": [10, 16]},
    # Tokens each agent's model read and wrote this shift (operator 08:55, from Nick); the director shows it every
    # tokens_every, halfway between the hauling cards, ranked, numbers only.
    "tokens": {"title": "Tokens this shift", "params": {}, "seconds": [10, 16]},
    # What the machines each agent built made this shift (Nick 15:50; efficiency.lua): the team's numbers and one
    # agent's line, a different agent each time; the director shows it every efficiency_every, no ranking.
    "efficiency": {"title": "Machines at work this shift", "params": {}, "seconds": [10, 16]},
}
LULL_ORDER = ["production", "spotlight", "research", "space", "overview", "recap"]
MOMENT_FRESH_S = 150.0
# A loss clip of one of these, alone, is routine: shake12 aired three replays in 41 s at 04:04, often one pipe or one
# belt. It airs only when nothing else has for a while (Segments.replay_gate).
CHEAP = ("pipe", "pipe to ground", "transport belt", "underground belt", "electric pole", "inserter")
# live.py loss_events: "9 lost near (24, -89): ..." or, off Nauvis, "59 lost on Vulcanus near (-223, 74): ..."
LOSS_RE = re.compile(r"^(\d+) lost (?:on [A-Z][\w -]* )?near \([^)]*\): (.*?)(?: \(by .*\))?$")


def cheap_loss(label):
    """"1 lost near (39, 84): 1 pipe to ground (by flamethrower turrets)" -> True: one building, and a cheap one."""
    m = LOSS_RE.match(label or "")
    if not m or int(m.group(1)) != 1:
        return False
    name = re.sub(r"^\d+ ", "", m.group(2).split(",")[0].strip())
    return name.endswith(CHEAP)


def big_replay(clip):
    """A replay that is the story, not routine: an agent's death (a death clip, or a loss that took a character)."""
    return clip.get("kind") == "death" or bool(re.search(r"\bcharacter\b", clip.get("label") or ""))


def human(item):
    return item.replace("-", " ")


class Segments:
    def __init__(self, spacing=180.0, lull_after=360.0, urgent_quiet=20.0, overview_zoom=0.2, spotlight_zoom=0.9,
                 recap_every=1200.0, replay_spacing=90.0, cheap_quiet=180.0, hauling_every=1800.0,
                 tokens_every=1800.0, efficiency_every=1800.0, site_every=2):
        self.spacing = spacing            # seconds between segment starts, whoever asks
        self.site_every = max(0, int(site_every))  # 0: never
        self.site_turn = 0
        # Replays skip `spacing` (replays.py), so they have their own: one start per replay_spacing (shake12: three in
        # 41 s). A single cheap building's loss airs only when no segment has started for cheap_quiet and no fight cut
        # for 60 s; the same loss line airs once in replay_repeat (live.py re-reports a loss: shake12 aired several
        # twice, ~90 s apart).
        self.replay_spacing = replay_spacing
        self.cheap_quiet = cheap_quiet
        self.replay_repeat = 300.0
        self.last_replay = -math.inf
        self.replay_aired = {}  # label -> when it last went on air
        self.research_seen = set()  # research_news names already seen (a new one cuts a routine replay)
        self.lull_after = lull_after      # the director fills a lull this long after the last segment ended
        # A recap is due this long after the last one (or the service start): the director starts it at the first
        # free slot, ahead of the lull rotation. In shake3 the hosts' research requests kept resetting the 6-minute
        # lull clock, the rotation reached overview at 01:18 and the run ended before recap's turn: it never ran.
        self.recap_every = recap_every
        self.last_recap = time.time()
        # An overdue recap (this long past due) goes next: other requests are refused until it starts. In shake4 the
        # recap waited for an empty slot and replays kept taking it: one gap was 30 minutes.
        self.recap_late = 600.0
        # The hand hauling card: due this long after the last one (or the service start), at the next free slot.
        self.hauling_every = hauling_every
        self.last_hauling = time.time()
        # The token card: the same, its first one half a period in (between the hauling cards, not after one).
        self.tokens_every = tokens_every
        self.last_tokens = time.time() - tokens_every / 2
        # The machines card: the same, its first one a third of a period in; each card names the next agent.
        self.efficiency_every = efficiency_every
        self.last_efficiency = time.time() - efficiency_every * 2 / 3
        self.efficiency_turn = 0
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
        self.shown_moments = set()

    # ---- availability ------------------------------------------------------------------------------------------
    def why_unavailable(self, kind, snap, now=None):
        if kind == "attack_replay":
            return self.replays.why(now) if self.replays else "replays are off (serve.py --no-replays, or the mock)"
        if snap is None:
            return "no game state yet"
        sci = snap.get("science") or {}
        if kind == "production" and not (snap.get("production") or sci.get("packs") or (sci.get("made") or {}).get("packs")):
            return "nothing produced yet"
        if kind == "production" and not self.production_moves(snap):
            return "no item's rate moved by 25% in 10 minutes"
        if kind == "recap" and not self.recap_news(snap, now or time.time()):
            return "nothing happened in the window"
        if kind == "research" and not (snap.get("research") or {}).get("current") and \
                not (snap.get("research") or {}).get("done_count"):
            return "no research yet"
        if kind in ("spotlight", "overview") and not self.live_agents(snap):
            return "no agent in the world"
        if kind == "space" and not (snap.get("space") or {}).get("active"):
            return "no Space Age progress yet"
        if kind == "space_moment" and not self.moments(snap):
            return "no Space Age moment yet"
        if kind == "hauling" and not ((snap.get("hauling") or {}).get("rows")):
            return "no hand hauling counted this shift yet"
        if kind == "tokens" and not any(r.get("total") for r in (snap.get("tokens") or {}).get("rows") or []):
            return "no tokens counted this shift yet"
        if kind == "efficiency" and not ((snap.get("efficiency") or {}).get("team") or {}).get("machines"):
            return "no machines counted yet"
        return None

    def moments(self, snap, fresh_only=False, now=None):
        """Moments not yet shown as a segment, newest first."""
        now = now or time.time()
        return [m for m in reversed((snap.get("space") or {}).get("moments") or [])
                if m["id"] not in self.shown_moments and (not fresh_only or now - m["t"] <= MOMENT_FRESH_S)]

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

    def recap_overdue(self, now):
        return now - self.last_recap >= self.recap_every + self.recap_late

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

    def end(self, seg_id, why, now=None):
        """End the running segment seg_id early (replays.py: its clip is gone, or the replay never started): the
        snapshot says "ended" with `cut`, the overlay drops its card and the hosts move on. False if it is not running."""
        now = now or time.time()
        with self.lock:
            cur = self.cur
            if not cur or cur["id"] != seg_id or cur["state"] not in ("starting", "live"):
                return False
            cur.update(state="ended", cut=why, ends=now)
            self.last_end = now
            return True

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
            why = self.why_unavailable(kind, snap, now)
            if why:
                return 409, {"error": "unavailable", "why": why, "retry_after": 60}
            if self.busy():
                end = self.cur["ends"] if self.cur else now + 30
                return 409, {"error": "busy", "retry_after": round(max(5, end - now + self.spacing), 1)}
            if self.recap_overdue(now) and kind != "recap":
                return 409, {"error": "busy", "why": "an overdue recap goes next", "retry_after": 60}
            if now - self.last_start < self.spacing and not ignore_spacing:
                return 409, {"error": "busy", "retry_after": round(self.last_start + self.spacing - now, 1)}
            if self.urgent_since(snap, now) < self.urgent_quiet:
                return 409, {"error": "declined", "why": "urgent event on screen", "retry_after": 30}
            if kind == "attack_replay":
                gate = self.replay_gate(snap, now)
                if gate:
                    return 409, gate
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
            if kind != "attack_replay" and self.site_every:
                self.site_turn += 1
                if self.site_turn % self.site_every == 0:
                    seg["site"] = SITE
            self.queue = seg
            if kind == "recap":
                self.last_recap = now
            if kind == "hauling":
                self.last_hauling = now
            if kind == "tokens":
                self.last_tokens = now
            if kind == "efficiency":
                self.last_efficiency = now
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
            self.news_wins(snap, now)
            cur = self.cur
            if cur and cur["state"] in ("starting", "live"):
                if cur["state"] == "starting" and now >= cur["started"] + STARTING_S:
                    cur["state"] = "live"
                    if cur["type"] == "attack_replay":  # on air (a replay cut while starting may air later)
                        self.last_replay = now
                        self.replay_aired[cur["facts"]["event"]] = now
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
        if now - self.last_recap >= self.recap_every and not self.recap_news(snap, now):
            self.last_recap = now  # a recap with nothing to say is skipped: the next one is due in recap_every
        if not self.busy() and not self.recap_overdue(now) and self.moments(snap, fresh_only=True, now=now):
            # a Space Age moment is news: start it as soon as nothing else runs (spacing waived, attacks still win)
            self.request({"type": "space_moment", "by": "director", "reason": "moment"}, now, ignore_spacing=True)
        elif self.recap_overdue(now) and not self.busy() and self.urgent_since(snap, now) >= self.urgent_quiet:
            # 10 minutes late: right after whatever is on (spacing waived), and nothing else is accepted meanwhile
            minutes = max(5, min(30, round((now - self.last_recap) / 60)))
            self.request({"type": "recap", "params": {"minutes": minutes}, "by": "director", "reason": "recap overdue"},
                         now, ignore_spacing=True)
        elif (self.cur is None and self.queue is None and now - self.last_recap >= self.recap_every
              and now - self.last_start >= self.spacing and self.urgent_since(snap, now) >= 60):
            minutes = max(5, min(30, round((now - self.last_recap) / 60)))
            self.request({"type": "recap", "params": {"minutes": minutes}, "by": "director", "reason": "recap due"}, now)
        elif (self.cur is None and self.queue is None and now - self.last_hauling >= self.hauling_every
              and now - self.last_start >= self.spacing and self.urgent_since(snap, now) >= 60):
            code, _ = self.request({"type": "hauling", "by": "director", "reason": "hauling due"}, now)
            if code != 200 and self.why_unavailable("hauling", snap, now):
                self.last_hauling = now  # nothing counted yet: the next one is due in hauling_every
        elif (self.cur is None and self.queue is None and now - self.last_tokens >= self.tokens_every
              and now - self.last_start >= self.spacing and self.urgent_since(snap, now) >= 60):
            code, _ = self.request({"type": "tokens", "by": "director", "reason": "tokens due"}, now)
            if code != 200 and self.why_unavailable("tokens", snap, now):
                self.last_tokens = now  # nothing counted yet: the next one is due in tokens_every
        elif (self.cur is None and self.queue is None and now - self.last_efficiency >= self.efficiency_every
              and now - self.last_start >= self.spacing and self.urgent_since(snap, now) >= 60):
            code, _ = self.request({"type": "efficiency", "by": "director", "reason": "machines card due"}, now)
            if code != 200 and self.why_unavailable("efficiency", snap, now):
                self.last_efficiency = now  # nothing counted yet: the next one is due in efficiency_every
        elif self.cur is None and self.queue is None and now - self.last_end >= self.lull_after:
            self.lull(snap, now)
        return self.public()

    # ---- replays: which clip airs, and when (replays.py offers them; shake12's bursts) ---------------------------
    def replay_gate(self, snap, now):
        """None when the waiting clip may air now, else the 409 reply. "skip": True tells replays.py the clip is not
        worth holding up a clip waiting behind it."""
        c = (self.replays.clip if self.replays else None) or {}
        label = c.get("label") or ""
        if now - self.last_replay < self.replay_spacing:
            return {"error": "busy", "why": "a replay aired less than 90 s ago",
                    "retry_after": round(self.last_replay + self.replay_spacing - now, 1)}
        if c.get("kind") == "loss" and now - self.replay_aired.get(label, -math.inf) < self.replay_repeat:
            return {"error": "declined", "why": "this loss already aired", "skip": True, "retry_after": 60}
        if not big_replay(c):
            if (snap or {}).get("research_news"):
                return {"error": "declined", "why": "the research card is up", "retry_after": 10}
            if snap and self.moments(snap, fresh_only=True, now=now):
                return {"error": "declined", "why": "a Space Age moment goes first", "retry_after": 10}
        if cheap_loss(label) and (now - self.last_start < self.cheap_quiet or now - self.last_attack_cut < 60):
            return {"error": "declined", "why": "one cheap building lost: only when nothing else has aired for a while",
                    "skip": True, "retry_after": 30}
        return None

    def news_wins(self, snap, now):
        """A research completion (the overlay's research card, hidden while the replay scene is on air) or a fresh Space
        Age moment cuts a routine replay that is queued or on air (lock held)."""
        news = {n["name"] for n in snap.get("research_news") or [] if n.get("name")}
        new_research = bool(news - self.research_seen)
        self.research_seen |= news
        if not (new_research or self.moments(snap, fresh_only=True, now=now)):
            return
        why = "research" if new_research else "space_moment"
        if self.queue and self.queue["type"] == "attack_replay" and not self.queue_big():
            self.queue = None
        cur = self.cur
        if cur and cur["type"] == "attack_replay" and cur["state"] in ("starting", "live") and \
                not big_replay({"kind": cur["facts"].get("kind"), "label": cur["facts"].get("event")}):
            cur.update(state="ended", cut=why, ends=now)
            self.last_end = now

    def queue_big(self):
        f = self.queue["facts"]
        return big_replay({"kind": f.get("kind"), "label": f.get("event")})

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
        if cur.get("site"):
            out["site"] = cur["site"]
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

    MOVE_MIN = 0.25  # a production change worth a segment: 25% up or down over 10 minutes (or a new line)

    @staticmethod
    def production_moves(snap):
        """Items whose rate moved by MOVE_MIN or more against 10 minutes ago (or started), biggest first."""
        out = []
        for p in snap.get("production") or []:
            series = p.get("series") or []
            ago = round(series[-6], 1) if len(series) >= 6 else None  # 2-minute buckets: 10 minutes back
            now = p.get("rate")
            if now is None or ago is None:
                continue
            if ago <= 0:
                change = 1.0 if now >= 1 else 0.0  # a new line (at least one a minute)
            else:
                change = (now - ago) / ago
            if abs(change) >= Segments.MOVE_MIN and abs(now - ago) >= 1:
                out.append({"item": human(p["item"]), "id": p["item"], "rate_now": now, "rate_10min_ago": ago,
                            "change_pct": round(change * 100)})
        return sorted(out, key=lambda i: -abs(i["change_pct"]))

    def build_production(self, params, snap, now):
        sci = snap.get("science") or {}
        items = self.production_moves(snap)[:3]  # only what changed: the card is small and up for ~15 s
        facts = {"science_per_min": sci.get("spm"), "stage": sci.get("stage_label"), "items": items,
                 "biggest_gain": next((i["item"] for i in items if i["change_pct"] > 0), None),
                 "biggest_drop": next((i["item"] for i in items if i["change_pct"] < 0), None)}
        top = items[0] if items else None
        title = (f"Production: {top['item']} {'+' if top['change_pct'] > 0 else ''}{top['change_pct']}% in 10 min"
                 if top else "Production")
        return title, facts, None

    def build_research(self, params, snap, now):
        r = snap.get("research") or {}
        pct = round(r["progress"] * 100) if r.get("progress") is not None else None
        # (d27 batch258 RR) recent: finished while this stream runs; done_before_this_stream: the most advanced ones
        # done before it, by how long ago in game time where the chronicle knows (seeded as recent at each start, they
        # aired as "the newest research")
        when = lambda x: f"{x['label']} ({x['ago']} ago)" if x.get("ago") else x["label"]
        facts = {"current": r.get("label"), "progress_pct": pct, "done_count": r.get("done_count") or 0,
                 "recent": [when(x) for x in (r.get("recent") or [])[:4] if x.get("t")],
                 "done_before_this_stream": [when(x) for x in (r.get("top_done") or [])[:3]]}
        title = f"Research: {r['label']}" + (f" {pct}%" if pct is not None else "") if r.get("label") else "Research"
        return title, facts, None

    HAULING_ROWS = 5

    def build_hauling(self, params, snap, now):
        """Items each agent moved by hand this shift, most first (live.py observe_hauling): items, calls, the share run
        by queues and standing orders, tiles carried."""
        h = snap.get("hauling") or {}
        names = {a["name"]: a.get("display_name") or a["name"] for a in snap.get("agents") or [] if a.get("name")}
        rows = []
        for i, r in enumerate((h.get("rows") or [])[:self.HAULING_ROWS], 1):
            planned = (r.get("queue_items") or 0) + (r.get("order_items") or 0)
            rows.append({"rank": i, "agent": names.get(r["name"], r["name"]), "items": r["items"], "calls": r["calls"],
                         "queued_pct": round(100 * planned / r["items"]) if r["items"] else 0,
                         "tiles_carried": r.get("carry_tiles") or 0})
        minutes = round((h["t"] - h["since"]) / 60) if h.get("t") and h.get("since") else None
        facts = {"rows": rows, "minutes": minutes,
                 "line": hauling.card_line(h.get("rows") or [], self.HAULING_ROWS, lambda n: names.get(n, n))}
        return "Hand hauling this shift", facts, None

    TOKEN_ROWS = 9

    def build_tokens(self, params, snap, now):
        """Tokens each agent's model read and wrote this shift, most first (tokens.py TokenFeed): the share read from
        cache, model calls (turns), tokens per game action, and the team's total."""
        t = snap.get("tokens") or {}
        names = {a["name"]: a.get("display_name") or a["name"] for a in snap.get("agents") or [] if a.get("name")}
        counted = [r for r in t.get("rows") or [] if r.get("total")]
        rows = []
        for i, r in enumerate(counted[:self.TOKEN_ROWS], 1):
            rows.append({"rank": i, "agent": names.get(r["name"], r["name"]), "tokens": r["total"],
                         "cached_pct": round(100 * (r.get("cache_read") or 0) / r["input"]) if r.get("input") else 0,
                         "output": r.get("output") or 0, "turns": r.get("calls") or 0,
                         "per_action": round(r["total"] / r["actions"]) if r.get("actions") else None})
        minutes = round((t["t"] - t["since"]) / 60) if t.get("t") and t.get("since") else None
        team = sum(r["total"] for r in counted)
        facts = {"rows": rows, "minutes": minutes, "team_tokens": team, "team_text": tokens.short(team),
                 "line": tokens.card_line(counted, 5, lambda n: names.get(n, n))}
        return "Tokens this shift", facts, None

    def build_efficiency(self, params, snap, now):
        """The team's machines this shift (efficiency.lua): items they made, how many machines and how many working,
        the share of items moved by machines (against hand hauling), and one agent's line; numbers only."""
        e = snap.get("efficiency") or {}
        names = {a["name"]: a.get("display_name") or a["name"] for a in snap.get("agents") or [] if a.get("name")}
        team = e.get("team") or {}
        one = efficiency.pick(e.get("agents") or [], self.efficiency_turn)
        self.efficiency_turn += 1
        facts = {"team_items_this_shift": team.get("items_shift") or 0, "team_items_text": efficiency.fmt(team.get("items_shift")),
                 "machines": team.get("machines") or 0, "machines_working": team.get("running") or 0,
                 "moved_by_machines_pct": team.get("machine_share_pct"),
                 "ore_mined_about": team.get("ore_about") or None,
                 "agent": names.get(one["name"], one["name"]) if one else None,
                 "agent_line": efficiency.agent_line(one, lambda n: names.get(n, n)) if one else None,
                 "agent_machines": one.get("machines") if one else None,
                 "agent_machines_working": one.get("running") if one else None}
        return "Machines at work this shift", {k: v for k, v in facts.items() if v is not None}, None

    def build_space(self, params, snap, now):
        sp = snap.get("space") or {}
        facts = {"planets": sp.get("planets") or [], "rockets": sp.get("rockets") or 0,
                 "platforms": [{k: p.get(k) for k in ("name", "where", "speed_kms", "paused")} for p in (sp.get("platforms") or [])[:4]],
                 "science": {p["label"]: {"total": p.get("total"), "per_min": p.get("rate")} for p in sp.get("science") or []},
                 "away": sp.get("away") or []}
        # the main camera shows a platform itself (its surface, hub in frame, zoomed to fit): one asked for, else one
        # flying between planets, else the first whose surface is known
        plats = [p for p in sp.get("platforms") or [] if p.get("view")]
        pick = next((p for p in plats if p["name"] == params.get("platform")), None) or \
            next((p for p in plats if p.get("route")), None) or (plats[0] if plats else None)
        camera = None
        if pick:
            facts["shown"] = pick["name"]
            camera = platform_shot(pick["view"])
        return "Space Age progress", facts, camera

    def build_space_moment(self, params, snap, now):
        ms = self.moments(snap)
        m = next((x for x in ms if x["id"] == params["moment"]), None) if params.get("moment") else (ms[0] if ms else None)
        if not m:
            raise ValueError("no such moment (or it was shown)")
        self.shown_moments.add(m["id"])
        facts = dict(m["facts"], moment=m["kind"])
        camera = None
        if m.get("agent") and any(a["name"] == m["agent"] for a in self.live_agents(snap)):
            camera = {"follow": m["agent"], "zoom": self.spotlight_zoom}  # a landing: the agent on the new planet
        elif facts.get("platform"):  # first platform, a platform reaching a planet: the platform itself
            view = next((p.get("view") for p in (snap.get("space") or {}).get("platforms") or []
                         if p.get("name") == facts["platform"] and p.get("view")), None)
            if view:  # a maiden flight is under way: framed for flight (room ahead for asteroids)
                camera = platform_shot(view, travelling=m["kind"] == "maiden_flight")
        return m["title"], facts, camera

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

    def recap_news(self, snap, now, minutes=None):
        """What happened in the last `minutes` (default: since the last recap, 5..30) -> facts, or None if nothing."""
        if minutes is None:
            minutes = max(5, min(30, round((now - self.last_recap) / 60)))
        since = now - minutes * 60
        hist = [(t, k, txt) for t, k, txt in self.history if t >= since]
        research = [x["label"] for x in (snap.get("research") or {}).get("recent") or [] if (x.get("t") or 0) >= since]
        done = [e["title"] for e in (snap.get("board") or {}).get("events") or []
                if e.get("verb") == "done" and (e.get("t") or 0) >= since]
        facts = {"minutes": minutes, "research_done": research,
                 "deaths": [txt for t, k, txt in hist if k == "death"],
                 "attacks": sum(1 for t, k, txt in hist if k in ("attack", "loss")),
                 "board_done": done[-4:], "science_per_min": (snap.get("science") or {}).get("spm")}
        if not (research or done or facts["deaths"] or facts["attacks"]):
            return None
        return facts

    def build_recap(self, params, snap, now):
        try:
            minutes = max(5, min(30, int(params.get("minutes") or 10)))
        except (TypeError, ValueError):
            raise ValueError("minutes")
        facts = self.recap_news(snap, now, minutes)
        if not facts:
            raise ValueError(f"nothing happened in the last {minutes} minutes")
        return f"Last {minutes} minutes", facts, None
