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
MAX_ANSWERS = 6
ANSWER_TTL = 120  # an answer older than this is no longer offered to the hosts


class AnalystBoard:
    def __init__(self):
        self.lock = threading.Lock()
        self.points = []  # newest last
        self.latest = None
        self.used = set()
        self.seq = 0
        self.cycles = 0
        self.answers = []  # viewer questions the analyst answered, newest last

    def answer(self, body, now=None):
        """`POST /analyst/answer`: one viewer question with the analyst's checked answer, for the hosts to say."""
        now = now or time.time()
        with self.lock:
            self.seq += 1
            a = {k: body.get(k) for k in ("msg_id", "viewer", "question", "answer", "facts", "seconds", "asked_t")}
            a.update(id=f"va{int(now)}-{self.seq}", t=now)  # unique across service restarts (the caster keeps seen ids)
            self.answers = (self.answers + [a])[-MAX_ANSWERS:]
            return {"ok": True, "id": a["id"]}

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
                                                     "corrections", "game_minute", "meta", "viewer_questions")}
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
            answers = [dict(x) for x in self.answers if now - x["t"] < ANSWER_TTL]
            if not self.latest:
                return {"answers": answers} if answers else None
            pts = sorted(self.fresh(now), key=lambda p: (-int(p.get("priority") or 2), -p["t"]))[:10]
            return dict(self.latest, age_s=round(now - self.latest["t"]), answers=answers,
                        talking_points=[{k: p.get(k) for k in ("id", "kind", "topic", "text", "facts", "priority", "agents",
                                                                "game_minute", "expires")} for p in pts])

    def full(self, now=None):
        with self.lock:
            return {"latest": self.latest, "points": list(self.points), "used": sorted(self.used), "cycles": self.cycles,
                    "answers": list(self.answers)}


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


# ---- viewer questions (analyst.py answers them; caster.py voices the answers) -------------------------------------
QUESTION_START = re.compile(r"^(?:@?\w+[,:]\s+)?(how|what|why|when|where|who|which|whose|is|are|was|were|can|could|"
                            r"will|would|do|does|did|should|has|have|had|any(?:one|body)?)\b", re.I)


def is_question(text):
    """A viewer message that asks something (a '?' or a question word first), at least three words."""
    t = (text or "").strip()
    return len(re.findall(r"[A-Za-z']+", t)) >= 3 and ("?" in t or bool(QUESTION_START.search(t)))


class QuestionPicker:
    """Which viewer question the analyst answers next: at most one answer per `every` seconds, only questions
    younger than `max_age` seconds when picked, never an order to the agents, newest first; a skipped question
    (off-topic, unsafe, no answer) only holds the next pick for `retry` seconds."""

    def __init__(self, every=150, max_age=60, retry=20):
        self.every, self.max_age, self.retry = every, max_age, retry
        self.seen = set()
        self.next_ok = 0.0

    def pick(self, viewers, now):
        if now < self.next_ok:
            return None
        cands = [v for v in viewers or [] if isinstance(v, dict) and v.get("id") not in self.seen
                 and not v.get("order") and now - float(v.get("t") or 0) <= self.max_age and is_question(v.get("text"))]
        if not cands:
            return None
        v = max(cands, key=lambda x: float(x.get("t") or 0))
        self.seen.add(v.get("id"))
        return v

    def answered(self, now):
        self.next_ok = now + self.every

    def skipped(self, now):
        self.next_ok = max(self.next_ok, now + self.retry)


def questions_on(analyst):
    """True while the analyst takes viewer questions (its latest cycle says so and is recent): the hosts then leave
    questions to it instead of answering them from their own knowledge."""
    return bool(analyst and (analyst.get("viewer_questions") or {}).get("on") and (analyst.get("age_s") or 0) < 400)
