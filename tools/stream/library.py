"""The team's blueprint library in the live state (d19 batch42 B4, seq 870, Sol via viewer Foobator: "lab-belt-four41 not
visible on site"). The site's /blueprints/ page is built from the newest shift's copy of the library (tools/bplibrary.py
mirrors it to runs/RUN/blueprints/index.json and NAME.txt; site/blueprints.py), and the site is built at each shift
change (tools/shift-change.sh -> site-refresh.sh), so a blueprint saved during the live shift was missing until it
ended. serve.py puts `library` in the snapshot: the newest NEWEST entries by save tick, their facts without the
blueprint string (name, author, saved_tick, entities, footprint, surface, description), and the copy's written time
and tick; the page lists those it does not have, with author and time, from the live state."""
import json
import os
import re

NEWEST = 15
DESC_MAX = 200
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,39}")
KEYS = ("name", "author", "saved_tick", "entities", "footprint", "surface")


class Library:
    def __init__(self, path):
        self.path, self.mtime, self.data = path, None, None

    def public(self):
        """{written, tick, entries} (newest first), or None without a copy. Read again when the file changes."""
        try:
            m = os.stat(self.path).st_mtime_ns
        except (OSError, TypeError):
            return self.data
        if m != self.mtime:
            self.mtime = m
            try:
                with open(self.path) as f:
                    index = json.load(f)
            except (OSError, ValueError):
                return self.data
            self.data = shape(index)
        return self.data


def shape(index):
    entries = []
    for e in (index or {}).get("entries") or []:
        if not isinstance(e, dict) or not NAME.fullmatch(str(e.get("name") or "")):
            continue
        row = {k: e[k] for k in KEYS if isinstance(e.get(k), (str, int, float)) and not isinstance(e.get(k), bool)}
        if e.get("description"):
            d = re.sub(r"\s+", " ", str(e["description"])).strip()
            row["description"] = d if len(d) <= DESC_MAX else d[:DESC_MAX - 1].rstrip() + "…"
        entries.append(row)
    entries.sort(key=lambda r: (-(r.get("saved_tick") or 0), r["name"]))
    return {"written": index.get("written"), "tick": index.get("tick"), "count": len(entries), "entries": entries[:NEWEST]}
