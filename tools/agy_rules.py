#!/usr/bin/env python3
"""An AGENTS.md that fits Antigravity's rules limit, and the per-turn digest of an agy loop (d15 trajectory analysis:
agy cuts a rules file to its first 24000 bytes, so Gemini never saw the action reference in its 94 KB AGENTS.md; and
each turn started with no memory of the last).

    python3 tools/agy_rules.py rules DIR      # AGENTS.md over the limit: the full text to AGENTS-full.md, a compact one
    python3 tools/agy_rules.py digest DIR     # what the loop puts at the head of each turn's prompt (stdout)

rules: the compact AGENTS.md keeps everything before "## Team" (goal, interface, pace, harness notes, rules, memory,
stopping), says where the rest is, lists every action with its argument names from describe.json, then as much of the
team section as fits, cut at a paragraph. digest: notes.md as the agent last wrote it (its "## Now" first, the file
cut to 4000 characters) and how its last turn ended (the last 800 characters agy printed, .agy-last.txt).
"""
import json, os, sys, time

LIMIT = 24000      # agy's cut, in bytes
BUDGET = 23000     # what the compact file may take (a margin under the cut)
DOC_KEYS = {"returns", "note", "notes", "examples", "usage", "reports", "outcomes", "checked", "max", "status"}


def action_index(describe_path):
    """'- name: arg, arg, ...' for every action in describe.json (one action per line), sorted; [] without the file."""
    try:
        d = json.load(open(describe_path))
    except (OSError, ValueError):
        return []
    acts = d.get("actions") if isinstance(d, dict) else None
    if not isinstance(acts, dict):
        return []
    out = []
    for name in sorted(acts):
        spec = acts[name] if isinstance(acts[name], dict) else {}
        args = [a for a in spec if a not in DOC_KEYS]
        out.append(f"- {name}" + (": " + ", ".join(args) if args else ""))
    return out


def cut_at_paragraph(text, nbytes):
    """The longest start of text within nbytes that ends at a blank line (or a line end)."""
    if len(text.encode()) <= nbytes:
        return text
    head = text.encode()[:nbytes].decode("utf-8", "ignore")
    i = head.rfind("\n\n")
    if i < len(head) // 2:
        i = head.rfind("\n")
    return head[:max(i, 0)].rstrip() + "\n"


def compact(full, index):
    i = full.find("\n## Team")
    head = full[:i + 1] if i >= 0 else cut_at_paragraph(full, BUDGET // 2)
    team = full[i + 1:] if i >= 0 else ""
    j = team.find("\n## ", 4)
    team = team[:j + 1] if j >= 0 else team
    pointer = ("## Full instructions\n\nThis file is cut to fit your client's 24 KB rules limit. The full instructions are in "
               "AGENTS-full.md in this directory: the whole team section (every action with its examples, the team's "
               "rules), Space Age, your tools and the compact instructions. Read its sections there when you need them "
               "(grep it for an action's name). Every action's arguments in full: describe.json, one action per line.\n\n")
    idx = ("## Actions and their arguments\n\n" + "\n".join(index) + "\n\n") if index else ""
    used = len((head + pointer + idx).encode())
    room = BUDGET - used - 80
    if room < 0:  # the head alone is too long: cut it too
        head = cut_at_paragraph(head, max(2000, BUDGET - len((pointer + idx).encode()) - 200))
        room = 0
    part = cut_at_paragraph(team, room) if room > 0 and team else ""
    tail = "\n(The team section goes on in AGENTS-full.md.)\n" if part and part != team else ""
    return head + pointer + idx + part + tail


def rules(dirpath):
    path = os.path.join(dirpath, "AGENTS.md")
    full = open(path).read()
    if len(full.encode()) <= LIMIT:
        return False
    with open(os.path.join(dirpath, "AGENTS-full.md"), "w") as f:
        f.write(full)
    text = compact(full, action_index(os.path.join(dirpath, "describe.json")))
    with open(path, "w") as f:
        f.write(text)
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
        print("compacted" if rules(argv[2]) else "fits")
        return 0
    if len(argv) == 3 and argv[1] == "digest":
        sys.stdout.write(digest(argv[2]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
