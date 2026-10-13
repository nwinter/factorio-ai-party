#!/usr/bin/env python3
"""Per-agent numbers for one shift of the long run, from its logs; the site's /agents/ page adds the shifts up.

    python3 tools/agent_stats.py shift04 [--runs-dir runs] [--cache-dir DIR] [--print]

Sources, all read-only, in runs/RUN/:
  AGENT/journal.jsonl(.gz)  every request the agent (and its tools) sent and the reply: requests by kind (game
                            actions, talk, reads), failures, what was built and mined, move targets, rockets launched,
                            chat (say), tells, confessions, the minutes with a game action, and the research queue's
                            queued_by (whose research the team ran)
  stream-service.log        the director's "<- death: NAME died" lines (one death shows on two lines)
  caster.log                "[voice:NAME/VOICE] (why) text": lines spoken on stream, and each agent's voice
  operator-inbox.jsonl      requests filed to the operator
  scores.jsonl              wall clock to game tick, for death times

The result is cached as agent-stats.json (in runs/RUN/, or --cache-dir) with the sources' sizes and times: a finished
shift is counted once, a live one again when a journal grows. Numbers only; no text from the logs is kept.
"""
import argparse
import datetime
import gzip
import json
import math
import os
import re
import sys
from pathlib import Path

VERSION = 2
# Requests that only read (no change in the game) and talk; every other action counts as a game action. The
# clock line's "+Ns since your last request" is no measure of busy time: an agent's tools send requests too.
READS = {"observe", "inspect", "sleep", "chat", "inventory", "inv", "tells", "board", "recipes", "placements",
         "wait_until", "wait_ticks", "describe", "technologies", "requests", "queue", "profiles", "research_done",
         "plans", "screenshot", "view", "clock", "callstatus", "status", "queue_status", "players", "scan"}
TALK = {"say", "tell", "confess", "board_plan", "board_update", "board_post", "board_claim", "operator",
        "harness_request", "plan_save", "profile", "vote"}
DEATH = re.compile(r"^\[director\] (\d\d:\d\d:\d\d) .*<- (?:attack|death): (.+?) died\b")
VOICE = re.compile(r"^\d\d:\d\d:\d\d \[voice:([^/\]]+)/([^\]]+)\] \((\w+)\)")
MENTION = re.compile(r"^\s*@([\w.-]+)")
LEG_MAX = 400  # tiles: a longer hop between move targets is a respawn, a trip to another surface or a teleport


def journal_path(d):
    for name in ("journal.jsonl", "journal.jsonl.gz"):
        if (d / name).exists():
            return d / name
    return None


def team(run_dir):
    """The shift's agents: team.txt (key|model line), else the folders with a journal."""
    t = run_dir / "team.txt"
    if t.exists():
        keys = [line.split("|", 1)[0].strip() for line in t.read_text().splitlines() if line.strip()]
        return [k for k in keys if k]
    return sorted(p.parent.name for p in run_dir.glob("*/journal.jsonl*"))


def blank():
    return {"requests": 0, "actions": 0, "talk": 0, "reads": 0, "failed": 0, "built": 0, "mined": 0, "walked": 0.0,
            "moves": 0, "research": 0, "research_done": 0, "rockets": 0, "say": 0, "aloud_marked": 0, "tells": 0,
            "confessions": 0, "viewer_answers": 0, "deaths": 0, "voiced": 0, "operator": 0, "active_min": 0,
            "minutes": 0, "first": None, "last": None}


def built_count(action, res):
    """Buildings a successful reply placed: build's `built` (or one `entity`), a route's placed entities."""
    if not isinstance(res, dict) or res.get("dry_run"):
        return 0
    if isinstance(res.get("built"), int):
        return res["built"]
    if action == "build" and isinstance(res.get("entity"), dict):
        return 1
    if action in ("belt_route", "pipe_route", "pole_route", "rail_route"):
        p = res.get("placed")
        return p if isinstance(p, int) else len(p) if isinstance(p, list) else 0
    return 0


