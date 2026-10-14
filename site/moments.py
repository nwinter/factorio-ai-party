#!/usr/bin/env python3
"""The agents' moments (docs/studies/2026-10-13-agent-moments.md) as data, for the /chat/ page's highlights
(site/highlights.py) and the hosts' story memo (tools/stream/hoststory.py):

    python3 site/moments.py docs/studies/2026-10-13-agent-moments.md > site/content/moments.json

Each moment: {n, theme, title, agents, shift, time (PDT, as written), quotes [{who, kind, text}], context, seen
[voiced|chat], fits [memo|chat|clip]}. Stdlib only.

Only what viewers already saw leaves the study (operator, 2026-10-13): a quote stays when it was spoken on stream,
posted in chat or a confession (its kind says voiced, chat or confession); thoughts, working text, private tells
between agents and shift summaries stay in the study document. A moment with no such quote is left out, and `seen`
is recomputed from the quotes kept."""
import json, re, sys

PUBLIC = re.compile(r"\b(voiced|chat|confession)\b")


def public(m):
    """The moment with only the quotes viewers saw (and `seen` from them), or None when it has none, or when an
    agent of the moment said nothing viewers saw (its point rests on private content: #25, a rediscovery made in a
    private thought). The study's context sentences stay in the study (some describe private reasoning)."""
    quotes = m.get("quotes") or []
    kept = [q for q in quotes if PUBLIC.search(str(q.get("kind") or "").lower())]
    if not kept:
        return None
    speakers = {q.get("who") for q in kept}
    if any(q.get("who") not in speakers for q in quotes):
        return None
    kinds = " ".join(str(q.get("kind") or "").lower() for q in kept)
    seen = [k for k, hit in (("voiced", "voiced" in kinds), ("chat", bool(re.search(r"\bchat\b|confession", kinds)))) if hit]
    agents = [a for a in m.get("agents") or [] if a in speakers] or sorted(speakers)
    # the time of what viewers saw, when the kept quotes give one (a header range can start at a private thought)
    times = [t for q in kept for t in re.findall(r"\b\d\d:\d\d\b", str(q.get("kind") or ""))]
    time = " and ".join(dict.fromkeys(times)) or m.get("time")
    # a title that quotes words viewers never saw (#18 '"Fair criticism."', Sonnet's working text) gives way to the
    # start of what they did see
    title = m.get("title") or ""
    said = re.match(r'^"(.+)"$', title.strip())
    if said and not any(said.group(1).strip(" .").lower() in q["text"].lower() for q in kept):
        words = kept[0]["text"].split()
        title = " ".join(words[:6]) + (" ..." if len(words) > 6 else "")
    return dict({k: v for k, v in m.items() if k not in ("seen_text", "context", "theme")}, agents=agents, quotes=kept,
                seen=seen, time=time, title=title)


def seen_only(rows):
    return [p for p in (public(m) for m in rows) if p]

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
    print(json.dumps(seen_only(parse(md)), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
