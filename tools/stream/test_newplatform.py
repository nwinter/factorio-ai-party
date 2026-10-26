#!/usr/bin/env python3
"""A platform is new when it is new in the game: python3 tools/stream/test_newplatform.py

d26 batch239 NP (viewer-experience review, batch237 finding 5). shift80, 07:25:04 (tools/stream/logs/
caster-20261026-072406.jsonl): "Spindle is new. A fresh platform just appeared in orbit of Nauvis", from the cue "New
space platform: Spindle" (director-20261026-072406.jsonl 07:25:28); then 07:25:29 "Aethera reaches Vulcanus. Arrived in
orbit just now." Spindle (platform index 2) existed long before; the stream service had restarted at 07:24:06. What
happened (runs/shift80/chronicle.jsonl, space-memory.json): Aethera, a platform record Sol made at tick 19263840
(89h11m) that never had a hub, got its starter pack at tick 66355476; its hub was built and the score read listed it
from tick 66357277, first in the force's order. model.py keyed the first platform in the list "platform" and every
other "platform:NAME": Spindle, first until then, moved to a key never seen, a "new" platform; Aethera, listed at
Vulcanus with nothing remembered of it, "reached" Vulcanus. Checks:
1. that case: no Spindle, no "Aethera reaches Vulcanus"; Aethera's hub is the news, said as its own (made at 89h11m);
2. a restart mid-shift (the space memory kept) announces nothing again;
3. a restart whose first read has no space data (the score read failed; an agent's surface alone) seeds nothing: the
   next full read announces nothing;
4. a platform missing from one read and back in the next is not new; a platform made while the service runs is new;
5. research: a short first read then the full list announces nothing; one technology done after is news.
No clock: every time and tick is fixed.
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
from model import Model  # noqa: E402

T0 = 1793024646.0  # 07:24:06, the service start (director-20261026-072406)
TICK0 = 66352000  # about the game tick then
SEEN = 66357277  # Aethera first listed (space-memory.json stops)
# shift80's platforms in the force's order (pairs over force.platforms), where each was; Aethera without a hub until
# its starter pack landed
FLEET = [("Aethera", "vulcanus"), ("Spindle", "nauvis"), ("Cinder", "gleba"), ("Swiftlet", "nauvis->vulcanus 40%"),
         ("Kestrel II", "fulgora"), ("Petrel", "nauvis"), ("Limestone", "nauvis"), ("Anvil", "vulcanus"), ("Chalk", "nauvis"),
         ("Petrel II", "nauvis"), ("Kestrel IVa", "nauvis"), ("Kestrel IVb", "fulgora->aquilo 20%"), ("Kestrel IVc", "fulgora"),
         ("Solstice", "nauvis"), ("Asterion", "aquilo"), ("Petrel III", "nauvis"), ("Meridian-V", "gleba"), ("Weaver", "nauvis"),
         ("Needle", "nauvis"), ("Lark", "nauvis"), ("Loom", "vulcanus")]
HISTORY = {"Aethera": {"created": 19263840, "by": "sol", "at": "vulcanus", "left": []},
           "Loom": {"created": 66287460, "by": "sol", "at": "vulcanus", "left": []}}
PLANETS = ["aquilo", "fulgora", "gleba", "nauvis", "vulcanus"]


def space(aethera_hub=True, without=(), rockets=46990, extra=()):
    rows = [{"name": n, "at": at, "hub": n != "Aethera" or aethera_hub} for n, at in FLEET if n not in without]
    return {"rockets": rockets, "planets": PLANETS, "platforms": rows + list(extra)}


def model(mem=None):
    m = Model({"agents": {"sol": {"display_name": "Sol"}}, "space_age": True})
    m.platform_history = {k: dict(v) for k, v in HISTORY.items()}
    if mem:
        m.set_space_memory(mem)
    return m


def heads(m, kind="space"):
    return [a["text"] for a in m.alerts if a["kind"] == kind]


def the_case():
    mem = os.path.join(tempfile.mkdtemp(), "space-memory.json")
    m = model(mem)
    m.ingest({"tick": TICK0, "agents": [], "space": space(aethera_hub=False)}, now=T0 + 4)  # the restart's first read
    assert not m.moments, list(m.moments)
    m.ingest({"tick": TICK0 + 2000, "agents": [], "space": space(aethera_hub=False)}, now=T0 + 37)
    m.ingest({"tick": SEEN, "agents": [], "space": space()}, now=T0 + 88)  # Aethera's hub built: listed first
    titles = [x["title"] for x in m.moments]
    assert not any("Spindle" in t for t in titles), titles
    assert not any("reaches" in t for t in titles), titles
    assert titles == ["Aethera gets its hub, a platform made at 89h11m"], titles
    mo = m.moments[0]
    assert mo["kind"] == "new_platform" and mo["facts"]["made_by"] == "sol" and mo["facts"]["hub_built"] is True, mo
    assert not any("Spindle" in t for t in heads(m)), heads(m)
    print("the case: ok (" + titles[0] + "; no Spindle, no 'Aethera reaches Vulcanus')")
    return mem


def restart(mem):
    m = model(mem)  # the service restarts later in the shift: the space memory has every platform
    m.ingest({"tick": SEEN + 6000, "agents": [], "space": space()}, now=T0 + 400)
    m.ingest({"tick": SEEN + 6600, "agents": [], "space": space()}, now=T0 + 410)
    assert not m.moments and not heads(m), (list(m.moments), heads(m))
    print("restart: ok (nothing announced again)")


def empty_first_read():
    m = model()
    # the restart's first observe: the score read failed, an agent stands on Vulcanus
    m.ingest({"agents": [{"name": "sol", "alive": True, "position": {"x": 0, "y": 0}, "surface": "vulcanus"}]}, now=T0 + 4)
    m.ingest({"tick": TICK0, "agents": [], "space": space()}, now=T0 + 10)
    m.ingest({"tick": TICK0 + 600, "agents": [], "space": space()}, now=T0 + 20)
    assert not m.moments and not heads(m), (list(m.moments), heads(m))
    print("empty first read: ok (nothing seeded from it; nothing announced after)")


def blip_and_made():
    m = model()
    m.ingest({"tick": TICK0, "agents": [], "space": space()}, now=T0)
    m.ingest({"tick": TICK0 + 600, "agents": [], "space": space(without=("Spindle",))}, now=T0 + 10)
    m.ingest({"tick": TICK0 + 1200, "agents": [], "space": space()}, now=T0 + 20)
    assert not m.moments, list(m.moments)
    # a platform made now (the chronicle's creation a minute ago): new
    m.platform_history["Quill"] = {"created": TICK0 + 1500, "by": "sol", "at": "nauvis", "left": []}
    m.ingest({"tick": TICK0 + 1800, "agents": [], "space": space(extra=[{"name": "Quill", "at": "nauvis", "hub": True}])},
             now=T0 + 30)
    assert [x["title"] for x in m.moments] == ["New space platform: Quill"], list(m.moments)
    print("blip and made: ok (a platform back after one missing read is not new; one made now is)")


def research():
    m = model()
    done = ["automation", "logistics", "electronics", "steel-processing", "oil-processing", "advanced-circuit"]
    m.ingest({"tick": TICK0, "agents": [], "research": {"done": [], "current": None}}, now=T0)  # a short first read
    m.ingest({"tick": TICK0 + 60, "agents": [], "research": {"done": done, "current": None}}, now=T0 + 3)
    assert not heads(m, "research"), heads(m, "research")
    m.ingest({"tick": TICK0 + 120, "agents": [], "research": {"done": done + ["rocketry"], "current": None}}, now=T0 + 6)
    assert heads(m, "research") == ["Research complete: Rocketry"], heads(m, "research")
    print("research: ok (a short first read then the full list: nothing; one done after: news)")


if __name__ == "__main__":
    the_case_mem = the_case()
    restart(the_case_mem)
    empty_first_read()
    blip_and_made()
    research()
    print("test_newplatform: ok")
