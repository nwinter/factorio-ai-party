#!/usr/bin/env python3
"""One YouTube video per shift, built offline from the shift's folder (docs/VIDEOS.md):

  python3 tools/shift_video.py RUN [--runs-dir DIR] [--recordings LIST] [--out DIR] [--frame IMG] [--no-thumb]
  python3 tools/shift_video.py --list-cmd          # the command that makes LIST on the box

RUN is a shift folder (runs/RUN). Writes into --out (default runs/RUN/video/):
  video.json       title, description, chapters, tags, the recording segments, the box plan (tools/yt_upload.py reads it)
  description.txt  the description as YouTube gets it (chapters included)
  concat.txt       ffmpeg's list of the shift's recordings, with in/out points when a file runs past the shift
  encode.cmd       the box's batch file: re-encode to 1080p HEVC at about 1 GB an hour, at low priority
  thumb.png        1280x720 thumbnail (Playwright's headless shell, as site/og_card.py)

Recordings: OBS names each file by the box's clock, which is PST all year (UTC-8, an hour behind PDT in summer), e.g.
D:\\pog\\recordings\\2026-10-12 17-36-12.mkv for a recording started at 18:36:12 PDT. LIST is one file per line, the path
optionally followed by ",SECONDS" (ffprobe's csv). Without LIST the recording is estimated from start.log (one file from
when start-team's helpers came up to the shift's end) and video.json says "estimated": true.

Sources (all read-only): scores.jsonl (research, rockets, platforms, planets), stream-service.log (the director's deaths
and loss alerts), caster.log (the hosts' segment calls), chat.jsonl (viewers' questions and the agents' answers),
stream.json and start.log (times only). Nothing from journals, notes or the operator's lines.
"""
import argparse
import datetime
import html
import json
import os
import re
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "site"))
sys.path.insert(0, str(REPO / "tools"))
sys.path.insert(0, str(REPO / "tools" / "stream"))
import longrun  # noqa: E402
import shift_times  # noqa: E402

PACIFIC = ZoneInfo("America/Los_Angeles")
SITE_URL = "https://factorio.nickwinter.net"
SERIES = "Factorio AI Party"
TEAM = ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]
OWNERS = {"nickwinter"}  # the operator's own chat name: not a viewer moment
VIDEO_KBPS, AUDIO_KBPS = 2000, 128  # about 0.96 GB an hour
MIN_GAP = 90  # seconds between chapters (YouTube's floor is 10)
MAX_CHAPTERS = 24
BIG_FIGHT = 10  # buildings lost in one alert: a fight worth a chapter
VIEWER_MOMENTS = 3

# technologies worth a chapter: (label, weight); the title takes the heaviest
TECHS = {
    "automation": ("Automation", 50), "logistic-science-pack": ("Green science", 55), "steel-processing": ("Steel", 45),
    "gun-turret": ("Gun turrets", 45), "oil-processing": ("Oil processing", 62), "plastics": ("Plastics", 55),
    "sulfur-processing": ("Sulfur", 50), "advanced-oil-processing": ("Advanced oil processing", 58),
    "chemical-science-pack": ("Blue science", 64), "batteries": ("Batteries", 50),
    "construction-robotics": ("Construction robots", 66), "logistic-robotics": ("Logistic robots", 66),
    "military-science-pack": ("Military science", 50), "production-science-pack": ("Purple science", 64),
    "utility-science-pack": ("Yellow science", 64), "nuclear-power": ("Nuclear power", 68),
    "uranium-processing": ("Uranium processing", 60), "kovarex-enrichment-process": ("Kovarex enrichment", 66),
    "rocket-silo": ("The rocket silo", 80), "space-platform-thruster": ("Platform thrusters", 74),
    "space-science-pack": ("Space science", 78), "laser-turret": ("Laser turrets", 55), "artillery": ("Artillery", 62),
    "spidertron": ("The spidertron", 70), "metallurgic-science-pack": ("Metallurgic science", 76),
    "electromagnetic-science-pack": ("Electromagnetic science", 76),
    "agricultural-science-pack": ("Agricultural science", 76), "cryogenic-science-pack": ("Cryogenic science", 78),
    "promethium-science-pack": ("Promethium science", 80),
    "planet-discovery-vulcanus": ("Vulcanus discovered", 72), "planet-discovery-fulgora": ("Fulgora discovered", 72),
    "planet-discovery-gleba": ("Gleba discovered", 72), "planet-discovery-aquilo": ("Aquilo discovered", 72),
}

STAMP = re.compile(r"^(?:\[\w+\] )?(\d\d):(\d\d):(\d\d) ")
DIRECTOR = re.compile(r"^\[director\] (\d\d:\d\d:\d\d) .*?<- (?:attack|death|loss): (.*)$")
DIED = re.compile(r"^(.+?) died\b")
LOST = re.compile(r"^(\d+) lost near \((-?\d+), (-?\d+)\): ([^(]*?)(?: \(by ([^)]+)\))?$")
SEGMENT = re.compile(r"^\[segment\] asked for (\w+) \([^)]*\): (\{.*)$")
FILE_TIME = re.compile(r"(\d{4})-(\d\d)-(\d\d)[ _](\d\d)-(\d\d)-(\d\d)")
LISTING = re.compile(r"^(.+?\.(?:mkv|mp4|mov|flv))(?:\s*,\s*([\d.]+|N/A))?\s*$", re.I)
SANITIZE = re.compile(r"[<>]")


