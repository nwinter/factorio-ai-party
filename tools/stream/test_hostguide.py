#!/usr/bin/env python3
"""Big moments are called with names and stakes: python3 tools/stream/test_hostguide.py

shift04 05:15:40, Rook: "Ooh, that hurts. A space platform hub is gone, and a solar panel too. Asteroids again." (that
was Skylark or Starling destroyed); shift05 07:48 and 08:37 "the space platform hub is getting hit" (no name); viewer
Joonazan: "<Space platform name> died to an asteroid would've been better than the slop they said", and "too
convoluted and AI-structured to be appealing". Checked here:
- model.py: losses and attacks on a platform carry its name and place; a platform gone from two space reads is a
  "headline" alert with name, place and cause (a rename or a one-read blip is not); the shift's first rocket and
  every new platform are moments; a death carries headline facts.
- caster.py: headlines outrank battle beats, are never folded into one, take two lines (Rook calls, Vale the stakes),
  and their facts and call reach the writer; the booth guide (DIALOGUE) is in every prompt.
"""
import os, sys, time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster, model  # noqa: E402


def space(*plats, rockets=40):
    return {"rockets": rockets, "planets": ["nauvis", "vulcanus"], "platforms": list(plats)}


def main():
    t = time.time()
    sky = {"name": "Skylark", "at": "vulcanus", "view": {"surface": "platform-2"}}
    star = {"name": "Starling", "at": "nauvis->vulcanus 40%", "view": {"surface": "platform-1"}}
    m = model.Model({"agents": {"astra": {}}, "space_age": True})
    m.ingest({"agents": [], "space": space(sky, star)}, t)

    # a loss line has no surface: the hub and the asteroids put it on a platform, by name only when that is certain
    m.ingest({"agents": [], "events": [{"kind": "loss", "key": "loss:1,2", "ttl": 90,
                                         "text": "1 lost near (1, 2): space platform hub (by medium metallic asteroids)",
                                         "position": {"x": 1, "y": 2, "surface": "nauvis"}}]}, t + 1)
    txt = m.alerts[-1]["text"]
    assert txt.startswith("1 lost on a space platform: space platform hub"), txt  # two platforms: not certain
    # an attack's surface names the platform
    m.ingest({"agents": [], "events": [{"kind": "attack", "key": "area:9,9", "ttl": 60,
                                         "text": "Base under attack near (9, 9): space platform hub",
                                         "position": {"x": 9, "y": 9, "surface": "platform-2"}}]}, t + 2)
    txt = m.alerts[-1]["text"]
    assert txt == "Platform Skylark (in orbit of Vulcanus) under attack: space platform hub", txt
    # with one platform left, a loss on it is named, and a lost hub says the platform is destroyed
    m1 = model.Model({"agents": {}, "space_age": True})
    m1.ingest({"agents": [], "space": space(sky)}, t)
    m1.ingest({"agents": [], "events": [{"kind": "loss", "key": "loss:3,4", "ttl": 90,
                                          "text": "2 lost near (3, 4): solar panel, space platform hub (by medium "
                                                  "metallic asteroids)", "position": {"x": 3, "y": 4}}]}, t + 1)
    txt = m1.alerts[-1]["text"]
    assert txt.startswith("2 lost on platform Skylark (in orbit of Vulcanus): solar panel, space platform hub") and \
        txt.endswith("the hub is gone, so Skylark is destroyed"), txt
    # Nauvis fights stay as they were
    m1.ingest({"agents": [], "events": [{"kind": "loss", "key": "loss:5,5", "ttl": 90,
                                          "text": "3 lost near (5, 5): transport belt (by small biter)",
                                          "position": {"x": 5, "y": 5}}]}, t + 2)
    assert m1.alerts[-1]["text"] == "3 lost near (5, 5): transport belt (by small biter)", m1.alerts[-1]

    # Skylark gone from two space reads: a headline with name, place and cause (from the hub loss before it)
    m.ingest({"agents": [], "events": [{"kind": "loss", "key": "loss:7,7", "ttl": 90,
                                         "text": "1 lost near (7, 7): space platform hub (by medium metallic asteroids)",
                                         "position": {"x": 7, "y": 7, "surface": "platform-2"}}]}, t + 3)
    m.ingest({"agents": [], "space": space(star)}, t + 4)
    assert not [a for a in m.alerts if a["kind"] == "headline"], "one read missing is not a loss yet"
    m.ingest({"agents": [], "space": space(star)}, t + 5)
    hl = [a for a in m.alerts if a["kind"] == "headline"]
    assert len(hl) == 1, list(m.alerts)
    h = hl[0]
    assert h["text"] == "Skylark destroyed in orbit of Vulcanus by medium metallic asteroids", h
    assert h["facts"]["platform"] == "Skylark" and h["facts"]["where"] == "in orbit of Vulcanus" and \
        h["facts"]["destroyed_by"] == "medium metallic asteroids" and h["facts"]["platforms_left"] == ["Starling"], h
    m.ingest({"agents": [], "space": space(star)}, t + 6)
    assert len([a for a in m.alerts if a["kind"] == "headline"]) == 1, "said once"
    # a blip (one read without it) and a rename are not losses
    m2 = model.Model({"agents": {}, "space_age": True})
    m2.ingest({"agents": [], "space": space(sky, star)}, t)
    m2.ingest({"agents": [], "space": space(star)}, t + 1)
    m2.ingest({"agents": [], "space": space(sky, star)}, t + 2)
    m2.ingest({"agents": [], "space": space(star)}, t + 3)
    m2.ingest({"agents": [], "space": space(dict(sky, name="Skylark II"), star)}, t + 4)
    m2.ingest({"agents": [], "space": space(dict(sky, name="Skylark II"), star)}, t + 5)
    assert not [a for a in m2.alerts if a["kind"] == "headline"], list(m2.alerts)

    # moments: the shift's first rocket, a new platform, each platform's first arrival at a planet
    m3 = model.Model({"agents": {}, "space_age": True})
    m3.ingest({"agents": [], "space": space(sky, rockets=40)}, t)
    m3.ingest({"agents": [], "space": space(sky, dict(star, name="Peregrine", at="vulcanus"), rockets=41)}, t + 1)
    kinds = sorted(x["kind"] for x in m3.moments)
    assert kinds == ["new_platform", "orbit", "shift_rocket"], kinds
    al = [a for a in m3.alerts if a["kind"] == "space"]
    assert all(a.get("facts", {}).get("headline") for a in al), al
    assert any(a["text"] == "Rocket 41 launched, the first this shift" for a in al), al

    # caster: alert facts reach the event; headlines rank first and are said alone, in two lines
    d = caster.Differ()
    d.diff({"agents": []})
    ev = d.diff({"agents": [], "alerts": [dict(h, id="h1")]})
    he = [e for e in ev if e["kind"] == "headline"]
    assert he and he[0]["facts"]["platform"] == "Skylark" and he[0]["prio"] > caster.PRIORITY["attack"], ev
    f = caster.facts_for(he[0], {"agents": [], "game_time": "17h23m"})
    assert f["headline"]["platform"] == "Skylark" and f["what_happened"].startswith("Skylark destroyed")
    assert "leading with the name" in f["how_to_call_it"] and "destroyed, not damaged" in f["how_to_call_it"]
    df = caster.facts_for({"kind": "death", "text": "Astra died", "t": t, "prio": 10,
                           "facts": {"headline": "agent_death", "agent": "Astra"}}, {"agents": []})
    assert "respawns" in df["how_to_call_it"], df
    notes = caster.spoken_notes()
    assert caster.DIALOGUE in notes and "Rook calls the play" in caster.DIALOGUE and "status tag" in caster.DIALOGUE
    assert "Skylark" not in caster.DIALOGUE, "examples use made-up names"
    src = open(os.path.join(HERE, "caster.py")).read()
    assert 'n, first = max(n, 2), "pbp"' in src  # a headline is a two-line exchange, Rook first
    print("hostguide ok: platform names on fights, destroyed platform headline (name, place, cause), shift rocket "
          "and new platforms, headlines alone and first, booth guide in the prompt")


if __name__ == "__main__":
    main()
