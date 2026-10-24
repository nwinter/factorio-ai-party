#!/usr/bin/env python3
"""The host view's OBS source (tools/obs.py; tools/stream/hostview.py): python3 tools/test_obs_hostview.py

1. stream_scene: "stream host" captures factorio-nick.exe only (by executable, never factorio.exe), off, in the on-air
   hole cropped as the cameras, stacked above the cameras and below the overlay.
2. host-view-source on a live scene that lacks it: added off just below the overlay; nothing else moves or changes.
3. Run again: the same, no second item.
"""
import os, sys, types
from types import SimpleNamespace as NS

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.modules.setdefault("obsws_python", types.ModuleType("obsws_python"))  # obs.py's client library (not needed here)
import obs  # noqa: E402

LAYOUT = {"mode": "onecam", "canvas": [1920, 1080], "cams": {"main": [24, 24, 1208, 1032], "inset": [808, 40, 408, 230]}}


class Fake:
    def __init__(self, scene=None):
        self.inputs = {}  # name -> (kind, settings)
        self.scenes = {"stream": list(scene or [])}  # bottom to top: [name]
        self.enabled, self.transforms, self.calls = {}, {}, []
        for n in self.scenes["stream"]:
            self.inputs[n] = ("x", {})
            self.enabled[n] = True

    def _id(self, scene, name): return self.scenes[scene].index(name) + 1000 * (list(self.inputs).index(name) + 1)

    def _name(self, scene, item): return next(n for n in self.scenes[scene] if self._id(scene, n) == item)

    def get_scene_list(self): return NS(scenes=[{"sceneName": n} for n in self.scenes])

    def create_scene(self, n): self.scenes[n] = []

    def get_input_list(self): return NS(inputs=[{"inputName": n} for n in self.inputs])

    def set_input_settings(self, name, settings, overlay):
        self.calls.append(("settings", name)); self.inputs[name] = (self.inputs[name][0], settings)

    def create_input(self, scene, name, kind, settings, enabled):
        self.calls.append(("create", name)); self.inputs[name] = (kind, settings); self.scenes[scene].append(name); self.enabled[name] = enabled

    def create_scene_item(self, scene, name, enabled):
        self.calls.append(("item", name)); self.scenes[scene].append(name); self.enabled[name] = enabled

    def get_scene_item_list(self, scene):
        return NS(scene_items=[{"sourceName": n, "sceneItemIndex": i} for i, n in enumerate(self.scenes[scene])])

    def get_scene_item_id(self, scene, name): return NS(scene_item_id=name)  # ids are the names here

    def set_scene_item_enabled(self, scene, item, on): self.enabled[item] = on

    def set_scene_item_transform(self, scene, item, t): self.transforms.setdefault(item, {}).update(t)

    def get_scene_item_transform(self, scene, item):
        w, h = getattr(self, "sizes", {}).get(item, (1920, 1080))
        return NS(scene_item_transform={"sourceWidth": w, "sourceHeight": h})

    def set_scene_item_index(self, scene, item, idx):
        self.calls.append(("index", item)); lst = self.scenes[scene]; lst.remove(item); lst.insert(idx, item)

    def press_input_properties_button(self, *a): pass


def main():
    f = Fake()
    obs.stream_scene(f, "http://127.0.0.1:8787/", layout=os.path.join(HERE, "stream", "static", "layout.json"))
    st = f.scenes["stream"]
    assert st == ["stream background", "stream cam1", "stream cam2", "stream cam3", "stream host", "stream overlay"], st
    kind, s = f.inputs["stream host"]
    assert kind == "game_capture" and s["window"] == "Factorio 2.0.77:Factorio:factorio-nick.exe" and s["priority"] == 2, s
    assert "factorio.exe" not in s["window"].replace("factorio-nick.exe", "")
    assert f.enabled["stream host"] is False
    t = f.transforms["stream host"]
    assert (t["positionX"], t["boundsWidth"], t["cropLeft"]) == (24, 1208, 328), t  # the on-air hole, as the cams
    assert f.transforms["stream cam1"]["cropLeft"] == 328

    live = ["stream background", "stream cam1", "stream cam2", "stream cam3", "stream overlay"]
    f = Fake(live)
    before = dict(f.enabled)
    out = obs.host_view_source(f, layout=LAYOUT)
    assert "off until host view is on" in out, out
    st = f.scenes["stream"]
    assert st == ["stream background", "stream cam1", "stream cam2", "stream cam3", "stream host", "stream overlay"], st
    assert f.enabled["stream host"] is False and all(f.enabled[n] == before[n] for n in live)
    assert not any(c for c in f.calls if c[0] == "settings" and c[1] != "stream host"), f.calls  # nothing else set
    obs.host_view_source(f, layout=LAYOUT)
    assert f.scenes["stream"].count("stream host") == 1
    # (d24 batch136 PH2) a capture not hooked yet (0 x 0, its client still starting): its crop is left as it is
    f = Fake()
    obs.stream_scene(f, "http://127.0.0.1:8787/", layout=os.path.join(HERE, "stream", "static", "layout.json"))
    f.transforms["stream cam3"]["cropLeft"] = 492
    f.sizes = {"stream cam3": (0, 0), "stream host": (0, 0)}
    obs.stream_scene(f, "http://127.0.0.1:8787/", layout=os.path.join(HERE, "stream", "static", "layout.json"))
    assert f.transforms["stream cam3"]["cropLeft"] == 492 and f.transforms["stream cam3"]["boundsWidth"] == 1208, f.transforms["stream cam3"]
    assert f.transforms["stream cam1"]["cropLeft"] == 328
    print("obs host view: ok (factorio-nick.exe only, off, on-air hole and crop, above the cameras, one-off adds it alone)")


if __name__ == "__main__":
    main()
