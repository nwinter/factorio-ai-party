"""An image on air (Sol 15:30 on d16, for viewer LimeLight: a schematic PNG of a viewer's blueprint; the operator did
it by hand at 15:31): POST /show {file, seconds?, label?, by?}, DELETE /show.

  curl -X POST http://127.0.0.1:8788/show -d '{"file": "runs/shift24/sol/tools/aethera-design24.png", "seconds": 45,
                                              "label": "Aethera design (Sol, for LimeLight)", "by": "operator"}'
  curl -X DELETE http://127.0.0.1:8788/show

file: a PNG under runs/ (a path relative to the repo, or absolute), at most MAX_BYTES and MAX_PX a side. It is copied
to the box (scp to D:/pog/overlay/show-<hash>.png), and shown in OBS scene "stream" over the main camera: an
image_source on a dark backdrop (inputs "pog show <tag>" and "pog show backdrop <tag>", new ones each time), both bounded to the on-air hole (layout.json `main`, the image letterboxed in it),
placed just below "stream overlay" so the overlay's caption ("🖼️ label") draws over it and every camera capture
stays below (cuts.py restacks the cameras only among their own places). seconds: 1..60 (default 30), counted only
while scene "stream" is on program, so a replay (scene "replay") in the middle does not eat the time; if the image
left the scene meanwhile it is put back. Then both sources are removed and the copy deleted. One at a time: a
second request while one is on air is 409 (DELETE /show ends it early). A leftover from a restart is removed at
start. Agents ask through `./fh operator` with the file path; the operator runs it.
"""
import hashlib, os, struct, subprocess, threading, time, traceback, uuid

from obsws import OBSError

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RUNS = os.path.join(ROOT, "runs")
MAX_S, DEFAULT_S = 60.0, 30.0
MAX_BYTES = 10 << 20
MIN_PX, MAX_PX = 32, 4096
# OBS removes an input a moment after RemoveInput (it is still listed right after: seen on the box's OBS 32.2.2), so
# each show gets inputs of its own, "pog show <tag>" and "pog show backdrop <tag>"; a cleanup removes every "pog show"
IMAGE, BACKDROP = "pog show", "pog show backdrop"
OVERLAY = "stream overlay"
BACKDROP_ABGR = 0xFF1A1714  # opaque, near the overlay's dark panels
BOX_DIR = "D:/pog/overlay"
BOX_DIR_WIN = BOX_DIR.replace("/", "\\")
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def png_size(path):
    """(width, height) from a PNG's IHDR, or None when the file is not a PNG."""
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != PNG_SIG or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def scp_copy(host="pogwin"):
    def copy(local, name):
        r = subprocess.run(["scp", "-q", local, f"{host}:{BOX_DIR}/{name}"], capture_output=True, text=True, timeout=60)
        if r.returncode:
            raise OSError(f"scp to {host} failed: {(r.stderr or r.stdout).strip()[:200]}")
    return copy


def ssh_delete(host="pogwin"):
    def delete(name):
        subprocess.run(["ssh", host, f'del "{BOX_DIR_WIN}\\{name}"'], capture_output=True, timeout=30)
    return delete


