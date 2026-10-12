#!/usr/bin/env python3
"""The replay on the overlay pages, under node: python3 tools/stream/test_replay_pages.py

1. The stream page's replay card (static/segview.js, used by overlay.js renderSegment) shows only while the replay
   segment is "starting" (the 2.5 s before the program cuts to the replay scene), not while it is live or after.
"""
import json, os, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")


def node(script):
    r = subprocess.run(["node", "-e", script], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def card_tests():
    cases = [(None, False),
             ({"type": "attack_replay", "state": "starting"}, True),
             ({"type": "attack_replay", "state": "live"}, False),   # the replay scene is on air: no card under it
             ({"type": "attack_replay", "state": "ended"}, False),
             ({"type": "production", "state": "starting"}, True),
             ({"type": "production", "state": "live"}, True),
             ({"type": "spotlight", "state": "ended"}, False)]
    got = node(f"const s = require({json.dumps(os.path.join(STATIC, 'segview.js'))});"
               f"console.log(JSON.stringify({json.dumps([c for c, _ in cases])}.map(s.cardVisible)))")
    assert got == [want for _, want in cases], list(zip(cases, got))
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        srcs = re.findall(r'<script src="/static/([^"]+)"', html)
        assert "segview.js" in srcs and srcs.index("segview.js") < srcs.index("overlay.js"), (page, srcs)
    assert "pogSeg.cardVisible(seg)" in open(os.path.join(STATIC, "overlay.js")).read()


def main():
    card_tests()
    print("replay pages: ok (card only while starting)")


if __name__ == "__main__":
    main()
