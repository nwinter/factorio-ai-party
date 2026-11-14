"""Offline checks for the private performance collectors; never connect to a game."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import load_bench
import standin_load


class BenchTests(unittest.TestCase):
    def test_truncated_or_interrupted_profiles_are_not_complete(self):
        def done(end, dropped):
            return f"agent-harness profile done from_tick=100 to_tick={end} (elapsed) keys=200 second_lines=20000 dropped={dropped}"
        self.assertTrue(load_bench.profile_completion(done(3700, 0), 100, 3700)["complete"])
        cut = load_bench.profile_completion(done(3700, 1200), 100, 3700)
        self.assertFalse(cut["complete"])
        self.assertEqual(cut["dropped_lines"], 1200)
        self.assertFalse(load_bench.profile_completion(done(1900, 0), 100, 3700)["complete"])
        self.assertFalse(load_bench.profile_completion(done(3700, 0), 101, 3700)["complete"])

    def test_ups_windows_preserve_boundaries(self):
        points = [{"from_tick": 0, "to_tick": 100, "ups": 30},
                  {"from_tick": 100, "to_tick": 700, "ups": 60},
                  {"from_tick": 700, "to_tick": 1300, "ups": 58},
                  {"from_tick": 1300, "to_tick": 1900, "ups": 61}]
        self.assertEqual(load_bench.ups_window(points, 100, 1300), {"samples": 2, "min": 58, "median": 59})
        self.assertEqual(load_bench.ups_window(points, 101, 699), {"samples": 0, "min": None, "median": None})

    def test_startup_calls_are_recorded(self):
        class Copy:
            def __init__(self, args):
                pass

            def call(self, bot, action, args):
                return {"ok": True, "tick": 42, "result": {"position": {"x": 0, "y": 0}}}, 321, 64

            def lua(self, code):
                return "3 4"

        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "load.jsonl"
            args = ["standin_load", "--port", "27475", "--password-file", "unused",
                    "--bots", "rb1,bb1", "--minutes", "0", "--out", str(out)]
            with patch.object(standin_load, "Copy", Copy), patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
                standin_load.main()
            rows = [json.loads(line) for line in out.read_text().splitlines()]
        self.assertEqual([(r["bot"], r["action"]) for r in rows],
                         [("rb1", "status"), ("rb1", "queue_repeat"), ("bb1", "status"), ("bb1", "queue_repeat")])
        self.assertTrue(all(r["phase"] == "startup" and r["ms"] == 321 and r["tick"] == 42 for r in rows))


if __name__ == "__main__":
    unittest.main()
