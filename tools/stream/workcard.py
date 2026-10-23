"""An agent card's current work and its stale plan line or focus (d20 batch70 AF3, viewer Aurora, d21 15:07: "Could
agent cards show the engineer's own current task plus background tests/deadlines, and flag stale plan/focus text?
Sonnet's plan still says free while sampling Cinder").

Work rows come from reads the service makes anyway:
  watch   the agent's bounded watches (status {brief, work}: uptime, turret_tally, belt_flow, collector_tally,
          asteroid_watch, and the flight watches it set, d22 batch99 BI5), running or needing it (late, stalled,
          invalid, final not read; a flight watch armed, waiting for its departure), with its scope, end and latest sample
  queue   each queue lane's active step (status brief queues): the step, when it started, the submission it came in
  order   a standing order running (status brief order)
  repeat  the same request sent again and again at a steady interval, read from the agent's journal (RepeatFeed): a
          script of the agent's own sampling something (Sonnet's `platform Cinder` every 60 s from 14:53 PDT, for a
          validation it took on; the harness has no watch of it)

A plan line or focus is flagged stale, with the times, when it was set before the agent's current work began (a test
running TEST_GRACE_S, a queue run or standing order RUN_GRACE_S) and names none of it (a watch's kind, a repeated
request's target, a word of a queue step's label or job name or of a standing order's name), or when it is
STALE_TEST_S old while a test that has run TEST_GRACE_S goes on and it names none of that test. Facts only: nothing suggests what the text should say.
"""
import json
import math
import re
from datetime import datetime

from waitcard import short

TEST_GRACE_S = 120
RUN_GRACE_S = 300
STALE_TEST_S = 600
LINE = 200  # a work row's or flag's characters on the card
ROWS = 4  # work rows a card shows
# Repeating requests: at least REPEAT_MIN at intervals within REPEAT_TOL (or 3 s) of their mean, REPEAT_GAP_S apart at
# least and at most; current while the last came within twice the interval (plus 10 s).
REPEAT_MIN = 4
REPEAT_TOL = 0.25
REPEAT_GAP_S = (20, 1800)
# The agent's own loop and housekeeping, never a test of its own
REPEAT_SKIP = {"sleep", "sleep_check", "status", "chat", "describe", "profiles", "queue_status", "wait_until",
               "wait_ticks", "board", "board_events", "board_plan", "board_focus", "reminders", "tells", "inbox",
               "help", "whoami", "pending", "chat_ack", "reminder_ack", "conflicts"}
KIND_WORDS = {"uptime": ("uptime",), "turret_tally": ("turret", "tally"), "belt_flow": ("belt", "flow"),
              "collector_tally": ("collector", "tally"), "asteroid_watch": ("asteroid", "watch"),
              # (d22 batch99 BI5) the flight watches the agent set (status work: kind flight_watch, scope its platform)
              "flight_watch": ("flight", "watch")}
STOP_WORDS = {"with", "from", "into", "onto", "then", "that", "this", "wait", "ticks", "until", "step", "steps", "more"}


def words(*texts):
    """The words of 4 letters or more in a step label, job or order name or a target: what a line naming it holds."""
    out = []
    for t in texts:
        for w in re.split(r"[^a-z0-9]+", str(t or "").lower()):
            if len(w) >= 5 and w.endswith("s"):
                w = w[:-1]  # "smelters" named as "smelter"
            if len(w) >= 4 and w not in STOP_WORDS and w not in out:
                out.append(w)
    return tuple(out)


def number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def fmt_age(sec):
    """As model.fmt_age: 40 s, 12 min, 2 h, 2 h 15 min."""
    sec = int(max(0, sec))
    if sec < 90:
        return f"{sec} s"
    if sec < 90 * 60:
        return f"{round(sec / 60)} min"
    h, m = sec // 3600, sec // 60 % 60
    return f"{h} h" + (f" {m} min" if m else "")


def target_text(args):
    """A request's target in a few words: a platform, a name, a surface, a position."""
    parts = []
    for key in ("platform", "name", "surface", "item", "entity"):
        v = args.get(key)
        if isinstance(v, str) and v and v not in parts:
            parts.append(v)
    pos = args.get("position")
    if isinstance(pos, dict) and number(pos.get("x")) and number(pos.get("y")):
        parts.append(f"({pos['x']:g},{pos['y']:g})")
    if isinstance(args.get("area"), dict):
        parts.append("an area")
    return " ".join(parts[:3])


