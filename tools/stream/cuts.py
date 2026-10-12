"""Cuts between the camera clients in OBS for the one-camera layout (onecam.py; docs/STREAM-NOTES.md "One camera").

All three captures ("stream cam1..3", factorio-cam1..3.exe, OBS order = the director's slots main, cam2, cam3) sit in
the on-air hole (layout.json `main`, the whole left column), cropped to its shape. A cut brings the client on air to
the front of the other two; the inset, while there is one, is moved to layout.json `inset` (uncropped) and put on top.
Only z-order and the inset's transform change: every capture keeps running, so a cut is instant. Nothing else in the
scene moves (background below, the overlay above). The vertical scene ("stream vertical" in Aitum Vertical's canvas,
tools/vertical.py) shares the captures and is restacked the same way in layout-portrait.json's holes.

Trio (onecam.py, program "layout": "trio"): the three captures move to layout-3cam.json's holes, the client on air in
the big one ("tiles": hole -> client); back to the on-air hole when it ends. Transforms only, over the websocket, so
the switch is live (no scene rebuild). The vertical scene stays one camera: the client on air (the big tile) in front.
"""
import json, os, threading, time, traceback

from obsws import OBSError

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = os.path.join(HERE, "static", "layout.json")
TRIO = os.path.join(HERE, "static", "layout-3cam.json")
SOURCES = ("stream cam1", "stream cam2", "stream cam3")
SLOTS = ("main", "cam2", "cam3")


def crop_for(src_w, src_h, rect_w, rect_h):
    """The centre crop that gives a src_w x src_h capture the rect's shape (nothing when it already has it)."""
    out = {"cropLeft": 0, "cropRight": 0, "cropTop": 0, "cropBottom": 0}
    if not (src_w and src_h and rect_w and rect_h):
        return out
    want = rect_w / rect_h
    if abs(src_w / src_h - want) < 0.01 * want:  # a 16:9 hole that is a pixel off: scale, no crop
        return out
    if src_w / src_h > want:  # too wide: crop the sides
        cut = int(round((src_w - src_h * want) / 2))
        out.update(cropLeft=cut, cropRight=cut)
    else:  # too tall: crop top and bottom
        cut = int(round((src_h - src_w / want) / 2))
        out.update(cropTop=cut, cropBottom=cut)
    return out


def view_frac(layout, client=(1920, 1080)):
    """Share of a client's width the on-air hole shows after the crop (the director's fight zoom scales by it)."""
    _, _, w, h = layout["cams"]["main"]
    return round(min(1.0, (w / h) / (client[0] / client[1])), 3)


def order(items, cams, top_first):
    """items: [(item id, index)] of the whole scene; cams: the camera item ids; top_first: cams from the front back.
    -> the scene's ids bottom to top with the cameras restacked in the slots they already occupy."""
    ids = [i for i, _ in sorted(items, key=lambda x: x[1])]
    slots = sorted(ids.index(c) for c in cams)
    out = list(ids)
    for pos, cid in zip(slots, reversed(top_first)):
        out[pos] = cid
    return out


VERTICAL = {"canvas": "Aitum Vertical", "scene": "stream vertical",  # tools/vertical.py
            "layout": os.path.join(HERE, "static", "layout-portrait.json")}


