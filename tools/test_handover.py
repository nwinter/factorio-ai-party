#!/usr/bin/env python3
"""Shift handover with measured outcomes and the post-compaction brief (tools/handover.py, tools/context.py;
docs/studies/2026-10-13-agent-minds.md fixes 8 and 12): python3 tools/test_handover.py

1. journal_stats: world actions, messages, reads and waits counted apart; idle from the replies' clock lines, never
   more than the time between requests (parallel requests counted one stretch twice: 643%); transfers and feeds that
   moved nothing; failures by message; the jobs a queue got through (its job ids advance).
2. carry: the new notes.md opens with "## Last shift, measured" (replacing the one before), keeps the notes, and caps
   them at 16 KB (the full text to notes-archive.md; Muse's was 134 KB).
3. brief: at most 3 KB after a compaction: notes.md's Now, Claims and Agreements, open board items and the last tells
   from the journal, the open team projects fh filed from its replies (eng/projects), the last 30 minutes measured;
   "AGENTS.md is still loaded" for Claude Code and Codex only.
"""
import json, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import context  # noqa: E402
import handover  # noqa: E402


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


def journal(path, t0, rows):
    """rows: (seconds after t0, action, args, ok, result) -> request/response pairs as fh journals them."""
    with open(path, "w") as f:
        for i, (s, action, args, ok, result) in enumerate(rows):
            rid = f"r{i}"
            f.write(json.dumps({"at": iso(t0 + s), "event": "request",
                                "request": {"id": rid, "action": action, "bot": "haiku", "args": args}}) + "\n")
            resp = {"id": rid, "ok": ok, "tick": 1}
            if ok:
                resp["result"] = result
            else:
                resp["error"] = {"code": "action_failed", "message": result}
            f.write(json.dumps({"at": iso(t0 + s + 0.5), "event": "response", "response": resp}) + "\n")


def clock(idle):
    return f"game 23h18m; +{idle}s since your last request, character idle {idle}s of it (100%); hand crafting 0s queued"


def sample(path, t0):
    journal(path, t0, [
        (0, "status", {}, True, {"clock": clock(0)}),
        (10, "transfer", {"item": "coal"}, True, {"transferred": 0, "clock": clock(10)}),
        (20, "transfer", {"item": "coal"}, True, {"transferred": 50, "clock": clock(2)}),
        (30, "feed", {}, True, {"transferred": 0, "clock": clock(10)}),
        (40, "sleep", {"seconds": 150}, True, {"sleeping_s": 150, "clock": clock(10)}),
        (200, "inspect", {"position": {"x": 1, "y": 2}}, False, "agent-harness/runtime:8746: target is outside local visible area: (12,5)"),
        (210, "inspect", {"position": {"x": 3, "y": 4}}, False, "agent-harness/runtime:8746: target is outside local visible area: (14,9)"),
        (220, "tell", {"to": "astra", "text": "on it"}, True, {"seq": 5, "clock": clock(9999),
                                                               "team": {"tells": ["astra, 2s ago: please feed the boilers"]}}),
        (230, "queue_status", {}, True, {"pending": [{"id": "job-100"}, {"id": "job-101"}]}),
        (900, "queue_status", {}, True, {"pending": [{"id": "job-140"}]}),
        (910, "board_post", {"kind": "claim", "title": "LDS line"}, True,
         {"item": {"id": 297, "title": "Fulgora ship: 85 foundation", "owner": "haiku", "status": "claimed"}}),
    ])


def stats():
    d = tempfile.mkdtemp()
    try:
        path = os.path.join(d, "journal.jsonl")
        t0 = time.time() - 1000
        sample(path, t0)
        st = handover.journal_stats(path)
        assert st["actions"] == 3 and st["talk"] == 2 and st["reads"] == 5 and st["waits"] == 1, st
        assert st["noop"] == {"transfer": 1, "feed": 1} and st["wait_s"] == 150, st
        assert st["errors"][0] == ("inspect: agent-harness/runtime:N: target is outside local visible area: (N,N)", 2), st
        assert st["queue_jobs"] == 40, st
        # idle: the tell's reply claims 9999 s; the gap before it was 10 s, so 10 counts
        assert st["idle_s"] == 10 + 2 + 10 + 10 + 10, st["idle_s"]
        lines = handover.measured_lines(st)
        assert lines[0] == "- 3 world actions, 2 messages and board posts, 5 reads, 1 waits (2 min of waiting asked) over 15 min", lines
        assert "- moved nothing: transfer x1, feed x1" in lines and "- your queue got through about 40 jobs" in lines, lines
        assert any(l.startswith("- failed x2: inspect:") for l in lines), lines
        # since: the last 5 minutes only
        st5 = handover.journal_stats(path, since=t0 + 800)
        assert st5["reads"] == 1 and st5["talk"] == 1 and st5["actions"] == 0, st5
        # gzipped by tools/stop-team.sh, journal.jsonl removed (d15: every carried notes.md said "no requests"): the .gz
        import gzip
        with open(path, "rb") as src, gzip.open(path + ".gz", "wb") as g:
            g.write(src.read())
        os.remove(path)
        stz = handover.journal_stats(path)
        assert stz and stz["actions"] == 3 and stz["reads"] == 5 and stz["queue_jobs"] == 40, stz
        print("stats: ok")
    finally:
        shutil.rmtree(d)


