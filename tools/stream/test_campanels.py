#!/usr/bin/env python3
"""Camera panels (d27 batch285 B, tools/cams.py POG_CAM_PANELS): python3 tools/stream/test_campanels.py

1. Off by default (three clients as before). POG_CAM_PANELS=2: one client (cam1), and the slots cam2 and cam3 are
   panels 1 and 2 drawn by player 1, at 16:9 rects across the strips the main hole's crop leaves off cam1's window.
2. The director's body for a panel slot names the panel and its rect; a map shot becomes a world view (zoom 0.3 or
   more) and a move is dropped (a GUI camera draws the world and has no move).
3. OneCam with panels: insets go to a panel (with one client and no panel there is none); a cut never goes to a panel:
   the client on air is moved (one client), so every program cut is on "main".
(OBS: tools/test_obs_panels.py, cp5: a panel is a scene of cam1's one capture, cropped to its rect.)
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import cams  # noqa: E402
from onecam import OneCam  # noqa: E402
from test_onecam import agent, snap  # noqa: E402
from test_cuts import LAYOUT  # noqa: E402

RIGHT, LEFT = [2388, 0, 492, 277], [0, 0, 492, 277]


def with_env(**kw):
    old = {k: os.environ.get(k) for k in kw}
    os.environ.update({k: str(v) for k, v in kw.items()})
    return old


def restore(old):
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


def switch():
    old = with_env(POG_CAM_PANELS="")
    try:
        assert cams.panels() == 0 and cams.cams("3") == ["cam1", "cam2", "cam3"]
        assert all("panel" not in s for s in cams.slots("3")) and cams.panel_sources("3") == {}
        os.environ["POG_CAM_PANELS"] = "2"
        assert cams.cams("3") == ["cam1"], "panels: cam1 alone, whatever POG_CAMS says"
        assert cams.slots("3") == [{"slot": "main", "player": 1},
                                   {"slot": "cam2", "player": 1, "panel": 1, "rect": RIGHT, "scale": 0.171},
                                   {"slot": "cam3", "player": 1, "panel": 2, "rect": LEFT, "scale": 0.171}], cams.slots("3")
        assert cams.panel_sources() == {"stream cam2": RIGHT, "stream cam3": LEFT}
        os.environ["POG_CAM_PANELS"] = "1"
        assert [s["slot"] for s in cams.slots()] == ["main", "cam2"]
        os.environ["POG_CAM_PANELS"] = "7"
        assert cams.panels() == 0, "only 1 or 2"
        # the strips follow the main hole: 1208x1032 in a 2880x1620 window leaves 492 px each side
        assert cams.panel_rects(2, (2880, 1620), LAYOUT) == [RIGHT, LEFT]
    finally:
        restore(old)
    root = os.path.dirname(os.path.dirname(HERE))
    start = open(os.path.join(root, "tools", "start-team.sh")).read()
    assert '"POG_CAM_PANELS=${POG_CAM_PANELS:-0}"' in start and \
        '"POG_CAMS=$([ "$(python3 tools/cams.py panels)" != 0 ] && echo 1 || echo "${POG_CAMS:-3}")"' in start, \
        "switches.env keeps the panels, and POG_CAMS=1 with them (the watchdog restarts no cam2/cam3)"
    import shift_change
    assert "POG_CAM_PANELS" in shift_change.KEYS and "POG_CAM_PANELS" in shift_change.ENV_FIRST
    print("1. the switch: off by default; 2 panels are cam2 and cam3 of player 1 in cam1's strips; carried in switches.env: ok")


SLOTS = [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 1, "panel": 1, "rect": RIGHT, "scale": 0.171},
         {"slot": "cam3", "player": 1, "panel": 2, "rect": LEFT, "scale": 0.171}]


def director(slots=SLOTS):
    sent = []
    d = OneCam(slots, lambda body: sent.append(body) or {"ok": True}, None, trio=False)
    d.started = 0
    return d, sent


def bodies():
    d, sent = director()
    d.apply(SLOTS[1], {"position": {"x": 5, "y": 6}, "surface": "nauvis", "zoom": 0.05, "map": True, "exact_zoom": True,
                       "move": {"segments": []}, "agents": []}, "map", {}, 1000)
    b = sent[-1]
    assert b["panel"] == 1 and b["rect"] == RIGHT and b["player"] == 1, b
    assert "map" not in b and "move" not in b and b["zoom"] == 0.05, b  # 0.05 x 0.171, within the panel range
    d.apply(SLOTS[2], {"follow": "luna", "zoom": 1.0, "agents": ["luna"]}, "inset", {}, 1001)
    assert sent[-1]["panel"] == 2 and sent[-1]["follow"] == "luna", sent[-1]
    side = round(min(d.cfg["max_zoom"], 1.0 * d.cfg["side_scale"]), 2)
    assert sent[-1]["zoom"] == round(side * 0.171, 2), (sent[-1], side)  # side_scale, then the panel's share
    d.apply(SLOTS[0], {"follow": "luna", "zoom": 1.0, "agents": ["luna"]}, "main", {}, 1002)
    assert "panel" not in sent[-1] and "rect" not in sent[-1], sent[-1]
    d.apply(SLOTS[1], None, "release", {}, 1003)
    assert sent[-1] == {"player": 1, "release": True, "panel": 1, "rect": RIGHT}, sent[-1]
    d.apply(SLOTS[1], {"follow": "luna", "zoom": 50, "exact_zoom": True, "agents": ["luna"]}, "close", {}, 1004)
    assert sent[-1]["zoom"] == round(d.cfg["max_zoom"] * 0.171, 2), sent[-1]  # the cap, then the share
    print("2. a panel's body names it and its rect, its zoom scaled to its share; no map, no move: ok")


TEAM = [agent("luna", 0, 0, 5), agent("sol", 400, 0, 1), agent("astra", -400, 0, 1)]


def attack(t, x=300, y=300):
    return {"id": f"a{t}", "kind": "attack", "t": t, "text": f"Base under attack near ({x}, {y}): gun turret",
            "position": {"x": x, "y": y, "extent": 16}, "key": f"area:{x},{y}:{t}"}


def onecam():
    d, sent = director()
    t = 1000
    for k in range(3):
        d.step(snap(TEAM), t + k)
    assert d.onair == "main" and (d.public().get("main") or {}).get("agents") == ["luna"], d.public()
    d.step(snap(TEAM, [attack(t + 10)]), t + 10)
    assert d.inset and d.inset["slot"] == "cam3", d.inset  # the last free panel
    framed = [b for b in sent if b.get("panel") == 2]
    assert framed and framed[-1]["rect"] == LEFT, sent[-3:]
    team = [dict(a) for a in TEAM]
    team[2]["interest"] = 40  # astra: a new story after the dwell
    for k in range(11, 400):
        d.step(snap(team), t + k)
    assert d.onair == "main" and all(c[1] == "main" for c in d.cuts), d.cuts
    assert len(d.cuts) >= 2 and (d.public().get("main") or {}).get("agents") == ["astra"], (d.cuts, d.public())
    assert all(b.get("panel") or b.get("player") == 1 for b in sent)
    # the same with one client and no panels: no inset
    d1, _ = director([SLOTS[0]])
    for k in range(3):
        d1.step(snap(TEAM), t + k)
    d1.step(snap(TEAM, [attack(t + 10)]), t + 10)
    assert not d1.inset, d1.inset
    print("3. onecam: insets in a panel, every cut on main (the one client moved): ok")


def main():
    switch()
    bodies()
    onecam()
    print("test_campanels: ok")


if __name__ == "__main__":
    main()
