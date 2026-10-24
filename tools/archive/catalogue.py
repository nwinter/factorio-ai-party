#!/usr/bin/env python3
"""The clip library's catalogue: every shift with a master on the SSD and logs, indexed, its candidate clips ranked
across the whole run (batch129 CL1, CL3):

    python3 tools/archive/catalogue.py build [--shifts 1-61] [--force] [--data DIR] [--runs-dir DIR] [--logs-dir DIR]
                                             [--recordings DIR ...]
    python3 tools/archive/catalogue.py search [--kind K] [--agent A] [--planet P] [--platform X] [--shift N]
                                              [--from T] [--to T] [--text WORDS] [--min-score S] [--limit 20] [--json]
    python3 tools/archive/catalogue.py show ID
    python3 tools/archive/catalogue.py best [--n 50] [--md FILE]

build: for each shift (runs/shiftNN that has ended and has a recording on the SSD), the index
(tools/archive/archive_index.py) with each recording's offset fitted from its voiced lines (tools/archive/calibrate.py;
kept in DATA/calibration.json, so a rerun reads no audio), then the shift's candidate clips (tools/archive/clips.py).
A shift whose index is newer than its logs is not rebuilt (--force does). Writes DATA/shifts/RUN-index.json and
DATA/catalogue.json: {shifts, media, entries}. An entry is one candidate clip: id (s48-platform_lost-001: the shift and
the event's id in its index), kind, title, times (epoch: t, t_in, t_out; `when`, Pacific), seconds, the shift's score
and the run's (`rank`: the score with a bonus for the first of its kind in the whole run), why, agents, planet,
platform, the voiced lines inside it (what viewers heard), the events folded into it (`also`), and where it plays in
which master (file, s_in). `flags` lists what keeps an entry off the air: no footage, a recording with no fitted
offset, a hidden viewer's chat on screen or name in a line (site/moderation.py).

search: every filter narrows. --agent matches the event's own agents (who died, who built the platform) when it
names any, else anyone on air or speaking in the clip; --planet is the event's, else the on-air camera's; --text
matches words in the title, the folded events and the voiced lines. Times are Pacific "2026-10-20 18:20[:SS]" or
epoch seconds. Best first by `rank`.

best: the run's best N for the tour writer, at most MAX_PER_SHIFT from a shift and MAX_PER_KIND of a kind, only
entries with no flags; --md writes the writer's list (tools/archive/catalogue.py best --md FILE).

DATA defaults to runs/archive in the main checkout (gitignored). Read-only on the masters and the logs; no game reads.
"""
import argparse
import datetime
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import archive_index  # noqa: E402
import calibrate  # noqa: E402
import clips  # noqa: E402

PACIFIC = archive_index.PACIFIC
MAIN = Path("/Users/owner/code/player-of-games")
SSD = Path("/Volumes/Extreme SSD/pog-recordings")
REC_DIRS = [SSD / d for d in ("public-run", "C-pog-recordings", "C-pog-recordings-moved", "D-pog-recordings")]
DEFAULT_DATA = MAIN / "runs" / "archive"
RUN_FIRST = 1.4         # the first of its kind in the whole run (a death: the agent's first; an arrival: the planet's)
ROUTINE_ROCKET = 0.5    # "first rocket of the shift" comes every shift
ONE_OFF_TECH = 2.0      # a technology researched once in the run, with no level number (Spidertron, Mech armor)
DISCOVERY = 3.0         # a planet discovered
MAX_PER_SHIFT = 3
MAX_PER_KIND = {"battle": 10, "death": 10, "replay": 6, "research": 6, "viewer_answer": 4, "arrival": 8,
                "rocket": 4, "segment": 4, "platform_created": 5, "platform_deleted": 2, "loss": 3, "note": 2,
                "maiden": 8, "platform_lost": 10}
SHIFT_RE = re.compile(r"^shift(\d+)$")
PLATFORM_RE = re.compile(r"\bPlatform (\S+)")
REACHES_RE = re.compile(r"reaches (\w+)")


# ---------------------------------------------------------------- times

def parse_time(s):
    """Pacific "YYYY-MM-DD HH:MM[:SS]" (or with a T) or epoch seconds, as epoch seconds."""
    s = str(s).strip()
    try:
        return float(s)
    except ValueError:
        pass
    t = datetime.datetime.fromisoformat(s.replace("T", " "))
    return (t.replace(tzinfo=PACIFIC) if t.tzinfo is None else t).timestamp()


