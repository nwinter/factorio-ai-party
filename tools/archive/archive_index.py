#!/usr/bin/env python3
"""One shift's archive index, keyed on wall-clock UTC seconds (report-D section 3; batch126 CI1):

    python3 tools/archive/archive_index.py RUN [--runs-dir DIR] [--logs-dir DIR] [--recordings DIR ...]
                                               [--calibration FILE] [--out FILE]

Every time in the index is epoch seconds (`t`); a game tick is an attribute, mapped through `clock` (shift13 replayed
shift12's game hours, and the game pauses, so a tick does not name a moment). The index holds:

  shift    the run folder, the world's shift number, start and end (tools/shift_video.py's window)
  media    the recordings that cover the shift: file, the start its name gives (`named_t0`: OBS names files by the
           box's clock, PST all year), the fitted `offset` (tools/archive/calibrate.py), `t0` = named_t0 + offset,
           ffprobe's duration, `t1`
  gaps     [t0, t1] inside the shift with no recording
  clock    [t, tick, paused] from scores.jsonl (every 2 minutes)
  onair    [t0, t1, slot, subject, reason, camera] the program's subject per interval: an agent's name, or a shot
           (@platform, @attack, @segment, @map, @incoming, @replay, @fallback: a camera whose platform was lost
           under it); camera is [surface, x, y, zoom] or null
  layout   [t, onecam|trio]
  events   {id, t, kind, title, ...}: research, rocket (the shift's first and each thousand), death, platform_lost,
           platform_created, platform_deleted, maiden, arrival, battle, loss, segment, replay, viewer_answer, note
  milestones  the ids of the events that mark progress (research, rockets, platforms, maiden flights, arrivals)
  lines    {t, dur, who, channel, text, event|label}: every voiced line (hosts, agents aloud, operator), t its play
           start on the log clock (audio-played.jsonl joined to the caster jsonl's text)
  chat     {t, who, kind: agent|viewer, text}: agents' chat lines and viewers' lines (site/moderation.py deletions out)
  stats    rows of `stats_cols`, from scores.jsonl

Sources (read-only): runs/RUN/{stream.json, start.log, scores.jsonl, chronicle.jsonl, chat.jsonl, audio-played.jsonl,
stream-service.log}, tools/stream/logs/{director,caster,viewers,viewer-answers}-STAMP.jsonl whose stamp falls in the
shift, the recordings folder (names and ffprobe only). No journals, notes or session logs (the 10-13 rule: only what
viewers saw or heard). No game reads.
"""
import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "tools"))
import shift_video as sv  # noqa: E402  (puts site/ and tools/stream on the path)
import shift_times  # noqa: E402
import longrun  # noqa: E402

PACIFIC = sv.PACIFIC
BOX = datetime.timezone(datetime.timedelta(hours=-8))  # OBS's file names: the box's clock, PST all year
TEAM = sv.TEAM
STAMP = re.compile(r"^\[(\w[\w-]*)\] (\d\d):(\d\d):(\d\d) (.*)$")
ON_AIR = re.compile(r"^ON AIR (\w+): (\S+)\s+<- (.*)$")
LAYOUT = re.compile(r"^LAYOUT (\w+)")
CUE = re.compile(r"<- (death|loss): (.*)$")
BATTLE = re.compile(r"^BATTLE \((?:incoming \()?score ([\d.]+)\)?\): (.*)$")
MAIDEN = re.compile(r"^maiden flight: (.*)$")
REACHES = re.compile(r"^segment: (.+?) reaches (\w+)$")
SEGMENT = re.compile(r"^segment: (.+)$")
REPLAY_ON = re.compile(r"^\[replays\] on air: (.*) \((\S+?), from (\d+) ms of (\d+) ms\)$")
REPLAY_SAVED = re.compile(r"^\[replays\] saved (\S+) for (.*)$")
LOST_N = re.compile(r"^(\d+) lost\b")
STAMP_FILE = re.compile(r"-(\d{8})-(\d{6})\.jsonl$")
MILESTONE_KINDS = {"research", "rocket", "platform_created", "platform_lost", "maiden", "arrival"}
STATS_COLS = ["t", "tick", "game_time", "rockets", "research", "researching", "spm", "packs_per_min", "platforms",
              "planets", "deaths"]


# ---------------------------------------------------------------- reading

