#!/usr/bin/env python3
"""What the program showed, from a director log and the agents' journals (d26 batch222 CD, viewer Aurora 20:09: "Grok's
repeat walking often fills the stream"; 03:42 site:4876-4879: idle-screen time, missed events, reaction delay and
excessive cuts):

  python3 tools/stream/airtime.py --log tools/stream/logs/director-20261025-194343.jsonl --runs runs/shift76 runs/shift77

Three numbers for the span of the log:
- idle/loop share: the share of the time the program followed an agent's character while that character idled (its
  journal's clock: "character idle Ns of it" at least IDLE_FRAC of the time since its last request) or ran a walk loop
  (a queue_repeat whose steps are all walks, from its accepted reply until a queue_cancel, queue_clear or another
  queue_repeat, a queue_status with nothing active or pending, or a run of idle clocks LOOP_IDLE_S long);
- time to a fresh event: an agent's accepted request of a visible kind (FRESH) it had not made in the FRESH_GAP before
  (batch240: of the kinds that change the map, work.did_kind's: no dry run, no launch that only sets the silo);
  from that request to the program showing the agent (following it, or a shot naming it), 0 when it is on air then,
  missed after MISS_S;
- cuts a minute: the program's cuts between clients and one client's moves (onecam.py `cut to` and `move` rows).

The on-air row: the program's client (onecam.py's `cut to SLOT` rows; the first slot until the first) and that client's
latest shot (its own rows: cmd.follow, the agents its target names). A trio counts its big tile. The journals' times are
UTC ISO (`at`), the log's epoch seconds. director_replay.py writes logs this reads the same way.
"""
import argparse, gzip, json, os, re, statistics, sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from work import DID, did_kind  # noqa: E402  (batch240: what changed the map, as the director's DidFeed says)

IDLE_FRAC = 0.9      # a clock this idle (character idle / time since the last request) is an idle stretch
LOOP_IDLE_S = 60.0   # idle clocks this long after a walk loop's start: the loop has stopped
FRESH_GAP = 600.0    # a visible request of a kind the agent made this recently is no fresh event
MISS_S = 600.0       # an event not on air this long after it is missed
WALKS = {"move_to", "walk", "path"}
FRESH = {"build", "place", "construct", "build_blueprint", "blueprint", "blueprint_place", "paste", "place_ghosts",
         "deconstruct", "mine", "launch", "load_silo", "shoot", "combat", "kite", "repair", "build_path", "vehicle"}
QUEUE_END = {"queue_cancel", "queue_clear", "queue_repeat"}
DUR = r"(?:\d+h)?(?:\d+m)?\d+s"
CLOCK_RE = re.compile(r"\+(" + DUR + r") since your last request, character idle (" + DUR + r") of it")


def seconds(text):
    """'1h2m3s' -> 3723."""
    total = 0
    for n, unit in re.findall(r"(\d+)([hms])", text or ""):
        total += int(n) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total


def iso_t(s):
    """'2026-10-26T02:02:47.944Z' -> epoch seconds."""
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def rows_of(path):
    opener = gzip.open if path.endswith(".gz") else open
    try:
        with opener(path, "rt", errors="replace") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    yield r
    except OSError:
        return


def journal_paths(runs):
    """{agent: [journal paths]} under each run folder: journal.jsonl.gz (the shift's, kept at its end) and journal.jsonl."""
    out = {}
    for run in runs:
        try:
            names = sorted(os.listdir(run))
        except OSError:
            continue
        for agent in names:
            for name in ("journal.jsonl.gz", "journal.jsonl"):
                p = os.path.join(run, agent, name)
                if os.path.isfile(p):
                    out.setdefault(agent, []).append(p)
    return out


def walk_loop(args):
    steps = args.get("steps") if isinstance(args, dict) else None
    return bool(steps) and all(isinstance(s, dict) and s.get("action") in WALKS for s in steps)


