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
  hauling.jsonl             the stream's reads of the harness's hand hauling counters (tools/stream/hauling.py): the
                            shift's items and calls moved by hand (direct, queue, standing order), carry distance and
                            top repeated haul, the last read less the first. A shift without it counts the journal's
                            direct hand moves whose reply says what moved (queue steps are not in the journals)

The result is cached as agent-stats.json (in runs/RUN/, or --cache-dir) with the sources' sizes and times: a finished
shift is counted once, a live one again when a journal grows. Text kept: only the lines spoken on stream and the
confessions (both public on the stream already), for the site's chat page, which redacts them as every page does.
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

sys.path.append(str(Path(__file__).resolve().parent / "stream"))
import hauling as haul_file  # noqa: E402  (tools/stream/hauling.py: the stream's hauling.jsonl rows)

VERSION = 6
# Requests that only read (no change in the game) and talk; every other action counts as a game action. The
# clock line's "+Ns since your last request" is no measure of busy time: an agent's tools send requests too.
READS = {"observe", "inspect", "sleep", "chat", "inventory", "inv", "tells", "board", "recipes", "placements",
         "wait_until", "wait_ticks", "describe", "technologies", "requests", "queue", "profiles", "research_done",
         "plans", "screenshot", "view", "clock", "callstatus", "status", "queue_status", "players", "scan"}
TALK = {"say", "tell", "confess", "board_plan", "board_update", "board_post", "board_claim", "operator",
        "harness_request", "plan_save", "profile", "vote"}
DEATH = re.compile(r"^\[director\] (\d\d:\d\d:\d\d) .*<- (?:attack|death): (.+?) died\b")
VOICE = re.compile(r"^(\d\d:\d\d:\d\d) \[voice:([^/\]]+)/([^\]]+)\] \((\w+)\) ?(.*)$")
TEXT_MAX = 600  # characters of a spoken line or confession kept for the site's chat page
MENTION = re.compile(r"^\s*@([\w.-]+)")
LEG_MAX = 400  # tiles: a longer hop between move targets is a respawn, a trip to another surface or a teleport
# Hand moves (the harness's hauling.lua counts the same): transfer either way, collect, feed, refuel, rearm, pickup
HAUL_TO_PLAYER = {"collect", "pickup"}
HAUL_TO_ENTITY = {"feed", "refuel", "rearm"}
HAUL = HAUL_TO_PLAYER | HAUL_TO_ENTITY | {"transfer"}
HAUL_CELL = 10  # tiles: puts of one item from one cell to another are one repeated haul


