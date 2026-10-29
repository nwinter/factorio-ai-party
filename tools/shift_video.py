#!/usr/bin/env python3
"""One YouTube video per shift, built offline from the shift's folder (docs/VIDEOS.md):

  python3 tools/shift_video.py RUN [--runs-dir DIR] [--recordings LIST] [--out DIR] [--frame IMG] [--no-thumb]
  python3 tools/shift_video.py --list-cmd          # the command that makes LIST on the box
  python3 tools/shift_video.py --titles 85-99 [--write]  # (d29 batch338) each shift's title by today's rules, old -> new,
                                                   # in order (each the next one's previous); --write puts them in
                                                   # runs/shiftN/video/video.json (title, highlight), nothing else

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

Sources (all read-only): scores.jsonl (research, rockets, platforms, planets; from d29 batch338 each platform's km
along the connection it flies, the earlier shifts' too for the farthest-yet records), chronicle.jsonl (platforms built, lost
or deleted, each arrival and departure, the agents' chronicle entries; the earlier shifts' for what the run did before),
stream-service.log (the director's deaths and loss alerts), caster.log (the hosts' segment calls), chat.jsonl (viewers'
questions and the agents' answers), stream.json and start.log (times only). Nothing from journals, notes or the
operator's lines.
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
# the host's chat account under any label ("NickWinter (host)" in shift29): the host is not a viewer, so not a viewer
# moment; a viewer's line or an agent's answer that names the host is (Nick d27 10:10: his name may appear)
OWNER_NAME = re.compile(r"(?i)\bnick(?:\s*winter)?\b")
VIDEO_KBPS, AUDIO_KBPS = 2000, 128  # about 0.96 GB an hour
MIN_GAP = 90  # seconds between chapters (YouTube's floor is 10)
MAX_CHAPTERS = 24
GAP_FILL = 2700  # seconds with no chapter before a lesser moment or an hour mark fills in
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


def research_weight(tech):
    """(label, weight): a milestone's own; any other technology 36 when new, 26 for a repeating one's next level."""
    if tech in TECHS:
        return TECHS[tech]
    level = re.search(r"-(\d+)$", tech)
    return longrun.tech_label(tech), 36 if not level or level.group(1) == "1" else 26


def score_events(sc, first_shift, base_rockets, platforms=True, research=True):
    """Research milestones, rockets, platforms and planets, each at the middle of the 2-minute score interval where it
    first shows. platforms=False, research=False: the chronicle tells those (chronicle_events; a repeating technology
    keeps its name from level to level, so only the chronicle sees its next level)."""
    out = []
    rockets_seen = base_rockets
    for a, b in zip(sc, sc[1:]):
        t = iso_local(a["t"]) + (iso_local(b["t"]) - iso_local(a["t"])) / 2
        for tech in sorted(b["done"] - a["done"]) if research else []:
            label, w = research_weight(tech)
            title = label if label.endswith("discovered") else f"{label} researched"
            out.append(ev(t, "research", title, w, tech=tech, label=label))
        if b["rockets"] > a["rockets"]:
            n0, n1 = a["rockets"] + 1, b["rockets"]
            if n0 == 1 and rockets_seen == 0:
                title, w = "First rocket launched", 92
            elif n1 // 1000 > (n0 - 1) // 1000:  # a thousandth rocket: a chapter; the rest are routine
                title, w = f"Rocket {n1 // 1000 * 1000:,} launched", 50
            else:
                title, w = (f"Rocket {n1} launched" if n0 == n1 else f"Rockets {n0} to {n1} launched"), 8
            out.append(ev(t, "rocket", title, w, first=(n0 == 1), count=n1 - n0 + 1))
            rockets_seen = b["rockets"]
        before = {p["name"]: p for p in a.get("platform_rows", [])}
        for p in (b.get("platform_rows", []) if platforms else []):
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


FAR = {"solar-system-edge": "the solar system edge", "shattered-planet": "the Shattered Planet"}


def place(p):
    return FAR.get(p) or (p or "?").replace("-", " ").capitalize()


def chronicle_rows(path, kinds=None):
    """chronicle.jsonl's rows (events with a kind, the agents' entries), each with its t."""
    out = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if kinds and not any(f'"{k}"' in line for k in kinds):
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and isinstance(r.get("t"), (int, float)):
                out.append(r)
    return out


def far_reach(p):
    """A score row's platform in flight on a connection with a far end (tools/pog.py score's route, km and len, since
    d29 batch338): (far end, other end, km from the other end, the connection's km), else None."""
    route, km, length = p.get("route"), p.get("km"), p.get("len")
    if not isinstance(route, str) or "->" not in route or not isinstance(km, (int, float)) or not isinstance(length, (int, float)):
        return None
    a, b = route.split("->", 1)
    return (b, a, km, length) if b in FAR else (a, b, length - km, length) if a in FAR else None


def reach_rows(path):
    """[(score row time, platform, far end, other end, km toward the far end, connection km)] from a scores.jsonl."""
    out = []
    if path.exists():
        for line in path.read_text().splitlines():
            if '"km"' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            for p in (r.get("score") or {}).get("platforms") or []:
                f = far_reach(p) if isinstance(p, dict) else None
                if f and r.get("t"):
                    out.append((iso_local(r["t"]), p.get("name") or "?") + f)
    return out


def run_history(d):
    """What the run did before shift d, from its world's earlier shifts' chronicles (the resumed-from chain): the places a
    platform reached, each platform's (platform, place) visits (arrived, left or built there), the far destinations (the
    edge, the Shattered Planet) set out for, each platform's (platform, far place) departures (far_by), and from their
    score logs the farthest any platform got toward each far place on each connection (best: {(far, other): (km,
    platform)}; score logs before d29 batch338 have no distance)."""
    h = {"places": {"nauvis"}, "visits": set(), "far_left": set(), "far_by": set(), "best": {}, "told": False}
    for run in shift_times.earlier_runs(str(d)):
        for _, name, far, other, km, _ in reach_rows(d.parent / run / "scores.jsonl"):
            if km > h["best"].get((far, other), (-1, None))[0]:
                h["best"][(far, other)] = (km, name)
        rows = chronicle_rows(d.parent / run / "chronicle.jsonl", ("platform_arrived", "platform_left", "platform_created"))
        h["told"] = h["told"] or bool(rows)
        for r in rows:
            if r.get("kind") == "platform_arrived" and r.get("at"):
                h["places"].add(r["at"])
                h["visits"].add((r.get("platform"), r["at"]))
            elif r.get("kind") == "platform_created" and r.get("at"):
                h["visits"].add((r.get("platform"), r["at"]))
            elif r.get("kind") == "platform_left":  # it was there: a visit
                if r.get("at"):
                    h["visits"].add((r.get("platform"), r["at"]))
                if r.get("to") in FAR:
                    h["far_left"].add(r["to"])
                    h["far_by"].add((r.get("platform"), r["to"]))
    return h


def chronicle_events(rows, start, end, history, planets=()):
    """The shift's platform story from chronicle.jsonl, weighed against what the run did before (history; planets: the
    planets the shift's first score already lists, reached before the chronicle began):
    - the first arrival at the solar system edge (the Space Age victory) or the Shattered Planet; the first platform to
      reach a planet; a departure for a far place the run never set out for before;
    - platforms built or lost; a platform's first departure for a far place and its first arrival there (the first of
      the shift when no earlier chronicle says); a platform's first visit to a place; the agents' chronicle entries;
      platforms deleted;
    - every other arrival and departure is a routine trip (weight under 10: summed by route in the description). (d29
      batch338 VT, Nick: shifts 91-94 were all "Resolute leaves the solar system edge for the Shattered Planet", a
      trial it flies and turns back from every shift) A far departure or arrival the platform made in an earlier
      shift is routine too: what is new in such a shift is a farthest-yet distance (reach_events) or its arrival."""
    places, visits, far_left = set(history["places"]) | set(planets), set(history["visits"]), set(history["far_left"])
    # (a platform's first visit needs an earlier shift's chronicle: before the chronicle began nothing says where it went)
    out, again = [], set()
    for r in sorted(rows, key=lambda r: r["t"]):
        t = local(r["t"])
        if not start <= t <= end:
            continue
        kind, name = r.get("kind"), r.get("platform") or "?"
        if kind == "platform_arrived" and r.get("at"):
            at = r["at"]
            if at not in places:
                title, w = ((f"{name} reaches the solar system edge: the Space Age victory", 100) if at == "solar-system-edge"
                            else (f"{name} reaches {place(at)}, the first platform there", 99 if at in FAR else 96))
                out.append(ev(t, "first", title, w, name=name, at=at))
            elif at in FAR and history.get("told", True) and (name, at) not in visits:
                out.append(ev(t, "far", f"{name} reaches {place(at)} for the first time", 64, name=name, at=at))
            elif at in FAR and not history.get("told", True) and (name, "at", at) not in again:
                again.add((name, "at", at))  # no earlier chronicle: what it did before is not known
                out.append(ev(t, "far", f"{name} reaches {place(at)} again", 64, name=name, at=at))
            elif (name, at) not in visits and history.get("told", True):  # no earlier chronicle: no visit known
                out.append(ev(t, "visit", f"{name} reaches {place(at)} for the first time", 48, name=name, at=at))
            else:
                out.append(ev(t, "trip_end", f"{name} reaches {place(at)}", 4, name=name, at=at))
            places.add(at)
            visits.add((name, at))
        elif kind == "platform_left":
            frm, to = r.get("at"), r.get("to")
            title = f"{name} leaves {place(frm)} for {place(to)}" if to else f"{name} leaves {place(frm)}"
            if to in FAR and to not in far_left:
                out.append(ev(t, "far", title + ", the first time", 90, name=name, at=frm, to=to))
            elif to in FAR and (name, to) not in history.get("far_by", ()) and (name, "for", to) not in again:
                again.add((name, "for", to))
                out.append(ev(t, "far", title, 66 if to == "shattered-planet" else 60, name=name, at=frm, to=to))
            else:
                out.append(ev(t, "trip", title, 6, name=name, at=frm, to=to))
            if to in FAR:
                far_left.add(to)
            if frm:  # it was there
                visits.add((name, frm))
        elif kind == "research" and r.get("name"):
            label, w = research_weight(r["name"])
            out.append(ev(t, "research", label if label.endswith("discovered") else f"{label} researched", w,
                          tech=r["name"], label=label))
        elif kind == "platform_created":
            out.append(ev(t, "platform", f"Space platform {name} built", 90, name=name))
            if r.get("at"):  # built in orbit there: its next arrival there is no first visit
                visits.add((name, r["at"]))
        elif kind == "platform_lost":
            where = (f" ({place(r['from'])} to {place(r['to'])})" if r.get("from") and r.get("to")
                     else f" (at {place(r.get('at'))})" if r.get("at") else "")
            out.append(ev(t, "lost", f"Platform {name} lost{where}", 91, name=name))
        elif kind == "platform_deleted":
            out.append(ev(t, "deleted", f"Platform {name} taken down", 34, name=name))
        elif r.get("type") == "entry" and r.get("title"):
            who = (r.get("agent") or "").capitalize()
            out.append(ev(t, "note", f"{who}: {r['title']}" if who else r["title"], 33, agent=r.get("agent")))
    return out


def reach_events(rows, start, end, best):
    """(d29 batch338 VT) The farthest a platform got toward a far place in the shift (rows: reach_rows, every 2 minutes),
    on each connection: "38,000 km toward the Shattered Planet", a farthest-yet record (weight 66 toward the
    Shattered Planet, else 60) when, rounded to 1,000 km, it beats the run's record before the shift (best: run_history's)
    and that record exists (else a lesser moment, 24); none once it got there (the arrival tells it)."""
    top = {}
    for t, name, far, other, km, length in rows:
        if start <= t <= end and km < length - 1 and km > top.get((far, other), (None, None, -1))[2]:
            top[(far, other)] = (t, name, km)
    out = []
    for (far, other), (t, name, km) in sorted(top.items(), key=lambda r: r[1][0]):
        km_text = f"{int(round(km, -3)) or int(round(km)):,} km toward {place(far)}"
        rec = best.get((far, other))
        if rec and round(km, -3) > round(rec[0], -3):
            # "Resolute: 38,000 km toward the Shattered Planet, its farthest yet" (a title's words stop at 70)
            out.append(ev(t, "far", f"{name}: {km_text}, {'its' if rec[1] == name else 'the'} farthest yet",
                          66 if far == "shattered-planet" else 60, name=name, to=far, km=round(km)))
        else:
            out.append(ev(t, "reach", f"{name} reaches {km_text}", 24, name=name, to=far, km=round(km)))
    return out


def trip_routes(events):
    """Routine trips (departures) by route: [(count, "Nauvis and Gleba", [platforms])], most first."""
    by = {}
    for e in events:
        if e["kind"] == "trip" and e.get("to"):
            key = tuple(sorted([e["at"] or "?", e["to"]]))
            c = by.setdefault(key, [0, []])
            c[0] += 1
            if e["name"] not in c[1]:
                c[1].append(e["name"])
    return sorted([(c[0], f"{place(a)} and {place(b)}", c[1]) for (a, b), c in by.items()], key=lambda r: (-r[0], r[1]))


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


def viewer_moments(d, tick0, names, hide=None):
    """Viewers' questions an agent answered: a viewer line with a question mark, and the first agent line within three
    minutes that names the viewer. Only this shift's lines (tick from its first score on): chat.jsonl starts with
    the last shift's tail. hide(viewer, text): True leaves a line out (site/moderation.py: deleted on YouTube)."""
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
        if viewer.lower() in OWNERS or OWNER_NAME.search(viewer) or "?" not in text or text.strip() in used or (hide and hide(viewer, text)):
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
    """YouTube's rules: the first at 0:00, at least three, each at least 10 s long; MIN_GAP apart, at most
    MAX_CHAPTERS. The milestones (weight 85 or more) first, heaviest first; two too close for two chapters share one
    title. Then the big ones (60 or more) by weight. Then the rest (30 or more), spread over the whole recording: each
    pick is the heaviest after its
    weight is scaled down by how near it is to a chapter already placed (full weight from total / MAX_CHAPTERS away).
    Hour marks fill in when fewer than three."""
    placed = [(0.0, start_title)]
    big = {}  # index in placed -> True for a milestone chapter
    rest = []
    for e in sorted(events, key=lambda e: (-e["weight"], e["t"])):
        o = offset(segs, e["t"])
        if e["weight"] < 30 or o is None or o < MIN_GAP or o > total - 30:  # under 30: description only
            continue
        if e["weight"] < 60:
            rest.append((o, e))
            continue
        if e["weight"] < 85:  # big, not a milestone: by weight, never sharing
            if len(placed) < MAX_CHAPTERS and all(abs(o - p) >= MIN_GAP for p, _ in placed):
                placed.append((o, e["title"]))
            continue
        near = [i for i, (p, _) in enumerate(placed) if abs(o - p) < MIN_GAP]
        if not near and len(placed) < MAX_CHAPTERS:
            big[len(placed)] = True
            placed.append((o, e["title"]))
        elif len(near) == 1 and big.get(near[0]):
            p, t = placed[near[0]]
            if len(t) + len(e["title"]) < 90:
                second = e["title"] if e["kind"] in ("depart", "arrive", "first", "far") else lower(e["title"])  # starts with a name
                placed[near[0]] = (p, f"{t}; {second}")
                big[near[0]] = False  # two to a chapter at most
    spacing = max(MIN_GAP, total / MAX_CHAPTERS)
    while rest and len(placed) < MAX_CHAPTERS:
        best, best_score = None, 0.0
        for i, (o, e) in enumerate(rest):
            gap = min(abs(o - p) for p, _ in placed)
            if gap < MIN_GAP:
                continue
            sc = e["weight"] * min(1.0, gap / spacing)
            if sc > best_score:
                best, best_score = i, sc
        if best is None:
            break
        o, e = rest.pop(best)
        placed.append((o, e["title"]))
    # a stretch of more than GAP_FILL with no chapter: its heaviest moment of weight 20 or more (a repeating
    # technology's level, a recap), else an hour mark
    lesser = sorted([(offset(segs, e["t"]), e) for e in events if 20 <= e["weight"] < 30], key=lambda r: -r[1]["weight"])
    left_open = set()
    while len(placed) < MAX_CHAPTERS:
        marks = sorted(p for p, _ in placed) + [total]
        gaps = [(a, b) for a, b in zip(marks, marks[1:]) if b - a > GAP_FILL and (a, b) not in left_open]
        if not gaps:
            break
        a, b = max(gaps, key=lambda r: r[1] - r[0])
        pick = next(((o, e["title"]) for o, e in lesser if o is not None and a + MIN_GAP <= o <= b - MIN_GAP), None)
        if pick is None:
            hours = [h for h in range(3600, int(b), 3600) if a + MIN_GAP <= h <= b - MIN_GAP]
            if hours:
                h = min(hours, key=lambda h: abs(h - (a + b) / 2))
                pick = (float(h), f"Hour {h // 3600 + 1}")
        if pick is None:
            left_open.add((a, b))
        else:
            placed.append(pick)
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


NOTABLE = ("first", "far", "planet", "arrive", "depart", "platform", "lost", "visit", "deleted")


def wording(text):
    """A title's words with the numbers taken out: "918 more rockets" reads as "1478 more rockets" does."""
    return re.sub(r"\d[\d,]*", "#", (text or "").lower()).strip()


def highlight(events, row, biggest, previous=None):
    """The title's few words: the shift's biggest moment, and a second one when it is big too (weight 60 or more,
    another platform or kind) and both fit. (d29 batch338 VT) previous: the shift before's highlight. A moment whose
    words (numbers aside) are in it does not lead or join: the next-heaviest leads (a big moment, else the heaviest
    research, an agent's chronicle entry, a big breach); only when nothing else is left does the repeat lead."""
    def fresh(text):
        return not previous or wording(text) not in wording(previous)
    ranked = sorted([e for e in events if e["kind"] in NOTABLE or e["kind"] in ("research", "rocket", "fight")
                     and e["weight"] >= 50], key=lambda e: (-e["weight"], e["t"]))
    bits, more = [], None
    rockets = [e for e in events if e["kind"] == "rocket"]
    if rockets:  # the rockets as one phrase, weighed by the first of them
        n = sum(e["count"] for e in rockets)
        first = any(e["first"] for e in rockets)
        phrase = (("the first rocket" if n == 1 else f"the first {n} rockets") if first else
                  ("one more rocket" if n == 1 else f"{n} more rockets"))
        ranked = [e for e in ranked if e["kind"] != "rocket"]
        w = max(e["weight"] for e in rockets)
        if w >= 50 and first:
            ranked.append(dict(rockets[0], title=phrase, weight=w))
            ranked.sort(key=lambda e: (-e["weight"], e["t"]))
        elif w >= 50:  # (batch338) a thousandth rocket: every shift has one, so after research, visits and entries
            more = dict(rockets[0], title=phrase, weight=w)
    stale = [e for e in ranked if not fresh(e["title"])]
    ranked = [e for e in ranked if fresh(e["title"])]
    for e in ranked:
        if not bits:
            bits.append(e)
        elif e["weight"] >= 60 and (e["kind"] != bits[0]["kind"] or e.get("name") != bits[0].get("name")) \
                and len(bits[0]["title"]) + len(e["title"]) + 5 <= 70:
            bits.append(e)
            break
    words = [b["title"] if i == 0 or b["kind"] in ("first", "far", "arrive", "depart", "visit") else lower(b["title"])
             for i, b in enumerate(bits)]
    techs = [t for t in sorted([e for e in events if e["kind"] == "research"], key=lambda e: -e["weight"])
             if fresh(t["title"])]
    if not words and techs:
        words.append(f"{techs[0]['label']} researched" if not techs[0]["label"].endswith("discovered") else techs[0]["label"])
    notes = [e for e in events if e["kind"] == "note" and fresh(e["title"])]
    if not words and notes:
        words.append(notes[0]["title"])
    if not words and more and fresh(more["title"]):
        words.append(more["title"])
    elif more and not fresh(more["title"]):
        stale.append(more)
    if biggest >= 50 and len(words) < 2 and sum(len(w) for w in words) < 30:
        words.append(f"a {biggest}-building biter breach")
    if not words and stale:  # nothing new to lead: the repeat after all
        words.append(stale[0]["title"])
    if not words:
        words.append(f"{row.get('research_new', 0)} new technologies")
    text = " and ".join(words[:2])
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
    items = []  # (weight, line): the heaviest first; routine trips summed near the end
    if row:
        research = sorted([e for e in events if e["kind"] == "research"], key=lambda e: -e["weight"])
        names, count = [], {}
        for e in research:
            k = (f"the {e['label'].replace(' discovered', ' discovery')}" if e["label"].endswith(" discovered")
                 else lower(e["label"]))
            if k not in count:
                names.append(k)
            count[k] = count.get(k, 0) + 1
        techs = [k + (f" ({count[k]} levels)" if count[k] > 1 else "") for k in names][:5]
        if len(names) > 5:
            techs.append(f"{len(names) - 5} more")
        finished = ", ".join(techs[:-1]) + f" and {techs[-1]}" if len(techs) > 1 else "".join(techs)
        in_all = f" ({row['research']} in all)" if row["research"] != row["research_new"] else ""
        # a repeating technology's next level keeps its name: research finished counts it, new technologies do not
        text = (f"• {row['research_new']} new technologies{in_all}" if row["research_new"] else
                f"• No new technologies ({row['research']} in all)") + (f"; research finished: {finished}" if techs else "")
        items.append((research[0]["weight"] if research else 20, text))
        rockets = [e for e in events if e["kind"] == "rocket"]
        if rockets:
            k = sum(e["count"] for e in rockets)
            items.append((max(e["weight"] for e in rockets) if any(e["first"] for e in rockets) else 25,
                          f"• {k} rocket{'s' if k != 1 else ''} launched" + (", the first of the run" if any(e["first"] for e in rockets) else "")))
        for e in events:
            if e["kind"] in NOTABLE and e["weight"] >= 30:
                items.append((e["weight"], f"• {e['title']}"))
        tries = {}  # (batch338) a far place set out for again: one line each, with the farthest it got
        for e in events:
            if e["kind"] == "trip" and e.get("to") in FAR:
                tries[(e["name"], e["to"])] = tries.get((e["name"], e["to"]), 0) + 1
        for (name, to), k in tries.items():
            got = max([e["km"] for e in events if e["kind"] in ("reach", "far") and e.get("km") is not None
                       and e.get("name") == name and e.get("to") == to], default=None)
            items.append((28, f"• {name} set out for {place(to)} again" + (f" ({k} times)" if k > 1 else "")
                          + (f", {int(round(got, -3)) or got:,} km at the farthest" if got is not None else "")))
        routes = trip_routes([e for e in events if not (e["kind"] == "trip" and e.get("to") in FAR)])
        if routes:
            k = sum(r[0] for r in routes)
            parts = [f"{c} between {pair}" + (f" ({', '.join(names[:3])}{' and others' if len(names) > 3 else ''})" if names else "")
                     for c, pair, names in routes[:4]]
            more = sum(r[0] for r in routes[4:])
            items.append((5, f"• {k} routine platform trip{'s' if k != 1 else ''}: " + "; ".join(parts)
                          + (f"; {more} on other routes" if more else "")))
        if row.get("spm") is not None:  # research units a minute (site/longrun.py): SPM as players say it
            items.append((3, f"• Science: {row['spm']:g} SPM on average (research units a minute)"))
    fights = sorted([e for e in events if e["kind"] == "fight"], key=lambda e: -e["lost"])
    line = f"• Deaths: {deaths}" if deaths else "• No deaths"
    if fights:
        line += f"; the biggest biter attack cost {fights[0]['lost']} buildings"
    dw = [e["weight"] for e in events if e["kind"] in ("death", "fight")]
    items.append((max(dw) if dw else 2, line))
    lines += [text for _, text in sorted(items, key=lambda r: -r[0])]
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

def previous_highlight(d):
    """The highlight of the shift before d: the nearest earlier run with a score log (one stopped while setting up has
    none), its video.json's, else built now (rotate builds the newest first); None when there is none."""
    before = next((r for r in shift_times.earlier_runs(str(d)) if (d.parent / r / "scores.jsonl").exists()), None)
    if not before:
        return None
    try:
        return json.loads((d.parent / before / "video" / "video.json").read_text()).get("highlight")
    except (OSError, ValueError):
        pass
    try:
        return build(before, d.parent, previous="")["highlight"]
    except (SystemExit, KeyError, ValueError, IndexError):
        return None


def build(run, runs_dir, listing=None, utc_offset=-8, frame=None, previous=None):
    """previous: the shift before's highlight (default: its video/video.json's; "" for none)."""
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
    chron = chronicle_rows(d / "chronicle.jsonl")
    told = any(r.get("kind") in ("platform_arrived", "platform_left", "platform_created") for r in chron)
    events = score_events(sc, n == 1, prev_rockets, platforms=not told,
                          research=not any(r.get("kind") == "research" for r in chron))
    history = run_history(d)
    if chron:
        events += chronicle_events(chron, start, end, history, planets=sc[0]["planets"] if sc else ())
    events += reach_events(reach_rows(d / "scores.jsonl"), start, end, history["best"])
    fights, deaths, biggest = fight_events(d, start)
    events += fights
    events += segment_events(d, start)
    import moderation  # site/moderation.py: YouTube deletions and the site's manual list
    hidden = moderation.load(runs_dir, REPO / "site" / "hidden-viewers.json")
    moments = viewer_moments(d, sc[0]["tick"] if sc else 0, names, hide=hidden.hides)
    events += moments
    events.sort(key=lambda e: e["t"])

    first = "Nine AIs, one empty map" if n == 1 else f"Shift {n} picks up at game time {row['game0']}" if row else f"Shift {n} begins"
    chapters = pick_chapters(events, segs, first, total)
    line = highlight(events, row or {}, biggest, previous_highlight(d) if previous is None else previous)
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


def retitle(first, last, runs_dir, write=False):
    """[(run, old title or None, new title)] for shifts first..last in order, each built with the one before's new
    highlight as its previous (the first: the shift before's video.json). write: each new title and highlight into the
    run's video/video.json when it has one (its description, chapters and the rest kept)."""
    out, previous = [], None
    for n in range(first, last + 1):
        run = f"shift{n}"
        if not (Path(runs_dir) / run / "scores.jsonl").exists():  # stopped while setting up: no shift, no video
            continue
        v = build(run, runs_dir, previous=previous)
        path = Path(runs_dir) / run / "video" / "video.json"
        old = json.loads(path.read_text()) if path.exists() else None
        out.append((run, old and old.get("title"), v["title"]))
        if write and old is not None and (old.get("title"), old.get("highlight")) != (v["title"], v["highlight"]):
            old.update(title=v["title"], highlight=v["highlight"])
            path.write_text(json.dumps(old, indent=1, ensure_ascii=False) + "\n")
        previous = v["highlight"]
    return out


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
    ap.add_argument("--titles", metavar="FIRST-LAST", help="shift numbers: each title by today's rules, old -> new")
    ap.add_argument("--write", action="store_true", help="with --titles: into each video.json")
    a = ap.parse_args()
    if a.list_cmd:
        print(LIST_CMD)
        return
    if a.titles:
        first, _, last = a.titles.partition("-")
        for run, old, new in retitle(int(first), int(last or first), a.runs_dir, a.write):
            print(f"{run}: {old or '(no video yet)'}\n  -> {new}{'' if old != new else ' (same)'}")
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
