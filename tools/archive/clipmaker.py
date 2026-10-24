#!/usr/bin/env python3
"""The clip library's clip maker: a catalogue entry (or a time range) cut from its master, put on R2, its URL back
(batch129 CL2):

    python3 tools/archive/clipmaker.py ID [--frame hole|full] [--no-upload] [--force]       # e.g. s48-death-002
    python3 tools/archive/clipmaker.py --range "2026-10-20 18:25:20" "2026-10-20 18:26:10" [--frame ...]
    python3 tools/archive/clipmaker.py --made                                                # what is on R2

Prints one JSON object: {id, url, vtt, meta, seconds, width, height, bytes, cached, encode_s, speed, caption,
title}. The same id again returns the cached clip without an encode (DATA/clips/made.json), unless --force or the
entry's in and out points changed.

The cut: H.264 (x264 veryfast, CRF 23, high profile, yuv420p, a keyframe every 2 s) with the program's sound (AAC 128
kbit/s), +faststart, at nice 19; one encode at a time on this Mac (a lock file, DATA/clips/encode.lock: a second
caller waits). --frame hole (the default) crops the program's camera column (HOLE: x 24, y 24, 1208x1032 of the
1920x1080 program, the overlay's main camera since 10-12: the game view with its bottom bar and toasts, without the
sidebar's cards and chat), so it fills today's camera hole pixel for pixel; --frame full keeps the whole program frame
(refused for an entry flagged for a hidden viewer's chat on screen).

R2 (bucket pog-archive, public at PUBLIC): clips/ID.mp4 (clips/ID-full.mp4 for the full frame), clips/ID.vtt (the
voiced lines as captions, from 0 at the clip's start) and clips/ID.json (title, caption "from shift 48, Oct 20", when,
seconds, size, frame). Masters never go to R2. A clip that would take the bucket over BUDGET_BYTES is refused.

A range id is s48-t182520-50s (shift, Pacific start, length). DATA as in tools/archive/catalogue.py.
"""
import argparse
import fcntl
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import captions  # noqa: E402
import catalogue  # noqa: E402
import r2_put  # noqa: E402

PUBLIC = "https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev"
BUCKET = "pog-archive"
PREFIX = "clips"
HOLE = (24, 24, 1208, 1032)  # x, y, w, h of the camera column in the program (tools/stream/static/layout.json)
CRF = 23
BUDGET_BYTES = 19e9  # the operator's ~20 GB for now
CLIP_CACHE = "public, max-age=86400"  # a day: a re-cut of the same id replaces it
SIZE_RE = re.compile(r"bucket_size:\s*([\d.]+)\s*(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)")
UNITS = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3,
         "TiB": 1024 ** 4}


def spec_entry(e, frame):
    """What to cut for a catalogue entry."""
    if "file" not in e:
        raise SystemExit(f"{e['id']}: no footage (a gap in the recording)")
    if frame == "full" and e.get("hidden_chat"):
        raise SystemExit(f"{e['id']}: a hidden viewer's chat was on screen; use --frame hole")
    return {"id": e["id"], "run": e["run"], "shift": e["shift"], "kind": e["kind"], "title": e["title"],
            "caption": e["caption"], "when": e["when"], "t_in": e["t_in"], "t_out": e["t_out"],
            "file": e["file"], "s_in": e["s_in"], "seconds": e["seconds"], "frame": frame}


