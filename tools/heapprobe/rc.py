#!/usr/bin/env python3
"""rc.py WORLD FILE.lua|-e CODE [--n] [--timeout S] [--plain]: one /silent-command (mod context unless --plain)."""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pog
a = sys.argv[1:]
world = a.pop(0)
code = a.pop(1) if a[0] == "-e" else open(a[0]).read()
if a[0] == "-e": a.pop(0)
else: a.pop(0)
if world == "n" and "--n" not in a: sys.exit("world n needs --n")
timeout = float(a[a.index("--timeout") + 1]) if "--timeout" in a else 60
lines = [l.strip() for l in code.splitlines()]
assert not any(l.startswith("--") or " --" in l for l in lines), "no -- comments"
one = " ".join(l for l in lines if l)
pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
r = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS[world], pw, timeout=timeout)
t = time.time()
out = r.command(("/silent-command " if "--plain" in a else "/silent-command __agent-harness__ ") + one)
sys.stdout.write(out + ("" if out.endswith("\n") else "\n"))
sys.stderr.write(f"[rc {world} {time.time()-t:.3f}s wall]\n")