def jsonl(path):
    out = []
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            out.append(r)
    return out


def epoch_local(s):
    """A naive ISO time from the Mac's logs (Pacific) as epoch seconds."""
    return sv.iso_local(s).timestamp()


def log_files(logs_dir, prefix, start, end):
    """tools/stream/logs/PREFIX-YYYYMMDD-HHMMSS.jsonl started inside the shift (a log starts at a service restart and
    runs until the next one; one stamped before the shift's start belongs to the shift before)."""
    out = []
    for p in sorted(Path(logs_dir).glob(f"{prefix}-*.jsonl")):
        m = STAMP_FILE.search(p.name)
        if not m or not re.fullmatch(re.escape(prefix) + r"-\d{8}-\d{6}\.jsonl", p.name):
            continue
        t = datetime.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=PACIFIC).timestamp()
        if start - 900 <= t < end:
            out.append(p)
    return out


def stamped_lines(path, start):
    """(epoch, tag, text, exact) for each line of stream-service.log: a line with its own HH:MM:SS is exact; an untagged
    one ([cuts], [replays]) takes the last stamped line's time. Dated from start; over midnight the day moves on."""
    out = []
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return out
    day = datetime.datetime.fromtimestamp(start, PACIFIC).date()
    anchor = datetime.datetime.fromtimestamp(start, PACIFIC)
    last, prev = None, None
    for line in text.splitlines():
        m = STAMP.match(line)
        if m:
            t = datetime.datetime.combine(day, datetime.time(*map(int, m.group(2, 3, 4))), PACIFIC)
            if prev is None and t < anchor - datetime.timedelta(hours=12):
                day += datetime.timedelta(days=1)
                t += datetime.timedelta(days=1)
            if prev and t < prev - datetime.timedelta(hours=6):
                day += datetime.timedelta(days=1)
                t += datetime.timedelta(days=1)
            prev = t
            last = t.timestamp()
            out.append((last, m.group(1), m.group(5), True))
        elif last is not None and line.startswith("["):
            out.append((last, line[1:line.index("]")] if "]" in line else "", line, False))
    return out


def replay_times(stream):
    """[(start, seconds, label, path, spread)] of the replays aired. Their lines carry no clock: a replay started between
    the stamped lines around its "on air" line and ended between those around its "back to ..." line; each is the
    middle of its bounds (spread: the wider bound). The clip's media length is not its time on air (OBS plays a clip at
    a speed the log does not give: shift48's battle replay spans 38 s of media and was on air 14 s)."""
    out = []
    stamps = [i for i, r in enumerate(stream) if r[3]]

    def bounds(i):
        lo = stream[i][0]
        hi = next((stream[j][0] for j in stamps if j > i), lo)
        return lo, hi

    for i, (t, tag, text, exact) in enumerate(stream):
        if tag != "replays":
            continue
        m = REPLAY_ON.match(text)
        if not m:
            continue
        lo, hi = bounds(i)
        start = (lo + hi) / 2
        back = next((j for j in range(i + 1, min(len(stream), i + 400))
                     if stream[j][1] == "replays" and stream[j][2].startswith("[replays] back to")), None)
        if back is not None:
            blo, bhi = bounds(back)
            end, spread = max(start + 1, (blo + bhi) / 2), max(hi - lo, bhi - blo)
        else:
            end, spread = start + (int(m.group(4)) - int(m.group(3))) / 1000, hi - lo
        out.append((round(start, 1), round(end - start, 1), m.group(1), m.group(2), round(spread, 1)))
    return out


# ---------------------------------------------------------------- recordings

def ffprobe_duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


def recordings(dirs, start, end, probe=ffprobe_duration, calibration=None):
    """The program recordings (not Replay_ clips) that overlap [start, end], oldest first, as media rows."""
    cal = calibration or {}
    rows = []
    for d in dirs:
        for p in sorted(Path(d).glob("*.mkv")):
            m = sv.FILE_TIME.search(p.name)
            if not m or p.name.lower().startswith("replay"):
                continue
            named = datetime.datetime(*map(int, m.groups()), tzinfo=BOX).timestamp()
            if named > end + 600 or named < start - 6 * 3600:
                continue
            dur = probe(p)
            if dur is None or named + dur < start - 60:
                continue
            c = cal.get(p.name) or {}
            off = c.get("offset") or 0.0
            rows.append({"file": str(p), "name": p.name, "named_t0": named, "offset": off,
                         "t0": round(named + off, 2), "duration": dur, "t1": round(named + off + dur, 2),
                         "calibrated": bool(c.get("offset") is not None and c)})
    rows.sort(key=lambda r: r["t0"])
    return [r for r in rows if r["t0"] < end and r["t1"] > start]