class RepeatFeed:
    """The same request (action and arguments) an agent sends at a steady interval, from its journal rows (fed by
    WorkFeed with the rows WaitFeed sees, the bounded tail at startup included)."""

    def __init__(self):
        self.requests = {}  # agent -> {request id: (signature, action, args, at)}
        self.runs = {}  # agent -> {signature: run}

    def ingest(self, agent, row):
        if not isinstance(row, dict):
            return
        if row.get("event") == "request":
            q = row.get("request") or {}
            action = q.get("action")
            if not isinstance(action, str) or action in REPEAT_SKIP or q.get("operator"):
                return
            args = q.get("args") if isinstance(q.get("args"), dict) else {}
            if action == "observe" and args.get("scope") == "sleep_check":
                return
            if action in KIND_WORDS and not args:  # a bounded watch's own read: its watch row shows it
                return
            sig = action + " " + json.dumps({k: v for k, v in args.items() if k != "peek"}, sort_keys=True)
            pending = self.requests.setdefault(agent, {})
            pending[q.get("id")] = (sig, action, args)
            while len(pending) > 128:
                pending.pop(next(iter(pending)))
            return
        if row.get("event") != "response":
            return
        resp = row.get("response") or {}
        got = self.requests.get(agent, {}).pop(resp.get("id"), None)
        if not got or not resp.get("ok"):
            return
        try:
            at = datetime.fromisoformat(row["at"].replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError, TypeError, AttributeError):
            return
        sig, action, args = got
        runs = self.runs.setdefault(agent, {})
        r = runs.get(sig)
        tick = resp.get("tick") if number(resp.get("tick")) else None
        if r and at > r["last_at"]:
            gap = at - r["last_at"]
            mean = (r["last_at"] - r["first_at"]) / (r["n"] - 1) if r["n"] > 1 else gap
            if REPEAT_GAP_S[0] <= gap <= REPEAT_GAP_S[1] and abs(gap - mean) <= max(3, REPEAT_TOL * mean):
                r.update(last_at=at, last_tick=tick, n=r["n"] + 1)
                return
            if REPEAT_GAP_S[0] <= gap <= REPEAT_GAP_S[1]:  # a new run from the last one
                runs[sig] = dict(r, first_at=r["last_at"], first_tick=r["last_tick"], last_at=at, last_tick=tick, n=2)
                return
        runs[sig] = {"action": action, "target": target_text(args), "first_at": at, "first_tick": tick,
                     "last_at": at, "last_tick": tick, "n": 1}
        if len(runs) > 64:
            for k in sorted(runs, key=lambda k: runs[k]["last_at"])[:-48]:
                del runs[k]

    def current(self, agent, now):
        """[{action, target, every_s, n, since_s, since_tick, last_s}] running now, newest start first."""
        out = []
        for r in (self.runs.get(agent) or {}).values():
            if r["n"] < REPEAT_MIN:
                continue
            every = (r["last_at"] - r["first_at"]) / (r["n"] - 1)
            if now - r["last_at"] > 2 * every + 10:
                continue
            out.append({"action": r["action"], "target": r["target"], "every_s": round(every), "n": r["n"],
                        "since_s": round(now - r["first_at"]), "since_tick": r["first_tick"],
                        "last_s": round(now - r["last_at"])})
        out.sort(key=lambda x: x["since_s"])
        return out[:3]


def _ago(tick, at_tick):
    return (tick - at_tick) / 60 if number(tick) and number(at_tick) else None


