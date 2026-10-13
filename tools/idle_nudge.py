#!/usr/bin/env python3
"""A fact-only nudge for idle characters (operator; tools/start-team.sh runs it beside the supervisors).

  python3 tools/idle_nudge.py --run runs/RUN --world n [--port 27025] [--dry-run] [--once]

shift05: Sonnet's character stood still most of the shift (a short plan, then long sleeps) and it discarded its fh
replies, so it missed the team's messages. Every --poll seconds this reads the harness's operator `idle_report`
(idle.lua, read only) and sends one operator tell (tells.lua: the next reply's team tells, and a wake from sleep;
never the game chat) to an agent whose character has stood --idle-min minutes or more: no action, no running queue
step, a body on the map (dead or in a cargo pod is not standing). A timed action the agent chose (wait_ticks,
wait_until) is an action, so it is never nudged; an fh sleep with nothing running is standing. A standing order
running for the agent (orders.lua: the report's `orders.running`) is work, so never nudged. The tell holds facts
only: how long, the queue and sleep state, the standing orders set, what waits unread. At most once per --every-min minutes per agent, never in
the first --grace-min minutes after this process starts (the shift start), and not after the run's deadline. Each
nudge is a line in runs/RUN/nudges.jsonl (sent or not, and why not).
"""
import argparse, datetime, json, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.dont_write_bytecode = True


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
    """The report's standing orders (orders.lua report: {set, running, paused}), or '' with none set."""
    if not o or not o.get("set"):
        return ""
    n = o["set"]
    return f" Standing orders: {n} set, " + ("paused" if o.get("paused") else "none running") + "."


def nudge_text(row):
    """The tell: facts only, no advice."""
    sleep = f", sleeping {minutes(row['sleeping_s'])} min" if row.get("sleeping_s") else ""
    def count(n, what):
        return f"{n} {what}" + ("" if n == 1 else "s")
    mentions = max(0, (row.get("unread_mentions") or 0) - (row.get("unread_tells") or 0))
    unread = [count(row.get("unread_chat") or 0, "chat message"), count(mentions, "mention"),
              count(row.get("unread_tells") or 0, "tell")]
    if row.get("unread_board"):
        unread.append(count(row["unread_board"], "board line"))
    return (f"Operator (automatic, facts only): your character has stood idle for {minutes(row['standing_s'])} min "
            f"(no action, no queue step{sleep}). Queue: {queue_text(row.get('queue'))}.{orders_text(row.get('orders'))} "
            "Unread for you: " + ", ".join(unread) + ".")


class Nudger:
    """The rules, apart from RCON (tests drive it with a fake report and a fake send)."""

    def __init__(self, members=None, idle_min=10, every_min=20, grace_min=5, start=None, deadline=None):
        self.members = set(members or [])
        self.idle_s, self.every_s, self.grace_s = idle_min * 60, every_min * 60, grace_min * 60
        self.start = start if start is not None else time.time()
        self.deadline = deadline
        self.last = {}  # agent -> time of its last nudge

    def due(self, row, now):
        """None when this agent gets a nudge now, else why not (only for agents standing long enough)."""
        if self.members and row["name"] not in self.members:
            return "not on the team"
        if (row.get("standing_s") or 0) < self.idle_s or not row.get("alive", True):
            return "active"
        if row.get("action"):
            return "in an action"
        if (row.get("orders") or {}).get("running"):
            return "running a standing order"
        if now - self.start < self.grace_s:
            return "first minutes of the shift"
        if self.deadline and now >= self.deadline:
            return "after the deadline"
        if now - self.last.get(row["name"], -1e18) < self.every_s:
            return f"nudged in the last {self.every_s / 60:g} min"
        return None

    def step(self, report, now, send, write):
        """One poll: nudge every agent that is due; write a log row for each nudge sent (or that failed to send)."""
        out = []
        for row in report.get("agents") or []:
            if self.due(row, now) is not None:
                continue
            text = nudge_text(row)
            entry = {"t": datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"),
                     "agent": row["name"], "standing_min": minutes(row.get("standing_s")),
                     "queue": queue_text(row.get("queue")), "sleeping_min": minutes(row.get("sleeping_s")) or None,
                     "unread": {k: row.get(k) or 0 for k in ("unread_chat", "unread_mentions", "unread_tells",
                                                             "unread_board")},
                     "last_request_min": minutes(row.get("last_request_s")) if row.get("last_request_s") is not None
                     else None, "text": text}
            try:
                res = send(row["name"], text)
                entry.update(sent=True, tell_seq=(res or {}).get("seq"))
                self.last[row["name"]] = now
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

    def dispatch(self, action, args):
        from harness import lua_string
        req = {"id": f"idle-nudge-{int(time.time() * 1000)}", "operator": True, "action": action, "args": args}
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
    a = ap.parse_args()
    h = Harness(a.world, a.port)
    n = Nudger(team_members(a.run), a.idle_min, a.every_min, a.grace_min, deadline=run_deadline(a.run))
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
        log(f"nudge {entry['agent']}: {'sent' if entry.get('sent') else entry.get('error')} ({entry['standing_min']} min)")

    log(f"idle nudges for {a.run}: {len(n.members) or 'all'} agents, idle {a.idle_min} min, every {a.every_min} min, "
        f"grace {a.grace_min} min, deadline {time.strftime('%H:%M', time.localtime(n.deadline)) if n.deadline else '?'}"
        + (" (dry run)" if a.dry_run else ""))
    while True:
        now = time.time()
        if n.deadline and now >= n.deadline:
            log("deadline reached")
            return
        try:
            n.step(h.dispatch("idle_report", {}), now, send, write)
        except Exception as e:
            log(f"poll failed: {type(e).__name__}: {e}")  # an old runtime without idle_report says so here
        if a.once:
            return
        time.sleep(a.poll)


if __name__ == "__main__":
    main()
