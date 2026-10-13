#!/usr/bin/env python3
"""Lua sent over RCON goes on one line (harness.one_line joins the lines), so a `--` comment inside it comments out
everything after it: shift07 15:10, a comment added to pog.SCORE_LUA made every score read fail ("'end' expected near
<eof>"): no game time, research or platforms on the stream, no scores.jsonl. python3 tools/test_lua_one_line.py"""
import os, sys
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, "stream")]
import pog, harness, live  # noqa: E402

bad = []
for mod in (pog, harness, live):
    for name, v in vars(mod).items():
        if name.isupper() and isinstance(v, str) and ("rcon.print" in v or "game." in v):
            bad += [f"{mod.__name__}.{name}: {l.strip()[:80]}" for l in v.splitlines() if "--" in l]
print("lua one-line: ok" if not bad else "FAIL: -- comments in one-line Lua:\n  " + "\n  ".join(bad))
sys.exit(1 if bad else 0)
