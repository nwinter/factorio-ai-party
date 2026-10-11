#!/usr/bin/env python3
"""Offline tests for tools/permit.py: python3 tools/test_permit.py"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from permit import decide  # noqa: E402

ALLOW = [
    # shake2's denied copper haul (Haiku, 12 times)
    './fh call move_to --args \'{"position":{"x":-38,"y":-12}}\' --wait --wait-timeout 120000 && for x in -44 -40 -36 -32; '
    'do ./fh call transfer --args "{\\"position\\":{\\"x\\":$x,\\"y\\":-14},\\"item\\":\\"copper-plate\\"}"; done',
    'for i in 1 2 3; do ./fh sleep 90; done',
    'for a in status chat; do ./fh call $a; done',
    './fh call describe --format json > describe.json',
    './fh call status 2>&1 | grep -E "error|power"',
    './fh call chat && ./fh board',
    'while true; do ./fh call status; sleep 30; done',
    'cat ../astra/notes.md',
    'date; cat deadline.txt',
    'for x in 1 2\ndo\n  ./fh call status\ndone',
]
PASS = [
    'rm -rf notes.md',
    'for x in a b; do rm $x; done',
    './fh call status > /tmp/out.txt',
    './fh call status > ../other/notes.md',
    'echo $(cat ~/.config/pog/rcon-n.pw)',
    'cat ~/.config/pog/rcon-n.pw',
    'echo `whoami`',
    'cat > notes.md <<EOF\nhi\nEOF',
    'x=1; ./fh call status',
    './fh call status; curl http://example.com',
    'echo ${HOME:-x}',
    'cd .. && ./fh call status',
    'python3 /Users/owner/x.py',
]

bad = [c for c in ALLOW if not decide(c)] + [c for c in PASS if decide(c)]
for c in bad:
    print("WRONG:", repr(c))
print("ok" if not bad else f"{len(bad)} wrong")
sys.exit(1 if bad else 0)
