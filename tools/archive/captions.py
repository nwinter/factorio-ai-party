#!/usr/bin/env python3
"""WebVTT captions from the voiced lines of an archive index (batch126 CI2; report-D section 3):

    python3 tools/archive/captions.py INDEX.json [--file NAME] [--from EPOCH --to EPOCH] [--out FILE.vtt]

Every voiced line was text sent to text-to-speech, and the index carries its play start on the log clock and its
length (audio-played.jsonl joined to the caster jsonl). A cue's time is the line's start minus the recording's t0
(t0 = the file name's time + the fitted offset, tools/archive/calibrate.py), so no speech recognition is needed. A long
line becomes several cues, its time shared by characters; a cue holds at most two lines of LINE_CHARS. Speakers go in
voice tags (<v Rook>). With --from/--to the cues count from --from (an HLS sample or a clip) and only lines that
overlap the window are kept.
"""
import argparse
import json
import sys
from pathlib import Path

LINE_CHARS = 42
CUE_CHARS = 2 * LINE_CHARS


def stamp(s):
    s = max(0.0, s)
    ms = int(round(s * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def wrap(words, width=LINE_CHARS):
    lines, cur = [], ""
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}" if cur else w
    if cur:
        lines.append(cur)
    return lines


def chunks(text, size=CUE_CHARS):
    """The text in pieces of at most two wrapped lines, broken at words."""
    out, cur = [], []
    for line in wrap(text.split()):
        cur.append(line)
        if len(cur) == 2:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def cues(lines, t0, t_from=None, t_to=None):
    """[(start s, end s, speaker, [text lines])] relative to t0 (or to t_from when given)."""
    base = t_from if t_from is not None else t0
    out = []
    for r in sorted(lines, key=lambda r: r["t"]):
        text = " ".join((r.get("text") or "").split())
        if not text or not r.get("dur"):
            continue
        a, b = r["t"], r["t"] + r["dur"]
        if (t_from is not None and b <= t_from) or (t_to is not None and a >= t_to):
            continue
        parts = chunks(text)
        total = sum(len(" ".join(p)) for p in parts) or 1
        at = a
        for p in parts:
            d = r["dur"] * len(" ".join(p)) / total
            s, e = at - base, at + d - base
            at += d
            if t_from is not None and (e <= 0 or (t_to is not None and s >= t_to - base)):
                continue
            if t_to is not None:
                e = min(e, t_to - base)
            if e - max(0.0, s) < 0.5:  # a sliver at a window's edge
                continue
            out.append((max(0.0, s), e, r.get("who") or "", p))
    return out


def vtt(lines, t0, t_from=None, t_to=None):
    body = ["WEBVTT", ""]
    for i, (s, e, who, text) in enumerate(cues(lines, t0, t_from, t_to), 1):
        body.append(str(i))
        body.append(f"{stamp(s)} --> {stamp(e)}")
        first = f"<v {esc(who)}>{esc(text[0])}" if who else esc(text[0])
        body.append("\n".join([first] + [esc(x) for x in text[1:]]))
        body.append("")
    return "\n".join(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("index")
    ap.add_argument("--file", help="the recording's name (default: the first media row)")
    ap.add_argument("--from", dest="t_from", type=float)
    ap.add_argument("--to", dest="t_to", type=float)
    ap.add_argument("--out")
    a = ap.parse_args()
    idx = json.load(open(a.index))
    media = [m for m in idx["media"] if not a.file or m["name"] == a.file]
    if not media:
        sys.exit("no such recording in the index")
    text = vtt(idx["lines"], media[0]["t0"], a.t_from, a.t_to)
    if a.out:
        Path(a.out).write_text(text)
    else:
        print(text)


if __name__ == "__main__":
    main()
