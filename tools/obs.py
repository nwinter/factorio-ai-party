#!/usr/bin/env python3
"""OBS control for pog recordings (through the SSH tunnel on 127.0.0.1:4455).

  tools/.venv/bin/python tools/obs.py coop-scene --left astra --right opus --title "..."
  tools/.venv/bin/python tools/obs.py start|stop|pause|resume|status       (recording)
  tools/.venv/bin/python tools/obs.py stream-start|stream-stop|stream-status   (YouTube; key in ~/.config/pog/youtube.key)
  tools/.venv/bin/python tools/obs.py shot OUT.png        # what OBS is composing right now
  tools/.venv/bin/python tools/obs.py stream-scene [--url http://127.0.0.1:8787/]   # overlay + 3 director cams
      (one on air in the left column; --layout tools/stream/static/layout-3cam.json: main + two side cameras)
  tools/.venv/bin/python tools/obs.py shot OUT.png --scene stream                  # any scene, no switching
  tools/.venv/bin/python tools/obs.py scene NAME                                   # switch the program scene
  tools/.venv/bin/python tools/obs.py stream-audio        # game audio (cam1 only) ducked under the overlay's voices
  tools/.venv/bin/python tools/obs.py rehook-cams         # the stream camN captures off and on (hook joined clients), then cropped
  tools/.venv/bin/python tools/obs.py cams                # read only: each camera's hole, crop and the crop it takes
  tools/.venv/bin/python tools/obs.py host-view-source    # add Nick's client capture ("stream host", off) to the live scene
  tools/.venv/bin/python tools/obs.py audio-test --url URL [--game-url URL]        # scratch scene, same mix
  tools/.venv/bin/python tools/obs.py meter --seconds 20 [--inputs a,b]           # peak dBFS per input per second
"""
import argparse, base64, json, os, sys

import obsws_python as obs

OVERLAY = r"D:\pog\overlay\coop.txt"


def client():
    # (d24 batch186) never the live OBS from a test run
    if os.environ.get("POG_TEST") == "1":
        raise SystemExit("POG_TEST=1: tools/obs.py does not connect to OBS in a test run")
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


# Host view (tools/stream/hostview.py; Nick 16:39): a capture of his own client, factorio-nick.exe (start-client.ps1 -Slot
# -nick), matched by executable so it never hooks another Factorio (his Steam game on Sunday is factorio.exe); off
# unless the host view is on (tools/stream/cuts.py turns it on, in the on-air hole over the cameras). A game capture
# with no window to hook draws nothing; the slow hook rate keeps its look for the window cheap.
HOST_SOURCE, HOST_EXE = "stream host", "factorio-nick.exe"
HOST_SETTINGS = {"capture_mode": "window", "window": f"Factorio 2.0.77:Factorio:{HOST_EXE}", "priority": 2,
                 "capture_cursor": True, "allow_transparency": False, "hook_rate": 0}


def host_capture(c, scene, layout=LAYOUT):
    """The host capture in this scene, off, in the on-air hole (cropped as the cameras); returns its item id."""
    lay = json.load(open(layout)) if isinstance(layout, str) else layout
    x, y, w, h = lay["cams"]["main"]
    item = scene_input(c, scene, HOST_SOURCE, "game_capture", HOST_SETTINGS)
    c.set_scene_item_enabled(scene, item, False)
    place(c, scene, item, x, y, w, h)
    sys.path.insert(0, os.path.dirname(LAYOUT) + "/..")
    from cuts import crop_for
    src = c.get_scene_item_transform(scene, item).scene_item_transform
    if src.get("sourceWidth") and src.get("sourceHeight"):  # not running yet (0 x 0): the crop left as it is
        c.set_scene_item_transform(scene, item, crop_for(src["sourceWidth"], src["sourceHeight"], w, h))
    return item


def host_view_source(c, scene="stream", layout=LAYOUT):
    """One-off for the live scene: the host capture added (or set again) just below the overlay, off; nothing else in
    the scene changes."""
    item = host_capture(c, scene, layout)
    items = c.get_scene_item_list(scene).scene_items
    idx = {i["sourceName"]: i["sceneItemIndex"] for i in items}
    ov, mine = idx.get("stream overlay"), idx.get(HOST_SOURCE)
    if ov is not None and mine is not None and mine != ov - 1:
        c.set_scene_item_index(scene, item, ov - 1 if mine < ov else ov)
    return f"{HOST_SOURCE} ({HOST_EXE}) in {scene}, off until host view is on"


