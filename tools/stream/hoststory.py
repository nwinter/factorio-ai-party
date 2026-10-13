"""The hosts know the story (viewer Joonazan, shift07 16:38: "why is Rook always out of the loop? Commentary without
understanding context is really weak.").

Rook's 14 lines from 16:20 to 16:38 held 8 attack calls, mostly hits where nothing was lost ("Biters hit a gun turret
once. The turret is still standing"), and lines that joined facts with no link between them ("Biters are at Astra
again. Sunward's holds are loaded, so ammo comes first"). Two parts, used by caster.py:

- AttackGate: an attack alert is a host beat only when it matters: something lost in it or near it, a key battle on
  air (the director's battle hold), or a threat score (threats.py, the director's own scoring against the run's
  history in runs/RUN/threat-history.json) at the director's floor: an agent fighting for a while, big or rare
  enemies, a long fight. Until then it waits; a fight that ends without mattering becomes a quiet hit, which another
  beat may mention in a word (quiet_note).
- StoryMemo: a short rolling memo of the run, rebuilt by rules every few minutes and kept in runs/RUN/host-memo.json
  so a restart keeps it: the team's goals, the last headlines with their times, what each agent is on and its last
  spoken line, research now, and the analyst's open storylines (what is stuck). Every host prompt carries it, for
  understanding; the beat's own facts stay about the beat.
"""
import json, math, os, re, time
from collections import deque

FLOOR = 1.5          # onecam's threat_floor: a battle hold or a followed group needs this much
NEAR_LOSS = 64       # tiles: a loss in another fight this close in the last LOSS_WINDOW s counts for an attack
LOSS_WINDOW = 120
PENDING_MAX = 300    # an attack waits this long at most for its fight to matter
QUIET_WINDOW = 300   # quiet hits this recent are mentioned in a word
MEMO_EVERY = 180
HEADLINES = 5
BIG_LOSS = 8         # caster --loss-big: a loss this big is a headline of the run too


def loss_pieces(text):
    m = re.match(r"\s*(\d+) lost", text or "")
    return int(m.group(1)) if m else 0


def near(a, b, tiles=NEAR_LOSS):
    """Two positions on one surface within `tiles`."""
    return bool(a and b and (a.get("surface") or "nauvis") == (b.get("surface") or "nauvis")
                and math.hypot(a["x"] - b["x"], a["y"] - b["y"]) <= tiles)


def clock(t):
    return time.strftime("%H:%M", time.localtime(t))


class AttackGate:
    def __init__(self, history_path=None, floor=FLOOR):
        self.path, self.floor = history_path, floor
        self.threats, self.loaded = None, 0.0
        self.pending = {}           # key -> {"e", "t"}
        self.quiet = deque(maxlen=50)  # (t, text) attacks that never mattered

    def scorer(self, now):
        """threats.Threats on the run's history, read again every 5 minutes (the director writes it)."""
        if self.threats is None or now - self.loaded > 300:
            from threats import Threats
            path = self.path if self.path and os.path.exists(self.path) else None
            self.threats, self.loaded = Threats(None), now
            if path:
                try:
                    with open(path) as f:
                        self.threats.h.update(json.load(f))
                except (OSError, ValueError):
                    pass
        return self.threats

    @staticmethod
    def fight_of(e, s):
        fights = {f.get("key"): f for f in s.get("fights") or []}
        key = e.get("alert_key") or (f"attack:{e['agent']}" if e.get("agent") else None)
        return fights.get(key), key

    def why(self, e, s, now):
        """Why this attack is worth a beat, or None."""
        f, key = self.fight_of(e, s)
        pos = (f or {}).get("position") or e.get("position")
        battle = (s.get("onair") or {}).get("battle")
        if battle and key and battle == key:
            return "a key battle, on screen now"
        if battle:
            held = next((g for g in s.get("fights") or [] if g.get("key") == battle), None)
            # a battle held on an incoming group has no fight of its own yet: an attack while it is on air is part of it
            if not held or (pos and near(held.get("position"), pos)):
                return "part of the key battle on screen now"
        for g in s.get("fights") or []:
            if g.get("losses") and now - max(g["losses"]) <= LOSS_WINDOW and pos and near(g.get("position"), pos):
                return "buildings lost in this fight" + (f" ({g['text']})" if g.get("text") else "")
        if not f:
            return None
        score, parts = self.scorer(now).score_fight(0, f.get("text") or e.get("text"), bool(f.get("agent")),
                                                   now - (f.get("first") or now))
        if score >= self.floor:
            return f"threat score {score} ({', '.join(k for k in parts)})"
        return None

    def admit(self, e, s, now):
        """An event from the snapshot diff -> the events to queue now (an attack that does not matter yet waits)."""
        if e.get("kind") != "attack":
            return [e]
        why = self.why(e, s, now)
        if why:
            return [dict(e, why_it_matters=why)]
        key = e.get("alert_key") or e.get("text")
        if key not in self.pending:
            self.pending[key] = {"e": e, "t": now}
        return []

    def poll(self, s, now):
        """Waiting attacks that came to matter (queued now), and the ones whose fight ended quietly."""
        out = []
        live = {f.get("key"): f for f in s.get("fights") or []}
        for key, p in list(self.pending.items()):
            why = self.why(p["e"], s, now)
            if why:
                out.append(dict(p["e"], t=now, why_it_matters=why))
                del self.pending[key]
                continue
            f = live.get(p["e"].get("alert_key"))
            if now - p["t"] > PENDING_MAX or not f or now - (f.get("last") or 0) > 60:
                self.quiet.append((p["t"], p["e"].get("text") or "an attack"))
                del self.pending[key]
        return out

    def quiet_note(self, now):
        """Quiet hits of the last few minutes, for a word in another line; None when there are none."""
        recent = [text for t, text in self.quiet if now - t <= QUIET_WINDOW]
        if not recent:
            return None
        return (f"{len(recent)} small hit{'s' if len(recent) > 1 else ''} in the last {QUIET_WINDOW // 60} minutes "
                f"with nothing lost (latest: {recent[-1]}); a word at most, never its own line")


