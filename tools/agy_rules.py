#!/usr/bin/env python3
"""The size guard on an agy workspace's AGENTS.md, and the per-turn digest of an agy loop (d15 trajectory analysis:
agy cuts a rules file to its first 24000 bytes, so Gemini never saw the action reference in its 94 KB AGENTS.md; and
each turn started with no memory of the last).

    python3 tools/agy_rules.py rules DIR      # AGENTS.md over agy's cut: a warning on stderr (exit 0 either way)
    python3 tools/agy_rules.py digest DIR     # what the loop puts at the head of each turn's prompt (stdout)

rules: the brief's core (tools/brief.py) stays under 20 KB, so agy gets the same AGENTS.md and ref/ topic files as
every agent; this warns at launch when it has grown past the 24000 bytes agy reads. digest: notes.md as the agent last
wrote it (its "## Now" first, the file cut to 4000 characters) and how its last turn ended (the last 800 characters agy
printed, .agy-last.txt).
"""
import os, sys, time

LIMIT = 24000      # agy's cut, in bytes


def rules(dirpath):
    """True (and a warning on stderr) when AGENTS.md is over agy's cut."""
    size = len(open(os.path.join(dirpath, "AGENTS.md"), "rb").read())
    if size <= LIMIT:
        return False
    print(f"agy_rules: {dirpath}/AGENTS.md is {size} bytes, over agy's {LIMIT}-byte cut: Gemini reads only the first "
          f"{LIMIT} (the core's size: tools/brief.py, tools/test_brief.py)", file=sys.stderr)
    return True


def section(text, name):
    i = text.find("## " + name)
    if i < 0:
        return ""
    j = text.find("\n## ", i + 3)
    return text[i:j if j >= 0 else len(text)].strip()


def digest(dirpath, now=None):
    now = now or time.time()
    parts = []
    notes_path = os.path.join(dirpath, "notes.md")
    try:
        notes = open(notes_path, errors="replace").read()
        age = int((now - os.path.getmtime(notes_path)) // 60)
        now_part = section(notes, "Now")
        body = (now_part + "\n\n" + notes.replace(now_part, "").strip()) if now_part else notes.strip()
        if len(body) > 4000:
            body = body[:4000].rsplit("\n", 1)[0] + "\n(cut; the rest is in notes.md)"
        parts.append(f"Your notes.md, as you last wrote it ({age} min ago):\n{body}")
    except OSError:
        parts.append("You have no notes.md yet.")
    try:
        last = open(os.path.join(dirpath, ".agy-last.txt"), errors="replace").read().strip()
        if last:
            parts.append("Your last turn ended with:\n" + last[-800:])
    except OSError:
        pass
    return "\n\n".join(parts).replace("\x00", "")


def main(argv):
    if len(argv) == 3 and argv[1] == "rules":
        print("over" if rules(argv[2]) else "fits")
        return 0
    if len(argv) == 3 and argv[1] == "digest":
        sys.stdout.write(digest(argv[2]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