def scene_source(c, scene, name):
    """Source `name` (an input or a scene) in this scene: added if missing; its item id."""
    if name not in [i["sourceName"] for i in c.get_scene_item_list(scene).scene_items]:
        c.create_scene_item(scene, name, True)
    return c.get_scene_item_id(scene, name).scene_item_id


# (d27 batch285 cp5) Camera panels (tools/cams.py POG_CAM_PANELS) come out of cam1's capture. OBS hooks a process once:
# a second game capture of factorio-cam1.exe never hooks (live check d27 22:08, OBS log `init_pipe: failed to start
# pipe` every 2 s), while crop is per scene item, so one capture can show in several places. Each panel is a scene named
# like the camera ("stream cam2"), holding one item of "stream cam1" cropped to the panel's rect and scaled to fill the
# canvas: in "stream" it is one item per name as before (cuts.py, rehook-cams, cams and vertical.py find items by name)
# and an ordinary 16:9 camera (crop_for). OBS names are unique across inputs and scenes, so the client capture of that
# name is removed while panels are on (and the scene removed when they are off again).
PANEL_SOURCE = "stream cam1"
CANVAS = (1920, 1080)


def panel_crop(rect, size):
    """The crop that leaves rect [x, y, w, h] of a frame of size (w, h)."""
    x, y, w, h = rect
    sw, sh = size
    return {"cropLeft": int(x), "cropTop": int(y), "cropRight": max(0, int(sw - x - w)), "cropBottom": max(0, int(sh - y - h))}


def panel_scene(c, name, rect, src=PANEL_SOURCE):
    """Scene `name` with one item of `src`, cropped to rect and filling the canvas; created (and an input of that name
    removed) when missing. The crop is from the capture's size, or cam1's window (tools/cams.py CLIENT) before it hooks;
    rehook-cams sets it again once it has hooked (panel_crops)."""
    if name in [i["inputName"] for i in c.get_input_list().inputs]:
        c.remove_input(name)
    if name not in [s["sceneName"] for s in c.get_scene_list().scenes]:
        c.create_scene(name)
    item = None
    for it in c.get_scene_item_list(name).scene_items:  # src once, nothing else
        if it["sourceName"] == src and item is None:
            item = it["sceneItemId"]
        else:
            c.remove_scene_item(name, it["sceneItemId"])
    if item is None:
        item = c.create_scene_item(name, src, True).scene_item_id
    return set_panel_crop(c, name, item, rect)


def set_panel_crop(c, name, item, rect):
    """The panel scene's item cropped to rect and scaled into the canvas; returns the crop."""
    import cams as cams_mod
    t = c.get_scene_item_transform(name, item).scene_item_transform
    size = (t["sourceWidth"], t["sourceHeight"]) if t.get("sourceWidth") and t.get("sourceHeight") else cams_mod.CLIENT
    crop = panel_crop(rect, size)
    c.set_scene_item_transform(name, item, dict(crop, positionX=0, positionY=0, alignment=5, boundsType="OBS_BOUNDS_SCALE_INNER",
                                                boundsWidth=CANVAS[0], boundsHeight=CANVAS[1], boundsAlignment=0))
    return crop


def panel_crops(c, panels, src=PANEL_SOURCE):
    """Each existing panel scene's crop set again from the capture's size (rehook-cams, once cam1 has hooked); a
    missing panel scene is named (stream-scene makes it)."""
    scenes = [s["sceneName"] for s in c.get_scene_list().scenes]
    out = []
    for name, rect in panels.items():
        items = c.get_scene_item_list(name).scene_items if name in scenes else []
        item = next((it["sceneItemId"] for it in items if it["sourceName"] == src), None)
        if item is None:
            out.append(f"{name} (panel scene): missing (run stream-scene)")
            continue
        crop = set_panel_crop(c, name, item, rect)
        out.append(f"{name} (panel scene): {src}, crop {crop['cropLeft']}/{crop['cropRight']} {crop['cropTop']}/{crop['cropBottom']}")
    return out


