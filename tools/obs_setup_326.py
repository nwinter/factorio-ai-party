#!/usr/bin/env python3
"""OBS on pogwin for batch326 (game-only replay audio, quiet speaker alarms; docs/STREAM-NOTES.md "Replay sound and
speaker alarms"), through obs-websocket (tools/obs.py's client, the SSH tunnel on 127.0.0.1:4455):

  tools/.venv/bin/python tools/obs_setup_326.py --check     # read only: each difference, one line each; exit 1 if any
  tools/.venv/bin/python tools/obs_setup_326.py --apply     # make them, then check again (idempotent)

What it sets (the operator's 7 steps):
1. profile: AdvOut RecTracks gains track 2 (a bitmask: 1 -> 3), AdvOut Track2Name "game only", AdvOut Track2Bitrate
   160. Written to the profile; they take effect when OBS starts again (start-team restarts OBS each shift).
2. "stream game clean" in scene "stream": an Application Audio Capture of the same window as "stream game audio"
   (match executable), -2 dB, tracks: 2 only; filters: limiter "limit peaks" (-12 dB, 60 ms), gains "alarm cue"
   (-6 dB) and "alarm hold" (-24 dB), created disabled; no compressor.
3. "replay game ambience" in scene "replay": the same capture, -16 dB, tracks: 1 only; filters: compressor "duck under
   voices" (as "stream game audio"'s, sidechain "stream overlay"), the limiter, the two gains; its scene item created
   hidden (the service shows it per replay).
4. "replay clip": the compressor "duck under voices"; tracks: 1 only. Its mute is the service's (left as it is).
5. "stream game audio": the two gains; tracks: 1 only.
6. "stream overlay", "replay banner": tracks: 1 only; every other audio source: track 2 off.
Live: sources, filters, tracks and the scene item at once. Not compared (the service sets them while it runs): the
alarm gains' enabled state, the ambience item's visibility, "replay clip"'s mute.
"""
import argparse, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# as tools/obs.py (test_obs_setup_326.py checks they agree)
DUCK = {"ratio": 2.5, "threshold": -40.0, "attack_time": 15, "release_time": 700, "output_gain": 0.0}
GAME_LIMIT = -12.0
OVERLAY = "stream overlay"
LIMIT = ("limit peaks", "limiter_filter", {"threshold": GAME_LIMIT, "release_time": 60})
DUCKF = ("duck under voices", "compressor_filter", dict(DUCK, sidechain_source=OVERLAY))
CUE = ("alarm cue", "gain_filter", {"db": -6.0})
HOLD = ("alarm hold", "gain_filter", {"db": -24.0})
ALARM_GAINS = {"alarm cue", "alarm hold"}  # created disabled; enabled by the service (alarmquiet.py)
ONLY_1 = {"1": True, "2": False}
ONLY_2 = {"1": False, "2": True, "3": False, "4": False, "5": False, "6": False}
PROFILE = [("AdvOut", "Track2Name", "game only"), ("AdvOut", "Track2Bitrate", "160")]


def spec(window):
    """Each source's wanted state; window: "stream game audio"'s window setting (the same capture)."""
    cap = {"window": window, "priority": 2}  # 2: match executable
    return {
        "stream game clean": {"scene": "stream", "kind": "wasapi_process_output_capture", "settings": cap, "volume": -2.0,
                              "tracks": ONLY_2, "filters": [LIMIT, CUE, HOLD], "item_enabled": True},
        "replay game ambience": {"scene": "replay", "kind": "wasapi_process_output_capture", "settings": cap, "volume": -16.0,
                                 "tracks": ONLY_1, "filters": [DUCKF, LIMIT, CUE, HOLD], "item_enabled": False},
        "replay clip": {"tracks": ONLY_1, "filters": [DUCKF]},
        "stream game audio": {"tracks": ONLY_1, "filters": [CUE, HOLD]},
        "stream overlay": {"tracks": ONLY_1},
        "replay banner": {"tracks": ONLY_1},
    }


def rec_tracks(value):
    """RecTracks with track 2 added (a bitmask of tracks 1-6)."""
    try:
        n = int(value or 1)
    except ValueError:
        n = 1
    return str(n | 2 | 1)