def carry():
    d = tempfile.mkdtemp()
    try:
        prev, new = os.path.join(d, "prev"), os.path.join(d, "new")
        os.makedirs(prev)
        os.makedirs(new)
        sample(os.path.join(prev, "journal.jsonl"), time.time() - 1000)
        notes = ("(Carried over from the previous shift, run shift05: its notes.md for haiku, as that shift left it.)\n\n"
                 "## Last shift, measured (from your journal, replaced each shift)\n- 1 world actions\n\n"
                 "# Notes\n\n## Now\nFeeding boilers.\n\n## Lessons\n" + ("x" * 90 + "\n") * 300 +
                 "## Log\n" + "".join(f"- line {i}\n" for i in range(40)))
        open(os.path.join(prev, "notes.md"), "w").write(notes)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "handover.py"), "carry", os.path.join(prev, "notes.md"),
                            os.path.join(prev, "journal.jsonl"), os.path.join(new, "notes.md"), "shift06", "haiku"],
                           capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.strip() == "cut", r.stdout + r.stderr
        out = open(os.path.join(new, "notes.md")).read()
        assert out.startswith("(Carried over from the previous shift, run shift06: its notes.md for haiku, as that shift left it; it was 27 KB, cut to 16 KB"), out[:200]
        assert out.count("## Last shift, measured") == 1 and "- 3 world actions" in out and "- 1 world actions" not in out, out[:600]
        assert "## Now\nFeeding boilers." in out and len(out) < handover.NOTES_MAX + 1200, len(out)
        assert out.count("Carried over") == 1
        arch = open(os.path.join(new, "notes-archive.md")).read()
        assert "- line 39" in arch and len(arch) > 27000, len(arch)
        # small notes: no cut, no archive
        shutil.rmtree(new)
        os.makedirs(new)
        open(os.path.join(prev, "notes.md"), "w").write("# Notes\n\n## Now\nFeeding boilers.\n")
        handover.carry(os.path.join(prev, "notes.md"), os.path.join(prev, "journal.jsonl"), os.path.join(new, "notes.md"),
                       "shift06", "haiku")
        assert not os.path.exists(os.path.join(new, "notes-archive.md"))
        # new-run.sh uses it for a resumed shift
        src = open(os.path.join(ROOT, "tools", "new-run.sh")).read()
        assert 'tools/handover.py" carry "$prev_notes"' in src
        print("carry: ok")
    finally:
        shutil.rmtree(d)


def brief():
    d = tempfile.mkdtemp()
    try:
        ws = os.path.join(d, "haiku")
        os.makedirs(ws)
        sample(os.path.join(ws, "journal.jsonl"), time.time() - 1000)
        open(os.path.join(ws, "notes.md"), "w").write(
            "# Notes\n\n## Now\nFeeding boilers for astra.\n\n## Claims\n- RF reserve chest 14.5,37.5\n\n"
            "## Agreements\n- Haiku keeps coal for boilers.\n\n## Lessons\n" + "y" * 20000 + "\n")
        open(os.path.join(ws, context.MARKER), "w").write("claude haiku 80000\n")
        b = context.brief(ws, "Your context was just compacted.")
        assert len(b) <= context.BRIEF_MAX, len(b)
        assert "AGENTS.md is still loaded in your context: do not re-read it." in b, b
        assert "## Now (notes.md)\nFeeding boilers for astra." in b and "RF reserve chest" in b and "keeps coal" in b, b
        assert "#297 Fulgora ship: 85 foundation (claimed)" in b and "astra, 2s ago: please feed the boilers" in b, b
        assert "## Your last 30 minutes, measured" in b and "moved nothing: transfer x1, feed x1" in b, b
        assert "yyyy" not in b  # the rest of notes.md stays in the file
        assert "## Open team projects" not in b  # none filed yet
        # open board projects fh filed from its replies (cli.ts .projects.json): this agent's own first, with their age
        at = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 14 * 60))
        lines = ["#15 robot mall: 0 of 1 step; owner grok (last request 3m00s ago); next 1. roboports",
                 "#12 nuclear plant: 2 of 4 steps; owner haiku; next 3. reactor; handoff: " + "h" * 300,
                 '+3 more: board {kind: "project"}']
        open(os.path.join(ws, context.PROJECTS_FILE), "w").write(json.dumps({"at": at, "lines": lines}))
        b = context.brief(ws, "Your context was just compacted.")
        assert len(b) <= context.BRIEF_MAX, len(b)
        part = b.split("## Open team projects (your fh replies, 14 min ago)\n", 1)[1].split("\n\n", 1)[0].split("\n")
        assert part[0].startswith("- #12 nuclear plant: 2 of 4 steps; owner haiku; next 3. reactor") and part[0].endswith(" [...]"), part
        assert part[1].startswith("- #15 robot mall") and part[2] == "- +3 more: ./fh board projects", part
        assert "## Your last 30 minutes, measured" in b, b  # still fits
        open(os.path.join(ws, context.MARKER), "w").write("grok grok-4.7 154000\n")
        assert "AGENTS.md is still loaded" not in context.brief(ws, "x")  # Grok reads it as a file
        # the hooks print the brief, not the whole notes.md
        open(os.path.join(ws, context.MARKER), "w").write("claude haiku 80000\n")
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "context.py"), "hook", "session-compact"],
                           input=json.dumps({"cwd": ws, "source": "compact"}), capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.startswith("Your context was just compacted. A brief of at most 3 KB"), r.stdout[:200]
        assert len(r.stdout) <= context.BRIEF_MAX + 2
        print(f"brief: ok ({len(b)} characters)")
    finally:
        shutil.rmtree(d)


