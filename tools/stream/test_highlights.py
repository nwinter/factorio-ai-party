#!/usr/bin/env python3
"""Camera highlights (highlights.py; Nick 2026-10-13 12:58: show what the agents act on inside the camera picture):
python3 tools/stream/test_highlights.py

1. attention.py: rearm with positions reads "rearming 12 turrets"; mine and shoot are attention points; head() is the
   label without where.
2. items(): each agent's attention under WINDOW seconds old with a position -> {agent, position, surface, extent,
   label "Sol · ...", color}, newest first, at most 12; a platform point keeps its surface.
3. Highlights.step: one call per change, never within MIN_GAP, an unchanged set again after REFRESH, a clear once when
   the set empties, nothing when nothing was drawn, off after FAIL_LIMIT refusals, an RCON error counted as one.
4. harness.py sends only `highlights` as an operator draw.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import attention  # noqa: E402
import highlights as hl  # noqa: E402
from model import Model  # noqa: E402


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# 1. attention points
p = attention.point("rearm", {"positions": [{"x": i, "y": 0} for i in range(12)], "ammo": "firearm-magazine"})
check(p and attention.head(p) == "rearming 12 turrets", p)
check(attention.head(attention.point("mine", {"position": {"x": 3, "y": 4}})) == "mining", "mine")
s = attention.point("shoot", {"position": {"x": 3, "y": 4}})
check(s["kind"] == "fighting" and attention.head(s) == "shooting at", s)
g = attention.point("place_ghosts", {"entities": [{"name": "gun-turret", "position": {"x": 1, "y": 1}}]})
check(attention.head(g) == "placing gun turret ghosts", g)
check(attention.text(g, {"x": 1, "y": 41}) == "placing gun turret ghosts 40 m north", attention.text(g, {"x": 1, "y": 41}))
check(attention.point("rearm", {"radius": 30}) is None, "rearm by radius names no place")

# 2. items from a model snapshot
run = {"agents": {"sol": {"display_name": "Sol", "color": "#ffcb45"}, "luna": {"display_name": "Luna"}}}
m = Model(run)
m.ingest({"agents": [{"name": "sol", "position": {"x": 0, "y": 0}, "alive": True},
                     {"name": "luna", "position": {"x": 100, "y": 0}, "alive": True}],
          "attention": [dict(p, agent="sol"), dict(attention.point("inspect", {"position": {"x": 104, "y": 2}}), agent="luna")]},
         1000.0)
snap = m.snapshot(1005.0, {})
its = hl.items(snap)
check(len(its) == 2, its)
sol = next(i for i in its if i["agent"] == "sol")
check(sol["label"] == "Sol · rearming 12 turrets" and sol["surface"] == "nauvis", sol)
check(sol["extent"] == 11.0 and sol["position"] == {"x": 5.5, "y": 0.0}, sol)
check(sol["color"] == {"r": 1.0, "g": 0.796, "b": 0.271}, sol["color"])
luna = next(i for i in its if i["agent"] == "luna")
# an inspect names no entity: the harness fills {entity} with what stands there ("inspecting gun turret")
check(luna["label"] == "Luna · inspecting {entity}" and "extent" not in luna, luna)
# looking reads apart from acting; both fade over WINDOW (alpha in quarter steps) and end at it (ttl)
check(luna["kind"] == "looking" and sol["kind"] == "acting", (luna, sol))
check(sol["alpha"] == 0.5 and sol["ttl"] == 300, sol)  # 5 s old of 10
check(hl.items(m.snapshot(1001.0, {}))[0]["alpha"] == 1.0, "fresh: full")
check(all(i["alpha"] == 0.25 and i["ttl"] == 60 for i in hl.items(m.snapshot(1009.0, {}))), "nearly gone: faint")
# too old: gone from the set
check(hl.items(m.snapshot(1000.0 + hl.WINDOW, {})) == [], "attention WINDOW s old is not drawn")
# a place_ghosts says how many
g12 = attention.point("place_ghosts", {"entities": [{"name": "gun-turret", "position": {"x": i, "y": 0}} for i in range(12)]})
check(hl.label(g12) == "placing 12 gun turret ghosts", hl.label(g12))
g3 = attention.point("place_ghosts", {"entities": [{"name": n, "position": {"x": i, "y": 0}} for i, n in enumerate(["pipe", "pump", "pipe"])]})
check(hl.label(g3) == "placing 3 ghosts", hl.label(g3))
m.ingest({"attention": [dict(g12, agent="sol")]}, 1006.0)
check(hl.items(m.snapshot(1007.0, {}))[0]["label"] == "Sol · placing 12 gun turret ghosts", "the count reaches the snapshot")
m.ingest({"attention": [dict(p, agent="sol")]}, 1000.0)
# a platform point keeps its surface
snap2 = {"agents": [{"name": "astra", "display_name": "Astra", "color": [153, 119, 255],
                     "attention": {"kind": "building", "action": "place_ghosts", "verb": "placing ghosts", "what": "",
                                   "position": {"x": 3, "y": -4}, "extent": 0, "surface": "platform-2", "age_s": 2}}]}
a = hl.items(snap2)[0]
check(a["surface"] == "platform-2" and a["label"] == "Astra · placing ghosts" and a["color"]["b"] == 1.0, a)
# at most 12, newest first
many = {"agents": [{"name": f"a{i}", "attention": {"verb": "inspecting", "position": {"x": i, "y": 0}, "age_s": 9.5 - i * 0.5}}
                   for i in range(15)]}
mi = hl.items(many)
check(len(mi) == 12 and mi[0]["agent"] == "a14", [x["agent"] for x in mi])
check(hl.rgb("#zzzzzz") is None and hl.rgb({"r": 0.5, "g": 0.5, "b": 0.5}) == {"r": 0.5, "g": 0.5, "b": 0.5}, "rgb")

# 3. sending
sent = []
reply = {"ok": True}
h = hl.Highlights(lambda body: (sent.append(body), reply)[1])
check(h.step(snap, 1005.0)["items"] == its and sent[-1]["ttl"] == 240, sent)
check(h.step(snap, 1005.2) is None, "never within MIN_GAP")
check(h.step(snap, 1006.0) is None, "unchanged: not again before REFRESH")
check(h.step(snap, 1007.1) is not None and len(sent) == 2, "refreshed before the objects expire")
# the next fade step is a change: sent at once
check(h.step(m.snapshot(1008.0, {}), 1008.0) is not None and len(sent) == 3, "a new fade step goes out")
empty = {"agents": []}
check(h.step(empty, 1010.0) == {"clear": True}, "an emptied set is cleared")
check(h.step(empty, 1011.0) is None and len(sent) == 4, "cleared once")
check(h.public() == {"on": True, "items": 0, "error": None}, h.public())
# refusals (an older runtime): off after FAIL_LIMIT in a row; an RCON error counts too
reply = {"ok": False, "error": {"message": "operator requests support board, ..."}}
h2 = hl.Highlights(lambda body: reply)
for t in range(hl.FAIL_LIMIT):
    h2.step(snap, 2000.0 + t)
check(h2.off and h2.step(snap, 2100.0) is None, "off after refusals")


def boom(body):
    raise OSError("rcon down")


h3 = hl.Highlights(boom)
h3.step(snap, 3000.0)
check(h3.fails == 1 and "rcon down" in h3.last_error["message"] and not h3.off, h3.last_error)

# 3b. speech bubbles: an agent line playing (snapshot voiced) -> a bubble over the character for the rest of the clip
voiced = {"agents": [], "voiced": [{"id": "c1", "channel": "agent", "agent": "sol", "text": "I will  take\nthe north wall",
                                    "duration": 6.0, "started": 5000.0}]}
b = hl.bubbles(voiced, 5002.0)
check(b == [{"agent": "sol", "text": "I will take the north wall", "ttl": 240, "id": "c1"}], b)
check(hl.bubbles(voiced, 5005.8) == [], "a clip nearly done gets none")
sent4 = []
h4 = hl.Highlights(lambda body: (sent4.append(body), {"ok": True})[1])
body = h4.step(voiced, 5002.0)
check(body["items"] == [] and body["bubbles"] == [{"agent": "sol", "text": "I will take the north wall", "ttl": 240}], body)
check(h4.step(voiced, 5003.0) is None, "the same line: not again before REFRESH (its ttl shrinking is no change)")
check(h4.step({"agents": [], "voiced": []}, 5007.0) == {"clear": True}, "the line over: cleared")

# 4. harness.py: only highlights goes out as an operator draw
import harness  # noqa: E402

check(harness.OPERATOR_DRAWS == {"highlights"}, harness.OPERATOR_DRAWS)
try:
    harness.Harness.operator_draw(object.__new__(harness.Harness), "camera", {})
    raise AssertionError("camera is not an operator draw")
except ValueError:
    pass
print("test_highlights: ok")
