#!/usr/bin/env python3
"""A viewer-experience review of one run, from its logs (d26 batch237 VX, viewer Aurora 10:44-10:45: "Could viewer
experience be a standing duty each shift? Review real footage and site use, find camera/narration/data weaknesses ...
Track missed action, idle airtime, narration lag/repeats and data clarity."):

  python3 tools/stream/vx_review.py runs/shift80 [--from 07:00 --to 09:00] [--logs tools/stream/logs] [--out DIR]

Read only: the run folder (journals, chronicle.jsonl, audio-played.jsonl, push-live.log, stream-service.log) and the
stream logs of the run's stream service (director-*.jsonl and caster-*.jsonl named in stream-service.log's "[stream]"
lines, hourly-*.jsonl named in hourly.log, tour-hourly-RUN-*.jsonl), and site/content/operator-updates.json. No game
or network read. It writes RUN/vx-review.md and RUN/vx-review.json (or into --out).

Five parts, each with numbers and examples with times (Pacific):
1. missed action: the journals' fresh visible requests (airtime.py FRESH: builds, vehicle outings, artillery,
   launches, ...), platforms made (the chronicle), the director's own threat sightings (battles, losses, attacks) and
   departures; each on air at once (within ONCE_S), late, or missed (not on air within airtime.MISS_S); (batch245) a
   threat is on air when the director took it or the program's camera stood within FRAME_TILES of its spot; one shown
   only in the inset is still missed (counted apart), a battle's repeat the director gave its inset is by design;
2. idle airtime: airtime.py's idle and walk-loop minutes by agent, minutes with no shot, and repeated shots (one
   aired again within REPEAT_S after something else);
3. narration: the caster's cue-to-line time, the lag from a chronicle event to the line that names it, an agent's
   chat to its voiced line, the audio queue's wait to play and clips cut short or skipped, repeated lines, the hourly
   pieces; and lines that call a platform new when the run made no such platform; (batch255) the event-to-line lag counts
   the lines whose own cue names the platform (an arrival, a departure, the card on screen), later mentions apart;
4. data clarity: the site push (failures, gaps, a tick that stopped moving), the chart's surfaces without cells, the
   base-map frames, the Updates page's open rows (due for review, no owner or priority);
5. cost: the stream service's slow game reads (its own load on the world), its errors, the caster's spend; this
   review's own run time.
Times in the logs are epoch seconds (journals: UTC ISO); the service log's HH:MM:SS are Pacific on the run's days.
"""
import argparse, datetime, json, math, os, re, statistics, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent / "site"))
import airtime  # noqa: E402  (journals, the program's timeline, idle and loop minutes)

try:
    from zoneinfo import ZoneInfo
    PACIFIC = ZoneInfo("America/Los_Angeles")
except Exception:  # no tz database: the machine's local time (the Mac runs on Pacific time)
    PACIFIC = None

ONCE_S = 30.0         # on air this soon after the event: at once
FRAME_TILES = 60.0    # (batch245) a threat's spot this close to the program's camera: on air (onecam fight_near 40 + a
                      # chunk's half: live.py reports an attacked chunk by its centre)
AREA_RE = re.compile(r"area:(-?[\d.]+),(-?[\d.]+)")
REPEAT_S = 900.0      # the same shot again this soon, after something else: a repeat
STEP = 1.0            # the program sampled every STEP seconds
EXAMPLES = 5
KINDS = {"vehicle": "vehicle outing", "artillery": "artillery", "launch": "launch", "load_silo": "launch",
         "shoot": "combat", "combat": "combat", "kite": "combat", "repair": "repair", "mine": "mining",
         "deconstruct": "deconstruction", "vehicle_go": "vehicle outing"}
BUILD = {"build", "place", "construct", "build_blueprint", "blueprint", "blueprint_place", "paste", "place_ghosts", "build_path"}


# ---- reading ------------------------------------------------------------------------------------------------------
def rows(path):
    return list(airtime.rows_of(str(path))) if path and os.path.isfile(path) else []


def local(t):
    return datetime.datetime.fromtimestamp(t, PACIFIC).strftime("%H:%M:%S") if t is not None else "?"


def day_of(t):
    return datetime.datetime.fromtimestamp(t, PACIFIC).date()


def epoch(day, hms):
    """Pacific day + 'HH:MM[:SS]' -> epoch seconds."""
    parts = [int(x) for x in hms.split(":")]
    d = datetime.datetime(day.year, day.month, day.day, parts[0], parts[1], parts[2] if len(parts) > 2 else 0, tzinfo=PACIFIC)
    return d.timestamp()


def timed(svc, day):
    """The service lines with epoch seconds: (t or None, tag, hms, text); a time far before the one before it is the
    next day (a run past midnight)."""
    out, prev = [], None
    for tag, hms, text in svc:
        t = None
        if hms:
            t = epoch(day, hms)
            if prev is not None and t < prev - 43200:
                day = day + datetime.timedelta(days=1)
                t = epoch(day, hms)
            prev = t
        out.append((t if t is not None else prev, tag, hms, text))
    return out


def service_lines(run):
    """The stream service's log lines of the run: (tag, HH:MM:SS or None, text)."""
    out = []
    p = Path(run) / "stream-service.log"
    if not p.is_file():
        return out
    for line in p.read_text(errors="replace").splitlines():
        m = re.match(r"\[([\w-]+)\] (?:(\d\d:\d\d:\d\d) )?(.*)", line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3)))
        else:
            out.append((None, None, line))
    return out


