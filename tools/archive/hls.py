#!/usr/bin/env python3
"""An HLS sample of one shift and the data its player page reads (batch126 CI4; report-D sections 2 and 4):

    python3 tools/archive/hls.py INDEX.json --from HH:MM[:SS] --minutes 13 --out DIR [--rungs 1080,540] [--dry-run]

Writes into DIR: 1080/ and 540/ (fMP4 segments of 4 s and a playlist each), master.m3u8, captions.vtt, sample.json and
encode.json (each rung's encode time, speed against realtime and size; --dry-run prints the encodes and writes only
the data files). One encode at a time, at nice 19 (the Mac is
shared). The ladder is report-D's: 1080p30 x264 veryfast CRF 23 capped at 6 Mbit/s; 540p30 at 1.2 Mbit/s; AAC
128 kbit/s; a keyframe every 2 s with no scene cuts, so segments line up across the rungs and a seek lands within 2 s.

sample.json is the index cut to the window: t0 (the wall time of the sample's first frame), the on-air intervals,
events, voiced lines, chat and stats inside it (plus the last stats row before it, so the panel has values at 0:00).
It is published with the video, so no local paths: an event's Replay_ file keeps its name only.
Times stay wall-clock epoch seconds; the page adds t0 to the video's currentTime.
--from is Pacific time on the shift's day (a time before the shift's start is the next day's).
"""
import argparse
import datetime
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import captions  # noqa: E402
from zoneinfo import ZoneInfo  # noqa: E402

PACIFIC = ZoneInfo("America/Los_Angeles")
SEG_S = 4
RUNGS = {
    1080: {"scale": None, "video": ["-crf", "23", "-maxrate", "6M", "-bufsize", "12M"], "bandwidth": 6_500_000,
           "resolution": "1920x1080"},
    540: {"scale": "scale=960:540", "video": ["-b:v", "1200k", "-maxrate", "1500k", "-bufsize", "3000k"],
          "bandwidth": 1_500_000, "resolution": "960x540"},
}


def wall(index, hhmm):
    """--from as epoch seconds: the shift's day, Pacific; a clock before the shift's start is the day after."""
    start = datetime.datetime.fromtimestamp(index["shift"]["start"], PACIFIC)
    parts = [int(x) for x in hhmm.split(":")] + [0]
    t = start.replace(hour=parts[0], minute=parts[1], second=parts[2], microsecond=0)
    if t < start - datetime.timedelta(minutes=1):
        t += datetime.timedelta(days=1)
    return t.timestamp()


def window(index, t_from, t_to):
    """The index cut to [t_from, t_to] for the page."""
    def inside(t):
        return t_from <= t <= t_to
    stats = index["stats"]
    before = [r for r in stats if r[0] < t_from][-1:]
    return {
        "shift": index["shift"], "t0": t_from, "t1": t_to,
        "onair": [r for r in index["onair"] if r[1] > t_from and r[0] < t_to],
        "layout": [r for r in index["layout"] if r[0] <= t_to][-1:] + [r for r in index["layout"] if inside(r[0])],
        "events": [{k: v for k, v in e.items() if k != "replay_file"}  # a path on the Mac: the name is kept
                   for e in index["events"] if inside(e["t"]) and e["kind"] != "note"],
        "lines": [r for r in index["lines"] if r["t"] + r["dur"] > t_from and r["t"] < t_to],
        "chat": [c for c in index["chat"] if t_from - 900 <= c["t"] <= t_to],
        "stats_cols": index["stats_cols"],
        "stats": before + [r for r in stats if inside(r[0])],
    }


def media_for(index, t_from, t_to):
    for m in index["media"]:
        if m["t0"] <= t_from and t_to <= m["t1"]:
            return m
    raise SystemExit("the window is not inside one recording")


def encode_cmd(src, s_in, seconds, rung, out_dir):
    r = RUNGS[rung]
    vf = ["-vf", r["scale"]] if r["scale"] else []
    return (["nice", "-n", "19", "ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", f"{s_in:.2f}", "-i", src,
             "-t", f"{seconds:.2f}", "-map", "0:v:0", "-map", "0:a:0?"] + vf +
            ["-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p"] + r["video"] +
            ["-g", "60", "-keyint_min", "60", "-sc_threshold", "0", "-c:a", "aac", "-b:a", "128k", "-ac", "2",
             "-f", "hls", "-hls_time", str(SEG_S), "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
             "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", str(out_dir / "seg%04d.m4s"),
             str(out_dir / "index.m3u8")])


def master(rungs):
    out = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for rung in rungs:
        r = RUNGS[rung]
        out.append(f'#EXT-X-STREAM-INF:BANDWIDTH={r["bandwidth"]},RESOLUTION={r["resolution"]},'
                   f'CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000')
        out.append(f"{rung}/index.m3u8")
    return "\n".join(out) + "\n"


def size(path):
    return sum(p.stat().st_size for p in Path(path).rglob("*") if p.is_file())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("index")
    ap.add_argument("--from", dest="start", required=True)
    ap.add_argument("--minutes", type=float, default=13)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rungs", default="1080,540")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    idx = json.load(open(a.index))
    t_from = wall(idx, a.start)
    t_to = t_from + a.minutes * 60
    m = media_for(idx, t_from, t_to)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rungs = [int(x) for x in a.rungs.split(",")]
    (out / "sample.json").write_text(json.dumps(window(idx, t_from, t_to), ensure_ascii=False, separators=(",", ":")))
    (out / "captions.vtt").write_text(captions.vtt(idx["lines"], m["t0"], t_from, t_to))
    report = {"source": m["name"], "s_in": round(t_from - m["t0"], 2), "seconds": a.minutes * 60, "rungs": {}}
    for rung in rungs:
        d = out / str(rung)
        d.mkdir(exist_ok=True)
        cmd = encode_cmd(m["file"], t_from - m["t0"], a.minutes * 60, rung, d)
        if a.dry_run:
            print(" ".join(cmd))
            continue
        t = time.time()
        subprocess.run(cmd, check=True)
        took = time.time() - t
        report["rungs"][rung] = {"encode_s": round(took, 1), "speed": round(a.minutes * 60 / took, 1),
                                 "bytes": size(d), "mbps": round(size(d) * 8 / (a.minutes * 60) / 1e6, 2)}
        print(rung, report["rungs"][rung])
    (out / "master.m3u8").write_text(master(rungs))
    if not a.dry_run:
        (out / "encode.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
