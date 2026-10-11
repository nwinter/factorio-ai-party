#!/usr/bin/env python3
"""The vertical (9:16) stream: a designed portrait scene in Aitum Vertical's canvas (docs/VERTICAL-PROPOSAL.md).

Needs the Aitum Vertical plugin (1.6.x, OBS 31.1+) on the box and obs-websocket 5.7+ (canvasUuid on scene requests).
Through the same SSH tunnel as tools/obs.py (127.0.0.1:4455):

  tools/.venv/bin/python tools/vertical.py check                  # read-only: versions, canvases, the plugin's scenes
  tools/.venv/bin/python tools/vertical.py scene [--url http://127.0.0.1:8787/portrait]
  tools/.venv/bin/python tools/vertical.py settings [--dry-run]  # OBS CLOSED: encoder, CBR, bitrate, keyframes,
                                                                  # audio track, output + key, start/stop with main
  tools/.venv/bin/python tools/vertical.py key [--server URL]     # an existing output's key, live (see `settings`)
  tools/.venv/bin/python tools/vertical.py status|stop|start --yes
  tools/.venv/bin/python tools/vertical.py shot OUT.png           # the vertical scene, 540x960

`scene` builds "stream vertical" in the plugin's canvas: a background, the three director captures the landscape
"stream" scene already has ("stream cam1..3", the same inputs, so nothing is captured twice) in the holes of
tools/stream/static/layout-portrait.json, and a 1080x1920 browser source on /portrait on top. That browser source is
muted: the landscape overlay already carries the casters' and agents' voices, and OBS mixes audio once for every
output, so an unmuted portrait page would play every voice twice on both streams. It never touches the main canvas,
the program scene or the pog profile's outputs.
"""
import argparse, base64, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

VENDOR = "aitum-vertical-canvas"
CANVAS = "Aitum Vertical"       # the plugin's CANVAS_NAME (vertical-canvas.cpp)
SCENE = "stream vertical"
W, H = 1080, 1920
LAYOUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream", "static", "layout-portrait.json")
KEY_FILE = os.path.expanduser("~/.config/pog/youtube-vertical.key")


def send(c, req, data=None):
    return c.send(req, data or {}, raw=True) or {}


def vendor(c, req, data=None):
    r = send(c, "CallVendorRequest", {"vendorName": VENDOR, "requestType": req,
                                      "requestData": dict({"width": W, "height": H}, **(data or {}))})
    return r.get("responseData", r)


def find_canvas(c):
    for cv in send(c, "GetCanvasList").get("canvases", []):
        if cv.get("canvasName") == CANVAS:
            return cv
    raise SystemExit(f"no canvas named {CANVAS!r}: is Aitum Vertical installed and its dock opened once? "
                     f"canvases: {[cv.get('canvasName') for cv in send(c, 'GetCanvasList').get('canvases', [])]}")


def check(c):
    v = send(c, "GetVersion")
    print("obs", v.get("obsVersion"), "websocket", v.get("obsWebSocketVersion"))
    vs = send(c, "GetVideoSettings")  # the main canvas; the plugin's canvas shares its frame rate
    print(f"main canvas: base {vs.get('baseWidth')}x{vs.get('baseHeight')}, output {vs.get('outputWidth')}x"
          f"{vs.get('outputHeight')}, {vs.get('fpsNumerator', 0) / max(1, vs.get('fpsDenominator', 1)):g} fps")
    for cv in send(c, "GetCanvasList").get("canvases", []):
        print("canvas", json.dumps(cv))
    print("plugin", vendor(c, "version"))
    print("plugin scenes", vendor(c, "get_scenes"))
    print("plugin current scene", vendor(c, "current_scene"))
    print("plugin outputs", vendor(c, "status"))


def scene_items(c, scene_uuid):
    return {i["sourceName"]: i["sceneItemId"] for i in send(c, "GetSceneItemList", {"sceneUuid": scene_uuid})["sceneItems"]}


def place(c, scene_uuid, item, x, y, w, h):
    send(c, "SetSceneItemTransform", {"sceneUuid": scene_uuid, "sceneItemId": item, "sceneItemTransform": {
        "positionX": x, "positionY": y, "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsWidth": w, "boundsHeight": h,
        "boundsAlignment": 0, "alignment": 5}})


