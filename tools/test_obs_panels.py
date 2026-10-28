#!/usr/bin/env python3
"""Camera panels in OBS (d27 batch285 cp5): python3 tools/test_obs_panels.py

The live check (d27 22:08) showed a second game capture of factorio-cam1.exe never hooks (`init_pipe: failed to start
pipe`); crop is per scene item. So with POG_CAM_PANELS a panel is a scene named like the camera, holding one item of
"stream cam1" cropped to the panel's rect. Against a stub OBS:
1. stream-scene with panels: "stream cam2"/"stream cam3" are scenes with one item of "stream cam1" each, cropped to
   their rects and scaled to fill the canvas; the client captures of those names are removed; the only game capture
   of factorio-cam1.exe is "stream cam1"; "stream" holds each camera name once, placed and cropped as a 16:9 client.
2. Before cam1 hooks the crop comes from cam1's window (cams.py CLIENT); rehook-cams sets it again from the capture's
   size. Run again, nothing doubles.
3. Panels off: the panel scenes go, the client captures (factorio-cam2/3.exe) come back.
4. cams (read only): each panel scene's crop against its rect: ok, CROP OFF, NO PANEL SCENE.
5. cuts.py: a panel scene in the inset or behind the on-air camera is cropped like a client (crop_for); nothing
   else to know about panels.
6. vertical.py: a camera that is a main-canvas scene is added to the vertical scene by name; an unknown one stops.
"""
import os, sys, types
from types import SimpleNamespace as NS

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
sys.modules.setdefault("obsws_python", types.ModuleType("obsws_python"))  # obs.py's client library (not needed here)
import obs  # noqa: E402
import cuts  # noqa: E402
import vertical  # noqa: E402
from test_cuts import FakeOBS, LAYOUT  # noqa: E402

RIGHT, LEFT = [2388, 0, 492, 277], [0, 0, 492, 277]
CAM1_EXE = "Factorio 2.0.77:Factorio:factorio-cam1.exe"


class StubOBS:
    """obsws_python's ReqClient calls obs.py makes. Inputs and scenes share one name space, as in OBS."""

    def __init__(self, sizes=None):
        self.inputs, self.scenes, self.items, self.next = {}, {}, {}, 1
        self.sizes = sizes or {}  # input name -> (w, h) once hooked; a scene reads the canvas
        self.calls = []

    def _taken(self, name):
        return name in self.inputs or name in self.scenes

    def _add(self, scene, name, enabled=True):
        assert name in self.inputs or name in self.scenes, name
        iid = self.next
        self.next += 1
        self.items[iid] = {"scene": scene, "source": name, "enabled": enabled, "tf": {}}
        self.scenes[scene].append(iid)
        return iid

    def get_scene_list(self): return NS(scenes=[{"sceneName": n} for n in self.scenes])

    def create_scene(self, name):
        assert not self._taken(name), f"name in use: {name}"
        self.scenes[name] = []
        self.calls.append(("create_scene", name))

    def remove_scene(self, name):
        for iid, it in list(self.items.items()):  # its own items, and every item showing it
            if it["scene"] == name or it["source"] == name:
                self.scenes.get(it["scene"], []).remove(iid) if iid in self.scenes.get(it["scene"], []) else None
                del self.items[iid]
        del self.scenes[name]
        self.calls.append(("remove_scene", name))

    def get_input_list(self): return NS(inputs=[{"inputName": n} for n in self.inputs])

    def create_input(self, scene, name, kind, settings, enabled):
        assert not self._taken(name), f"name in use: {name}"
        self.inputs[name] = {"kind": kind, "settings": dict(settings)}
        self.calls.append(("create_input", name))
        return NS(scene_item_id=self._add(scene, name, enabled))

    def remove_input(self, name):
        for iid, it in list(self.items.items()):
            if it["source"] == name:
                self.scenes[it["scene"]].remove(iid)
                del self.items[iid]
        del self.inputs[name]
        self.calls.append(("remove_input", name))

    def set_input_settings(self, name, settings, overlay): self.inputs[name]["settings"].update(settings)

    def create_scene_item(self, scene, name, enabled):
        assert name != scene
        return NS(scene_item_id=self._add(scene, name, enabled))

    def remove_scene_item(self, scene, iid):
        self.scenes[scene].remove(iid)
        del self.items[iid]

    def get_scene_item_list(self, scene):
        return NS(scene_items=[{"sourceName": self.items[i]["source"], "sceneItemId": i, "sceneItemIndex": k,
                                "sceneItemEnabled": self.items[i]["enabled"]} for k, i in enumerate(self.scenes[scene])])

    def get_scene_item_id(self, scene, name):
        return NS(scene_item_id=next(i for i in self.scenes[scene] if self.items[i]["source"] == name))

    def get_scene_item_transform(self, scene, iid):
        src = self.items[iid]["source"]
        w, h = (1920, 1080) if src in self.scenes else self.sizes.get(src, (0, 0))
        return NS(scene_item_transform=dict(self.items[iid]["tf"], sourceWidth=float(w), sourceHeight=float(h)))

    def set_scene_item_transform(self, scene, iid, tf): self.items[iid]["tf"].update(tf)

    def set_scene_item_enabled(self, scene, iid, on): self.items[iid]["enabled"] = on

    def get_scene_item_enabled(self, scene, iid): return NS(scene_item_enabled=self.items[iid]["enabled"])

    def set_scene_item_index(self, scene, iid, idx):
        lst = self.scenes[scene]
        lst.remove(iid)
        lst.insert(idx, iid)

    def press_input_properties_button(self, *a): pass

    # reads for the asserts
    def names(self, scene): return [self.items[i]["source"] for i in self.scenes[scene]]

    def tf(self, scene, name): return self.items[self.get_scene_item_id(scene, name).scene_item_id]["tf"]


