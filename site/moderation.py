"""Viewer lines the site leaves out: YouTube deletions and the operator's own list, for site/build.py.

Sources, read at every build:
- runs/*/viewer-deletions.jsonl (tools/stream/viewers.py, one row per YouTube deletion): {t, kind: "id"|"author",
  ident, source, name, texts}. A deletion by id hides those texts from that viewer; one by author hides every line by
  that name, in every shift.
- site/hidden-viewers.json, edited by hand: {"names": [...], "texts": [...]}. A name hides all of that viewer's lines;
  a text hides that exact line from anyone.

A line relayed into the game (chat.jsonl, "viewer NAME") can differ from what was typed: the relay may put "@agent "
in front or trim it with "…". Both sides are compared without leading @names, case, extra spaces or a trailing
ellipsis, and a trimmed line matches the start of the deleted one. The agents' and hosts' own lines are never hidden.
"""
import json
import re
import unicodedata
from pathlib import Path

LEAD_AT = re.compile(r"^(?:@[\w.\-]+[\s,:]*)+")
TRIM_MIN = 12  # a trimmed relayed line must keep this many characters to match the start of a deleted one


def norm(text):
    t = unicodedata.normalize("NFKC", str(text or "")).strip()
    t = LEAD_AT.sub("", t)
    t = re.sub(r"(?:…|\.\.\.)\s*$", "", t)
    return re.sub(r"\s+", " ", t).strip().lower()


def norm_name(name):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", str(name or "")).strip().lstrip("@")).lower()


class Hidden:
    def __init__(self):
        self.names = set()   # every line by these viewers
        self.texts = {}      # viewer name ("" for anyone) -> set of normalized texts

    def add_text(self, name, text):
        t = norm(text)
        if t:
            self.texts.setdefault(norm_name(name), set()).add(t)

    def hides(self, name, text):
        """True for a viewer line (its name as shown, its text as relayed) that a deletion or the list removes."""
        n = norm_name(name)
        if n and n in self.names:
            return True
        g = norm(text)
        if not g:
            return False
        for d in self.texts.get(n, set()) | self.texts.get("", set()):
            if g == d or (len(g) >= TRIM_MIN and d.startswith(g)) or (len(d) >= TRIM_MIN and g.startswith(d)):
                return True
        return False

    def __bool__(self):
        return bool(self.names or self.texts)


def load(runs_dir, manual=None):
    """Every run's viewer-deletions.jsonl under runs_dir, and the manual list (a missing file is an empty list)."""
    h = Hidden()
    root = Path(runs_dir)
    for f in sorted(root.glob("*/viewer-deletions.jsonl")) if root.is_dir() else []:
        for line in f.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            texts = [t for t in row.get("texts") or [] if isinstance(t, str)]
            if row.get("kind") == "author" and row.get("name"):
                h.names.add(norm_name(row["name"]))
            for t in texts:  # each deleted line, from that viewer (from anyone when the name is unknown)
                h.add_text(row.get("name") or "", t)
    if manual and Path(manual).exists():
        try:
            m = json.loads(Path(manual).read_text())
        except ValueError:
            m = {}
        h.names |= {norm_name(n) for n in m.get("names") or [] if isinstance(n, str) and n.strip()}
        for t in m.get("texts") or []:
            if isinstance(t, str):
                h.add_text("", t)
    return h
