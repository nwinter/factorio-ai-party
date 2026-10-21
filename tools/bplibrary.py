#!/usr/bin/env python3
"""The team blueprint library's copy in the run (blueprints.lua in the harness: blueprint_save and friends).

    bplibrary.py --world W --run-dir runs/RUN once                 one pass
    bplibrary.py --world W --run-dir runs/RUN watch [--interval 60]
    bplibrary.py --world W show                                     the entries as the operator read gives them

The library lives in the save (storage), so it goes on with the world from shift to shift. Each pass is an operator
read, `blueprint_library {since}`: storage only, no entity scan, so it stays well under the 20 ms a command on world n
may take. It returns every entry's facts and the blueprint string of each entry changed since the revision the run
dir last saw, about 1 MB of strings a read (the JSON of 7.6 MB took 21.8 ms on the private copy): while the reply
names `strings_after`, the pass reads on with `{since, after}`. Files in RUN/blueprints/: NAME.txt (the entry's blueprint string), index.json (every entry's facts, the
library revision and the game tick), .mirror.json (the revision this copy holds). A .txt whose entry is gone from the
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


def mirror(read, run_dir, out=sys.stdout):
    """One pass: read the library (read(since) -> the operator reply) into RUN/blueprints/. Returns what changed."""
    folder = os.path.join(run_dir, "blueprints")
    os.makedirs(folder, exist_ok=True)
    state_path = os.path.join(folder, ".mirror.json")
    try:
        state = json.load(open(state_path))
    except (OSError, ValueError):
        state = {}
    since = state.get("revision", -1)
    lib = read(since)
    entries = [e for e in lib.get("entries") or [] if isinstance(e, dict) and NAME.fullmatch(str(e.get("name", "")))]
    # (d20 batch59 U2) the strings come about 1 MB a read: strings_after names the last entry whose string came.
    after, reads = lib.get("strings_after"), 1
    while isinstance(after, str) and reads < 1000:
        more = read(since, after)
        reads += 1
        got = {e.get("name"): e["string"] for e in more.get("entries") or [] if isinstance(e, dict) and isinstance(e.get("string"), str)}
        for e in entries:
            if e["name"] in got:
                e["string"] = got[e["name"]]
        nxt = more.get("strings_after")
        after = nxt if isinstance(nxt, str) and nxt > after else None
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
    return {"written": written, "moved": moved, "entries": len(entries), "revision": lib.get("revision")}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", required=True)
    ap.add_argument("--run-dir")
    ap.add_argument("command", choices=["once", "watch", "show"])
    ap.add_argument("--interval", type=float, default=60)
    a = ap.parse_args(argv)
    game = Game(a.world)
    if a.command == "show":
        lib = game.operator("blueprint_library", {"since": 1 << 30})
        print(json.dumps(lib, indent=1))
        return 0
    if not a.run_dir:
        ap.error(f"{a.command} needs --run-dir")
    read = lambda since, after=None: game.operator("blueprint_library", dict({"since": since}, **({"after": after} if after else {})))  # noqa: E731
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