class Journal:
    """One agent's states from its journal rows: idle stretches, walk loops, fresh events, requests (replays)."""

    def __init__(self, agent):
        self.agent = agent
        self.idle = []     # (t0, t1): the character idled (its clock)
        self.loops = []    # [t0, t1, {name, steps, interval_ticks}]: a walk loop ran
        self.events = []   # (t, kind): fresh visible requests
        self.requests = []  # (t, action, args, result or None, ok): every request with its reply
        self.status = []   # (t, position, surface): status replies (where the body stood)
        self.last_t = None  # the journal's last row
        self.vehicle_rows = []  # (t, row): vehicle requests and their replies (director_replay.py's work.VehicleFeed)

    def read(self, rows):
        pending, last_kind, open_loop = {}, {}, None
        for r in rows:
            ev, t = r.get("event"), iso_t(r.get("at"))
            if t is None:
                continue
            self.last_t = t
            if ev == "request":
                q = r.get("request") or {}
                args = q.get("args") if isinstance(q.get("args"), dict) else {}
                pending[q.get("id")] = (t, q.get("action"), args)
                if q.get("action") == "vehicle":
                    self.vehicle_rows.append((t, r))
                if q.get("action") in QUEUE_END and open_loop is not None:
                    open_loop[1], open_loop = t, None
                continue
            if ev != "response":
                continue
            resp = r.get("response") or {}
            req = pending.pop(resp.get("id"), None)
            if not req:
                continue
            t0, action, args = req
            if action == "vehicle":
                self.vehicle_rows.append((t, r))
            res = resp.get("result") if isinstance(resp.get("result"), dict) else None
            ok = bool(resp.get("ok"))
            self.requests.append((t0, action, args, res, ok))
            clock = CLOCK_RE.search((res or {}).get("clock") or "")
            if clock:
                span, idle = seconds(clock.group(1)), seconds(clock.group(2))
                if span > 0 and idle >= IDLE_FRAC * span:
                    self.idle.append((t - span, t))
                    if open_loop is not None and t - span >= open_loop[0] and span >= LOOP_IDLE_S:
                        open_loop[1], open_loop = t - span, None
            if action == "status" and res and isinstance(res.get("position"), dict):
                self.status.append((t, res["position"], res.get("surface")))
            if action == "queue_repeat" and ok and walk_loop(args):
                open_loop = [t, None, {"name": args.get("name"), "steps": args["steps"],
                                       "interval_ticks": args.get("interval_ticks") or 0}]
                self.loops.append(open_loop)
            elif action == "queue_status" and ok and res and open_loop is not None and \
                    not res.get("active") and not res.get("pending") and not res.get("repeating"):
                open_loop[1], open_loop = t, None
            if ok and action in FRESH and (action != "vehicle" or args.get("go_to") or args.get("drive")) and \
                    (action not in DID or did_kind(action, args, res)):  # (batch240) no dry run, no settings call
                if t0 - last_kind.get(action, -1e18) >= FRESH_GAP:
                    self.events.append((t0, action))
                last_kind[action] = t0
        self.idle = merge(self.idle)
        return self

    def close(self, end=None):
        """A loop still open at the journal's end ran until then (or `end`, when that is sooner)."""
        for lp in self.loops:
            if lp[1] is None:
                lp[1] = min(x for x in (end, self.last_t) if x is not None)


def merge(spans):
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1] + 1.0:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def in_spans(spans, t):
    for a, b in spans:
        if a <= t < b:
            return True
        if a > t:
            return False
    return False


def journals(runs, end=None):
    out = {}
    for agent, paths in journal_paths(runs).items():
        j = Journal(agent)
        rows = []
        for p in paths:
            rows.extend(rows_of(p))
        rows.sort(key=lambda r: str(r.get("at") or ""))
        j.read(rows)
        j.close(end)
        out[agent] = j
    return out


# ---- the director log ---------------------------------------------------------------------------------------------
def program(rows):
    """[(t, shot)]: what the program shows from t on; shot {"follow": agent or None, "agents": [...], "reason"}; and the
    cuts [(t, reason)]."""
    state, onair, out, cuts = {}, None, [], []
    first = None
    for r in rows:
        slot, reason, t = r.get("slot"), str(r.get("reason") or ""), r.get("t")
        if t is None or not slot:
            continue
        if slot == "program":
            m = re.match(r"(cut to|move) (\S+?): (.*)", reason)
            if m:
                onair = m.group(2)
                cuts.append((t, m.group(3)))
        else:
            if first is None:
                first = slot
            cmd = r.get("cmd") or {}
            if cmd.get("release"):
                state[slot] = None
            elif reason in ("reframe",) or reason.startswith("zoom") and slot in state:
                pass  # the same shot, moved or zoomed
            else:
                tgt = r.get("target") or {}
                state[slot] = {"follow": cmd.get("follow"), "agents": list(tgt.get("agents") or []), "reason": reason}
        cur = onair or first
        out.append((t, dict(state.get(cur) or {"follow": None, "agents": [], "reason": None}, client=cur)))
    return out, cuts


def shot_at(timeline, t):
    """The program's shot at t (timeline from program(), in time order)."""
    lo, hi = 0, len(timeline)
    while lo < hi:
        mid = (lo + hi) // 2
        if timeline[mid][0] <= t:
            lo = mid + 1
        else:
            hi = mid
    return timeline[lo - 1][1] if lo else None


ARTY_RE = re.compile(r"Artillery · (\S+?)'s ")


