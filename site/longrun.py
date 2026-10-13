"""The long run: one world played over many shifts (runs/RUN/resumed-from chains them), for site/build.py.

Read-only, from each shift's folder: scores.jsonl (game time, research, science packs made, rockets, platforms and
where they are, planets), start.log (only its timestamps: the rest names accounts and quotas), stream-service.log (the
director's lines: deaths and losses it cut to), caster.log (the hosts' Space Age lines and their answers to viewers)
and chat.jsonl (viewer lines that reached the game, and the agents' answers that name them). No journals.

Science packs made: the game's production counters can fall (a platform's own counts go with it when it is lost, and
a counter can restart), so every pack is counted from the rise between consecutive score rows, a fall counted as 0.
Rates come from that running total, so they are never below 0.
"""
import datetime
import json
import os
import re
from pathlib import Path

SCIENCE = re.compile(r"-science-pack$")
# every science pack in tech-tree order: (item, label)
PACKS = [("automation-science-pack", "Red"), ("logistic-science-pack", "Green"), ("military-science-pack", "Military"),
         ("chemical-science-pack", "Blue"), ("production-science-pack", "Purple"), ("utility-science-pack", "Yellow"),
         ("space-science-pack", "Space"), ("metallurgic-science-pack", "Metallurgic"),
         ("electromagnetic-science-pack", "Electromagnetic"), ("agricultural-science-pack", "Agricultural"),
         ("cryogenic-science-pack", "Cryogenic"), ("promethium-science-pack", "Promethium")]
PACK_LABEL = dict(PACKS)
# technologies worth a line in a shift's moments (the rest is in the research count)
MILESTONES = {
    "oil-processing": "oil processing", "advanced-oil-processing": "advanced oil processing",
    "plastics": "plastics", "sulfur-processing": "sulfur", "batteries": "batteries",
    "construction-robotics": "construction robots", "logistic-robotics": "logistic robots",
    "nuclear-power": "nuclear power", "uranium-processing": "uranium processing",
    "kovarex-enrichment-process": "Kovarex enrichment", "rocket-silo": "the rocket silo",
    "space-platform-thruster": "platform thrusters", "space-science-pack": "space science",
    "planet-discovery-vulcanus": "the Vulcanus discovery", "planet-discovery-fulgora": "the Fulgora discovery",
    "planet-discovery-gleba": "the Gleba discovery", "planet-discovery-aquilo": "the Aquilo discovery",
    "metallurgic-science-pack": "metallurgic science",
    "electromagnetic-science-pack": "electromagnetic science", "agricultural-science-pack": "agricultural science",
    "cryogenic-science-pack": "cryogenic science", "promethium-science-pack": "promethium science",
    "artillery": "artillery", "laser-turret": "laser turrets", "spidertron": "the spidertron",
}
# technologies in the milestones table, in tree order: name -> label
TECH_FIRSTS = [
    ("automation", "Automation"), ("electronics", "Electronics"), ("logistics", "Logistics"),
    ("steel-processing", "Steel processing"), ("military-science-pack", "Military science"),
    ("chemical-science-pack", "Chemical science"), ("oil-processing", "Oil processing"),
    ("advanced-oil-processing", "Advanced oil processing"), ("plastics", "Plastics"),
    ("advanced-circuit", "Advanced circuits"), ("battery", "Batteries"), ("robotics", "Robotics"),
    ("construction-robotics", "Construction robots"), ("logistic-robotics", "Logistic robots"),
    ("uranium-processing", "Uranium processing"), ("nuclear-power", "Nuclear power"),
    ("kovarex-enrichment-process", "Kovarex enrichment"), ("production-science-pack", "Production science"),
    ("utility-science-pack", "Utility science"), ("rocket-fuel", "Rocket fuel"),
    ("low-density-structure", "Low density structure"), ("processing-unit", "Processing units"),
    ("rocket-silo", "Rocket silo"), ("space-platform", "Space platform"),
    ("space-platform-thruster", "Platform thrusters"), ("space-science-pack", "Space science"),
    ("planet-discovery-vulcanus", "Vulcanus discovered"), ("planet-discovery-fulgora", "Fulgora discovered"),
    ("planet-discovery-gleba", "Gleba discovered"), ("planet-discovery-aquilo", "Aquilo discovered"),
    ("foundry", "Foundry"), ("big-mining-drill", "Big mining drill"), ("metallurgic-science-pack", "Metallurgic science"),
    ("electromagnetic-plant", "Electromagnetic plant"), ("recycling", "Recycling"),
    ("electromagnetic-science-pack", "Electromagnetic science"), ("agricultural-science-pack", "Agricultural science"),
    ("cryogenic-science-pack", "Cryogenic science"), ("artillery", "Artillery"), ("spidertron", "Spidertron"),
    ("railgun", "Railgun"), ("promethium-science-pack", "Promethium science"),
]
ROCKET_COUNTS = (1, 10, 25, 50, 100, 250, 500, 1000)
TECH_COUNTS = (25, 50, 100, 150, 200)
# the director's reason for a cut: "<- attack: ..." before shift01, "<- death: ..." / "<- loss: ..." since
DEATH = re.compile(r"<- (?:attack|death): (.+?) died\b")
LOSS = re.compile(r"<- (?:attack|loss): (\d+ lost near .*)$")
CLOCK = re.compile(r"(\d\d):(\d\d):(\d\d)")
HOST = re.compile(r"^(\d\d:\d\d:\d\d) \[\w+\] \(space[^,]*, [^)]*\) (.*)$")
HOST_CALL = re.compile(r"^(\d\d:\d\d:\d\d) \[(\w+)\] \((space\w*|research|attack|loss), [^)]*\) (.*)$")
# a research, attack or loss call is a big one when it names one of these
BIG = re.compile(r"(?i)\b(rocket|silo|platform|hub|orbit|vulcanus|fulgora|gleba|aquilo|space science|oil processing|"
                 r"robot|nuclear|uranium|kovarex|foundry|planet|blue science|purple|yellow|metallurgic|landing)")