def local(t):
    return datetime.datetime.fromtimestamp(t, PACIFIC)


def when(t):
    return local(t).strftime("%Y-%m-%d %H:%M:%S")


def shift_no(run):
    m = SHIFT_RE.match(run)
    return int(m.group(1)) if m else None


def parse_shifts(spec):
    """"1-61" or "48" or "1-14,48" as a set of numbers (None: every shift)."""
    if not spec:
        return None
    out = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


# ---------------------------------------------------------------- entries

def surface_planet(surface):
    if not surface:
        return None
    s = str(surface).lower()
    return "space" if s.startswith("platform") else s


def camera_at(index, t):
    """The on-air row at t: (subject, camera) or (None, None)."""
    for a, b, slot, subject, reason, *rest in index["onair"]:
        if a <= t < b:
            return subject, (rest[0] if rest else None)
    return None, None


def entry(index, c, hidden=None):
    """A catalogue entry from one candidate clip of one shift's index."""
    run = index["shift"]["run"]
    n = shift_no(run)
    ev = next((e for e in index["events"] if e["id"] == c["id"]), {})
    subject, cam = camera_at(index, c["t_event"])
    agents = {a.lower() for a in (c.get("agents") or [])}
    if subject and not subject.startswith("@"):
        agents.add(subject.lower())
    planet = (str(ev.get("planet")).lower() if ev.get("planet") else None) or surface_planet(ev.get("surface"))
    if not planet and "space platform" in (c.get("title") or ""):
        planet = "space"
    if not planet and cam:
        planet = surface_planet(cam[0])
    platform = ev.get("platform")
    if not platform:
        m = PLATFORM_RE.search(c.get("title") or "")
        platform = m.group(1) if m else None
    lines = [{"t": r["t"], "who": r.get("who"), "text": r["text"],
              **{k: r[k] for k in ("channel", "event") if r.get(k)}} for r in index["lines"]
             if r.get("text") and r["t"] + r.get("dur", 0) > c["t_in"] and r["t"] < c["t_out"]]
    for r in index["lines"]:
        if r.get("agent") and r["t"] + r.get("dur", 0) > c["t_in"] and r["t"] < c["t_out"]:
            agents.add(str(r["agent"]).lower())
    titles = {e["id"]: e.get("title") for e in index["events"]}
    media = next((m for m in index["media"] if c.get("file") == m["file"]), None)
    flags = []
    if "file" not in c:
        flags.append("no footage")
    elif media and not media.get("calibrated"):
        flags.append("recording offset not fitted (times within about 10 s)")
    if hidden:
        names = {nm for nm in getattr(hidden, "names", ())}
        if any(nm and nm in (r["text"] or "").lower() for r in lines for nm in names):
            flags.append("a hidden viewer's name in a voiced line")
    d = local(c["t_event"])
    out = {
        "id": f"s{n:02d}-{c['id']}" if n is not None else f"{run}-{c['id']}",
        "run": run, "shift": n, "kind": c["kind"], "title": c.get("title"),
        "t": c["t_event"], "t_in": c["t_in"], "t_out": c["t_out"], "seconds": c["seconds"],
        "when": when(c["t_event"]), "date": f"{d:%b} {d.day}", "caption": f"from shift {n}, {d:%b} {d.day}",
        "score": c["score"], "rank": c["score"], "why": list(c.get("why") or []),
        "agents": sorted(agents), "subjects": sorted(a.lower() for a in c.get("agents") or []),
        "planet": planet, "platform": platform, "on_air": subject,
        "lines": lines, "also": [{"id": i, "title": titles.get(i)} for i in c.get("also") or []],
        "flags": [f for f in flags if f],
    }
    if c.get("replay_file"):
        out["replay"] = Path(c["replay_file"]).name
    if "file" in c:
        out.update(file=c["file"], recording=Path(c["file"]).name, s_in=c["s_in"], s_out=c["s_out"])
    return out


