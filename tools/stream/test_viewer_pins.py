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


def pins(now, chat, viewers, tick=None):
    """(kind, viewer, the answering agent(s) or None, pinned since) per pin."""
    out = []
    for p in js("c.viewerPins(d)", {"now": now, "chat": chat, "viewers": viewers, "tick": tick}):
        ans = [a["agent"] for a in p.get("answers") or []]
        out.append((p["kind"], (p.get("v") or {}).get("name"), (ans[0] if len(ans) == 1 else tuple(ans)) or None, p["t"]))
    return out


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
    assert p["keys"] == ["v:yt:c223", "231"], p  # the feed's keys for these lines (overlay renderChat)

    # shift01 16:16-16:32, Joonazan (runs/shift01/chat.jsonl seqs 253-283; lane rows as viewers.py has them, game copies
    # as the relay posted them). The 16:31 restart stamped every chat line with t = 16:31, so ages go by game ticks.
    J = 1_791_850_601.0  # 16:16:41
    def jv(i, dt, text):
        return {"id": f"yt:j{i}", "source": "youtube", "name": "Joonazan", "text": text, "t": J + dt}
    def copy(seq, tick, text):
        return {"seq": seq, "tick": tick, "from": "viewer Joonazan", "text": text, "viewer": True, "lane": "viewer"}
    q253 = "@sol Why is the gamma of the ingame image way too high? It was normal for a while."
    q256 = "Ah, instead of modding darkness out, the image is adjusted"
    q266 = ("@astra Are the agents replying to me also playing? So I could help or hinder their efforts akin to Twitch "
            "plays Pokemon?")
    q283 = ("Your should dedicate one or two to figuring out where the attacks are coming from, placing turrets there "
            "and killing ne…")
    lane = [jv(1, 0, q253.replace("@sol ", "")), jv(2, 64, q256), jv(3, 184, q266.replace("@astra ", "")),
            jv(4, 621, q283.rstrip("…") + "sts before they grow")]
    sol = {"seq": 254, "tick": 377481, "from": "sol", "agent": "sol", "lane": "talk", "aloud": True,
           "text": "Joonazan, I cannot see or control the stream gamma settings. I will pass the image brightness issue "
                   "to the operator."}
    astra = {"seq": 267, "tick": 389040, "from": "astra", "agent": "astra", "lane": "talk", "aloud": True,
             "text": "Joonazan, yes, I am both answering you and building the factory. Your suggestions reach us in "
                     "chat, so you can help us spot mistakes or propose plans. We still choose and carry out the game "
                     "actions ourselves."}
    gchat = [copy(253, 377166, q253), sol, copy(256, 380893, q256), copy(266, 388176, q266), astra,
             copy(283, 414293, q283)]
    restart = J + 870  # 16:31:11: serve.py restamps the chat it reads
    stamped = [dict(m, t=restart) for m in gchat]
    assert pins(restart + 60, stamped, lane, tick=414293 + 60 * 300) == [], \
        "after a restart, twelve-minute-old answers do not pin again (game ticks say how old they are)"
    # live, each answer as it came: Sol's pairs with the gamma question, Astra's with "Are the agents ... playing?"
    live = [dict(m, t=J + (m["tick"] - 377166) / 60) for m in gchat]
    got = pins(J + 10, live[:2], lane[:1], tick=377166 + 600)
    assert [(k, n, a) for k, n, a, _ in got] == [("qa", "Joonazan", "sol")], got
    p = js("c.viewerPins(d)[0]", {"now": J + 10, "chat": live[:2], "viewers": lane[:1], "tick": 377166 + 600})
    assert p["v"]["text"].startswith("Why is the gamma"), p["v"]
    now = J + (389040 - 377166) / 60 + 5
    p = js("c.viewerPins(d)", {"now": now, "chat": live[:5], "viewers": lane[:3], "tick": 389040 + 300})
    assert len(p) == 1 and p[0]["kind"] == "qa" and p[0]["v"]["text"].startswith("Are the agents replying"), p
    assert [a["agent"] for a in p[0]["answers"]] == ["astra"]
    # word match over recency: an answer about the image brightness, given after the later questions, still pairs
    # with the gamma question
    late = {"seq": 282, "tick": 377166 + 60 * 500, "from": "luna", "agent": "luna", "lane": "talk", "t": J + 500,
            "text": "Joonazan, the image brightness and gamma are the operator's side, not ours."}
    p = js("c.viewerPins(d)", {"now": J + 505, "chat": live[:5] + [late], "viewers": lane[:3],
                               "tick": 377166 + 60 * 505})
    assert p[0]["v"]["text"].startswith("Why is the gamma"), p[0]["v"]
    # two answers to one question share its pin
    both = {"seq": 268, "tick": 389100, "from": "grok", "agent": "grok", "lane": "talk", "t": live[4]["t"] + 1,
            "text": "Joonazan, same here: playing and chatting at once."}
    p = js("c.viewerPins(d)", {"now": live[4]["t"] + 5, "chat": live[:5] + [both], "viewers": lane[:3],
                               "tick": 389100 + 240})
    assert len(p) == 1 and [a["agent"] for a in p[0]["answers"]] == ["astra", "grok"], p
    assert p[0]["keys"] == ["v:yt:j3", "267", "268"], p[0]["keys"]

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

    # delivery on each viewer line (viewers.py Relay: delivery, to, to_all), display names from the snapshot
    agents = [{"name": "astra", "display_name": "Astra"}, {"name": "sol", "display_name": "Soul"}]
    lab = lambda v: js("c.deliveryLabel(d[0], d[1])", [v, agents])  # noqa: E731
    assert lab({"delivery": "sent", "relayed": True, "to": "astra", "to_all": ["astra"]}) == "→ Astra"
    assert lab({"delivery": "sent", "relayed": True, "to": "astra", "to_all": ["astra", "sol"]}) == "→ Astra, Soul"
    assert lab({"delivery": "sent", "relayed": True}) == "→ team"
    assert lab({"delivery": "too_soon"}) == "not sent: too soon"
    assert lab({"delivery": "waiting"}) == "queued"
    assert lab({"delivery": "busy"}) == "not sent: chat busy"
    assert lab({"chatter": True}) == "" and lab({}) == ""
    ov = open(os.path.join(STATIC, "overlay.js")).read()
    assert ov.count("showDelivery(") >= 3, "feed and pins show delivery"  # definition + feed + pins

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