def gaps(media, start, end, slack=1.0):
    out, at = [], start
    for m in media:
        if m["t0"] > at + slack:
            out.append([round(at, 1), round(min(m["t0"], end), 1)])
        at = max(at, m["t1"])
    if at < end - slack:
        out.append([round(at, 1), round(end, 1)])
    return out


def at(index, t):
    """Where wall time t plays: {file, s} in a recording, or {gap: [t0, t1], nearest: t} in a gap."""
    for m in index["media"]:
        if m["t0"] <= t <= m["t1"]:
            return {"file": m["file"], "s": round(t - m["t0"], 2)}
    for g in index["gaps"]:
        if g[0] <= t <= g[1]:
            nxt = next((m["t0"] for m in index["media"] if m["t0"] >= g[1] - 1), None)
            prv = next((m["t1"] for m in reversed(index["media"]) if m["t1"] <= g[0] + 1), None)
            near = min((x for x in (nxt, prv) if x is not None), key=lambda x: abs(x - t), default=None)
            return {"gap": g, "nearest": near}
    return None


# ---------------------------------------------------------------- clocks

def clock_rows(scores_path, start, end):
    """[t, tick, paused] from scores.jsonl inside the shift (plus one row either side, for the edges)."""
    rows = []
    for r in jsonl(scores_path):
        s = r.get("score") or {}
        if s.get("tick") is None or not r.get("t"):
            continue
        rows.append([epoch_local(r["t"]), s["tick"], bool(s.get("paused"))])
    rows.sort()
    inside = [i for i, r in enumerate(rows) if start <= r[0] <= end]
    if not inside:
        return []
    return [[round(r[0], 1), r[1], r[2]] for r in rows[max(0, inside[0] - 1):inside[-1] + 2]]


def tick_to_t(clock, tick):
    """The wall time of a tick inside this shift's clock (linear between samples), or None outside it."""
    for a, b in zip(clock, clock[1:]):
        if a[1] <= tick <= b[1]:
            return a[0] + (b[0] - a[0]) * ((tick - a[1]) / ((b[1] - a[1]) or 1))
    return None


def t_to_tick(clock, t):
    if not clock or t < clock[0][0] or t > clock[-1][0]:
        return None
    return round(longrun.interp([r[0] for r in clock], [r[1] for r in clock], t))


# ---------------------------------------------------------------- on air

def onair(stream, director_rows, start, end):
    """The program's subject per interval, from the director's ON AIR lines; a replay interrupts its subject for the
    clip's length and the subject resumes after. camera: the slot's last camera move from the director's jsonl."""
    cuts, replays, layout = [], [], []
    for t, tag, text, exact in stream:
        if tag == "director" and exact:
            m = ON_AIR.match(text)
            if m:
                cuts.append([t, m.group(1), m.group(2), m.group(3)])
                continue
            m = LAYOUT.match(text)
            if m:
                layout.append([round(t, 1), m.group(1)])
    replays = [[t, dur, label] for t, dur, label, _, _ in replay_times(stream)]
    cams = {}
    for r in director_rows:
        cam = (r.get("result") or {}).get("camera") or (r.get("cmd") or {})
        pos = cam.get("position") or {}
        if r.get("slot") in ("main", "cam2", "cam3") and pos and r.get("t"):
            cams.setdefault(r["slot"], []).append((r["t"], [cam.get("surface") or r.get("surface"), pos.get("x"),
                                                            pos.get("y"), cam.get("zoom")]))

    def camera(slot, t):
        best = None
        for ct, body in cams.get(slot, []):
            if ct > t + 5:
                break
            best = body
        return best

    rows = []
    for i, (t, slot, subject, reason) in enumerate(cuts):
        t1 = cuts[i + 1][0] if i + 1 < len(cuts) else end
        rows.append([t, t1, slot, subject, reason])
    out = rows
    for rt, dur, label in replays:  # a replay takes the program over the director's own cuts for its length
        nxt = []
        for p in out:
            if p[1] <= rt or p[0] >= rt + dur:
                nxt.append(p)
                continue
            if p[0] < rt:
                nxt.append([p[0], rt] + p[2:])
            if p[1] > rt + dur:
                nxt.append([rt + dur, p[1]] + p[2:])
        nxt.append([rt, rt + dur, "replay", "@replay", label])
        out = sorted(nxt)
    out = [p for p in out if p[1] - p[0] >= 0.5]
    out = [[round(max(a, start), 1), round(min(b, end), 1), slot, subj, reason[:160],
            camera(slot, a) if slot != "replay" else None]
           for a, b, slot, subj, reason in out if b > start and a < end]
    return out, [x for x in layout if start <= x[0] <= end]


