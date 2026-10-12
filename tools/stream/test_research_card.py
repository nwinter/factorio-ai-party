#!/usr/bin/env python3
"""The "Research complete" card: python3 tools/stream/test_research_card.py

- model.py: a technology the score shows finishing becomes research_news for 30 s; research.lua's board event adds
  what it unlocks, whether it comes before or after the score; an old event (a board history replayed at start)
  makes no card;
- static/segview.js researchCard: the newest under 8 s, three unlocks and "+N more";
- the pages have the card and the research alert banner gives way to it.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Model  # noqa: E402

STATIC = os.path.join(HERE, "static")


def ev(seq, tech, text):
    return {"seq": seq, "tick": 1000 + seq, "by": "research", "change": "done", "title": tech, "kind": "research",
            "status": "done", "text": text}


def model_tests():
    m = Model({"agents": {"astra": {}}})
    t = 1000.0
    m.ingest({"research": {"current": "automation", "done": ["logistics"], "top_done": ["logistics"]}}, t)
    # an old event replayed from the board's history: kept for its unlocks, but no card (the score did not change)
    m.ingest({"board_events": [ev(1, "logistics", "unlocks: underground-belt, splitter")]}, t + 1)
    assert m.snapshot(t + 1)["research_news"] == []
    # the board event first, then the score
    m.ingest({"board_events": [ev(2, "automation", "unlocks: assembling-machine-1, long-handed-inserter")]}, t + 5)
    m.ingest({"research": {"current": "electronics", "done": ["logistics", "automation"]}}, t + 6)
    news = m.snapshot(t + 7)["research_news"]
    assert [(n["label"], n["unlocks"], n["more"]) for n in news] == [
        ("Automation", ["Assembling machine 1", "Long handed inserter"], 0)], news
    # the score first, then the event (a poll later), with more unlocks than research.lua lists
    m.ingest({"research": {"current": None, "done": ["logistics", "automation", "electronics"]}}, t + 20)
    assert m.snapshot(t + 20)["research_news"][-1]["unlocks"] == []
    m.ingest({"board_events": [ev(3, "electronics", "unlocks: a, b, c, d, e, f, +2 more")]}, t + 22)
    n = m.snapshot(t + 22)["research_news"][-1]
    assert n["name"] == "electronics" and len(n["unlocks"]) == 6 and n["more"] == 2, n
    assert m.snapshot(t + 60)["research_news"] == []  # 30 s on the state
    return n


def card_tests(n):
    js = (f"const s = require({json.dumps(os.path.join(STATIC, 'segview.js'))});"
          f"console.log(JSON.stringify([s.researchCard({json.dumps([dict(n, age_s=3)])}), "
          f"s.researchCard({json.dumps([dict(n, age_s=9)])}), "
          f"s.researchCard([{{\"name\": \"x\", \"label\": \"X\", \"unlocks\": [], \"more\": 0, \"age_s\": 1}}])]))")
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    shown, gone, bare = json.loads(r.stdout)
    assert shown == {"key": "electronics", "label": "Electronics", "unlocks": "A, B, C +5 more"}, shown
    assert gone is None and bare == {"key": "x", "label": "X", "unlocks": ""}
    for page in ("index.html", "portrait.html"):
        assert 'id="research-card"' in open(os.path.join(STATIC, page)).read(), page
    js = open(os.path.join(STATIC, "overlay.js")).read()
    assert 'a.kind === "research" && s.research_news' in js and "renderResearchCard(s);" in js


def main():
    n = model_tests()
    card_tests(n)
    print("research card: ok (news from the score, unlocks either order, no card from old events, 8 s card)")


if __name__ == "__main__":
    main()