def brief_trim():
    """(d19 batch41 C2, viewer Aurora: the 3 KB cut fell on the later sections while older notes stayed) over 3 KB, the
    ground rules, open commitments and live checks stay whole; the measured lines, projects and other tells go first,
    then Now from its end; the brief says what it trimmed."""
    d = tempfile.mkdtemp()
    try:
        ws = os.path.join(d, "sol")
        os.makedirs(ws)
        journal(os.path.join(ws, "journal.jsonl"), time.time() - 1000, [
            (0, "status", {}, True, {"clock": clock(0), "team": {"tells": ["astra, 9s ago: " + "t" * 170,
                                                                           "reminder #97, 5s ago: freight review (sol, every 15m): check Swiftlet PU"]}}),
            (10, "transfer", {"item": "coal"}, True, {"transferred": 0, "clock": clock(10)}),
            (20, "board_post", {"kind": "task", "title": "x"}, True, {"item": {"id": 1213, "title": "Bastion departure checklist", "owner": "sol", "status": "doing"}}),
        ])
        rules = [f"rule {i} (by astra): ship rule {i} " + "r" * 120 + f"; from lessons #{40 + i}" for i in range(1, 4)]
        open(os.path.join(ws, context.RULES_FILE), "w").write(json.dumps({"at": "2026-10-19T13:00:00.000Z", "lines": rules}))
        now = "\n".join(f"- older state line {i} " + "n" * 60 for i in range(30))
        open(os.path.join(ws, "notes.md"), "w").write(
            "# Notes\n\n## Now\n" + now + "\n\n## Commitments\n- Swiftlet PU 600 to Aquilo each leg (Sol owns)\n\n"
            "## Next check\n- Swiftlet section 5 on at 14:00\n")
        b = context.brief(ws, "Your context was just compacted.")
        assert len(b) <= context.BRIEF_MAX, len(b)
        for r in rules:
            assert r in b, r
        assert "Swiftlet PU 600 to Aquilo each leg (Sol owns)" in b and "#1213 Bastion departure checklist (doing)" in b, b
        live = b.split("## Your live checks\n", 1)[1]
        assert "Swiftlet section 5 on at 14:00" in live and "reminder #97" in live and live.rstrip().endswith("./fh call chat."), live
        assert "older state line 0" in b and "older state line 29" not in b, b
        trimmed = b.split("Trimmed to fit 3 KB (notes.md and your journal have them): ", 1)[1].split("\n", 1)[0]
        assert "Your last 30 minutes, measured (your journal) (all 4 lines); Last tells to you (all 1 line)" in trimmed and "lines of Now (notes.md)" in trimmed, trimmed
        print(f"brief trim: ok ({len(b)} characters)")
    finally:
        shutil.rmtree(d)


