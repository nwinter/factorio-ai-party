#!/usr/bin/env python3
"""The offset between the Mac's log clock and a recording's own timeline, from the voiced lines (report-D section 3):

    python3 tools/archive/calibrate.py MASTER.mkv LINES.json [--t0 EPOCH] [--windows 6] [--minutes 8]

Every voiced line has a logged play start and length (runs/RUN/audio-played.jsonl, the Mac's clock). The recording
carries the same speech. For a few windows spread over the file, ffmpeg extracts mono audio at 8 kHz (input seek, so a
window costs about a second on the SSD), the loudness is taken every 0.1 s, and a 0.1 s step counts as speech when it
is 8 dB or more over the window's quiet floor (the 20th percentile over 30 s: the game's own sound). The logged
speech, as on/off steps from the named start time t0, is slid over that from -30 s to +30 s; the lag where the two
agree most is the window's offset. The fit is the median of the windows that agree (a window with too little speech,
or a peak no higher than the next distinct one, is left out), and the drift is the slope over the file.

offset > 0: the recording's first frame is later than the file name says (the event at log time t plays at
t - (t0 + offset) seconds into the file). Read-only on the master. No game reads.
"""
import argparse
import array
import json
import math
import subprocess
import sys

STEP = 0.1        # seconds per loudness step
LAG = 30.0        # the search range, seconds either way
OVER = 8.0        # dB over the quiet floor that counts as speech
FLOOR_S = 30.0    # the quiet floor's window
MIN_SPEECH = 0.04  # a window with less logged speech than this share of its steps tells nothing


def loudness(samples, rate, step=STEP):
    """dB of each step of a mono 16-bit sample array."""
    hop = int(rate * step)
    out = []
    for i in range(0, len(samples) - hop + 1, hop):
        s = 0
        for x in samples[i:i + hop]:
            s += x * x
        out.append(10 * math.log10(max(s / hop, 1)))
    return out


def speech_steps(db, step=STEP):
    """1 where a step is OVER dB above the 20th percentile of the FLOOR_S around it, else 0."""
    half = int(FLOOR_S / step / 2)
    out = []
    for i in range(len(db)):
        w = sorted(db[max(0, i - half):i + half])
        out.append(1 if db[i] - w[len(w) // 5] > OVER else 0)
    return out


def logged_steps(lines, w0, n, step=STEP):
    """On/off steps of the logged speech from file second w0: lines are (file second, seconds)."""
    ref = [0] * n
    for s, d in lines:
        a, b = int((s - w0) / step), int((s + d - w0) / step)
        for i in range(max(0, a), min(n, b)):
            ref[i] = 1
    return ref


def best_lag(ref, heard, step=STEP, lag=LAG):
    """(lag seconds, peak, next distinct peak): the shift of `heard` against `ref` where they agree most. A positive lag
    means the recording hears a line `lag` seconds after the log puts it."""
    n = len(ref)
    m1, m2 = sum(heard) / n, sum(ref) / n
    on = [i for i, v in enumerate(ref) if v]
    k = int(lag / step)
    scores = []
    for L in range(-k, k + 1):
        c = 0.0
        for i in on:
            j = i + L
            if 0 <= j < n:
                c += heard[j] - m1
        # the off steps' part of the covariance is -m2 * sum(heard - m1) over them; small and almost constant in L
        scores.append((c * (1 - m2), L * step))
    scores.sort(reverse=True)
    top = scores[0]
    second = next((s for s in scores if abs(s[1] - top[1]) > 2.0), (0.0, None))
    return round(top[1], 1), round(top[0], 2), round(second[0], 2)


def extract(master, at, seconds, rate=8000):
    """Mono 16-bit samples of `seconds` from file second `at` (ffmpeg at low priority)."""
    cmd = ["nice", "-n", "19", "ffmpeg", "-nostdin", "-v", "error", "-ss", f"{at:.2f}", "-t", f"{seconds:.2f}",
           "-i", str(master), "-vn", "-ac", "1", "-ar", str(rate), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    a = array.array("h")
    a.frombytes(raw[:len(raw) // 2 * 2])
    if sys.byteorder == "big":
        a.byteswap()
    return a


def fit(windows):
    """{offset, drift_s_per_h, used, windows}: the median offset of the windows that agree, and the slope."""
    good = [w for w in windows if w.get("ok")]
    if not good:
        return {"offset": None, "drift_s_per_h": None, "used": 0, "windows": windows}
    lags = sorted(w["lag"] for w in good)
    med = lags[len(lags) // 2] if len(lags) % 2 else (lags[len(lags) // 2 - 1] + lags[len(lags) // 2]) / 2
    keep = [w for w in good if abs(w["lag"] - med) <= 1.5]
    drift = None
    if len(keep) >= 2:
        xs, ys = [w["at"] / 3600 for w in keep], [w["lag"] for w in keep]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        den = sum((x - mx) ** 2 for x in xs)
        drift = round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den, 2) if den else None
    off = -sum(w["lag"] for w in keep) / len(keep)  # heard `lag` s after the log: the file began `lag` s sooner
    return {"offset": round(off, 1), "drift_s_per_h": -drift if drift else drift, "used": len(keep), "windows": windows}


def calibrate(master, lines, t0, duration, n_windows=6, minutes=8.0, sampler=extract):
    """Fit the offset of one recording. lines: [(log epoch start, seconds)] of the voiced lines; t0: the epoch the
    file's name gives; duration: ffprobe's. sampler(master, at, seconds) -> samples at 8 kHz (a test passes its own)."""
    span = minutes * 60
    rel = [(t - t0, d) for t, d in lines]
    windows = []
    for k in range(n_windows):
        at = max(0.0, (duration - span) * (k + 0.5) / n_windows)
        samples = sampler(master, at, span)
        heard = speech_steps(loudness(samples, 8000))
        ref = logged_steps(rel, at, len(heard))
        share = sum(ref) / max(1, len(ref))
        row = {"at": round(at, 1), "speech": round(share, 3)}
        if share < MIN_SPEECH or not heard:
            row["ok"] = False
            row["why"] = "too little logged speech"
        else:
            lag, peak, second = best_lag(ref, heard)
            row.update(lag=lag, peak=peak, next=second, ok=peak > 1.15 * max(second, 0.0))
            if not row["ok"]:
                row["why"] = "no clear peak"
        windows.append(row)
    return fit(windows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("master")
    ap.add_argument("lines", help="the index JSON (its lines and media) or a list of [epoch, seconds]")
    ap.add_argument("--t0", type=float, help="the file name's start epoch (default: the index's media row)")
    ap.add_argument("--duration", type=float)
    ap.add_argument("--windows", type=int, default=6)
    ap.add_argument("--minutes", type=float, default=8.0)
    a = ap.parse_args()
    data = json.load(open(a.lines))
    t0, dur = a.t0, a.duration
    if isinstance(data, dict):
        lines = [(r["t"], r["dur"]) for r in data.get("lines", []) if r.get("dur")]
        media = next((m for m in data.get("media", []) if m["file"] == a.master), None)
        if media:
            t0 = t0 or media["named_t0"]
            dur = dur or media["duration"]
    else:
        lines = [tuple(x) for x in data]
    print(json.dumps(calibrate(a.master, lines, t0, dur, a.windows, a.minutes), indent=1))


if __name__ == "__main__":
    main()