def ensure(c, scene_uuid, name, kind, settings):
    """Global input `name` in this scene: created here if new, else updated (settings given) and added if missing."""
    inputs = {i["inputName"] for i in send(c, "GetInputList")["inputs"]}
    if name not in inputs:
        if kind is None:
            raise SystemExit(f"input {name!r} is missing: run tools/obs.py stream-scene first")
        return send(c, "CreateInput", {"sceneUuid": scene_uuid, "inputName": name, "inputKind": kind,
                                       "inputSettings": settings, "sceneItemEnabled": True})["sceneItemId"]
    if settings:
        send(c, "SetInputSettings", {"inputName": name, "inputSettings": settings, "overlay": True})
    items = scene_items(c, scene_uuid)
    if name in items:
        return items[name]
    return send(c, "CreateSceneItem", {"sceneUuid": scene_uuid, "sourceName": name, "sceneItemEnabled": True})["sceneItemId"]


def build_scene(c, url):
    cv = find_canvas(c)
    scenes = {s["sceneName"]: s["sceneUuid"] for s in
              send(c, "GetSceneList", {"canvasUuid": cv["canvasUuid"]}).get("scenes", [])}
    uuid = scenes.get(SCENE) or send(c, "CreateScene", {"canvasUuid": cv["canvasUuid"], "sceneName": SCENE})["sceneUuid"]
    cams = json.load(open(LAYOUT))["cams"]
    order = []
    bg = ensure(c, uuid, "vertical background", "color_source_v3", {"color": 0xFF181210, "width": W, "height": H})
    place(c, uuid, bg, 0, 0, W, H)
    order.append(bg)
    for i, slot in enumerate(("main", "cam2", "cam3"), 1):
        item = ensure(c, uuid, f"stream cam{i}", None, None)  # the landscape scene's captures, shared
        place(c, uuid, item, *cams[slot])
        order.append(item)
    ov = ensure(c, uuid, "vertical overlay", "browser_source", {
        "url": url, "width": W, "height": H, "fps": 30, "fps_custom": True, "css": "",
        "shutdown": False, "restart_when_active": False, "reroute_audio": True})
    send(c, "SetSceneItemTransform", {"sceneUuid": uuid, "sceneItemId": ov, "sceneItemTransform": {
        "positionX": 0, "positionY": 0, "alignment": 5, "boundsType": "OBS_BOUNDS_NONE", "scaleX": 1.0, "scaleY": 1.0}})
    send(c, "SetInputMute", {"inputName": "vertical overlay", "inputMuted": True})
    order.append(ov)
    for idx, item in enumerate(order):
        send(c, "SetSceneItemIndex", {"sceneUuid": uuid, "sceneItemId": item, "sceneItemIndex": idx})
    vendor(c, "switch_scene", {"scene": SCENE})
    return uuid


def set_key(c, server, key_file=KEY_FILE):
    key = open(key_file).read().strip()
    vendor(c, "update_stream_server", {"stream_server": server, "index": 0})
    vendor(c, "update_stream_key", {"stream_key": key, "index": 0})
    return server


# ---- the plugin's output settings (config.json on the box, edited with OBS closed) ----------------------------------
# Aitum Vertical 1.6.6 reads %APPDATA%\obs-studio\plugin_config\vertical-canvas\config.json once at load
# ({"canvas": [one object per canvas]}) and writes it back only when OBS exits (save_canvas on
# OBS_FRONTEND_EVENT_EXIT), so an edit made while OBS runs is overwritten. Facts from vertical-canvas.cpp at 1.6.6:
#   - stream_advanced_settings true ("Use main OBS settings" unticked): the encoder is stream_encoder with
#     stream_encoder_settings passed as they are (bitrate, rate_control, keyint_sec live in there);
#     stream_audio_track N uses mixer N-1. streaming_video_bitrate is used only with main settings, set it anyway so
#     the dialog shows the same number.
#   - stream_outputs: [{name, stream_server, stream_key, enabled}]; rtmp_custom service. The vendor requests
#     update_stream_key/update_stream_server change an existing entry only (an index past the end does nothing and
#     still answers success) and never enable it.
#   - streaming_match_main: MainStreamStart() calls StartStream(); with no enabled output StartStream() opens a
#     QMessageBox ("No output server") on the box. So it is only turned on together with an enabled output that has
#     a key.
CONFIG_ON_BOX = "C:/Users/player/AppData/Roaming/obs-studio/plugin_config/vertical-canvas/config.json"
QSV_H264 = "obs_qsv11_v2"   # OBS's Quick Sync H.264 (texture) encoder id, as the landscape stream