def carry_keep():
    """(d19 batch41 C3, viewer Aurora: a shortened handoff keeps current decisions, open commitments and the next live
    check) over the cap: Log first, then the older sections in file order; the first Now, agreements, open board items
    and next check stay whole; the head says what was trimmed."""
    d = tempfile.mkdtemp()
    try:
        prev, new = os.path.join(d, "prev"), os.path.join(d, "new")
        os.makedirs(prev); os.makedirs(new)
        now = "## Now\nSwiftlet waits at Aquilo for PU 600.\n\n"
        keep = ("## Team agreements\n- Sol owns Swiftlet section 5.\n\n## Open board items\n- #1213 Bastion checklist (doing)\n\n"
                "## Next check\n- section 5 on at 14:00\n\n")
        old_now = "## Now (shift39)\n" + "o" * 3000 + "\n\n"
        lessons = "## Lessons\n" + "l" * 9000 + "\n\n"
        newest = "## Shift41\n" + "s" * 4000 + "\n\n"
        log = "## Log\n" + "".join(f"- {i} event\n" for i in range(400)) + "\n"
        open(os.path.join(prev, "notes.md"), "w").write("# Notes\n\n" + now + keep + old_now + lessons + newest + log)
        assert handover.carry(os.path.join(prev, "notes.md"), os.path.join(prev, "journal.jsonl"), os.path.join(new, "notes.md"),
                              "shift41", "sol")
        out = open(os.path.join(new, "notes.md")).read()
        for part in (now, keep, newest, lessons):
            assert part.strip() in out, part[:40]
        assert "o" * 3000 not in out and "## Now (shift39)\n" + "o" * 100 in out, "the older Now is cut from its end, first"
        head = out.split("\n")[1]
        assert head.startswith("(Trimmed: Log: 390 older lines; Now (shift39): ") and "Kept whole: the sections on now" in head, head
        print("carry keep: ok")
    finally:
        shutil.rmtree(d)


def batch275():
    """(d27 batch275 HW) acks and reads the runtime counts as such are no world actions (Opus's carry-over said 15435,
    15429 of them chat_ack; Muse's 58 were ghosts and alerts_digest); the longest stretch with no world action; a ## Now
    section with the same text at the end of 2 or more shifts in a row; no negative queue count."""
    d = tempfile.mkdtemp()
    try:
        t0 = time.time() - 20000
        path = os.path.join(d, "journal.jsonl")
        journal(path, t0, [
            (0, "status", {}, True, {}),
            (60, "chat_ack", {"seq": "all"}, True, {}),
            (120, "lookahead", {}, True, {}),
            (180, "ghosts", {}, True, {}),
            (240, "alerts_digest", {}, True, {}),
            (300, "reminder_ack", {"id": 3}, True, {}),
            (360, "build", {"name": "inserter"}, True, {"built": 1}),
            (7560, "deconstruct", {}, True, {"marked": 4}),
            (7600, "queue_status", {}, True, {"pending": [{"id": "job-90"}]}),
            (7700, "queue_status", {}, True, {"pending": [{"id": "job-20"}]}),
            (16000, "chat_ack", {"seq": "all"}, True, {}),
        ])
        st = handover.journal_stats(path)
        assert st["actions"] == 2 and st["reads"] == 6 and st["talk"] == 3, st
        lines = handover.measured_lines(st)
        assert "- longest stretch with no world action: 141 min" in " ".join(lines), lines
        assert any(l.startswith("- longest stretch with no world action: 141 min (") and l.endswith(" UTC, to your last request)") for l in lines), lines
        assert not any("queue got through" in l for l in lines), lines
        # ## Now unchanged across shifts: said from the second shift on, with the run it began
        prev, mid, new = (os.path.join(d, x) for x in ("s1", "s2", "s3"))
        for x in (prev, mid, new):
            os.makedirs(x)
        open(os.path.join(prev, "notes.md"), "w").write("# Notes\n\n## Now\nshift 80: paper design for Loom.\n")
        handover.carry(os.path.join(prev, "notes.md"), path, os.path.join(mid, "notes.md"), "shift80", "sonnet")
        assert "## Now section" not in open(os.path.join(mid, "notes.md")).read()
        open(os.path.join(mid, "notes.md"), "w").write("# Notes\n\n## Now\nshift 80:  paper design\nfor Loom.\n")
        handover.carry(os.path.join(mid, "notes.md"), path, os.path.join(new, "notes.md"), "shift81", "sonnet")
        out = open(os.path.join(new, "notes.md")).read()
        assert "- your notes' ## Now section had the same text at the end of the last 2 shifts (shift80 to shift81)" in out, out
        open(os.path.join(new, "notes.md"), "w").write("# Notes\n\n## Now\nbuilding the copper cell.\n")
        last = os.path.join(d, "s4")
        os.makedirs(last)
        handover.carry(os.path.join(new, "notes.md"), path, os.path.join(last, "notes.md"), "shift82", "sonnet")
        assert "## Now section" not in open(os.path.join(last, "notes.md")).read()
        assert json.load(open(os.path.join(last, handover.NOW_FILE)))["since"] == "shift82"
        print("batch275: ok")
    finally:
        shutil.rmtree(d)


if __name__ == "__main__":
    batch275()
    stats()
    carry()
    brief()
    brief_trim()
    carry_keep()