def crop(tf): return (tf.get("cropLeft"), tf.get("cropRight"), tf.get("cropTop"), tf.get("cropBottom"))


def env(value):
    if value is None:
        os.environ.pop("POG_CAM_PANELS", None)
    else:
        os.environ["POG_CAM_PANELS"] = value


def three_clients():
    """A box set up for three clients: the scene as stream-scene makes it with panels off."""
    o = StubOBS()
    env(None)
    obs.stream_scene(o, "http://127.0.0.1:8787/")
    assert [o.inputs[f"stream cam{i}"]["settings"]["window"] for i in (1, 2, 3)] == \
        [f"Factorio 2.0.77:Factorio:factorio-cam{i}.exe" for i in (1, 2, 3)]
    return o


def panels_on():
    o = three_clients()
    env("2")
    o.sizes["stream cam1"] = (0, 0)  # cam1 not hooked yet (stream-scene runs before the clients join)
    obs.stream_scene(o, "http://127.0.0.1:8787/")
    assert ("remove_input", "stream cam2") in o.calls and ("remove_input", "stream cam3") in o.calls, o.calls
    assert "stream cam2" in o.scenes and "stream cam3" in o.scenes and "stream cam2" not in o.inputs
    for name, rect, want in (("stream cam2", RIGHT, (2388, 0, 0, 1343)), ("stream cam3", LEFT, (0, 2388, 0, 1343))):
        assert o.names(name) == ["stream cam1"], o.names(name)
        tf = o.tf(name, "stream cam1")
        assert crop(tf) == want, (name, tf)
        assert (tf["boundsType"], tf["boundsWidth"], tf["boundsHeight"], tf["positionX"], tf["positionY"]) == \
            ("OBS_BOUNDS_SCALE_INNER", 1920, 1080, 0, 0), tf
    caps = [n for n, i in o.inputs.items() if i["kind"] == "game_capture" and i["settings"].get("window") == CAM1_EXE]
    assert caps == ["stream cam1"], f"one capture of cam1's window: {caps}"
    names = o.names("stream")
    for n in ("stream cam1", "stream cam2", "stream cam3"):
        assert names.count(n) == 1, names
    # the panel scene is a 16:9 source in "stream": cropped like a client in the main hole (1920x1080 into 1208x1032)
    assert crop(o.tf("stream", "stream cam2")) == (328, 328, 0, 0), o.tf("stream", "stream cam2")
    assert names[-1] == "stream overlay" and names[0] == "stream background", names
    print("1. stream-scene with panels: two panel scenes of the one cam1 capture, no second capture: ok")
    return o


def rehook(o):
    o.sizes["stream cam1"] = (2880, 1600)  # hooked, at a size other than the window cams.py expects
    out = obs.rehook_cams(o, sleep=lambda s: None)
    assert crop(o.tf("stream cam2", "stream cam1")) == (2388, 0, 0, 1323), o.tf("stream cam2", "stream cam1")
    assert "stream cam2 (panel scene): stream cam1, crop 2388/0 0/1323" in out and \
        "stream cam3 (panel scene): stream cam1, crop 0/2388 0/1323" in out, out
    o.sizes["stream cam1"] = (2880, 1620)
    before = (dict(o.inputs), {k: list(v) for k, v in o.scenes.items()})
    obs.stream_scene(o, "http://127.0.0.1:8787/")  # again: same scenes, items, inputs
    assert (set(o.inputs), {k: len(v) for k, v in o.scenes.items()}) == \
        (set(before[0]), {k: len(v) for k, v in before[1].items()}), (o.inputs, o.scenes)
    assert crop(o.tf("stream cam2", "stream cam1")) == (2388, 0, 0, 1343)
    print("2. rehook-cams crops each panel from the hooked size; stream-scene again changes nothing: ok")


