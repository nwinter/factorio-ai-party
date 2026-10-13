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
check(luna["label"] == "Luna · inspecting" and "extent" not in luna, luna)
# too old: gone from the set
check(hl.items(m.snapshot(1000.0 + hl.WINDOW + 1, {})) == [], "old attention is not drawn")
# a platform point keeps its surface
snap2 = {"agents": [{"name": "astra", "display_name": "Astra", "color": [153, 119, 255],
                     "attention": {"kind": "building", "action": "place_ghosts", "verb": "placing ghosts", "what": "",
                                   "position": {"x": 3, "y": -4}, "extent": 0, "surface": "platform-2", "age_s": 2}}]}
a = hl.items(snap2)[0]
check(a["surface"] == "platform-2" and a["label"] == "Astra · placing ghosts" and a["color"]["b"] == 1.0, a)
# at most 12, newest first
many = {"agents": [{"name": f"a{i}", "attention": {"verb": "inspecting", "position": {"x": i, "y": 0}, "age_s": 20 - i}}
                   for i in range(15)]}
mi = hl.items(many)
check(len(mi) == 12 and mi[0]["agent"] == "a14", [x["agent"] for x in mi])
check(hl.rgb("#zzzzzz") is None and hl.rgb({"r": 0.5, "g": 0.5, "b": 0.5}) == {"r": 0.5, "g": 0.5, "b": 0.5}, "rgb")

# 3. sending
sent = []
reply = {"ok": True}
h = hl.Highlights(lambda body: (sent.append(body), reply)[1])
check(h.step(snap, 1005.0)["items"] == its and sent[-1]["ttl"] == 360, sent)
check(h.step(snap, 1005.2) is None, "never within MIN_GAP")
check(h.step(snap, 1006.0) is None, "unchanged: not again before REFRESH")
check(h.step(snap, 1009.1) is not None and len(sent) == 2, "refreshed before the objects expire")
empty = {"agents": []}
check(h.step(empty, 1010.0) == {"clear": True}, "an emptied set is cleared")
check(h.step(empty, 1011.0) is None and len(sent) == 3, "cleared once")
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

# 4. harness.py: only highlights goes out as an operator draw
import harness  # noqa: E402

check(harness.OPERATOR_DRAWS == {"highlights"}, harness.OPERATOR_DRAWS)
try:
    harness.Harness.operator_draw(object.__new__(harness.Harness), "camera", {})
    raise AssertionError("camera is not an operator draw")
except ValueError:
    pass
print("test_highlights: ok")
