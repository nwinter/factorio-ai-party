#!/usr/bin/env python3
"""A fact-only nudge for idle characters (operator; tools/start-team.sh runs it beside the supervisors).

  python3 tools/idle_nudge.py --run runs/RUN --world n [--port 27025] [--dry-run] [--once]

shift05: Sonnet's character stood still most of the shift (a short plan, then long sleeps) and it discarded its fh
replies, so it missed the team's messages. Every --poll seconds this reads the harness's operator `idle_report`
(idle.lua, read only) and sends one operator tell (tells.lua: the next reply's team tells, and a wake from sleep;
never the game chat) to an agent whose character has stood --idle-min minutes or more: nothing that moves or works it, a body on the map
(dead or in a cargo pod is not standing). A wait is not work: wait_ticks, wait_until and sleep, and a queue held behind
a direct wait (the plan runs only after it), count as standing (shift07: Sonnet waited 20000-30000 ticks back to back
from 15:13 to 16:24 with its loop3 plan queued behind each wait, and was never nudged); work seen in one poll only (a
few seconds between waits) does not end standing. One definition of idle (agent-minds study, fix 2): a harness that
reports `counted` (idle.lua: the clock line on every reply uses the same busy()) is the only count; standing ends on a
game action that changed something, a move to a new spot, or 20 s of work summed over 2 minutes (shift07: 0 of 227
short walks by Grok and Muse ended it under the old rule, so half the nudges were false and agents learned to dismiss
them). Before such a harness, standing is the longer of the harness's count and this process's own, so an older
harness that counts waits as work is covered too. A standing order running for the agent (orders.lua: the report's
`orders.running`) is work, so never nudged, and so is a bounded watch running (the report's `measuring`: uptime,
turret_tally, belt_flow; d20 batch70 AF1: Haiku was nudged 72 s into a 120 s uptime watch at d21 12:11:50 and 74 s
into another at 12:51:53); a watch late, stalled, invalid or done with its final not read is named in the tell
(`measures`). The tell holds facts only: how long, the wait, the queue and sleep state, the standing orders set, what was counted over the last 10 minutes and what idle means, what waits unread. At most
once per --every-min minutes per agent, never in the first --grace-min minutes after this process starts (the shift
start), and not after the run's deadline. Each nudge is a line in runs/RUN/nudges.jsonl (sent or not, and why not),
with since_last_nudge: whether a reply delivered the last nudge's tell (its unread tells went to 0) and whether the
agent made requests since. Delivered is not read: Sonnet writes its replies to a file and reads the last 2 lines.
(d24 batch158, viewer Aurora 11:50 and 11:51) A tell holds 500 bytes: the nudge says how long, the unread counts and
the queue first, then the standing orders, watches, the sleep's reason, what is open (unanswered items first), what was
counted and what idle means, each while it fits (the first that does not is cut at a word). An agent resting
(resting.json) gets none. One that does not answer (a nudge's tell not delivered and no request of its own in its
journal since; or its herdr pane idle or done with no request of its own for 30 min) is nudged at every_min doubled
for each nudge it did not answer, at most every 4 h; only the idle nudge backs off (the harness's urgent alerts and
tells go as before). While it rests or does not answer, one handoff tell goes to the first --lead that is active (a
request of its own in the last 10 min, not resting; else the team member with the most recent request of its own)
naming what waits on it (unanswered requests and tells, its board items, claims), when anything does.
The same supervisor sends a cached factory digest once at deadline - 2 h: what changed since the last digest, each
fact told to its owner by board claim (factory_digest.py, d17 batch35 D2). --digest-now sends the full census to the
team (on request) and exits; --dry-run logs without sending.
"""
import argparse, datetime, json, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.dont_write_bytecode = True
from factory_digest import Digest, haul_lines
import pacing  # noqa: E402  (tools/stream/pacing.py: an agent's rest between turns)


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def minutes(s):
    return int(round((s or 0) / 60))


def queue_text(q):
    q = q or {}
    if q.get("state") == "paused":
        return f"paused with {q.get('steps', 0)} steps"
    if q.get("state") == "running":
        return "running"
    return "empty" if q.get("state") == "empty" else "none"


