#!/usr/bin/env python3
"""Long tells with a summary line on the stream and the site (d27 batch273 TL): python3 tools/stream/test_tellsummary.py

A tell holds up to 2000 bytes; one over 500 has a summary (tells.lua). The overlay and the hosts show the summary, the
site the whole text and the summary.

1. model.py: a tell's `body` (the overlay's words) is its summary, `text` the whole tell, `summary` kept; a short tell
   as before.
2. chatfeed.js (the overlay's tell lines): the summary.
3. caster.agent_intent (what the hosts hear an agent meant): the summary, not 2000 bytes cut at 140.
4. push_live: the site's chat keeps `summary` beside the whole text, the newest lines within CHAT_BYTES; live.js shows
   the summary above the text, and the agent cards the summary.
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "site"))
from model import Model  # noqa: E402
import caster  # noqa: E402
import push_live  # noqa: E402

AUDIT = ("Silo (-18.5,17.5) launch 14 at tick 71945279: 25 uranium rounds received by Asterion. " * 20).strip()
SUMMARY = "Aquilo launch audit: 20 launches, all received by Asterion; ammo reserve ok"


def model_rows():
    m = Model({"agents": {"sol": {}, "astra": {}}})
    now = time.time()
    m._ingest_tell({"seq": 7, "tick": 100, "from": "sol", "to": ["astra"], "text": AUDIT, "summary": SUMMARY}, now)
    m._ingest_tell({"seq": 8, "tick": 101, "from": "astra", "to": ["sol"], "text": "ok, loading now"}, now)
    long_, short = [c for c in m.chat if c.get("tell")][-2:]
    assert long_["body"] == SUMMARY and long_["summary"] == SUMMARY, long_
    assert long_["text"].endswith(AUDIT) and long_["text"].startswith("→ "), long_["text"][:40]
    assert short["body"] == "ok, loading now" and "summary" not in short, short
    print("1. model: a long tell's body is its summary, its text whole; a short one as before: ok")
    return long_, short


def chatfeed(rows):
    js = (f"const c = require({json.dumps(os.path.join(HERE, 'static', 'chatfeed.js'))});"
          f"console.log(JSON.stringify(c.foldTells({json.dumps(rows)}).map(g => g.body)))")
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    got = json.loads(r.stdout)
    assert got == [SUMMARY, "ok, loading now"], got
    print("2. the overlay's tell lines: the summary: ok")


def hosts(long_):
    s = {"chat": [dict(long_, t=time.time())]}
    said = caster.agent_intent(s, {"name": "sol", "display_name": "Sol"})
    assert said and "Aquilo launch audit" in said and "tick 71945279" not in said, said
    print("3. the hosts: the summary: ok")


def site(long_, short):
    rows = push_live.public_chat([long_, short])
    assert rows[0]["summary"] == SUMMARY and rows[0]["text"].endswith(AUDIT), rows[0].keys()
    assert "body" not in rows[0] and "summary" not in rows[1]
    many = [dict(long_, seq=f"t{i}") for i in range(40)]
    kept = push_live.public_chat(many)
    size = sum(len(json.dumps(r, ensure_ascii=False).encode()) for r in kept)
    assert size <= push_live.CHAT_BYTES and kept[-1]["seq"] == "t39" and len(kept) >= 10, (size, len(kept))
    assert len(push_live.public_chat([short] * 60)) == push_live.CHAT_LINES
    js = open(os.path.join(ROOT, "site", "static", "live.js")).read()
    assert "c.summary ? ' <span class=\"tell-summary\">' + esc(c.summary)" in js
    assert "esc(c.summary ? '→ ' + c.summary : c.text)" in js
    print(f"4. the site: the whole text and its summary, {len(kept)} long tells within {push_live.CHAT_BYTES} bytes: ok")


def main():
    long_, short = model_rows()
    chatfeed([long_, short])
    hosts(long_)
    site(long_, short)
    print("test_tellsummary: ok")


if __name__ == "__main__":
    main()