# ---------------------------------------------------------------- times

def local(ts):
    return datetime.datetime.fromtimestamp(ts, PACIFIC)


def stamped(path, anchor):
    """(time, text) for each line of a log that starts with HH:MM:SS (or "[tag] HH:MM:SS"), dated from anchor: the
    date moves on when the clock goes back more than 6 hours (a shift over midnight)."""
    if not path.exists():
        return []
    day, prev, out = anchor.date(), None, []
    for line in path.read_text(errors="replace").splitlines():
        m = STAMP.match(line)
        if not m:
            continue
        t = datetime.datetime.combine(day, datetime.time(*map(int, m.groups())), PACIFIC)
        if prev is None and t < anchor - datetime.timedelta(hours=12):
            day += datetime.timedelta(days=1)
            t += datetime.timedelta(days=1)
        if prev and t < prev - datetime.timedelta(hours=6):
            day += datetime.timedelta(days=1)
            t += datetime.timedelta(days=1)
        prev = t
        out.append((t, line))
    return out


def iso_local(s):
    t = datetime.datetime.fromisoformat(s)
    return t if t.tzinfo else t.replace(tzinfo=PACIFIC)


def clock(seconds):
    s = int(seconds)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def pacific(t):
    return t.strftime("%-I:%M %p").replace("AM", "a.m.").replace("PM", "p.m.")


# ---------------------------------------------------------------- the shift

def shift_window(d):
    """(start, end, running): start-team's start (stream.json shift.start, else start.log's first line) to the last
    line the hosts or the director wrote, or the last score; a shift still on ends at its planned end."""
    try:
        meta = json.loads((d / "stream.json").read_text()).get("shift") or {}
    except (OSError, ValueError):
        meta = {}
    sc = longrun.scores(d / "scores.jsonl")
    if meta.get("start"):
        anchor = local(meta["start"])
    elif sc:
        anchor = iso_local(sc[0]["t"])
    else:
        raise SystemExit(f"{d}: no stream.json shift times and no scores")
    first = stamped(d / "start.log", anchor)
    start = min([anchor] + [t for t, _ in first[:1]])
    last = [t for p in ("caster.log", "stream-service.log") for t, _ in stamped(d / p, anchor)[-1:]]
    if sc:
        last.append(iso_local(sc[-1]["t"]))
    end = max(last) if last else anchor
    running = bool(sc) and (datetime.datetime.now(PACIFIC) - iso_local(sc[-1]["t"])).total_seconds() < 600
    if running and meta.get("end"):
        end = max(end, local(meta["end"]))
    return start, end, running


def recording_start_estimate(d, start):
    """When start-team started OBS: right after its helpers came up (the first "helper ... up" line)."""
    for t, line in stamped(d / "start.log", start):
        if " helper " in line and " up" in line:
            return t
    return start


def read_listing(path, utc_offset):
    """[(path, start, seconds or None)] from the box's file list, Replay_ clips left out, oldest first."""
    tz = datetime.timezone(datetime.timedelta(hours=utc_offset))
    out = []
    for line in Path(path).read_text(errors="replace").splitlines():
        m = LISTING.match(line.strip())
        if not m:
            continue
        name = re.split(r"[\\/]", m.group(1))[-1]
        f = FILE_TIME.search(name)
        if not f or name.lower().startswith("replay"):
            continue
        t = datetime.datetime(*map(int, f.groups()), tzinfo=tz).astimezone(PACIFIC)
        dur = float(m.group(2)) if m.group(2) and m.group(2) != "N/A" else None
        out.append((m.group(1), t, dur))
    return sorted(out, key=lambda r: r[1])


def segments(files, start, end, slack=600):
    """The recordings that overlap the shift, as [{file, start, end, in, out}]: a file's end is its start plus its
    duration, else the next file's start, else the shift's end; in/out trim a file that runs past the shift by more
    than `slack` seconds (a recording left on through a break)."""
    segs = []
    for i, (path, t0, dur) in enumerate(files):
        if dur is not None:
            t1 = t0 + datetime.timedelta(seconds=dur)
        elif i + 1 < len(files):
            t1 = files[i + 1][1]
        else:
            t1 = max(end, t0)
        if (min(t1, end) - max(t0, start)).total_seconds() < 60:  # the next or last shift's file at the edges
            continue
        a = max(t0, start - datetime.timedelta(seconds=60)) if (start - t0).total_seconds() > slack else t0
        b = min(t1, end + datetime.timedelta(seconds=60)) if (t1 - end).total_seconds() > slack else t1
        segs.append({"file": path, "file_start": t0, "start": a, "end": b,
                     "in": round((a - t0).total_seconds(), 1), "out": round((b - t0).total_seconds(), 1),
                     "trim_out": b < t1, "duration_known": dur is not None})
    return segs


def offset(segs, t):
    """Seconds into the joined video for a wall-clock time; None when outside it. A time in a gap between files maps
    to the next file's first frame; one up to 2 minutes before the first file, to 0:00."""
    at = 0.0
    for i, s in enumerate(segs):
        if t < s["start"]:
            if i == 0:
                return 0.0 if (s["start"] - t).total_seconds() <= 120 else None
            return at
        if t <= s["end"]:
            return at + (t - s["start"]).total_seconds()
        at += (s["end"] - s["start"]).total_seconds()
    return None


# ---------------------------------------------------------------- what happened