def orders_text(o):
    """The report's standing orders (orders.lua report: {set, running, paused, operator_paused}), or '' with none set."""
    if not o or not o.get("set"):
        return ""
    n = o["set"]
    state = "paused by the operator" if o.get("operator_paused") else "paused" if o.get("paused") else "none running"
    # armed (d17 batch16 A5, cp4): the orders on watch are named; the standing time still counts and the nudge fires
    watch = f"; on watch: {o['armed']}" if o.get("armed") else ""
    return f" Standing orders: {n} set, {state}{watch}."


WAITS = ("wait_ticks", "wait_until", "sleep")  # not work (idle.lua WAITS)


def working(row):
    """Something moves or works the character now: an action that is not a wait, or a queue that can run (a queue
    is held behind a direct wait)."""
    act = row.get("action")
    if act:
        return act not in WAITS
    return (row.get("queue") or {}).get("state") == "running"


TELL_MAX = 500   # bytes in one tell (tells.lua MAX_LEN): the harness cuts a longer text at 500


def cut_bytes(text, room):
    """text in at most `room` UTF-8 bytes, cut at a word with "..." when it does not fit; '' when under 24 bytes fit."""
    if len(text.encode()) <= room:
        return text
    if room < 24:
        return ""
    head = text.encode()[:room - 3].decode("utf-8", "ignore")
    if " " in head:
        head = head.rsplit(" ", 1)[0]
    return head.rstrip(" ,;:(") + "..."


def fit(essential, parts, limit=TELL_MAX):
    """(d24 batch158, viewer Aurora 11:50: Muse's nudge of 677-1059 bytes was cut at 500 in the unread field, "20") the
    essential sentences always, then each part in order while it fits; the first that does not is cut at a word, and
    nothing after it."""
    text = essential
    for part in parts:
        if not part:
            continue
        room = limit - len(text.encode())
        if len(part.encode()) <= room:
            text += part
            continue
        text += cut_bytes(part, room)
        break
    return cut_bytes(text, limit)


def nudge_text(row, standing_s=None):
    """The tell: facts only, no advice, in at most TELL_MAX bytes: how long, the unread counts and the queue first."""
    sleep = f", sleeping {minutes(row['sleeping_s'])} min" if row.get("sleeping_s") else ""
    def count(n, what):
        return f"{n} {what}" + ("" if n == 1 else "s")
    mentions = max(0, (row.get("unread_mentions") or 0) - (row.get("unread_tells") or 0))
    chat = count(row.get("unread_chat") or 0, "chat message")
    if row.get("unread_chat") and row.get("unread_chat_to_you") is not None:  # (d23 batch121 CD1) those naming you
        chat += f" ({row['unread_chat_to_you']} naming you)"
    unread = [chat, count(mentions, "mention"), count(row.get("unread_tells") or 0, "tell")]
    if row.get("unacked_tells"):  # shown in a team block, not yet marked read (chat_ack, reply_to or a tells read)
        unread.append(count(row["unacked_tells"], "tell") + " shown, not acknowledged"
                      + (f" (oldest {minutes(row['unacked_oldest_s'])} min)" if row.get("unacked_oldest_s") is not None else ""))
    if row.get("unread_board"):
        unread.append(count(row["unread_board"], "board line"))
    act = row.get("action")
    if act in WAITS:
        q = row.get("queue") or {}
        held = (f", your queue's {q['steps']} steps start only after it" if q.get("state") == "running" and q.get("steps")
                else "")
        doing = f"in {act}{held}{sleep}"
    else:
        doing = f"no action, no queue step{sleep}"
    standing = standing_s if standing_s is not None else row.get("standing_s")
    counted = (row.get("counted") or {}).get("text")
    essential = (f"Operator (automatic, facts only): idle for {minutes(standing)} min ({doing}). "
                 "Unread for you: " + ", ".join(unread) + f". Queue: {queue_text(row.get('queue'))}.")
    return fit(essential, [orders_text(row.get("orders")), watches_text(row.get("measures")),
                           reason_text(row.get("sleep_reason")), open_text(row.get("open")),
                           f" Counted, {str(counted).rstrip('.')}." if counted else "",
                           " Idle: a wait or sleep counts; a game action that changed something, a move to a new spot or "
                           "20 s of work in 2 min ends it." if counted else ""])