def hidden_chat_flags(entries, raw_chat, hidden):
    """Flag entries whose full frame showed a hidden viewer's line (the program's chat panel keeps about the last
    five lines on screen; a line counts from 5 minutes before the clip to its end)."""
    if not hidden:
        return
    bad = [c["t"] for c in raw_chat if c.get("kind") == "viewer" and hidden.hides(c.get("who"), c.get("text"))]
    for e in entries:
        if any(e["t_in"] - 300 <= t <= e["t_out"] for t in bad):
            e["flags"].append("a hidden viewer's chat on the full frame (the camera-hole crop leaves it out)")
            e["hidden_chat"] = True


def run_rank(entries):
    """The run-wide score: the shift's score, x RUN_FIRST for the first of its kind in the run (a death: per agent; an
    arrival: per planet; a maiden flight: per platform), x ROUTINE_ROCKET for a shift's first rocket, x ONE_OFF_TECH
    for a one-off technology and x DISCOVERY for a planet discovered."""
    seen = set()
    one_off = {}
    for e in entries:
        if e["kind"] == "research":
            one_off[e["title"]] = one_off.get(e["title"], 0) + 1
    for e in sorted(entries, key=lambda x: x["t"]):
        kind = e["kind"]
        if kind == "death":
            key = (kind, (e.get("subjects") or e["agents"] or [None])[0])
        elif kind == "arrival":
            m = REACHES_RE.search(e["title"] or "")
            key = (kind, m.group(1).lower() if m else e.get("planet"))
        elif kind == "maiden":
            key = (kind, e.get("platform"))
        elif kind in ("battle", "loss", "replay", "viewer_answer", "note", "segment", "research"):
            key = None  # research titles are unique already; battles repeat by nature
        else:
            key = (kind,)
        factor = 1.0
        if key and key not in seen:
            seen.add(key)
            factor = RUN_FIRST
            e["why"] = [w for w in e["why"] if not w.startswith(("the shift's first", "the first death of"))]
            e["why"].insert(0, f"the run's first {kind.replace('_', ' ')}" +
                            (f" ({key[1]})" if len(key) > 1 and key[1] else ""))
        if kind == "rocket" and "First rocket of the shift" in (e["title"] or ""):
            factor *= ROUTINE_ROCKET
        if kind == "research" and one_off.get(e["title"]) == 1 and not re.search(r"\d|productivity", e["title"]):
            factor *= DISCOVERY if "discovered" in e["title"] else ONE_OFF_TECH
            e["why"].insert(0, "a planet discovered" if "discovered" in e["title"] else "a one-off technology")
        e["rank"] = round(e["score"] * factor, 1)


# ---------------------------------------------------------------- build

class ProbeCache:
    """ffprobe durations kept on disk by path, size and mtime (the SSD is slow to probe)."""

    def __init__(self, path):
        self.path = Path(path)
        try:
            self.d = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.d = {}

    def __call__(self, p):
        st = os.stat(p)
        k = f"{p}|{st.st_size}|{int(st.st_mtime)}"
        if k not in self.d:
            self.d[k] = archive_index.ffprobe_duration(p)
        return self.d[k]

    def save(self):
        self.path.write_text(json.dumps(self.d, indent=0))


def stale(index_path, run_dir):
    if not index_path.exists():
        return True
    t = index_path.stat().st_mtime
    return any((run_dir / f).exists() and (run_dir / f).stat().st_mtime > t
               for f in ("scores.jsonl", "stream-service.log", "chronicle.jsonl", "audio-played.jsonl", "chat.jsonl"))


def build_shift(run, a, data, cal, probe, hidden, log=print):
    """One shift's index (calibrating new recordings) and its entries; None when it has no recording."""
    rec = [str(d) for d in a.recordings]
    idx = archive_index.build(run, a.runs_dir, a.logs_dir, rec, cal, probe=probe, hidden=hidden)
    if not idx["media"]:
        return None
    lines = [(r["t"], r["dur"]) for r in idx["lines"] if r.get("dur")]
    fresh = False
    for m in idx["media"]:
        if m["name"] in cal:
            continue
        t = time.time()
        fit = calibrate.calibrate(m["file"], lines, m["named_t0"], m["duration"])
        fit["lines"] = lines_from(idx)
        fit["fitted_with"] = run
        cal[m["name"]] = fit
        fresh = True
        log(f"  {m['name']}: offset {fit['offset']} s, drift {fit['drift_s_per_h']} s/h, {fit['used']} of "
            f"{len(fit['windows'])} windows ({fit['lines']} lines, {time.time() - t:.1f} s)")
    if fresh:
        (data / "calibration.json").write_text(json.dumps(cal, indent=1))
        idx = archive_index.build(run, a.runs_dir, a.logs_dir, rec, cal, probe=probe, hidden=hidden)
    return idx


