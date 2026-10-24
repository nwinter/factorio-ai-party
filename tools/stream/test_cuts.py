#!/usr/bin/env python3
"""OBS cuts for the one-camera layout (cuts.py): python3 tools/stream/test_cuts.py

1. Every capture sits in the on-air hole, centre-cropped to its shape (a 1920x1080 client in 1208x1032: the sides go).
2. A cut restacks the captures only: the one on air in front, background below and overlay above untouched.
3. An inset moves to its corner (uncropped) on top, and back when it ends.
4. The vertical scene (Aitum Vertical's canvas) is restacked the same way, in its own holes.
6. (d24 batch136 PH2) A capture not hooked yet (0 x 0) goes to its hole with its crop left as it is, and is placed
   again at the next apply until its size is known; then it is cropped.
5. Host view (hostview.py): "stream host" comes on in the on-air hole in front of every camera while the program says
   host, and goes off and behind them after.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cuts  # noqa: E402

LAYOUT = {"canvas": [1920, 1080], "cams": {"main": [24, 24, 1208, 1032], "inset": [808, 40, 408, 230]}}
NAMES = ["stream background", "stream cam1", "stream cam2", "stream cam3", "stream overlay"]


class FakeOBS:
    def __init__(self, vertical=False):
        self.scenes = {"stream": list(NAMES)}  # bottom to top
        if vertical:
            self.scenes["V"] = ["vertical background", "stream cam1", "stream cam2", "stream cam3", "vertical overlay"]
        self.vertical = vertical
        self.ids = {n: i + 1 for i, n in enumerate(sorted({n for v in self.scenes.values() for n in v}))}
        self.transforms = {}
        self.calls = []
        self.sizes = {}  # item id -> (w, h) the capture reads; default a 1920x1080 client

    def scene(self, d):
        return "V" if d.get("sceneUuid") == "uuid-v" else d["sceneName"]

    def call(self, req, d=None):
        d = d or {}
        self.calls.append(req)
        if req == "GetSceneItemList":
            items = self.scenes[self.scene(d)]
            return {"sceneItems": [{"sourceName": n, "sceneItemId": self.ids[n], "sceneItemIndex": i} for i, n in enumerate(items)]}
        if req == "GetSceneItemTransform":
            w, h = self.sizes.get(d["sceneItemId"], (1920, 1080))
            return {"sceneItemTransform": {"sourceWidth": w, "sourceHeight": h}}
        if req == "SetSceneItemTransform":
            self.transforms[(self.scene(d), d["sceneItemId"])] = d["sceneItemTransform"]
            return {}
        if req == "SetSceneItemIndex":
            items = self.scenes[self.scene(d)]
            name = next(n for n in items if self.ids[n] == d["sceneItemId"])
            items.remove(name)
            items.insert(d["sceneItemIndex"], name)
            return {}
        if req == "GetCanvasList":
            return {"canvases": [{"canvasName": "Main"}] + ([{"canvasName": "Aitum Vertical", "canvasUuid": "cv"}]
                                                           if self.vertical else [])}
        if req == "GetSceneList":
            return {"scenes": [{"sceneName": "stream vertical", "sceneUuid": "uuid-v"}]}
        raise AssertionError(req)

    def tf(self, name, scene="stream"):
        return self.transforms[(scene, self.ids[name])]


def main():
    assert cuts.crop_for(1920, 1080, 1208, 1032) == {"cropLeft": 328, "cropRight": 328, "cropTop": 0, "cropBottom": 0}
    assert cuts.crop_for(1920, 1080, 408, 230)["cropLeft"] <= 3  # an inset keeps (nearly) the whole picture
    assert cuts.crop_for(1920, 1080, 1208, 680) == {"cropLeft": 0, "cropRight": 0, "cropTop": 0, "cropBottom": 0}
    assert cuts.crop_for(0, 0, 1208, 1032)["cropLeft"] == 0  # a window not found yet: no crop
    assert cuts.view_frac(LAYOUT) == 0.658

    o = FakeOBS()
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False, vertical=None)
    c.set({"onair": "cam2", "inset": None})
    c.work()
    st = o.scenes["stream"]
    assert st[0] == "stream background" and st[-1] == "stream overlay" and st[-2] == "stream cam2", st
    t = o.tf("stream cam1")
    assert (t["positionX"], t["positionY"], t["boundsWidth"], t["boundsHeight"], t["cropLeft"]) == (24, 24, 1208, 1032, 328), t
    n = len(o.calls)
    c.work()
    assert len(o.calls) == n  # nothing changed: no requests
    c.set({"onair": "cam3", "inset": None})
    c.work()
    assert o.scenes["stream"][-2] == "stream cam3" and "SetSceneItemTransform" not in o.calls[n:], o.calls[n:]  # a cut: order only
    c.set({"onair": "cam3", "inset": "main"})
    c.work()
    st = o.scenes["stream"]
    assert st[-2] == "stream cam1" and st[-3] == "stream cam3" and st[-1] == "stream overlay", st
    t = o.tf("stream cam1")
    assert (t["positionX"], t["boundsWidth"]) == (808, 408) and t["cropLeft"] <= 3, t
    c.set({"onair": "cam3", "inset": None})
    c.work()
    assert o.tf("stream cam1")["boundsWidth"] == 1208 and o.scenes["stream"][-2] == "stream cam3"

    o = FakeOBS(vertical=True)
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False)
    c.set({"onair": "cam2", "inset": None})
    c.work()
    assert c.status["vertical"] == "on" and o.scenes["V"][-2] == "stream cam2", (c.status, o.scenes["V"])
    t = o.tf("stream cam2", "V")
    assert (t["positionX"], t["positionY"], t["boundsWidth"], t["boundsHeight"]) == (24, 112, 1032, 883), t
    o = FakeOBS()
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False)
    c.set({"onair": "main", "inset": None})
    c.work()
    assert c.status["vertical"] == "no scene stream vertical" or c.status["vertical"] is None, c.status
    host_view()
    unhooked()
    print("cuts: ok (crop to the on-air hole, cuts restack only, inset on top and back, vertical scene too, host view)")


def unhooked():
    # cam3's client has not hooked yet when the director first places the captures (16:20, after the shift change)
    o = FakeOBS()
    o.sizes[o.ids["stream cam3"]] = (0, 0)
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False, vertical=None)
    c.set({"onair": "cam1", "inset": None})
    c.work()
    t = o.tf("stream cam3")
    assert (t["positionX"], t["boundsWidth"], t["boundsHeight"]) == (24, 1208, 1032) and "cropLeft" not in t, t
    assert o.tf("stream cam1")["cropLeft"] == 328
    assert "stream cam3" not in c.targets[0]["placed"] and c.targets[0]["placed"]["stream cam1"] == "main", c.targets[0]["placed"]
    c.set({"onair": "cam2", "inset": None})  # still not hooked: placed again, crop still left alone
    c.work()
    assert "cropLeft" not in o.tf("stream cam3")
    o.sizes[o.ids["stream cam3"]] = (2880, 1620)  # hooked: the next apply crops it, and it is kept as placed
    c.set({"onair": "cam1", "inset": None})
    c.work()
    assert o.tf("stream cam3")["cropLeft"] == 492 and c.targets[0]["placed"]["stream cam3"] == "main", o.tf("stream cam3")
    n = len(o.calls)
    c.set({"onair": "cam2", "inset": None})
    c.work()
    assert "SetSceneItemTransform" not in o.calls[n:], o.calls[n:]  # placed: a cut is order only again


class HostOBS(FakeOBS):
    """The stream scene with the host capture (obs.py stream_scene: off, just above the cameras)."""
    def __init__(self):
        super().__init__()
        self.scenes["stream"].insert(4, "stream host")
        self.ids["stream host"] = 99
        self.enabled = {"stream host": False}

    def call(self, req, d=None):
        d = d or {}
        if req == "GetSceneItemList":
            out = super().call(req, d)
            for it in out["sceneItems"]:
                it["sceneItemEnabled"] = self.enabled.get(it["sourceName"], True)
            return out
        if req == "SetSceneItemEnabled":
            self.calls.append(req)
            name = next(n for n, i in self.ids.items() if i == d["sceneItemId"])
            self.enabled[name] = d["sceneItemEnabled"]
            return {}
        return super().call(req, d)


def host_view():
    o = HostOBS()
    c = cuts.Cuts(o, LAYOUT, log=lambda *a: None, start=False, vertical=None)
    c.set({"onair": "cam2", "inset": None})
    c.work()
    st = o.scenes["stream"]
    assert o.enabled["stream host"] is False and st[-2] == "stream cam2" and st.index("stream host") < st.index("stream cam2"), st
    c.set({"onair": "cam2", "inset": None, "host": True})
    c.work()
    st = o.scenes["stream"]
    assert o.enabled["stream host"] is True and st[-2] == "stream host" and st[-1] == "stream overlay", st
    t = o.tf("stream host")
    assert (t["positionX"], t["boundsWidth"], t["cropLeft"]) == (24, 1208, 328), t  # the on-air hole, cropped as the cams
    c.set({"onair": "cam2", "inset": None})
    c.work()
    st = o.scenes["stream"]
    assert o.enabled["stream host"] is False and st[-2] == "stream cam2", st


if __name__ == "__main__":
    main()