def surface_lost(onair_rows, events):
    """A camera on a platform's surface stops showing it when the platform is lost: the game deletes the surface and the
    view falls back to a planet, while the director's line still names the platform (shift48 18:25:35, Limestone).
    The interval splits at the loss; the rest is "@fallback"."""
    for e in events:
        if e["kind"] != "platform_lost" or not e.get("surface"):
            continue
        out = []
        for r in onair_rows:
            cam = r[5]
            if cam and cam[0] == e["surface"] and r[0] < e["t"] < r[1]:
                out.append([r[0], round(e["t"], 1)] + r[2:])
                out.append([round(e["t"], 1), r[1], r[2], "@fallback",
                            f"platform {e.get('platform')} lost: the view left its surface", None])
            else:
                out.append(r)
        onair_rows = out
    return onair_rows


def subject_at(onair_rows, t):
    for r in onair_rows:
        if r[0] <= t < r[1]:
            return r
    return None


# ---------------------------------------------------------------- events

def chronicle_events(rows, clock, start, end):
    """Research, the shift's first rocket, deaths, platforms built, lost or deleted, and the agents' chronicle entries.
    A row's own t, unless the log wrote a batch late (more than a minute from where its tick puts it)."""
    out, first_rocket = [], False
    for r in rows:
        t = r.get("t")
        mapped = tick_to_t(clock, r["tick"]) if isinstance(r.get("tick"), (int, float)) else None
        if t is None or (mapped is not None and abs(t - mapped) > 60):
            t = mapped
        if t is None or not start <= t <= end:
            continue
        kind = r.get("kind") if r.get("type") == "event" else "note" if r.get("type") == "entry" else None
        base = {"t": round(t, 1), "tick": r.get("tick"), "src": "chronicle"}
        if kind == "research":
            out.append(dict(base, kind="research", title=f"Research: {longrun.tech_label(r.get('name') or '')}",
                            tech=r.get("name"), agents=[r["queued_by"]] if r.get("queued_by") else []))
        elif kind == "rocket" and not first_rocket:
            first_rocket = True
            out.append(dict(base, kind="rocket", title="First rocket of the shift", surface=r.get("surface"),
                            first=True))
        elif kind == "death":
            who = (r.get("agent") or "?")
            out.append(dict(base, kind="death", title=f"{who.capitalize()} dies on {(r.get('planet') or r.get('surface') or '?').capitalize()}"
                            + (f" ({r['by'].replace('-', ' ')})" if r.get("by") else ""),
                            agents=[who], surface=r.get("surface"), by=r.get("by"),
                            x=(r.get("position") or {}).get("x"), y=(r.get("position") or {}).get("y")))
        elif kind == "platform_lost":
            out.append(dict(base, kind="platform_lost", surface=r.get("surface"), title=f"Platform {r.get('platform')} lost "
                            f"({r.get('from')} to {r.get('to')}, {r.get('flown')}% flown)", platform=r.get("platform"),
                            by=r.get("by"), cargo_items=r.get("cargo_items"), agents=[r["creator"]] if r.get("creator") else []))
        elif kind in ("platform_created", "platform_deleted"):
            verb = "built" if kind == "platform_created" else "deleted"
            out.append(dict(base, kind=kind, title=f"Platform {r.get('platform')} {verb}", platform=r.get("platform")))
        elif kind == "note":
            out.append(dict(base, kind="note", title=(r.get("title") or "")[:90], agents=[r["agent"]] if r.get("agent") else []))
    return out


