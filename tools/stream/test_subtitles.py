#!/usr/bin/env python3
"""The narration as timed captions (subtitles.py, d23 batch128 CK4). Offline: python3 tools/stream/test_subtitles.py

1. Pieces at punctuation ("27,400" kept whole), syllables (numbers by digits, a silent e).
2. Timing: each boundary on the nearest pause in order (within 1.2 s), the lead-in and tail silence trimmed, none
   found: the estimate; captions grouped up to 84 characters, a sentence's end closing one; a long clause cut at
   words; each caption up to the next.
3. pauses(): ffmpeg silencedetect on a made clip with known silences (skipped without ffmpeg).
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import subtitles as S  # noqa: E402

TEXT = "This is where it started. Shift one, raw ore, burner drills and a handful of belts."


def text_parts():
    assert S.pieces(TEXT) == ["This is where it started.", "Shift one,", "raw ore,", "burner drills and a handful of belts."]
    assert S.pieces("It stands at 27,400 rockets, and counting.") == ["It stands at 27,400 rockets,", "and counting."]
    assert S.pieces("A wall — then a gate") == ["A wall —", "then a gate"]
    assert S.syllables("started") == 2 and S.syllables("the") == 1 and S.syllables("27,400") == 5
    assert S.syllables("make") == 1 and S.syllables("table") == 2


def timing():
    # the narrator's pauses after "started." (1.3-1.76), "one," (2.54-2.94), "ore," (3.73-4.05); a tail at 6.25
    gaps = [(1.31, 1.76), (2.54, 2.94), (3.73, 4.05), (6.25, None)]
    caps = S.timed(TEXT, 6.7, gaps)
    assert caps == [{"t0": 0.0, "t1": 1.76, "text": "This is where it started."},
                    {"t0": 1.76, "t1": 6.55, "text": "Shift one, raw ore, burner drills and a handful of belts."}], caps
    # the pieces' own times put the second caption's start on the pause's end, not the estimate
    fine = S.timed("Alpha bravo charlie delta. Echo foxtrot golf hotel india juliet kilo lima mike november oscar.", 10,
                   [(0.0, 0.4), (2.9, 3.3)])
    assert fine[0]["t0"] == 0.4 and fine[1]["t0"] == 3.3, fine
    # no pauses found: the estimate by syllables over the clip
    est = S.timed("Tick tock tick tock. Tick tock tick tock.", 6.0)
    assert est[0]["t0"] == 0 and abs(est[1]["t0"] - 3.0) < 0.01 and est[-1]["t1"] == 6.0, est
    # a pause too far from the estimate is not taken
    far = S.timed("Tick tock tick tock. Tick tock tick tock.", 10.0, [(8.0, 8.5)])
    assert abs(far[1]["t0"] - 5.0) < 0.01, far
    # a clause over 84 characters is cut at words; captions never pass 84 and stay in order
    long = ("an extraordinarily long clause without a single comma that goes on and on across the whole screen "
            "and further still until it ends")
    caps = S.timed(long + ".", 12.0)
    assert len(caps) == 2 and all(len(c["text"]) <= S.MAX_CHARS for c in caps), caps
    assert " ".join(c["text"] for c in caps) == long + "."
    assert all(a["t1"] == b["t0"] for a, b in zip(caps, caps[1:])) and caps[0]["t0"] == 0
    assert S.timed("", 5) == [] and S.timed("x", 0) == []


def ffmpeg_pauses():
    if not shutil.which("ffmpeg"):
        print("  (no ffmpeg: pauses() skipped)")
        return
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "c.mp3")
        # 1 s of tone, 0.5 s silence, 1 s tone, 0.4 s silence
        expr = "if(lt(t,1)+between(t,1.5,2.5),0.5*sin(2*PI*220*t),0)"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"aevalsrc='{expr}':s=24000:d=2.9",
                        "-b:a", "64k", path], check=True)
        gaps = S.pauses(path)
        assert len(gaps) == 2 and abs(gaps[0][0] - 1.0) < 0.08 and abs(gaps[0][1] - 1.5) < 0.08, gaps
        assert abs(gaps[1][0] - 2.5) < 0.08, gaps
        caps = S.for_clip(path, "One two three, four five six.", 2.9)
        assert caps[0]["t0"] == 0 and abs(caps[-1]["t1"] - min(2.9, gaps[1][0] + 0.3)) < 0.05, caps
    assert S.pauses("/nowhere.mp3") == []


if __name__ == "__main__":
    for f in (text_parts, timing, ffmpeg_pauses):
        f()
        print("ok", f.__name__)
    print("test_subtitles: all ok")
