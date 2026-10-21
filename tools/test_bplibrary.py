#!/usr/bin/env python3
"""Offline checks for the team blueprint library's copy in the run (tools/bplibrary.py): python3 tools/test_bplibrary.py

The library itself (blueprint_save, blueprint_list, place by name, delete and rename rules, the operator read) is
tested in the harness: vendor/factorio-harness/tests/blueprints.lua and mod/tests/runtime_test.lua.
- A first pass asks for every string (since -1) and writes NAME.txt and index.json; a later pass asks from the
  revision it holds and writes only what changed; a deleted entry's file moves to deleted/; a missing file asks for
  every string again; a name that is not a library name is never written.
- The operator request form.
- start-team.sh starts the watch with the helpers; stop-team.sh runs a last pass before the save; the agent/ref/building.md line
  describes the tools only.
"""
import io
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import bplibrary  # noqa: E402


class FakeLibrary:
    """The operator read over a dict of entries: name -> (rev, string)."""

    def __init__(self):
        self.entries, self.revision, self.asked = {}, 0, []

    def put(self, name, text):
        self.revision += 1
        self.entries[name] = (self.revision, text)

    def read(self, since):
        self.asked.append(since)
        rows = []
        for name, (rev, text) in sorted(self.entries.items()):
            row = {"name": name, "author": "sol", "entities": 3, "rev": rev}
            if rev > since:
                row["string"] = text
            rows.append(row)
        return {"revision": self.revision, "tick": 600, "entries": rows}


def main():
    tmp = tempfile.mkdtemp()
    try:
        run = os.path.join(tmp, "run")
        lib = FakeLibrary()
        lib.put("smelter-row", "0eNqA")
        lib.put("pair", "0eNqB")
        out = io.StringIO()
        r = bplibrary.mirror(lib.read, run, out)
        folder = os.path.join(run, "blueprints")
        assert lib.asked == [-1], lib.asked
        assert sorted(r["written"]) == ["pair", "smelter-row"], r
        assert open(os.path.join(folder, "smelter-row.txt")).read() == "0eNqA\n"
        index = json.load(open(os.path.join(folder, "index.json")))
        assert index["revision"] == 2 and [e["name"] for e in index["entries"]] == ["pair", "smelter-row"], index
        assert all("string" not in e for e in index["entries"]), "strings stay in the .txt files"
        # Nothing changed: asked from revision 2, nothing written.
        r = bplibrary.mirror(lib.read, run, out)
        assert lib.asked[-1] == 2 and r["written"] == [] and r["moved"] == [], r
        # A replaced entry is written again; a deleted one moves to deleted/.
        lib.put("pair", "0eNqC")
        del lib.entries["smelter-row"]
        lib.revision += 1
        r = bplibrary.mirror(lib.read, run, out)
        assert r["written"] == ["pair"] and r["moved"] == ["smelter-row"], r
        assert open(os.path.join(folder, "pair.txt")).read() == "0eNqC\n"
        assert not os.path.exists(os.path.join(folder, "smelter-row.txt"))
        assert len(os.listdir(os.path.join(folder, "deleted"))) == 1
        # A file gone from the run dir: the next pass asks for every string.
        os.remove(os.path.join(folder, "pair.txt"))
        bplibrary.mirror(lib.read, run, out)
        bplibrary.mirror(lib.read, run, out)
        assert lib.asked[-1] == -1 and os.path.exists(os.path.join(folder, "pair.txt")), lib.asked
        # Only library names become files.
        lib.entries["../evil"] = (99, "x")
        bplibrary.mirror(lib.read, run, out)
        assert not os.path.exists(os.path.join(run, "evil.txt")) and not os.path.exists(os.path.join(folder, "../evil.txt"))
        print("mirror: ok")
        # (d20 batch59 U2) strings paged: strings_after, read on with after, every string written once.
        run2 = os.path.join(tmp, "run2")
        paged = FakeLibrary()
        for name in ("a", "b", "c"):
            paged.put(name, "0eN" + name)
        calls = []

        def read(since, after=None):
            calls.append((since, after))
            r = paged.read(since)
            keep = [e for e in r["entries"] if "string" in e and (after is None or e["name"] > after)][:1]
            for e in r["entries"]:
                if e not in keep:
                    e.pop("string", None)
            if keep and any("string" in e and e["name"] > keep[0]["name"] for e in paged.read(since)["entries"]):
                r["strings_after"] = keep[0]["name"]
            return r
        r = bplibrary.mirror(read, run2, out)
        assert sorted(r["written"]) == ["a", "b", "c"], r
        assert calls == [(-1, None), (-1, "a"), (-1, "b")], calls
        assert open(os.path.join(run2, "blueprints", "c.txt")).read() == "0eNc\n"
        print("paged strings: ok")
    finally:
        shutil.rmtree(tmp)

    # The operator request form.
    sent = []

    class FakeHarness:
        def command(self, cmd):
            sent.append(cmd)
            return json.dumps({"ok": True, "result": {"revision": 0, "entries": []}})

    g = bplibrary.Game.__new__(bplibrary.Game)
    g.harness = FakeHarness()
    assert g.operator("blueprint_library", {"since": 3}) == {"revision": 0, "entries": []}
    assert '"operator": true' in sent[0] and '"action": "blueprint_library"' in sent[0] and '"since": 3' in sent[0], sent[0]
    print("request form: ok")

    # Wiring and wording.
    start = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    stop = open(os.path.join(ROOT, "tools", "stop-team.sh")).read()
    assert "tools/bplibrary.py --world \"$world\" --run-dir \"$rundir\" watch" in start, "start-team starts the watch"
    assert stop.index("tools/bplibrary.py") < stop.index("pog.py --world \"$world\" save"), "a last pass before the save"
    ref = open(os.path.join(ROOT, "agent", "ref", "building.md")).read().lower()
    line = next(l for l in ref.splitlines() if "blueprint_save" in l)
    for word in ("should", "consider", "try ", "when you", "if you"):
        assert word not in line, f"ref/building.md blueprint line has {word!r}: {line}"
    print("wiring: ok")


if __name__ == "__main__":
    main()
