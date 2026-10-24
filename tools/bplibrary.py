#!/usr/bin/env python3
"""The team blueprint library's copy in the run (blueprints.lua in the harness: blueprint_save and friends).

    bplibrary.py --world W --run-dir runs/RUN once                 one pass
    bplibrary.py --world W --run-dir runs/RUN watch [--interval 60]
    bplibrary.py --world W show                                     the entries as the operator read gives them

The library lives in the save (storage), so it goes on with the world from shift to shift. Each pass is operator
reads, `blueprint_library`: storage only, no entity scan. On world n no command may take over 10 ms. Every entry's facts
in one read were 15.3 ms there (158 entries, 133 KB, tick 56169756), so a pass first reads the revision alone
(`{probe: true}`), and only when it moved since the last pass (or a file is missing here) reads the facts in pages of
PAGE entries by name (`{since, limit, after}`; next_after names a page's last entry while more follow), with the blueprint string of
each entry changed since the revision the run dir last saw, 400 KB of strings a page at most (the JSON of 7.6 MB of
strings took 21.8 ms on the private copy, 416 KB 1.0 ms). A page read while the revision moves ends the pass unwritten;
the next pass reads again. Files in RUN/blueprints/: NAME.txt (the entry's blueprint string), index.json (every
entry's facts, the library revision and the game tick; written once, after the last page), .mirror.json (the revision this copy holds). A .txt whose entry is gone from the
library moves to deleted/. A new run dir (a resumed shift) starts at no revision and so gets every string.
"""
import argparse
import json
import os
import re
import sys
import time
import uuid

sys.dont_write_bytecode = True  # tools/__pycache__ is tracked in git; do not rewrite it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stream.harness import Harness, lua_string  # noqa: E402

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,39}")


class Game:
    """RCON to one world: the harness's operator requests."""

    def __init__(self, world):
        self.harness = Harness(world)

    def operator(self, action, args=None):
        req = {"id": "bplibrary-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "operator": True}
        raw = self.harness.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {})


PAGE = 24  # entries a page: pages of 32 were 2.5-4.9 ms on world n (d24 06:41, 158 entries), so 24 keeps under about 4 ms


def fetch(read, since, page=PAGE):
    """Every entry's facts, and the strings changed since `since`, page by page ({since, limit, after}). Returns the
    first page's reply with all entries, or None when the library's revision moved between pages (the next pass reads
    again). An older runtime answers the first page with the whole library (strings_after pages its strings)."""
    lib = read({"since": since, "limit": page})
    entries, reads = list(lib.get("entries") or []), 1
    if "next_after" not in lib and "strings_after" in lib:
        # (d20 batch59 U2) the older read: strings_after names the last entry whose string came.
        after = lib.get("strings_after")
        while isinstance(after, str) and reads < 1000:
            more = read({"since": since, "after": after})
            reads += 1
            got = {e.get("name"): e["string"] for e in more.get("entries") or [] if isinstance(e, dict) and isinstance(e.get("string"), str)}
            for e in entries:
                if isinstance(e, dict) and e.get("name") in got:
                    e["string"] = got[e["name"]]
            nxt = more.get("strings_after")
            after = nxt if isinstance(nxt, str) and nxt > after else None
        return dict(lib, entries=entries, reads=reads)
    after = lib.get("next_after")
    while isinstance(after, str) and reads < 1000:
        more = read({"since": since, "limit": page, "after": after})
        reads += 1
        if more.get("revision") != lib.get("revision"):
            return None
        entries += more.get("entries") or []
        nxt = more.get("next_after")
        after = nxt if isinstance(nxt, str) and nxt > after else None
    return dict(lib, entries=entries, reads=reads)