def reason_text(reason):
    """(d20 batch70 AF1, operator d21 13:18) the agent's own reason to wait, given with its sleep, quoted as given."""
    return f" Your reason to wait (your sleep): {str(reason).strip().rstrip('.')}." if reason else ""


def flagged(measures):
    """The agent's bounded watches that need it (measures.lua): late, stalled, invalid, or done with the final not read."""
    return [m for m in measures or [] if m.get("state") in ("late", "stalled", "invalid")
            or m.get("state") == "done" and not m.get("final_read")]


def watches_text(measures):
    """(d20 batch70 AF1) its watches that are not running and need it, each the harness's line; '' with none."""
    lines = [str(m.get("line") or m.get("id")).rstrip(".") for m in flagged(measures)]
    return f" Watches: {'; '.join(lines)}." if lines else ""


def top_items(text, sep="; "):
    """text split at sep outside parentheses."""
    out, depth, start, i = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        depth += c == "("
        depth -= c == ")" and depth > 0
        if depth == 0 and text.startswith(sep, i):
            out.append(text[start:i]); start = i + len(sep); i = start; continue
        i += 1
    out.append(text[start:])
    return [x for x in out if x.strip()]


def open_text(line):
    """The harness's "open for you" line (open.lua, d15 H3: board items, alert groups and idle machines in fresh claims,
    unanswered requests and tells), as a sentence of the nudge; nothing from a harness before it. (d24 batch158) The
    items naming something unanswered come first, so a cut at the tell's length keeps them."""
    if not line:
        return ""
    line = str(line).strip().rstrip(".")
    head, sep, rest = line.partition(": ")
    if not sep:
        return " " + line[0].upper() + line[1:] + "."
    items = top_items(rest)
    items = [x for x in items if "unanswered" in x] + [x for x in items if "unanswered" not in x]
    return " " + head[0].upper() + head[1:] + ": " + "; ".join(items) + "."