def rows(watches, queues, order, repeats, tick):
    """The card's work rows: [{kind, line, start_tick, test, words}] (start_tick None when unknown)."""
    out = []
    for w in watches or []:
        if not isinstance(w, dict):
            continue
        kind, state = w.get("kind") or "watch", w.get("state")
        what = f"{'flight' if kind == 'flight_watch' else kind} watch {w.get('id') or ''}".strip()
        scope = w.get("scope") or ""
        latest = (w.get("latest") or {}).get("line")
        left = _ago(w.get("end_tick"), tick)
        if state == "running":
            text = f"{what}, {scope}: ends in {fmt_age(left)}" if left is not None else f"{what}, {scope}: running"
            if latest:
                text += f"; latest: {latest}"
        else:
            since = _ago(tick, w.get("end_tick"))
            text = f"{what}, {scope}: " + {
                "done": "ended, its final result not read yet",
                "late": f"late: ended {fmt_age(since or 0)} ago and no final result came",
                "stalled": "stalled: no sample lately",
                "invalid": "invalid: nothing left to read",
                "armed": "waiting for its next departure" + (f", then at most {fmt_age(w['minutes'] * 60)}" if number(w.get("minutes")) else ""),
            }.get(state, str(state))
        if w.get("reason"):
            text += f"; its reason: {w['reason']}"
        out.append({"kind": "watch", "line": short(text, LINE), "test": state == "running",
                    "start_tick": w.get("start_tick") if state == "running" else None,
                    "what": f"its {kind} watch", "words": KIND_WORDS.get(kind, (kind,))})
    for lane in ("body", "remote"):
        q = (queues or {}).get(lane)
        act = q.get("active") if isinstance(q, dict) else None
        if not isinstance(act, dict) or q.get("paused"):
            continue
        step = act.get("label") or str(act.get("action") or "?").replace("_", " ")
        name = "queue" if lane == "body" else "remote queue"
        text = f"{name}: {step}"
        started = _ago(tick, act.get("started_tick"))
        if started is not None:
            text += f", started {fmt_age(started)} ago"
        if q.get("pending"):
            text += f"; {q['pending']} more queued"
        run = act.get("run") if isinstance(act.get("run"), dict) else None
        if run:
            since = _ago(tick, run.get("tick"))
            text += (f"; repeating job {run['name']}" if run.get("kind") == "repeat" and run.get("name") else
                     f"; submitted with {run.get('steps')} step{'' if run.get('steps') == 1 else 's'}")
            if since is not None:
                text += f" {fmt_age(since)} ago"
        out.append({"kind": "queue", "line": short(text, LINE), "test": False,
                    "start_tick": run.get("tick") if run else None, "what": f"its {name} run",
                    "words": words(act.get("label"), run and run.get("name"))})
    if isinstance(order, dict) and order.get("name"):
        text = f"standing order {order['name']}"
        if order.get("steps"):
            text += f": step {order.get('step')} of {order['steps']}"
        started = _ago(tick, order.get("started_tick"))
        if started is not None:
            text += f", started {fmt_age(started)} ago"
        out.append({"kind": "order", "line": short(text, LINE), "test": False, "start_tick": order.get("started_tick"),
                    "what": f"its standing order {order['name']}", "words": words(order["name"])})
    for r in repeats or []:
        what = " ".join(x for x in (r["action"], r.get("target")) if x)
        text = f"repeating request: {what} every {fmt_age(r['every_s'])} for {fmt_age(r['since_s'])} ({r['n']} so far)"
        out.append({"kind": "repeat", "line": short(text, LINE), "test": True, "start_tick": r.get("since_tick"),
                    "what": f"its repeating {what}",
                    "words": words(r.get("target"))})
    return out


def stale(texts, work, tick):
    """Flags for the card's plan line and focus. texts: [(label, set_tick, text)]; work: rows(). -> [line]"""
    out = []
    for label, set_tick, text in texts:
        if not number(set_tick) or not number(tick):
            continue
        age = (tick - set_tick) / 60
        low = (text or "").lower()
        def names(w):
            return any(x in low for x in w.get("words") or ())
        began = [w for w in work if number(w.get("start_tick")) and w["start_tick"] > set_tick and not names(w)
                 and (tick - w["start_tick"]) / 60 >= (TEST_GRACE_S if w["test"] else RUN_GRACE_S)]
        if began:
            w = max(began, key=lambda w: w["start_tick"])
            out.append(f"{label} set {fmt_age(age)} ago, before {w['what']} began {fmt_age((tick - w['start_tick']) / 60)} ago")
            continue
        if age < STALE_TEST_S:
            continue
        for w in work:
            ran = (tick - w["start_tick"]) / 60 if number(w.get("start_tick")) else None
            if ran is not None and ran < TEST_GRACE_S:
                continue  # too new to count
            if w["test"] and not names(w):
                out.append(f"{label} set {fmt_age(age)} ago does not mention {w['what']}" +
                           (f", running {fmt_age(ran)}" if ran is not None else ""))
                break
    return [short(x, LINE) for x in out]
