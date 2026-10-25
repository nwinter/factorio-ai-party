#!/usr/bin/env python3
"""The team's ground rules after a compaction, per harness (d20 batch50 E2): python3 tools/test_rules_inject.py

- Claude (SessionStart compact), Grok and Muse (post-compact --mark, then the next tool call): tools/context.py brief(),
  which starts with the ground rules fh filed in .ground_rules.json (d19 batch41 C2).
- Codex: re-injects only AGENTS.md. tools/launch-agent.sh files the rules (a ground_rules read) and tools/brief.py rules
  writes them into AGENTS.md as their own section (fh keeps it current: host/rules.ts, tests/rulessection.test.ts).
- agy: a fresh conversation (.agy-loop.sh past compact_at) gets tools/agy_rules.py digest-rules: the rules first.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import brief, agy_rules, context  # noqa: E402

RULES = ["rule 1 (by sol): one checklist per ship; from lessons #41 (evidence tick 200, verified 0h ago)",
         "rule 8 (by astra): Use big mining drills by default for new ore outposts. Ordinary drills require a recorded "
         "exception and an owned conversion task.; from lessons #77 (evidence tick 900, verified 2h ago)"]


def main():
    core = "# Brief\n\nbody\n\n## Compact instructions\nkeep the board\n"
    t = brief.rules_note(core, RULES)
    assert t.index("## The team's ground rules") < t.index("## Compact instructions"), t
    assert f"{brief.RULES_START}\n- {RULES[0]}\n- {RULES[1]}\n{brief.RULES_END}\n" in t, t
    t2 = brief.rules_note(t, RULES[1:])  # replaced, not added twice
    assert t2.count("## The team's ground rules") == 1 and RULES[0] not in t2 and RULES[1] in t2, t2
    assert brief.rules_note(t, []) == core.replace("body\n\n", "body\n\n"), brief.rules_note(t, [])  # none: no section
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "AGENTS.md"), "w").write(core)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "brief.py"), "rules", d], capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.strip() == "0" and open(os.path.join(d, "AGENTS.md")).read() == core, r
        json.dump({"at": "2026-10-20T15:48:00", "lines": RULES}, open(os.path.join(d, ".ground_rules.json"), "w"))
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "brief.py"), "rules", d], capture_output=True, text=True)
        assert r.stdout.strip() == "2" and "rule 8 (by astra): Use big mining drills" in open(os.path.join(d, "AGENTS.md")).read()
        # agy: the plain digest has no rules, the fresh start's does, first
        open(os.path.join(d, "notes.md"), "w").write("## Now\nbuilding\n")
        assert "ground rules" not in agy_rules.digest(d)
        g = agy_rules.digest(d, with_rules=True)
        assert g.startswith("The team's ground rules (as the shift start gave them):\n- rule 1 (by sol)") and "## Now" in g, g
        # Claude, Grok, Muse: the brief after a compaction starts with them (context.py, unchanged)
        for kind in ("claude", "grok", "muse"):
            open(os.path.join(d, context.MARKER), "w").write(f"{kind} m 100000\n")
            b = context.brief(d, "Your context was just compacted.")
            assert "## Ground rules (the team's, from your fh replies)\n- rule 1 (by sol)" in b, (kind, b[:400])
    # the launch wiring: Codex files and writes them; the agy loop's fresh start uses digest-rules
    sh = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    codex = sh[sh.index("  codex)"):sh.index("  grok)")]
    assert '"$dir/fh" call ground_rules' in codex and 'brief.py" rules "$dir"' in codex, codex
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["bash", os.path.join(ROOT, "tools", "launch-agent.sh"), "--agy-loop", d, "gemini-x", "100000", "/dev/null"],
                       check=True, capture_output=True, env=dict(os.environ, POG_TEST="1"))
        loop = open(os.path.join(d, ".agy-loop.sh")).read()
        fresh = loop[loop.index("This is a fresh conversation"):]
        assert "digest-rules" in loop and "$(memr)" in fresh.split("elif")[0], fresh[:600]
    print("rules after compaction: ok (Claude, Grok, Muse brief; Codex AGENTS.md section; agy fresh start)")


if __name__ == "__main__":
    main()