def owner(shot):
    """(batch224) Whose the shot is: the agent it follows or names first; an artillery shot's agent (its label: "💥
    Artillery · Opus's flare → ..."); else what it shows ("@map", "@tour", ...: the reason's first word) or None."""
    if not shot:
        return None
    if shot.get("follow"):
        return shot["follow"]
    if shot.get("agents"):
        return shot["agents"][0]
    reason = str(shot.get("reason") or "")
    m = ARTY_RE.search(reason)
    if m:
        return m.group(1).lower()
    return ("@" + reason.split(":")[0].replace("standby", "").strip(" @")) if reason else None


def on_air_by(log_rows, t0=None, t1=None, step=1.0):
    """(batch224) {owner: seconds on air} over [t0, t1] (owner(): an agent, or what the shot shows)."""
    log_rows = [r for r in log_rows if isinstance(r.get("t"), (int, float))]
    if not log_rows:
        return {}
    t0 = log_rows[0]["t"] if t0 is None else t0
    t1 = log_rows[-1]["t"] if t1 is None else t1
    timeline, _ = program(log_rows)
    out, t = {}, t0
    while t < t1:
        who = owner(shot_at(timeline, t)) or "-"
        out[who] = out.get(who, 0.0) + step
        t += step
    return out


def measure(log_rows, js, t0=None, t1=None, step=1.0):
    """The three numbers (module doc) over [t0, t1] (default: the log's span)."""
    log_rows = [r for r in log_rows if isinstance(r.get("t"), (int, float))]
    if not log_rows:
        return None
    t0 = log_rows[0]["t"] if t0 is None else t0
    t1 = log_rows[-1]["t"] if t1 is None else t1
    timeline, cuts = program(log_rows)
    total = idle = loop = followed = 0.0
    by_agent = {}
    t = t0
    while t < t1:
        s = shot_at(timeline, t)
        total += step
        who = (s or {}).get("follow")
        if who:
            followed += step
            j = js.get(who)
            if j and any(a <= t < b for a, b, _ in j.loops):
                loop += step
                by_agent[who] = by_agent.get(who, 0.0) + step
            elif j and in_spans(j.idle, t):
                idle += step
                by_agent[who] = by_agent.get(who, 0.0) + step
        t += step
    delays, missed, events = [], 0, 0
    for agent, j in js.items():
        for et, kind in j.events:
            if not (t0 <= et < t1 - MISS_S):
                continue
            events += 1
            d, t = None, et
            while t <= et + MISS_S:
                s = shot_at(timeline, t) or {}
                if s.get("follow") == agent or agent in (s.get("agents") or []):
                    d = t - et
                    break
                t += step
            if d is None:
                missed += 1
            else:
                delays.append(d)
    minutes = (t1 - t0) / 60.0
    n_cuts = sum(1 for t, _ in cuts if t0 <= t < t1)
    return {"from": t0, "to": t1, "minutes": round(minutes, 1),
            "idle_loop_share": round((idle + loop) / total, 3) if total else None,
            "idle_share": round(idle / total, 3) if total else None, "loop_share": round(loop / total, 3) if total else None,
            "followed_share": round(followed / total, 3) if total else None,
            "idle_loop_by_agent_min": {k: round(v / 60, 1) for k, v in sorted(by_agent.items(), key=lambda kv: -kv[1])},
            "fresh_events": events, "fresh_missed": missed,
            "fresh_delay_median_s": round(statistics.median(delays), 1) if delays else None,
            "fresh_within_60s": round(sum(1 for d in delays if d <= 60) / events, 3) if events else None,
            "cuts": n_cuts, "cuts_per_min": round(n_cuts / minutes, 2) if minutes > 0 else None}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--log", nargs="+", required=True, help="director-*.jsonl (each measured on its own span)")
    ap.add_argument("--runs", nargs="+", required=True, help="run folders whose AGENT/journal.jsonl[.gz] cover the logs")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    out, js = [], journals(a.runs)
    for log in a.log:
        rows = list(rows_of(log))
        m = measure(rows, js)
        if m:
            m["log"] = os.path.basename(log)
            out.append(m)
    if a.json:
        print(json.dumps(out, indent=1))
    else:
        for m in out:
            print(f"{m['log']}: {m['minutes']} min; idle or walk loop on air {100 * m['idle_loop_share']:.1f}% "
                  f"(idle {100 * m['idle_share']:.1f}%, loop {100 * m['loop_share']:.1f}%; {m['idle_loop_by_agent_min']}); "
                  f"fresh events {m['fresh_events']}, median {m['fresh_delay_median_s']} s to air, "
                  f"{m['fresh_missed']} missed; cuts {m['cuts_per_min']}/min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
