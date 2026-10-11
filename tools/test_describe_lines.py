#!/usr/bin/env python3
"""Offline checks for tools/describe-lines.py against a fake describe reply. python3 tools/test_describe_lines.py"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "describe-lines.py")

# The shape `fh call describe --format json` prints (trimmed), including an action with a `name` argument.
reply = {"id": "x", "ok": True, "tick": 1, "result": {
    "protocol": 1, "version": "0.1.0",
    "actions": {
        "craft": {"recipe": "name", "count": "1..1000"},
        "scan": {"name": "optional name or array", "radius": "1..64"},
        "inventory": {"returns": "the character inventory"},
    }}}

text = subprocess.run([sys.executable, TOOL], input=json.dumps(reply), capture_output=True, text=True,
                      check=True).stdout
data = json.loads(text)  # still one valid JSON document
assert data["protocol"] == 1 and data["version"] == "0.1.0", data
assert data["actions"]["craft"] == {"name": "craft", "args": {"recipe": "name", "count": "1..1000"}}
assert data["actions"]["scan"]["args"]["name"] == "optional name or array"


def grep(pattern):
    return [l for l in text.splitlines() if pattern in l]


# Both ways agents grep find exactly the action's own line, with its arguments on it.
for action in ("craft", "scan", "inventory"):
    for pattern in (f'"name": "{action}"', f'"{action}"'):
        hits = grep(pattern)
        assert len(hits) == 1, (pattern, hits)
        assert hits[0].lstrip().startswith(f'"{action}": {{"name": "{action}", "args": '), hits[0]
assert '"count": "1..1000"' in grep('"name": "craft"')[0]
print("describe-lines: ok")
