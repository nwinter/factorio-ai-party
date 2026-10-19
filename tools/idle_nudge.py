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
`orders.running`) is work, so never nudged. The tell holds facts only: how long, the wait, the queue and sleep state,
the standing orders set, what was counted over the last 10 minutes and what idle means, what waits unread. At most
once per --every-min minutes per agent, never in the first --grace-min minutes after this process starts (the shift
start), and not after the run's deadline. Each nudge is a line in runs/RUN/nudges.jsonl (sent or not, and why not),
with since_last_nudge: whether a reply delivered the last nudge's tell (its unread tells went to 0) and whether the
agent made requests since. Delivered is not read: Sonnet writes its replies to a file and reads the last 2 lines.
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


def nudge_text(row, standing_s=None):
    """The tell: facts only, no advice."""
    sleep = f", sleeping {minutes(row['sleeping_s'])} min" if row.get("sleeping_s") else ""
    def count(n, what):
        return f"{n} {what}" + ("" if n == 1 else "s")
    mentions = max(0, (row.get("unread_mentions") or 0) - (row.get("unread_tells") or 0))
    unread = [count(row.get("unread_chat") or 0, "chat message"), count(mentions, "mention"),
              count(row.get("unread_tells") or 0, "tell")]
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
    counted = (f" Counted, {counted} (a wait or sleep is idle; a game action that changed something, a move to a new "
               f"spot or 20 s of work in 2 minutes ends idle).") if counted else ""
    return (f"Operator (automatic, facts only): your character has stood idle for {minutes(standing)} min "
            f"({doing}).{counted} Queue: {queue_text(row.get('queue'))}.{orders_text(row.get('orders'))} "
            "Unread for you: " + ", ".join(unread) + "." + open_text(row.get("open")))


def open_text(line):
    """The harness's "open for you" line (open.lua, d15 H3: board items, alert groups and idle machines in fresh claims,
    unanswered requests and tells), as the nudge's last sentence; nothing from a harness before it."""
    if not line:
        return ""
    line = str(line).strip().rstrip(".")
    return " " + line[0].upper() + line[1:] + "."


class Nudger:
    """The rules, apart from RCON (tests drive it with a fake report and a fake send)."""

    def __init__(self, members=None, idle_min=10, every_min=20, grace_min=5, start=None, deadline=None, run_dir=None):
        self.members = set(members or [])
        self.run_dir = run_dir
        self.idle_s, self.every_s, self.grace_s = idle_min * 60, every_min * 60, grace_min * 60
        self.start = start if start is not None else time.time()
        self.deadline = deadline
        self.last = {}  # agent -> time of its last nudge
        self.idle_since = {}  # agent -> since when this process has seen it standing (waits are standing)
        self.busy_polls = {}  # agent -> polls in a row it was seen working (one alone does not end standing)
        self.since = {}  # agent -> since its last nudge: {tell_delivered, requests}

    def observe(self, row, now):
        """This poll's view of an agent: its own standing count, and what happened since its last nudge."""
        name = row["name"]
        if not row.get("alive", True):
            self.idle_since.pop(name, None)
            self.busy_polls.pop(name, None)
        elif working(row) or (row.get("orders") or {}).get("running"):
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
        if self.queue_work(row["name"], now):
            return "queued work in its journal"
        if now - self.start < self.grace_s:
            return "first minutes of the shift"
        rest = self.run_dir and pacing.resting(os.path.join(self.run_dir, row["name"]), now)
        if rest:  # the agy loop sleeps between turns (tools/agy-quota.py): nobody reads a tell until it wakes
            return pacing.label(rest)
        if self.deadline and now >= self.deadline:
            return "after the deadline"
        if now - self.last.get(row["name"], -1e18) < self.every_s:
            return f"nudged in the last {self.every_s / 60:g} min"
        return None

    def step(self, report, now, send, write):
        """One poll: nudge every agent that is due; write a log row for each nudge sent (or that failed to send)."""
        out = []
        for row in report.get("agents") or []:
            self.observe(row, now)
            if self.due(row, now) is not None:
                continue
            standing = self.standing(row, now)
            text = nudge_text(row, standing)
            entry = {"t": datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"),
                     "agent": row["name"], "standing_min": minutes(standing), "action": row.get("action"),
                     "queue": queue_text(row.get("queue")), "sleeping_min": minutes(row.get("sleeping_s")) or None,
                     "unread": {k: row.get(k) or 0 for k in ("unread_chat", "unread_mentions", "unread_tells",
                                                             "unread_board")},
                     "last_request_min": minutes(row.get("last_request_s")) if row.get("last_request_s") is not None
                     else None, "counted": (row.get("counted") or {}).get("text"), "text": text}
            if row["name"] in self.last:  # did a reply carry the last nudge, and has the agent asked anything since?
                entry["since_last_nudge"] = dict(self.since.get(row["name"]) or {"tell_delivered": False,
                                                                                  "requests": False})
            try:
                res = send(row["name"], text)
                entry.update(sent=True, tell_seq=(res or {}).get("seq"))
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
    ap.add_argument("--dry-run", action="store_true", help="log what would be sent; send nothing")
    ap.add_argument("--once", action="store_true", help="one poll (with --grace-min 0 to check the rules now)")
    ap.add_argument("--digest-now", action="store_true", help="send the full cached factory census to the team now, then exit (no idle nudges)")
    a = ap.parse_args()
    h = Harness(a.world, a.port)
    n = Nudger(team_members(a.run), a.idle_min, a.every_min, a.grace_min, deadline=run_deadline(a.run), run_dir=a.run)
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
