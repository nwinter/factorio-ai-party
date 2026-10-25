#!/usr/bin/env python3
"""Whole shifts as HLS web renditions on R2, one shift at a time (batch211; Nick d25 15:30 and 15:50):

    python3 tools/archive/r2_shifts.py shift01 [shift02 ...]        # or --shifts 2-69
    python3 tools/archive/r2_shifts.py shift01 --dry-run            # the plan: recordings, in/out, the encodes

Per shift, in order (a shift with a receipt in --receipts is skipped):
1. The index: tools/archive/archive.py RUN --out HLS/RUN/work --recordings <the SSD's master folders> (no clip cut).
   The run's fitted offsets (runs/archive/calibration.json) are copied in first, so no master is read to calibrate.
2. The encode, at nice 19, one ffmpeg at a time, hls.py's ladder (1080p CRF 23 capped 6 Mbit/s, 540p 1.2 Mbit/s,
   4 s fMP4, a keyframe every 2 s) into HLS/RUN/full/: each recording that covers the shift is one part
   (RUNG/pNN/), and RUNG/index.m3u8 plays the parts back to back with a discontinuity between them. Beside it
   master.m3u8, captions.vtt (cues placed on the joined video), shift.json (the index cut to the shift, as hls.py's
   sample.json, plus `parts`: [video s, wall t, seconds, name] for the player) and encode.json. A recording overlaps
   the shift by a minute or more to count; one running more than 10 minutes past an edge is cut a minute past it
   (tools/shift_video.py's rule).
3. The upload with tools/archive/r2_put.py's plan and put to BUCKET/RUN/full/: segments first, playlists last. The
   rate is measured every --window seconds; --jobs starts at 4 and rises by 2 while the rate is under 80% of
   --max-mbps (150), never past --jobs-max, and stops rising once the cap is reached (a window over the cap takes
   one job off). Before each window the stream's health is read (tools/obs.py stream-status): with skipped frames
   rising or congestion over 0, no new puts start until two reads in a row are clean; the pauses go in the receipt.
4. The check: a HEAD of every object at the public r2.dev URL, its Content-Length against the local file's size; a
   missing or different one is put again and checked again; then RUN/full/receipt.json goes up and is checked too,
   and the same receipt is written to --receipts/RUN.json.
5. HLS/RUN/ is removed (the renditions only: the folder must hold no master), and RUN's row in --status reads
   "complete (r2-receipts/RUN.json)".

The masters are only read (ffprobe, ffmpeg input); r2_put refuses .mkv/.mov/.flv. Before an encode the SSD must have
the shift's estimate (8 Mbit/s for its length) plus --margin-gb free and the estimate must be under --max-local-gb.
"""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import captions  # noqa: E402
import hls  # noqa: E402
import r2_put  # noqa: E402

MAIN = Path.home() / "code" / "player-of-games"
SSD = Path("/Volumes/Extreme SSD")
SOURCES = [SSD / "pog-recordings" / d for d in ("public-run", "C-pog-recordings", "C-pog-recordings-moved",
                                                "D-pog-recordings")]
HLS_ROOT = SSD / "pog-hls"
OPERATOR = Path.home() / "code" / "pog-operator"
PUBLIC = "https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev"
PLAYER = PUBLIC + "/player/index.html"
UA = "pog-archive-check/1 (tools/archive/r2_shifts.py)"  # r2.dev refuses urllib's default agent
RUNGS = [1080, 540]
EDGE, SLACK = 60, 600  # shift_video.segments: a minute of overlap to count; trim an overhang past 10 minutes
EST_MBPS = 8.0  # both rungs' ceiling (6.5 + 1.5 Mbit/s): the space a shift may take


def shifts_arg(text):
    out = []
    for part in (text or "").split(","):
        if "-" in part:
            a, b = part.split("-")
            out += range(int(a), int(b) + 1)
        elif part.strip():
            out.append(int(part))
    return [f"shift{n:02d}" for n in out]


# ---------------------------------------------------------------- the plan

