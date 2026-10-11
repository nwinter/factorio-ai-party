#!/usr/bin/env python3
"""Offline check for tools/vertical.py against a fake obs-websocket with an Aitum Vertical canvas: the scene is made in
that canvas (not the main one), shares the landscape captures, puts them in layout-portrait.json's holes, mutes the
portrait page, stacks background < cams < overlay, switches the plugin to it, and a second run changes nothing.
python3 tools/test_vertical.py"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vertical as v  # noqa: E402


class Fake:
    def __init__(self):
        self.calls = []
        self.inputs = {"stream cam1": "game_capture", "stream cam2": "game_capture", "stream cam3": "game_capture",
                       "stream overlay": "browser_source"}
        self.scenes = {"main-uuid": {"stream": "s-stream"}, "vert-uuid": {}}  # canvas -> scene name -> uuid
        self.items = {}  # scene uuid -> [source names]
        self.muted = set()

    def send(self, req, data, raw=False):
        self.calls.append((req, data))
        if req == "GetCanvasList":
            return {"canvases": [{"canvasName": "Main", "canvasUuid": "main-uuid"},
                                 {"canvasName": "Aitum Vertical", "canvasUuid": "vert-uuid"}]}
        if req == "GetSceneList":
            return {"scenes": [{"sceneName": n, "sceneUuid": u} for n, u in self.scenes[data["canvasUuid"]].items()]}
        if req == "CreateScene":
            uuid = f"s-{data['sceneName']}"
            self.scenes[data["canvasUuid"]][data["sceneName"]] = uuid
            self.items[uuid] = []
            return {"sceneUuid": uuid}
        if req == "GetInputList":
            return {"inputs": [{"inputName": n} for n in self.inputs]}
        if req == "CreateInput":
            self.inputs[data["inputName"]] = data["inputKind"]
            self.items[data["sceneUuid"]].append(data["inputName"])
            return {"sceneItemId": len(self.items[data["sceneUuid"]])}
        if req == "CreateSceneItem":
            assert data["sourceName"] in self.inputs
            self.items[data["sceneUuid"]].append(data["sourceName"])
            return {"sceneItemId": len(self.items[data["sceneUuid"]])}
        if req == "GetSceneItemList":
            return {"sceneItems": [{"sourceName": n, "sceneItemId": k + 1} for k, n in enumerate(self.items[data["sceneUuid"]])]}
        if req == "SetInputMute":
            self.muted.add(data["inputName"])
        if req == "CallVendorRequest":
            assert data["vendorName"] == "aitum-vertical-canvas" and data["requestData"]["width"] == 1080
            return {"responseData": {"success": True}}
        return {}


def main():
    f = Fake()
    uuid = v.build_scene(f, "http://127.0.0.1:8787/portrait")
    assert uuid == "s-stream vertical" and "stream vertical" in f.scenes["vert-uuid"] and len(f.scenes["main-uuid"]) == 1
    assert ("CreateScene", {"canvasUuid": "vert-uuid", "sceneName": "stream vertical"}) in f.calls
    assert f.items[uuid] == ["vertical background", "stream cam1", "stream cam2", "stream cam3", "vertical overlay"], f.items
    created = [d["inputName"] for r, d in f.calls if r == "CreateInput"]
    assert created == ["vertical background", "vertical overlay"], created  # the captures are shared, not new
    cams = json.load(open(v.LAYOUT))["cams"]
    tf = {d["sceneItemId"]: d["sceneItemTransform"] for r, d in f.calls if r == "SetSceneItemTransform"}
    assert (tf[2]["positionX"], tf[2]["positionY"], tf[2]["boundsWidth"], tf[2]["boundsHeight"]) == tuple(cams["main"])
    assert (tf[4]["positionX"], tf[4]["boundsWidth"]) == (cams["cam3"][0], cams["cam3"][2])
    ov = [d for r, d in f.calls if r == "CreateInput" and d["inputName"] == "vertical overlay"][0]["inputSettings"]
    assert ov["url"].endswith("/portrait") and (ov["width"], ov["height"]) == (1080, 1920)
    assert f.muted == {"vertical overlay"}
    idx = [(d["sceneItemId"], d["sceneItemIndex"]) for r, d in f.calls if r == "SetSceneItemIndex"]
    assert idx == [(1, 0), (2, 1), (3, 2), (4, 3), (5, 4)], idx
    sw = [d["requestData"] for r, d in f.calls if r == "CallVendorRequest" and d["requestType"] == "switch_scene"]
    assert sw and sw[0]["scene"] == "stream vertical"
    assert not any(r in ("SetCurrentProgramScene", "StartStream", "SetProfileParameter", "SetStreamServiceSettings")
                   for r, _ in f.calls)
    n = len(f.calls)
    v.build_scene(f, "http://127.0.0.1:8787/portrait")  # again: same items, nothing new
    assert f.items[uuid] == ["vertical background", "stream cam1", "stream cam2", "stream cam3", "vertical overlay"]
    assert not [r for r, _ in f.calls[n:] if r in ("CreateScene", "CreateInput", "CreateSceneItem")]

    with tempfile.NamedTemporaryFile("w", suffix=".key", delete=False) as k:
        k.write("abcd-efgh\n")
    v.set_key(f, "rtmp://a.rtmp.youtube.com/live2", k.name)
    os.unlink(k.name)
    reqs = {d["requestType"]: d["requestData"] for r, d in f.calls if r == "CallVendorRequest"}
    assert reqs["update_stream_key"]["stream_key"] == "abcd-efgh" and reqs["update_stream_key"]["index"] == 0
    assert reqs["update_stream_server"]["stream_server"] == "rtmp://a.rtmp.youtube.com/live2"
    print("vertical: ok")


if __name__ == "__main__":
    main()