def ev(t, kind, title, weight, **more):
    return dict(t=t, kind=kind, title=SANITIZE.sub("", title)[:70], weight=weight, **more)


def score_events(sc, first_shift, base_rockets):
    """Research milestones, rockets, platforms and planets, each at the middle of the 2-minute score interval where it
    first shows."""
    out = []
    rockets_seen = base_rockets
    for a, b in zip(sc, sc[1:]):
        t = iso_local(a["t"]) + (iso_local(b["t"]) - iso_local(a["t"])) / 2
        for tech in sorted(b["done"] - a["done"]):
            if tech in TECHS:
                label, w = TECHS[tech]
                title = label if label.endswith("discovered") else f"{label} researched"
                out.append(ev(t, "research", title, w, tech=tech, label=label))
        if b["rockets"] > a["rockets"]:
            n0, n1 = a["rockets"] + 1, b["rockets"]
            if n0 == 1 and rockets_seen == 0:
                title, w = "First rocket launched", 92
            else:
                title, w = (f"Rocket {n1} launched" if n0 == n1 else f"Rockets {n0} to {n1} launched"), 60
            out.append(ev(t, "rocket", title, w, first=(n0 == 1), count=n1 - n0 + 1))
            rockets_seen = b["rockets"]
        before = {p["name"]: p for p in a.get("platform_rows", [])}
        for p in b.get("platform_rows", []):
            q = before.get(p["name"])
            if p.get("hub", True) and (q is None or not q.get("hub", True)):
                out.append(ev(t, "platform", f"Space platform {p['name']} built", 90, name=p["name"]))
            if q and q.get("at") != p.get("at"):
                if q.get("at") and not p.get("at"):
                    out.append(ev(t, "depart", f"{p['name']} leaves {q['at'].capitalize()}", 88, name=p["name"]))
                elif p.get("at"):
                    out.append(ev(t, "arrive", f"{p['name']} reaches {p['at'].capitalize()}", 93, name=p["name"]))
        for pl in b["planets"]:
            if pl not in a["planets"] and pl != "nauvis":
                out.append(ev(t, "planet", f"Landing on {pl.capitalize()}", 95, planet=pl))
    return out


def platform_rows(path):
    """Each score row's platforms with their place (`at`) and hub flag (longrun.scores keeps only built names)."""
    rows = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                s = json.loads(line).get("score") or {}
            except ValueError:
                continue
            if s.get("tick") is not None:  # between planets the score says "in transit": no place
                rows.append((s["tick"], [dict(p, at=None) if p.get("at") == "in transit" else p
                                         for p in s.get("platforms") or [] if isinstance(p, dict)]))
    return dict(rows)


