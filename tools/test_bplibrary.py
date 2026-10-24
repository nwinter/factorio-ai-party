#!/usr/bin/env python3
"""Offline checks for the team blueprint library's copy in the run (tools/bplibrary.py): python3 tools/test_bplibrary.py

The library itself (blueprint_save, blueprint_list, place by name, delete and rename rules, the operator read) is
tested in the harness: vendor/factorio-harness/tests/blueprints.lua and mod/tests/runtime_test.lua.
- A first pass asks for every string (since -1) and writes NAME.txt and index.json; a later pass asks from the
  revision it holds and writes only what changed; a deleted entry's file moves to deleted/; a missing file asks for
  every string again; a name that is not a library name is never written.
- (d24 batch147 PS1) a pass reads the revision alone first; with it unchanged and every file here, that is the pass.
  Otherwise the facts come in pages of PAGE entries (since, limit, after), index.json is written once with every
  entry; a revision that moves between pages ends the pass unwritten; an older runtime's whole read still works.
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
    """The operator read over a dict of entries: name -> (rev, string). The runtime's three forms: {probe}, a page
    ({since, limit, after}), and (old=True, an older runtime) every entry in one read."""

    def __init__(self, old=False):
        self.entries, self.revision, self.asked, self.calls, self.old = {}, 0, [], [], old

    def put(self, name, text):
        self.revision += 1
        self.entries[name] = (self.revision, text)

    def row(self, name, since):
        rev, text = self.entries[name]
        row = {"name": name, "author": "sol", "entities": 3, "rev": rev}
        if rev > since:
            row["string"] = text
        return row

    def read(self, args):
        self.calls.append(dict(args))
        since = args.get("since", -1)
        if args.get("probe") and not self.old:
            return {"revision": self.revision, "tick": 600, "count": len(self.entries)}
        if "limit" in args and not self.old:
            names = sorted(n for n in self.entries if args.get("after") is None or n > args["after"])
            rows = [self.row(n, since) for n in names[:args["limit"]]]
            out = {"revision": self.revision, "tick": 600, "entries": rows}
            if len(rows) < len(names):
                out["next_after"] = rows[-1]["name"]
            return out
        self.asked.append(since)
        return {"revision": self.revision, "tick": 600, "entries": [self.row(n, since) for n in sorted(self.entries)]}

    def pages(self):
        """The since of each first page read (a pass that read the facts)."""
        return [c["since"] for c in self.calls if "limit" in c and "after" not in c]


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
        assert lib.calls[0] == {"probe": True, "since": -1} and lib.pages() == [-1], lib.calls
        assert sorted(r["written"]) == ["pair", "smelter-row"], r
        assert open(os.path.join(folder, "smelter-row.txt")).read() == "0eNqA\n"
        index = json.load(open(os.path.join(folder, "index.json")))
        assert index["revision"] == 2 and [e["name"] for e in index["entries"]] == ["pair", "smelter-row"], index
        assert all("string" not in e for e in index["entries"]), "strings stay in the .txt files"
        # Nothing changed: the probe alone, nothing written, index.json untouched.
        n, mtime = len(lib.calls), os.stat(os.path.join(folder, "index.json")).st_mtime_ns
        r = bplibrary.mirror(lib.read, run, out)
        assert lib.calls[n:] == [{"probe": True, "since": 2}] and r["written"] == [] and r["reads"] == 1, (lib.calls[n:], r)
        assert os.stat(os.path.join(folder, "index.json")).st_mtime_ns == mtime
        # A replaced entry is written again; a deleted one moves to deleted/.
        lib.put("pair", "0eNqC")
        del lib.entries["smelter-row"]
        lib.revision += 1
        r = bplibrary.mirror(lib.read, run, out)
        assert lib.pages()[-1] == 2 and r["written"] == ["pair"] and r["moved"] == ["smelter-row"], r
        assert open(os.path.join(folder, "pair.txt")).read() == "0eNqC\n"
        assert not os.path.exists(os.path.join(folder, "smelter-row.txt"))
        assert len(os.listdir(os.path.join(folder, "deleted"))) == 1
        # A file gone from the run dir: the same pass reads every string, the revision unchanged.
        os.remove(os.path.join(folder, "pair.txt"))
        r = bplibrary.mirror(lib.read, run, out)
        assert lib.pages()[-1] == -1 and r["written"] == ["pair"] and os.path.exists(os.path.join(folder, "pair.txt")), lib.calls
        # Only library names become files.
        lib.put("../evil", "x")
        bplibrary.mirror(lib.read, run, out)
        assert not os.path.exists(os.path.join(run, "evil.txt")) and not os.path.exists(os.path.join(folder, "../evil.txt"))
        print("mirror: ok")
        # (d24 batch147 PS1) pages of `page` entries by name, each page from after the last; index.json once, complete.
        run2 = os.path.join(tmp, "run2")
        paged = FakeLibrary()
        for name in ("a", "b", "c", "d", "e"):
            paged.put(name, "0eN" + name)
        r = bplibrary.mirror(paged.read, run2, out, page=2)
        pages = [c for c in paged.calls if "limit" in c]
        assert [c.get("after") for c in pages] == [None, "b", "d"] and all(c["limit"] == 2 and c["since"] == -1 for c in pages), pages
        assert sorted(r["written"]) == ["a", "b", "c", "d", "e"] and r["reads"] == 4, r
        index = json.load(open(os.path.join(run2, "blueprints", "index.json")))
        assert [e["name"] for e in index["entries"]] == ["a", "b", "c", "d", "e"] and index["revision"] == 5, index
        # The revision moves between pages: nothing written, the next pass reads again.
        paged.put("b", "0eNb2")
        real = paged.read

        def moving(args):
            if args.get("after") == "b":
                paged.put("f", "0eNf")
            return real(args)
        r = bplibrary.mirror(moving, run2, out, page=2)
        assert r.get("retry") and r["written"] == [] and open(os.path.join(run2, "blueprints", "b.txt")).read() == "0eNb\n", r
        assert "changed during the read" in out.getvalue()
        r = bplibrary.mirror(paged.read, run2, out, page=2)
        assert sorted(r["written"]) == ["b", "f"] and json.load(open(os.path.join(run2, "blueprints", "index.json")))["revision"] == 7, r
        print("pages: ok")
        # An older runtime (no probe, no pages): its whole read, strings paged by strings_after.
        run3 = os.path.join(tmp, "run3")
        old = FakeLibrary(old=True)
        for name in ("a", "b", "c"):
            old.put(name, "0eN" + name)
        calls = []

        def read(args):
            since, after = args.get("since", -1), args.get("after")
            calls.append((since, after))
            r = old.read({"since": since})
            keep = [e for e in r["entries"] if "string" in e and (after is None or e["name"] > after)][:1]
            for e in r["entries"]:
                if e not in keep:
                    e.pop("string", None)
            if keep and any("string" in e and e["name"] > keep[0]["name"] for e in old.read({"since": since})["entries"]):
                r["strings_after"] = keep[0]["name"]
            return r
        r = bplibrary.mirror(read, run3, out)
        assert sorted(r["written"]) == ["a", "b", "c"], r
        assert calls == [(-1, None), (-1, "a"), (-1, "b")] and r["reads"] == 3, (calls, r)
        assert open(os.path.join(run3, "blueprints", "c.txt")).read() == "0eNc\n"
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