def stream_scene(c, url, scene="stream", layout=LAYOUT):
    """Director layout under the browser-source overlay. One camera on air (layout.json mode "onecam"): the three
    captures of factorio-cam1..3.exe all sit in the left column, centre-cropped to its shape; the stream service
    (tools/stream/cuts.py) brings the one on air to the front. Else (layout-3cam.json): 1 large + 2 small.
    POG_CAM_PANELS: "stream cam2"/"stream cam3" are panel scenes (panel_scene) instead of captures of their clients."""
    if scene not in [s["sceneName"] for s in c.get_scene_list().scenes]:
        c.create_scene(scene)
    lay = json.load(open(layout))
    cams, onecam = lay["cams"], lay.get("mode") == "onecam"
    order = []
    bg = scene_input(c, scene, "stream background", "color_source_v3", {"color": 0xFF181210, "width": 1920, "height": 1080})
    place(c, scene, bg, 0, 0, 1920, 1080)
    order.append(bg)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cams as cams_mod
    panels = cams_mod.panel_sources()  # (d27 batch285 B) POG_CAM_PANELS: cam2/cam3 are views of cam1's capture
    scenes = [s["sceneName"] for s in c.get_scene_list().scenes]
    for i, slot in enumerate(("main", "cam2", "cam3"), 1):
        name = f"stream cam{i}"
        if name in panels:
            panel_scene(c, name, panels[name])
            item = scene_source(c, scene, name)
        else:
            if name in scenes:  # a panel scene from a shift with panels: the client capture takes its name again
                c.remove_scene(name)
            item = scene_input(c, scene, name, "game_capture", {
                "capture_mode": "window", "window": f"Factorio 2.0.77:Factorio:factorio-cam{i}.exe", "priority": 2,
                "capture_cursor": False, "allow_transparency": False})
        x, y, w, h = cams["main" if onecam else slot]
        place(c, scene, item, x, y, w, h)
        # cropped to the hole's shape (none for a 16:9 hole, which also clears a crop left by the other layout).
        # (d24 batch136 PH2) a capture not hooked yet reads 0 x 0: its crop is left as it is (crop_for gave none and the
        # main hole showed it letterboxed); rehook-cams crops it once its client has joined
        sys.path.insert(0, os.path.dirname(LAYOUT) + "/..")
        from cuts import crop_for
        src = c.get_scene_item_transform(scene, item).scene_item_transform
        if src.get("sourceWidth") and src.get("sourceHeight"):
            c.set_scene_item_transform(scene, item, crop_for(src["sourceWidth"], src["sourceHeight"], w, h))
        order.append(item)
    order.append(host_capture(c, scene, lay))  # Nick's own client, off until host view (above the cameras)
    ov = scene_input(c, scene, "stream overlay", "browser_source", {
        "url": url, "width": 1920, "height": 1080, "fps": 30, "fps_custom": True, "css": "",
        "shutdown": False, "restart_when_active": False, "reroute_audio": True})
    c.set_scene_item_transform(scene, ov, {"positionX": 0, "positionY": 0, "alignment": 5, "boundsType": "OBS_BOUNDS_NONE",
                                           "scaleX": 1.0, "scaleY": 1.0})
    order.append(ov)
    for idx, item in enumerate(order):
        c.set_scene_item_index(scene, item, idx)
    c.press_input_properties_button("stream overlay", "refreshnocache")  # the page reads its layout once, at load
    return scene


# ---- audio (docs/AUDIO-NOTES.md) ------------------------------------------------------------------------------------
GAME_DB = 4.0      # cam1 spectating a base peaks near -28 dBFS raw (metered 2026-10-10); music off (-Sound)
GAME_LIMIT = -12.0  # limiter on the game so a nearby explosion can't jump over the voices
MUSIC_DB = -24.0   # slot for an original music bed
MUSIC_FILE = r"D:\pog\music\bed.mp3"  # off (music=False) until the file exists: OBS warns at every start about a missing file
# Sidechain ducking from the overlay page (casters + agent voices) while anyone talks. Ratio 6 measured ~22 dB down
# (the game vanished); 2.5 aims at ~12-14 dB so the factory stays audible under the voices.
DUCK = {"ratio": 2.5, "threshold": -40.0, "attack_time": 15, "release_time": 700, "output_gain": 0.0}


