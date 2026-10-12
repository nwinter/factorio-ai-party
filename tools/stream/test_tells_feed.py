#!/usr/bin/env python3
"""Tells in the chat feed (static/chatfeed.js, overlay.js renderChat): python3 tools/stream/test_tells_feed.py

- A burst of tells from one agent to the same recipients (each within 45 s of the last) folds into one line that
  shows the latest in full and how many came before; another recipient, a pause, or another sender starts a new line.
- Tells from a service started before they had their own lane ("→ Astra: text") read the same.
- Both pages load chatfeed.js before overlay.js, and the old two-line ticker is gone.
"""
import json, os, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")


def fold(tells):
    js = (f"const c = require({json.dumps(os.path.join(STATIC, 'chatfeed.js'))});"
          f"console.log(JSON.stringify(c.foldTells({json.dumps(tells)})))")
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def tell(seq, t, frm, to, body, old=False):
    m = {"seq": f"t{seq}", "t": t, "tick": seq * 60, "from": frm, "agent": frm, "tell": True,
         "text": f"→ {to}: {body}"}
    if not old:
        m.update(lane="tell", to_shown=to, body=body)
    return m


def main():
    tells = [tell(1, 100, "sol", "Astra", "need 40 plates"), tell(2, 110, "sol", "Astra", "chest at (3,4)"),
             tell(3, 112, "astra", "Sol", "on it"), tell(4, 130, "sol", "Astra", "thanks, belt's moving"),
             tell(5, 131, "sol", "team", "north belt down"), tell(6, 200, "sol", "Astra", "more plates please"),
             tell(7, 201, "luna", "Sol", "power is low", old=True)]
    groups = fold(tells)
    got = [(g["from"], g["to"], g["count"], g["body"]) for g in groups]
    assert got == [("sol", "Astra", 3, "thanks, belt's moving"),   # 100, 110, 130: one burst, the latest in full
                   ("astra", "Sol", 1, "on it"),
                   ("sol", "team", 1, "north belt down"),          # another recipient: its own line
                   ("sol", "Astra", 1, "more plates please"),      # 70 s later: a new line
                   ("luna", "Sol", 1, "power is low")], got        # the old "→ Sol: text" form
    assert groups[0]["t"] == 130 and groups[0]["first_t"] == 100 and groups[0]["key"] == "tg:t1"
    # out-of-order arrival folds the same
    assert [(g["count"], g["body"]) for g in fold(list(reversed(tells[:2])))] == [(2, "chest at (3,4)")]
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        srcs = re.findall(r'<script src="/static/([^"]+)"', html)
        assert srcs.index("chatfeed.js") < srcs.index("overlay.js"), (page, srcs)
        assert "chat-ticker" not in html, page
    js = open(os.path.join(STATIC, "overlay.js")).read()
    assert "pogChat.foldTells" in js and not re.search(r"(?<!function )renderTicker\(", js)  # never called
    print("tells feed: ok (bursts folded, old tell form read, both pages, ticker gone)")


if __name__ == "__main__":
    main()