class StoryMemo:
    def __init__(self, path=None):
        self.path = path
        self.headlines = []   # {"t", "text"}, oldest first
        self.memo, self.built = None, 0.0
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    d = json.load(f)
                self.headlines = list(d.get("headlines") or [])[-20:]
                self.memo = d.get("memo")
            except (OSError, ValueError):
                pass

    def note(self, e, now):
        """A beat of the run's story: a headline, a death, a space first, a big loss."""
        text = None
        if e.get("kind") in ("headline", "space", "death"):
            text = e.get("text")
        elif e.get("kind") == "loss" and loss_pieces(e.get("text")) >= BIG_LOSS:
            text = e.get("text")
        if not text or any(h["text"] == text and now - h["t"] < 600 for h in self.headlines):
            return
        self.headlines = (self.headlines + [{"t": now, "text": text}])[-20:]
        self.save()

    def update(self, s, now, force=False):
        """Rebuild the memo from the snapshot every MEMO_EVERY seconds."""
        if not force and self.memo and now - self.built < MEMO_EVERY:
            return self.memo
        self.built = now
        board = s.get("board") or {}
        plan = board.get("plan") or {}
        names = {a.get("name"): a.get("display_name") or a.get("name") for a in s.get("agents") or []}
        lines = {d.get("name"): d.get("text") for d in plan.get("doing") or []}
        agents = []
        for a in s.get("agents") or []:
            if not a.get("seen", True):
                continue
            name = a.get("display_name") or a.get("name")
            on = lines.get(a.get("name")) or lines.get(name) or a.get("job") or a.get("activity")
            parts = [f"{name}: {short(on, 120).rstrip('.') if on else 'no plan line'}"]
            if a.get("where") and a["where"] != "Nauvis":
                parts.append(f"On {a['where']}")
            said = a.get("last_said") or {}
            if said.get("text") and now - float(said.get("t") or now) < 900:
                parts.append(f"Said {int((now - float(said.get('t') or now)) // 60)} min ago: \"{short(said['text'], 110)}\"")
            if a.get("alive") is False:
                parts.append("Dead, respawning")
            agents.append(". ".join(parts))
        res = s.get("research") or {}
        research = None
        if res.get("label"):
            pct = res.get("progress")
            research = f"{res['label']}" + (f", {int(round(pct * 100 if pct <= 1 else pct))}% done" if pct else "")
        an = s.get("analyst") or {}
        stuck = [short(x.get("text"), 160) for x in an.get("storylines") or []
                 if isinstance(x, dict) and x.get("status") in ("new", "developing") and x.get("text")][:3]
        memo = {
            "goals": short(plan.get("goals"), 260) or None,
            "headlines": [f"{clock(h['t'])} {h['text']}" for h in self.headlines[-HEADLINES:]] or None,
            "agents": agents or None,
            "research": research,
            "stuck_or_developing": stuck or None,
            "state_of_play": short(an.get("headline"), 200) or None,
            "as_of": clock(now),
        }
        self.memo = {k: v for k, v in memo.items() if v}
        self.save()
        return self.memo

    def facts(self):
        if not self.memo:
            return None
        return dict(self.memo, note=("background for understanding this beat: who is doing what and why, what happened "
                                     "earlier. Never recite it or list it; use a piece only when it explains this beat, "
                                     "in a few words"))

    def save(self):
        if not self.path:
            return
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"headlines": self.headlines, "memo": self.memo}, f, ensure_ascii=False)
            os.replace(tmp, self.path)
        except OSError:
            pass


def short(text, n):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    if len(text) <= n:
        return text
    cut = text[:n].rsplit(" ", 1)[0]
    return cut.rstrip(",;:") + "..."
