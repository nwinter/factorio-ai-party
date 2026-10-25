#!/usr/bin/env python3
"""analyst.run_claude reads the claude CLI's reply in both shapes (d25 batch204): one result object, or, with "verbose"
in the route's ~/.claude.json (the personal route), the list of every message with the result row last. Before the
fix every cycle on the personal route failed with "'list' object has no attribute 'get'".
No game, no network, no CLI: python3 tools/stream/test_analyst_cli.py
"""
import json, os, sys, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import analyst  # noqa: E402

RESULT = {"type": "result", "subtype": "success", "is_error": False, "result": '{"points": []}', "num_turns": 3,
          "total_cost_usd": 0.012}


def run_with(stdout):
    real = analyst.subprocess.run
    analyst.subprocess.run = lambda *x, **k: types.SimpleNamespace(returncode=0, stdout=stdout, stderr="")
    try:
        a = types.SimpleNamespace(replay=None, world="n", surface="nauvis", bot="astra", player=None, run_dir=None,
                                  claude="claude", model="sonnet", effort=None, timeout=5)
        return analyst.run_claude(a, "digest")
    finally:
        analyst.subprocess.run = real


def main():
    text, meta = run_with(json.dumps(RESULT))
    assert text == '{"points": []}' and meta["turns"] == 3 and meta["cost_usd"] == 0.012, (text, meta)
    msgs = [{"type": "system", "subtype": "init"}, {"type": "assistant", "message": {"content": []}}, RESULT]
    text, meta = run_with(json.dumps(msgs))
    assert text == '{"points": []}' and meta["turns"] == 3, (text, meta)
    err = dict(RESULT, is_error=True, result="limit reached")
    try:
        run_with(json.dumps([{"type": "system"}, err]))
        raise AssertionError("an error row in the list should raise")
    except RuntimeError as e:
        assert "limit reached" in str(e), e
    print("analyst cli: ok (one result object, the verbose message list, an error row in the list)")


if __name__ == "__main__":
    main()
