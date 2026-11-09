#!/usr/bin/env python3
"""A ship on camera (d19 batch42, viewer Foobator): python3 tools/stream/test_shipcard.py

C1. Every camera showing a platform (a platform shot, or an agent aboard) carries `ship` (onecam.py ship_facts): at a
    planet {name, at}, travelling {name, from, to, pct, speed_kms}, paused when it is; the overlay draws it as a card.
C2. A platform shot taller than the view at its zoom (Bastion in flight: 129 x 174 tiles with the flight margin, the
    view ~113 tiles high at zoom 0.3) has a `pan` (model.platform_shot); OneCam starts it at the bow (north) and moves
    it to the stern during the shot (pan_step: PAN_END_S at each end, a leg of at most PAN_LEG_S, back and forth on a
    long hold). A ship that fits has no pan, and the classic director keeps the centre.
"""
import os, sys, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import world  # noqa: E402
from test_platformcam import plat, snap, team, main_row  # noqa: E402
from model import platform_shot  # noqa: E402

# Bastion as the live state read it on 2026-10-19 13:40 (103 x 124 tiles), Cinder (34 x 61)
BASTION = {"surface": "platform-2", "hub": {"x": 0, "y": 0}, "bounds": {"left": -51, "top": -62, "right": 52, "bottom": 62},
           "hub_health": 100}
CINDER = {"surface": "platform-5", "hub": {"x": 0, "y": 0}, "bounds": {"left": -17, "top": -30, "right": 17, "bottom": 31},
          "hub_health": 100}


def shots():
    fly = platform_shot(BASTION, travelling=True, frac=0.658)
    assert fly["zoom"] == 0.3 and fly["pan"]["y0"] < fly["pan"]["y1"], fly
    vh = 33.75 / 0.3
    # the view's top edge at the bow is the flight framing's top (32 tiles ahead and half the margin), its bottom edge
    # at the stern the build's bottom with 8 and half the margin
    assert abs((fly["pan"]["y0"] - vh / 2) - (-62 - 32 - 5)) < 0.2 and abs((fly["pan"]["y1"] + vh / 2) - (62 + 8 + 5)) < 0.2, fly
    assert fly["position"]["y"] == -12.0, fly  # the flight framing's centre: a camera without the pan keeps it
    assert "pan" not in platform_shot(CINDER, travelling=True, frac=0.658)
    assert "pan" not in platform_shot(BASTION, frac=1.0) or platform_shot(BASTION, frac=1.0)["zoom"] == 0.3


def pan():
    from test_ship_survey import setup, run
    d, cam, _ = setup()
    d.watch_platforms(snap([], [plat("Bastion", view=BASTION)]), 1000)
    shot = d.visit_target("Bastion", 30, 1000)
    d.frame_on(d.slots[0], shot, "visit", {}, 1000)
    run(d, cam, 1000, shot["until"])
    q = d.surveys[d.state["main"]["survey_key"]]
    assert q.ends == {"bow", "stern"} and q.coverage == [(-62, 62)], q.public()
    # the pan's place over a long hold: bow, stern, back to the bow
    t0 = {"pan": {"y0": -40.0, "y1": 20.0}, "since": 0.0, "until": 600.0}
    assert d.pan_y(t0, 1.0) == -40.0 and d.pan_y(t0, d.PAN_END_S + d.PAN_LEG_S) == 20.0
    assert d.pan_y(t0, 2 * d.PAN_END_S + d.PAN_LEG_S + 2.0) < 20.0  # (CG2: eased, it leaves the stern gently) and d.pan_y(t0, 2 * (d.PAN_END_S + d.PAN_LEG_S) + 1) == -40.0
    short = {"pan": {"y0": -40.0, "y1": 20.0}, "since": 0.0, "until": 20.0}
    assert d.pan_y(short, 17.0) == 20.0 and d.pan_y(short, 2.0) == -40.0


def facts():
    d, sent = world(auto_feature=False, map_every=0)
    a, t = team(), 1000
    rows = [plat("Cinder", at="nauvis->gleba 57%", view=CINDER, toward="nauvis"), plat("Swiftlet", at="fulgora",
            view=dict(CINDER, surface="platform-6")), plat("Drift", at="nauvis->vulcanus 10%", view=dict(CINDER, surface="platform-7"),
            paused=True)]
    d.step(snap(a, rows), t)
    assert d.ship_facts("Cinder") == {"name": "Cinder", "from": "Gleba", "to": "Nauvis", "pct": 43, "speed_kms": 72}, d.ship_facts("Cinder")
    assert d.ship_facts("Swiftlet") == {"name": "Swiftlet", "at": "Fulgora"}, d.ship_facts("Swiftlet")
    assert d.ship_facts("Drift")["paused"] and d.ship_facts("Nope") is None and d.ship_facts(None) is None
    assert d.surface_platform("platform-6") == "Swiftlet" and d.surface_platform("nauvis") is None
    for k in range(0, 60):
        d.step(snap(a, rows), t + k)
        if d.platforms:
            break
    for j in range(k + 1, k + 4):
        d.step(snap(a, rows), t + j)
    row = main_row(d, t + j)
    assert row.get("ship") and row["ship"]["name"] == row["platform"]["name"], row
    # the overlay draws it (node --check; the card's code is in overlay.js)
    js = open(os.path.join(HERE, "static", "overlay.js")).read()
    assert "function renderShip(" in js and "renderShip(frame, slot," in js and ".ship-card" in open(os.path.join(HERE, "static", "overlay.css")).read()
    subprocess.run(["node", "--check", os.path.join(HERE, "static", "overlay.js")], check=True)


def main():
    shots()
    pan()
    facts()
    print("ship card: ok (ship facts on a camera showing a platform; a tall ship pans bow to stern during its shot)")


if __name__ == "__main__":
    main()
