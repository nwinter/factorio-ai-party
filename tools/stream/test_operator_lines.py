#!/usr/bin/env python3
"""The operator's game-chat lines are seen and heard: python3 tools/stream/test_operator_lines.py

shift01 16:25: the operator wrote in game chat as `server` ("Thanks Craig! Your camera idea is live ..."); Nick: "I
think it was in the in-game Factorio chat but cut-off and not easy to see or voiced." Now:
- model.py puts `server` lines in lane "operator" ("harness vN:" changelog lines stay "log" for the board panel).
- The page shows them in the feed with an OP badge, labelled Operator, and pins them for 25 s (chatfeed.js); both pages.
- The caster voices each one at once in voices.OPERATOR_VOICE (Aura-2, never an agent's or a host's), channel
  "operator", ranked like an agent line, outside the agents' pacing; the hosts may react afterwards. The page's voice
  caption (audio.js) shows "Operator" with an OP badge and no avatar.
"""
import argparse, json, os, re, subprocess, sys, threading, random
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster, model, voices  # noqa: E402

LINE = ("Thanks Craig! Your camera idea is live: when the player on air stands still, the camera now moves on to "
        "someone who is busy. Pinned replies to viewers are coming next.")


def main():
    # model: the lane
    assert model.chat_lane({"from": "server", "text": LINE}) == "operator"
    assert model.chat_lane({"from": "server", "text": "harness v7: plan_run macros"}) == "log"
    assert model.chat_lane({"from": "server", "text": "server: harness v7: plan_run"}) == "log"
    assert model.chat_lane({"from": "sol", "agent": "sol", "text": LINE}) == "talk"
    # the chat window keeps operator and viewer lines apart from logistics, which must not push them out
    win = model.Model.chat_window
    fake = type("M", (), {})()
    fake.chat = deque([{"seq": 1, "lane": "operator", "text": LINE}] +
                      [{"seq": 2 + i, "lane": "log", "text": f"ack {i}"} for i in range(30)])
    assert any(r["lane"] == "operator" for r in win(fake)), "30 logistics lines must not push the operator out"

    # the page: pinned for 25 s, then in the feed; OP badge, Operator label, on both pages
    node = subprocess.run(["node", "-e", (
        f"const c = require({json.dumps(os.path.join(STATIC, 'chatfeed.js'))});"
        "const s = (now) => ({now, tick: 408410 + (now - 1000) * 60, viewers: [],"
        " chat: [{seq: 281, tick: 408410, from: 'server', lane: 'operator', t: 1000, text: 'Thanks Craig!'}]});"
        "console.log(JSON.stringify([c.viewerPins(s(1010)), c.viewerPins(s(1026))]))")], capture_output=True, text=True)
    assert node.returncode == 0, node.stderr
    at10, at26 = json.loads(node.stdout)
    assert [(p["kind"], p["keys"]) for p in at10] == [("operator", ["281"])], at10
    assert at26 == [], at26
    ov = open(os.path.join(STATIC, "overlay.js")).read()
    assert 'function operatorRow(m)' in ov and 'el("div", "obadge", "OP")' in ov and '"Operator"' in ov
    assert 'm.lane === "operator"' in ov  # in the feed after its pin
    css = open(os.path.join(STATIC, "overlay.css")).read()
    assert ".msg.operator" in css and ".msg .obadge" in css and ".pin.operator" in css
    assert ".msg .obadge" in open(os.path.join(STATIC, "portrait.css")).read()
    for page in ("index.html", "portrait.html"):
        html = open(os.path.join(STATIC, page)).read()
        assert 'id="chat-pins"' in html and "audio.js" in html, page
    au = open(os.path.join(STATIC, "audio.js")).read()
    assert 'clip.channel === "operator"' in au and 'who.textContent = "Operator"' in au and '"obadge"' in au
    assert re.search(r'VOL\[clip\.channel === "agent" \|\| clip\.channel === "operator"', au)

    # the caster: Differ -> an "operator" event (not an agent chat line), queued apart from the agents' lines
    d = caster.Differ()
    snap = {"agents": [], "chat": []}
    d.diff(snap)  # first snapshot: nothing is news
    now = __import__("time").time()
    ev = d.diff({"agents": [], "chat": [{"seq": 281, "tick": 408410, "from": "server", "lane": "operator", "t": now,
                                         "text": LINE},
                                        {"seq": 282, "from": "server", "lane": "log", "t": now, "text": "harness v8: x"}]})
    ops = [e for e in ev if e["kind"] == "operator"]
    assert [e["text"] for e in ops] == [LINE] and not [e for e in ev if e["kind"] == "chat"], ev
    assert caster.is_operator_line({"from": "server", "text": LINE})  # a snapshot without lanes
    assert not caster.is_operator_line({"from": "server", "text": "harness v8: plan_run"})

    c = caster.Caster.__new__(caster.Caster)
    c.lock, c.snap, c.differ = threading.Lock(), None, caster.Differ()
    c.events, c.chat_q = deque(maxlen=60), deque(maxlen=30)
    c.on_snapshot({"agents": [], "chat": []})
    c.on_snapshot({"agents": [], "chat": [{"seq": 281, "from": "server", "lane": "operator", "t": now, "text": LINE}]})
    assert [e["text"] for e in c.op_q] == [LINE] and not c.chat_q
    assert [e["kind"] for e in c.events] == ["open"], c.events  # only the first snapshot's opening

    # operator_tick: voiced at once in its own voice, channel operator, ranked like an agent line; the hosts may react
    pushed = []
    c.voice = lambda text, voice_id, cst, meta, rec, hold=None: pushed.append((text, voice_id, meta, rec)) or 4.0
    c.stats, c.history, c.rng = {"agent_lines": 0}, deque(maxlen=12), random.Random(1)
    c.a = argparse.Namespace(react=1.0, yield_s=30)
    c.agent_free = c.caster_free = 0.0
    c.snap = {"game_time": "4h10m"}
    c.operator_tick()
    assert len(pushed) == 1, pushed
    text, vid, meta, rec = pushed[0]
    assert vid == voices.OPERATOR_VOICE and meta["channel"] == "operator" and meta["speaker"] == "Operator"
    assert meta["rank"] == "agent" and rec["type"] == "operator" and text.startswith("Thanks Craig")
    assert not c.op_q and c.stats["operator_lines"] == 1 and c.history[-1].startswith("operator at")
    e = c.yielding["event"]
    assert e["operator"] and e["react"] and e["kind"] == "chat"
    f = caster.facts_for(dict(e, t=now), {"agents": [], "game_time": "4h10m"})
    assert "operator" in f["how_to_call_it"] and f["operator_said"].startswith("Thanks Craig")

    # the voice: Aura-2, no host's, no premium voice's stand-in, never an agent's default
    assert voices.OPERATOR_VOICE in voices.VOICES
    assert voices.OPERATOR_VOICE not in voices.CASTERS.values()
    assert voices.OPERATOR_VOICE not in {v for vs in voices.ROLE_VOICES.values() for v in vs}
    assert voices.OPERATOR_VOICE not in {e[3] for e in voices.PREMIUM.values()}
    many = [{"name": f"agent{i}"} for i in range(40)]
    assert voices.OPERATOR_VOICE not in voices.assign_voices(many).values()
    print("operator lines: ok (lane, pin 25 s, feed and caption badge on both pages, voiced at once in "
          f"{voices.OPERATOR_VOICE}, hosts may react)")


if __name__ == "__main__":
    main()
