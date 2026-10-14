#!/usr/bin/env python3
"""The agents' moments (docs/studies/2026-10-13-agent-moments.md) as data, for the /chat/ page's highlights
(site/highlights.py) and the hosts' story memo (tools/stream/hoststory.py):

    python3 site/moments.py docs/studies/2026-10-13-agent-moments.md > site/content/moments.json

Each moment: {n, theme, title, agents, shift, time (PDT, as written), quotes [{who, kind, text}], context, seen
[voiced|chat|private], seen_text, fits [memo|chat|clip]}. Stdlib only."""
import json, re, sys

HEAD = re.compile(r"^\*\*(\d+)\. (.+?)\*\*\s*$")
THEME = re.compile(r"^## \d+\. (.+?)\s*$")
QUOTE = re.compile(r'^- Quote(?: \(([^)]*)\))?: (.+)$')
NAMES = ("Astra", "Sol", "Luna", "Opus", "Sonnet", "Haiku", "Grok", "Gemini", "Muse")


def quotes_in(line):
    """'"a" ... "b"' -> the quoted parts joined; a quote with no closing mark: the rest of the line."""
    parts = re.findall(r'"([^"]+)"', line)
    return " ... ".join(parts) if parts else line.strip()


def parse(md):
    out, theme, cur = [], None, None
    for line in md.splitlines():
        m = THEME.match(line)
        if m:
            theme = m.group(1)
            continue
        m = HEAD.match(line)
        if m:
            head = m.group(2)
            who, _, rest = head.partition(", shift")
            sh = re.match(r"(\d+)", rest)
            when, _, title = rest.partition(": ")
            cur = {"n": int(m.group(1)), "theme": theme, "title": title.strip() or head,
                   "agents": [n.lower() for n in NAMES if re.search(rf"\b{n}\b", who)],
                   "shift": int(sh.group(1)) if sh else None,
                   "time": re.sub(r"^\d+,?\s*", "", when).strip(), "quotes": [], "context": None,
                   "seen": [], "seen_text": None, "fits": []}
            out.append(cur)
            continue
        if not cur or not line.startswith("- "):
            continue
        q = QUOTE.match(line)
        if q:
            # "(Muse, tell 17:45)": the speaker, then the kind; "(tell to Gemini, 16:00)": the moment's own agent
            # speaks, to Gemini
            meta = (q.group(1) or "").strip()
            lead = re.match(r"(" + "|".join(NAMES) + r"),\s*(.*)$", meta)
            who = lead.group(1).lower() if lead else (cur["agents"][0] if cur["agents"] else None)
            kind = (lead.group(2) if lead else meta).strip() or None
            cur["quotes"].append({"who": who, "kind": kind, "text": quotes_in(q.group(2))})
        elif line.startswith("- Context: "):
            cur["context"] = line[len("- Context: "):].strip()
        elif line.startswith("- Seen: "):
            seen, _, fits = line[len("- Seen: "):].partition("Fits: ")
            s = seen.strip().rstrip(".").lower()
            cur["seen_text"] = seen.strip().rstrip(".")
            cur["seen"] = [k for k, hit in (("voiced", "voiced" in s), ("chat", bool(re.search(r"\bchat\b|confession", s))),
                                            ("private", "private" in s)) if hit]
            f = fits.lower()
            cur["fits"] = [k for k, hit in (("memo", "memo" in f), ("chat", "/chat/" in f), ("clip", "clip" in f)) if hit]
    return out


def main():
    md = open(sys.argv[1]).read()
    print(json.dumps(parse(md), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