class Hauls:
    """Hand moves in one journal, direct requests only (a queue's steps are not in it), as hauling.lua counts them:
    items, the calls that moved some, the carry distance (per item, the straight line from the spot it was last taken
    or put to the spot it is put; a put of several items adds its longest leg) and the puts by item and cells."""

    def __init__(self):
        self.items = self.calls = 0
        self.carry = 0.0
        self.at, self.take, self.groups = {}, {}, {}

    def moved(self, direction, pos, surface, stacks):
        stacks = [(n, c) for n, c in stacks if isinstance(n, str) and isinstance(c, (int, float)) and c > 0]
        if not stacks:
            return 0
        if isinstance(pos, (list, tuple)) and len(pos) == 2:  # [x, y], as the harness also takes
            pos = {"x": pos[0], "y": pos[1]}
        ok = isinstance(pos, dict) and all(isinstance(pos.get(c), (int, float)) for c in ("x", "y"))
        here = (math.floor(pos["x"] + 0.5), math.floor(pos["y"] + 0.5), surface) if ok else None
        leg = 0.0
        for name, count in stacks:
            if here is None or direction not in ("to_player", "to_entity") or name == "?":
                continue
            prev = self.at.get(name)
            if direction == "to_entity" and prev and prev[2] == here[2]:
                d = math.dist(prev[:2], here[:2])
                if d <= LEG_MAX:
                    leg = max(leg, d)
            self.at[name] = here
            if direction == "to_player":
                self.take[name] = here
                continue
            src = self.take.get(name)
            src = src if src and src[2] == here[2] else None
            cell = lambda p: (p[0] // HAUL_CELL, p[1] // HAUL_CELL)  # noqa: E731
            key = (name, here[2], cell(src) if src else None, cell(here))
            g = self.groups.setdefault(key, {"item": name, "surface": here[2], "times": 0, "items": 0,
                                             "from": {"x": src[0], "y": src[1]} if src else None,
                                             "to": {"x": here[0], "y": here[1]}})
            g["times"] += 1
            g["items"] += count
        self.carry += leg
        n = sum(c for _, c in stacks)
        self.items += n
        return n

    def call(self, action, args, res, surface):
        """One direct hand move's reply: what it moved, where (each target's row when it lists them)."""
        direction = args.get("direction") or res.get("direction")
        if action in HAUL_TO_PLAYER:
            direction = "to_player"
        elif action in HAUL_TO_ENTITY:
            direction = "to_entity"
        elif direction in ("from_player", "give", "put", "insert", "to_chest", "to_container"):
            direction = "to_entity"
        elif direction in ("from_entity", "take", "from_chest", "from_container"):
            direction = "to_player"
        items = res.get("items")
        names = [i.get("name") for i in items if isinstance(i, dict)] if isinstance(items, list) else \
            list(items) if isinstance(items, dict) else []
        item = args.get("item") if isinstance(args.get("item"), str) else None
        moved = 0
        rows = res.get("entities") if isinstance(res.get("entities"), list) else []
        if rows:
            for row in rows:
                if not isinstance(row, dict):
                    continue
                if isinstance(row.get("gave"), dict):
                    stacks = list(row["gave"].items())
                elif item:
                    stacks = [(item, row.get("transferred") or 0)]
                elif isinstance(items, list) and len(rows) == 1:
                    stacks = [(i.get("name"), i.get("count")) for i in items if isinstance(i, dict)]
                else:  # several targets of several items: the reply has no split; counted, not placed
                    stacks = [(names[0] if names else "?", row.get("transferred") or 0)]
                    moved += self.moved(None, None, surface, stacks)
                    continue
                moved += self.moved(direction, row.get("position"), surface, stacks)
        elif isinstance(res.get("transferred"), (int, float)) and res["transferred"] > 0:
            pos = args.get("position") or args.get("target")
            if item:
                stacks = [(item, res["transferred"])]
            elif isinstance(items, list):
                stacks = [(i.get("name"), i.get("count")) for i in items if isinstance(i, dict)]
            elif isinstance(items, dict):
                stacks = list(items.items())
            else:
                stacks = [("?", res["transferred"])]
            moved += self.moved(direction, pos, surface, stacks)
        if moved:
            self.calls += 1

    def stats(self):
        top = max(self.groups.values(), key=lambda g: (g["times"], g["items"]), default=None)
        return {"haul_items": round(self.items), "haul_calls": self.calls, "haul_direct_items": round(self.items),
                "haul_direct_calls": self.calls, "haul_queue_items": None, "haul_queue_calls": None,
                "haul_order_items": None, "haul_order_calls": None, "haul_carry": round(self.carry),
                "haul_top": top if top and top["times"] > 1 else None, "haul_from": "journal"}


def game_hauls(run_dir, keys):
    """{key: haul stats} from the stream's hauling.jsonl (the harness's own counts: queue and standing order steps
    too), the shift's last read less its first; {} without the file or with one read."""
    rows = haul_file.read_rows(str(Path(run_dir) / haul_file.FILE))
    if len(rows) < 2:
        return {}
    out = {}
    for r in haul_file.shift_rows(rows[0], rows[-1], set(keys)):
        top = r.get("top")
        out[r["name"]] = {"haul_items": r["items"], "haul_calls": r["calls"], "haul_direct_items": r["direct_items"],
                          "haul_direct_calls": r["direct_calls"], "haul_queue_items": r["queue_items"],
                          "haul_queue_calls": r["queue_calls"], "haul_order_items": r["order_items"],
                          "haul_order_calls": r["order_calls"], "haul_carry": r["carry_tiles"],
                          "haul_top": {k: top.get(k) for k in ("item", "surface", "from", "to", "times", "items")}
                          if top and top.get("times", 0) > 1 else None, "haul_from": "game"}
    for k in keys:
        out.setdefault(k, {"haul_items": 0, "haul_calls": 0, "haul_direct_items": 0, "haul_direct_calls": 0,
                           "haul_queue_items": 0, "haul_queue_calls": 0, "haul_order_items": 0, "haul_order_calls": 0,
                           "haul_carry": 0, "haul_top": None, "haul_from": "game"})
    return out


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
            "minutes": 0, "first": None, "last": None, "confession_lines": [], "spoken_lines": []} | Hauls().stats()


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
    hauls, surface = Hauls(), None
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
            pl = res.get("player")
            if isinstance(pl, dict) and isinstance(pl.get("surface"), str):
                surface = pl["surface"]  # where the character is, for hand moves' carry legs
            if a in HAUL:
                hauls.call(a, args, res, surface)
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
                s["confession_lines"].append([resp.get("tick"), str(args.get("text") or "")[:TEXT_MAX]])
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
    s.update(hauls.stats())
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
        if k in last and 0 <= (t - last[k]).total_seconds() <= 10:  # the pair is 2 s apart; a respawn can die in 30
            continue
        last[k] = t
        tick = tick_at(clock, t)
        if tick is not None:
            out[k].append(tick)
    return out