def stream_logs(run, logs, svc):
    """The director and caster logs of the run's stream service ('[stream] ... director log PATH'), the hourly logs
    hourly.log names, and the run's tour-hourly logs."""
    directors = []
    for tag, _, text in svc:
        m = tag == "stream" and re.search(r"director log (\S+)", text)
        if m:
            name = os.path.basename(m.group(1))
            if name not in directors:
                directors.append(name)
    hourly = []
    hp = Path(run) / "hourly.log"
    if hp.is_file():
        for m in re.finditer(r"log \S*?(hourly-\d{8}-\d{6}\.jsonl)", hp.read_text(errors="replace")):
            if m.group(1) not in hourly:
                hourly.append(m.group(1))
    name = Path(run).name
    tours = sorted(p.name for p in Path(logs).glob(f"tour-hourly-{name}-*.jsonl")) if Path(logs).is_dir() else []
    # the caster starts with the service, a few seconds after its director log: the caster log stamped within
    # CASTER_S after each director log's stamp
    casters = []
    for d in directors:
        t = stamp_of(d)
        for c in sorted(Path(logs).glob("caster-*.jsonl")) if t is not None else []:
            ct = stamp_of(c.name)
            if ct is not None and 0 <= ct - t <= CASTER_S and c not in casters:
                casters.append(c)
    return [Path(logs) / d for d in directors], casters, [Path(logs) / h for h in hourly], [Path(logs) / t for t in tours]


CASTER_S = 120
CHART_STALE_S = 900   # the pushed chart's version standing this long while pushes go on: a stale layer


def stamp_of(name):
    """'director-20261026-061113.jsonl' -> its stamp as epoch seconds (Pacific), or None."""
    m = re.search(r"(\d{8})-(\d{6})", str(name))
    if not m:
        return None
    d = datetime.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=PACIFIC)
    return d.timestamp()