class Cuts:
    def __init__(self, obs, layout=None, scene="stream", sources=SOURCES, slots=SLOTS, log=print, start=True,
                 vertical=VERTICAL, trio=None):
        """vertical: the 9:16 scene in Aitum Vertical's canvas, restacked the same way when it exists (None: off).
        trio: the holes of the three-tile layout (default layout-3cam.json's cams)."""
        self.obs = obs
        self.targets = [{"name": scene, "ref": {"sceneName": scene}, "layout": layout or json.load(open(LAYOUT)),
                         "trio": trio or json.load(open(TRIO))["cams"], "placed": {}}]
        self.vertical = vertical
        self.vertical_checked = False
        self.by_slot = dict(zip(slots, sources))
        self.log = log
        self.want = None
        self.applied = None
        self.status = {"connected": False, "error": None, "onair": None, "inset": None, "t": None, "vertical": None}
        self.lock = threading.Lock()
        if start:
            threading.Thread(target=self.run, daemon=True).start()

    def set(self, program):
        with self.lock:
            self.want = dict(program)

    def run(self):
        while True:
            try:
                self.work()
            except (OSError, OBSError) as e:
                self.status.update(connected=False, error=str(e)[:200])
                for t in self.targets:
                    t["placed"] = {}
                self.applied = None
                time.sleep(5)
            except Exception as e:
                self.status["error"] = f"{type(e).__name__}: {e}"[:200]
                traceback.print_exc()
                time.sleep(2)
            time.sleep(0.1)

    def find_vertical(self):
        """The vertical scene's uuid (another canvas: scene requests need its uuid), once; None without the plugin."""
        self.vertical_checked = True
        v = self.vertical
        try:
            cv = next((c for c in self.obs.call("GetCanvasList").get("canvases") or []
                       if c.get("canvasName") == v["canvas"]), None)
            if not cv:
                return
            scenes = self.obs.call("GetSceneList", {"canvasUuid": cv["canvasUuid"]}).get("scenes") or []
            uuid = next((s["sceneUuid"] for s in scenes if s.get("sceneName") == v["scene"]), None)
        except OBSError as e:  # an OBS without canvases (obs-websocket before 5.7)
            self.status["vertical"] = f"off ({e})"[:120]
            return
        if uuid:
            self.targets.append({"name": v["scene"], "ref": {"sceneUuid": uuid}, "layout": json.load(open(v["layout"])),
                                 "placed": {}})
        self.status["vertical"] = "on" if uuid else "no scene " + v["scene"]

    def work(self):
        with self.lock:
            want = self.want
        if not want or want == self.applied:
            return
        if self.vertical and not self.vertical_checked:
            self.find_vertical()
        for t in self.targets:
            self.apply(t, want)
        self.applied = want
        self.status.update(connected=True, error=None, onair=want.get("onair"), inset=want.get("inset"), t=time.time(),
                           layout=want.get("layout") or "onecam")
        onair, inset = self.by_slot.get(want.get("onair")), self.by_slot.get(want.get("inset") or "")
        self.log(f"[cuts] on air {onair}" + (f", inset {inset}" if inset else "") +
                 (" (trio)" if want.get("layout") == "trio" else ""))

    def apply(self, target, want):
        o, ref = self.obs, target["ref"]
        items = o.call("GetSceneItemList", ref)["sceneItems"]
        ids = {it["sourceName"]: it["sceneItemId"] for it in items}
        cams = {src: ids[src] for src in self.by_slot.values() if src in ids}
        if not cams:
            raise OBSError(f"no camera captures in scene {target['name']!r}")
        onair = self.by_slot.get(want.get("onair"))
        inset = self.by_slot.get(want.get("inset")) if want.get("inset") else None
        hole = {}  # capture -> its trio hole, when this scene shows the trio
        if want.get("layout") == "trio" and target.get("trio") and want.get("tiles"):
            hole = {self.by_slot.get(s): h for h, s in want["tiles"].items()}
        for src, iid in cams.items():  # the hole each capture belongs in: on air and standby share the main one
            role = "trio:" + hole[src] if src in hole else "inset" if src == inset else "main"
            if target["placed"].get(src) != role:
                self.place(target, iid, role)
                target["placed"][src] = role
        front = [s for s in (inset, onair) if s in cams] + [s for s in self.by_slot.values() if s in cams and s not in (inset, onair)]
        final = order([(it["sceneItemId"], it["sceneItemIndex"]) for it in items], list(cams.values()),
                      [cams[s] for s in front])
        cur = [i for i, _ in sorted(((it["sceneItemId"], it["sceneItemIndex"]) for it in items), key=lambda x: x[1])]
        for idx, iid in enumerate(final):  # bottom up: each move leaves the positions below it as they are
            if cur[idx] != iid:
                o.call("SetSceneItemIndex", dict(ref, sceneItemId=iid, sceneItemIndex=idx))
                cur.remove(iid)
                cur.insert(idx, iid)

    def place(self, target, iid, role):
        o, ref = self.obs, target["ref"]
        x, y, w, h = target["trio"][role[5:]] if role.startswith("trio:") else target["layout"]["cams"][role]
        t = o.call("GetSceneItemTransform", dict(ref, sceneItemId=iid))["sceneItemTransform"]
        crop = crop_for(t.get("sourceWidth"), t.get("sourceHeight"), w, h)
        o.call("SetSceneItemTransform", dict(ref, sceneItemId=iid, sceneItemTransform=dict(
            crop, positionX=float(x), positionY=float(y), boundsType="OBS_BOUNDS_SCALE_INNER", boundsWidth=float(w),
            boundsHeight=float(h), boundsAlignment=0, alignment=5)))

    def public(self):
        return dict(self.status)
