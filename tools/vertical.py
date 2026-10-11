#!/usr/bin/env python3
"""The vertical (9:16) stream: a designed portrait scene in Aitum Vertical's canvas (docs/VERTICAL-PROPOSAL.md).

Needs the Aitum Vertical plugin (1.6.x, OBS 31.1+) on the box and obs-websocket 5.7+ (canvasUuid on scene requests).
Through the same SSH tunnel as tools/obs.py (127.0.0.1:4455):

  tools/.venv/bin/python tools/vertical.py check                  # read-only: versions, canvases, the plugin's scenes
  tools/.venv/bin/python tools/vertical.py scene [--url http://127.0.0.1:8787/portrait]
  tools/.venv/bin/python tools/vertical.py key [--server URL]     # key: ~/.config/pog/youtube-vertical.key
  tools/.venv/bin/python tools/vertical.py status|start|stop
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


def shot(c, out):
    cv = find_canvas(c)
    img = send(c, "GetSourceScreenshot", {"sourceName": SCENE, "canvasUuid": cv["canvasUuid"], "imageFormat": "png",
                                          "imageWidth": 540, "imageHeight": 960})["imageData"]
    open(out, "wb").write(base64.b64decode(img.split(",", 1)[1]))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "scene", "key", "status", "start", "stop", "shot"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--url", default="http://127.0.0.1:8787/portrait", help="scene: the portrait page as the box sees it")
    ap.add_argument("--server", default="rtmps://a.rtmps.youtube.com:443/live2",
                    help="key: YouTube's ingest (the landscape stream uses this RTMPS one, docs/SETUP.md)")
    a = ap.parse_args()
    from obs import client
    c = client()
    if a.cmd == "check":
        check(c)
    elif a.cmd == "scene":
        print("scene", SCENE, build_scene(c, a.url))
    elif a.cmd == "key":
        print("vertical output ->", set_key(c, a.server), "(key from", KEY_FILE + ")")
    elif a.cmd == "status":
        print(vendor(c, "status"))
    elif a.cmd == "start":
        print(vendor(c, "start_streaming"))
    elif a.cmd == "stop":
        print(vendor(c, "stop_streaming"))
    elif a.cmd == "shot":
        print(shot(c, a.out or "vertical.png"))


if __name__ == "__main__":
    main()
