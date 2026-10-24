#!/usr/bin/env python3
"""Every ended shift's recording to YouTube, private, one shift at a time (docs/VIDEOS.md "The whole run";
operator d24 14:45, Nick approved shift 63's private test).

  python3 tools/archive_upload.py --inventory              # which shifts have recordings, minutes covered, gaps
  python3 tools/archive_upload.py --dry-run                # each shift's plan: files, cut or join, size, time
  python3 tools/archive_upload.py --shifts 2,4             # upload those (in order); --shifts 1-69 --limit 10

Recordings: the masters on the Extreme SSD (pog-recordings/{public-run, C-pog-recordings, C-pog-recordings-moved,
D-pog-recordings}) and the box's D:\\pog\\recordings and C:\\pog\\recordings (ssh pogwin, ffprobe there), each named
by the box's clock (PST, UTC-8); Replay_ clips and empty files are left out; a name on the SSD and the box is the
SSD's. Durations come from ffprobe (kept in --durations by path, size and mtime). Each shift's recordings and in/out
points are tools/shift_video.py's (segments: a file overlapping the shift by under a minute is the next or last
shift's; one running more than 10 minutes past an end is cut a minute past it).

Per shift, in order, an uploaded one skipped (its video id in --manifest or runs/RUN/video/upload.json):
1. One file, no cut: that file as it is (a box file is copied to --tmp first by scp, its size checked).
2. Else (several files, or a cut): box files copied to --tmp, then joined without re-encoding (ffmpeg's concat
   demuxer, -c copy, with shift_video's inpoint/outpoint) into --tmp/RUN.mkv; its duration is checked.
3. shift_video builds runs/RUN/video/ (title, description, chapters, thumbnail) from the same recording list.
4. tools/yt_upload.py uploads it: --privacy private --no-playlist --max-mbps 200, the site record to --manifest (a
   private file, not site/content/videos.json). An interrupted upload resumes on the next run (upload.json).
5. Once yt_upload reports the video id, what this tool wrote to --tmp for the shift is removed. The masters are
   never moved, renamed, written or removed.

Quota (yt_upload.py's figures): videos.insert is 1 of 100 uploads a day; thumbnails.set 50 of the 10,000 daily
units; with --no-playlist nothing else. --limit stops after N uploads in one run.
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import shift_video as sv  # noqa: E402

SSD = Path("/Volumes/Extreme SSD")
SOURCES = [SSD / "pog-recordings" / d for d in ("public-run", "C-pog-recordings", "C-pog-recordings-moved", "D-pog-recordings")]
BOX_DIRS = [r"D:\pog\recordings", r"C:\pog\recordings"]
TMP = SSD / "pog-videos" / "tmp"
OPERATOR = Path.home() / "code" / "pog-operator" / "video-work"
MANIFEST = OPERATOR / "videos-private.json"
DURATIONS = SSD / "pog-videos" / "durations.json"  # ffprobe durations by path, size, mtime (not the masters folder)
RUNS = Path(os.environ.get("POG_SITE_RUNS") or Path.home() / "code" / "player-of-games" / "runs")
NAME = re.compile(r"^20\d\d-\d\d-\d\d[ _]\d\d-\d\d-\d\d\.(mkv|mp4|mov|flv)$", re.I)
GAP = 60  # seconds of a shift with no recording that count as a gap
# for the dry run's time (estimates): the LAN copy from the box and the join's read and write on the SSD
SCP_MBS, JOIN_MBS = 100, 250


def shifts_arg(text):
    """"2,4,10-12" -> [2, 4, 10, 11, 12]."""
    out = []
    for part in (text or "").split(","):
        if "-" in part:
            a, b = part.split("-")
            out += range(int(a), int(b) + 1)
        elif part.strip():
            out.append(int(part))
    return out


# ---------------------------------------------------------------- recordings

def probe(path):
    """ffprobe's duration in seconds, or None."""
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                             capture_output=True, text=True, timeout=120).stdout.strip()
        return float(out)
    except (ValueError, OSError, subprocess.SubprocessError):
        return None