def parts(index):
    """The recordings that cover the shift as parts played back to back:
    [{name, file, folder, s_in, seconds, wall, video_at}] (wall: the wall time of the part's first frame)."""
    start, end = index["shift"]["start"], index["shift"]["end"]
    out, at = [], 0.0
    for m in index["media"]:
        if min(m["t1"], end) - max(m["t0"], start) < EDGE:
            continue
        a = max(m["t0"], start - EDGE) if start - m["t0"] > SLACK else m["t0"]
        b = min(m["t1"], end + EDGE) if m["t1"] - end > SLACK else m["t1"]
        seconds = round(b - a, 2)
        out.append({"name": m["name"], "file": m["file"], "folder": Path(m["file"]).parent.name,
                    "s_in": round(a - m["t0"], 2), "seconds": seconds, "wall": round(a, 2), "video_at": round(at, 2)})
        at += seconds
    return out


def part_dir(i):
    return f"p{i:02d}"


def stitch(rung_dir, n_parts):
    """RUNG/index.m3u8 from the parts' own playlists (RUNG/pNN/index.m3u8): each part's init map and segments,
    a discontinuity between parts."""
    target, body = 0, []
    for i in range(n_parts):
        sub = part_dir(i)
        if i:
            body.append("#EXT-X-DISCONTINUITY")
        for line in (Path(rung_dir) / sub / "index.m3u8").read_text().splitlines():
            line = line.strip()
            if line.startswith("#EXT-X-TARGETDURATION:"):
                target = max(target, int(line.split(":")[1]))
            elif line.startswith("#EXT-X-MAP:"):
                body.append(re.sub(r'URI="([^"]+)"', lambda m: f'URI="{sub}/{m.group(1)}"', line))
            elif line.startswith("#EXTINF:") or line.startswith("#EXT-X-BYTERANGE:"):
                body.append(line)
            elif line and not line.startswith("#"):
                body.append(f"{sub}/{line}")
    head = ["#EXTM3U", "#EXT-X-VERSION:7", f"#EXT-X-TARGETDURATION:{target}", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
    return "\n".join(head + body + ["#EXT-X-ENDLIST"]) + "\n"


def parts_vtt(lines, ps):
    """WebVTT on the joined video: each part's cues counted from its own start, moved to where it plays."""
    body, n = ["WEBVTT", ""], 0
    for p in ps:
        for s, e, who, text in captions.cues(lines, p["wall"], p["wall"], p["wall"] + p["seconds"]):
            n += 1
            body.append(str(n))
            body.append(f"{captions.stamp(s + p['video_at'])} --> {captions.stamp(e + p['video_at'])}")
            first = f"<v {captions.esc(who)}>{captions.esc(text[0])}" if who else captions.esc(text[0])
            body.append("\n".join([first] + [captions.esc(x) for x in text[1:]]))
            body.append("")
    return "\n".join(body)


def shift_data(index, ps):
    """hls.window over the joined video's wall span, with the parts (names only, no paths)."""
    t0 = ps[0]["wall"]
    t1 = ps[-1]["wall"] + ps[-1]["seconds"]
    d = hls.window(index, t0, t1)
    d["parts"] = [[p["video_at"], p["wall"], p["seconds"], p["name"]] for p in ps]
    d["gaps"] = [g for g in index["gaps"] if g[1] > t0 and g[0] < t1]
    return d


# ---------------------------------------------------------------- index and encode

def build_index(run, work, a, runner=subprocess.run):
    work.mkdir(parents=True, exist_ok=True)
    cal_src = Path(a.calibration)
    if cal_src.exists() and not (work / "calibration.json").exists():
        shutil.copyfile(cal_src, work / "calibration.json")
    cmd = [sys.executable, str(HERE / "archive.py"), run, "--out", str(work), "--recordings",
           *[str(s) for s in a.sources], "--runs-dir", str(a.runs_dir), "--logs-dir", str(a.logs_dir)]
    r = runner(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"{run}: archive.py failed: {(r.stderr or '')[-800:]}")
    return json.loads((work / f"{run}-index.json").read_text())


def encode(index, ps, out, runner=subprocess.run, clock=time.time, log=print):
    """Every rung of every part, then the playlists and data; returns encode.json's content."""
    out.mkdir(parents=True, exist_ok=True)
    report = {"parts": [{k: p[k] for k in ("name", "folder", "s_in", "seconds", "video_at")} for p in ps],
              "rungs": {}}
    total_s = sum(p["seconds"] for p in ps)
    for rung in RUNGS:
        took = 0.0
        for i, p in enumerate(ps):
            d = out / str(rung) / part_dir(i)
            d.mkdir(parents=True, exist_ok=True)
            t = clock()
            runner(hls.encode_cmd(p["file"], p["s_in"], p["seconds"], rung, d), check=True)
            took += clock() - t
        (out / str(rung) / "index.m3u8").write_text(stitch(out / str(rung), len(ps)))
        size = hls.size(out / str(rung))
        report["rungs"][rung] = {"encode_s": round(took, 1), "speed": round(total_s / took, 1) if took else None,
                                 "bytes": size, "mbps": round(size * 8 / total_s / 1e6, 2) if total_s else None}
        log(f"  {rung}p: {report['rungs'][rung]}")
    (out / "master.m3u8").write_text(hls.master(RUNGS))
    (out / "captions.vtt").write_text(parts_vtt(index["lines"], ps))
    (out / "shift.json").write_text(json.dumps(shift_data(index, ps), ensure_ascii=False, separators=(",", ":")))
    report["seconds"] = round(total_s, 1)
    (out / "encode.json").write_text(json.dumps(report, indent=1))
    return report


# ---------------------------------------------------------------- upload

def order(items):
    """Segments and init files first, then the rung playlists, then master.m3u8: a player that finds a playlist
    finds its segments."""
    def rank(it):
        key = it[1]
        if key.endswith("/master.m3u8"):
            return 2
        return 1 if key.endswith(".m3u8") else 0
    return sorted(items, key=lambda it: (rank(it), it[1]))


def parse_status(text):
    """tools/obs.py stream-status's line -> {active, skipped, total, congestion} (None when it does not parse)."""
    m = re.search(r"active=(\w+).*skipped=(\d+)/(\d+) congestion=([\d.]+)", text or "")
    if not m:
        return None
    return {"active": m.group(1) == "True", "skipped": int(m.group(2)), "total": int(m.group(3)),
            "congestion": float(m.group(4))}


class Health:
    """The stream's health between upload windows: bad while skipped frames rise or congestion is over 0."""

    def __init__(self, read):
        self.read = read
        self.last = None

    def check(self):
        s = parse_status(self.read())
        if s is None:
            return True, "stream status unreadable"
        rising = self.last is not None and s["skipped"] > self.last["skipped"] and s["total"] >= self.last["total"]
        self.last = s
        ok = not (s["active"] and (rising or s["congestion"] > 0))
        return ok, f"skipped={s['skipped']}/{s['total']} congestion={s['congestion']:.2f}"


def obs_status():
    py = MAIN / "tools" / ".venv" / "bin" / "python"
    try:
        r = subprocess.run([str(py), str(MAIN / "tools" / "obs.py"), "stream-status"], capture_output=True,
                           text=True, timeout=30)
        return r.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def next_jobs(jobs, mbps, max_mbps, jobs_max, capped):
    """(jobs, capped) for the next window: over the cap, one job less and no more raising; under 80% of it and
    never capped, two more (at most jobs_max)."""
    if mbps > max_mbps:
        return max(1, jobs - 1), True
    if not capped and mbps < 0.8 * max_mbps:
        return min(jobs_max, jobs + 2), capped
    return jobs, capped or mbps >= 0.8 * max_mbps


def upload(items, putter, max_mbps=150.0, jobs=4, jobs_max=16, window=30.0, health=None, clock=time.time,
           sleep=time.sleep, log=print):
    """Put every item, `jobs` at a time, the rate held at or under max_mbps; returns the upload's record."""
    items = order(items)
    todo = list(items)
    t_start = clock()
    t_win, bytes_win, done_bytes = t_start, 0, 0
    capped = False
    failed, pauses, trace = [], [], []
    running = {}
    paused_since, clean = None, 0

    def gate():
        nonlocal paused_since, clean
        if health is None:
            return True
        ok, text = health()
        if paused_since is None and not ok:
            paused_since, clean = clock(), 0
            log(f"  stream health: {text}; uploads paused")
            pauses.append({"from": round(paused_since - t_start, 1), "why": text})
        elif paused_since is not None:
            clean = clean + 1 if ok else 0
            if clean >= 2:
                pauses[-1]["seconds"] = round(clock() - paused_since, 1)
                log(f"  stream health: {text}; uploads resumed")
                paused_since = None
        return paused_since is None

    open_gate = gate()
    with ThreadPoolExecutor(jobs_max) as ex:
        while todo or running:
            while open_gate and todo and len(running) < jobs:
                it = todo.pop(0)
                running[ex.submit(putter, it)] = it
            if running:
                fin, _ = wait(list(running), timeout=1.0, return_when=FIRST_COMPLETED)
                for f in fin:
                    it = running.pop(f)
                    key, code, err = f.result()
                    if code:
                        failed.append(key)
                        log(f"  failed {key}: {err}")
                    else:
                        bytes_win += it[0].stat().st_size
                        done_bytes += it[0].stat().st_size
            else:
                sleep(window / 3)
            now = clock()
            if now - t_win >= window:
                mbps = bytes_win * 8 / (now - t_win) / 1e6
                trace.append([round(now - t_start, 1), jobs, round(mbps, 1)])
                if todo:
                    jobs, capped = next_jobs(jobs, mbps, max_mbps, jobs_max, capped)
                t_win, bytes_win = now, 0
                open_gate = gate()
            elif not open_gate:
                sleep(window / 3)
                open_gate = gate()
    took = clock() - t_start
    if paused_since is not None:
        pauses[-1]["seconds"] = round(clock() - paused_since, 1)
    return {"objects": len(items) - len(failed), "bytes": done_bytes, "seconds": round(took, 1),
            "mbps": round(done_bytes * 8 / took / 1e6, 1) if took else None, "jobs_last": jobs,
            "jobs_max_used": max([j for _, j, _ in trace] + [jobs]), "capped": capped, "failed": failed,
            "pauses": pauses, "windows": trace}


def head_size(url, tries=4, sleep=time.sleep):
    """The object's Content-Length from a HEAD at the public URL; None when it is not there."""
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA}), timeout=30) as r:
                return int(r.headers.get("Content-Length", -1))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
        except (urllib.error.URLError, OSError, ValueError):
            pass
        sleep(2 * (k + 1))
    return None