def own_request_at(run_dir, name):
    """When the agent's journal (runs/RUN/AGENT/journal.jsonl) last holds a request of its own (not describe, profiles,
    cameras or a peek), as Unix seconds; None with none in its last 400 KB. The harness's last_request_s also counts
    reads others make of it, so it is not the session's own sign of life (d24 batch158: Muse's rows read requests
    while its journal held none for hours)."""
    if not run_dir:
        return None
    try:
        with open(os.path.join(run_dir, name, "journal.jsonl"), "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 400000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        if '"event":"request"' not in line and '"event": "request"' not in line:
            continue
        try:
            e = json.loads(line)
            req = e.get("request") or {}
            if req.get("action") in pacing.NOT_OWN or (req.get("args") or {}).get("peek"):
                continue
            return datetime.datetime.fromisoformat(e["at"].replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
    return None


def herdr_status(run_dir):
    """The agent's pane status as herdr reports it (agent_status: working, idle, done, blocked), from panes.txt's pane;
    a function of the agent's name, None where it cannot be read (no herdr, no pane)."""
    panes = {}
    try:
        for l in open(os.path.join(run_dir, "panes.txt")):
            parts = l.split()
            if len(parts) >= 2:
                panes[parts[0]] = parts[1]
    except OSError:
        pass

    def status(name):
        import subprocess
        pane = panes.get(name)
        if not pane:
            return None
        try:
            out = subprocess.run(["herdr", "pane", "get", pane], capture_output=True, text=True, timeout=5).stdout
            return (json.loads(out) or {}).get("agent_status")
        except Exception:
            return None
    return status


class Nudger:
    """The rules, apart from RCON (tests drive it with a fake report and a fake send)."""

    # (d24 batch158, viewer Aurora 11:51) a session that does not answer: idle nudges back off (every_min doubled for
    # each nudge not answered, at most BACKOFF_MAX); a pane idle or done with no request of its own for STOPPED_S is a
    # session that stopped (back off from the first); a handoff goes to an active lead once while it does not answer
    BACKOFF_MAX = 4 * 3600
    STOPPED_S = 30 * 60
    ACTIVE_S = 10 * 60   # a lead with a request of its own this recent is active

    def __init__(self, members=None, idle_min=10, every_min=20, grace_min=5, start=None, deadline=None, run_dir=None,
                 pane_status=None, leads=None):
        self.members = set(members or [])
        self.run_dir = run_dir
        self.idle_s, self.every_s, self.grace_s = idle_min * 60, every_min * 60, grace_min * 60
        self.start = start if start is not None else time.time()
        self.deadline = deadline
        self.last = {}  # agent -> time of its last nudge
        self.idle_since = {}  # agent -> since when this process has seen it standing (waits are standing)
        self.busy_polls = {}  # agent -> polls in a row it was seen working (one alone does not end standing)
        self.since = {}  # agent -> since its last nudge: {tell_delivered, requests}
        self.pane_status = pane_status or (lambda name: None)
        self.leads = list(leads or [])
        self.unanswered = {}  # agent -> nudges in a row with no answer (tell not delivered, no request of its own since)
        self.handed = {}  # agent -> the reason a handoff was sent for, while it does not answer

    def observe(self, row, now):
        """This poll's view of an agent: its own standing count, and what happened since its last nudge."""
        name = row["name"]
        if not row.get("alive", True):
            self.idle_since.pop(name, None)
            self.busy_polls.pop(name, None)
        elif working(row) or (row.get("orders") or {}).get("running") or row.get("measuring"):
            self.busy_polls[name] = self.busy_polls.get(name, 0) + 1
            if self.busy_polls[name] >= 2:
                self.idle_since.pop(name, None)
        else:
            self.busy_polls[name] = 0
            self.idle_since.setdefault(name, now - (row.get("standing_s") or 0))
        if name in self.last:
            s = self.since.setdefault(name, {"tell_delivered": False, "requests": False})
            if not (row.get("unread_tells") or 0):
                s["tell_delivered"] = True
            if row.get("last_request_s") is not None and now - row["last_request_s"] > self.last[name]:
                s["requests"] = True
            if self.answered(name):
                self.unanswered[name] = 0
                self.handed.pop(name, None)

    QUEUE_WORK = ('"action":"queue_submit"', '"action":"queue_repeat"', '"action":"queue_resume"', '"action":"plan_run"')

    def queue_work(self, name, now):
        """Did the agent start queued work within the idle window (journal requests)? A queue of short jobs can finish
        between two polls, so the polls see an empty queue while the character works (shift07 19:08, Sol: 30+ queue
        jobs in 10 min, nudged as idle). Until the harness's own standing count sees queue steps (eng/minds-waits)."""
        if not self.run_dir:
            return False
        path = os.path.join(self.run_dir, name, "journal.jsonl")
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 400000))
                lines = f.read().decode("utf-8", "replace").splitlines()
        except OSError:
            return False
        for line in reversed(lines):
            if '"event":"request"' not in line or not any(k in line for k in self.QUEUE_WORK):
                continue
            try:
                at = datetime.datetime.fromisoformat(json.loads(line)["at"].replace("Z", "+00:00")).timestamp()
            except Exception:
                continue
            return now - at < min(300, self.idle_s)  # a plan started 8 min ago and long finished is not work now
        return False

    def standing(self, row, now):
        """The harness's count where it reports what it counted (one definition, idle.lua); before that, the longer of
        the harness's count and this process's own."""
        if row.get("counted"):
            return row.get("standing_s") or 0
        own = now - self.idle_since[row["name"]] if row["name"] in self.idle_since else 0
        return max(row.get("standing_s") or 0, own)

    def due(self, row, now):
        """None when this agent gets a nudge now, else why not (only for agents standing long enough)."""
        if self.members and row["name"] not in self.members:
            return "not on the team"
        if self.standing(row, now) < self.idle_s or not row.get("alive", True):
            return "active"
        if working(row):
            return "in an action"
        if (row.get("orders") or {}).get("running"):
            return "running a standing order"
        if row.get("measuring"):  # (d20 batch70 AF1) a bounded watch running: uptime, turret_tally, belt_flow
            return f"measuring ({row['measuring']})"
        if self.queue_work(row["name"], now):
            return "queued work in its journal"
        if now - self.start < self.grace_s:
            return "first minutes of the shift"
        rest = self.run_dir and pacing.resting(os.path.join(self.run_dir, row["name"]), now)
        if rest:  # the agy loop sleeps between turns (tools/agy-quota.py): nobody reads a tell until it wakes
            return pacing.label(rest, now)
        quiet = self.not_answering(row["name"], now)
        if quiet:
            return quiet
        if self.deadline and now >= self.deadline:
            return "after the deadline"
        if now - self.last.get(row["name"], -1e18) < self.every_s:
            return f"nudged in the last {self.every_s / 60:g} min"
        return None

    def answered(self, name):
        """Since its last nudge: the tell was delivered, or the agent made a request of its own (its journal; with no
        run folder, the harness's count)."""
        s = self.since.get(name) or {}
        if s.get("tell_delivered"):
            return True
        if not self.run_dir:
            return bool(s.get("requests"))
        own = own_request_at(self.run_dir, name)
        return own is not None and own > self.last.get(name, 1e18)

    def silence(self, name, now):
        """(k, why): how many nudges it has not answered (a stopped session counts 1 from the start) and the facts."""
        k = self.unanswered.get(name, 0)
        own = own_request_at(self.run_dir, name)
        quiet_min = minutes(now - own) if own is not None else None
        pane = self.pane_status(name)
        stopped = pane in ("idle", "done") and (own is None or now - own >= self.STOPPED_S)
        parts = []
        if k:
            parts.append(f"{k} nudge{'' if k == 1 else 's'} not delivered and no request of its own since")
        if stopped:
            parts.append(f"its pane reads {pane}")
        if parts:
            parts.append(f"no request of its own for {quiet_min} min" if quiet_min is not None else "no request of its own in its journal")
        return max(k, 1 if stopped else 0), "; ".join(parts)

    def not_answering(self, name, now):
        """None, or why an idle nudge waits: the session does not answer and the backed-off interval has not passed."""
        k, why = self.silence(name, now)
        if not k:
            return None
        every = min(self.every_s * 2 ** k, self.BACKOFF_MAX)
        if now - self.last.get(name, -1e18) < every:
            return f"not answering ({why}): idle nudges every {every / 60:g} min while it does not answer"
        return None

    def lead_for(self, name, report, now):
        """The lead a handoff goes to: the first of --lead that is active (a request of its own in the last ACTIVE_S, not
        resting), else the team member with the most recent request of its own; never the agent itself."""
        names = [r["name"] for r in report.get("agents") or [] if r["name"] != name and (not self.members or r["name"] in self.members)]

        def active_at(n):
            at = own_request_at(self.run_dir, n)
            rest = self.run_dir and pacing.resting(os.path.join(self.run_dir, n), now)
            return at if at is not None and not rest and now - at <= self.ACTIVE_S else None
        for n in self.leads:
            if n != name and active_at(n) is not None:
                return n
        best = max(((active_at(n), n) for n in names if active_at(n) is not None), default=None)
        return best[1] if best else None

    def handoff(self, row, why, report, now, send, write):
        """Once while an agent does not answer (resting, or not answering nudges): a tell to the active lead naming what
        waits on it (the open items with something unanswered, a claim or a board item), when anything does."""
        name = row["name"]
        if name in self.handed:
            return None
        import re
        items = [x for x in top_items(str(row.get("open") or "").partition(": ")[2].rstrip("."))
                 if "unanswered" in x or "board item" in x or re.search(r"\bclaim #\d", x)]
        items = [x for x in items if "unanswered" in x] + [x for x in items if "unanswered" not in x]
        if not items:
            return None
        lead = self.lead_for(name, report, now)
        entry = {"t": datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"), "agent": name,
                 "handoff": True, "why": why, "lead": lead}
        if not lead:
            entry.update(sent=False, error="no active lead (--lead, or a team member with a request of its own in 10 min)")
        else:
            text = fit(f"Operator (automatic, facts only): {name} does not answer ({why}).",
                       [" Waiting on it: " + "; ".join(items) + "."])
            entry["text"] = text
            try:
                res = send(lead, text)
                entry.update(sent=True, tell_seq=(res or {}).get("seq"))
            except Exception as e:
                entry.update(sent=False, error=f"{type(e).__name__}: {e}"[:200])
        self.handed[name] = why
        write(entry)
        return entry

    def step(self, report, now, send, write):
        """One poll: nudge every agent that is due; write a log row for each nudge sent (or that failed to send); a
        handoff to the active lead for one that does not answer."""
        out = []
        for row in report.get("agents") or []:
            self.observe(row, now)
            why = self.due(row, now)
            if why is not None:
                if why.startswith("not answering") or (self.run_dir and pacing.resting(os.path.join(self.run_dir, row["name"]), now)):
                    h = self.handoff(row, why, report, now, send, write)
                    if h:
                        out.append(h)
                continue
            standing = self.standing(row, now)
            text = nudge_text(row, standing)
            entry = {"t": datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"),
                     "agent": row["name"], "standing_min": minutes(standing), "action": row.get("action"),
                     "queue": queue_text(row.get("queue")), "sleeping_min": minutes(row.get("sleeping_s")) or None,
                     "unread": {k: row.get(k) or 0 for k in ("unread_chat", "unread_chat_to_you", "unread_mentions",
                                                             "unread_tells", "unacked_tells", "unread_board")},
                     "last_request_min": minutes(row.get("last_request_s")) if row.get("last_request_s") is not None
                     else None, "counted": (row.get("counted") or {}).get("text"), "text": text}
            if flagged(row.get("measures")):
                entry["watches"] = [{k: m.get(k) for k in ("id", "state", "end_tick", "final_read")} for m in flagged(row.get("measures"))]
            if row["name"] in self.last:  # did a reply carry the last nudge, and has the agent asked anything since?
                entry["since_last_nudge"] = dict(self.since.get(row["name"]) or {"tell_delivered": False,
                                                                                  "requests": False})
            try:
                res = send(row["name"], text)
                entry.update(sent=True, tell_seq=(res or {}).get("seq"))
                # the last nudge not answered (its tell not delivered, no request of its own since): one more
                if row["name"] in self.last and row["name"] in self.since and not self.answered(row["name"]):
                    self.unanswered[row["name"]] = self.unanswered.get(row["name"], 0) + 1
                entry["unanswered"] = self.unanswered.get(row["name"], 0) or None
                self.last[row["name"]] = now
                self.since[row["name"]] = {"tell_delivered": False, "requests": False}
            except Exception as e:
                entry.update(sent=False, error=f"{type(e).__name__}: {e}"[:200])
            write(entry)
            out.append(entry)
        return out


