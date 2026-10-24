#!/usr/bin/env python3
"""The page's timed clips (static/audio.js, d23 batch128 CK1): tour_audio_selftest.mjs in Node (a fake DOM, WebAudio
and event stream; no service). A clip with `at` starts at that moment and reports started_at, an agent line that
would still play then waits for it, one that fits plays first, a cancelled clip never plays, one voice at a time.
Skipped without node. Offline: python3 tools/stream/test_touraudio.py
"""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

if __name__ == "__main__":
    node = shutil.which("node")
    if not node:
        print("test_touraudio: skipped (no node)")
        sys.exit(0)
    for attempt in (1, 2):  # real timers: a loaded machine gets one more try
        r = subprocess.run([node, os.path.join(HERE, "tour_audio_selftest.mjs")], capture_output=True, text=True,
                           timeout=60)
        if r.returncode == 0:
            break
    print(r.stdout[-2000:])
    assert r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]
    print("test_touraudio: all ok")
