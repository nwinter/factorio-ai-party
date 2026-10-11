#!/usr/bin/env python3
"""OBS control for pog recordings (through the SSH tunnel on 127.0.0.1:4455).

  tools/.venv/bin/python tools/obs.py coop-scene --left astra --right opus --title "..."
  tools/.venv/bin/python tools/obs.py start|stop|pause|resume|status       (recording)
  tools/.venv/bin/python tools/obs.py stream-start|stream-stop|stream-status   (YouTube; key in ~/.config/pog/youtube.key)
  tools/.venv/bin/python tools/obs.py shot OUT.png        # what OBS is composing right now
  tools/.venv/bin/python tools/obs.py stream-scene [--url http://127.0.0.1:8787/]   # overlay + 3 director cams
  tools/.venv/bin/python tools/obs.py shot OUT.png --scene stream                  # any scene, no switching
  tools/.venv/bin/python tools/obs.py scene NAME                                   # switch the program scene
  tools/.venv/bin/python tools/obs.py stream-audio        # game audio (cam1 only) ducked under the overlay's voices
  tools/.venv/bin/python tools/obs.py audio-test --url URL [--game-url URL]        # scratch scene, same mix
  tools/.venv/bin/python tools/obs.py meter --seconds 20 [--inputs a,b]           # peak dBFS per input per second
"""
import argparse, base64, json, os, sys

import obsws_python as obs

OVERLAY = r"D:\pog\overlay\coop.txt"


def client():
    pw = open(os.path.expanduser("~/.config/pog/obs.pw")).read().strip()
    return obs.ReqClient(host="127.0.0.1", port=4455, password=pw, timeout=15)


def ensure_input(c, scene, name, kind, settings):
    names = [i["inputName"] for i in c.get_input_list().inputs]
    if name in names:
        c.set_input_settings(name, settings, True)
    else:
        c.create_input(scene, name, kind, settings, True)
    return c.get_scene_item_id(scene, name).scene_item_id


def place(c, scene, item, x, y, w, h):
    c.set_scene_item_transform(scene, item, {
        "positionX": x, "positionY": y, "boundsType": "OBS_BOUNDS_SCALE_INNER",
        "boundsWidth": w, "boundsHeight": h, "boundsAlignment": 0, "alignment": 5})


def coop_scene(c, left, right, title):
    scene = "co-op"
    if scene not in [s["sceneName"] for s in c.get_scene_list().scenes]:
        c.create_scene(scene)
    c.set_current_program_scene(scene)
    bg = ensure_input(c, scene, "background", "color_source_v3", {"color": 0xFF1A1A1A, "width": 1920, "height": 1080})
    place(c, scene, bg, 0, 0, 1920, 1080)
    for i, (slot, x) in enumerate(((left, 0), (right, 960))):
        exe = f"factorio-{slot}.exe"
        item = ensure_input(c, scene, f"game {slot}", "game_capture", {
            "capture_mode": "window", "window": f"Factorio 2.0.77:Factorio:{exe}", "priority": 2,
            "capture_cursor": False, "allow_transparency": False})
        place(c, scene, item, x, 120, 960, 540)
        label = ensure_input(c, scene, f"label {slot}", "text_gdiplus_v3", {
            "text": f"pog-{slot}", "font": {"face": "Segoe UI", "size": 34, "style": "Bold"}, "color": 0xFFFFFFFF})
        c.set_scene_item_transform(scene, label, {"positionX": x + 20, "positionY": 668, "alignment": 5})
    t = ensure_input(c, scene, "title", "text_gdiplus_v3", {
        "text": title, "font": {"face": "Segoe UI", "size": 44, "style": "Bold"}, "color": 0xFFFFFFFF})
    c.set_scene_item_transform(scene, t, {"positionX": 30, "positionY": 30, "alignment": 5})
    feed = ensure_input(c, scene, "overlay", "text_gdiplus_v3", {
        "read_from_file": True, "file": OVERLAY, "font": {"face": "Consolas", "size": 26, "style": "Regular"},
        "color": 0xFFE0E0E0, "extents": True, "extents_cx": 1860, "extents_cy": 340, "wrap": True})
    c.set_scene_item_transform(scene, feed, {"positionX": 30, "positionY": 725, "alignment": 5})
    return scene


LAYOUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream", "static", "layout.json")


def scene_input(c, scene, name, kind, settings):
    """Create the input, or update it and make sure it is in this scene (inputs are global in OBS)."""
    names = [i["inputName"] for i in c.get_input_list().inputs]
    if name in names:
        c.set_input_settings(name, settings, True)
        items = [i["sourceName"] for i in c.get_scene_item_list(scene).scene_items]
        if name not in items:
            c.create_scene_item(scene, name, True)
    else:
        c.create_input(scene, name, kind, settings, True)
    return c.get_scene_item_id(scene, name).scene_item_id


def stream_scene(c, url, scene="stream"):
    """Director layout: 1 large + 2 small captures of factorio-cam1..3.exe under the browser-source overlay."""
    if scene not in [s["sceneName"] for s in c.get_scene_list().scenes]:
        c.create_scene(scene)
    cams = json.load(open(LAYOUT))["cams"]
    order = []
    bg = scene_input(c, scene, "stream background", "color_source_v3", {"color": 0xFF181210, "width": 1920, "height": 1080})
    place(c, scene, bg, 0, 0, 1920, 1080)
    order.append(bg)
    for i, slot in enumerate(("main", "cam2", "cam3"), 1):
        exe = f"factorio-cam{i}.exe"
        item = scene_input(c, scene, f"stream cam{i}", "game_capture", {
            "capture_mode": "window", "window": f"Factorio 2.0.77:Factorio:{exe}", "priority": 2,
            "capture_cursor": False, "allow_transparency": False})
        x, y, w, h = cams[slot]
        place(c, scene, item, x, y, w, h)
        order.append(item)
    ov = scene_input(c, scene, "stream overlay", "browser_source", {
        "url": url, "width": 1920, "height": 1080, "fps": 30, "fps_custom": True, "css": "",
        "shutdown": False, "restart_when_active": False, "reroute_audio": True})
    c.set_scene_item_transform(scene, ov, {"positionX": 0, "positionY": 0, "alignment": 5, "boundsType": "OBS_BOUNDS_NONE",
                                           "scaleX": 1.0, "scaleY": 1.0})
    order.append(ov)
    for idx, item in enumerate(order):
        c.set_scene_item_index(scene, item, idx)
    return scene


# ---- audio (docs/AUDIO-NOTES.md) ------------------------------------------------------------------------------------
GAME_DB = 4.0      # cam1 spectating a base peaks near -28 dBFS raw (metered 2026-10-10); music off (-Sound)
GAME_LIMIT = -12.0  # limiter on the game so a nearby explosion can't jump over the voices
MUSIC_DB = -24.0   # slot for an original music bed
MUSIC_FILE = r"D:\pog\music\bed.mp3"  # off (music=False) until the file exists: OBS warns at every start about a missing file
# Sidechain ducking from the overlay page (casters + agent voices) while anyone talks. Ratio 6 measured ~22 dB down
# (the game vanished); 2.5 aims at ~12-14 dB so the factory stays audible under the voices.
DUCK = {"ratio": 2.5, "threshold": -40.0, "attack_time": 15, "release_time": 700, "output_gain": 0.0}


def ensure_filter(c, source, name, kind, settings):
    if name in [f["filterName"] for f in c.get_source_filter_list(source).filters]:
        c.set_source_filter_settings(source, name, settings, True)
    else:
        c.create_source_filter(source, name, kind, settings)