def spec_range(cat, t_from, t_to, frame):
    """What to cut for a time range: inside one recording, in a catalogued shift."""
    if not 1 <= t_to - t_from <= 600:
        raise SystemExit("a range is 1 s to 10 minutes")
    m = next((m for m in cat["media"] if m["t0"] <= t_from and t_to <= m["t1"]), None)
    if not m:
        raise SystemExit("the range is not inside one recording")
    s = next((s for s in cat["shifts"] if s["start"] - 600 <= t_from <= s["end"] + 600), None)
    if not s:
        raise SystemExit("the range is not in a catalogued shift")
    d = catalogue.local(t_from)
    rid = f"s{s['shift']:02d}-t{d:%H%M%S}-{round(t_to - t_from)}s"
    return {"id": rid, "run": s["run"], "shift": s["shift"], "kind": "range", "title": None,
            "caption": f"from shift {s['shift']}, {d:%b} {d.day}", "when": catalogue.when(t_from), "t_in": t_from,
            "t_out": t_to, "file": m["file"], "s_in": round(t_from - m["t0"], 2), "seconds": round(t_to - t_from, 2),
            "frame": frame}


def key_id(spec):
    return spec["id"] + ("-full" if spec["frame"] == "full" else "")


def cut_cmd(spec, out, crf=CRF):
    """ffmpeg at nice 19: input seek (decodes from the keyframe before s_in), re-encoded, cropped for the hole."""
    vf = ["-vf", "crop={2}:{3}:{0}:{1}".format(*HOLE)] if spec["frame"] == "hole" else []
    return (["nice", "-n", "19", "ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", f"{spec['s_in']:.2f}",
             "-i", spec["file"], "-t", f"{spec['seconds']:.2f}", "-map", "0:v:0", "-map", "0:a:0?"] + vf +
            ["-c:v", "libx264", "-preset", "veryfast", "-crf", str(crf), "-profile:v", "high", "-pix_fmt", "yuv420p",
             "-g", "60", "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart", str(out)])


def size_of(frame):
    return (HOLE[2], HOLE[3]) if frame == "hole" else (1920, 1080)


def r2_usage(run=subprocess.run):
    """The bucket's size in bytes from wrangler (it can lag a few minutes), or None."""
    try:
        r = run(["npx", "wrangler", "r2", "bucket", "info", BUCKET], cwd=r2_put.REPO / "site" / "worker",
                capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = SIZE_RE.search(r.stdout or "")
    return float(m.group(1)) * UNITS[m.group(2)] if m else None


class Library:
    """made.json and the encode lock under DATA/clips."""

    def __init__(self, data):
        self.dir = Path(data) / "clips"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.made_path = self.dir / "made.json"

    def made(self):
        try:
            return json.loads(self.made_path.read_text())
        except (OSError, ValueError):
            return {}

    def record(self, k, row):
        m = self.made()
        m[k] = row
        tmp = self.made_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(m, indent=1, ensure_ascii=False))
        tmp.replace(self.made_path)

    def lock(self):
        f = open(self.dir / "encode.lock", "w")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another encode is running; waiting", file=sys.stderr)
            fcntl.flock(f, fcntl.LOCK_EX)
        return f


def captions_for(data, spec):
    path = Path(data) / "shifts" / f"{spec['run']}-index.json"
    idx = json.loads(path.read_text())
    return captions.vtt(idx["lines"], 0, spec["t_in"], spec["t_out"])