HOST_REPLY = re.compile(r"^(\d\d:\d\d:\d\d) \[(\w+)\] \(viewer_reply, [^)]*\) (.*)$")


def game_time(tick):
    m = int(tick // 3600)
    return f"{m // 60}h{m % 60:02d}m"


def parents(runs_dir):
    parent = {}
    for d in runs_dir.iterdir() if runs_dir.is_dir() else []:
        f = d / "resumed-from"
        if d.is_dir() and f.exists():
            parent[d.name] = f.read_text().strip()
    return parent


def chain(runs_dir, start=None):
    """The longest chain of shifts linked by resumed-from, oldest first ([] when there is none). With start: the
    longest chain that begins at that run (just [start] until a shift resumes from it; [] without its folder)."""
    parent = parents(runs_dir)
    if start:
        if not (runs_dir / start).is_dir():
            return []
        kids = {}
        for k, p in parent.items():
            kids.setdefault(p, []).append(k)

        def longest(node, seen):
            best = [node]
            for k in sorted(kids.get(node, [])):
                if k not in seen and (runs_dir / k).is_dir():
                    c = [node] + longest(k, seen | {k})
                    if len(c) > len(best):
                        best = c
            return best
        return longest(start, {start})
    best = []
    for leaf in set(parent) - set(parent.values()):
        c, seen = [leaf], {leaf}
        while c[-1] in parent and parent[c[-1]] not in seen and (runs_dir / parent[c[-1]]).is_dir():
            c.append(parent[c[-1]])
            seen.add(c[-1])
        if len(c) > len(best):
            best = c
    return list(reversed(best)) if len(best) > 1 else []


def scores(path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        s = row.get("score") or {}
        if s.get("tick") is None:
            continue
        done = s.get("research_done") or []
        produced = s.get("produced") or {}
        plats = [p for p in s.get("platforms") or [] if isinstance(p, dict) and p.get("hub", True) and p.get("name")]
        rows.append({"tick": s["tick"], "raw": s["tick"], "t": row.get("t"),
                     "research": len(done if isinstance(done, list) else list(done)),
                     "done": set(done if isinstance(done, list) else done),
                     "science": sum(v for k, v in produced.items() if SCIENCE.search(k)),
                     "packs": {k: v for k, v in produced.items() if SCIENCE.search(k) and isinstance(v, (int, float))},
                     "rockets": s.get("rockets") or 0,
                     "current": s.get("current_research") if isinstance(s.get("current_research"), str) else None,
                     "platforms": [p["name"] for p in plats],
                     "at": {p["name"]: p.get("at") for p in plats},
                     "planets": list(s.get("planets") or [])})
    rows.sort(key=lambda r: r["tick"])
    return rows


def parse_t(t):
    try:
        return datetime.datetime.fromisoformat(t)
    except (TypeError, ValueError):
        return None


def log_times(path):
    """First and last HH:MM:SS of a log, with the file's date (start.log has no dates)."""
    if not path.exists():
        return None, None
    times = re.findall(r"^(\d\d:\d\d):\d\d ", path.read_text(errors="replace"), re.M)
    day = datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    return (f"{day}T{times[0]}", f"{day}T{times[-1]}") if times else (None, None)


def clock_at(start, hms):
    """A log line's HH:MM:SS as a datetime in the shift that began at `start` (a shift can run past midnight)."""
    h, m, s = map(int, hms)
    t = start.replace(hour=h, minute=m, second=s, microsecond=0)
    if t < start - datetime.timedelta(minutes=30):
        t += datetime.timedelta(days=1)
    return t


def stream_events(path, start=None, detail=False):
    """Deaths and loss alerts the director cut to, from stream-service.log: each death once; each loss alert once (a
    loss stays in the game's alerts for minutes and comes back as a new alert, so its building counts would add up the
    same buildings several times: the number of alerts is the honest count). With detail, also the list of deaths
    [(datetime, who)] and the first loss alert's time, dated from start (the shift's first score time)."""
    if not path.exists():
        return (0, 0, [], None) if detail else (0, 0)
    deaths, losses, last, died, first_loss = 0, 0, {}, [], None

    def new(key, line):
        """One death or alert shows on two director lines (the zoom, then the cut) a few seconds apart."""
        try:
            h, mi, s = map(int, line[11:19].split(":"))
            t = h * 3600 + mi * 60 + s
        except ValueError:
            t = None
        prev = last.get(key)
        last[key] = t
        return t is None or prev is None or not 0 <= t - prev <= 60

    for line in path.read_text(errors="replace").splitlines():
        if "<- " not in line:
            continue
        c = CLOCK.search(line[:24])
        when = clock_at(start, c.groups()) if (start and c) else None
        m = DEATH.search(line)
        if m and new(("death", m.group(1)), line):
            deaths += 1
            if when:
                died.append((when, m.group(1)))
        m = LOSS.search(line)
        if m and new(("loss", m.group(1)), line):
            losses += 1
            if when and first_loss is None:
                first_loss = when
    return (deaths, losses, died, first_loss) if detail else (deaths, losses)


def host_moments(path, limit=2):
    if not path.exists():
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = HOST.match(line)
        if m:
            out.append(m.group(2))
    return out[:limit]


def host_replies(path, start):
    """The hosts' answers to viewers: [(datetime, host, text)]."""
    if not path.exists() or not start:
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = HOST_REPLY.match(line)
        if m:
            out.append((clock_at(start, m.group(1).split(":")), m.group(2), m.group(3)))
    return out


def host_calls(path, start, limit=10):
    """The hosts' big calls: every Space Age moment, and research, attack and loss calls that name a big subject
    (BIG): [(datetime, host, text)] in time order, at most `limit`: the Space Age moments first, then the rest in
    order (so a long shift's early research calls do not crowd out its rocket)."""
    if not path.exists() or not start:
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = HOST_CALL.match(line)
        if m and (m.group(3).startswith("space") or BIG.search(m.group(4))):
            out.append((not m.group(3).startswith("space"), len(out), clock_at(start, m.group(1).split(":")), m.group(2), m.group(4)))
    return [c[2:] for c in sorted(sorted(out)[:limit], key=lambda c: c[1])]


def in_progress(name):
    """Research under way, by its plain name: 'planet-discovery-fulgora' -> 'Planet discovery: Fulgora'."""
    if not name:
        return None
    if name.startswith("planet-discovery-"):
        return "Planet discovery: " + name[len("planet-discovery-"):].capitalize()
    return name.replace("-", " ").capitalize()


def label(name):
    return name.replace("-", " ")


TECH_LABEL = dict(TECH_FIRSTS)


def tech_label(name):
    """'mining-productivity-2' -> 'Mining productivity 2' (the milestones' own labels where they have one)."""
    if name in TECH_LABEL:
        return TECH_LABEL[name]
    s = name.replace("-", " ")
    return s[:1].upper() + s[1:]


def rebase(r, origin):
    """A score row counted from origin (the save the first shift resumed from): game time, technologies, rockets,
    platforms and planets other than Nauvis that the save already had are left out."""
    if not origin:
        return r
    return dict(r, tick=r["tick"] - origin["tick"], done=r["done"] - origin["done"],
                research=len(r["done"] - origin["done"]), rockets=max(0, r["rockets"] - origin["rockets"]),
                platforms=[p for p in r["platforms"] if p not in origin["platforms"]],
                at={k: v for k, v in r.get("at", {}).items() if k not in origin["platforms"]},
                planets=[p for p in r["planets"] if p == "nauvis" or p not in origin["planets"]])


def interp(xs, ys, x):
    """Linear interpolation on sorted xs (clamped at the ends)."""
    if not xs:
        return None
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    lo, hi = 0, len(xs) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] <= x:
            lo = mid
        else:
            hi = mid
    f = (x - xs[lo]) / ((xs[hi] - xs[lo]) or 1)
    return ys[lo] + (ys[hi] - ys[lo]) * f


def chat_lines(path):
    if not path.exists():
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            c = json.loads(line)
        except ValueError:
            continue
        if isinstance(c, dict) and isinstance(c.get("tick"), (int, float)) and isinstance(c.get("text"), str):
            out.append(c)
    return out


def load(runs_dir, clean=lambda s: s, start=None, keep=lambda s: True, agents=()):
    """{"shifts": [row per shift], "research": [(game minute, technologies)], "spm": [(game minute, packs/min)],
    "spm_packs": {pack: [(game minute, packs/min)]}, "rockets": [(game minute, rockets)], "made": {pack: total},
    "firsts": [{label, kind, tick, t, shift}], "bounds": [(game minute, shift n, started)], "clock": [(game minute,
    iso time)]} or None without a chain. clean: the site's redaction (build.clean) for any text taken from logs; keep:
    False drops a line outright (names the site must not show); agents: the agents' ids (their chat answers).
    start (site.json's run_start): the chain begins at that run, and when it resumed from another run's save,
    game time, technologies, rockets, platforms and planets count from that save's last score."""
    runs_dir = Path(runs_dir)
    names = chain(runs_dir, start)
    if not names:
        return None
    origin = None  # the last score of the save run_start resumed from
    if start:
        p = parents(runs_dir).get(start)
        before = scores(runs_dir / p / "scores.jsonl") if p and (runs_dir / p).is_dir() else []
        origin = before[-1] if before else None
    shifts, research, spm, rockets_s, clock, bounds = [], [], [], [], [], []
    spm_packs, made, firsts, seen_first = {}, {}, [], set()
    prev = rebase(origin, origin) if origin else None
    last_row = origin  # for the made-pack deltas across shift changes
    seen_seq = set()
    agents = set(agents)
    n = 0
    # platforms, row by row: built (first row with its hub), the places it stopped at, lost (gone from the list:
    # the score read lists every platform the force has, and none when it has none)
    plats, live_plats, alive = [], {}, set()

    def first(key, label_, kind, tick, t, shift_n):
        if key in seen_first:
            return
        seen_first.add(key)
        firsts.append({"key": key, "label": label_, "kind": kind, "tick": tick, "t": t, "shift": shift_n})

    for i, name in enumerate(names):
        d = runs_dir / name
        sc = [rebase(r, origin) for r in scores(d / "scores.jsonl")]
        start_log = log_times(d / "start.log")
        n += 1 if sc else 0  # only shifts that played are numbered
        row = {"id": name, "n": n if sc else None, "moments": []}
        if not sc:
            deaths, losses = stream_events(d / "stream-service.log")
            nxt = names[i + 1] if i + 1 < len(names) else None
            row.update(started=start_log[0], ended=start_log[1], empty=True, resumed_as=nxt, deaths=deaths, losses=losses,
                       note="did not start (stopped while setting up)" if nxt else "no score log yet")
            shifts.append(row)
            continue
        a, b = sc[0], sc[-1]
        base = prev or a
        mins = (b["tick"] - a["tick"]) / 3600
        ta = parse_t(a["t"])
        deaths, losses, died, first_loss = stream_events(d / "stream-service.log", ta, detail=True)
        # packs made: the rise of every counter between consecutive rows, a fall counted as 0
        made0 = dict(made)
        for r in sc:
            if last_row is not None and r["raw"] >= last_row["raw"]:
                for k, v in r["packs"].items():
                    made[k] = made.get(k, 0) + max(0, v - last_row["packs"].get(k, 0))
            elif last_row is None:
                for k, v in r["packs"].items():
                    made[k] = made.get(k, 0) + max(0, v)
            r["made"] = dict(made)
            last_row = r
        shift_made = {k: made.get(k, 0) - made0.get(k, 0) for k in made}
        # the shift's own made total runs from its first row (what came before it belongs to the change-over)
        own = {k: b["made"].get(k, 0) - a["made"].get(k, 0) for k in b["made"]}
        try:  # the last score is under 10 minutes old: the shift is still on (the score loop writes every 2 minutes)
            running = i == len(names) - 1 and (datetime.datetime.now() - datetime.datetime.fromisoformat(b["t"])).total_seconds() < 600
        except (TypeError, ValueError):
            running = False
        built, lost = [], []
        for r in sc:
            now_names = set(r["platforms"])
            for pn in r["platforms"]:
                rec = live_plats.get(pn)
                if rec is None:
                    rec = {"name": pn, "built": r["t"], "built_tick": r["tick"], "built_shift": n, "places": [],
                           "lost": None, "lost_tick": None, "lost_shift": None, "at": None}
                    plats.append(rec)
                    live_plats[pn] = rec
                    built.append(pn)
                at = r["at"].get(pn)
                if at and at != "in transit" and at not in rec["places"]:
                    rec["places"].append(at)
                rec["at"] = at
            for pn in sorted(alive - now_names):
                rec = live_plats.pop(pn)
                rec.update(lost=r["t"], lost_tick=r["tick"], lost_shift=n)
                lost.append(pn)
            alive = now_names
        ticks = [r["raw"] for r in sc]
        stamps = [parse_t(r["t"]).timestamp() if parse_t(r["t"]) else None for r in sc]
        ok = [(x, y) for x, y in zip(ticks, stamps) if y is not None]
        tx, ty = [x for x, _ in ok], [y for _, y in ok]

        def tick_at(when):
            """A real time in this shift as a game tick (rebased), from the score rows around it."""
            raw = interp(ty, tx, when.timestamp()) if ty else None
            return None if raw is None else raw - (origin["tick"] if origin else 0)

        def time_at(raw_tick):
            v = interp(tx, ty, raw_tick) if tx else None
            return datetime.datetime.fromtimestamp(v).isoformat(timespec="seconds") if v is not None else None

        row.update(started=a["t"], ended=b["t"], running=running, tick0=a["tick"], tick1=b["tick"], game0=game_time(a["tick"]),
                   game1=game_time(b["tick"]), research=b["research"], research_new=b["research"] - base["research"],
                   researching=in_progress(b.get("current")),
                   spm=round(sum(own.values()) / mins, 1) if mins > 0 else None,
                   rockets=b["rockets"], rockets_new=b["rockets"] - base["rockets"],
                   platforms=b["platforms"], planets=b["planets"], deaths=deaths, losses=losses,
                   made=shift_made, made_total=sum(shift_made.values()), platforms_built=built, platforms_lost=lost,
                   calls=[{"t": w.isoformat(timespec="seconds"), "who": h, "text": clean(x)}
                          for w, h, x in host_calls(d / "caster.log", ta) if keep(x)],
                   died=[{"t": w.isoformat(timespec="seconds"), "tick": tick_at(w), "who": who} for w, who in died])
        new_techs = sorted(b["done"] - base["done"])
        for t in new_techs:
            if t in MILESTONES:
                row["moments"].append(f"researched {MILESTONES[t]}")
        if b["rockets"] and not base["rockets"]:
            row["moments"].append("first rocket launched")
        for p in b["platforms"]:
            if p not in base["platforms"]:
                row["moments"].append(f"platform {p} built")
        for pl in b["planets"]:
            if pl not in base["planets"] and pl != "nauvis":
                row["moments"].append(f"reached {pl.capitalize()}")
        row["moments"] += [clean(h) for h in host_moments(d / "caster.log") if keep(h)]

        # firsts, row by row (each at the first score row that shows it: up to 2 minutes after it happened)
        bounds.append((round(a["tick"] / 3600, 1), n, a["t"]))
        before_row = prev
        for r in sc:
            g = r["tick"]
            for k, lab in PACKS:
                if r["made"].get(k, 0) > 0:
                    first(f"pack:{k}", f"First {lab.lower()} science pack", "science", g, r["t"], n)
            for tech, lab in TECH_FIRSTS:
                if tech in r["done"]:
                    first(f"tech:{tech}", lab, "research", g, r["t"], n)
            for c in TECH_COUNTS:
                if r["research"] >= c:
                    first(f"techs:{c}", f"{c} technologies", "research", g, r["t"], n)
            for c in ROCKET_COUNTS:
                if r["rockets"] >= c:
                    first(f"rockets:{c}", "First rocket launched" if c == 1 else f"{c} rockets launched", "space", g, r["t"], n)
            if r["platforms"]:
                first("platform", f"First space platform ({r['platforms'][0]})", "space", g, r["t"], n)
            if before_row is not None:
                gone = [p for p in before_row["platforms"] if p not in r["platforms"]]
                if gone:
                    first("platform-lost", f"First platform lost ({gone[0]})", "space", g, r["t"], n)
            for pl in r["planets"]:
                if pl != "nauvis":
                    first(f"planet:{pl}", f"{pl.capitalize()} reached", "space", g, r["t"], n)
            if before_row is not None:
                for pname, at in r.get("at", {}).items():
                    was = before_row.get("at", {}).get(pname)
                    if was and at and was != at:
                        if at == "in transit" and was != "in transit":
                            first(f"depart:{was}", f"First platform departure from {was.capitalize()} ({pname})", "space", g, r["t"], n)
                        elif at != "in transit":
                            first(f"arrive:{at}", f"First platform arrival at {at.capitalize()} ({pname})", "space", g, r["t"], n)
            # every technology this shift finished, at the first row that shows it
            for tech in sorted(r["done"] - (before_row["done"] if before_row is not None else set())):
                row.setdefault("techs", []).append({"name": tech, "label": tech_label(tech), "tick": g, "t": r["t"]})
            before_row = r
        row.setdefault("techs", [])
        if died:
            w, who = died[0]
            tk = tick_at(w)
            if tk is not None:
                first("death", f"First agent death ({who})", "team", tk, w.isoformat(timespec="seconds"), n)
        if first_loss:
            tk = tick_at(first_loss)
            if tk is not None:
                first("loss", "First building lost to an attack", "team", tk, first_loss.isoformat(timespec="seconds"), n)

        # viewers: their lines that reached the game, the agents' answers that name them, the hosts' answers
        lo, hi = a["raw"] - 1, b["raw"] + 1800
        chat = [c for c in chat_lines(d / "chat.jsonl") if lo <= c["tick"] <= hi and c.get("seq") not in seen_seq]
        for c in chat:
            seen_seq.add(c.get("seq"))
        qa, viewers = [], {}
        for c in chat:
            who = str(c.get("from", ""))
            if not keep(c["text"]) or not keep(who):
                continue
            if c.get("viewer") or who.startswith("viewer "):
                vname = who[len("viewer "):] if who.startswith("viewer ") else who
                viewers[vname.lower()] = c["tick"]
                if any(q["kind"] == "viewer" and q["who"] == clean(vname) and q["text"] == clean(c["text"])
                       and c["tick"] - q["tick"] < 5 * 3600 for q in qa[-6:]):
                    continue  # the same line again (a resend, or the relay's retry)
                qa.append({"kind": "viewer", "who": clean(vname), "text": clean(c["text"]), "tick": c["tick"]})
        if qa:
            for c in chat:
                who = str(c.get("from", ""))
                if who not in agents or not keep(c["text"]):
                    continue
                low = c["text"].lower()
                if any(v in low and 0 <= c["tick"] - t <= 20 * 3600 for v, t in viewers.items() if len(v) >= 3):
                    qa.append({"kind": "agent", "who": who, "text": clean(c["text"]), "tick": c["tick"]})
            for w, host, text in host_replies(d / "caster.log", ta):
                raw = tick_at(w)
                if raw is not None and keep(text):
                    qa.append({"kind": "host", "who": host, "text": clean(text), "tick": raw + (origin["tick"] if origin else 0)})
            qa.sort(key=lambda q: q["tick"])
            first_v = next((q for q in qa if q["kind"] == "viewer"), None)
            if first_v:
                first("viewer", "First viewer message in the game", "team",
                      first_v["tick"] - (origin["tick"] if origin else 0), time_at(first_v["tick"]), n)
        for q in qa:
            q["game"] = game_time(q["tick"] - (origin["tick"] if origin else 0))
            q["t"] = time_at(q["tick"])
        row["qa"] = qa
        row["viewer_lines"] = sum(1 for q in qa if q["kind"] == "viewer")
        shifts.append(row)

        # chart series on the run's game clock: research and rockets at every row (thinned to one per 5 game
        # minutes), science per minute over 10-game-minute windows from the made totals, per pack and in all
        last_m = None
        for r in sc:
            m = r["tick"] / 3600
            if last_m is None or m - last_m >= 5 or r is b:
                research.append((round(m, 1), r["research"]))
                rockets_s.append((round(m, 1), r["rockets"]))
                clock.append((round(m, 1), r["t"]))
                last_m = m
        w0 = a
        for r in sc[1:]:
            dm = (r["tick"] - w0["tick"]) / 3600
            if dm >= 10:
                x = round(r["tick"] / 3600, 1)
                tot = 0
                for k in r["made"]:
                    v = max(0.0, (r["made"].get(k, 0) - w0["made"].get(k, 0)) / dm)
                    tot += v
                    spm_packs.setdefault(k, []).append((x, round(v, 1)))
                spm.append((x, round(tot, 1)))
                w0 = r
        row["series"] = {"research": [(round(r["tick"] / 3600, 1), r["research"]) for r in sc],
                         "rockets": [(round(r["tick"] / 3600, 1), r["rockets"]) for r in sc]}
        prev = b
    if all(s.get("empty") for s in shifts):
        return None  # nothing played yet (run_start's first minutes): no page until the first score
    firsts.sort(key=lambda f: f["tick"])
    # per-pack series start at 0 where a pack appears late, so every line covers the same windows
    xs = [x for x, _ in spm]
    for k, pts in spm_packs.items():
        have = dict(pts)
        spm_packs[k] = [(x, have.get(x, 0.0)) for x in xs]
    return {"shifts": shifts, "research": research, "spm": spm, "spm_packs": spm_packs, "rockets": rockets_s,
            "made": made, "firsts": firsts, "bounds": bounds, "clock": clock, "platforms": plats}