# ---- the program --------------------------------------------------------------------------------------------------
class Program:
    """What aired, from the director logs: the shot at any time, by airtime.program()."""

    def __init__(self, director_rows):
        self.rows = sorted((r for r in director_rows if isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
        self.timeline, self.cuts = airtime.program(self.rows)
        # insets: a client set to an inset shot ("inset departure: ...", "inset: Base under attack ..."): on the screen
        # beside the program, which airtime.program() does not follow
        self.insets = [(r["t"], {"reason": r.get("reason"), "agents": list((r.get("target") or {}).get("agents") or []),
                                 "follow": (r.get("cmd") or {}).get("follow"), "spot": self.spot_of(r)})
                       for r in self.rows if r.get("slot") != "program" and
                       re.match(r"(inset|group inset|enemy inset)\b", str(r.get("reason") or ""))]
        # (batch245) where each client's camera was: its command results, in time order
        self.spots = {}
        for r in self.rows:
            sp = self.spot_of(r)
            if sp and r.get("slot") != "program":
                self.spots.setdefault(r["slot"], ([], []))
                self.spots[r["slot"]][0].append(r["t"])
                self.spots[r["slot"]][1].append(sp)

    @staticmethod
    def spot_of(r):
        c = (r.get("result") or {}).get("camera") or {}
        p = c.get("position")
        if not isinstance(p, dict) or p.get("x") is None:
            return None
        return {"x": p["x"], "y": p["y"], "surface": c.get("surface") or "nauvis"}

    def spot(self, t):
        """(batch245) Where the program's camera was at t: the on-air client's latest command result."""
        cl = self.shot(t).get("client")
        ts, sps = self.spots.get(cl, ([], []))
        lo, hi = 0, len(ts)
        while lo < hi:
            mid = (lo + hi) // 2
            if ts[mid] <= t:
                lo = mid + 1
            else:
                hi = mid
        return sps[lo - 1] if lo else None

    def framed(self, t, pos, within=airtime.MISS_S):
        """(batch245) Seconds from t to the first time the program's camera stood within FRAME_TILES of pos (None)."""
        s = t
        while s <= t + within:
            sp = self.spot(s)
            if sp and sp["surface"] == pos["surface"] and math.hypot(sp["x"] - pos["x"], sp["y"] - pos["y"]) <= FRAME_TILES:
                return s - t
            s += STEP
        return None

    def inset_of(self, t, key, pos, within=airtime.MISS_S):
        """(batch245) Seconds from t to an inset naming the threat or framing its spot (None)."""
        for it, sh in self.insets:
            if t - 2 <= it <= t + within:
                sp = sh.get("spot")
                if (key and key in str(sh.get("reason") or "")) or (pos and sp and sp["surface"] == pos["surface"] and
                                                                 math.hypot(sp["x"] - pos["x"], sp["y"] - pos["y"]) <= FRAME_TILES):
                    return max(0.0, it - t)
        return None

    def span(self):
        return (self.rows[0]["t"], self.rows[-1]["t"]) if self.rows else (None, None)

    def shot(self, t):
        return airtime.shot_at(self.timeline, t) or {}

    def first(self, t, match, within=airtime.MISS_S):
        """Seconds from t to the first time the program's shot, or an inset beside it, matches (None: not within)."""
        inset = next((it - t for it, sh in self.insets if t <= it <= t + within and match(sh)), None)
        s = t
        while s <= t + within and (inset is None or s - t < inset):
            if match(self.shot(s)):
                return s - t
            s += STEP
        return inset


def shows_agent(agent):
    return lambda s: s.get("follow") == agent or agent in (s.get("agents") or [])


def shows_text(*words):
    ws = [w.lower() for w in words if w]
    return lambda s: any(w in str(s.get("reason") or "").lower() for w in ws)


def either(*fns):
    return lambda s: any(f(s) for f in fns)


# ---- 1. missed action ---------------------------------------------------------------------------------------------
def events(js, chronicle, director_rows, t0, t1):
    """[{t, cat, who, what, match}]: the big things of [t0, t1] and how to see each on the program."""
    out = []
    for agent, j in js.items():
        for t, kind in j.events:
            if t0 <= t < t1:
                cat = "new build" if kind in BUILD else KINDS.get(kind, kind)
                out.append({"t": t, "cat": cat, "who": agent, "what": f"{agent}: {kind}", "match": shows_agent(agent)})
    for r in chronicle:
        t = r.get("t")
        if r.get("kind") == "platform_created" and isinstance(t, (int, float)) and t0 <= t < t1:
            who = r.get("by")
            out.append({"t": t, "cat": "platform made", "who": who, "what": r.get("line") or f"platform {r.get('platform')} made",
                        "match": either(shows_text(r.get("platform")), shows_agent(who)) if who else shows_text(r.get("platform"))})
    seen = {}
    for r in director_rows:
        th, t = r.get("threat"), r.get("t")
        if not isinstance(th, dict) or not isinstance(t, (int, float)) or not (t0 <= t < t1):
            continue
        key = th.get("key") or f"{th.get('threat')}@{t}"
        e = seen.get(key)
        if e is None:
            kind = str(th.get("threat") or "")
            cat = "loss" if "loss" in kind or key.startswith("loss:") else "battle" if "battle" in kind else "attack" if "attack" in kind else "enemy group"
            m = AREA_RE.match(key)
            w = th.get("where") or {}  # (batch245) a group's place
            pos = {"x": float(m.group(1)), "y": float(m.group(2)), "surface": "nauvis"} if m else \
                dict(w["position"], surface=w.get("surface") or "nauvis") if isinstance(w.get("position"), dict) else None
            e = seen[key] = {"t": t, "cat": cat, "who": None, "what": f"{kind} {key}", "taken": None, "decisions": [],
                             "key": key.split("@")[0], "pos": pos, "whys": []}
            out.append(e)
        e["decisions"].append(th.get("decision"))
        e["whys"].append(str(th.get("why") or ""))
        if th.get("decision") == "take" and e["taken"] is None:
            e["taken"] = t - e["t"]
    for r in director_rows:
        dep, t = r.get("departure"), r.get("t")
        if isinstance(dep, dict) and isinstance(t, (int, float)) and t0 <= t < t1:
            cat = "platform departure (news)" if dep.get("news") else "platform departure (routine)"
            out.append({"t": t, "cat": cat, "who": None, "what": dep.get("label") or dep.get("name"),
                        "decision": dep.get("decision"), "match": shows_text(dep.get("name"))})
    out.sort(key=lambda e: e["t"])
    return out


def coverage(prog, evs, t1):
    """Each event: delay to air (None: missed), by category: n, at once, late, missed, median delay, examples."""
    cats = {}
    for e in evs:
        if "taken" in e:  # a threat: on air when the director took it, or (batch245) the program framed its spot
            d = e["taken"]
            if d is None and e.get("pos"):
                d = prog.framed(e["t"], e["pos"])
            if d is None and all(w.startswith("repeat:") for w in e["whys"]):
                c = cats.setdefault(e["cat"], {"n": 0, "at_once": 0, "late": 0, "missed": 0, "delays": [], "missed_examples": [], "late_examples": []})
                c["n"] += 1  # (batch245) a repeat of a battle aired lately: its inset, by design
                c["not_shown_by_design"] = c.get("not_shown_by_design", 0) + 1
                continue
            if d is None and prog.inset_of(e["t"], e.get("key"), e.get("pos")) is not None:
                c = cats.setdefault(e["cat"], {"n": 0, "at_once": 0, "late": 0, "missed": 0, "delays": [], "missed_examples": [], "late_examples": []})
                c["inset_only"] = c.get("inset_only", 0) + 1  # beside the program, not on it: still counted missed
        elif "decision" in e and e["decision"] == "none":
            e["delay"] = None  # the director chose not to show it (routine): counted apart, not as missed
            c = cats.setdefault(e["cat"], {"n": 0, "at_once": 0, "late": 0, "missed": 0, "delays": [], "missed_examples": [], "late_examples": []})
            c["n"] += 1
            c["not_shown_by_design"] = c.get("not_shown_by_design", 0) + 1
            continue
        else:
            if e["t"] > t1 - airtime.MISS_S and prog.first(e["t"], e["match"], within=max(0.0, t1 - e["t"])) is None:
                continue  # too close to the end to say
            d = prog.first(e["t"], e["match"])
        e["delay"] = d
        c = cats.setdefault(e["cat"], {"n": 0, "at_once": 0, "late": 0, "missed": 0, "delays": [], "missed_examples": [], "late_examples": []})
        c["n"] += 1
        if d is None:
            c["missed"] += 1
            if len(c["missed_examples"]) < EXAMPLES:
                c["missed_examples"].append(f"{local(e['t'])} {e['what']}")
        elif d <= ONCE_S:
            c["at_once"] += 1
        else:
            c["late"] += 1
            if len(c["late_examples"]) < EXAMPLES:
                c["late_examples"].append(f"{local(e['t'])} {e['what']} (on air {round(d)} s later)")
        if d is not None:
            c["delays"].append(d)
    for c in cats.values():
        ds = c.pop("delays")
        c["median_delay_s"] = round(statistics.median(ds), 1) if ds else None
    return cats


# ---- 2. idle airtime ----------------------------------------------------------------------------------------------
def idle(prog, js, t0, t1):
    m = airtime.measure(prog.rows, js, t0, t1, STEP) or {}
    by = airtime.on_air_by(prog.rows, t0, t1, STEP)
    total = sum(by.values()) or 1.0
    empty = by.get("-", 0.0) + by.get(None, 0.0)
    # repeated shots: a shot (whose, and its reason's kind) aired again within REPEAT_S after another one
    shots, last, s = [], None, t0
    while s < t1:
        sh = prog.shot(s)
        key = (airtime.owner(sh), re.sub(r"[\d.,()-]+", "#", str(sh.get("reason") or ""))[:48])
        if key != last:
            shots.append([s, key, STEP])
            last = key
        else:
            shots[-1][2] += STEP
        s += STEP
    seen, rep_s, rep = {}, 0.0, {}
    for t, key, dur in shots:
        view = key[0] and str(key[0]).startswith("@") or not re.match(r"(standby|back to|attention)\b", key[1])
        news = key[0] == "@battle" or re.match(r"battle\b", key[1])  # (batch245) another battle is news, not a repeat
        if key[0] and view and not news and key in seen and t - seen[key] <= REPEAT_S:
            rep_s += dur
            rep.setdefault(key, [0, 0.0, t])
            rep[key][0] += 1
            rep[key][1] += dur
        seen[key] = t + dur
    top = sorted(rep.items(), key=lambda kv: -kv[1][1])[:EXAMPLES]
    return {"minutes": m.get("minutes"), "idle_min": round((m.get("idle_share") or 0) * (m.get("minutes") or 0), 1),
            "loop_min": round((m.get("loop_share") or 0) * (m.get("minutes") or 0), 1),
            "idle_loop_share": m.get("idle_loop_share"), "idle_loop_by_agent_min": m.get("idle_loop_by_agent_min") or {},
            "followed_share": m.get("followed_share"), "cuts_per_min": m.get("cuts_per_min"),
            "fresh_events": m.get("fresh_events"), "fresh_missed": m.get("fresh_missed"), "fresh_delay_median_s": m.get("fresh_delay_median_s"),
            "on_air_min": {k or "-": round(v / 60, 1) for k, v in sorted(by.items(), key=lambda kv: -kv[1])},
            "empty_min": round(empty / 60, 1), "empty_share": round(empty / total, 3),
            "repeat_min": round(rep_s / 60, 1), "repeats": [f"{k[0]} '{k[1]}' again {n}x, {round(d / 60, 1)} min (first repeat {local(t)})" for k, (n, d, t) in top]}


# ---- 3. narration -------------------------------------------------------------------------------------------------
def norm(line):
    return " ".join(re.sub(r"[^a-z ]+", " ", re.sub(r"\d+", "#", str(line).lower())).split())


def narration(caster, audio, chronicle, hourly, tours, t0, t1):
    lines = [r for r in caster if r.get("type") in ("caster", "agent") and isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1]
    cue = [r["t"] - r["exchange"] for r in lines if r.get("type") == "caster" and isinstance(r.get("exchange"), (int, float))]
    # a chronicle event to the caster line naming its platform (the newest such event before the line's cue)
    plat_ev = {}
    for r in chronicle:
        if r.get("platform") and isinstance(r.get("t"), (int, float)):
            plat_ev.setdefault(r["platform"].lower(), []).append(r)
    made = {str(r.get("platform")).lower() for r in chronicle if r.get("kind") == "platform_created"}
    lags, lag_ex, wrong_new, mentions = [], [], [], []
    ex_facts = {}
    for r in lines:
        if r.get("facts") and r.get("exchange") is not None:
            ex_facts.setdefault(r["exchange"], r["facts"])
    for r in lines:
        if r.get("type") != "caster":
            continue
        text = str(r.get("line") or "")
        low = text.lower()
        cue_t = r.get("exchange") or r["t"]
        best = None
        for name, evs in plat_ev.items():
            if re.search(r"\b" + re.escape(name) + r"\b", low):
                prior = [e for e in evs if e["t"] <= cue_t and cue_t - e["t"] <= 1800]
                if prior and (best is None or prior[-1]["t"] > best["t"]):
                    best = prior[-1]
        if best:
            # (d26 batch255) an announcement: the line's own cue is about that platform (its facts name it: an
            # arrival, a departure, the card on screen); else a later line that mentions it (an analyst, info, board or
            # plan cue), counted apart: shift82's "475 s median" was those (an announcement median 28 s)
            fx = r.get("facts") or ex_facts.get(r.get("exchange")) or {}  # (an exchange's second voice logs none)
            subject = " ".join(str(fx.get(k) or "") for k in ("arrival", "departure")).lower() + \
                (str(fx.get("text") or "").lower() if r.get("event") in ("arrival", "departure") else "") + \
                (str(fx.get("on_screen_now")).lower() if "depart" in str(fx.get("on_screen_now")) else "")
            own = re.search(r"\b" + re.escape(best["platform"].lower()) + r"\b", subject)
            (lags if own else mentions).append(r["t"] - best["t"])
            if own and len(lag_ex) < EXAMPLES and r["t"] - best["t"] > 120:
                lag_ex.append(f"{local(best['t'])} {best.get('line')} -> {local(r['t'])} \"{text[:90]}\"")
        cue_text = str((r.get("facts") or {}).get("text") or "")
        m = re.match(r"New space platform: (.+)", cue_text)
        if m and m.group(1).strip().lower() not in made:
            wrong_new.append(f"{local(r['t'])} \"{text[:100]}\" (its cue: \"{cue_text}\"; the run made no platform "
                             f"{m.group(1).strip()}: {', '.join(sorted(made)) or 'none'} made)")
    # an agent's chat line to its voiced line
    chats = [r for r in caster if r.get("type") == "chat_decision" and r.get("voiced")]
    voiced = [r for r in lines if r.get("type") == "agent"]
    chat_lag = []
    for v in voiced:
        cands = [c for c in chats if c.get("agent") == v.get("agent") and c["t"] <= v["t"] and v["t"] - c["t"] <= 600]
        if cands:
            chat_lag.append(v["t"] - cands[-1]["t"])
    # repeats: the same line (digits and punctuation aside) again in the span
    seen, repeats = {}, []
    for r in lines:
        k = norm(r.get("line"))
        if len(k.split()) < 4:
            continue
        if k in seen:
            repeats.append(f"{local(r['t'])} \"{str(r.get('line'))[:90]}\" (first {local(seen[k])})")
        else:
            seen[k] = r["t"]
    # the audio queue: a clip's wait from its push (its id's epoch) to its start; clips cut short or skipped
    waits, early, skipped, by_ch = [], [], 0, {}
    for r in audio:
        if not (isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1) or not r.get("ended"):
            continue
        if r.get("state") == "skip":
            skipped += 1
            continue
        m = re.match(r"(\d{9,11})", str(r.get("id") or ""))
        if m and isinstance(r.get("played"), (int, float)):
            w = r["t"] - r["played"] - int(m.group(1))
            if -5 <= w <= 3600:
                waits.append(w)
                by_ch.setdefault(r.get("channel") or "?", []).append(w)
        if r.get("early"):
            early.append(f"{local(r['t'])} {r.get('channel')} {r.get('speaker')}: played {r.get('played')} of {r.get('duration')} s ({r.get('reason')})")
    pieces = [r for r in hourly if r.get("event") == "written" and isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1]
    aired = [r for rs in tours for r in rs if r.get("event") == "aired" and isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1]
    return {"lines": len(lines), "caster_lines": sum(1 for r in lines if r.get("type") == "caster"), "agent_lines": len(voiced),
            "cue_to_line_median_s": q(cue, 50), "cue_to_line_p90_s": q(cue, 90),
            "event_to_line_n": len(lags), "event_to_line_median_s": q(lags, 50), "event_to_line_p90_s": q(lags, 90), "event_to_line_examples": lag_ex,
            "mention_n": len(mentions), "mention_median_s": q(mentions, 50),
            "chat_to_voice_median_s": q(chat_lag, 50), "chat_to_voice_p90_s": q(chat_lag, 90),
            "audio_wait_median_s": q(waits, 50), "audio_wait_p90_s": q(waits, 90),
            "audio_wait_by_channel_median_s": {k: q(v, 50) for k, v in sorted(by_ch.items())},
            "clips_cut_short": len(early), "clips_cut_short_examples": early[:EXAMPLES], "clips_skipped": skipped,
            "repeated_lines": len(repeats), "repeated_examples": repeats[:EXAMPLES],
            "called_new_wrongly": wrong_new[:EXAMPLES], "called_new_wrongly_n": len(wrong_new),
            "hourly_pieces": len(pieces), "tour_stops_aired": len(aired)}


def q(xs, pct):
    """The pct-th percentile (50: the median, the mean of the middle two when they are even), or None."""
    xs = sorted(xs)
    if not xs:
        return None
    if pct == 50:
        return round(statistics.median(xs), 1)
    return round(xs[min(len(xs) - 1, int(len(xs) * pct / 100))], 1)


# ---- 4. data clarity ----------------------------------------------------------------------------------------------
def clarity(run, svc, day, t0, t1, updates_path):
    out = {}
    pushes, fails, gaps, stuck = [], [], [], []
    p = Path(run) / "push-live.log"
    prev_t, prev_tick, same = None, None, 0
    chart_v, chart_since, chart_stale, no_terrain = None, None, [], []
    for line in (p.read_text(errors="replace").splitlines() if p.is_file() else []):
        m = re.match(r"\[push\] (\d\d:\d\d:\d\d) (ok|failed)[^:]*: ?(.*)", line)
        if not m:
            continue
        t = epoch(day, m.group(1))
        if prev_t is not None and t < prev_t - 43200:
            day = day + datetime.timedelta(days=1)
            t = epoch(day, m.group(1))
        if not (t0 <= t < t1):
            prev_t = t
            continue
        if m.group(2) == "failed":
            fails.append(f"{m.group(1)} {m.group(3)[:90]}")
        else:
            tick = re.search(r"tick (\d+)", m.group(3))
            tick = int(tick.group(1)) if tick else None
            pushes.append(t)
            # the chart layer: its version standing while the pushes go on; the terrain layer: no frames
            v = re.search(r"chart v(\d+)", m.group(3))
            v = int(v.group(1)) if v else None
            if v is not None and v != chart_v:
                if chart_since is not None and t - chart_since > CHART_STALE_S:
                    chart_stale.append(f"{local(chart_since)}-{m.group(1)}: chart v{chart_v} for {round((t - chart_since) / 60)} min")
                chart_v, chart_since = v, t
            if re.search(r"terrain frames 0\b", m.group(3)):
                no_terrain.append(m.group(1))
            same = same + 1 if tick is not None and tick == prev_tick else 0
            if same == 2:
                stuck.append(f"{m.group(1)}: the pushed state's tick {tick} unchanged for 3 pushes")
            prev_tick = tick
        if prev_t is not None and t - prev_t > 180 and t0 <= prev_t:
            gaps.append(f"{local(prev_t)}-{m.group(1)} ({round((t - prev_t) / 60, 1)} min with no push line)")
        prev_t = t
    if chart_since is not None and pushes and pushes[-1] - chart_since > CHART_STALE_S:
        chart_stale.append(f"{local(chart_since)}-{local(pushes[-1])}: chart v{chart_v} for {round((pushes[-1] - chart_since) / 60)} min (to the end)")
    out["push"] = {"ok_lines": len(pushes), "failed": len(fails), "failed_examples": fails[:EXAMPLES], "gaps": gaps[:EXAMPLES],
                   "gaps_n": len(gaps), "tick_stuck": stuck[:EXAMPLES], "chart_stale": chart_stale[:EXAMPLES],
                   "terrain_empty_pushes": len(no_terrain)}
    empty_layers, frames = [], {"saved": 0, "skipped": 0, "errors": 0}
    for t, tag, hms, text in svc:
        if t is None or not (t0 <= t < t1):
            continue
        if tag == "chart":
            m = re.search(r"(\d+) surfaces \((\d+) with cells\)", text)
            if m and int(m.group(2)) < int(m.group(1)):
                empty_layers.append(f"{hms} chart: {int(m.group(1)) - int(m.group(2))} of {m.group(1)} surfaces without cells")
    mf = Path(run) / "mapframes.log"
    for line in (mf.read_text(errors="replace").splitlines() if mf.is_file() else []):
        m = re.match(r"\[mapframes\] (\d\d:\d\d:\d\d) (saved|skipped|error):", line)
        if m and t0 <= epoch(day, m.group(1)) < t1:
            frames[{"saved": "saved", "skipped": "skipped", "error": "errors"}[m.group(2)]] += 1
    out["chart_empty_layers"] = empty_layers[:EXAMPLES]
    out["base_map_frames"] = frames
    up = {}
    try:
        import updates as upd
        data = upd.load(updates_path)
        now = datetime.datetime.fromtimestamp(t1, PACIFIC).replace(tzinfo=None)
        # open: planned or in progress; due: its next review passed, or none (batch235's fields; a row without them is due)
        open_ = [u for u in data["updates"] if u.get("status") in ("planned", "in progress")]
        due = [u for u in open_ if not upd.when(u.get("next_review")) or upd.when(u["next_review"]) <= now]

        def changed(u):
            ts = [upd.when(v) for v in (u.get("dates") or {}).values()] + [upd.when(u.get("note_at"))]
            ts = [x for x in ts if x]
            return max(ts) if ts else None

        def ago(x):
            if not x:
                return "?"
            h = (now - x).total_seconds() / 3600
            return f"{h / 24:.1f} d" if h >= 24 else f"{h:.1f} h"
        up = {"open": len(open_), "due_for_review": len(due), "no_owner": sum(1 for u in open_ if not u.get("owner")),
              "no_priority": sum(1 for u in open_ if not u.get("priority")),
              "oldest_open": [f"{u['id']} ({u['status']}, changed {ago(changed(u))} ago)"
                              for u in sorted(open_, key=lambda u: changed(u) or datetime.datetime.min)[:EXAMPLES]]}
    except Exception as x:  # the review reads the page's data only to count it
        up = {"error": f"{type(x).__name__}: {x}"}
    out["updates_page"] = up
    return out


# ---- 5. cost ------------------------------------------------------------------------------------------------------
def cost(svc, caster, t0, t1):
    slow, kinds, errors = [], {}, 0
    for t, tag, _, text in svc:
        if t is None or not (t0 <= t < t1):
            continue
        if tag == "slow-rcon":
            m = re.match(r"([\d.]+)s (\d+) B: (.*)", text)
            if m:
                s = float(m.group(1))
                slow.append(s)
                k = re.sub(r"\s+", " ", m.group(3))[:60]
                kinds.setdefault(k, [0, 0.0])
                kinds[k][0] += 1
                kinds[k][1] += s
        elif tag is None and re.match(r"\w*(Error|Exception): ", text):
            errors += 1
    usd = [r.get("usd_per_hour") for r in caster if r.get("type") == "cost" and isinstance(r.get("usd_per_hour"), (int, float))
           and isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1]
    top = sorted(kinds.items(), key=lambda kv: -kv[1][1])[:3]
    return {"slow_game_reads": len(slow), "slow_game_read_s": round(sum(slow), 1), "slow_game_read_max_s": max(slow) if slow else None,
            "slow_game_read_top": [f"{n}x {round(s, 1)} s: {k}" for k, (n, s) in top], "service_errors": errors,
            "caster_usd_per_hour_median": q(usd, 50), "game_reads_by_this_review": 0}


# ---- the review ---------------------------------------------------------------------------------------------------
def review(run, logs, t_from=None, t_to=None, updates_path=None):
    started = time.time()
    run = Path(run)
    svc = service_lines(run)
    dirs, casters, hourlies, tours = stream_logs(run, logs, svc)
    drows = [r for d in dirs for r in rows(d)]
    prog = Program(drows)
    a, b = prog.span()
    if a is None:
        raise SystemExit(f"{run}: no director log named in stream-service.log under {logs}")
    day = day_of(a)
    t0 = epoch(day, t_from) if t_from else a
    t1 = epoch(day, t_to) if t_to else b
    if t1 <= t0:
        t1 += 86400
    t0, t1 = max(t0, a), min(t1, b)
    svc_t = timed(svc, day)
    js = airtime.journals([str(run)], end=t1)
    chronicle = rows(run / "chronicle.jsonl")
    caster = [r for c in casters for r in rows(c)]
    audio = rows(run / "audio-played.jsonl")
    hourly = [r for h in hourlies for r in rows(h)]
    tour_rows = [rows(t) for t in tours]
    evs = events(js, chronicle, prog.rows, t0, t1)
    out = {"run": run.name, "from": local(t0), "to": local(t1), "minutes": round((t1 - t0) / 60, 1),
           "inputs": {"director": [d.name for d in dirs], "caster": [c.name for c in casters if c.is_file()],
                      "hourly": [h.name for h in hourlies], "tour_hourly": [t.name for t in tours],
                      "journals": sorted(js)},
           "missed_action": coverage(prog, evs, t1),
           "rockets": dict(rocket_count(chronicle, t0, t1),  # (batch257) and the launch shot's
                           on_air=airtime.launches_on_air(prog.rows, airtime.chronicle_rockets(chronicle)[0], t0, t1)),
           "idle_airtime": idle(prog, js, t0, t1),
           "narration": narration(caster, audio, chronicle, hourly, tour_rows, t0, t1),
           "data_clarity": clarity(run, svc_t, day, t0, t1, updates_path or (HERE.parent.parent / "site" / "content" / "operator-updates.json")),
           "cost": cost(svc_t, caster, t0, t1)}
    out["findings"] = findings(out)
    out["cost"]["review_s"] = round(time.time() - started, 1)
    return out


def rocket_count(chronicle, t0, t1):
    by = {}
    for r in chronicle:
        if r.get("kind") == "rocket" and isinstance(r.get("t"), (int, float)) and t0 <= r["t"] < t1:
            by[r.get("surface") or "?"] = by.get(r.get("surface") or "?", 0) + 1
    return {"launches": sum(by.values()), "by_surface": by}


def findings(r):
    """The weaknesses, each {area, what, minutes (viewer-minutes it touches, when it can be said), examples}, the most
    viewer-minutes first."""
    f = []
    ia = r["idle_airtime"]
    if ia.get("idle_min") or ia.get("loop_min"):
        f.append({"area": "idle airtime", "minutes": round((ia.get("idle_min") or 0) + (ia.get("loop_min") or 0), 1),
                  "what": f"{ia.get('idle_min')} min of a standing character and {ia.get('loop_min')} min of walk loops on air "
                          f"({round(100 * (ia.get('idle_loop_share') or 0), 1)}% of {ia.get('minutes')} min)",
                  "examples": [f"{k} {v} min" for k, v in list(ia.get("idle_loop_by_agent_min", {}).items())[:EXAMPLES]]})
    if ia.get("repeat_min"):
        f.append({"area": "idle airtime", "minutes": ia["repeat_min"], "what": f"{ia['repeat_min']} min of repeated shots", "examples": ia["repeats"]})
    if ia.get("empty_min"):
        f.append({"area": "idle airtime", "minutes": ia["empty_min"], "what": f"{ia['empty_min']} min with no shot", "examples": []})
    for cat, c in r["missed_action"].items():
        if c["missed"] or c["late"]:
            f.append({"area": "missed action", "minutes": round(c["missed"] * 2 + c["late"] * 0.5, 1),
                      "what": f"{cat}: {c['missed']} of {c['n']} never on air, {c['late']} late"
                              + (f" (median {c['median_delay_s']} s to air)" if c["median_delay_s"] is not None else ""),
                      "examples": c["missed_examples"] + c["late_examples"]})
    n = r["narration"]
    if n["called_new_wrongly_n"]:
        f.append({"area": "narration", "minutes": n["called_new_wrongly_n"] * 1.0,
                  "what": f"{n['called_new_wrongly_n']} lines call a platform new that the run did not make", "examples": n["called_new_wrongly"]})
    if n["repeated_lines"]:
        f.append({"area": "narration", "minutes": n["repeated_lines"] * 0.5, "what": f"{n['repeated_lines']} lines said again word for word",
                  "examples": n["repeated_examples"]})
    if (n["event_to_line_p90_s"] or 0) > 120:
        f.append({"area": "narration", "minutes": n["event_to_line_n"] * 0.1,
                  "what": f"an event to the line announcing it: median {n['event_to_line_median_s']} s, p90 {n['event_to_line_p90_s']} s",
                  "examples": n["event_to_line_examples"]})
    if n["clips_cut_short"]:
        f.append({"area": "narration", "minutes": n["clips_cut_short"] * 0.2, "what": f"{n['clips_cut_short']} clips cut short",
                  "examples": n["clips_cut_short_examples"]})
    d = r["data_clarity"]
    if d["push"]["failed"] or d["push"]["gaps_n"] or d["push"]["tick_stuck"]:
        f.append({"area": "data clarity", "minutes": d["push"]["gaps_n"] * 3.0 + d["push"]["failed"] * 1.0,
                  "what": f"site push: {d['push']['failed']} failures, {d['push']['gaps_n']} gaps over 3 min, {len(d['push']['tick_stuck'])} stretches of a frozen tick",
                  "examples": d["push"]["failed_examples"] + d["push"]["gaps"] + d["push"]["tick_stuck"]})
    if d["push"]["chart_stale"] or d["push"]["terrain_empty_pushes"]:
        f.append({"area": "data clarity", "minutes": 1.0, "what": f"site layers: {len(d['push']['chart_stale'])} stretches of a chart standing over "
                  f"{CHART_STALE_S // 60} min, {d['push']['terrain_empty_pushes']} pushes with no terrain frames", "examples": d["push"]["chart_stale"]})
    if d["chart_empty_layers"]:
        f.append({"area": "data clarity", "minutes": 1.0, "what": "chart surfaces without cells", "examples": d["chart_empty_layers"]})
    up = d.get("updates_page") or {}
    if up.get("due_for_review"):
        f.append({"area": "data clarity", "minutes": 0.5, "what": f"Updates page: {up['due_for_review']} of {up['open']} open rows due for review, "
                  f"{up['no_owner']} with no owner, {up['no_priority']} with no priority", "examples": up.get("oldest_open") or []})
    f.sort(key=lambda x: -x["minutes"])
    return f


def markdown(r):
    ia, n, d, c = r["idle_airtime"], r["narration"], r["data_clarity"], r["cost"]
    L = [f"# Viewer-experience review: {r['run']} {r['from']}-{r['to']} ({r['minutes']} min)", "",
         f"Inputs: director {', '.join(r['inputs']['director'])}; caster {', '.join(r['inputs']['caster']) or 'none'}; "
         f"{len(r['inputs']['journals'])} journals; hourly {', '.join(r['inputs']['hourly']) or 'none'}. Logs only: no game reads.", "",
         "## Findings, most viewer-minutes first", ""]
    for x in r["findings"]:
        L.append(f"- **{x['area']}** ({x['minutes']} min): {x['what']}")
        L += [f"  - {e}" for e in x["examples"][:3]]
    L += ["", "## 1. Missed action", "", "| Kind | Events | At once | Late | Missed (of them in the inset) | Not shown by design | Median to air (s) |",
          "|---|---|---|---|---|---|---|"]
    for cat, v in sorted(r["missed_action"].items(), key=lambda kv: -kv[1]["n"]):
        ins = f" ({v['inset_only']})" if v.get("inset_only") else ""
        L.append(f"| {cat} | {v['n']} | {v['at_once']} | {v['late']} | {v['missed']}{ins} | {v.get('not_shown_by_design', 0)} | {v['median_delay_s']} |")
    rk = r["rockets"]
    la = rk.get("on_air") or {}
    L += ["", f"Rockets launched: {rk['launches']} ({', '.join(f'{k} {v}' for k, v in rk['by_surface'].items()) or 'none'}); "
          + (f"launch shots {la['shots']} ({la['shot_min']} min); rockets lifting off on air {la['on_air']} of {la['rockets']}, "
             f"{la['cut_before']} of them with the shot up before lift-off (by planet: the chronicle names no silo); "
             if la.get("shots") else "no launch shot on air; ") + "they are not counted as missed.", "",
          "## 2. Idle airtime", "",
          f"- Standing character {ia['idle_min']} min, walk loops {ia['loop_min']} min ({round(100 * (ia['idle_loop_share'] or 0), 1)}% of {ia['minutes']} min); "
          f"by agent: {ia['idle_loop_by_agent_min']}.",
          f"- No shot {ia['empty_min']} min; repeated shots {ia['repeat_min']} min; cuts {ia['cuts_per_min']} a minute.",
          f"- On air by whose shot (min): {dict(list(ia['on_air_min'].items())[:12])}.", "",
          "## 3. Narration", "",
          f"- {n['lines']} lines ({n['caster_lines']} caster, {n['agent_lines']} agents). Cue to line: median {n['cue_to_line_median_s']} s, p90 {n['cue_to_line_p90_s']} s.",
          f"- An event to the caster line announcing it (its cue names the platform; {n['event_to_line_n']} lines): median {n['event_to_line_median_s']} s, p90 {n['event_to_line_p90_s']} s; later lines that mention the platform, from other cues: {n['mention_n']}, median {n['mention_median_s']} s since its last event.",
          f"- An agent's chat to its voiced line: median {n['chat_to_voice_median_s']} s, p90 {n['chat_to_voice_p90_s']} s.",
          f"- Audio queue wait to play: median {n['audio_wait_median_s']} s, p90 {n['audio_wait_p90_s']} s; by channel {n['audio_wait_by_channel_median_s']}; "
          f"{n['clips_cut_short']} cut short, {n['clips_skipped']} skipped.",
          f"- Repeated lines: {n['repeated_lines']}; lines calling a platform new wrongly: {n['called_new_wrongly_n']}; "
          f"hourly pieces {n['hourly_pieces']}, tour stops aired {n['tour_stops_aired']}.", "",
          "## 4. Data clarity", "",
          f"- Site push: {d['push']['ok_lines']} ok lines, {d['push']['failed']} failed, {d['push']['gaps_n']} gaps over 3 min, "
          f"{len(d['push']['tick_stuck'])} frozen-tick stretches; the chart layer standing over {CHART_STALE_S // 60} min "
          f"{len(d['push']['chart_stale'])} times, {d['push']['terrain_empty_pushes']} pushes with no terrain frames.",
          f"- Chart: {len(d['chart_empty_layers'])} reads with surfaces lacking cells. Base-map frames: {d['base_map_frames']}.",
          f"- Updates page: {d['updates_page']}.", "",
          "## 5. Cost", "",
          f"- The stream service's slow game reads: {c['slow_game_reads']} ({c['slow_game_read_s']} s, worst {c['slow_game_read_max_s']} s); top: {c['slow_game_read_top']}.",
          f"- Service errors: {c['service_errors']}. Caster spend: median {c['caster_usd_per_hour_median']} USD an hour.",
          f"- This review: {c.get('review_s')} s, {c['game_reads_by_this_review']} game reads.", ""]
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run")
    ap.add_argument("--from", dest="t_from", help="HH:MM (Pacific)")
    ap.add_argument("--to", dest="t_to", help="HH:MM (Pacific)")
    ap.add_argument("--logs", default=str(HERE / "logs"))
    ap.add_argument("--updates", help="the Updates data (default site/content/operator-updates.json)")
    ap.add_argument("--out", help="where vx-review.md and vx-review.json go (default the run folder)")
    a = ap.parse_args(argv)
    r = review(a.run, a.logs, a.t_from, a.t_to, a.updates)
    out = Path(a.out or a.run)
    out.mkdir(parents=True, exist_ok=True)
    (out / "vx-review.json").write_text(json.dumps(r, indent=1, default=str))
    (out / "vx-review.md").write_text(markdown(r))
    print(f"{out / 'vx-review.md'}: {len(r['findings'])} findings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