def stream_audio(c, scene="stream", overlay="stream overlay", prefix="stream", exe="factorio-cam1.exe",
                 game_url=None, music=False):
    """Game audio from the main director client only, ducked under the overlay page's voices, plus a music slot."""
    game = f"{prefix} game audio"
    if game_url:  # test stand-in: any audio URL looped through a media source
        game = f"{prefix} game stand-in"
        scene_input(c, scene, game, "ffmpeg_source", {"is_local_file": False, "input": game_url, "looping": True,
                                                      "restart_on_activate": True, "close_when_inactive": False})
    else:
        scene_input(c, scene, game, "wasapi_process_output_capture",
                    {"window": f"Factorio 2.0.77:Factorio:{exe}", "priority": 2})
    c.set_input_volume(game, vol_db=GAME_DB)
    ensure_filter(c, game, "duck under voices", "compressor_filter", dict(DUCK, sidechain_source=overlay))
    ensure_filter(c, game, "limit peaks", "limiter_filter", {"threshold": GAME_LIMIT, "release_time": 60})
    c.set_input_settings(overlay, {"reroute_audio": True}, True)  # "Control audio via OBS"
    c.set_input_volume(overlay, vol_db=0.0)
    # voices arrive at -18 LUFS / -1.5 dBTP; one clip metered +5.5 dBFS right after a page reload, so cap it
    ensure_filter(c, overlay, "limit peaks", "limiter_filter", {"threshold": -1.0, "release_time": 60})
    inputs = {i["inputName"]: i["inputKind"] for i in c.get_input_list().inputs}
    for i in (1, 2, 3):  # the video captures stay silent; only the process capture above carries game sound
        if inputs.get(f"stream cam{i}") == "game_capture":
            c.set_input_settings(f"stream cam{i}", {"capture_audio": False}, True)
    if music:
        bed = f"{prefix} music bed"
        item = scene_input(c, scene, bed, "ffmpeg_source", {"is_local_file": True, "local_file": MUSIC_FILE,
                                                            "looping": True, "close_when_inactive": False})
        c.set_input_volume(bed, vol_db=MUSIC_DB)
        ensure_filter(c, bed, "duck under voices", "compressor_filter", dict(DUCK, sidechain_source=overlay))
        c.set_scene_item_enabled(scene, item, False)  # enable once an original track exists at MUSIC_FILE
    return [game] + ([f"{prefix} music bed"] if music else [])


def audio_test_scene(c, url, game_url=None):
    """Scratch scene 'audio-test': its own overlay browser source (url) and game audio, same mix as 'stream'."""
    scene = "audio-test"
    if scene not in [s["sceneName"] for s in c.get_scene_list().scenes]:
        c.create_scene(scene)
    bg = scene_input(c, scene, "audio-test background", "color_source_v3",
                     {"color": 0xFF102018, "width": 1920, "height": 1080})
    place(c, scene, bg, 0, 0, 1920, 1080)
    ov = scene_input(c, scene, "audio-test overlay", "browser_source", {
        "url": url, "width": 1920, "height": 1080, "fps": 30, "fps_custom": True, "shutdown": True,
        "restart_when_active": False, "reroute_audio": True})  # shut when hidden: Chrome's 6 connections per host
    c.set_scene_item_transform(scene, ov, {"positionX": 0, "positionY": 0, "alignment": 5,
                                           "boundsType": "OBS_BOUNDS_NONE", "scaleX": 1.0, "scaleY": 1.0})
    stream_audio(c, scene, overlay="audio-test overlay", prefix="audio-test", game_url=game_url, music=False)
    return scene


