"""The analyst's talking points inside the stream service (serve.py), and a picker for the hosts. Stdlib only.

serve.py keeps one AnalystBoard: `POST /analyst` stores a cycle from tools/stream/analyst.py, `POST /analyst/used
{id}` marks a point as said, `GET /analyst.json` returns everything, and every snapshot carries `analyst` (the
compact public view below). Points expire after their ttl_s; a used point is not offered again.

For the hosts (tools/stream/caster.py):

    from analyst_board import pick_point, point_facts
    p = pick_point(snapshot.get("analyst"), used_ids, kinds=None)   # best fresh unused point, or None
    facts["analyst"] = point_facts(p)                               # {"point": text, **its facts}
    # after the line is said: POST /analyst/used {"id": p["id"]}

The point's text is written for a voice and its facts hold every name and number in it, so a host line built from
it passes the caster's fact check.
"""
import re, threading, time

MAX_POINTS = 60


class AnalystBoard:
    def __init__(self):
        self.lock = threading.Lock()
        self.points = []  # newest last
        self.latest = None
        self.used = set()
        self.seq = 0
        self.cycles = 0

    def post(self, cycle, now=None):
        now = now or time.time()
        with self.lock:
            self.cycles += 1
            topics = {(p.get("topic") or "") for p in cycle.get("talking_points") or []}
            # a fresh point on the same topic replaces the old one
            self.points = [p for p in self.points if not p.get("topic") or p.get("topic") not in topics]
            for p in cycle.get("talking_points") or []:
                self.seq += 1
                q = dict(p, id=f"tp{self.seq}", t=now, expires=now + float(p.get("ttl_s") or 300),
                         game_minute=cycle.get("game_minute"))
                self.points.append(q)
            self.points = self.points[-MAX_POINTS:]
            self.latest = {k: cycle.get(k) for k in ("headline", "judgement", "storylines", "next", "segments",
                                                     "corrections", "game_minute", "meta")}
            self.latest["t"] = now
            return {"ok": True, "cycle": self.cycles, "points": len(cycle.get("talking_points") or [])}

    def mark_used(self, pid):
        with self.lock:
            self.used.add(pid)
        return {"ok": True}

    def fresh(self, now=None):
        now = now or time.time()
        return [p for p in self.points if p["expires"] > now and p["id"] not in self.used]

    def public(self, now=None):
        """Compact view for the snapshot: the latest judgement and storylines, fresh points best first."""
        now = now or time.time()
        with self.lock:
            if not self.latest:
                return None
            pts = sorted(self.fresh(now), key=lambda p: (-int(p.get("priority") or 2), -p["t"]))[:10]
            return dict(self.latest, age_s=round(now - self.latest["t"]),
                        talking_points=[{k: p.get(k) for k in ("id", "kind", "topic", "text", "facts", "priority", "agents",
                                                                "game_minute", "expires")} for p in pts])

    def full(self, now=None):
        with self.lock:
            return {"latest": self.latest, "points": list(self.points), "used": sorted(self.used), "cycles": self.cycles}


def pick_point(analyst, used=(), kinds=None, now=None):
    """Best fresh point from a snapshot's `analyst` view that the caster has not used, optionally by kind."""
    if not analyst:
        return None
    now = now or time.time()
    for p in analyst.get("talking_points") or []:
        if p.get("id") in used or (p.get("expires") or now + 1) <= now:
            continue
        if kinds and p.get("kind") not in kinds:
            continue
        return p
    return None


def point_facts(p):
    """Facts for a host line built on a talking point: the point's text plus its own facts."""
    if not p:
        return None
    f = dict(p.get("facts") or {}, point=p.get("text"), kind=p.get("kind"))
    if compares_runs(p.get("text")) or p.get("kind") == "comparison":
        f["pace"] = p.get("text")  # eng/audio's check_line allows previous-run comparisons only with a pace fact
    return f


RUN_WORDS = re.compile(r"\b(shake\d*|co-?op ?\d*|coop\d*|baseline\d*|turns\w*|previous run|last run|past runs?|solo run)\b", re.I)


def compares_runs(text):
    return bool(text and RUN_WORDS.search(text))
