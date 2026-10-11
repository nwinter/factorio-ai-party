#!/usr/bin/env python3
"""Rewrite `fh call describe --format json` (stdin) as JSON with one action per line, so `grep NAME describe.json`
returns that action's arguments instead of the whole one-line file (shake1: 31K characters per grep).

Each action's line also carries `"name": "ACTION"`: agents grep for that form (shake2: Grok searched
`"name": "craft"`, found nothing in the `"craft": {...}` lines, concluded the file was missing and tried to
regenerate it). The arguments sit under "args" because some actions take an argument called `name`."""
import json
import sys


def lines(reply):
    d = reply.get("result", reply)
    d = dict(d)
    actions = d.pop("actions", {})
    out = [f"  {json.dumps(k)}: {json.dumps(v)}," for k, v in d.items()]
    out.append('  "actions": {')
    out.append(",\n".join(f"    {json.dumps(k)}: {json.dumps({'name': k, 'args': v})}" for k, v in actions.items()))
    out.append("  }")
    return "{\n" + "\n".join(out) + "\n}"


if __name__ == "__main__":
    print(lines(json.load(sys.stdin)))