def rehook_cams(c, scene="stream", n=3, wait_s=10.0, step_s=0.5, sleep=None):
    """Turn each game capture "stream camN" off and on again so it hooks the client that has just joined (19:15: the
    captures started before the clients and the picture stayed black). An item that was off stays off.
    (d23 16:28, Nick: the main view letterboxed, cam1 and cam3 at crop 0 after the 16:20 shift change) then each capture
    is cropped to its hole's shape, as stream_scene does, once its source has a size: a game capture reads 0 x 0 until it
    hooks a client, and stream_scene runs before the clients join. A re-enabled capture is read every step_s for up to
    wait_s (the whole call's budget); one off is read once."""
    import time
    sleep = sleep or time.sleep
    out, todo = [], []
    for i in range(1, n + 1):
        name = f"stream cam{i}"
        try:
            item = c.get_scene_item_id(scene, name).scene_item_id
        except Exception as e:  # noqa: BLE001
            out.append(f"{name}: not in {scene} ({type(e).__name__})")
            continue
        was = c.get_scene_item_enabled(scene, item).scene_item_enabled
        if not was:
            out.append(f"{name}: off, left off")
            todo.append((len(out) - 1, name, item, False))
            continue
        c.set_scene_item_enabled(scene, item, False)
        sleep(0.5)
        c.set_scene_item_enabled(scene, item, True)
        out.append(f"{name}: re-enabled")
        todo.append((len(out) - 1, name, item, True))
    sys.path.insert(0, os.path.dirname(LAYOUT) + "/..")
    from cuts import crop_for
    left = wait_s
    for k, name, item, on in todo:
        while True:
            t = c.get_scene_item_transform(scene, item).scene_item_transform
            sw, sh = t.get("sourceWidth") or 0, t.get("sourceHeight") or 0
            if (sw and sh) or not on or left <= 0:
                break
            sleep(step_s)
            left -= step_s
        bw, bh = t.get("boundsWidth") or 0, t.get("boundsHeight") or 0
        if not (sw and sh and bw and bh):
            out[k] += (f"; no source size after {wait_s:g} s" if on else "; no source size") + \
                f", crop not set (left {t.get('cropLeft', 0)}/{t.get('cropRight', 0)} {t.get('cropTop', 0)}/{t.get('cropBottom', 0)})"
            continue
        crop = crop_for(sw, sh, bw, bh)
        was_crop = tuple(t.get(f"crop{side}", 0) for side in ("Left", "Right", "Top", "Bottom"))
        now = tuple(crop[f"crop{side}"] for side in ("Left", "Right", "Top", "Bottom"))
        c.set_scene_item_transform(scene, item, crop)
        out[k] += (f"; crop {now[0]}/{now[1]} {now[2]}/{now[3]} (source {sw:g}x{sh:g} into {bw:g}x{bh:g}"
                   + (", unchanged)" if now == was_crop else f", was {was_crop[0]}/{was_crop[1]} {was_crop[2]}/{was_crop[3]})"))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cams as cams_mod
    panels = cams_mod.panel_sources()
    if panels:  # (batch285 cp5) cam1 has hooked by now: each panel's crop from its real size
        out += panel_crops(c, panels)
    return " | ".join(out)