def lines_from(idx):
    kinds = {bool(r.get("pushed")) for r in idx["lines"]}
    return "both" if len(kinds) > 1 else "pushed" if True in kinds else "played"


def shift_row(idx):
    s = idx["shift"]
    cover = sum(min(m["t1"], s["end"]) - max(m["t0"], s["start"]) for m in idx["media"])
    return {"run": s["run"], "shift": shift_no(s["run"]), "start": s["start"], "end": s["end"],
            "start_local": when(s["start"]), "hours": round((s["end"] - s["start"]) / 3600, 2),
            "covered_h": round(cover / 3600, 2), "recordings": [m["name"] for m in idx["media"]],
            "calibrated": all(m["calibrated"] for m in idx["media"]),
            "lines_from": lines_from(idx),
            "events": len(idx["events"]), "lines": len(idx["lines"])}


def cmd_build(a):
    data = Path(a.data)
    (data / "shifts").mkdir(parents=True, exist_ok=True)
    import moderation  # site/moderation.py (archive_index put site/ on the path)
    hidden = moderation.load(a.runs_dir, REPO / "site" / "hidden-viewers.json")
    cal_path = data / "calibration.json"
    cal = json.loads(cal_path.read_text()) if cal_path.exists() else {}
    probe = ProbeCache(data / "durations.json")
    want = parse_shifts(a.shifts)
    old = {}
    if (data / "catalogue.json").exists():
        try:
            prev = json.loads((data / "catalogue.json").read_text())
            old = {s["run"]: s for s in prev.get("shifts", [])}
        except ValueError:
            pass
    shifts, media, entries = [], [], []
    t_all = time.time()
    for d in sorted(Path(a.runs_dir).glob("shift*"), key=lambda p: shift_no(p.name) or 0):
        n = shift_no(d.name)
        if n is None or (want and n not in want):
            continue
        path = data / "shifts" / f"{d.name}-index.json"
        t = time.time()
        if a.force or stale(path, d):
            try:
                _, _, running = archive_index.sv.shift_window(d)
            except SystemExit as x:
                print(f"{d.name}: skipped ({x})")
                continue
            if running:
                print(f"{d.name}: skipped (still on)")
                continue
            idx = build_shift(d.name, a, data, cal, probe, hidden)
            probe.save()
            if idx is None:
                print(f"{d.name}: no recording on the SSD")
                continue
            path.write_text(json.dumps(idx, ensure_ascii=False, separators=(",", ":")))
        else:
            idx = json.loads(path.read_text())
        cands = clips.candidates(idx)
        es = [entry(idx, c, hidden) for c in cands]
        raw = archive_index.chat_rows(archive_index.jsonl(d / "chat.jsonl"), [
            r for p in archive_index.log_files(a.logs_dir, "viewers", idx["shift"]["start"], idx["shift"]["end"])
            for r in archive_index.jsonl(p)], idx["shift"]["start"], idx["shift"]["end"], None)
        hidden_chat_flags(es, raw, hidden)
        entries += es
        row = shift_row(idx)
        row["entries"] = len(es)
        shifts.append(row)
        for m in idx["media"]:
            if not any(x["name"] == m["name"] for x in media):
                media.append({k: m[k] for k in ("name", "file", "named_t0", "offset", "t0", "t1", "duration",
                                                "calibrated")})
        print(f"{d.name}: {len(idx['events'])} events, {len(idx['lines'])} lines, {len(es)} entries, "
              f"{row['covered_h']} h of footage ({time.time() - t:.1f} s)")
    if want and old:  # a partial build keeps the other shifts from the last catalogue
        kept = [s for r, s in old.items() if shift_no(r) not in want]
        if kept:
            prev_entries = [e for e in prev["entries"] if e["shift"] not in want]
            shifts = sorted(kept + shifts, key=lambda s: s["shift"])
            entries = prev_entries + entries
            media = [m for m in prev["media"] if not any(x["name"] == m["name"] for x in media)] + media
    for e in entries:
        e["why"] = [w for w in e["why"] if not w.startswith(RUN_WHY)]
    run_rank(entries)
    entries.sort(key=lambda e: -e["rank"])
    cat = {"version": 1, "built": round(time.time()), "shifts": shifts,
           "media": sorted(media, key=lambda m: m["t0"]), "entries": entries}
    (data / "catalogue.json").write_text(json.dumps(cat, ensure_ascii=False, separators=(",", ":")))
    print(f"{data / 'catalogue.json'}: {len(shifts)} shifts, {len(media)} recordings, {len(entries)} entries "
          f"({time.time() - t_all:.0f} s)")


