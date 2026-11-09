#!/usr/bin/env python3
"""The size guard on an agy workspace's AGENTS.md, and the per-turn digest of an agy loop (d15 trajectory analysis:
agy cuts a rules file to its first 24000 bytes, so Gemini never saw the action reference in its 94 KB AGENTS.md; and
each turn started with no memory of the last).

    python3 tools/agy_rules.py rules DIR      # AGENTS.md over agy's cut: a warning on stderr (exit 0 either way)
    python3 tools/agy_rules.py digest DIR     # what the loop puts at the head of each turn's prompt (stdout)
    python3 tools/agy_rules.py digest-rules DIR   # the same with the team's ground rules first (a fresh conversation)

rules: the brief's core (tools/brief.py) stays under 20 KB, so agy gets the same AGENTS.md and ref/ topic files as
every agent; this warns at launch when it has grown past the 24000 bytes agy reads. digest: notes.md as the agent last
wrote it, through context.py's 3000-byte recovery brief, and how its last turn ended (the last 800 bytes agy
printed, .agy-last.txt). Both digest and digest-rules carry the ground rules, deadline, ownership, work and checks;
digest-rules remains a compatible name for the fresh-conversation loop branch.
"""
import json, os, sys, time

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


def ground_rules(dirpath):
    try:
        return [l for l in json.load(open(os.path.join(dirpath, ".ground_rules.json"))).get("lines") or [] if isinstance(l, str) and l.strip()]
    except (OSError, ValueError, AttributeError):
        return []


def digest(dirpath, now=None, with_rules=False):
    # Every turn may have lost context; the same bounded recovery fields apply to fresh
    # conversations, continuations, and shift starts. Rules cannot crowd out the deadline.
    from context import brief
    body = brief(dirpath, "Recovery brief from your local files.")
    try:
        with open(os.path.join(dirpath, ".agy-last.txt"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 800))
            last = f.read().decode("utf-8", "replace").strip()
        if last:
            body += "\n\nYour last turn ended with:\n" + last
    except OSError:
        pass
    return body.replace("\x00", "")


def main(argv):
    if len(argv) == 3 and argv[1] == "rules":
        print("over" if rules(argv[2]) else "fits")
        return 0
    if len(argv) == 3 and argv[1] in ("digest", "digest-rules"):
        sys.stdout.write(digest(argv[2], with_rules=argv[1] == "digest-rules"))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
