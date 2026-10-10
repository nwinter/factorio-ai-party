#!/usr/bin/env python3
"""OBS control for pog recordings (through the SSH tunnel on 127.0.0.1:4455).

  tools/.venv/bin/python tools/obs.py coop-scene --left astra --right opus --title "..."
  tools/.venv/bin/python tools/obs.py start|stop|pause|resume|status
  tools/.venv/bin/python tools/obs.py shot OUT.png        # what OBS is composing right now
"""
import argparse, base64, os, sys

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["coop-scene", "start", "stop", "pause", "resume", "status", "shot"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--left", default="astra")
    ap.add_argument("--right", default="opus")
    ap.add_argument("--title", default="Astra + Opus 5.5 play Factorio together (real time)")
    a = ap.parse_args()
    c = client()
    if a.cmd == "coop-scene":
        print("scene", coop_scene(c, a.left, a.right, a.title))
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
    elif a.cmd == "shot":
        scene = c.get_current_program_scene().scene_name
        img = c.get_source_screenshot(scene, "png", 1280, 720, -1).image_data
        open(a.out, "wb").write(base64.b64decode(img.split(",", 1)[1]))
        print(a.out)


if __name__ == "__main__":
    main()
