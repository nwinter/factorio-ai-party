#!/usr/bin/env python3
"""The game runs Lua 5.2: the integer division `//`, bitwise operators and `goto`-less 5.3+ syntax fail to load there, while
the local test interpreter (Lua 5.5) accepts them (d18 13:07: `WATCH // 60` in drops.lua passed every test and the deploy
was refused, invalid_runtime). Scan the mod's Lua for `//` and the 5.3 bitwise operators outside comments and strings."""
import glob, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0")

def code_only(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--[[", i) or re.match(r"--\[=*\[", src[i:i+8] or ""):
            m = re.match(r"--\[(=*)\[", src[i:]); close = "]" + m.group(1) + "]"; j = src.find(close, i); i = n if j < 0 else j + len(close); continue
        if src.startswith("--", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        m = re.match(r"\[(=*)\[", src[i:i+8])
        if m:
            close = "]" + m.group(1) + "]"; j = src.find(close, i + 2); out.append(" "); i = n if j < 0 else j + len(close); continue
        if c in "'\"":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append('""'); i = j + 1; continue
        out.append(c); i += 1
    return "".join(out)

bad = []
for path in sorted(glob.glob(os.path.join(MOD, "**", "*.lua"), recursive=True)):
    code = code_only(open(path, encoding="utf-8").read())
    for ln, line in enumerate(code.split("\n"), 1):
        if "//" in line or re.search(r"[^~=<>]~[^=]|<<|>>|(?<![.\w])&(?!&)", line):
            bad.append(f"{os.path.relpath(path, ROOT)}:{ln}: {line.strip()[:100]}")
assert not bad, "Lua 5.3+ syntax the game (Lua 5.2) cannot load:\n" + "\n".join(bad[:20])
print("lua 5.2 syntax: ok")
