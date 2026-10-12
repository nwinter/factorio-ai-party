"""The long run: one world played over many shifts (runs/RUN/resumed-from chains them), for site/build.py.

Read-only, from each shift's folder: scores.jsonl (game time, research, science made, rockets, platforms, planets),
start.log (only its timestamps: the rest names accounts and quotas), stream-service.log (the director's lines: deaths
and losses it cut to) and caster.log (the hosts' Space Age lines). No journals, no chat.
"""
import datetime
import json
import os
import re
from pathlib import Path

SCIENCE = re.compile(r"-science-pack$")
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
DEATH = re.compile(r"<- attack: (.+?) died\b")
LOSS = re.compile(r"<- attack: (\d+) lost near")
HOST = re.compile(r"^(\d\d:\d\d:\d\d) \[\w+\] \(space[^,]*, [^)]*\) (.*)$")


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
        rows.append({"tick": s["tick"], "t": row.get("t"), "research": len(done if isinstance(done, list) else list(done)),
                     "done": set(done if isinstance(done, list) else done),
                     "science": sum(v for k, v in (s.get("produced") or {}).items() if SCIENCE.search(k)),
                     "rockets": s.get("rockets") or 0,
                     "platforms": [p.get("name") for p in s.get("platforms") or [] if isinstance(p, dict) and p.get("hub", True)],
                     "planets": list(s.get("planets") or [])})
    rows.sort(key=lambda r: r["tick"])
    return rows


def log_times(path):
    """First and last HH:MM:SS of a log, with the file's date (start.log has no dates)."""
    if not path.exists():
        return None, None
    times = re.findall(r"^(\d\d:\d\d):\d\d ", path.read_text(errors="replace"), re.M)
    day = datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    return (f"{day}T{times[0]}", f"{day}T{times[-1]}") if times else (None, None)


def stream_events(path):
    """Deaths and loss alerts the director cut to, from stream-service.log: each death once; each loss alert once (a
    loss stays in the game's alerts for minutes and comes back as a new alert, so its building counts would add up the
    same buildings several times: the number of alerts is the honest count)."""
    if not path.exists():
        return 0, 0
    deaths, losses = set(), 0
    for line in path.read_text(errors="replace").splitlines():
        if "<- attack:" not in line:
            continue
        m = DEATH.search(line)
        if m:
            deaths.add((line[11:16], m.group(1)))
        if LOSS.search(line):
            losses += 1
    return len(deaths), losses


def host_moments(path, limit=2):
    if not path.exists():
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = HOST.match(line)
        if m:
            out.append(m.group(2))
    return out[:limit]


def label(name):
    return name.replace("-", " ")


def rebase(r, origin):
    """A score row counted from origin (the save the first shift resumed from): game time, technologies, rockets,
    platforms and planets other than Nauvis that the save already had are left out."""
    if not origin:
        return r
    return dict(r, tick=r["tick"] - origin["tick"], done=r["done"] - origin["done"],
                research=len(r["done"] - origin["done"]), rockets=max(0, r["rockets"] - origin["rockets"]),
                platforms=[p for p in r["platforms"] if p not in origin["platforms"]],
                planets=[p for p in r["planets"] if p == "nauvis" or p not in origin["planets"]])


def load(runs_dir, clean=lambda s: s, start=None):
    """{"shifts": [row per shift], "research": [(game minute, technologies)], "spm": [(game minute, packs/min)]}
    or None without a chain. clean: the site's redaction (build.clean) for any text taken from logs.
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
    shifts, research, spm = [], [], []
    prev = rebase(origin, origin) if origin else None
    n = 0
    for i, name in enumerate(names):
        d = runs_dir / name
        sc = [rebase(r, origin) for r in scores(d / "scores.jsonl")]
        start_log = log_times(d / "start.log")
        deaths, losses = stream_events(d / "stream-service.log")
        n += 1 if sc else 0  # only shifts that played are numbered
        row = {"id": name, "n": n if sc else None, "deaths": deaths, "losses": losses, "moments": []}
        if not sc:
            nxt = names[i + 1] if i + 1 < len(names) else None
            row.update(started=start_log[0], ended=start_log[1], empty=True, resumed_as=nxt,
                       note="did not start (stopped while setting up)" if nxt else "no score log yet")
            shifts.append(row)
            continue
        a, b = sc[0], sc[-1]
        base = prev or a
        mins = (b["tick"] - a["tick"]) / 3600
        try:  # the last score is under 10 minutes old: the shift is still on (the score loop writes every 2 minutes)
            running = i == len(names) - 1 and (datetime.datetime.now() - datetime.datetime.fromisoformat(b["t"])).total_seconds() < 600
        except (TypeError, ValueError):
            running = False
        row.update(started=a["t"], ended=b["t"], running=running, tick0=a["tick"], tick1=b["tick"], game0=game_time(a["tick"]),
                   game1=game_time(b["tick"]), research=b["research"], research_new=b["research"] - base["research"],
                   spm=round((b["science"] - a["science"]) / mins, 1) if mins > 0 else None,
                   rockets=b["rockets"], rockets_new=b["rockets"] - base["rockets"],
                   platforms=b["platforms"], planets=b["planets"])
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
        row["moments"] += [clean(h) for h in host_moments(d / "caster.log")]
        shifts.append(row)
        # chart series: research at every snapshot (thinned to one per 5 game minutes), science per minute over
        # 10-game-minute windows, both on the run's game clock
        last_m = None
        for r in sc:
            m = r["tick"] / 3600
            if last_m is None or m - last_m >= 5 or r is b:
                research.append((round(m, 1), r["research"]))
                last_m = m
        w0 = a
        for r in sc[1:]:
            dm = (r["tick"] - w0["tick"]) / 3600
            if dm >= 10:
                spm.append((round(r["tick"] / 3600, 1), round((r["science"] - w0["science"]) / dm, 1)))
                w0 = r
        prev = b
    if all(s.get("empty") for s in shifts):
        return None  # nothing played yet (run_start's first minutes): no page until the first score
    return {"shifts": shifts, "research": research, "spm": spm}