# ---------------------------------------------------------------- search

def load(data):
    return json.loads((Path(data) / "catalogue.json").read_text())


def search(entries, kind=None, agent=None, planet=None, platform=None, shift=None, t_from=None, t_to=None,
           text=None, min_score=None):
    out = []
    words = [w.lower() for w in (text or "").split()]
    for e in entries:
        if kind and e["kind"] not in kind.split(","):
            continue
        if agent and agent.lower() not in (e.get("subjects") or e["agents"]):  # the one who died, else anyone in it
            continue
        if planet and (e.get("planet") or "") != planet.lower():
            continue
        if platform and platform.lower() not in (e.get("platform") or "").lower():
            continue
        if shift is not None and e["shift"] != shift:
            continue
        if t_from is not None and e["t_out"] < t_from:
            continue
        if t_to is not None and e["t_in"] > t_to:
            continue
        if min_score is not None and e["rank"] < min_score:
            continue
        if words:
            hay = " ".join([e["title"] or ""] + [x["title"] or "" for x in e["also"]] +
                           [ln["text"] for ln in e["lines"]]).lower()
            if not all(w in hay for w in words):
                continue
        out.append(e)
    return sorted(out, key=lambda e: -e["rank"])


def brief(e):
    flags = f"  [{'; '.join(e['flags'])}]" if e["flags"] else ""
    return (f"{e['id']:<28} {e['rank']:>6} {e['when']}  {e['seconds']:>4.0f}s  {e['kind']:<16} "
            f"{(e['title'] or '')[:90]}{flags}")


def cmd_search(a):
    cat = load(a.data)
    found = search(cat["entries"], a.kind, a.agent, a.planet, a.platform, a.shift,
                   parse_time(a.start) if a.start else None, parse_time(a.end) if a.end else None, a.text,
                   a.min_score)
    if a.json:
        print(json.dumps([{k: v for k, v in e.items() if k != "file"} for e in found[:a.limit]],
                         ensure_ascii=False, indent=1))
        return
    for e in found[:a.limit]:
        print(brief(e))
    print(f"{len(found)} found" + (f", {a.limit} shown" if len(found) > a.limit else ""))


