#!/usr/bin/env python3
"""The camera on a spidertron firing rockets (d22 batch93 BC2, viewer Foobator 13:33: "could the camera on spidertrons
zoom out a bit more when rockets are fired? half the action is not on cam"): python3 tools/stream/test_spidercam.py

Shift58 13:28-13:30: Opus drove spidertron 2 to the nest at (-369,-943) and its rockets killed 2 spawners and 4 worms
from about 32 tiles out; the director followed Opus at the follow zoom for driving (0.75 x 1.5 = 1.12 sent: about 35
tiles across the on-air hole at view_frac 0.658), so the targets were off frame. Status brief's vehicle_fire (read on
a copy of world n's 12:04 autosave, Opus seated at (-370,-926.4)): range 36, rockets 162, 17 enemies, the farthest
33.9 out, the nearest 7.2.
1. Driving a spidertron that fires (enemies in range, rockets loaded): the shot of it on air widens to fit the
   farthest (fight_zoom of twice that distance, the fight shots' limits: 0.4 at the least); a cut to it starts wide.
2. The fire over (no enemy in range, or no rockets): back to the activity's zoom. Never closer than the follow zoom.
3. The model passes vehicle_fire from the agent's status to the snapshot.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from model import Model  # noqa: E402

FIRE = {"vehicle": "spidertron", "unit_number": 22844293, "range": 36, "ammo": 162, "targets": 17, "farthest": 33.9,
        "nearest": 7.2, "box": {"left_top": {"x": -383, "y": -960}, "right_bottom": {"x": -366, "y": -930}}}


STEP = [0]


def opus(fire=None, active="vehicle"):
    STEP[0] += 1  # it drives: a little further each step (a character standing still is cut away from)
    a = agent("opus", -370 + 0.3 * (STEP[0] % 40), -926.4, 6, active=active)
    if fire is not None:
        a["vehicle_fire"] = fire
    return a


def snap(a):
    return {"agents": [a, agent("muse", 300, 0, 1)], "alerts": []}


def sent_zoom(sent, who="opus"):
    """The zoom last sent to a client following who (any client: in onecam the one on air changes)."""
    rows = [b for b in sent if b.get("follow") == who and "zoom" in b]
    return rows[-1]["zoom"] if rows else None


def main():
    # before: driving, no fire read: the follow zoom for driving (0.75 x main_scale 1.5)
    d, sent = world(map_every=0, platform_every=0, view_frac=0.658)
    for k in range(0, 20):
        d.step(snap(opus()), 1000 + k)
    before = sent_zoom(sent)
    assert before == 1.12, (before, sent[-3:])
    # its spidertron fires: widened on air within zoom_settle, to fit the farthest (33.9 out)
    for k in range(20, 30):
        d.step(snap(opus(FIRE)), 1000 + k)
    after = sent_zoom(sent)
    want = round(max(0.4, round(60.0 / (2 * 33.9 + 24.0), 2) * 0.658), 2)
    assert after == want == 0.43, (after, want)
    # on-air width: about 60 tiles across at zoom 1 on the client, view_frac of it on air
    print(f"opus in spidertron 2 at (-370,-926.4): before zoom {before} (~{60 / before * 0.658:.0f} tiles across on air), "
          f"after {after} (~{60 / after * 0.658:.0f} tiles: the farthest target 33.9 out)")
    # the fire over: back to the driving zoom
    for k in range(30, 45):
        d.step(snap(opus(dict(FIRE, targets=0, farthest=None, nearest=None, box=None))), 1000 + k)
    assert sent_zoom(sent) == 1.12, sent[-2:]
    # no rockets: no wider shot
    for k in range(45, 60):
        d.step(snap(opus(dict(FIRE, ammo=0))), 1000 + k)
    assert sent_zoom(sent) == 1.12, sent[-2:]
    # a target close by (5 tiles): its fit is closer than the follow zoom: unchanged
    for k in range(60, 75):
        d.step(snap(opus(dict(FIRE, farthest=5.0))), 1000 + k)
    assert sent_zoom(sent) == 1.12, sent[-2:]
    # the farthest at the edge of a wider range (a modded launcher, 120 tiles): the fight shots' least zoom, 0.4
    for k in range(75, 90):
        d.step(snap(opus(dict(FIRE, farthest=120.0, range=120))), 1000 + k)
    assert sent_zoom(sent) == 0.4, sent[-2:]

    # a cut to it while it fires starts wide (apply's fit), not at the follow zoom
    d, sent = world(map_every=0, platform_every=0, view_frac=0.658)
    for k in range(0, 5):
        d.step({"agents": [agent("muse", 300, 0, 6)], "alerts": []}, 2000 + k)
    for k in range(5, 200):
        d.step({"agents": [agent("muse", 300, 0, 0.1, activity="thinking", active=False), opus(FIRE)], "alerts": []}, 2000 + k)
        if (d.public(2000 + k).get("main") or {}).get("agents") == ["opus"]:
            break
    opus_frames = [b for b in sent if b.get("follow") == "opus"]
    assert opus_frames and opus_frames[0]["zoom"] == 0.43, opus_frames[:2]

    # the model passes it through
    m = Model({"agents": {"opus": {}}})
    m.ingest({"tick": 100, "agents": [dict(opus(FIRE), surface="nauvis", kind="bot")]}, 10)
    row = next(a for a in m.snapshot(10)["agents"] if a["name"] == "opus")
    assert row["vehicle_fire"]["farthest"] == 33.9, row.get("vehicle_fire")
    m.ingest({"tick": 160, "agents": [dict(opus(), surface="nauvis", kind="bot")]}, 11)
    assert next(a for a in m.snapshot(11)["agents"] if a["name"] == "opus")["vehicle_fire"] is None
    print("spidercam: ok (a firing spidertron's driver framed to its farthest target, back after; never closer; "
          "a cut starts wide; the model passes vehicle_fire)")


if __name__ == "__main__":
    main()