def check(o):
    out = obs.cams_check(o)
    assert "stream cam2 (panel scene): stream cam1 at [2388, 0, 492, 277], crop 2388/0 0/1343 (not hooked): ok" in out, out
    o.sizes["stream cam1"] = (2880, 1620)
    before = repr((o.inputs, o.scenes, o.items))
    out = obs.cams_check(o)
    assert repr((o.inputs, o.scenes, o.items)) == before, "cams writes nothing"
    assert "stream cam2: on, main, crop 328/328 0/0, source 1920x1080: ok" in out, out
    assert "stream cam2 (panel scene): stream cam1 at [2388, 0, 492, 277], crop 2388/0 0/1343: ok" in out, out
    assert "stream cam3 (panel scene): stream cam1 at [0, 0, 492, 277], crop 0/2388 0/1343: ok" in out, out
    o.set_scene_item_transform("stream cam3", o.get_scene_item_id("stream cam3", "stream cam1").scene_item_id,
                               {"cropLeft": 0, "cropRight": 0})
    out = obs.cams_check(o)
    assert "stream cam3 (panel scene): stream cam1 at [0, 0, 492, 277], crop 0/0 0/1343: CROP OFF (the rect takes 0/2388 0/1343)" in out, out
    o2 = three_clients()
    env("2")
    assert "stream cam2 (panel scene): MISSING (run stream-scene)" in obs.cams_check(o2), obs.cams_check(o2)
    print("4. cams: each panel scene's crop against its rect, read only: ok")


def panels_off(o):
    env(None)
    obs.stream_scene(o, "http://127.0.0.1:8787/")
    assert "stream cam2" not in o.scenes and "stream cam3" not in o.scenes, list(o.scenes)
    assert [o.inputs[f"stream cam{i}"]["settings"]["window"] for i in (2, 3)] == \
        ["Factorio 2.0.77:Factorio:factorio-cam2.exe", "Factorio 2.0.77:Factorio:factorio-cam3.exe"]
    assert all(o.names("stream").count(f"stream cam{i}") == 1 for i in (1, 2, 3)), o.names("stream")
    print("3. panels off: the panel scenes go, the client captures come back: ok")


def cuts_plain():
    f = FakeOBS()
    f.sizes = {f.ids["stream cam1"]: (2880, 1620)}  # cam2/cam3 panel scenes read the 1920x1080 canvas
    c = cuts.Cuts(f, LAYOUT, log=lambda *a: None, start=False, vertical=None)
    c.set({"onair": "main", "inset": "cam2"})
    c.work()
    t = f.tf("stream cam2")
    assert (t["positionX"], t["boundsWidth"], t["boundsHeight"]) == (808, 408, 230) and crop(t) == (0, 0, 0, 0), t
    assert crop(f.tf("stream cam3")) == (328, 328, 0, 0), f.tf("stream cam3")  # behind the on-air one, main hole
    assert crop(f.tf("stream cam1")) == (492, 492, 0, 0), f.tf("stream cam1")
    assert not hasattr(cuts, "crop_of")
    print("5. cuts.py: a panel scene is placed and cropped like a client: ok")


def vertical_scene():
    calls = []

    class C:
        def send(self, req, data, raw=True):
            calls.append((req, data))
            if req == "GetInputList":
                return {"inputs": [{"inputName": "stream cam1"}]}
            if req == "GetSceneList":
                return {"scenes": [{"sceneName": "stream"}, {"sceneName": "stream cam2"}]}
            if req == "GetSceneItemList":
                return {"sceneItems": []}
            if req == "CreateSceneItem":
                return {"sceneItemId": 7}
            raise AssertionError(req)
    assert vertical.ensure(C(), "uuid-v", "stream cam2", None, None) == 7
    assert calls[-1] == ("CreateSceneItem", {"sceneUuid": "uuid-v", "sourceName": "stream cam2", "sceneItemEnabled": True}), calls
    try:
        vertical.ensure(C(), "uuid-v", "stream cam3", None, None)
        raise AssertionError("an unknown camera must stop")
    except SystemExit as e:
        assert "stream-scene first" in str(e)
    print("6. vertical.py: a panel scene joins the vertical scene by name: ok")


def main():
    old = os.environ.get("POG_CAM_PANELS")
    try:
        o = panels_on()
        rehook(o)
        panels_off(o)
        o = panels_on()
        check(o)
        cuts_plain()
        vertical_scene()
    finally:
        env(old)
    print("test_obs_panels: ok")


if __name__ == "__main__":
    main()
