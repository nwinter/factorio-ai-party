#!/usr/bin/env python3
"""The live page's dashboard layout (d24 batch155 PY1, viewer Aurora site:4705: "could Research sit above Board, with
both spanning the full dashboard width on desktop? This would remove the empty half-column beside Board."):
python3 site/test_live_layout.py

static/live.js makes the cards in CARDS order; static/style.css places them on a 12-column grid (one column under
960 px). Research comes right before Board, and both span the 12 columns.
"""
import os, re

SITE = os.path.dirname(os.path.abspath(__file__))


def main():
    js = open(os.path.join(SITE, "static", "live.js")).read()
    m = re.search(r"var CARDS = \[(.*?)\];", js)
    assert m, "no CARDS in live.js"
    order = re.findall(r"\['(\w+)', '[^']*'\]", m.group(1))
    assert "research" in order and "board" in order, order
    assert order.index("research") + 1 == order.index("board"), f"Research is not right above Board: {order}"
    css = open(os.path.join(SITE, "static", "style.css")).read()
    assert ".live-dash { display: grid; grid-template-columns: repeat(12, minmax(0, 1fr));" in css
    spans = {}
    for sel, n in re.findall(r"^([^{}\n]*\.card-[^{}\n]*)\{ grid-column: span (\d+); \}", css, re.M):
        for card in re.findall(r"\.card-(\w+)", sel):
            spans[card] = int(n)
    assert spans.get("research") == 12 and spans.get("board") == 12, spans
    assert "@media (max-width: 960px) { .live-dash > * { grid-column: 1 / -1; } }" in css
    print("live layout: Research above Board, both full width: ok")


if __name__ == "__main__":
    main()
