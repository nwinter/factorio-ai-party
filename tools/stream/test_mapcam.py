#!/usr/bin/env python3
"""The base map on stream (onecam.py, mapcam.py, cameras.lua `map`; a viewer: "kind wish there was a map in one of
them at times to see the overall base layout"): python3 tools/stream/test_mapcam.py

1. Framing: the core and its outposts from the snapshot's basemap; a long pipeline alone does not stretch the frame,
   the outpost at its end does; the zoom fits the hole (the on-air crop) and stays a chart zoom.
2. About every map_every (after map_first) a standby is framed on the map (a `map` camera call: chart, fixed
   position) and the program cuts to it within ready_s; it holds map_hold, labelled "Base map", then the story it
   interrupted comes back; the map client is released once off air (no stuck map view).
3. Never during an urgent shot, a replay (hold_layout) or an inset; replays.py gets no frame from it.
4. A check-in trio shows the map in one small tile.
5. snapshot onair.map for the hosts; the caster's facts say so.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from mapcam import map_shot  # noqa: E402
from onecam import onair_info  # noqa: E402

# 8-tile cells from (-80, -80): a core of furnaces/assemblers, a drill outpost, and a pipeline east to pumpjacks
ROWS = ["...................................................................",
        ".SSAA..............................................................",
        ".SAAAM.............................................................",
        ".KAAEE....PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPOO",
        "..BBB.............................................................O",
        "...B...............................................................",
        "...B...............................................................",
        "..MM...............................................................",
        "..MM..............................................................."]
BASEMAP = {"cell": 8, "x0": -80, "y0": -80, "rows": ROWS}


def snap(agents, alerts=(), basemap=BASEMAP):
    return {"agents": agents, "alerts": list(alerts), "basemap": basemap}


def framing():
    s = map_shot(BASEMAP)
    assert s["groups"] == 3, s  # core, drill outpost, oil outpost (the pipeline is no group of its own)
    w, h = s["size"]
    assert w >= 8 * 67 - 8 and h >= 7 * 8, s  # the oil outpost at the far end is in frame
    no_oil = map_shot(dict(BASEMAP, rows=[r.replace("O", ".") for r in ROWS]))
    assert no_oil["size"][0] < 100, no_oil  # the pipeline alone does not stretch it
    # the zoom fits the main hole's cropped width (1208x1032 of a 1920x1080 client: 0.658 of it)
    assert abs(s["zoom"] - 1920 * 0.658 / (32 * w)) < 0.003 or s["zoom"] == 0.02, s
    assert 0.02 <= s["zoom"] <= 0.5 and map_shot({"rows": []}) is None


def team():
    return [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3), agent("astra", -300, 0, 3)]


def on_air_map():
    d, sent = world(map_every=600, map_first=300)
    d.started = 0
    a = team()
    t = 1000  # past map_first
    for k in range(0, 4):
        d.step(snap(a), t + k)
    maps = [b for b in sent if b.get("map")]
    assert maps and maps[-1]["smooth"] is False and "position" in maps[-1] and maps[-1]["zoom"] < 0.5, sent[-3:]
    pub = d.public(t + 3)
    assert pub["main"].get("map") == "Base map" and pub["main"]["agents"] == [] and "frame" not in pub["main"], pub
    assert onair_info({"agents": a}, pub)["map"] == "on air"
    on = d.onair
    for k in range(4, 30):
        d.step(snap(a), t + k)
    pub = d.public(t + 30)
    assert not pub["main"].get("map") and pub["main"]["agents"], pub  # the story is back
    # the map client is off the map: released, or already framing its next subject (cameras.lua: a spectator again)
    after = d.state.get(on)
    assert after is None or (after.get("follow") and not after.get("map")), after
    i = max(i for i, b in enumerate(sent) if b.get("map"))
    assert any(b.get("release") or b.get("follow") for b in sent[i + 1:] if b["player"] == maps[-1]["player"]), sent[i:]
    # not again before map_every
    for k in range(30, 500):
        d.step(snap(a), t + k)
    assert len(d.maps) == 1, d.maps


def never_when_busy():
    d, sent = world(map_every=600, map_first=300)
    d.started = 0
    a = team()
    for k in range(0, 20):
        d.hold_layout = True  # a replay on air
        d.step(snap(a), 1000 + k)
    assert not d.maps
    d.hold_layout = False
    death = {"id": "d1", "kind": "death", "t": 1020, "text": "Sol died", "agent": "sol"}
    a[1]["alive"] = False
    d.step(snap(a, [death]), 1020)
    d.step(snap(a), 1022)
    assert not d.maps and d.public(1022)["main"].get("alert") == "death", (d.maps, d.public(1022))
    d2, _ = world(map_every=600, map_first=300)
    d2.started = 0
    for k in range(0, 10):
        d2.step(snap(team(), basemap=None), 1000 + k)
    assert not d2.maps  # no basemap yet: no map


def trio_tile():
    d, sent = world(trio=True, map_every=0, trio_ratio=50.0)  # only a check-in trio, no on-air map
    d.started = 0
    a = team()
    for t in range(1000, 1100):
        d.step(snap(a), t)
        if d.mode == "trio":
            break
    assert d.mode == "trio" and d.maps and d.maps[-1][1] == "trio tile", (d.mode, d.layouts, d.maps)
    pub = d.public(t)
    assert pub["cam3"].get("map") == "Base map" and pub["cam2"]["agents"], pub
    assert onair_info({"agents": a}, pub)["map"] == "tile"
    tile_maps = [b for b in sent if b.get("map")]
    assert tile_maps and tile_maps[-1]["zoom"] <= 0.5


def hosts():
    import caster
    s = {"agents": [], "onair": {"agent": None, "map": "on air"}}
    f = caster.facts_for({"kind": "lull", "angle": "explain"}, s)
    assert f["on_screen_map"]["where"] == "the whole picture", f


def main():
    framing()
    on_air_map()
    never_when_busy()
    trio_tile()
    hosts()
    print("mapcam: ok (core and outposts framed, pipeline alone not; on air every 10 min for 15 s and back; released "
          "after; never during replays or urgent shots; a trio tile at a check-in; hosts told)")


if __name__ == "__main__":
    main()
