#!/usr/bin/env python3
"""Viewer Q&A pins in the chat panel (static/chatfeed.js viewerPins, overlay.js renderPins): python3 tools/stream/test_viewer_pins.py

shift01 16:09: Nick saw Astra's "Yes, Craig, ..." (seq 231) for a split second before the agents' tells pushed it out
of the chat panel. Now:
- A viewer's line, or a viewer's line with an agent's answer to it, is pinned above the feed for 25 s; at most two
  pins, newest first; a pinned line leaves the feed meanwhile and comes back to it afterwards.
- An answer names the viewer the way the hosts detect it (caster.viewer_short_names): "Craig" for craigNZ830,
  "@craigNZ830"; short forms of 3 letters or fewer only with @.
- Both pages (index.html, portrait.html) have #chat-pins above #chat-list and load chatfeed.js before overlay.js.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True


def js(expr, data):
    code = (f"const c = require({json.dumps(os.path.join(STATIC, 'chatfeed.js'))});"
            f"const d = {json.dumps(data)}; console.log(JSON.stringify({expr}))")
    r = subprocess.run(["node", "-e", code], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def pins(now, chat, viewers):
    return [(p["kind"], p["v"]["name"], (p.get("m") or {}).get("agent"), p["t"])
            for p in js("c.viewerPins(d)", {"now": now, "chat": chat, "viewers": viewers})]


def main():
    # shift01 (runs/shift01/chat.jsonl): Craig asks at 16:07:53, Astra answers at 16:09:16, then the tells roll in
    T0 = 1_791_850_073.0
    craig = {"id": "yt:c223", "seq": 41, "source": "youtube", "name": "craigNZ830",
             "text": "Will they make a proper big base in the end??", "t": T0}
    answer = {"seq": 231, "tick": 350634, "from": "Astra", "agent": "astra", "lane": "talk", "t": T0 + 83,
              "text": "Yes, Craig—the base is growing north now. We have forty-eight iron furnaces running, and the "
                      "next outpost will feed steel separately so science keeps its share."}
    tells = [{"seq": f"t{i}", "tick": 350640 + i * 60, "from": "Sol", "agent": "sol", "tell": True, "lane": "tell",
              "to_shown": "Astra", "body": f"plates {i}", "text": f"→ Astra: plates {i}", "t": T0 + 84 + i}
             for i in range(12)]
    chat = [answer] + tells
    viewers = [craig]

    assert pins(T0 + 5, [], viewers) == [("viewer", "craigNZ830", None, T0)], "a viewer's line is pinned on arrival"
    assert pins(T0 + 26, [], viewers) == [], "and unpinned after 25 s"
    got = pins(T0 + 83 + 12, chat, viewers)
    assert got == [("qa", "craigNZ830", "astra", T0 + 83)], got  # 12 tells later the pair is still up
    assert pins(T0 + 83 + 24, chat, viewers) == got, "pinned for 25 s from the answer"
    assert pins(T0 + 83 + 26, chat, viewers) == [], "then back in the feed"
    p = js("c.viewerPins(d)[0]", {"now": T0 + 90, "chat": chat, "viewers": viewers})
    assert (p["vkey"], p["mkey"]) == ("v:yt:c223", "231"), p  # the feed's keys for these lines (overlay renderChat)

    # gemini at 15:56:45 answered "@craigNZ830" 11 s after his question; a later question does not take that answer
    q1 = {"id": "yt:c202", "source": "youtube", "name": "craigNZ830", "t": 1000.0,
          "text": "So no human interaction at all in the game?"}
    q2 = dict(q1, id="yt:c206", t=1030.0, text="so weird. Factorio is my favourite game though")
    gem = {"seq": 203, "from": "Gemini", "agent": "gemini", "lane": "talk", "t": 1011.0,
           "text": "Hey @craigNZ830! It is an all-autonomous AI multi-agent team"}
    got = pins(1020.0, [gem], [q1, q2])
    assert got == [("qa", "craigNZ830", "gemini", 1011.0)], got
    got = pins(1031.0, [gem], [q1, q2])
    assert got == [("viewer", "craigNZ830", None, 1030.0), ("qa", "craigNZ830", "gemini", 1011.0)], got

    # at most two, newest first; a third newer pin pushes the oldest back into the feed
    vs = [{"id": f"v{i}", "source": "site", "name": f"fan{i}", "text": f"hello {i}", "t": 2000.0 + i * 5} for i in range(3)]
    assert [x[1] for x in pins(2012.0, [], vs)] == ["fan2", "fan1"]

    # names: the hosts' rule; short forms of 3 letters or fewer need @; tells, viewer copies and old answers don't pair
    import caster
    for name in ["craigNZ830", "noscopersscope3718", "Al", "NickWinter", "beltqueen", "x_y_99"]:
        assert js("c.viewerShortNames(d)", name) == caster.viewer_short_names(name), name
    assert js("c.answersViewer(d[0], d[1])", ["Yes, Craig, soon", "craigNZ830"])
    assert js("c.answersViewer(d[0], d[1])", ["thanks @al", "Al"])
    assert not js("c.answersViewer(d[0], d[1])", ["al the furnaces are full", "Al"])
    assert not js("c.answersViewer(d[0], d[1])", ["craigslist? no", "craigNZ830"])
    old = dict(answer, t=T0 + 700)  # more than 10 minutes after the question
    assert pins(T0 + 705, [old], viewers) == []
    as_tell = dict(answer, tell=True, lane="tell")
    copy = dict(answer, agent=None, viewer=True, lane="viewer", text="Craig: hi")
    assert pins(T0 + 90, [as_tell, copy], viewers) == []

    # both pages: the pin box above the feed, chatfeed.js before overlay.js; overlay.js takes pinned lines out of the feed
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        assert re.search(r'id="chat-pins"></div>\s*<div id="chat-list"', html), page
        assert html.index('src="/static/chatfeed.js"') < html.index('src="/static/overlay.js"'), page
    ov = open(os.path.join(STATIC, "overlay.js")).read()
    assert "viewerPins(s)" in ov and "pinnedKeys.has(it.key)" in ov and 'renderPins(s, pins)' in ov
    print("viewer pins ok")


if __name__ == "__main__":
    main()