def make(spec, data, upload=True, force=False, runner=subprocess.run, putter=None, usage=r2_usage):
    """Cut, caption and upload one clip (or return the cached one). putter(bucket, (path, key, type, cache)) ->
    (key, code, err) is r2_put.put by default."""
    lib = Library(data)
    k = key_id(spec)
    old = lib.made().get(k)
    same = old and abs(old["t_in"] - spec["t_in"]) < 0.05 and abs(old["t_out"] - spec["t_out"]) < 0.05
    if same and not force and (old.get("url") or not upload):
        return dict(old, cached=True)
    putter = putter or (lambda bucket, item: r2_put.put(bucket, item))
    with lib.lock():
        old = lib.made().get(k)  # another caller may have made it while this one waited
        same = old and abs(old["t_in"] - spec["t_in"]) < 0.05 and abs(old["t_out"] - spec["t_out"]) < 0.05
        if same and not force and (old.get("url") or not upload):
            return dict(old, cached=True)
        mp4 = lib.dir / f"{k}.mp4"
        t = time.time()
        runner(cut_cmd(spec, mp4), check=True)
        took = time.time() - t
        w, h = size_of(spec["frame"])
        nbytes = mp4.stat().st_size
        vtt = lib.dir / f"{spec['id']}.vtt"
        vtt.write_text(captions_for(data, spec))
        meta = {"id": spec["id"], "title": spec["title"], "caption": spec["caption"], "when": spec["when"],
                "shift": spec["shift"], "kind": spec["kind"], "seconds": spec["seconds"], "frame": spec["frame"],
                "width": w, "height": h, "source": "program recording", "vtt": f"{spec['id']}.vtt"}
        meta_path = lib.dir / f"{spec['id']}.json"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1))
        row = dict(meta, t_in=spec["t_in"], t_out=spec["t_out"], bytes=nbytes, encode_s=round(took, 1),
                   speed=round(spec["seconds"] / max(took, 0.01), 1), made=round(time.time()), file=str(mp4),
                   url=None, vtt_url=None, meta_url=None)
        if upload:
            used = usage()
            known = sum(r.get("bytes", 0) for kk, r in lib.made().items() if r.get("url") and kk != k)
            if max(used or 0, known) + nbytes > BUDGET_BYTES:
                lib.record(k, row)
                raise SystemExit(f"R2 is at {max(used or 0, known) / 1e9:.1f} GB: this clip would pass "
                                 f"{BUDGET_BYTES / 1e9:.0f} GB")
            items = [(mp4, f"{PREFIX}/{k}.mp4", "video/mp4", CLIP_CACHE),
                     (vtt, f"{PREFIX}/{spec['id']}.vtt", r2_put.TYPES[".vtt"], CLIP_CACHE),
                     (meta_path, f"{PREFIX}/{spec['id']}.json", "application/json", r2_put.SHORT)]
            for item in items:
                key, code, err = putter(BUCKET, item)
                if code:
                    lib.record(k, row)
                    raise SystemExit(f"upload of {key} failed: {err}")
            row.update(url=f"{PUBLIC}/{PREFIX}/{k}.mp4", vtt_url=f"{PUBLIC}/{PREFIX}/{spec['id']}.vtt",
                       meta_url=f"{PUBLIC}/{PREFIX}/{spec['id']}.json")
        lib.record(k, row)
        return dict(row, cached=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id", nargs="?")
    ap.add_argument("--range", nargs=2, metavar=("FROM", "TO"))
    ap.add_argument("--frame", choices=("hole", "full"), default="hole")
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--made", action="store_true")
    ap.add_argument("--data", default=str(catalogue.DEFAULT_DATA))
    a = ap.parse_args()
    if a.made:
        made = Library(a.data).made()
        for k, r in sorted(made.items(), key=lambda kv: kv[1]["made"]):
            print(f"{k:<34} {r['seconds']:>5.0f} s {r['bytes'] / 1e6:>6.1f} MB {r['speed']:>5.1f}x  {r.get('url')}")
        on = [r for r in made.values() if r.get("url")]
        print(f"{len(on)} clips on R2, {sum(r['bytes'] for r in on) / 1e6:.0f} MB")
        return
    cat = catalogue.load(a.data)
    if a.range:
        spec = spec_range(cat, catalogue.parse_time(a.range[0]), catalogue.parse_time(a.range[1]), a.frame)
    elif a.id:
        e = next((x for x in cat["entries"] if x["id"] == a.id), None)
        if not e:
            raise SystemExit(f"{a.id}: not in the catalogue (tools/archive/catalogue.py search)")
        spec = spec_entry(e, a.frame)
    else:
        raise SystemExit("give a clip id or --range")
    out = make(spec, a.data, upload=not a.no_upload, force=a.force)
    print(json.dumps({k: out.get(k) for k in ("id", "url", "vtt_url", "meta_url", "seconds", "width", "height",
                                              "bytes", "cached", "encode_s", "speed", "caption", "title")},
                     ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