def apply_settings(cfg, bitrate=6000, encoder=QSV_H264, keyint=2, track=1, server=None, key=None, match_main=True,
                   width=W, height=H):
    """Edit the plugin's config dict in place -> list of lines saying what was set."""
    canvases = cfg.get("canvas") or []
    mine = [c for c in canvases if (c.get("width"), c.get("height")) == (width, height)]
    if not mine and len(canvases) == 1:
        mine = canvases
    if len(mine) != 1:
        raise SystemExit(f"expected one {width}x{height} canvas in the plugin's config, found "
                         f"{[(c.get('width'), c.get('height')) for c in canvases]}")
    c = mine[0]
    c["stream_advanced_settings"] = True
    c["stream_encoder"] = encoder
    es = dict(c.get("stream_encoder_settings") or {})
    es.update(rate_control="CBR", bitrate=bitrate, max_bitrate=bitrate, keyint_sec=keyint)
    c["stream_encoder_settings"] = es
    c["streaming_video_bitrate"] = bitrate
    c["stream_audio_track"] = track
    outs = c.get("stream_outputs") or []
    if not outs:  # seeded from the legacy single output if an older config had one
        outs = [{"name": "YouTube vertical", "stream_server": c.get("stream_server") or "",
                 "stream_key": c.get("stream_key") or "", "enabled": False}]
    o = outs[0]
    if server:
        o["stream_server"] = server
    if key is not None:
        o["stream_key"] = key
    o["enabled"] = bool(o.get("stream_server") and o.get("stream_key"))
    c["stream_outputs"] = outs
    c.pop("stream_server", None), c.pop("stream_key", None)  # the legacy single output, read only without outputs
    c["streaming_match_main"] = bool(match_main and o["enabled"])
    lines = [f"encoder {encoder}: CBR {bitrate} Kbps, keyframe every {keyint} s, audio track {track}",
             f"output '{o.get('name')}': {o.get('stream_server') or '(no server)'}, key "
             f"{'set (' + str(len(o['stream_key'])) + ' chars)' if o.get('stream_key') else 'not set'}, "
             f"{'enabled' if o['enabled'] else 'disabled'}"]
    if match_main and not o["enabled"]:
        lines.append("start/stop with main: OFF until the output has a server and a key (with no enabled output the "
                     "plugin opens a 'No output server' dialog whenever the main stream starts)")
    else:
        lines.append(f"start/stop with main: {'on' if c['streaming_match_main'] else 'off'}")
    return lines


def box(*args, host=None):
    import subprocess
    host = host or os.environ.get("POG_WIN_HOST", "pogwin")
    return subprocess.run([args[0], *([host] if args[0] == "ssh" else []), *args[1:]], capture_output=True, text=True)