def local_files(sources, cache):
    """[{name, path, size, duration, where}] for the SSD's recordings; durations kept in `cache` by path."""
    out = []
    for src in sources:
        if not Path(src).is_dir():
            continue
        for p in sorted(Path(src).iterdir()):
            if not NAME.match(p.name):
                continue
            st = p.stat()
            if st.st_size == 0:
                continue
            key = str(p)
            got = cache.get(key)
            if not (got and got[0] == st.st_size and got[1] == int(st.st_mtime)):
                got = [st.st_size, int(st.st_mtime), probe(p)]
                cache[key] = got
            out.append({"name": p.name, "path": key, "size": st.st_size, "duration": got[2], "where": Path(src).name})
    return out


BOX_LIST = ('for %d in ({dirs}) do @for %f in (%d\\20*.mkv) do @echo F,%~zf,%f '
            '& @ffprobe -v error -show_entries format=duration -of csv=p=0 "%f"')


def parse_box(text):
    """The box listing (BOX_LIST's output: `F,SIZE,PATH` then the duration or N/A on the next line) -> files."""
    out, cur = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("F,"):
            _, size, path = line.split(",", 2)
            name = re.split(r"[\\/]", path)[-1]
            cur = {"name": name, "path": path, "size": int(size), "duration": None, "where": "box"}
            if NAME.match(name) and cur["size"] > 0:
                out.append(cur)
        elif cur is not None and line:
            try:
                cur["duration"] = float(line)
            except ValueError:
                pass
            cur = None
    return out