def verify(items, head, public=PUBLIC, jobs=8):
    """[(key, local bytes, remote bytes)] for every object whose R2 size differs from the local file's."""
    def one(it):
        p, key = it[0], it[1]
        want = p.stat().st_size
        got = head(f"{public}/{key}")
        return key, want, got
    with ThreadPoolExecutor(jobs) as ex:
        return [r for r in ex.map(one, items) if r[1] != r[2]]


# ---------------------------------------------------------------- the shift

def receipt_of(run, index, ps, enc, up, items, checked, now_iso):
    total = sum(it[0].stat().st_size for it in items)
    rungs = {}
    for it in items:
        top = it[1].split("/")[2] if it[1].count("/") >= 3 else "top"
        r = rungs.setdefault(top, {"objects": 0, "bytes": 0})
        r["objects"] += 1
        r["bytes"] += it[0].stat().st_size
    sh = index["shift"]
    first, last = ps[0]["wall"], ps[-1]["wall"] + ps[-1]["seconds"]
    return {
        "run": run, "prefix": f"{run}/full/", "objects": len(items), "bytes": total, "by_folder": rungs,
        "masters": [{"name": p["name"], "folder": p["folder"], "from_s": p["s_in"], "seconds": p["seconds"]}
                    for p in ps],
        "duration_s": round(sum(p["seconds"] for p in ps), 1),
        "covered": {"from": iso(first), "to": iso(last)},
        "shift": {"start": iso(sh["start"]), "end": iso(sh["end"]), "seconds": round(sh["end"] - sh["start"], 1)},
        "gaps": [[iso(a), iso(b)] for a, b in index["gaps"]],
        "encode": enc["rungs"], "upload": {k: v for k, v in up.items() if k != "windows"},
        "verified": {"checked": checked, "ok": True, "how": "HEAD at the public URL, Content-Length = local size"},
        "playback": playback(run), "time": now_iso,
    }