def rocket_thousands(stats, start, end):
    """Each thousandth rocket, at the middle of the score interval that crossed it (stats rows: t, tick, game time,
    rockets, ...)."""
    out = []
    for a, b in zip(stats, stats[1:]):
        if not (start <= b[0] <= end + 120):
            continue
        for k in range(a[3] // 1000 + 1, b[3] // 1000 + 1):
            out.append({"t": round((a[0] + b[0]) / 2, 1), "kind": "rocket", "title": f"Rocket {k * 1000:,}",
                        "count": k * 1000, "src": "scores"})
    return out


def director_events(stream, start, end, replay_files):
    """Battles taken (with the director's score), loss alerts and deaths it cut to, maiden flights, arrivals and host
    segments put on air, and the replays aired (with their Replay_ file when it is on the recordings drive)."""
    out, seen, saved = [], {}, {}

    def fresh(key, t, within=60):
        prev = seen.get(key)
        seen[key] = t
        return prev is None or t - prev > within

    for t, tag, text, exact in stream:
        if not start <= t <= end:
            if tag == "replays":
                m = REPLAY_SAVED.match(text)
                if m:
                    saved[m.group(2)] = m.group(1)
            continue
        if tag == "replays":
            m = REPLAY_SAVED.match(text)
            if m:
                saved[m.group(2)] = m.group(1)
            continue
        if tag != "director" or not exact:
            continue
        m = BATTLE.match(text)
        if m:
            out.append({"t": round(t, 1), "kind": "battle", "title": f"Battle: {m.group(2)}"[:110],
                        "score": float(m.group(1)), "src": "stream-service"})
            continue
        m = MAIDEN.match(text)
        if m and fresh(("maiden", m.group(1)), t, 600):
            parts = [p.strip() for p in m.group(1).split("·")]
            by = re.search(r"built by (\w+)", m.group(1))
            out.append({"t": round(t, 1), "kind": "maiden", "title": f"Maiden flight: {parts[0]} ({parts[2] if len(parts) > 2 else ''})",
                        "platform": parts[0], "agents": [by.group(1).lower()] if by else [], "src": "stream-service"})
            continue
        m = ON_AIR.match(text)
        if m:
            reason = m.group(3)
            r = REACHES.match(reason)
            if r and fresh(("arrival", reason), t, 300):
                out.append({"t": round(t, 1), "kind": "arrival", "title": f"{r.group(1)} reaches {r.group(2)}",
                            "platform": r.group(1), "planet": r.group(2), "src": "stream-service"})
            elif not r:
                s = SEGMENT.match(reason)
                if s and fresh(("segment", reason), t, 300):
                    out.append({"t": round(t, 1), "kind": "segment", "title": s.group(1)[:90], "src": "stream-service"})
            continue
        m = CUE.search(text)
        if m and fresh((m.group(1), m.group(2)), t):
            if m.group(1) == "death":
                who = re.match(r"(.+?) died", m.group(2))
                out.append({"t": round(t, 1), "kind": "death_cut", "title": m.group(2)[:90],
                            "agents": [who.group(1).split()[0].lower()] if who else [], "src": "stream-service"})
            else:
                n = LOST_N.match(m.group(2))
                out.append({"t": round(t, 1), "kind": "loss", "title": f"Loss: {m.group(2)}"[:120],
                            "lost": int(n.group(1)) if n else None, "src": "stream-service"})
    for t, dur, label, path, spread in replay_times(stream):
        if start <= t <= end:
            name = re.split(r"[\\/]", path)[-1]
            out.append({"t": t, "kind": "replay", "title": f"Replay: {label}"[:110], "seconds": round(dur, 1),
                        "within": spread, "replay_file": replay_files.get(name), "replay_name": name,
                        "src": "stream-service"})
    for e in out:  # a replay's file from its saved line (the label matches)
        if e["kind"] == "replay" and not e.get("replay_file"):
            label = e["title"][len("Replay: "):]
            path = saved.get(label)
            if path:
                e["replay_name"] = re.split(r"[\\/]", path)[-1]
                e["replay_file"] = replay_files.get(e["replay_name"])
    return out


def merge_deaths(events):
    """A chronicle death and the director's cut to it are one death: the cut marks it as shown; a cut with no chronicle
    row stays as a death of its own."""
    deaths = [e for e in events if e["kind"] == "death"]
    rest = []
    for e in events:
        if e["kind"] != "death_cut":
            rest.append(e)
            continue
        match = next((d for d in deaths if set(d.get("agents") or []) & set(e.get("agents") or [])
                      and -30 <= e["t"] - d["t"] <= 90), None)
        if match:
            match["cut_t"] = e["t"]
        else:
            rest.append(dict(e, kind="death"))
    return rest


def viewer_answer_events(rows, start, end, hidden):
    out = []
    for r in rows:
        ans = (r.get("reply") or {}).get("answer")
        if not ans or not r.get("t") or not start <= r["t"] <= end:
            continue
        if hidden and hidden.hides(r.get("viewer") or "", r.get("text") or ""):
            continue
        q = (r.get("reply") or {}).get("question") or r.get("text") or ""
        out.append({"t": round(r["t"], 1), "kind": "viewer_answer", "title": f"{r.get('viewer')} asks: {sv.short(q, 60)}",
                    "viewer": r.get("viewer"), "question": r.get("text"), "answer": ans, "src": "viewer-answers"})
    return out


# ---------------------------------------------------------------- lines and chat

def voiced_lines(played, caster_rows, start, end):
    """Each voiced clip that played: its start (logged end minus played seconds), length, speaker and text. The text
    comes from the caster jsonl row pushed in the same second as the clip's id ("EPOCH-N": the hub's add time), with
    the same length within half a second; a clip with no such row keeps its time and an empty text."""
    pushed = [r for r in caster_rows if r.get("pushed") and r.get("line") and r.get("t")]
    pushed.sort(key=lambda r: r["t"])
    used = set()
    out = []
    for p in played:
        if p.get("state") != "end" or not p.get("played"):
            continue
        t0 = p["t"] - p["played"]
        if not start - 60 <= t0 <= end + 60:
            continue
        try:
            added = int(str(p.get("id", "")).split("-")[0])
        except ValueError:
            added = None
        best = None
        for i, r in enumerate(pushed):
            if i in used or added is None or abs(r["t"] - added) > 3:
                continue
            if p.get("duration") and r.get("seconds") and abs(r["seconds"] - p["duration"]) > 0.6:
                continue
            best = i
            break
        row = {"t": round(t0, 2), "dur": round(p["played"], 2), "who": p.get("speaker"), "channel": p.get("channel"),
               "agent": p.get("agent"), "text": ""}
        if best is not None:
            used.add(best)
            r = pushed[best]
            row["text"] = r["line"]
            if r.get("event"):
                row["event"] = r["event"]
            if r.get("label"):
                row["label"] = r["label"]
        out.append(row)
    return out


def chat_rows(chat, viewers, start, end, hidden):
    """Agents' chat (chat.jsonl) and viewers' lines (viewers-*.jsonl that passed the filter), in time order."""
    out = []
    for r in chat:
        who = r.get("from") or ""
        if who not in TEAM or not r.get("logged_at"):
            continue
        t = epoch_local(r["logged_at"])
        if start <= t <= end:
            out.append({"t": round(t, 1), "who": who, "kind": "agent", "text": r.get("text") or "",
                        **({"aloud": True} if r.get("aloud") else {})})
    seen = set()
    for r in viewers:
        if not r.get("pass") or not r.get("t") or not start <= r["t"] <= end or r.get("id") in seen:
            continue
        seen.add(r.get("id"))
        name = r.get("name") or "viewer"
        if name.lower() in sv.OWNERS or (hidden and hidden.hides(name, r.get("text") or "")):
            continue
        out.append({"t": round(r["t"], 1), "who": name, "kind": "viewer", "text": r.get("text") or "",
                    "source": r.get("source")})
    out.sort(key=lambda r: r["t"])
    return out


# ---------------------------------------------------------------- stats

def stats_rows(scores_path, start, end, events):
    sc = [r for r in longrun.scores(Path(scores_path)) if r.get("t")]
    for r in sc:
        r["epoch"] = epoch_local(r["t"])
    sc = [r for r in sc if start - 150 <= r["epoch"] <= end + 150]
    deaths = sorted(e["t"] for e in events if e["kind"] == "death")
    out = []
    for i, r in enumerate(sc):
        prev = sc[i - 1] if i else None
        spm = packs = None
        if prev:
            mins = (r["epoch"] - prev["epoch"]) / 60 or 1
            used = longrun.used_between(prev, r)
            spm = round(longrun.research_units(used) / mins, 1) if used is not None else None
            packs = round(max(0, r["science"] - prev["science"]) / mins)
        out.append([round(r["epoch"], 1), r["tick"], longrun.game_time(r["tick"]), r["rockets"], r["research"],
                    longrun.in_progress(r["current"], r.get("infinite")), spm, packs, len(r["platforms"]),
                    len(r["planets"]), sum(1 for d in deaths if d <= r["epoch"])])
    return out


# ---------------------------------------------------------------- build

def build(run, runs_dir, logs_dir, rec_dirs, calibration=None, probe=ffprobe_duration, hidden=None):
    d = Path(runs_dir) / run
    s, e, running = sv.shift_window(d)
    start, end = s.timestamp(), e.timestamp()
    media = recordings(rec_dirs, start, end, probe, calibration)
    replay_files = {}
    for rd in rec_dirs:
        for p in Path(rd).glob("Replay_*.mkv"):
            replay_files[p.name] = str(p)
    clock = clock_rows(d / "scores.jsonl", start, end)
    stream = stamped_lines(d / "stream-service.log", start)
    director = [r for p in log_files(logs_dir, "director", start, end) for r in jsonl(p)]
    on, layout = onair(stream, director, start, end)
    events = chronicle_events(jsonl(d / "chronicle.jsonl"), clock, start, end)
    events += rocket_thousands(stats_rows(d / "scores.jsonl", start, end, []), start, end)
    events += director_events(stream, start, end, replay_files)
    viewer_answers = [r for p in log_files(logs_dir, "viewer-answers", start, end) for r in jsonl(p)]
    events += viewer_answer_events(viewer_answers, start, end, hidden)
    events = merge_deaths(events)
    events.sort(key=lambda x: (x["t"], x["kind"]))
    on = surface_lost(on, events)
    counts = {}
    for x in events:
        counts[x["kind"]] = counts.get(x["kind"], 0) + 1
        x["id"] = f"{x['kind']}-{counts[x['kind']]:03d}"
        if x.get("tick") is None:
            tk = t_to_tick(clock, x["t"])
            if tk is not None:
                x["tick"] = tk
        sub = subject_at(on, x["t"])
        x["on_air"] = sub[3] if sub else None
    caster = [r for p in log_files(logs_dir, "caster", start, end) for r in jsonl(p)]
    lines = voiced_lines(jsonl(d / "audio-played.jsonl"), caster, start, end)
    viewers = [r for p in log_files(logs_dir, "viewers", start, end) for r in jsonl(p)]
    chat = chat_rows(jsonl(d / "chat.jsonl"), viewers, start, end, hidden)
    return {
        "version": 1,
        "shift": {"run": run, "number": shift_times.shift_number(str(d)), "start": round(start, 1),
                  "end": round(end, 1), "running": running,
                  "start_local": s.isoformat(timespec="seconds"), "end_local": e.isoformat(timespec="seconds")},
        "media": media,
        "gaps": gaps(media, start, end),
        "clock": clock,
        "onair": on,
        "layout": layout,
        "events": events,
        "milestones": [x["id"] for x in events if x["kind"] in MILESTONE_KINDS],
        "lines": lines,
        "chat": chat,
        "stats_cols": STATS_COLS,
        "stats": stats_rows(d / "scores.jsonl", start, end, events),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--runs-dir", default=str(REPO / "runs"))
    ap.add_argument("--logs-dir", default=str(REPO / "tools" / "stream" / "logs"))
    ap.add_argument("--recordings", nargs="+", default=[])
    ap.add_argument("--calibration", help="JSON {file name: {offset, ...}} from tools/archive/calibrate.py")
    ap.add_argument("--out")
    a = ap.parse_args()
    import moderation  # site/moderation.py
    hidden = moderation.load(a.runs_dir, REPO / "site" / "hidden-viewers.json")
    cal = json.load(open(a.calibration)) if a.calibration else None
    idx = build(a.run, a.runs_dir, a.logs_dir, a.recordings, cal, hidden=hidden)
    text = json.dumps(idx, ensure_ascii=False, separators=(",", ":"))
    if a.out:
        Path(a.out).write_text(text)
    else:
        print(text)


if __name__ == "__main__":
    main()