def box_files(host, dirs):
    cmd = BOX_LIST.format(dirs=" ".join(dirs))
    try:
        r = subprocess.run(["ssh", host, cmd], capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        raise SystemExit(f"the box's list (ssh {host}): {e}")
    return parse_box(r.stdout)


def catalogue(local, box):
    """One row per recording name, the SSD's copy first; files with no duration are left out (a recording still
    being written: OBS writes the duration at the end)."""
    by = {}
    for f in local + box:
        if f["name"] not in by and f["duration"]:
            by[f["name"]] = f
    return sorted(by.values(), key=lambda f: f["name"])


def file_time(name):
    """A recording's start from its name, by the box's clock (PST all year, UTC-8), in Pacific time."""
    f = sv.FILE_TIME.search(name)
    box = datetime.timezone(datetime.timedelta(hours=-8))
    return datetime.datetime(*map(int, f.groups()), tzinfo=box).astimezone(sv.PACIFIC)


def listing(files):
    """shift_video.read_listing's text: `PATH,DURATION` per file."""
    return "".join(f"{f['path']},{f['duration']}\n" for f in files)


# ---------------------------------------------------------------- plans

def plan(run, runs_dir, files, tmp):
    """The shift's plan: its window, segments (shift_video's), covered minutes, gaps and what to do."""
    d = Path(runs_dir) / run
    start, end, running = sv.shift_window(d)
    by_path = {f["path"]: f for f in files}
    lst = [(f["path"], file_time(f["name"]), f["duration"]) for f in files]
    segs = sv.segments(sorted(lst, key=lambda r: r[1]), start, end)
    covered, gaps, at = 0.0, [], start
    for s in segs:
        a, b = max(s["start"], start), min(s["end"], end)
        if b > a:
            covered += (b - a).total_seconds()
        if (a - at).total_seconds() > GAP:
            gaps.append((at, a))
        at = max(at, b)
    if (end - at).total_seconds() > GAP:
        gaps.append((at, end))
    rows = [dict(s, **{k: by_path[s["file"]][k] for k in ("name", "size", "where")}) for s in segs]
    cut = any(s["in"] > 1 or s["trim_out"] for s in segs)
    if not segs:
        action = "none"
    elif len(segs) == 1 and not cut:
        action = "copy" if rows[0]["where"] == "box" else "as is"
    else:
        action = "join"
    seconds = sum((s["end"] - s["start"]).total_seconds() for s in segs)
    # the upload's size: the file as it is, or each part's share of its file
    size = sum(r["size"] * min(1.0, (r["out"] - r["in"]) / max(1.0, by_path[r["file"]]["duration"])) if action == "join"
               else r["size"] for r in rows)
    box_bytes = sum(r["size"] for r in rows if r["where"] == "box")
    target = None
    if action == "as is":
        target = rows[0]["file"]
    elif action != "none":
        target = str(Path(tmp) / (rows[0]["name"] if action == "copy" else f"{run}.mkv"))
    return {"run": run, "start": start, "end": end, "running": running, "segments": rows, "seconds": seconds,
            "covered": covered, "gaps": gaps, "action": action, "size": int(size), "box_bytes": box_bytes,
            "file": target}


def plan_time(p, max_mbps):
    """Estimated seconds: the box copy, the join, the upload at max_mbps."""
    t = p["box_bytes"] / (SCP_MBS * 1e6)
    if p["action"] == "join":
        t += p["size"] / (JOIN_MBS * 1e6)
    return t + p["size"] * 8 / (max_mbps * 1e6)


def uploaded(run, runs_dir, manifest):
    """The video id when the shift is up: in the manifest, or runs/RUN/video/upload.json."""
    if (manifest.get(run) or {}).get("id"):
        return manifest[run]["id"]
    try:
        return json.loads((Path(runs_dir) / run / "video" / "upload.json").read_text()).get("video_id")
    except (OSError, ValueError):
        return None


def hm(seconds):
    m = int(round(seconds / 60))
    return f"{m // 60}h{m % 60:02d}"


def gaps_text(gaps):
    return ", ".join(f"{a:%H:%M}-{b:%H:%M} ({hm((b - a).total_seconds())})" for a, b in gaps) or "-"


# ---------------------------------------------------------------- doing it

def run_cmd(cmd, **kw):
    print("  $ " + " ".join(shlex.quote(str(c)) for c in cmd), flush=True)
    return subprocess.run(cmd, **kw)


def fetch(row, tmp, host):
    """A box file copied to tmp (scp), its size checked; returns the local path."""
    dest = Path(tmp) / row["name"]
    if dest.exists() and dest.stat().st_size == row["size"]:
        return dest
    src = row["file"].replace("\\", "/")
    if run_cmd(["scp", "-q", f"{host}:{src}", str(dest)]).returncode != 0 or dest.stat().st_size != row["size"]:
        raise SystemExit(f"copy of {row['file']} failed or its size differs ({dest})")
    return dest


def streams(path):
    """A file's streams as ffprobe gives them (codec, size, rate, audio format): the concat demuxer with -c copy
    needs them the same in every file (d24: all 22 files of the 9 joins are hevc 1920x1080 30/1, aac 48000 2)."""
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels", "-of", "csv=p=0",
                        str(path)], capture_output=True, text=True, timeout=120)
    return r.stdout.strip()