def cmd_show(a):
    cat = load(a.data)
    e = next((x for x in cat["entries"] if x["id"] == a.id), None)
    if not e:
        raise SystemExit(f"{a.id}: not in the catalogue")
    print(json.dumps(e, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- best

def best(entries, n=50, per_shift=MAX_PER_SHIFT, per_kind=MAX_PER_KIND):
    """The run's best n with no flags, at most per_shift from one shift and per_kind of a kind, best first."""
    out, by_shift, by_kind = [], {}, {}
    for e in sorted(entries, key=lambda x: -x["rank"]):
        if e["flags"] and not all("full frame" in f for f in e["flags"]):
            continue
        if by_shift.get(e["shift"], 0) >= per_shift or by_kind.get(e["kind"], 0) >= per_kind.get(e["kind"], 5):
            continue
        out.append(e)
        by_shift[e["shift"]] = by_shift.get(e["shift"], 0) + 1
        by_kind[e["kind"]] = by_kind.get(e["kind"], 0) + 1
        if len(out) >= n:
            break
    return out


CALLS = {"death": {"death"}, "battle": {"attack", "loss"}, "loss": {"loss"},
         "platform_lost": {"loss", "attack", "space"}, "research": {"research"},
         "maiden": {"space", "segment", "arrival"},
         "arrival": {"space", "segment", "arrival"}, "viewer_answer": {"viewer_reply"}}
RUN_WHY = ("the run's first", "a one-off technology", "a planet discovered")  # run_rank's own reasons


def first_line(e):
    """What viewers heard about the moment: the hosts calling it, else the hosts' first line from 3 s before it on,
    else anyone's."""
    after = [ln for ln in e["lines"] if ln["t"] >= e["t"] - 3]
    pick = (next((ln for ln in after if ln.get("event") in CALLS.get(e["kind"], ())), None)
            or next((ln for ln in after if ln.get("channel") == "caster"), None) or (after or [None])[0])
    if not pick:
        return ""
    text = pick["text"] if len(pick["text"]) <= 140 else pick["text"][:137].rsplit(" ", 1)[0] + "..."
    return f"{pick['who']}: \"{text}\""


def best_md(cat, picked, url_base):
    s = cat["shifts"]
    lines = [
        "# The run's best 50 moments (clip library, batch129 CL3)", "",
        f"From the catalogue of {len(s)} shifts (shift {s[0]['shift']} to {s[-1]['shift']}, "
        f"{sum(x['covered_h'] for x in s):.0f} hours of program recordings) and {len(cat['entries'])} candidate "
        f"clips. Ranked by the run-wide score: how strong the moment is (a platform lost, a death, a battle's size, "
        f"a maiden flight), whether the program had it on screen, whether chat and the hosts reacted, and a bonus "
        f"for the first of its kind in the whole run. At most {MAX_PER_SHIFT} from one shift; clips with a problem "
        f"(no footage, an unfitted clock, moderation) are left out.", "",
        "To use one, put its clip id in the tour script. The clip is made on demand (about a minute):", "",
        "    python3 tools/archive/clipmaker.py CLIP_ID", "",
        f"and plays from {url_base}/clips/CLIP_ID.mp4 (cropped to the camera hole, 1208x1032, with the program's "
        f"sound; captions at CLIP_ID.vtt, details at CLIP_ID.json). Times are Pacific. Lengths include the hosts' "
        f"reaction; a stop can use part of a clip.", "",
        "Listed in run order; # is the rank. Heard: the hosts calling the moment, else their first line from it "
        "on (sometimes about something else on screen); in shifts 1-13 lines are placed by when they were sent to the "
        "page, so one can be a few seconds off.", "",
        "| # | when (PT) | shift | length | moment | why | heard | clip id |",
        "|---|---|---|---|---|---|---|---|",
    ]
    rank = {e["id"]: i for i, e in enumerate(picked, 1)}
    for e in sorted(picked, key=lambda x: x["t"]):
        why = "; ".join(e["why"][:4])
        lines.append(f"| {rank[e['id']]} | {e['when'][5:16]} | {e['shift']} | {e['seconds']:.0f} s | "
                     f"{(e['title'] or '').replace('|', '/')} | {why.replace('|', '/')} | "
                     f"{first_line(e).replace('|', '/')} | `{e['id']}` |")
    return "\n".join(lines) + "\n"


def cmd_best(a):
    cat = load(a.data)
    picked = best(cat["entries"], a.n)
    if a.md:
        import clipmaker
        Path(a.md).write_text(best_md(cat, picked, clipmaker.PUBLIC))
        print(f"{a.md}: {len(picked)} moments")
    else:
        for e in picked:
            print(brief(e))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default=str(DEFAULT_DATA))
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--shifts")
    b.add_argument("--force", action="store_true")
    b.add_argument("--runs-dir", default=str(MAIN / "runs"))
    b.add_argument("--logs-dir", default=str(MAIN / "tools" / "stream" / "logs"))
    b.add_argument("--recordings", nargs="+", default=[str(d) for d in REC_DIRS])
    s = sub.add_parser("search")
    s.add_argument("--kind")
    s.add_argument("--agent")
    s.add_argument("--planet")
    s.add_argument("--platform")
    s.add_argument("--shift", type=int)
    s.add_argument("--from", dest="start")
    s.add_argument("--to", dest="end")
    s.add_argument("--text")
    s.add_argument("--min-score", type=float)
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--json", action="store_true")
    w = sub.add_parser("show")
    w.add_argument("id")
    t = sub.add_parser("best")
    t.add_argument("--n", type=int, default=50)
    t.add_argument("--md")
    a = ap.parse_args()
    {"build": cmd_build, "search": cmd_search, "show": cmd_show, "best": cmd_best}[a.cmd](a)


if __name__ == "__main__":
    main()
