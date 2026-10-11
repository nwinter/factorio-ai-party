#!/usr/bin/env python3
"""Rewrite `fh call describe --format json` (stdin) as JSON with one action per line, so `grep NAME describe.json`
returns that action's arguments instead of the whole one-line file (shake1: 31K characters per grep)."""
import json
import sys

d = json.load(sys.stdin)
d = d.get("result", d)
actions = d.pop("actions", {})
lines = [f"  {json.dumps(k)}: {json.dumps(v)}," for k, v in d.items()]
lines.append('  "actions": {')
lines.append(",\n".join(f"    {json.dumps(k)}: {json.dumps(v)}" for k, v in actions.items()))
lines.append("  }")
print("{\n" + "\n".join(lines) + "\n}")