def join(p, tmp, local_of, streams_of=streams):
    """The segments joined without re-encoding into tmp/RUN.mkv, shift_video's in/out points; duration checked."""
    kinds = {str(local_of[s["file"]]): streams_of(local_of[s["file"]]) for s in p["segments"]}
    if len(set(kinds.values())) != 1:
        raise SystemExit(f"{p['run']}: the files differ in their streams, so they cannot be joined without "
                         f"re-encoding: {kinds}")
    out = Path(tmp) / f"{p['run']}.mkv"
    lst = Path(tmp) / f"{p['run']}.concat.txt"
    lines = ["ffconcat version 1.0"]
    for s in p["segments"]:
        lines.append("file '" + str(local_of[s["file"]]).replace("'", r"'\''") + "'")
        if s["in"] > 1:
            lines.append(f"inpoint {s['in']}")
        if s["trim_out"]:
            lines.append(f"outpoint {s['out']}")
    lst.write_text("\n".join(lines) + "\n")
    r = run_cmd(["nice", "-n", "19", "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "concat",
                 "-safe", "0", "-i", str(lst), "-map", "0", "-c", "copy", str(out)])
    got = probe(out) if r.returncode == 0 else None
    if got is None or abs(got - p["seconds"]) > 30 + 0.002 * p["seconds"]:
        raise SystemExit(f"{p['run']}: the join {out} is {got} s, the plan {p['seconds']:.0f} s")
    return out, lst