def meter(c, seconds, names):
    """Peak dBFS per input, per second, from OBS's own meters (post-filter, post-fader)."""
    import math, time
    levels = {}
    ev = obs.EventClient(host="127.0.0.1", port=4455, password=open(os.path.expanduser("~/.config/pog/obs.pw")).read().strip(),
                         subs=obs.Subs.LOW_VOLUME | obs.Subs.INPUTVOLUMEMETERS)

    def on_input_volume_meters(data):
        sec = int(time.time())
        for i in data.inputs:
            if names and i["inputName"] not in names:
                continue
            peak = max((ch[1] for ch in i["inputLevelsMul"]), default=0.0)
            db = 20 * math.log10(peak) if peak > 0 else -99.0
            row = levels.setdefault(sec, {})
            row[i["inputName"]] = max(row.get(i["inputName"], -99.0), db)

    ev.callback.register(on_input_volume_meters)
    time.sleep(seconds)
    ev.disconnect()
    return levels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["coop-scene", "stream-scene", "scene", "reload-overlay", "start", "stop", "pause",
                                    "resume", "status", "shot", "stream-start", "stream-stop", "stream-status",
                                    "stream-audio", "audio-test", "meter", "replay-stop"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--game-url", help="audio-test: loop this audio URL as a stand-in for the game client")
    ap.add_argument("--seconds", type=float, default=20, help="meter: how long to listen")
    ap.add_argument("--inputs", default="", help="meter: comma-separated input names (default: all)")
    ap.add_argument("--left", default="astra")
    ap.add_argument("--right", default="opus")
    ap.add_argument("--url", default="http://127.0.0.1:8787/", help="stream-scene: overlay page as seen from the box")
    ap.add_argument("--scene", help="shot: screenshot this scene instead of the program scene")
    ap.add_argument("--title", default="Astra + Opus 5.5 play Factorio together (real time)")
    a = ap.parse_args()
    c = client()
    if a.cmd == "coop-scene":
        print("scene", coop_scene(c, a.left, a.right, a.title))
    elif a.cmd == "stream-scene":
        print("scene", stream_scene(c, a.url))
    elif a.cmd == "stream-audio":
        print("audio inputs", stream_audio(c))
    elif a.cmd == "audio-test":
        print("scene", audio_test_scene(c, a.url, a.game_url))
    elif a.cmd == "meter":
        names = [n for n in a.inputs.split(",") if n]
        for sec, row in sorted(meter(c, a.seconds, names).items()):
            print(sec % 1000, "  ".join(f"{k}={v:6.1f}" for k, v in sorted(row.items())))
    elif a.cmd == "scene":
        c.set_current_program_scene(a.out); print("program scene", a.out)
    elif a.cmd == "reload-overlay":
        c.press_input_properties_button("stream overlay", "refreshnocache"); print("reloaded")
    elif a.cmd == "start":
        c.start_record(); print("recording")
    elif a.cmd == "stop":
        print("saved", c.stop_record().output_path)
    elif a.cmd == "pause":
        c.pause_record(); print("paused")
    elif a.cmd == "resume":
        c.resume_record(); print("resumed")
    elif a.cmd == "status":
        r = c.get_record_status()
        print(f"active={r.output_active} paused={r.output_paused} time={r.output_timecode} bytes={r.output_bytes}")
    elif a.cmd == "stream-start":
        c.start_stream(); print("streaming to YouTube (visibility is set in YouTube Studio)")
    elif a.cmd == "stream-stop":
        c.stop_stream(); print("stream stopped")
    elif a.cmd == "replay-stop":
        c.stop_replay_buffer(); print("replay buffer stopped")
    elif a.cmd == "stream-status":
        r = c.get_stream_status()
        print(f"active={r.output_active} reconnecting={r.output_reconnecting} time={r.output_timecode} "
              f"skipped={r.output_skipped_frames}/{r.output_total_frames} congestion={r.output_congestion:.2f}")
    elif a.cmd == "shot":
        scene = a.scene or c.get_current_program_scene().scene_name
        img = c.get_source_screenshot(scene, "png", 1280, 720, -1).image_data
        open(a.out, "wb").write(base64.b64decode(img.split(",", 1)[1]))
        print(a.out)


if __name__ == "__main__":
    main()
