#!/usr/bin/env python3
"""tools/agy_rules.py (d15 trajectory analysis: agy cuts AGENTS.md to 24000 bytes, and each of Gemini's turns started
with no memory): python3 tools/test_agy_rules.py

1. rules: an AGENTS.md over 24000 bytes gets a warning on stderr and stays as it is (agy gets the same core and ref/
   topic files as every agent, tools/brief.py); one that fits: no warning.
2. digest: notes.md with its "## Now" first, how old it is, the end of the last turn's output; no notes: says so.
"""
import contextlib, io, os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import agy_rules  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    head = "# You are playing Factorio\n\n## Goal\n\nPlay.\n\n"
    full = head + "## Team\n\n" + "".join(f"- Action example {i}: ./fh call feed does a thing.\n\n" for i in range(900))
    open(os.path.join(d, "AGENTS.md"), "w").write(full)
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        assert agy_rules.rules(d)
    assert "over agy's 24000-byte cut" in err.getvalue(), err.getvalue()
    assert open(os.path.join(d, "AGENTS.md")).read() == full, "the guard changes nothing"
    assert not os.path.exists(os.path.join(d, "AGENTS-full.md"))
    # one that fits: no warning
    open(os.path.join(d, "AGENTS.md"), "w").write(head)
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        assert not agy_rules.rules(d)
    assert err.getvalue() == "" and open(os.path.join(d, "AGENTS.md")).read() == head
    print("rules: ok")

    # digest
    assert agy_rules.digest(d) == "You have no notes.md yet."
    notes = os.path.join(d, "notes.md")
    open(notes, "w").write("# Notes\n\nold stuff\n\n## Now\n- refuel the boilers at (10,20)\n\n## Done\n- x\n")
    os.utime(notes, (time.time() - 600, time.time() - 600))
    open(os.path.join(d, ".agy-last.txt"), "w").write("x" * 2000 + "Fixed the south unloader.")
    g = agy_rules.digest(d)
    assert g.startswith("Your notes.md, as you last wrote it (10 min ago):\n## Now\n- refuel the boilers at (10,20)"), g
    assert "old stuff" in g and g.endswith("Fixed the south unloader.") and "Your last turn ended with:" in g, g[-200:]
    assert len(g) < 3000, len(g)
    print("digest: ok")
print("all passed")