def cams_check(c, scene="stream", n=3, layout=LAYOUT):
    """Read only (d24 batch136 PH2: cam3 read crop 0 at about 21:07 while it was the inset, which is uncropped by
    design): each "stream camN" with its hole (by its bounds: layout.json's main or inset, layout-3cam.json's trio
    tiles), source size, crop, and the crop crop_for gives that size in that hole: ok, CROP OFF, or no source size.
    With POG_CAM_PANELS, each panel scene's crop of cam1's capture against its rect too (panel_check)."""
    sys.path.insert(0, os.path.dirname(LAYOUT) + "/..")
    from cuts import crop_for, TRIO
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cams as cams_mod
    panels = cams_mod.panel_sources()
    holes = {}
    for path, prefix in ((layout, ""), (TRIO, "trio ")):
        lay = json.load(open(path)) if isinstance(path, str) else path
        for k, (_, _, w, h) in lay["cams"].items():
            holes.setdefault((float(w), float(h)), prefix + k)
    out = []
    for i in range(1, n + 1):
        name = f"stream cam{i}"
        try:
            item = c.get_scene_item_id(scene, name).scene_item_id
        except Exception as e:  # noqa: BLE001
            out.append(f"{name}: not in {scene} ({type(e).__name__})")
            continue
        on = c.get_scene_item_enabled(scene, item).scene_item_enabled
        t = c.get_scene_item_transform(scene, item).scene_item_transform
        sw, sh, bw, bh = (t.get(k) or 0 for k in ("sourceWidth", "sourceHeight", "boundsWidth", "boundsHeight"))
        hole = holes.get((float(bw), float(bh)), f"bounds {bw:g}x{bh:g}")
        crop = tuple(t.get(f"crop{side}", 0) for side in ("Left", "Right", "Top", "Bottom"))
        text = f"{name}: {'on' if on else 'off'}, {hole}, crop {crop[0]}/{crop[1]} {crop[2]}/{crop[3]}"
        if not (sw and sh):
            out.append(text + ", no source size (not hooked)")
            continue
        want = crop_for(sw, sh, bw, bh)
        want = tuple(want[f"crop{side}"] for side in ("Left", "Right", "Top", "Bottom"))
        out.append(text + f", source {sw:g}x{sh:g}: " + ("ok" if want == crop else f"CROP OFF (that hole takes {want[0]}/{want[1]} {want[2]}/{want[3]})"))
    if panels:
        out += panel_check(c, panels)
    return " | ".join(out)


def panel_check(c, panels, src=PANEL_SOURCE):
    """Read only: each panel scene's item of cam1's capture, its crop against its rect."""
    import cams as cams_mod
    scenes = [s["sceneName"] for s in c.get_scene_list().scenes]
    out = []
    for name, rect in panels.items():
        items = c.get_scene_item_list(name).scene_items if name in scenes else []
        item = next((it["sceneItemId"] for it in items if it["sourceName"] == src), None)
        if item is None:
            out.append(f"{name} (panel scene): MISSING (run stream-scene)")
            continue
        t = c.get_scene_item_transform(name, item).scene_item_transform
        hooked = bool(t.get("sourceWidth") and t.get("sourceHeight"))
        want = panel_crop(rect, (t["sourceWidth"], t["sourceHeight"]) if hooked else cams_mod.CLIENT)
        crop = tuple(t.get(f"crop{side}", 0) for side in ("Left", "Right", "Top", "Bottom"))
        want = tuple(want[f"crop{side}"] for side in ("Left", "Right", "Top", "Bottom"))
        extra = "" if len(items) == 1 else f", {len(items)} items"
        out.append(f"{name} (panel scene): {src} at {rect}, crop {crop[0]}/{crop[1]} {crop[2]}/{crop[3]}{extra}" +
                   ("" if hooked else " (not hooked)") + (": ok" if want == crop and not extra else
                                                          f": CROP OFF (the rect takes {want[0]}/{want[1]} {want[2]}/{want[3]})"))
    return out


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
                                    "stream-audio", "audio-test", "meter", "replay-stop", "rehook-cams", "cams",
                                    "host-view-source"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--game-url", help="audio-test: loop this audio URL as a stand-in for the game client")
    ap.add_argument("--seconds", type=float, default=20, help="meter: how long to listen")
    ap.add_argument("--inputs", default="", help="meter: comma-separated input names (default: all)")
    ap.add_argument("--left", default="astra")
    ap.add_argument("--right", default="opus")
    ap.add_argument("--url", default="http://127.0.0.1:8787/", help="stream-scene: overlay page as seen from the box")
    ap.add_argument("--scene", help="shot: screenshot this scene instead of the program scene")
    ap.add_argument("--layout", default=LAYOUT, help="stream-scene: camera holes (layout-3cam.json: the old three)")
    ap.add_argument("--title", default="Astra + Opus 5.5 play Factorio together (real time)")
    a = ap.parse_args()
    c = client()
    if a.cmd == "coop-scene":
        print("scene", coop_scene(c, a.left, a.right, a.title))
    elif a.cmd == "stream-scene":
        print("scene", stream_scene(c, a.url, layout=a.layout))
    elif a.cmd == "stream-audio":
        print("audio inputs", stream_audio(c))
    elif a.cmd == "rehook-cams":
        print(rehook_cams(c))
    elif a.cmd == "cams":
        print(cams_check(c))
    elif a.cmd == "host-view-source":
        print(host_view_source(c, layout=a.layout))
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
