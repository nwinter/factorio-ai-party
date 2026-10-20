#!/usr/bin/env python3
"""A platform between stops is "in transit" on the stream's labels (d20 batch50 F1): python3 tools/stream/test_orbitlabel.py

shift46 stream-service.log 08:50:28 "inset cue: Grok · Petrel · in orbit of in transit", 09:00:06 "platform visit: Anvil
· in orbit of in transit": the score row's `at` was "in transit" with no route read and a state that did not read as
flying, so OneCam.platform_label wrote "in orbit of" before it. Every builder of "in orbit of" + a location: this label,
model.platform_place (the hosts' facts) and ship_facts (the ship card) say "in transit" or the route instead; the
runtime's launch line names the planet a wait was for.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import world  # noqa: E402
from test_platformcam import plat, snap, team  # noqa: E402
from model import platform_place  # noqa: E402


def main():
    d, _ = world(map_every=0)
    rows = [plat("Petrel", at="in transit", state="waiting_at_station"), plat("Anvil", at="in transit", state=None),
            plat("Starling", at="nauvis"), plat("Cinder", at="nauvis->gleba 57%", toward="gleba")]
    d.step(snap(team(), rows), 1000)
    labels = {n: d.platform_label(n) for n in ("Petrel", "Anvil", "Starling", "Cinder")}
    assert labels["Petrel"] == "Petrel · in transit" and labels["Anvil"] == "Anvil · in transit", labels
    assert labels["Starling"] == "Starling · in orbit of Nauvis", labels
    assert labels["Cinder"].startswith("Cinder · travelling to Gleba (57%)"), labels
    assert not any("orbit of in transit" in v for v in labels.values())
    # the cue inset's label is built the same way ("Grok · " + platform_label)
    assert d.platform_target("Petrel", "cue", 1060, label="Grok · " + d.platform_label("Petrel"))["platform"]["label"] == \
        "Grok · Petrel · in transit"
    # the hosts' facts and the ship card
    assert platform_place({"name": "Petrel", "at": "in transit"}) == "in transit"
    assert d.ship_facts("Petrel") == {"name": "Petrel", "at": None}, d.ship_facts("Petrel")
    print("orbit label: ok (a platform between stops reads in transit, never in orbit of in transit)")


if __name__ == "__main__":
    main()