def read_journal(path, names):
    """One pass over a journal: (stats, {technology: who queued it}). names: the team's keys and display names (an
    @mention of one is not a viewer)."""
    s = blank()
    acts, jobs, last_pos, minutes, queued = {}, set(), None, set(), {}
    op = gzip.open if path.suffix == ".gz" else open
    with op(path, "rt", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            ev = r.get("event")
            at = r.get("at")
            if ev == "request":
                q = r.get("request") or {}
                a, args = q.get("action"), q.get("args") or {}
                acts[q.get("id")] = (a, args)
                s["requests"] += 1
                if a in READS or (a == "research" and not args):
                    s["reads"] += 1
                elif a in TALK:
                    s["talk"] += 1
                else:
                    s["actions"] += 1
                    if at:
                        minutes.add(at[:16])
                if at:
                    s["first"] = s["first"] or at
                    s["last"] = at
                continue
            if ev != "response":
                continue
            resp = r.get("response") or {}
            a, args = acts.pop(resp.get("id"), (None, {}))
            res = resp.get("result")
            if not resp.get("ok"):
                s["failed"] += 1
                continue
            if not isinstance(res, dict):
                continue
            for e in res.get("entries") or []:  # the research queue, with who queued each technology
                if isinstance(e, dict) and e.get("name") and e.get("queued_by"):
                    queued[e["name"]] = e["queued_by"]
            if a == "research" and isinstance(args.get("technology"), str):
                queued.setdefault(args["technology"], path.parent.name)
            s["built"] += built_count(a, res)
            if a == "mine":
                s["mined"] += 1
            elif a == "move_to":
                p = res.get("position") or args.get("position")
                if isinstance(p, dict) and "x" in p:
                    if last_pos:
                        d = math.dist((p["x"], p["y"]), last_pos)
                        if d <= LEG_MAX:
                            s["walked"] += d
                    last_pos = (p["x"], p["y"])
                    s["moves"] += 1
            elif a == "launch" and res.get("launched"):
                s["rockets"] += 1
            elif a == "say":
                s["say"] += 1
                s["aloud_marked"] += bool(args.get("aloud"))
                mm = MENTION.match(str(args.get("text") or ""))
                if mm and mm.group(1).lower() not in names:
                    s["viewer_answers"] += 1
            elif a == "tell":
                s["tells"] += 1
            elif a == "confess":
                s["confessions"] += 1
            # jobs a queue ran: their results come back in queue replies' history (each job once)
            for h in res.get("history") or []:
                if not isinstance(h, dict) or h.get("id") in jobs or not h.get("ok"):
                    continue
                jobs.add(h.get("id"))
                hr = h.get("result") or {}
                comp = hr.get("completion") or {}
                ha = h.get("action")
                if ha == "build":
                    s["built"] += built_count("build", hr) or (comp.get("built") or 0)
                elif ha == "mine":
                    s["mined"] += 1
                elif ha == "move_to" and isinstance(comp.get("target"), dict):
                    p = comp["target"]
                    if last_pos and math.dist((p["x"], p["y"]), last_pos) <= LEG_MAX:
                        s["walked"] += math.dist((p["x"], p["y"]), last_pos)
                    last_pos = (p["x"], p["y"])
                    s["moves"] += 1
                elif ha == "launch" and hr.get("launched"):
                    s["rockets"] += 1
    s["walked"] = round(s["walked"])
    s["active_min"] = len(minutes)
    if s["first"] and s["last"]:
        span = datetime.datetime.fromisoformat(s["last"].replace("Z", "+00:00")) - \
            datetime.datetime.fromisoformat(s["first"].replace("Z", "+00:00"))
        s["minutes"] = round(span.total_seconds() / 60)
    return s, queued


def key_of(name, keys):
    """A display name from the logs ("Muse Spark", "haiku", "Opus") to the agent's key."""
    n = name.strip().lower()
    if n in keys:
        return n
    first = n.split()[0] if n.split() else n
    return first if first in keys else None


def score_clock(run_dir):
    """[(datetime, tick)] from scores.jsonl, for death times in game ticks."""
    out = []
    p = run_dir / "scores.jsonl"
    if p.exists():
        for line in p.read_text().splitlines():
            try:
                r = json.loads(line)
                out.append((datetime.datetime.fromisoformat(r["t"]), r["score"]["tick"]))
            except (ValueError, KeyError, TypeError):
                continue
    return out


def research_done(run_dir):
    """Technologies the shift finished: its last score's research_done less its first's."""
    rows = []
    p = run_dir / "scores.jsonl"
    if p.exists():
        for line in p.read_text().splitlines():
            try:
                d = json.loads(line)["score"].get("research_done") or []
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            rows.append(set(d if isinstance(d, list) else json.loads(d) if isinstance(d, str) else d))
    return rows[-1] - rows[0] if rows else set()


def tick_at(clock, t):
    """The game tick at wall time t (60 ticks a second from the nearest score before it)."""
    before = [c for c in clock if c[0] <= t]
    if not before:
        return clock[0][1] if clock else None
    c = before[-1]
    return int(c[1] + (t - c[0]).total_seconds() * 60)


def deaths(run_dir, keys, clock):
    """{key: [game tick of each death]} from the director's lines; one death shows on two lines a few seconds apart."""
    out = {k: [] for k in keys}
    p = run_dir / "stream-service.log"
    if not p.exists() or not clock:
        return out
    day, prev, last = clock[0][0].date(), None, {}
    for line in p.read_text(errors="replace").splitlines():
        m = DEATH.match(line)
        if not m:
            continue
        h, mi, sec = map(int, m.group(1).split(":"))
        t = datetime.datetime.combine(day, datetime.time(h, mi, sec))
        if prev and t < prev - datetime.timedelta(hours=12):  # past midnight
            day += datetime.timedelta(days=1)
            t += datetime.timedelta(days=1)
        prev = t
        k = key_of(m.group(2), keys)
        if not k:
            continue
        if k in last and 0 <= (t - last[k]).total_seconds() <= 60:
            continue
        last[k] = t
        tick = tick_at(clock, t)
        if tick is not None:
            out[k].append(tick)
    return out


def voices(run_dir, keys):
    """({key: lines spoken on stream}, {key: voice id}) from caster.log."""
    n, v = {}, {}
    p = run_dir / "caster.log"
    if p.exists():
        for line in p.read_text(errors="replace").splitlines():
            m = VOICE.match(line)
            if m:
                k = key_of(m.group(1), keys)
                if k:
                    n[k] = n.get(k, 0) + 1
                    v[k] = m.group(2)
    return n, v


def operator_requests(run_dir, keys):
    n = {}
    p = run_dir / "operator-inbox.jsonl"
    if p.exists():
        for line in p.read_text(errors="replace").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            k = key_of(str(r.get("agent") or ""), keys) if not r.get("viewer") else None
            if k:
                n[k] = n.get(k, 0) + 1
    return n


def sources(run_dir, keys):
    files = [journal_path(run_dir / k) for k in keys] + [run_dir / f for f in (
        "stream-service.log", "caster.log", "operator-inbox.jsonl", "scores.jsonl", "team.txt")]
    out = {}
    for f in files:
        if f and f.exists():
            st = f.stat()
            out[str(f.relative_to(run_dir))] = [st.st_size, int(st.st_mtime)]
    return out


def compute(run_dir, display_names=()):
    run_dir = Path(run_dir)
    keys = team(run_dir)
    names = set(keys) | {n.lower() for n in display_names} | {"operator", "all", "team", "everyone"}
    clock = score_clock(run_dir)
    died = deaths(run_dir, keys, clock)
    spoken, voice = voices(run_dir, keys)
    ops = operator_requests(run_dir, keys)
    agents, queued = {}, {}
    for k in keys:
        j = journal_path(run_dir / k)
        s, q = read_journal(j, names) if j else (blank(), {})
        for tech, who in q.items():
            queued.setdefault(tech, who)  # the queue's own queued_by wins over a request seen elsewhere
        agents[k] = s
    done = research_done(run_dir)
    for tech, who in queued.items():
        k = key_of(str(who), keys)
        if k:
            agents[k]["research"] += 1
            agents[k]["research_done"] += tech in done
    for k, s in agents.items():
        s["deaths"] = len(died.get(k, []))
        s["death_ticks"] = died.get(k, [])
        s["voiced"] = spoken.get(k, 0)
        s["voice"] = voice.get(k)
        s["operator"] = ops.get(k, 0)
    return {"version": VERSION, "run": run_dir.name, "tick0": clock[0][1] if clock else None,
            "tick1": clock[-1][1] if clock else None, "agents": agents, "sources": sources(run_dir, keys)}


def load(run_dir, cache_dir=None, display_names=()):
    """The shift's stats, from the cache when its sources have not changed; recounted (and the cache rewritten, when
    it can be) otherwise."""
    run_dir = Path(run_dir)
    cache = Path(cache_dir) / f"{run_dir.name}.json" if cache_dir else run_dir / "agent-stats.json"
    try:
        c = json.loads(cache.read_text())
        if c.get("version") == VERSION and c.get("sources") == sources(run_dir, team(run_dir)):
            return c
    except (OSError, ValueError):
        pass
    c = compute(run_dir, display_names)
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(c, indent=1) + "\n")
        os.replace(tmp, cache)
    except OSError:
        pass  # a read-only runs folder: counted each build
    return c


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--runs-dir", default=str(Path(__file__).resolve().parent.parent / "runs"))
    ap.add_argument("--cache-dir", help="where agent-stats go (default: the shift's folder)")
    ap.add_argument("--print", action="store_true", help="print a table")
    a = ap.parse_args()
    c = load(Path(a.runs_dir) / a.run, a.cache_dir)
    if a.print:
        cols = ["requests", "actions", "talk", "failed", "built", "mined", "walked", "research", "research_done",
                "rockets", "say", "voiced", "tells", "confessions", "viewer_answers", "operator", "deaths",
                "active_min", "minutes"]
        print("agent".ljust(8) + "".join(c_[:7].rjust(8) for c_ in cols))
        for k, s in c["agents"].items():
            print(k.ljust(8) + "".join(str(s[c_]).rjust(8) for c_ in cols))
    else:
        print(json.dumps({k: v for k, v in c.items() if k != "sources"}, indent=1))


if __name__ == "__main__":
    sys.exit(main())