class Show:
    def __init__(self, obs, layout, runs=RUNS, scene="stream", copy=None, delete=None, log=print, start=True,
                 tick_s=0.5):
        """obs: an obsws.OBS; layout: layout.json (its cams.main hole); copy(local, name) puts the file in BOX_DIR on
        the box, delete(name) removes it there."""
        self.obs, self.scene, self.runs, self.log = obs, scene, os.path.realpath(runs), log
        self.hole = layout["cams"]["main"]
        self.copy = copy or scp_copy(os.environ.get("POG_WIN_HOST", "pogwin"))
        self.delete = delete or ssh_delete(os.environ.get("POG_WIN_HOST", "pogwin"))
        self.cur = None  # {file, name, label, by, seconds, shown_s, started, state: "on" | "paused"}
        self.end_now = False
        self.lock = threading.Lock()
        self.tick_s = tick_s
        self.status = {"error": None}
        self.cleaned = False
        if start:
            threading.Thread(target=self.run, daemon=True).start()

    # ---- request ----------------------------------------------------------------------------------------------
    def resolve(self, file):
        """-> (absolute path, None) or (None, why not)."""
        f = str(file or "").strip()
        if not f:
            return None, "file missing (a PNG under runs/)"
        full = os.path.realpath(f if os.path.isabs(f) else os.path.join(ROOT, f))
        if not full.startswith(self.runs + os.sep):
            return None, f"{f} is not under runs/"
        if not os.path.isfile(full):
            return None, f"no file {f}"
        return full, None

    def request(self, body, now=None):
        """POST /show -> (http code, reply)."""
        now = time.time() if now is None else now
        if not isinstance(body, dict):
            return 400, {"error": "expected an object with file and optional seconds, label, by"}
        full, why = self.resolve(body.get("file"))
        if why:
            return 400, {"error": why}
        size = os.path.getsize(full)
        if size > MAX_BYTES:
            return 400, {"error": f"{size} bytes: at most {MAX_BYTES} ({MAX_BYTES >> 20} MB)"}
        dims = png_size(full)
        if not dims:
            return 400, {"error": "not a PNG file (by its header)"}
        w, h = dims
        if not (MIN_PX <= w <= MAX_PX and MIN_PX <= h <= MAX_PX):
            return 400, {"error": f"{w} x {h} px: each side must be {MIN_PX}..{MAX_PX}"}
        try:
            secs = float(body["seconds"]) if body.get("seconds") is not None else DEFAULT_S
            if secs != secs or secs in (float("inf"), float("-inf")):
                raise ValueError()
        except (TypeError, ValueError):
            return 400, {"error": "seconds must be a finite number"}
        secs = max(1.0, min(MAX_S, secs))
        label = str(body.get("label") or "").strip()[:80] or os.path.splitext(os.path.basename(full))[0]
        by = str(body.get("by") or "operator")[:40]
        with self.lock:
            if self.cur:
                return 409, {"error": f"an image is on air ({self.cur['label']}, {self.remaining(self.cur)} s left); "
                                      "one at a time (DELETE /show ends it)"}
            self.cur = {"state": "starting"}  # holds the slot while the copy runs
        with open(full, "rb") as f:
            name = "show-" + hashlib.sha256(f.read()).hexdigest()[:12] + ".png"
        tag = uuid.uuid4().hex[:6]
        try:
            self.copy(full, name)
            self.put(name, tag)
        except Exception as e:
            with self.lock:
                self.cur = None
            self.remove(tag, name, quiet=True)
            self.log(f"[show] {by}: {os.path.relpath(full, ROOT)} failed: {type(e).__name__}: {e}")
            return 502, {"error": f"{type(e).__name__}: {e}"[:300]}
        cur = {"file": os.path.relpath(full, ROOT), "name": name, "tag": tag, "label": label, "by": by, "seconds": secs,
               "shown_s": 0.0, "started": now, "last": time.monotonic(), "state": "on", "size": [w, h]}
        with self.lock:
            self.cur = cur
            self.end_now = False
        self.log(f"[show] {by}: {cur['file']} ({w} x {h}) for {int(secs)} s: {label}")
        return 200, self.public_of(cur)

    def clear(self):
        """DELETE /show: ends the image on air at the next tick."""
        with self.lock:
            on = bool(self.cur and self.cur.get("name"))
            self.end_now = on
        return 200, {"show": None, "ending": on}

    # ---- OBS ---------------------------------------------------------------------------------------------------
    def put(self, name, tag):
        """The backdrop and image in the scene, bounded to the hole, just below the overlay (above every camera)."""
        o, ref = self.obs, {"sceneName": self.scene}
        x, y, w, h = self.hole
        inputs = {i["inputName"] for i in o.call("GetInputList")["inputs"]}
        for src, kind, settings in ((f"{BACKDROP} {tag}", "color_source_v3", {"color": BACKDROP_ABGR, "width": w, "height": h}),
                                    (f"{IMAGE} {tag}", "image_source", {"file": f"{BOX_DIR}/{name}", "unload": False})):
            if src in inputs:
                o.call("SetInputSettings", {"inputName": src, "inputSettings": settings})
                try:
                    iid = o.call("GetSceneItemId", dict(ref, sourceName=src))["sceneItemId"]
                except OBSError:
                    iid = o.call("CreateSceneItem", dict(ref, sourceName=src))["sceneItemId"]
            else:
                iid = o.call("CreateInput", dict(ref, inputName=src, inputKind=kind, inputSettings=settings,
                                                 sceneItemEnabled=True))["sceneItemId"]
            o.call("SetSceneItemTransform", dict(ref, sceneItemId=iid, sceneItemTransform={
                "positionX": float(x), "positionY": float(y), "alignment": 5, "boundsType": "OBS_BOUNDS_SCALE_INNER",
                "boundsWidth": float(w), "boundsHeight": float(h), "boundsAlignment": 0,
                "cropLeft": 0, "cropRight": 0, "cropTop": 0, "cropBottom": 0}))
            o.call("SetSceneItemEnabled", dict(ref, sceneItemId=iid, sceneItemEnabled=True))
            self.below_overlay(iid)

    def below_overlay(self, iid):
        """Move the item just below "stream overlay" (else the topmost browser source); without one it stays on top.
        OBS takes the index the item ends up at: from above the overlay that is the overlay's index (the overlay
        moves up one), from below it the one under the overlay's."""
        o, ref = self.obs, {"sceneName": self.scene}
        items = o.call("GetSceneItemList", ref)["sceneItems"]
        over = [it["sceneItemIndex"] for it in items if it.get("sourceName") == OVERLAY] or \
               [it["sceneItemIndex"] for it in items if it.get("inputKind") == "browser_source"]
        if not over:
            return
        k = max(over)
        mine = next(it["sceneItemIndex"] for it in items if it["sceneItemId"] == iid)
        want = k if mine > k else k - 1
        if mine != want:
            o.call("SetSceneItemIndex", dict(ref, sceneItemId=iid, sceneItemIndex=want))

    def in_scene(self, tag):
        try:
            self.obs.call("GetSceneItemId", {"sceneName": self.scene, "sourceName": f"{IMAGE} {tag}"})
            return True
        except OBSError:
            return False

    def remove(self, tag=None, name=None, quiet=False):
        """This show's two inputs (tag), or every "pog show" input (tag None: a cleanup), and the copy on the box."""
        srcs = [f"{IMAGE} {tag}", f"{BACKDROP} {tag}"] if tag else \
            [i["inputName"] for i in self.obs.call("GetInputList")["inputs"] if i["inputName"].startswith(IMAGE)]
        for src in srcs:
            try:
                self.obs.call("RemoveInput", {"inputName": src})
            except (OSError, OBSError) as e:
                if not quiet and "No source was found" not in str(e) and "not found" not in str(e).lower():
                    self.log(f"[show] remove {src}: {e}")
        if name:
            try:
                self.delete(name)
            except Exception:
                pass

    # ---- the countdown -------------------------------------------------------------------------------------------
    @staticmethod
    def remaining(cur):
        return max(0, int(round(cur.get("seconds", 0) - cur.get("shown_s", 0))))

    def step(self):
        """One tick: count the time while scene `stream` is on program; put the image back if it left the scene;
        remove it when its time is up or DELETE /show asked."""
        if not self.cleaned:  # a leftover from before a restart
            with self.lock:
                idle = self.cur is None
            if idle:
                self.remove(quiet=True)
            self.cleaned = True
        with self.lock:
            cur, end = self.cur, self.end_now
        if not cur or cur.get("state") == "starting":
            return
        t = time.monotonic()
        program = self.obs.call("GetCurrentProgramScene").get("sceneName")
        with self.lock:
            if program == self.scene:
                cur["shown_s"] += t - cur["last"]
                cur["state"] = "on"
            else:
                cur["state"] = "paused"  # a replay or another scene on program: the time waits
            cur["last"] = t
            done = end or cur["shown_s"] >= cur["seconds"]
        if done:
            self.remove(cur["tag"], cur["name"])
            with self.lock:
                self.cur, self.end_now = None, False
            self.log(f"[show] off: {cur['label']} (" + ("ended early" if end else f"{int(cur['seconds'])} s shown") + ")")
            return
        if program == self.scene and not self.in_scene(cur["tag"]):
            self.log("[show] the image left the scene: putting it back")
            self.remove(cur["tag"], quiet=True)
            cur["tag"] = uuid.uuid4().hex[:6]  # new inputs: the old ones may still be going away
            self.put(cur["name"], cur["tag"])

    def run(self):
        while True:
            try:
                self.step()
                self.status["error"] = None
            except (OSError, OBSError) as e:
                self.status["error"] = str(e)[:200]
                with self.lock:  # OBS away: no time counted meanwhile
                    if self.cur and self.cur.get("last"):
                        self.cur["last"] = time.monotonic()
                time.sleep(2)
            except Exception as e:
                self.status["error"] = f"{type(e).__name__}: {e}"[:200]
                traceback.print_exc()
                time.sleep(2)
            time.sleep(self.tick_s)

    def public_of(self, cur):
        return {"file": cur["file"], "label": cur["label"], "by": cur["by"], "seconds": int(cur["seconds"]),
                "remaining_s": self.remaining(cur), "state": cur["state"], "size": cur.get("size")}

    def public(self):
        """snapshot["show"]: the image on air {file, label, by, seconds, remaining_s, state, size}, or None."""
        with self.lock:
            cur = self.cur
            return self.public_of(cur) if cur and cur.get("name") else None