class Setup:
    """send(request, data) -> dict: obs-websocket raw requests (obsws_python ReqClient.send(..., raw=True))."""

    def __init__(self, send):
        self.send = send
        self.diffs = []

    def q(self, req, data=None):
        return self.send(req, data) or {}

    def diff(self, text):
        self.diffs.append(text)

    def run(self, apply):
        self.diffs = []
        inputs = {i["inputName"]: i.get("inputKind") for i in self.q("GetInputList").get("inputs", [])}
        if "stream game audio" not in inputs:
            raise SystemExit('no "stream game audio" input: the stream scene is not set up (tools/obs.py stream-audio)')
        window = self.q("GetInputSettings", {"inputName": "stream game audio"}).get("inputSettings", {}).get("window")
        want = spec(window)
        # 1. the profile (takes effect at the next OBS start)
        cur = self.q("GetProfileParameter", {"parameterCategory": "AdvOut", "parameterName": "RecTracks"}).get("parameterValue")
        for cat, name, value in [("AdvOut", "RecTracks", rec_tracks(cur))] + PROFILE:
            got = cur if name == "RecTracks" else \
                self.q("GetProfileParameter", {"parameterCategory": cat, "parameterName": name}).get("parameterValue")
            if str(got) != value:
                self.diff(f"profile {cat}.{name}: {got!r}, wanted {value!r} (at the next OBS start)")
                if apply:
                    self.q("SetProfileParameter", {"parameterCategory": cat, "parameterName": name, "parameterValue": value})
        # 2-6. sources
        for name, w in want.items():
            if name not in inputs:
                if "kind" not in w:
                    self.diff(f"{name}: missing (made by the stream setup, not here)")
                    continue
                self.diff(f"{name}: missing ({w['kind']} in scene {w['scene']!r})")
                if not apply:
                    continue
                self.q("CreateInput", {"sceneName": w["scene"], "inputName": name, "inputKind": w["kind"],
                                       "inputSettings": w["settings"], "sceneItemEnabled": w["item_enabled"]})
                inputs[name] = w["kind"]
            elif "settings" in w:
                have = self.q("GetInputSettings", {"inputName": name}).get("inputSettings", {})
                off = {k: v for k, v in w["settings"].items() if have.get(k) != v}
                if off:
                    self.diff(f"{name}: settings {sorted(off)} differ ({ {k: have.get(k) for k in off} } -> {off})")
                    if apply:
                        self.q("SetInputSettings", {"inputName": name, "inputSettings": off, "overlay": True})
            if "volume" in w:
                v = self.q("GetInputVolume", {"inputName": name}).get("inputVolumeDb")
                if v is None or abs(float(v) - w["volume"]) > 0.05:
                    self.diff(f"{name}: volume {v} dB, wanted {w['volume']:g} dB")
                    if apply:
                        self.q("SetInputVolume", {"inputName": name, "inputVolumeDb": w["volume"]})
            self.filters(name, w.get("filters") or [], apply)
            self.tracks(name, w["tracks"], apply)
        for name in inputs:  # 6. every other audio source: track 2 off
            if name in want:
                continue
            try:
                t = self.q("GetInputAudioTracks", {"inputName": name}).get("inputAudioTracks")
            except Exception:
                continue  # no audio
            if t and t.get("2"):
                self.tracks(name, {"2": False}, apply, have=t)
        return self.diffs

    def filters(self, name, wanted, apply):
        have = {f["filterName"]: f for f in self.q("GetSourceFilterList", {"sourceName": name}).get("filters", [])}
        for fname, kind, settings in wanted:
            f = have.get(fname)
            if not f:
                self.diff(f"{name}: filter {fname!r} ({kind}) missing")
                if apply:
                    self.q("CreateSourceFilter", {"sourceName": name, "filterName": fname, "filterKind": kind,
                                                  "filterSettings": settings})
                    if fname in ALARM_GAINS:
                        self.q("SetSourceFilterEnabled", {"sourceName": name, "filterName": fname, "filterEnabled": False})
                continue
            if f.get("filterKind") != kind:
                self.diff(f"{name}: filter {fname!r} is a {f.get('filterKind')}, wanted {kind} (left as it is: rename or remove it)")
                continue
            off = {k: v for k, v in settings.items() if (f.get("filterSettings") or {}).get(k) != v}
            if off:
                self.diff(f"{name}: filter {fname!r} settings {off} differ ({ {k: (f.get('filterSettings') or {}).get(k) for k in off} })")
                if apply:
                    self.q("SetSourceFilterSettings", {"sourceName": name, "filterName": fname, "filterSettings": off,
                                                       "overlay": True})

    def tracks(self, name, wanted, apply, have=None):
        have = have or self.q("GetInputAudioTracks", {"inputName": name}).get("inputAudioTracks") or {}
        off = {k: v for k, v in wanted.items() if bool(have.get(k)) != v}
        if off:
            said = ", ".join(k + (" on" if v else " off") for k, v in sorted(off.items()))
            self.diff(f"{name}: tracks {said}")
            if apply:
                self.q("SetInputAudioTracks", {"inputName": name, "inputAudioTracks": off})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    sys.path.insert(0, HERE)
    import obs  # the venv's obsws_python; POG_TEST=1 refuses (never the live OBS from a test)
    c = obs.client()
    s = Setup(lambda req, data=None: c.send(req, data, raw=True))
    diffs = s.run(apply=a.apply)
    for d in diffs:
        print(("set: " if a.apply else "differs: ") + d)
    if a.apply:
        left = s.run(apply=False)
        for d in left:
            print("still differs: " + d)
        print(f"applied {len(diffs)} change(s); {len(left)} left" + (" (the profile's take effect at the next OBS start)"
                                                                     if any(d.startswith('profile') for d in left) else ""))
        return 0 if all(d.startswith("profile") for d in left) else 1
    print("OBS matches batch326" if not diffs else f"{len(diffs)} difference(s)")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
