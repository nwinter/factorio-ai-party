#!/usr/bin/env python3
"""tools/obs_setup_326.py (d28 batch326: the OBS settings for game-only replay audio and quiet alarms) against a stand-in
obs-websocket holding pogwin's state as read on d28 19:2x: python3 tools/test_obs_setup_326.py

- --check on today's state lists each difference (the profile's track 2, the two new sources, the filters, the tracks)
  and changes nothing;
- --apply makes them: the sources in their scenes (the ambience's item hidden), the alarm gains created disabled, the
  tracks, the profile parameters; a second --check finds none and a second --apply changes nothing (idempotent);
- what the service sets while it runs is not compared nor reset: the alarm gains' enabled state, the ambience item's
  visibility, "replay clip"'s mute;
- its settings agree with tools/obs.py's (DUCK, GAME_LIMIT); a test run never reaches the live OBS (obs.client refuses).
"""
import copy, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["POG_TEST"] = "1"
import obs_setup_326 as su  # noqa: E402

WIN = "Factorio 2.0.77:Factorio:factorio-cam1.exe"
ALL = {str(k): True for k in range(1, 7)}


class FakeOBS:
    def __init__(self):
        self.profile = {("AdvOut", "RecTracks"): "1", ("AdvOut", "Track2Name"): None, ("AdvOut", "Track2Bitrate"): "160"}
        self.inputs = {
            "stream game audio": {"kind": "wasapi_process_output_capture", "settings": {"window": WIN, "priority": 2},
                                  "volume": -2.0, "tracks": dict(ALL), "muted": False,
                                  "filters": [{"filterName": "duck under voices", "filterKind": "compressor_filter", "filterEnabled": True,
                                               "filterSettings": dict(su.DUCK, sidechain_source="stream overlay")},
                                              {"filterName": "limit peaks", "filterKind": "limiter_filter", "filterEnabled": True,
                                               "filterSettings": {"threshold": -12.0, "release_time": 60}}]},
            "stream overlay": {"kind": "browser_source", "settings": {}, "volume": 0.0, "tracks": dict(ALL), "filters": []},
            "replay clip": {"kind": "ffmpeg_source", "settings": {}, "volume": 0.0, "tracks": dict(ALL), "muted": True, "filters": []},
            "replay banner": {"kind": "browser_source", "settings": {}, "volume": 0.0, "tracks": dict(ALL), "filters": []},
            "stream cam1": {"kind": "game_capture", "settings": {}, "volume": 0.0, "tracks": dict(ALL), "filters": []},
            "stream background": {"kind": "color_source_v3", "settings": {}, "noaudio": True, "filters": []},
        }
        self.items = {}  # (scene, source) -> enabled
        self.calls = []

    def send(self, req, data=None):
        data = data or {}
        self.calls.append((req, copy.deepcopy(data)))
        i = self.inputs.get(data.get("inputName") or data.get("sourceName"))
        if req == "GetInputList":
            return {"inputs": [{"inputName": n, "inputKind": v["kind"]} for n, v in self.inputs.items()]}
        if req == "GetInputSettings":
            return {"inputSettings": dict(i["settings"])}
        if req == "SetInputSettings":
            i["settings"].update(data["inputSettings"])
        elif req == "GetInputVolume":
            return {"inputVolumeDb": i["volume"]}
        elif req == "SetInputVolume":
            i["volume"] = data["inputVolumeDb"]
        elif req == "GetInputAudioTracks":
            if i.get("noaudio"):
                raise RuntimeError("604: the specified input does not support audio")
            return {"inputAudioTracks": dict(i["tracks"])}
        elif req == "SetInputAudioTracks":
            i["tracks"].update(data["inputAudioTracks"])
        elif req == "GetSourceFilterList":
            return {"filters": copy.deepcopy(i["filters"])}
        elif req == "CreateSourceFilter":
            i["filters"].append({"filterName": data["filterName"], "filterKind": data["filterKind"], "filterEnabled": True,
                                 "filterSettings": dict(data["filterSettings"])})
        elif req == "SetSourceFilterEnabled":
            next(f for f in i["filters"] if f["filterName"] == data["filterName"])["filterEnabled"] = data["filterEnabled"]
        elif req == "SetSourceFilterSettings":
            next(f for f in i["filters"] if f["filterName"] == data["filterName"])["filterSettings"].update(data["filterSettings"])
        elif req == "CreateInput":
            self.inputs[data["inputName"]] = {"kind": data["inputKind"], "settings": dict(data["inputSettings"]), "volume": 0.0,
                                              "tracks": dict(ALL), "filters": []}
            self.items[(data["sceneName"], data["inputName"])] = data["sceneItemEnabled"]
        elif req == "GetProfileParameter":
            return {"parameterValue": self.profile.get((data["parameterCategory"], data["parameterName"]))}
        elif req == "SetProfileParameter":
            self.profile[(data["parameterCategory"], data["parameterName"])] = data["parameterValue"]
        return {}

    def filt(self, src, name):
        return next((f for f in self.inputs[src]["filters"] if f["filterName"] == name), None)