class Harness:
    """Operator dispatches over RCON (the operator's own password, as tools/pog.py: agents never hold it)."""

    def __init__(self, world, port=None):
        import pog
        self.pog = pog
        self.port = port or pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
        self.pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.rcon = None

    def dispatch(self, action, args, request_id=None):
        from harness import lua_string
        req = {"id": request_id or f"idle-nudge-{time.time_ns()}", "operator": True, "action": action, "args": args}
        cmd = ('/silent-command rcon.print(remote.call("agent_harness","dispatch",'
               + lua_string(json.dumps(req, ensure_ascii=False)) + '))')
        for attempt in (0, 1):
            try:
                if self.rcon is None:
                    self.rcon = self.pog.Rcon("127.0.0.1", self.port, self.pw, timeout=10)
                reply = json.loads(self.rcon.command(cmd) or "{}")
                break
            except (OSError, ConnectionError):
                self.rcon = None
                if attempt:
                    raise
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {(reply.get('error') or {}).get('message', reply)}")
        return reply.get("result") or {}


def run_deadline(run):
    """The run's deadline (any workspace's deadline.txt, "2026-10-13 10:56 PDT"), as Unix seconds, or None."""
    for name in sorted(os.listdir(run)):
        path = os.path.join(run, name, "deadline.txt")
        if os.path.isfile(path):
            text = open(path).read().strip()
            try:
                return time.mktime(time.strptime(text.rsplit(" ", 1)[0], "%Y-%m-%d %H:%M"))
            except ValueError:
                return None
    return None