def fight_events(d, anchor):
    """Deaths and big fights from the director's lines: loss alerts at one place (64 tiles) within 10 minutes of each
    other are one fight, sized by the largest alert (an alert repeats with the running total)."""
    deaths, fights = [], []
    seen = set()
    for t, line in stamped(d / "stream-service.log", anchor):
        m = DIRECTOR.match(line)
        if not m:
            continue
        what = m.group(2).strip()
        key = (t.strftime("%H:%M"), what)
        if key in seen:
            continue
        seen.add(key)
        dm = DIED.match(what)
        if dm:
            name = dm.group(1).strip()
            if not any(x["name"].lower() == name.lower() and (t - x["t"]).total_seconds() < 120 for x in deaths):
                deaths.append({"t": t, "name": name[:1].upper() + name[1:], "by": None})
            continue
        lm = LOST.match(what)
        if not lm:
            continue
        n, x, y, items, by = int(lm.group(1)), int(lm.group(2)), int(lm.group(3)), lm.group(4), lm.group(5)
        if items.strip() == f"{n} character":  # a death's own alert: its cause
            for dd in deaths:
                if 0 <= (t - dd["t"]).total_seconds() < 180 and not dd["by"]:
                    dd["by"] = by
            continue
        for f in fights:
            if abs(f["x"] - x) <= 64 and abs(f["y"] - y) <= 64 and (t - f["last"]).total_seconds() <= 600:
                f["last"] = t
                if n > f["lost"]:
                    f.update(lost=n, items=items, by=by or f["by"])
                if n >= BIG_FIGHT and not f["big"]:
                    f["big"] = t
                break
        else:
            fights.append({"t": t, "last": t, "x": x, "y": y, "lost": n, "items": items, "by": by,
                           "big": t if n >= BIG_FIGHT else None})
    out, died = [], set()
    for i, dd in enumerate(deaths):  # an agent's first death is a chapter; the same agent dying again rarely is
        cause = f" ({dd['by']})" if dd["by"] else ""
        again = dd["name"] in died
        died.add(dd["name"])
        out.append(ev(dd["t"], "death", f"{dd['name']} dies{' again' if again else ''}{cause}",
                      45 if i == 0 else 22 if again else 38, name=dd["name"]))
    for f in fights:
        if f["big"]:  # the chapter starts at the alert where it got big, not at the first stray turret
            what = ", ".join(i.strip() for i in f["items"].split(",")[:2])
            out.append(ev(f["big"], "fight", f"Biters break in: {f['lost']} lost ({what})", 55 + min(30, f["lost"] // 4),
                          lost=f["lost"], near=[f["x"], f["y"]], by=f["by"]))
    return out, len(deaths), max([f["lost"] for f in fights] or [0])


def segment_events(d, anchor):
    """The hosts' segment calls: spotlights, base overviews, production and recap cards (research cards repeat the
    research chapters)."""
    weights = {"spotlight": 35, "overview": 30, "production": 30, "recap": 20}
    out = []
    for t, line in stamped(d / "caster.log", anchor):
        m = SEGMENT.match(line[9:])
        if not m or m.group(1) not in weights:
            continue
        try:
            title = json.loads(m.group(2)).get("title") or ""
        except ValueError:
            title = re.search(r'"title": "([^"]+)"', m.group(2))
            title = title.group(1) if title else ""
        if title and title != "Last 10 minutes":
            out.append(ev(t, "segment", title, weights[m.group(1)]))
    return out


def lower(label):
    """A technology's label inside a sentence ("Blue science" -> "blue science"; names of planets stay)."""
    first = label.split(" ", 1)[0]
    return label if first in ("Vulcanus", "Fulgora", "Gleba", "Aquilo", "Kovarex") else label[:1].lower() + label[1:]


def short(text, n):
    text = " ".join(text.split())
    return text if len(text) <= n else text[:n - 1].rsplit(" ", 1)[0].rstrip(",.;:") + "…"


def viewer_moments(d, tick0, names):
    """Viewers' questions an agent answered: a viewer line with a question mark, and the first agent line within three
    minutes that names the viewer. Only this shift's lines (tick from its first score on): chat.jsonl starts with
    the last shift's tail."""
    path = d / "chat.jsonl"
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if (r.get("tick") or 0) >= tick0 and r.get("logged_at"):
            rows.append(r)
    out, used = [], set()
    for i, r in enumerate(rows):
        who = r.get("from") or ""
        if not r.get("viewer") or not who.startswith("viewer "):
            continue
        viewer = who.split(" ", 1)[1]
        text = r.get("text") or ""
        if viewer.lower() in OWNERS or "?" not in text or text.strip() in used:
            continue
        t = iso_local(r["logged_at"])
        for s in rows[i + 1:]:
            st = iso_local(s["logged_at"])
            if (st - t).total_seconds() > 180:
                break
            if s.get("viewer") or s.get("from") not in names:
                continue
            if viewer.lower() in (s.get("text") or "").lower():
                used.add(text.strip())
                q = re.sub(r"^@\w+\s+", "", text.strip())
                a = re.sub(r"^@\w+[,:]?\s+", "", (s.get("text") or "").strip())
                out.append(ev(t, "viewer", f"{viewer} asks: {short(q, 44)}", 42, viewer=viewer, question=q,
                              agent=names[s["from"]], answer=a))
                break
    # the best few, in time order: a full answer about the game beats a hand-off to the operator; one per viewer first
    def score(m):
        return min(len(m["answer"]), 220) - (150 if re.search(r"\boperator\b|\bstream\b", m["answer"], re.I) else 0)
    best, seen = [], set()
    for m in sorted(out, key=score, reverse=True):
        if m["viewer"] not in seen or len(seen) >= len({x["viewer"] for x in out}):
            best.append(m)
            seen.add(m["viewer"])
    return sorted(best[:VIEWER_MOMENTS], key=lambda m: m["t"])


def pick_chapters(events, segs, start_title, total):
    """YouTube's rules: the first at 0:00, at least three, each at least 10 s long. Heaviest first, MIN_GAP apart,
    at most MAX_CHAPTERS; hour marks fill in when fewer than three. Two milestones (weight 85 or more) too close for
    two chapters share one title."""
    placed = [(0.0, start_title)]
    big = {}  # index in placed -> True for a milestone chapter
    for e in sorted(events, key=lambda e: (-e["weight"], e["t"])):
        o = offset(segs, e["t"])
        if e["weight"] < 30 or o is None or o < MIN_GAP or o > total - 30:  # under 30: description only
            continue
        near = [i for i, (p, _) in enumerate(placed) if abs(o - p) < MIN_GAP]
        if not near and len(placed) < MAX_CHAPTERS:
            big[len(placed)] = e["weight"] >= 85
            placed.append((o, e["title"]))
        elif len(near) == 1 and e["weight"] >= 85 and big.get(near[0]):
            p, t = placed[near[0]]
            if len(t) + len(e["title"]) < 90:
                second = e["title"] if e["kind"] in ("depart", "arrive") else lower(e["title"])  # starts with a name
                placed[near[0]] = (p, f"{t}; {second}")
                big[near[0]] = False  # two to a chapter at most
    h = 3600
    while len(placed) < 3 and h < total - 30:
        if all(abs(h - p) >= MIN_GAP for p, _ in placed):
            placed.append((float(h), f"Hour {h // 3600 + 1}"))
        h += 3600
    placed.sort()
    return [{"at": int(o), "time": clock(o), "title": t} for o, t in placed]


# ---------------------------------------------------------------- words

def agent_names(d):
    site = json.loads((REPO / "site" / "content" / "site.json").read_text())["agents"]
    try:
        run = json.loads((d / "stream.json").read_text()).get("agents") or {}
    except (OSError, ValueError):
        run = {}
    out = {}
    for k in run or TEAM:
        a = dict(site.get(k, {}), **run.get(k, {}))
        out[k] = {"name": a.get("name") or k.capitalize(), "model": a.get("model", ""), "harness": a.get("harness", "")}
    return out


def highlight(events, row, biggest):
    """The title's few words: the shift's biggest things, heaviest first."""
    bits = []
    kinds = {e["kind"]: e for e in sorted(events, key=lambda e: -e["weight"])}
    for k in ("planet", "arrive", "depart"):
        if k in kinds:
            bits.append(kinds[k]["title"])
    rockets = [e for e in events if e["kind"] == "rocket"]
    if rockets:
        n = sum(e["count"] for e in rockets)
        first = any(e["first"] for e in rockets)
        bits.append(("the first rocket" if n == 1 else f"the first {n} rockets") if first else
                    ("one more rocket" if n == 1 else f"{n} more rockets"))
    if "platform" in kinds:
        bits.append(f"space platform {kinds['platform']['name']}")
    techs = sorted([e for e in events if e["kind"] == "research"], key=lambda e: -e["weight"])
    if techs and len(bits) < 2:
        bits.append(lower(techs[0]["label"]))
    if biggest >= 50 and len(bits) < 2:
        bits.append(f"a {biggest}-building biter breach")
    if not bits:
        bits.append(f"{row.get('research_new', 0)} new technologies")
    text = " and ".join(bits[:2])
    return text[:1].upper() + text[1:]


def describe(n, row, start, end, events, chapters, team, deaths, biggest, moments, page_url):
    game = f"game time {row['game0']} to {row['game1']}" if row else ""
    if n == 1:
        lede = (f"Shift 1 of the {SERIES}: nine AI agents from five labs start a Factorio: Space Age world from "
                f"nothing and build one factory together, live and in real time, by the same rules as a human player.")
    else:
        lede = (f"Shift {n} of the {SERIES}: nine AI agents from five labs keep building one Factorio: Space Age "
                f"factory together, live and in real time, by the same rules as a human player. This shift picks up "
                f"the save where shift {n - 1} left it.")
    when = f"Streamed live {start.strftime('%b %-d, %Y')}, {pacific(start)} to {pacific(end)} Pacific ({game})."
    lines = [lede, "", when, "", "What happened"]
    if row:
        techs = [lower(e["label"]) for e in sorted(events, key=lambda e: -e["weight"]) if e["kind"] == "research"][:4]
        including = ", ".join(techs[:-1]) + f" and {techs[-1]}" if len(techs) > 1 else "".join(techs)
        in_all = f" ({row['research']} in all)" if row["research"] != row["research_new"] else ""
        lines.append(f"• {row['research_new']} new technologies{in_all}"
                     + (f", including {including}" if techs else ""))
        rockets = [e for e in events if e["kind"] == "rocket"]
        if rockets:
            k = sum(e["count"] for e in rockets)
            lines.append(f"• {k} rocket{'s' if k != 1 else ''} launched" + (", the first of the run" if any(e["first"] for e in rockets) else ""))
        for e in events:
            if e["kind"] in ("platform", "depart", "arrive", "planet"):
                lines.append(f"• {e['title']}")
        if row.get("spm") is not None:
            lines.append(f"• Science: {row['spm']:g} packs a minute on average")
    fights = sorted([e for e in events if e["kind"] == "fight"], key=lambda e: -e["lost"])
    line = f"• Deaths: {deaths}" if deaths else "• No deaths"
    if fights:
        line += f"; the biggest biter attack cost {fights[0]['lost']} buildings"
    lines.append(line)
    if moments:
        lines += ["", "From chat"]
        for m in moments[:3]:
            lines.append(f"• {m['viewer']} asked: \"{short(m['question'], 140)}\" {m['agent']} answered: "
                         f"\"{short(m['answer'], 200)}\"")
    lines += ["", "The team: " + ", ".join(f"{a['name']} ({a['model']}, {a['harness']})" for a in team.values()) + ".",
              "Hosts: Rook and Vale, two AI casters who call the action from the game's own feed.", "", "Chapters"]
    lines += [f"{c['time']} {c['title']}" for c in chapters]
    lines += ["", f"Charts and every shift: {page_url}", f"Live and next shift: {SITE_URL}"]
    text = SANITIZE.sub("", longrun_clean("\n".join(lines)))
    while len(text.encode()) > 4900 and moments:  # YouTube's limit is 5,000 bytes
        moments = moments[:-1]
        return describe(n, row, start, end, events, chapters, team, deaths, biggest, moments, page_url)
    return text


def longrun_clean(text):
    try:
        import build  # site/build.py's redaction (emails, paths, keys, addresses)
        return build.clean(text)
    except Exception:  # noqa: BLE001  (build.py needs site/content; the words here come from game logs only)
        return text


# ---------------------------------------------------------------- the box

def encode_plan(run, segs, total):
    out_dir = r"C:\pog\videos"
    concat = ["ffconcat version 1.0"]
    for s in segs:
        concat.append("file '" + s["file"].replace("\\", "/").replace("'", r"'\''") + "'")
        if s["in"] > 1:
            concat.append(f"inpoint {s['in']}")
        if s["trim_out"]:
            concat.append(f"outpoint {s['out']}")
    gb = total * (VIDEO_KBPS + AUDIO_KBPS) / 8 / 1e6
    ffmpeg = (f'ffmpeg -hide_banner -nostdin -y -f concat -safe 0 -i {out_dir}\\{run}.txt -map 0:v:0 -map 0:a:0? '
              f'-c:v hevc_qsv -preset slow -b:v {VIDEO_KBPS}k -maxrate {VIDEO_KBPS * 3 // 2}k -bufsize {VIDEO_KBPS * 3}k '
              f'-g 120 -tag:v hvc1 -c:a aac -b:a {AUDIO_KBPS}k -movflags +faststart {out_dir}\\{run}.mp4')
    cpu = ffmpeg.replace("-c:v hevc_qsv -preset slow", "-c:v libx265 -preset fast -x265-params pools=2")
    cmd = "\r\n".join([
        f"@echo off",
        f"rem {run}: {len(segs)} recording(s) -> {out_dir}\\{run}.mp4, {clock(total)} long, about {gb:.1f} GB",
        f"rem Run on the box when no stream is live: Quick Sync also encodes the stream. Needs ffmpeg on PATH.",
        f"rem From the Mac: scp concat.txt pogwin:C:/pog/videos/{run}.txt; scp encode.cmd pogwin:C:/pog/videos/{run}.cmd",
        f"rem then: ssh pogwin \"schtasks /create /f /tn pog-encode-{run} /sc once /st 23:59 /tr C:\\pog\\videos\\{run}.cmd"
        f" && schtasks /run /tn pog-encode-{run}\"",
        f"rem (a scheduled task outlives the SSH session; this file starts ffmpeg at low priority and logs to {run}.log)",
        f"if not exist {out_dir} mkdir {out_dir}",
        f"where ffmpeg >nul 2>&1 || (echo ffmpeg is not on PATH: winget install Gyan.FFmpeg & exit /b 1)",
        f'start "" /low /wait /b cmd /c "{ffmpeg} > {out_dir}\\{run}.log 2>&1"',
        f"rem During a live stream use the CPU instead (slower than real time on two threads):",
        f'rem start "" /low /wait /b cmd /c "{cpu} > {out_dir}\\{run}.log 2>&1"',
        f"schtasks /delete /f /tn pog-encode-{run} >nul 2>&1",
        ""])
    return "\n".join(concat) + "\n", cmd, ffmpeg, gb


# ---------------------------------------------------------------- thumbnail

def pick_frame(d, frame):
    if frame and Path(frame).exists():
        return Path(frame)
    shots = [p for p in d.glob("*/shots/*.png")]
    for words in (("rocket", "launch"), ("platform", "starling", "space"), ("silo",), ("base", "overview", "wide")):
        hits = [p for p in shots if any(w in p.name.lower() for w in words)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    bg = REPO / "site" / "og" / "bg.jpg"
    return bg if bg.exists() else None


def thumb_html(n, line, team, bg):
    import base64
    import avatar as avatar_art  # tools/stream/avatar.py
    site = json.loads((REPO / "site" / "content" / "site.json").read_text())["agents"]
    bg_css = ""
    if bg:
        mime = "image/png" if bg.suffix.lower() == ".png" else "image/jpeg"
        bg_css = f"background-image: url(data:{mime};base64,{base64.b64encode(bg.read_bytes()).decode()});"
    faces = "".join(
        f'<div class="face" style="border-color:{html.escape(site.get(k, {}).get("color") or "#888")}">'
        f'{avatar_art.svg({"name": k, "display_name": a["name"], "color": site.get(k, {}).get("color"), "avatar": site.get(k, {}).get("avatar")}, 76)}</div>'
        for k, a in team.items())
    return f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Titillium+Web:wght@600;700&display=swap">
<style>
html, body {{ margin: 0; width: 1280px; height: 720px; overflow: hidden; background: #141414; }}
.card {{ position: relative; width: 1280px; height: 720px; {bg_css} background-size: cover; background-position: center;
  font-family: 'Titillium Web', 'Segoe UI', sans-serif; color: #f2efe8; }}
.card::before {{ content: ""; position: absolute; inset: 0;
  background: linear-gradient(100deg, rgba(14,15,18,.95) 0%, rgba(14,15,18,.82) 45%, rgba(14,15,18,.25) 100%); }}
.inner {{ position: absolute; inset: 0; padding: 56px 64px; display: flex; flex-direction: column; }}
.series {{ font-weight: 700; letter-spacing: .12em; font-size: 30px; color: #ffb43a; text-transform: uppercase; }}
h1 {{ margin: 6px 0 0; font-size: 168px; line-height: .95; font-weight: 700; color: #fff; text-shadow: 0 4px 0 #000; }}
p {{ margin: 18px 0 0; font-size: 54px; line-height: 1.1; font-weight: 700; max-width: 1000px; color: #ffd27a;
  text-shadow: 0 3px 0 #000; }}
.team {{ margin-top: auto; display: flex; gap: 12px; }}
.face {{ width: 84px; height: 84px; border: 3px solid; border-radius: 10px; background: #0e1322; display: flex;
  align-items: center; justify-content: center; overflow: hidden; }}
.face svg {{ width: 76px; height: 76px; display: block; }}
</style></head><body><div class="card"><div class="inner">
<div class="series">{html.escape(SERIES)}</div>
<h1>Shift {n}</h1>
<p>{html.escape(line)}</p>
<div class="team">{faces}</div>
</div></div></body></html>"""


def thumb_pillow(n, line, team, bg, out):
    """The same card without a browser (Pillow): initials in each agent's colour stand in for the pixel portraits."""
    from PIL import Image, ImageDraw, ImageFont
    site = json.loads((REPO / "site" / "content" / "site.json").read_text())["agents"]
    W, H = 1280, 720
    img = Image.new("RGB", (W, H), (20, 20, 20))
    if bg:
        b = Image.open(bg).convert("RGB")
        scale = max(W / b.width, H / b.height)
        b = b.resize((round(b.width * scale), round(b.height * scale)))
        img.paste(b, ((W - b.width) // 2, (H - b.height) // 2))
    shade = Image.new("L", (W, 1))
    for x in range(W):  # dark on the left (the words), the frame shows through on the right
        k = x / W
        shade.putpixel((x, 0), round(255 * (0.95 - 0.13 * k / 0.45 if k < 0.45 else 0.82 - 0.57 * (k - 0.45) / 0.55)))
    img = Image.composite(Image.new("RGB", (W, H), (14, 15, 18)), img, shade.resize((W, H)))
    d = ImageDraw.Draw(img)

    def font(size):
        for f in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf",
                  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
            if os.path.exists(f):
                return ImageFont.truetype(f, size)
        return ImageFont.load_default(size)
    d.text((64, 56), SERIES.upper(), font=font(30), fill=(255, 180, 58))
    d.text((60, 96), f"Shift {n}", font=font(160), fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    words, rows, f54 = line.split(), [""], font(54)
    for w in words:  # wrap at 1000 px, two lines at most
        trial = (rows[-1] + " " + w).strip()
        if d.textlength(trial, font=f54) > 1000 and rows[-1]:
            rows.append(w)
        else:
            rows[-1] = trial
    for i, r in enumerate(rows[:2]):
        d.text((64, 300 + i * 62), r, font=f54, fill=(255, 210, 122), stroke_width=2, stroke_fill=(0, 0, 0))
    f26 = font(28)
    for i, k in enumerate(team):
        x, y = 64 + i * 96, 580
        color = site.get(k, {}).get("color") or "#888888"
        rgb = tuple(int(color.lstrip("#")[j:j + 2], 16) for j in (0, 2, 4)) if len(color) == 7 else (136, 136, 136)
        if sum(rgb) < 200:  # a near-black colour (Grok's) would vanish on the dark tile
            rgb = (200, 200, 200)
        d.rounded_rectangle((x, y, x + 84, y + 84), radius=10, fill=(14, 19, 34), outline=rgb, width=3)
        d.text((x + 42, y + 42), team[k]["name"][:2], font=f26, fill=rgb, anchor="mm")
    img.save(out)


def render(page, out, w=1280, h=720):
    import glob
    import subprocess
    import tempfile
    shells = sorted(glob.glob(os.path.expanduser(
        "~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")))
    if not shells:
        return "no Playwright headless shell (npx playwright install chromium-headless-shell)"
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "thumb.html"
        src.write_text(page)
        try:
            subprocess.run([shells[-1], "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                            f"--window-size={w},{h}", "--timeout=6000", f"--screenshot={Path(out).resolve()}",
                            src.as_uri()], check=True, capture_output=True, timeout=90)
        except (OSError, subprocess.SubprocessError) as e:
            return f"the headless shell failed ({type(e).__name__}: {str(e)[-80:]})"
    return None


# ---------------------------------------------------------------- main

def build(run, runs_dir, listing=None, utc_offset=-8, frame=None):
    d = Path(runs_dir) / run
    if not d.is_dir():
        raise SystemExit(f"no shift folder {d}")
    n = shift_times.shift_number(str(d))
    start, end, running = shift_window(d)
    if listing:
        files = read_listing(listing, utc_offset)
        segs = segments(files, start, end)
        estimated = False
        if not segs:
            raise SystemExit(f"no recording in {listing} overlaps {start:%Y-%m-%d %H:%M} to {end:%H:%M} Pacific")
    else:
        rs = recording_start_estimate(d, start)
        box = rs.astimezone(datetime.timezone(datetime.timedelta(hours=utc_offset)))
        name = f"D:\\pog\\recordings\\{box:%Y-%m-%d %H-%M-%S}.mkv"
        segs = segments([(name, rs, None)], start, end)
        estimated = True
    total = sum((s["end"] - s["start"]).total_seconds() for s in segs)

    run_start = json.loads((REPO / "site" / "content" / "site.json").read_text()).get("run_start")
    lr = longrun.load(Path(runs_dir), start=run_start if run_start and (Path(runs_dir) / run_start).is_dir() else None)
    row = next((s for s in (lr or {}).get("shifts", []) if s["id"] == run), None)
    sc = longrun.scores(d / "scores.jsonl")
    plat = platform_rows(d / "scores.jsonl")
    for r in sc:
        r["platform_rows"] = plat.get(r["tick"], [])
    prev_rockets = row["rockets"] - row["rockets_new"] if row else 0
    team = agent_names(d)
    names = {k: a["name"] for k, a in team.items()}
    events = score_events(sc, n == 1, prev_rockets)
    fights, deaths, biggest = fight_events(d, start)
    events += fights
    events += segment_events(d, start)
    moments = viewer_moments(d, sc[0]["tick"] if sc else 0, names)
    events += moments
    events.sort(key=lambda e: e["t"])

    first = "Nine AIs, one empty map" if n == 1 else f"Shift {n} picks up at game time {row['game0']}" if row else f"Shift {n} begins"
    chapters = pick_chapters(events, segs, first, total)
    line = highlight(events, row or {}, biggest)
    title = f"{SERIES} · Shift {n}: {line}"
    if len(title) > 100:
        title = title[:99].rsplit(" ", 1)[0] + "…"
    page_url = f"{SITE_URL}/runs/long/shift-{n}/"
    description = describe(n, row, segs[0]["start"], segs[-1]["end"], events, chapters, team, deaths, biggest,
                           moments, page_url)
    concat, cmd, ffmpeg, gb = encode_plan(run, segs, total)
    best = max(events, key=lambda e: e["weight"], default=None)
    frame_at = offset(segs, best["t"]) if best else None
    return {
        "run": run, "shift": n, "running": running, "estimated": estimated,
        "window": [start.isoformat(), end.isoformat()],
        "title": SANITIZE.sub("", title), "highlight": line, "description": description, "chapters": chapters,
        "tags": ["Factorio", "Factorio Space Age", "AI agents", "AI plays Factorio", "LLM", "Claude", "GPT", "Gemini",
                 "Grok", "multi-agent"],
        "category_id": "20", "page_url": page_url,
        "segments": [{"file": s["file"], "file_start": s["file_start"].isoformat(), "in": s["in"], "out": s["out"],
                      "duration_known": s["duration_known"]} for s in segs],
        "duration": round(total), "size_gb": round(gb, 2),
        "box": {"concat": concat, "encode_cmd": cmd, "ffmpeg": ffmpeg, "output": f"C:\\pog\\videos\\{run}.mp4",
                "frame": (f"ffmpeg -hide_banner -ss {int(frame_at or 0)} -i C:\\pog\\videos\\{run}.mp4 -frames:v 1 "
                          f"-q:v 2 C:\\pog\\videos\\{run}-frame.jpg") if frame_at is not None else None},
        "events": [{"time": clock(offset(segs, e["t"]) or 0), "at": e["t"].strftime("%H:%M:%S"), "kind": e["kind"],
                    "title": e["title"]} for e in events],
        "_team": team, "_frame": frame,
    }


def write(v, out, thumb=True):
    out.mkdir(parents=True, exist_ok=True)
    (out / "description.txt").write_text(v["description"] + "\n")
    (out / "concat.txt").write_text(v["box"]["concat"])
    (out / "encode.cmd").write_text(v["box"]["encode_cmd"])
    note = None
    if thumb:
        bg = pick_frame(Path(v["_runs_dir"]) / v["run"], v["_frame"])
        page = thumb_html(v["shift"], v["highlight"], v["_team"], bg)
        (out / "thumb.html").write_text(page)  # to render again by hand (a browser at 1280x720)
        note = render(page, out / "thumb.png")
        if note:  # no browser here (or it cannot start): Pillow's plainer card
            try:
                thumb_pillow(v["shift"], v["highlight"], v["_team"], bg, out / "thumb.png")
                note = f"{note}; drew the plain card with Pillow"
                v["thumbnail_plain"] = True
            except Exception as e:  # noqa: BLE001
                note = f"{note}; Pillow too: {type(e).__name__}: {e}"
        v["thumbnail"] = str(out / "thumb.png") if (out / "thumb.png").exists() else None
        v["thumbnail_background"] = bg.name if bg else None
    data = {k: x for k, x in v.items() if not k.startswith("_")}
    (out / "video.json").write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    return note


LIST_CMD = ('ssh pogwin "for %f in (D:\\pog\\recordings\\20*.mkv C:\\pog\\recordings\\20*.mkv) do '
            '@ffprobe -v error -show_entries format=filename,duration -of csv=p=0 \\"%f\\"" > recordings.txt\n'
            '# without ffprobe on the box (each file then ends where the next starts):\n'
            'ssh pogwin "dir /b /s D:\\pog\\recordings\\20*.mkv C:\\pog\\recordings\\20*.mkv" > recordings.txt')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", nargs="?")
    ap.add_argument("--runs-dir", default=os.environ.get("POG_SITE_RUNS") or str(
        REPO / "runs" if (REPO / "runs").is_dir() else Path.home() / "code" / "player-of-games" / "runs"))
    ap.add_argument("--recordings", help="the box's recording list (--list-cmd prints how to make it)")
    ap.add_argument("--box-utc-offset", type=float, default=-8, help="the box clock's UTC offset (PST all year: -8)")
    ap.add_argument("--out", help="default runs/RUN/video")
    ap.add_argument("--frame", help="a frame from the recording for the thumbnail (video.json's box.frame makes one)")
    ap.add_argument("--no-thumb", action="store_true")
    ap.add_argument("--list-cmd", action="store_true")
    a = ap.parse_args()
    if a.list_cmd:
        print(LIST_CMD)
        return
    if not a.run:
        ap.error("RUN is required")
    v = build(a.run, a.runs_dir, a.recordings, a.box_utc_offset, a.frame)
    v["_runs_dir"] = a.runs_dir
    out = Path(a.out) if a.out else Path(a.runs_dir) / a.run / "video"
    note = write(v, out, thumb=not a.no_thumb)
    print(f"{v['run']}: {v['title']}")
    print(f"  {clock(v['duration'])} from {len(v['segments'])} recording(s){' (estimated: no --recordings)' if v['estimated'] else ''}"
          f"{', shift still on' if v['running'] else ''}; {len(v['chapters'])} chapters; about {v['size_gb']} GB re-encoded")
    print(f"  wrote {out}/: video.json description.txt concat.txt encode.cmd"
          + (" thumb.html" if not a.no_thumb else "") + (" thumb.png" if v.get("thumbnail") else ""))
    if note:
        print(f"  thumbnail: {note}")


if __name__ == "__main__":
    main()