def settings_on_box(a):
    """Copy the plugin's config.json from the box, apply_settings, keep a dated copy there, copy it back."""
    import tempfile, time
    host = os.environ.get("POG_WIN_HOST", "pogwin")
    r = box("ssh", 'tasklist /FI "IMAGENAME eq obs64.exe" /NH')
    if r.returncode or "obs64.exe" in r.stdout:
        raise SystemExit("OBS is running on the box (or tasklist failed): exit OBS first (File > Exit); the plugin "
                         f"rewrites its config.json when OBS exits. {r.stdout.strip()} {r.stderr.strip()}")
    tmp = tempfile.mkdtemp()
    local = os.path.join(tmp, "config.json")
    r = box("scp", "-q", f"{host}:{CONFIG_ON_BOX}", local)
    if r.returncode:
        raise SystemExit(f"could not copy {CONFIG_ON_BOX}: {r.stderr.strip()} (the plugin writes it when OBS exits "
                         "for the first time after the install)")
    raw = open(local, encoding="utf-8-sig").read()
    cfg = json.loads(raw)
    key = None
    if os.path.exists(a.key_file):
        key = open(a.key_file).read().strip() or None
    for line in apply_settings(cfg, a.bitrate, a.encoder, a.keyint, a.track, a.server, key, not a.no_match_main):
        print(line)
    if a.dry_run:
        print("dry run: nothing written")
        return
    stamp = time.strftime("%Y%m%d-%H%M%S")
    win = CONFIG_ON_BOX.replace("/", "\\")
    r = box("ssh", f'copy /Y "{win}" "{win}.pog-{stamp}"')
    if r.returncode:
        raise SystemExit(f"could not back up the config on the box: {r.stdout} {r.stderr}")
    with open(local, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=4)
    r = box("scp", "-q", local, f"{host}:{CONFIG_ON_BOX}")
    if r.returncode:
        raise SystemExit(f"copy back failed: {r.stderr.strip()}; check {CONFIG_ON_BOX} against its copy "
                         f"{CONFIG_ON_BOX}.pog-{stamp} before starting OBS")
    os.unlink(local)
    print(f"written; the previous config is {CONFIG_ON_BOX}.pog-{stamp}")


def shot(c, out):
    cv = find_canvas(c)
    img = send(c, "GetSourceScreenshot", {"sourceName": SCENE, "canvasUuid": cv["canvasUuid"], "imageFormat": "png",
                                          "imageWidth": 540, "imageHeight": 960})["imageData"]
    open(out, "wb").write(base64.b64decode(img.split(",", 1)[1]))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "scene", "settings", "key", "status", "start", "stop", "shot"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--url", default="http://127.0.0.1:8787/portrait", help="scene: the portrait page as the box sees it")
    ap.add_argument("--server", default="rtmps://a.rtmps.youtube.com:443/live2",
                    help="settings, key: YouTube's ingest (the landscape stream uses this RTMPS one, docs/SETUP.md)")
    ap.add_argument("--key-file", default=KEY_FILE, help="settings, key: the vertical stream key (on this Mac)")
    ap.add_argument("--bitrate", type=int, default=6000, help="settings: video Kbps, CBR")
    ap.add_argument("--encoder", default=QSV_H264, help="settings: OBS encoder id")
    ap.add_argument("--keyint", type=int, default=2, help="settings: seconds between keyframes (YouTube: 2)")
    ap.add_argument("--track", type=int, default=1, help="settings: audio mixer track (1-based)")
    ap.add_argument("--no-match-main", action="store_true", help="settings: do not start/stop with the main stream")
    ap.add_argument("--dry-run", action="store_true", help="settings: print what would be set, write nothing")
    ap.add_argument("--yes", action="store_true", help="start: the plugin has an enabled output (see `settings`)")
    a = ap.parse_args()
    if a.cmd == "settings":  # over ssh/scp with OBS closed; no websocket
        return settings_on_box(a)
    from obs import client
    c = client()
    if a.cmd == "check":
        check(c)
    elif a.cmd == "scene":
        print("scene", SCENE, build_scene(c, a.url))
    elif a.cmd == "key":
        print("vertical output 1 ->", set_key(c, a.server, a.key_file), "(key from", a.key_file + ")")
        print("note: this changes an output that already exists and does not enable it; on a fresh install "
              "the plugin has none and answers success anyway. Use `settings` with OBS closed instead.")
    elif a.cmd == "status":
        print(vendor(c, "status"))
    elif a.cmd == "start":
        if not a.yes:  # 1.6.6 opens a modal "No output server" dialog on the box when no output is enabled
            raise SystemExit("start: only after `settings` gave the plugin an enabled output (else a dialog opens on "
                             "the box); add --yes to go ahead. A run normally starts it with the main stream.")
        print(vendor(c, "start_streaming"))
    elif a.cmd == "stop":
        print(vendor(c, "stop_streaming"))
    elif a.cmd == "shot":
        print(shot(c, a.out or "vertical.png"))


if __name__ == "__main__":
    main()
