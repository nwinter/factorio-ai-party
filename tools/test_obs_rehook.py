#!/usr/bin/env python3
"""obs.py rehook-cams crops the cameras once they hook (Nick d23 16:28: after the 16:20 shift change "stream cam1" and
"stream cam3" had crop 0, the main view letterboxed; stream_scene had read their size as 0 x 0 before the clients
joined): python3 tools/test_obs_rehook.py

1. Each camera on is turned off and on, then read until its source has a size and cropped to its hole (2880 x 1620
   into 1208 x 1032: 492/492), with the crop it had in the reply.
2. A camera off stays off; it is cropped when it already has a size, and left as it is when it has none.
3. A source with no size within the wait: crop not set, said so; the wait is one budget for the whole call.
4. A camera not in the scene is named; the others go on.
"""
import os, sys, types
from types import SimpleNamespace as NS

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.modules.setdefault("obsws_python", types.ModuleType("obsws_python"))  # obs.py's client library (not needed here)
import obs  # noqa: E402

HOLE = {"boundsWidth": 1208.0, "boundsHeight": 1032.0}


class Fake:
    """cams: name -> {on, size (w, h) once hooked, after (reads of 0 x 0 first), crop (l, r, t, b)}"""

    def __init__(self, cams):
        self.cams, self.ids, self.calls, self.reads = cams, {n: k + 1 for k, n in enumerate(cams)}, [], {}

    def _name(self, item): return next(n for n, k in self.ids.items() if k == item)

    def get_scene_item_id(self, scene, name):
        if name not in self.cams:
            raise KeyError(name)
        return NS(scene_item_id=self.ids[name])

    def get_scene_item_enabled(self, scene, item): return NS(scene_item_enabled=self.cams[self._name(item)]["on"])

    def set_scene_item_enabled(self, scene, item, on):
        self.calls.append(("enabled", self._name(item), on)); self.cams[self._name(item)]["on"] = on

    def get_scene_item_transform(self, scene, item):
        n = self._name(item); cam = self.cams[n]
        self.reads[n] = self.reads.get(n, 0) + 1
        w, h = cam["size"] if cam.get("size") and self.reads[n] > cam.get("after", 0) else (0, 0)
        l, r, t, b = cam.get("crop", (0, 0, 0, 0))
        return NS(scene_item_transform=dict(HOLE, sourceWidth=float(w), sourceHeight=float(h),
                                            cropLeft=l, cropRight=r, cropTop=t, cropBottom=b))

    def set_scene_item_transform(self, scene, item, tr):
        n = self._name(item)
        self.calls.append(("transform", n, dict(tr)))
        self.cams[n]["crop"] = (tr["cropLeft"], tr["cropRight"], tr["cropTop"], tr["cropBottom"])


def run(cams, **kw):
    slept = []
    c = Fake(cams)
    out = obs.rehook_cams(c, sleep=slept.append, **kw)
    return c, out, slept


def main():
    # 1. the 16:20 case: cam1 and cam3 at crop 0 and not hooked yet, cam2 already cropped
    c, out, slept = run({"stream cam1": {"on": True, "size": (2880, 1620), "after": 3},
                         "stream cam2": {"on": True, "size": (2880, 1620), "crop": (492, 492, 0, 0)},
                         "stream cam3": {"on": True, "size": (2880, 1620), "after": 1}})
    for n in ("stream cam1", "stream cam2", "stream cam3"):
        assert c.cams[n]["crop"] == (492, 492, 0, 0), (n, c.cams[n])
        assert c.calls.index(("enabled", n, False)) < c.calls.index(("enabled", n, True)), c.calls
    # every camera comes on again before any is waited on
    last_on = max(i for i, x in enumerate(c.calls) if x[0] == "enabled")
    first_crop = min(i for i, x in enumerate(c.calls) if x[0] == "transform")
    assert last_on < first_crop, c.calls
    assert out == ("stream cam1: re-enabled; crop 492/492 0/0 (source 2880x1620 into 1208x1032, was 0/0 0/0) | "
                   "stream cam2: re-enabled; crop 492/492 0/0 (source 2880x1620 into 1208x1032, unchanged) | "
                   "stream cam3: re-enabled; crop 492/492 0/0 (source 2880x1620 into 1208x1032, was 0/0 0/0)"), out
    assert slept == [0.5] * 3 + [0.5] * 3 + [0.5], slept  # three off-and-ons, cam1's three empty reads, cam3's one
    # a 16:9 hole: no crop, and a crop left by the other layout cleared
    HOLE.update(boundsWidth=1920.0, boundsHeight=1080.0)
    try:
        c, out, _ = run({"stream cam1": {"on": True, "size": (1920, 1080), "crop": (492, 492, 0, 0)}}, n=1)
    finally:
        HOLE.update(boundsWidth=1208.0, boundsHeight=1032.0)
    assert c.cams["stream cam1"]["crop"] == (0, 0, 0, 0) and "was 492/492 0/0" in out, out

    # 2. off: left off, cropped when it has a size, never waited on
    c, out, slept = run({"stream cam1": {"on": True, "size": (2880, 1620)},
                         "stream cam2": {"on": False, "size": (2880, 1620)},
                         "stream cam3": {"on": False, "size": None, "crop": (7, 7, 0, 0)}})
    assert not any(x[1] != "stream cam1" for x in c.calls if x[0] == "enabled"), c.calls
    assert c.cams["stream cam2"]["crop"] == (492, 492, 0, 0) and c.cams["stream cam3"]["crop"] == (7, 7, 0, 0), c.cams
    assert "stream cam2: off, left off; crop 492/492 0/0" in out, out
    assert "stream cam3: off, left off; no source size, crop not set (left 7/7 0/0)" in out, out
    assert c.reads["stream cam3"] == 1 and slept == [0.5], (c.reads, slept)

    # 3. never hooked: the whole budget once, then the rest read once each
    c, out, slept = run({"stream cam1": {"on": True, "size": None},
                         "stream cam2": {"on": True, "size": (2880, 1620), "after": 2},
                         "stream cam3": {"on": True, "size": (2880, 1620)}}, wait_s=2.0)
    assert "stream cam1: re-enabled; no source size after 2 s, crop not set (left 0/0 0/0)" in out, out
    assert "stream cam2: re-enabled; no source size after 2 s, crop not set" in out, out  # its size came too late
    assert c.cams["stream cam3"]["crop"] == (492, 492, 0, 0), c.cams
    assert sum(slept) == 1.5 + 2.0 and c.reads["stream cam2"] == 1, (slept, c.reads)
    assert not any(x[0] == "transform" and x[1] != "stream cam3" for x in c.calls), c.calls

    # 4. a camera missing from the scene
    c, out, _ = run({"stream cam1": {"on": True, "size": (2880, 1620)}, "stream cam3": {"on": True, "size": (2880, 1620)}})
    assert "stream cam2: not in stream (KeyError)" in out and out.count("crop 492/492") == 2, out

    print("obs rehook-cams: ok (each camera cropped to its hole once its source has a size; off ones left off; "
          "a source with no size said so; one wait for the call)")


if __name__ == "__main__":
    main()