def mirror(read, run_dir, out=sys.stdout, page=PAGE):
    """One pass: read the library (read(args) -> the operator reply) into RUN/blueprints/. Returns what changed.
    (d24 batch147 PS1) a pass first reads the revision alone ({probe: true}); the facts and strings follow only when it
    moved since the last pass or a file is missing here."""
    folder = os.path.join(run_dir, "blueprints")
    os.makedirs(folder, exist_ok=True)
    state_path = os.path.join(folder, ".mirror.json")
    try:
        state = json.load(open(state_path))
    except (OSError, ValueError):
        state = {}
    since = state.get("revision", -1)
    probe = read({"probe": True, "since": since})
    if "entries" in probe:  # an older runtime: the whole read
        lib = fetch(lambda args: probe if args.get("limit") and "after" not in args else read(args), since, page)
        lib["reads"] -= 1  # the probe was its first read
    else:
        try:
            held = [e.get("name") for e in json.load(open(os.path.join(folder, "index.json"))).get("entries") or []]
        except (OSError, ValueError, AttributeError):
            held = None
        complete = held is not None and all(os.path.exists(os.path.join(folder, f"{n}.txt")) for n in held if NAME.fullmatch(str(n)))
        if since != -1 and complete and probe.get("revision") == state.get("seen"):
            return {"written": [], "moved": [], "entries": probe.get("count"), "revision": probe.get("revision"), "reads": 1}
        if not complete:
            since = -1
        lib = fetch(read, since, page)
        if lib is None:
            print(f"{time.strftime('%H:%M:%S')} the library changed during the read; the next pass reads it again", file=out, flush=True)
            return {"written": [], "moved": [], "entries": None, "revision": None, "reads": None, "retry": True}
    entries = [e for e in lib.get("entries") or [] if isinstance(e, dict) and NAME.fullmatch(str(e.get("name", "")))]
    names = {e["name"] for e in entries}
    written, moved, missing = [], [], False
    for e in entries:
        text = e.pop("string", None)
        path = os.path.join(folder, e["name"] + ".txt")
        # A string comes with each entry changed since `since`; a file missing here asks for every string next pass.
        if isinstance(text, str):
            with open(path, "w") as f:
                f.write(text + "\n")
            written.append(e["name"])
        elif not os.path.exists(path):
            missing = True
    for file in sorted(os.listdir(folder)):
        if file.endswith(".txt") and file[:-4] not in names:
            os.makedirs(os.path.join(folder, "deleted"), exist_ok=True)
            os.replace(os.path.join(folder, file), os.path.join(folder, "deleted", f"{file[:-4]}.{time.strftime('%Y%m%dT%H%M%S')}.txt"))
            moved.append(file[:-4])
    if written or moved or lib.get("revision") != state.get("seen"):
        with open(os.path.join(folder, "index.json"), "w") as f:
            json.dump({"revision": lib.get("revision"), "tick": lib.get("tick"), "written": time.strftime("%Y-%m-%dT%H:%M:%S"),
                       "entries": entries}, f, indent=1)
    state["revision"] = -1 if missing else lib.get("revision", since)
    state["seen"] = lib.get("revision")
    with open(state_path, "w") as f:
        json.dump(state, f)
    for name in written:
        print(f"{time.strftime('%H:%M:%S')} {name}.txt written", file=out, flush=True)
    for name in moved:
        print(f"{time.strftime('%H:%M:%S')} {name}.txt moved to deleted/", file=out, flush=True)
    return {"written": written, "moved": moved, "entries": len(entries), "revision": lib.get("revision"), "reads": 1 + lib.get("reads", 1)}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", required=True)
    ap.add_argument("--run-dir")
    ap.add_argument("command", choices=["once", "watch", "show"])
    ap.add_argument("--interval", type=float, default=60)
    a = ap.parse_args(argv)
    game = Game(a.world)
    if a.command == "show":
        lib = fetch(lambda args: game.operator("blueprint_library", args), 1 << 30)
        print(json.dumps(lib, indent=1) if lib else "the library changed during the read; run it again")
        return 0
    if not a.run_dir:
        ap.error(f"{a.command} needs --run-dir")
    read = lambda args: game.operator("blueprint_library", args)  # noqa: E731
    while True:
        try:
            mirror(read, a.run_dir)
        except Exception as e:  # an older runtime, a restart, a dropped connection: report and keep going
            print(f"{time.strftime('%H:%M:%S')} pass failed: {e}", file=sys.stderr, flush=True)
            if a.command == "once":
                return 1
        if a.command == "once":
            return 0
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