def do_shift(p, a, files):
    run, tmp = p["run"], Path(a.tmp)
    if any(tmp.resolve() == Path(src).resolve() for src in (a.source or SOURCES)):
        raise SystemExit(f"--tmp {tmp} is a folder of masters")
    tmp.mkdir(parents=True, exist_ok=True)
    made = []
    local_of = {}
    for s in p["segments"]:
        if s["where"] == "box":
            dest = fetch(s, tmp, a.box)
            made.append(dest)
            local_of[s["file"]] = dest
        else:
            local_of[s["file"]] = Path(s["file"])
    if p["action"] == "join":
        out, lst = join(p, tmp, local_of)
        made += [out, lst]
        video = out
    else:
        video = local_of[p["segments"][0]["file"]]
    # the plan: the same recording list (masters' paths) as this tool's
    rec = tmp / f"{run}.recordings.txt"
    rec.write_text(listing(files))
    made.append(rec)
    r = run_cmd([sys.executable, str(HERE / "shift_video.py"), run, "--runs-dir", str(a.runs_dir), "--recordings", str(rec)])
    if r.returncode != 0:
        raise SystemExit(f"{run}: shift_video failed")
    v = json.loads((Path(a.runs_dir) / run / "video" / "video.json").read_text())
    if [s["file"] for s in v["segments"]] != [s["file"] for s in p["segments"]]:
        raise SystemExit(f"{run}: shift_video's segments differ from the plan's")
    r = run_cmd([sys.executable, str(HERE / "yt_upload.py"), run, "--file", str(video), "--runs-dir", str(a.runs_dir),
                 "--privacy", a.privacy, "--no-playlist", "--max-mbps", str(a.max_mbps), "--videos-json", str(a.manifest)])
    vid = uploaded(run, a.runs_dir, load(a.manifest))
    if r.returncode != 0 or not vid:
        raise SystemExit(f"{run}: the upload did not finish (run again to resume); {tmp} kept")
    for f in made:
        # (the SSD is exFAT: macOS writes a ._NAME sidecar beside each file it makes there)
        for x in (Path(f), Path(f).with_name("._" + Path(f).name)):
            if x.resolve().parent == tmp.resolve() and x.exists():
                x.unlink()
    return vid


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inventory", action="store_true", help="the recordings per shift; nothing is written")
    ap.add_argument("--dry-run", action="store_true", help="each shift's plan; nothing is copied, joined or sent")
    ap.add_argument("--shifts", help="shift numbers, e.g. 2,4 or 1-69 (default every ended shift)")
    ap.add_argument("--limit", type=int, help="stop after this many uploads")
    ap.add_argument("--runs-dir", default=str(RUNS))
    ap.add_argument("--source", action="append", help="a folder of masters (default the Extreme SSD's four)")
    ap.add_argument("--box", default="pogwin", help="ssh host of the box ('' for none)")
    ap.add_argument("--tmp", default=str(TMP))
    ap.add_argument("--manifest", default=str(MANIFEST))
    ap.add_argument("--durations", default=str(DURATIONS))
    ap.add_argument("--privacy", default="private", choices=["private", "unlisted", "public"])
    ap.add_argument("--max-mbps", type=float, default=200)
    a = ap.parse_args()
    cache = load(a.durations)
    local = local_files(a.source or SOURCES, cache)
    Path(a.durations).parent.mkdir(parents=True, exist_ok=True)
    Path(a.durations).write_text(json.dumps(cache, indent=0) + "\n")
    box = box_files(a.box, BOX_DIRS) if a.box else []
    files = catalogue(local, box)
    runs = sorted((p.name for p in Path(a.runs_dir).glob("shift[0-9]*") if p.is_dir()), key=lambda n: int(n[5:]))
    if a.shifts:
        want = set(shifts_arg(a.shifts))
        runs = [r for r in runs if int(r[5:]) in want]
    manifest = load(a.manifest)
    plans = []
    for run in runs:
        try:
            plans.append(plan(run, a.runs_dir, files, a.tmp))
        except SystemExit as e:
            print(f"{run}: no plan ({e})")
    print(f"{len(files)} recordings ({sum(f['where'] != 'box' for f in files)} on the SSD, {sum(f['where'] == 'box' for f in files)} only on the box); {len(plans)} shifts")
    if a.inventory or a.dry_run:
        head = "| shift | window (Pacific) | recordings | covered | gaps |" + (" plan | upload | time |" if a.dry_run else "")
        print(head)
        print("|" + "---|" * (head.count("|") - 1))
        total_t = total_b = 0
        for p in plans:
            recs = "; ".join(f"{s['name']} ({s['where']}, {s['size'] / 1e9:.1f} GB"
                             + (f", {s['in']:.0f}-{s['out']:.0f} s" if s["in"] > 1 or s["trim_out"] else "") + ")"
                             for s in p["segments"]) or "none"
            row = (f"| {p['run']}{' (on)' if p['running'] else ''} | {p['start']:%m-%d %H:%M}-{p['end']:%H:%M} | {recs} | "
                   f"{p['covered'] / 60:.0f} of {(p['end'] - p['start']).total_seconds() / 60:.0f} min | {gaps_text(p['gaps'])} |")
            if a.dry_run:
                vid = uploaded(p["run"], a.runs_dir, manifest)
                if vid:
                    row += f" uploaded {vid} | | |"
                elif p["running"] or p["action"] == "none":
                    row += f" skip ({'on' if p['running'] else 'no recording'}) | | |"
                else:
                    t = plan_time(p, a.max_mbps)
                    total_t += t
                    total_b += p["size"]
                    row += f" {p['action']} | {p['size'] / 1e9:.1f} GB | {hm(t)} |"
            print(row)
        if a.dry_run:
            n = sum(1 for p in plans if p["action"] != "none" and not p["running"] and not uploaded(p["run"], a.runs_dir, manifest))
            print(f"\n{n} uploads, {total_b / 1e9:.0f} GB, about {hm(total_t)} at {a.max_mbps:g} Mbit/s (estimate: box copy "
                  f"{SCP_MBS} MB/s, join {JOIN_MBS} MB/s); quota: {n} of the 100 uploads a day, {50 * n} of the 10,000 "
                  f"daily units (thumbnails.set)")
        return
    done = 0
    for p in plans:
        if a.limit is not None and done >= a.limit:
            break
        vid = uploaded(p["run"], a.runs_dir, manifest)
        if vid or p["running"] or p["action"] == "none":
            print(f"{p['run']}: skip ({'uploaded ' + vid if vid else 'on' if p['running'] else 'no recording'})")
            continue
        print(f"{p['run']}: {p['action']}, {len(p['segments'])} file(s), {p['size'] / 1e9:.1f} GB", flush=True)
        vid = do_shift(p, a, files)
        print(f"{p['run']}: https://www.youtube.com/watch?v={vid} ({a.privacy})", flush=True)
        manifest = load(a.manifest)
        done += 1


if __name__ == "__main__":
    main()