def team_members(run):
    """Agent names from panes.txt (start-team.sh), else none (every agent the report lists)."""
    path = os.path.join(run, "panes.txt")
    if not os.path.isfile(path):
        return []
    return [l.split()[0] for l in open(path) if l.strip()]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", required=True, help="runs/RUN (nudges.jsonl goes here)")
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "n"))
    ap.add_argument("--port", type=int)
    ap.add_argument("--poll", type=float, default=60.0)
    ap.add_argument("--idle-min", type=float, default=10)
    ap.add_argument("--every-min", type=float, default=20)
    ap.add_argument("--grace-min", type=float, default=5)
    ap.add_argument("--lead", action="append", default=[], help="an agent a handoff goes to while it is active (repeat for several; "
                    "default: the team member with the most recent request of its own)")
    ap.add_argument("--dry-run", action="store_true", help="log what would be sent; send nothing")
    ap.add_argument("--once", action="store_true", help="one poll (with --grace-min 0 to check the rules now)")
    ap.add_argument("--digest-now", action="store_true", help="send the full cached factory census to the team now, then exit (no idle nudges)")
    a = ap.parse_args()
    h = Harness(a.world, a.port)
    n = Nudger(team_members(a.run), a.idle_min, a.every_min, a.grace_min, deadline=run_deadline(a.run), run_dir=a.run,
               pane_status=herdr_status(a.run), leads=a.lead)
    # (d17 batch35 D5) each agent's most repeated haul this shift, and its destination's feed now, in its part of the delta
    digest = Digest(a.run, n.deadline, extra=lambda report: haul_lines(a.run, h.dispatch))
    if a.digest_now:
        for row in digest.step(time.time(), h.dispatch, manual=True, dry_run=a.dry_run):
            log(row['text'])
        return
    path = os.path.join(a.run, "nudges.jsonl")

    def send(name, text):
        if a.dry_run:
            return {"dry_run": True}
        return h.dispatch("tell", {"to": name, "text": text})

    def write(entry):
        if a.dry_run:
            entry["dry_run"] = True
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        if entry.get("handoff"):
            log(f"handoff for {entry['agent']} to {entry.get('lead')}: {'sent' if entry.get('sent') else entry.get('error')}")
            return
        since = entry.get("since_last_nudge")
        log(f"nudge {entry['agent']}: {'sent' if entry.get('sent') else entry.get('error')} ({entry['standing_min']} min"
            + (f", {entry['action']}" if entry.get("action") else "")
            + (f"; since the last nudge: tell {'delivered' if since['tell_delivered'] else 'not delivered'}, "
               f"{'requests' if since['requests'] else 'no requests'}" if since else "") + ")")

    log(f"idle nudges for {a.run}: {len(n.members) or 'all'} agents, idle {a.idle_min} min, every {a.every_min} min, "
        f"grace {a.grace_min} min, deadline {time.strftime('%H:%M', time.localtime(n.deadline)) if n.deadline else '?'}"
        + (" (dry run)" if a.dry_run else ""))
    while True:
        now = time.time()
        digest.deadline = n.deadline = run_deadline(a.run)
        if n.deadline and now >= n.deadline:
            log("deadline reached")
            return
        try:
            for row in digest.step(now, h.dispatch, dry_run=a.dry_run):
                log(f"factory digest part {row['part']}: {'dry run' if a.dry_run else 'sent'}")
        except Exception as e:
            log(f"factory digest failed: {type(e).__name__}: {e}")
        try:
            n.step(h.dispatch("idle_report", {}), now, send, write)
        except Exception as e:
            log(f"poll failed: {type(e).__name__}: {e}")  # an old runtime without idle_report says so here
        if a.once:
            return
        time.sleep(a.poll)


if __name__ == "__main__":
    main()