def wall(day, hms, prev):
    """A log's HH:MM:SS on the shift's day, a day later once the times wrap past midnight: (datetime, day)."""
    h, mi, sec = map(int, hms.split(":"))
    t = datetime.datetime.combine(day, datetime.time(h, mi, sec))
    if prev and t < prev - datetime.timedelta(hours=12):
        day += datetime.timedelta(days=1)
        t += datetime.timedelta(days=1)
    return t, day


def voices(run_dir, keys, clock=()):
    """({key: [[game tick, why, text] of each line spoken on stream]}, {key: voice id}) from caster.log."""
    n, v = {}, {}
    p = run_dir / "caster.log"
    if p.exists():
        day, prev = (clock[0][0].date() if clock else datetime.date.today()), None
        for line in p.read_text(errors="replace").splitlines():
            m = VOICE.match(line)
            if not m:
                continue
            t, day = wall(day, m.group(1), prev)
            prev = t
            k = key_of(m.group(2), keys)
            if k:
                n.setdefault(k, []).append([tick_at(clock, t) if clock else None, m.group(4), m.group(5)[:TEXT_MAX]])
                v[k] = m.group(3)
    return n, v


def operator_requests(run_dir, keys):
    """{key: [seq of each request]} from the inbox, each seq once (the game's id for the request). Until the stream
    service's fix a shift's inbox also held the earlier shifts' requests again: site/agents.py counts a seq in the
    first shift that has it. Viewer lines to the operator ("viewer NAME") are no agent's."""
    n = {}
    p = run_dir / "operator-inbox.jsonl"
    if p.exists():
        for line in p.read_text(errors="replace").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            k = key_of(str(r.get("agent") or ""), keys) if not r.get("viewer") else None
            if k and isinstance(r.get("seq"), int) and r["seq"] not in n.get(k, []):
                n.setdefault(k, []).append(r["seq"])
    return n


def sources(run_dir, keys):
    files = [journal_path(run_dir / k) for k in keys] + [run_dir / f for f in (
        "stream-service.log", "caster.log", "operator-inbox.jsonl", "scores.jsonl", "team.txt", haul_file.FILE)]
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
    spoken, voice = voices(run_dir, keys, clock)
    ops = operator_requests(run_dir, keys)
    agents, queued = {}, {}
    for k in keys:
        j = journal_path(run_dir / k)
        s, q = read_journal(j, names) if j else (blank(), {})
        for tech, who in q.items():
            queued.setdefault(tech, who)  # the queue's own queued_by wins over a request seen elsewhere
        agents[k] = s
    # the harness's own hand hauling counts, where the stream kept them, over the journals' direct moves
    for k, h in game_hauls(run_dir, keys).items():
        if k in agents:
            agents[k].update(h)
    done = research_done(run_dir)
    for tech, who in queued.items():
        k = key_of(str(who), keys)
        if k:
            agents[k]["research"] += 1
            agents[k]["research_done"] += tech in done
    for k, s in agents.items():
        s["deaths"] = len(died.get(k, []))
        s["death_ticks"] = died.get(k, [])
        s["spoken_lines"] = spoken.get(k, [])
        s["voiced"] = len(s["spoken_lines"])
        s["voice"] = voice.get(k)
        s["operator_seqs"] = ops.get(k, [])
        s["operator"] = len(s["operator_seqs"])  # this file's; across shifts see site/agents.py
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
                "active_min", "minutes", "haul_items", "haul_calls", "haul_carry"]
        print("agent".ljust(8) + "".join(c_[:7].rjust(8) for c_ in cols))
        for k, s in c["agents"].items():
            print(k.ljust(8) + "".join(str(s[c_]).rjust(8) for c_ in cols))
    else:
        print(json.dumps({k: v for k, v in c.items() if k != "sources"}, indent=1))


if __name__ == "__main__":
    sys.exit(main())