def main():
    o = FakeOBS()
    s = su.Setup(o.send)
    diffs = s.run(apply=False)
    assert not [c for c in o.calls if not c[0].startswith("Get")], "--check only reads"
    text = "\n".join(diffs)
    for part in ("profile AdvOut.RecTracks: '1', wanted '3'", "profile AdvOut.Track2Name: None, wanted 'game only'",
                 "stream game clean: missing (wasapi_process_output_capture in scene 'stream')",
                 "replay game ambience: missing (wasapi_process_output_capture in scene 'replay')",
                 "replay clip: filter 'duck under voices' (compressor_filter) missing",
                 "stream game audio: filter 'alarm cue' (gain_filter) missing", "stream game audio: tracks 2 off",
                 "stream overlay: tracks 2 off", "stream cam1: tracks 2 off"):
        assert part in text, (part, text)
    assert "Track2Bitrate" not in text and "stream background" not in text
    print(f"1. --check on pogwin's state: {len(diffs)} differences, nothing changed: ok")

    o.inputs["replay clip"]["muted"] = True
    s.run(apply=True)
    clean, amb = o.inputs["stream game clean"], o.inputs["replay game ambience"]
    assert clean["settings"] == {"window": WIN, "priority": 2} and amb["settings"] == clean["settings"]
    assert clean["volume"] == -2.0 and amb["volume"] == -16.0
    assert o.items == {("stream", "stream game clean"): True, ("replay", "replay game ambience"): False}
    assert {k for k, v in clean["tracks"].items() if v} == {"2"} and amb["tracks"]["1"] and not amb["tracks"]["2"]
    assert [f["filterName"] for f in clean["filters"]] == ["limit peaks", "alarm cue", "alarm hold"]
    assert [f["filterName"] for f in amb["filters"]] == ["duck under voices", "limit peaks", "alarm cue", "alarm hold"]
    for src in ("stream game clean", "replay game ambience", "stream game audio"):
        assert o.filt(src, "alarm cue")["filterEnabled"] is False and o.filt(src, "alarm hold")["filterEnabled"] is False
        assert o.filt(src, "alarm cue")["filterSettings"] == {"db": -6.0} and o.filt(src, "alarm hold")["filterSettings"] == {"db": -24.0}
    assert o.filt("replay clip", "duck under voices")["filterSettings"]["sidechain_source"] == "stream overlay"
    assert all(not o.inputs[n]["tracks"]["2"] for n in o.inputs if n != "stream game clean" and not o.inputs[n].get("noaudio"))
    assert o.profile[("AdvOut", "RecTracks")] == "3" and o.profile[("AdvOut", "Track2Name")] == "game only"
    assert o.inputs["replay clip"]["muted"] is True
    print("2. --apply: the sources, filters (gains disabled), tracks, the hidden ambience item and the profile: ok")

    n = len(o.calls)
    assert s.run(apply=False) == [] and s.run(apply=True) == []
    assert not [c for c in o.calls[n:] if not c[0].startswith("Get")], "a second apply changes nothing"
    # the service's own state is not compared nor reset
    o.filt("stream game audio", "alarm hold")["filterEnabled"] = True
    o.items[("replay", "replay game ambience")] = True
    o.inputs["replay clip"]["muted"] = False
    assert s.run(apply=True) == [] and o.filt("stream game audio", "alarm hold")["filterEnabled"] is True
    print("3. idempotent: a second check finds nothing, a second apply sends nothing; the service's toggles left alone: ok")

    src = open(os.path.join(HERE, "obs.py")).read()
    duck = eval(re.search(r"^DUCK = (\{.*\})", src, re.M).group(1))
    assert duck == su.DUCK and float(re.search(r"^GAME_LIMIT = (-?[\d.]+)", src, re.M).group(1)) == su.GAME_LIMIT
    assert su.rec_tracks("1") == "3" and su.rec_tracks("5") == "7" and su.rec_tracks("3") == "3"
    try:
        su.main(["--check"])
        raise AssertionError("reached OBS")
    except (SystemExit, ImportError) as e:
        assert "POG_TEST" in str(e) or isinstance(e, ImportError), e
    print("4. its settings agree with tools/obs.py; a test run never reaches the live OBS: ok")
    print("test_obs_setup_326: all ok")


if __name__ == "__main__":
    main()
