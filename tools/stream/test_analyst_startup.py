#!/usr/bin/env python3
"""Analyst entry-point imports, with replay data and an ephemeral local /ask listener; no live services or model."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def entry_point():
    with tempfile.TemporaryDirectory() as tmp:
        run = Path(tmp)
        (run / "scores.jsonl").write_text(json.dumps({"score": {"tick": 3600, "produced": {}}}) + "\n")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        # start-team invokes this script from the repository root, with --ask-port
        # and --viewer-questions. Replay/digest-only exit before any live read,
        # viewer polling, or model call; --help would miss the failing imports.
        env = dict(os.environ, POG_TEST="1", POG_ANALYST_PAST_RUNS="0", POG_KB="base-2.0.77")
        result = subprocess.run(
            [sys.executable, "tools/stream/analyst.py", "--world", "n", "--bot", "startup-test",
             "--run-dir", tmp, "--replay", tmp, "--ask-port", str(port), "--viewer-questions",
             "--digest-only", "--dry-run"],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert f"[ask] answering viewer questions on http://127.0.0.1:{port}/ask" in result.stdout, result.stdout
        assert "## Current game" in result.stdout, result.stdout


def distinct_modules():
    # Both import orders in fresh interpreters also cover sys.modules caching.
    for first in ("freshness", "commentary_freshness"):
        code = """
import importlib, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path[:0] = [str(root / 'tools'), str(root / 'tools/stream')]
importlib.import_module(sys.argv[2])
import freshness, commentary_freshness
assert Path(freshness.__file__).resolve() == root / 'tools/freshness.py'
assert Path(commentary_freshness.__file__).resolve() == root / 'tools/stream/commentary_freshness.py'
assert callable(freshness.ages)
assert commentary_freshness.stamp({'tick': 6000}, now=1000)['expires'] == 1300
from analyst_board import AnalystBoard
board = AnalystBoard()
board.post({'headline': 'A recorded fact', 'talking_points': []}, now=1000)
assert board.public(now=1001)['headline'] == 'A recorded fact'
"""
        result = subprocess.run([sys.executable, "-c", code, str(ROOT), first], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    entry_point()
    distinct_modules()
    print("analyst startup: entry script, replay digest, /ask imports, and both freshness import orders pass")
