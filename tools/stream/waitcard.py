"""Current waits from the existing status/journal reads. No game reads of its own.

A timeout is a countdown only for an unconditional sleep/wait_ticks; it is never a
condition ETA. Idle seconds are the harness's measurement, not wall time standing.
"""
import math
import re
from datetime import datetime

STALE_S = 45
REASON_S = 300


def number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def short(text, limit):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1].rsplit(" ", 1)[0] + "…"


def duration(seconds, up=True):
    seconds = max(0, math.ceil(seconds))
    if seconds < 60:
        return f"{seconds} s"
    minutes = math.ceil(seconds / 60) if up else seconds // 60
    if minutes < 60:
        return f"{minutes} min"
    return f"{minutes // 60} h {minutes % 60} min"


def record(result, tick, at, kind):
    if not isinstance(result, dict) or not number(tick):
        return None
    if result.get("woke") or result.get("already_met") or result.get("repeat") or result.get("outcome"):
        return None
    until = result.get("until_tick")
    if not number(until) or until <= tick:
        return None
    rows = result.get("wait_estimates")
    rows = [dict(r) for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
    condition = result.get("condition")
    if isinstance(condition, dict):
        condition = " ".join(str(condition[k]) for k in ("until", "technology", "item", "platform") if condition.get(k))
    return {"kind": kind, "tick": tick, "at": at, "until_tick": until, "estimates": rows,
            "condition": condition, "idle_s": result.get("idle_s")}


def line(wait, tick, now):
    if not wait or now - wait["at"] > STALE_S or tick >= wait["until_tick"]:
        return None
    rows = wait["estimates"]
    labels = [str(r.get("condition") or "condition").replace("_", " ") for r in rows]
    label = " or ".join(short(s, 32) for s in labels[:2])
    if len(labels) > 2:
        label += f" or {len(labels) - 2} more"
    label = label or str(wait.get("condition") or ("sleep" if wait["kind"] == "sleep" else "timer")).replace("_", " ")
    estimates = [max(0, r["eta_s"] - max(0, tick - r.get("as_of_tick", wait["tick"])) / 60)
                 for r in rows if number(r.get("eta_s")) and number(r.get("as_of_tick", wait["tick"]))]
    if estimates:
        eta = "~" + duration(min(estimates)) if min(estimates) > 0 else "checking"
    elif rows or wait.get("condition"):
        eta = "ETA unknown"
    else:
        eta = "up to " + duration((wait["until_tick"] - tick) / 60)  # wakes may end a sleep early
    idle = wait.get("idle_s")
    idle_text = f" (idle {duration(idle, up=False)})" if number(idle) else ""
    return f"waiting: {short(label, 64)}, {eta}{idle_text}"


# Only a statement about the speaker's own wait; never infer a motive from a job,
# someone else's statement, or general logistics chat. Keep the original words.
SELF_WAIT = re.compile(r"\b(?:I|we)(?:['’]m| am|['’]re| are|['’]ll| will)?\s+(?:(?:am|will|going to|just|still)\s+)*"
                       r"(?:wait(?:ing)?|sleep(?:ing)?|idl(?:e|ing)|paus(?:e|ing))\b|"
                       r"^(?:wait(?:ing)?|sleep(?:ing)?|idl(?:e|ing)|paus(?:e|ing))\s+(?:\d+\s*(?:s|seconds?|m|min(?:utes?)?)\s+)?(?:for|until|while|because|to)\b", re.I)


def reason(chat, agent, tick, now):
    for m in reversed(chat):
        if m.get("agent") != agent or m.get("viewer") or m.get("source") or m.get("notice") or m.get("lane") in ("tells", "operator"):
            continue
        if not number(m.get("t")) or not 0 <= now - m["t"] <= REASON_S:
            continue
        if number(m.get("tick")) and not 0 <= tick - m["tick"] <= REASON_S * 60:
            continue
        for sentence in reversed(re.split(r"(?<=[.!?])\s+|[\r\n]+", m.get("text") or "")):
            if SELF_WAIT.search(sentence):
                return short(sentence, 160)
    return None


class WaitFeed:
    """Fed journal rows by WorkFeed, with bounded pending request IDs and no extra file polling.

    Sleep and body/queue waits are separate: sleep can run while a queue works.
    A newer status clears a finished body wait, but does not cancel an active sleep.
    """
    def __init__(self):
        self.requests = {}
        self.waits = {}
        self.reasons = {}

    def reset(self, agent):
        self.requests.pop(agent, None)
        # LiveSource may already have polled status in this round. Keep that newer
        # body/queue observation when WorkFeed first opens or truncates a journal.
        self.waits.get(agent, {}).pop("sleep", None)

    def put(self, agent, channel, value, tick, at):
        if not number(tick):
            return
        slots = self.waits.setdefault(agent, {})
        # Multiple actions can occur at the same game tick while paused. Receipt
        # time breaks that tie so a bootstrap row cannot undo a newer status.
        if (tick, at) >= slots.get(channel, (-1, 0, None))[:2]:
            slots[channel] = (tick, at, value)

    def status(self, agent, result, tick, at):
        active = result.get("active")
        wait = record(active, tick, at, active.get("kind")) if isinstance(active, dict) and active.get("kind") in ("wait_until", "wait_ticks") else None
        self.put(agent, "body", wait, tick, at)
        for lane, q in (result.get("queues") or {}).items():
            if lane not in ("body", "remote") or not isinstance(q, dict):
                continue
            channel = "queue" if lane == "body" else "remote"
            if "waiting" in q or q.get("paused") or not q.get("active") or q["active"].get("action") not in ("wait_until", "wait_ticks"):
                self.put(agent, channel, record(q.get("waiting"), tick, at, "wait_until") if not q.get("paused") else None, tick, at)

    def ingest(self, agent, row):
        if not isinstance(row, dict):
            return
        if row.get("event") == "request":
            q = row.get("request") or {}
            pending = self.requests.setdefault(agent, {})
            pending[q.get("id")] = q
            while len(pending) > 128:
                pending.pop(next(iter(pending)))
            return
        if row.get("event") != "response":
            return
        response = row.get("response") or {}
        q = self.requests.get(agent, {}).pop(response.get("id"), {})
        if not response.get("ok") or not isinstance(response.get("result"), dict):
            return
        try:
            at = datetime.fromisoformat(row["at"].replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError, TypeError):
            return
        result, tick = response["result"], response.get("tick")
        action, args = q.get("action"), q.get("args") or {}
        if "sleeping_s" in result or "slept_s" in result or action == "sleep_check" or action == "observe" and args.get("scope") == "sleep_check":
            value = record(result, tick, at, "sleep")
            if action == "sleep":  # the agent's own reason to wait (fh sleep --reason), kept through its sleep_checks
                why = args.get("reason")
                self.reasons[agent] = short(why, 160) if isinstance(why, str) and why.strip() else None
            if value and self.reasons.get(agent):
                value["reason"] = self.reasons[agent]
            self.put(agent, "sleep", value, tick, at)
        elif action == "status" or "active" in result and "position" in result:
            self.status(agent, result, tick, at)
        elif action == "queue_status":
            channel = "remote" if args.get("lane") == "remote" else "queue"
            wait = result.get("waiting") if not result.get("paused") else None
            self.put(agent, channel, record(wait, tick, at, "wait_until"), tick, at)
        elif action in ("wait_until", "wait_ticks"):
            value = dict(result)
            if action == "wait_until":
                value.setdefault("condition", args)
            self.put(agent, "body", record(value, tick, at, action), tick, at)
        elif action == "stop":
            self.put(agent, "body", None, tick, at)
            self.put(agent, "queue", None, tick, at)

    def current(self, agent, tick, now):
        slots = self.waits.get(agent, {})
        available = [v for _, _, v in slots.values() if line(v, tick, now)]
        # A condition says more than an unconditional sleep while that same queue waits.
        return max(available, key=lambda v: (bool(v["estimates"] or v["condition"]), v["tick"]), default=None)
