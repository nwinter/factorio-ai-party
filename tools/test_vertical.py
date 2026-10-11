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
    settings_tests()
    print("vertical: ok")


# A config as Aitum Vertical 1.6.6 writes it on exit (SaveSettings keys; fresh install: no outputs, main settings)
FRESH = {"canvas": [{"width": 1080, "height": 1920, "current_scene": "stream vertical", "streaming_video_bitrate": 0,
                     "streaming_match_main": False, "stream_advanced_settings": False, "stream_audio_track": 0,
                     "stream_encoder": "", "stream_encoder_settings": {}, "stream_outputs": [],
                     "backtrack": False, "record_path": "", "transitions": [{"name": "Fade"}]}]}


def settings_tests():
    import copy, subprocess
    cfg = copy.deepcopy(FRESH)
    lines = v.apply_settings(cfg, server="rtmps://a.rtmps.youtube.com:443/live2")
    c = cfg["canvas"][0]
    assert c["stream_advanced_settings"] is True and c["stream_encoder"] == "obs_qsv11_v2"
    assert c["stream_encoder_settings"] == {"rate_control": "CBR", "bitrate": 6000, "max_bitrate": 6000, "keyint_sec": 2}
    assert c["stream_audio_track"] == 1 and c["streaming_video_bitrate"] == 6000
    assert c["stream_outputs"] == [{"name": "YouTube vertical", "stream_server": "rtmps://a.rtmps.youtube.com:443/live2",
                                    "stream_key": "", "enabled": False}]
    assert c["streaming_match_main"] is False and "OFF until" in lines[2], lines  # no key: never the dialog
    assert c["transitions"] == [{"name": "Fade"}] and c["current_scene"] == "stream vertical"  # the rest kept
    v.apply_settings(cfg, bitrate=4500, key="abcd-efgh")
    assert c["stream_outputs"][0]["enabled"] is True and c["stream_outputs"][0]["stream_key"] == "abcd-efgh"
    assert c["streaming_match_main"] is True and c["stream_encoder_settings"]["bitrate"] == 4500
    v.apply_settings(cfg, match_main=False)
    assert c["streaming_match_main"] is False and c["stream_outputs"][0]["stream_key"] == "abcd-efgh"  # key kept
    legacy = {"canvas": [{"width": 1080, "height": 1920, "stream_server": "rtmp://x/live2", "stream_key": "old"}]}
    v.apply_settings(legacy)
    assert legacy["canvas"][0]["stream_outputs"][0]["stream_key"] == "old" and "stream_key" not in legacy["canvas"][0]
    try:
        v.apply_settings({"canvas": [{"width": 1080, "height": 1920}, {"width": 720, "height": 1280}]}, width=1920)
        raise AssertionError("two canvases, none matching: must refuse")
    except SystemExit:
        pass

    # settings_on_box over stand-in ssh/scp: refuses while OBS runs, keeps a dated copy, writes the new config
    with tempfile.TemporaryDirectory() as d:
        boxdir, bindir = os.path.join(d, "box"), os.path.join(d, "bin")
        os.makedirs(boxdir), os.makedirs(bindir)
        open(os.path.join(boxdir, "config.json"), "w").write("﻿" + json.dumps(FRESH))  # BOM: read anyway
        state = os.path.join(d, "obs-running")
        open(state, "w").write("1")
        open(os.path.join(bindir, "ssh"), "w").write(f"""#!/bin/sh
cmd="$2"
echo "$cmd" >> {d}/ssh.log
case "$cmd" in
  tasklist*) if [ "$(cat {state})" = 1 ]; then echo "obs64.exe 1234 Console 1 500,000 K"; else echo "INFO: No tasks are running"; fi;;
  copy*) cp {boxdir}/config.json {boxdir}/config.json.bak-copy;;
esac
""")
        open(os.path.join(bindir, "scp"), "w").write(f"""#!/bin/sh
src="$2"; dst="$3"
case "$src" in pogwin:*) cp {boxdir}/config.json "$dst";; *) cp "$src" {boxdir}/config.json;; esac
""")
        os.chmod(os.path.join(bindir, "ssh"), 0o755), os.chmod(os.path.join(bindir, "scp"), 0o755)
        keyf = os.path.join(d, "vertical.key")
        open(keyf, "w").write("wxyz-1234\n")
        old_path = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + old_path
        args = type("A", (), dict(key_file=keyf, bitrate=6000, encoder="obs_qsv11_v2", keyint=2, track=1,
                                  server="rtmps://a.rtmps.youtube.com:443/live2", no_match_main=False, dry_run=False))
        try:
            try:
                v.settings_on_box(args)
                raise AssertionError("OBS running: must refuse")
            except SystemExit as e:
                assert "OBS is running" in str(e), e
            assert json.load(open(os.path.join(boxdir, "config.json"), encoding="utf-8-sig")) == FRESH
            open(state, "w").write("0")
            v.settings_on_box(args)
        finally:
            os.environ["PATH"] = old_path
        out = json.load(open(os.path.join(boxdir, "config.json")))["canvas"][0]
        assert out["stream_outputs"][0]["stream_key"] == "wxyz-1234" and out["stream_outputs"][0]["enabled"]
        assert out["streaming_match_main"] is True and out["stream_encoder_settings"]["keyint_sec"] == 2
        assert os.path.exists(os.path.join(boxdir, "config.json.bak-copy"))  # the dated copy was made first
        assert not open(os.path.join(boxdir, "config.json"), "rb").read().startswith(b"\xef\xbb\xbf")  # no BOM


if __name__ == "__main__":
    main()
