#!/usr/bin/env python3
"""tools/obs.py stats (d28 batch318 OC: a camera's surface switch, OBS's frames and the game's ticks each second), on a
fake OBS client and clock: python3 tools/test_obs_stats.py"""
import json, os, sys, tempfile, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["POG_TEST"] = "1"
try:
    import obs
except ImportError as e:  # no obsws_python in this python: the venv's runs it
    print(f"obs_stats: skipped ({e})")
    sys.exit(0)


class Fake:
    def __init__(self):
        self.n = 0

    def get_stats(self):
        self.n += 1
        return types.SimpleNamespace(active_fps=30.0, render_total_frames=30 * self.n, render_skipped_frames=self.n // 3,
                                     output_skipped_frames=0, average_frame_render_time=1.75)


def main():
    clock = [1000.0]
    import time as T
    saved = T.time
    T.time = lambda: clock[0]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "s.jsonl")
            rows = obs.stats(Fake(), 3.5, out=out, sleep=lambda s: clock.__setitem__(0, clock[0] + 1.0))
            assert len(rows) == 4 and rows[1]["d_rendered"] == 30 and rows[2]["d_render_skipped"] == 1, rows
            assert "tick" not in rows[0] and len(open(out).read().splitlines()) == 4
            assert json.loads(open(out).read().splitlines()[2])["frame_ms"] == 1.75
    finally:
        T.time = saved
    print("obs_stats: ok (per-second deltas, rows appended; no world: no tick read)")


if __name__ == "__main__":
    main()
