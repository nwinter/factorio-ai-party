#!/usr/bin/env python3
"""tools/agy_rules.py (d15 trajectory analysis: agy cuts AGENTS.md to 24000 bytes, and each of Gemini's turns started
with no memory): python3 tools/test_agy_rules.py

1. rules: an AGENTS.md over 24000 bytes becomes a compact one under the cut (everything before "## Team", where the rest
   is, every action with its arguments, then the team section's start), the full text in AGENTS-full.md; one that fits
   is left alone.
2. digest: notes.md with its "## Now" first, how old it is, the end of the last turn's output; no notes: says so.
"""
import json, os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import agy_rules  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    head = "# You are playing Factorio\n\n## Goal\n\nPlay.\n\n## Your interface: `./fh`\n\nCall actions.\n\n"
    team = "## Team\n\n" + "".join(f"- Action example {i}: ./fh call feed --args '{{}}' does a thing.\n\n" for i in range(900))
    full = head + team + "## Space Age\n\nPlanets.\n\n## Compact instructions\n\nKeep notes.\n"
    open(os.path.join(d, "AGENTS.md"), "w").write(full)
    json.dump({"actions": {"feed": {"position": "x", "radius": "r", "returns": "doc"}, "status": {}}}, open(os.path.join(d, "describe.json"), "w"))
    assert agy_rules.rules(d)
    text = open(os.path.join(d, "AGENTS.md")).read()
    assert len(text.encode()) <= agy_rules.LIMIT, len(text.encode())
    assert text.startswith(head) and "## Full instructions" in text and "AGENTS-full.md" in text, text[:400]
    assert "- feed: position, radius\n- status\n" in text, "every action with its arguments, doc keys left out"
    assert "Action example 0:" in text and "(The team section goes on in AGENTS-full.md.)" in text
    assert "## Space Age" not in text
    assert open(os.path.join(d, "AGENTS-full.md")).read() == full
    # one that fits stays as it is
    open(os.path.join(d, "AGENTS.md"), "w").write(head)
    assert not agy_rules.rules(d) and open(os.path.join(d, "AGENTS.md")).read() == head
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