def iso(t):
    return datetime.datetime.fromtimestamp(t, hls.PACIFIC).isoformat(timespec="seconds")


def playback(run):
    return (f"{PLAYER}?src=../{run}/full/master.m3u8&data=../{run}/full/shift.json"
            f"&vtt=../{run}/full/captions.vtt")


def mark_status(path, run, receipt_rel):
    """RUN's row in the status table: the renditions column reads complete with the receipt."""
    p = Path(path)
    if not p.exists():
        return False
    text = p.read_text()
    new, n = re.subn(rf"^\| {re.escape(run)} \| [^|]*\|", f"| {run} | complete ({receipt_rel}) |", text,
                     count=1, flags=re.M)
    if n:
        p.write_text(new)
    return bool(n)


def remove_local(folder, root):
    folder, root = Path(folder).resolve(), Path(root).resolve()
    if folder.parent != root:
        raise SystemExit(f"{folder} is not a shift folder under {root}")
    bad = [p for p in folder.rglob("*") if p.suffix.lower() in r2_put.MASTER_SUFFIXES]
    if bad:
        raise SystemExit(f"{folder} holds a recording ({bad[0]}); not removed")
    shutil.rmtree(folder)


def free_gb(path):
    return shutil.disk_usage(path).free / 1e9


def do_shift(run, a, putter, head, health, runner=subprocess.run, clock=time.time, log=print, free=free_gb):
    receipt_path = Path(a.receipts) / f"{run}.json"
    if receipt_path.exists():
        log(f"{run}: receipt {receipt_path} exists; skipped")
        return json.loads(receipt_path.read_text())
    folder = Path(a.hls_root) / run
    work, out = folder / "work", folder / "full"
    t_shift = clock()
    index = build_index(run, work, a, runner)
    ps = parts(index)
    if not ps:
        raise SystemExit(f"{run}: no recording covers the shift")
    secs = sum(p["seconds"] for p in ps)
    est_gb = secs * EST_MBPS / 8 / 1e3
    log(f"{run}: {len(ps)} part(s), {secs / 3600:.2f} h: " +
        "; ".join(f"{p['folder']}/{p['name']} from {p['s_in']} s for {p['seconds']} s" for p in ps))
    if a.dry_run:
        for i, p in enumerate(ps):
            for rung in RUNGS:
                log("  " + " ".join(hls.encode_cmd(p["file"], p["s_in"], p["seconds"], rung,
                                                  out / str(rung) / part_dir(i))))
        return None
    if est_gb > a.max_local_gb:
        raise SystemExit(f"{run}: up to {est_gb:.1f} GB, over --max-local-gb {a.max_local_gb}")
    enc_path = out / "encode.json"
    if enc_path.exists():
        enc = json.loads(enc_path.read_text())
        log(f"{run}: encode.json present; the encode is reused")
    else:
        if out.exists():
            shutil.rmtree(out)  # a half-made encode
        if free(a.hls_root) < est_gb + a.margin_gb:
            raise SystemExit(f"{run}: {free(a.hls_root):.0f} GB free, the shift needs up to {est_gb:.1f} GB "
                             f"+ {a.margin_gb} GB margin")
        enc = encode(index, ps, out, runner, clock, log)
    items = r2_put.plan(out, f"{run}/full")
    if (folder / "upload.started").exists():
        redo = {k for k, _, _ in verify(items, head)}
        log(f"{run}: an earlier upload: {len(items) - len(redo)} of {len(items)} objects already there")
        todo = [it for it in items if it[1] in redo]
    else:
        todo = items
    (folder / "upload.started").write_text(iso(clock()))
    log(f"{run}: uploading {len(todo)} objects, {sum(it[0].stat().st_size for it in todo) / 1e9:.2f} GB")
    up = upload(todo, putter, a.max_mbps, a.jobs, a.jobs_max, a.window, health, clock, log=log)
    log(f"{run}: upload {up['objects']} objects in {up['seconds']} s, {up['mbps']} Mbit/s, jobs {up['jobs_last']}"
        f" (max {up['jobs_max_used']}), {len(up['pauses'])} pause(s)")
    for attempt in range(2):
        bad = verify(items, head)
        if not bad:
            break
        log(f"{run}: {len(bad)} object(s) missing or a different size; putting them again")
        again = [it for it in items if it[1] in {k for k, _, _ in bad}]
        upload(again, putter, a.max_mbps, min(a.jobs, 4), a.jobs_max, a.window, health, clock, log=log)
    else:
        bad = verify(items, head)
    if bad:
        raise SystemExit(f"{run}: {len(bad)} object(s) still differ in R2 (first {bad[0]}); {folder} kept")
    rec = receipt_of(run, index, ps, enc, up, items, len(items), iso(clock()))
    rec["shift_seconds_total"] = round(clock() - t_shift, 1)
    rec_file = folder / "receipt.json"
    rec_file.write_text(json.dumps(rec, indent=1))
    item = (rec_file, f"{run}/full/receipt.json", r2_put.TYPES[".json"], r2_put.SHORT)
    key, code, err = putter(item)
    if code or verify([item], head):
        raise SystemExit(f"{run}: receipt.json did not go up ({err}); {folder} kept")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(rec, indent=1))
    remove_local(folder, a.hls_root)
    if not mark_status(a.status, run, f"r2-receipts/{run}.json"):
        log(f"{run}: no row for it in {a.status}")
    log(f"{run}: complete; {rec['objects']} objects, {rec['bytes'] / 1e9:.2f} GB; {playback(run)}")
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--shifts", help="e.g. 2-69")
    ap.add_argument("--hls-root", default=str(HLS_ROOT))
    ap.add_argument("--sources", nargs="+", default=[str(s) for s in SOURCES])
    ap.add_argument("--runs-dir", default=str(MAIN / "runs"))
    ap.add_argument("--logs-dir", default=str(MAIN / "tools" / "stream" / "logs"))
    ap.add_argument("--calibration", default=str(MAIN / "runs" / "archive" / "calibration.json"))
    ap.add_argument("--receipts", default=str(OPERATOR / "r2-receipts"))
    ap.add_argument("--status", default=str(OPERATOR / "r2-status-d25.md"))
    ap.add_argument("--bucket", default="pog-archive")
    ap.add_argument("--max-mbps", type=float, default=150.0)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--jobs-max", type=int, default=16)
    ap.add_argument("--window", type=float, default=30.0)
    ap.add_argument("--max-local-gb", type=float, default=25.0)
    ap.add_argument("--margin-gb", type=float, default=10.0)
    ap.add_argument("--no-health", action="store_true", help="do not read the stream's status")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    runs = a.runs + shifts_arg(a.shifts)
    if not runs:
        ap.error("name a shift")
    Path(a.hls_root).mkdir(parents=True, exist_ok=True)
    health = None if a.no_health else Health(obs_status).check

    def putter(item):
        return r2_put.put(a.bucket, item, nice=10)

    for run in runs:
        do_shift(run, a, putter, head_size, health)


if __name__ == "__main__":
    main()
