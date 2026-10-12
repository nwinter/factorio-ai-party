#!/usr/bin/env python3
"""pog.py sends its Lua as one line: a "--" comment would cut off everything after it (shake8's score)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pog

for name in dir(pog):
    value = getattr(pog, name)
    if name.endswith("_LUA") and isinstance(value, str):
        assert "--" not in value, f"{name} holds a Lua comment; pog.py flattens it to one line"
print("pog lua: ok")
