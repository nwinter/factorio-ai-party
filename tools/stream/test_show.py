#!/usr/bin/env python3
"""An image on air (show.py; Sol 15:30 on d16 for viewer LimeLight): POST /show puts a PNG from runs/ over the main
camera with a caption and removes it after. Offline, no OBS and no box: python3 tools/stream/test_show.py

1. Checks: under runs/ only (no ../ or symlink out), a PNG by its header, at most 10 MB and 32..4096 px a side,
   seconds 1..60; 400 with why.
2. On air: copied to the box under a content name, backdrop and image in scene "stream" bounded to the main hole,
   just below "stream overlay" (above every camera, also after a cut restacks them); one at a time (409).
3. The time counts only while "stream" is on program: a replay in the middle pauses it; an image that left the
   scene is put back; then both sources go and the copy is deleted. DELETE /show ends it early.
4. A leftover from a restart is removed; a failed copy or OBS call is 502 and frees the slot.
5. HTTP, snapshot, the hosts' facts and the overlay's caption (node; skipped without it).
"""
import json, os, shutil, struct, subprocess, sys, tempfile, threading, urllib.error, urllib.request, zlib
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import show as show_mod  # noqa: E402
from show import Show, IMAGE, BACKDROP, png_size  # noqa: E402
from obsws import OBSError  # noqa: E402
from cuts import order  # noqa: E402

LAYOUT = {"canvas": [1920, 1080], "cams": {"main": [24, 24, 1208, 1032], "inset": [808, 40, 408, 230]}}


def png(path, w=64, h=48):
    raw = b"".join(b"\x00" + b"\x80\x40\x20" * w for _ in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    return path


class FakeOBS:
    """Scene "stream" as on the box (2026-10-16 16:20): background, cam3, cam1, cam2, overlay, game audio."""
    def __init__(self):
        self.inputs = {"stream background": "color_source_v3", "stream cam1": "game_capture",
                       "stream cam2": "game_capture", "stream cam3": "game_capture", "stream overlay": "browser_source",
                       "stream game audio": "wasapi_process_output_capture"}
        self.settings = {}
        self.items = [[1, "stream background"], [4, "stream cam3"], [2, "stream cam1"], [3, "stream cam2"],
                      [5, "stream overlay"], [6, "stream game audio"]]  # bottom to top: [id, source]
        self.transforms, self.program, self.calls, self.next_id, self.fail = {}, "stream", [], 7, None
        self.removed = []

    def call(self, req, data=None):
        data = data or {}
        self.calls.append((req, data))
        if self.fail and req == self.fail:
            raise OBSError(f"{req} failed")
        if req == "GetInputList":
            return {"inputs": [{"inputName": n, "inputKind": k} for n, k in self.inputs.items()]}
        if req == "GetSceneItemList":
            return {"sceneItems": [{"sceneItemId": i, "sourceName": n, "sceneItemIndex": k, "inputKind": self.inputs[n]}
                                   for k, (i, n) in enumerate(self.items)]}
        if req == "GetSceneItemId":
            for i, n in self.items:
                if n == data["sourceName"]:
                    return {"sceneItemId": i}
            raise OBSError("No scene items were found in the specified scene by that name or offset.")
        if req == "CreateInput":
            assert data["inputName"] not in self.inputs
            self.inputs[data["inputName"]] = data["inputKind"]
            self.settings[data["inputName"]] = data["inputSettings"]
            return self.call("CreateSceneItem", {"sceneName": data["sceneName"], "sourceName": data["inputName"]})
        if req == "CreateSceneItem":
            self.items.append([self.next_id, data["sourceName"]])
            self.next_id += 1
            return {"sceneItemId": self.next_id - 1}
        if req == "SetInputSettings":
            self.settings[data["inputName"]] = data["inputSettings"]
            return {}
        if req == "SetSceneItemTransform":
            self.transforms[data["sceneItemId"]] = data["sceneItemTransform"]
            return {}
        if req == "SetSceneItemIndex":
            it = next(x for x in self.items if x[0] == data["sceneItemId"])
            self.items.remove(it)
            self.items.insert(data["sceneItemIndex"], it)
            return {}
        if req == "RemoveInput":
            self.removed.append(data["inputName"])
            if data["inputName"] not in self.inputs:
                raise OBSError("No source was found by the name of `x`.")
            del self.inputs[data["inputName"]]
            self.items = [x for x in self.items if x[1] != data["inputName"]]
            return {}
        if req == "GetCurrentProgramScene":
            return {"sceneName": self.program}
        if req == "SetSceneItemEnabled":
            return {}
        raise AssertionError(req)

    def names(self):
        """The scene bottom to top, this show's inputs without their tag."""
        return [n.rsplit(" ", 1)[0] if n.startswith(IMAGE + " ") and n[-6:].isalnum() and len(n.rsplit(" ", 1)[1]) == 6
                else n for _, n in self.items]

    def mine(self, base):
        return [n for n in self.inputs if n.startswith(base + " ") and len(n) == len(base) + 7]

    def restack(self, top_first):
        """What cuts.py does on a cut: the cameras restacked among their own places."""
        items = [(i, k) for k, (i, n) in enumerate(self.items)]
        ids = {n: i for i, n in self.items}
        final = order(items, [ids[c] for c in ("stream cam1", "stream cam2", "stream cam3")], [ids[c] for c in top_first])
        by_id = {i: n for i, n in self.items}
        self.items = [[i, by_id[i]] for i in final]


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def make(tmp, obs=None, **kw):
    runs = os.path.join(tmp, "runs")
    os.makedirs(os.path.join(runs, "shift24", "sol", "tools"), exist_ok=True)
    copied, deleted = [], []
    obs = obs or FakeOBS()
    sh = Show(obs, LAYOUT, runs=runs, copy=lambda local, name: copied.append((local, name)),
              delete=deleted.append, log=lambda m: None, start=False, **kw)
    return sh, obs, runs, copied, deleted


def checks():
    with tempfile.TemporaryDirectory() as tmp:
        sh, obs, runs, copied, _ = make(tmp)
        good = png(os.path.join(runs, "shift24", "sol", "tools", "aethera.png"), 1600, 1200)
        assert png_size(good) == (1600, 1200)
        outside = png(os.path.join(tmp, "outside.png"))
        os.symlink(outside, os.path.join(runs, "link.png"))
        open(os.path.join(runs, "fake.png"), "wb").write(b"GIF89a" + b"\0" * 40)
        png(os.path.join(runs, "tiny.png"), 8, 8)
        png(os.path.join(runs, "huge.png"), 5000, 40)
        with open(os.path.join(runs, "big.png"), "wb") as f:
            f.write(open(good, "rb").read() + b"\0" * (show_mod.MAX_BYTES + 1))
        for body, why in (({"file": outside}, "not under runs/"), ({"file": os.path.join(runs, "link.png")}, "not under runs/"),
                          ({"file": os.path.join(runs, "..", "outside.png")}, "not under runs/"),
                          ({"file": os.path.join(runs, "missing.png")}, "no file"), ({}, "file missing"),
                          ({"file": os.path.join(runs, "fake.png")}, "not a PNG"),
                          ({"file": os.path.join(runs, "tiny.png")}, "8 x 8 px"),
                          ({"file": os.path.join(runs, "huge.png")}, "5000 x 40 px"),
                          ({"file": os.path.join(runs, "big.png")}, "at most"),
                          ({"file": good, "seconds": "soon"}, "finite"), ({"file": good, "seconds": float("nan")}, "finite"),
                          (None, "expected an object")):
            code, r = sh.request(body)
            assert code == 400 and why in r["error"], (body, r)
        assert not copied and sh.cur is None
        code, r = sh.request({"file": good, "seconds": 600})
        assert code == 200 and r["seconds"] == 60 and r["label"] == "aethera" and r["size"] == [1600, 1200], r
        # a path relative to the repo: runs/... under show.ROOT
        assert sh.resolve("runs/x.png")[1] in ("no file runs/x.png", "runs/x.png is not under runs/")


def on_air():
    with tempfile.TemporaryDirectory() as tmp:
        sh, obs, runs, copied, deleted = make(tmp)
        f = png(os.path.join(runs, "shift24", "sol", "tools", "aethera.png"), 1600, 1200)
        sh.step()  # the first tick: no leftovers to remove
        code, r = sh.request({"file": f, "seconds": 3, "label": "Aethera design (Sol, for LimeLight)", "by": "op"})
        assert code == 200 and r["state"] == "on" and r["remaining_s"] == 3, r
        name = copied[-1][1]
        assert copied[-1][0] == os.path.realpath(f) and name.startswith("show-") and name.endswith(".png")
        tag = sh.cur["tag"]
        assert obs.settings[f"{IMAGE} {tag}"] == {"file": f"D:/pog/overlay/{name}", "unload": False}
        assert obs.names() == ["stream background", "stream cam3", "stream cam1", "stream cam2", BACKDROP, IMAGE,
                               "stream overlay", "stream game audio"], obs.names()
        ids = {n: i for (i, _), n in zip(obs.items, obs.names())}
        for src in (IMAGE, BACKDROP):
            t = obs.transforms[ids[src]]
            assert (t["positionX"], t["positionY"], t["boundsWidth"], t["boundsHeight"]) == (24, 24, 1208, 1032), t
            assert t["boundsType"] == "OBS_BOUNDS_SCALE_INNER" and t["alignment"] == 5
        assert obs.settings[f"{BACKDROP} {tag}"]["width"] == 1208
        # a cut restacks the cameras: the image stays above every one of them
        obs.restack(["stream cam3", "stream cam1", "stream cam2"])
        n = obs.names()
        assert max(n.index(c) for c in ("stream cam1", "stream cam2", "stream cam3")) < n.index(BACKDROP) < n.index(IMAGE)
        # one at a time
        code, r = sh.request({"file": f})
        assert code == 409 and "one at a time" in r["error"] and "Aethera" in r["error"], r
        assert sh.public()["label"] == "Aethera design (Sol, for LimeLight)" and sh.public()["by"] == "op"
        # the time counts on "stream" only: a replay in the middle pauses it
        clock = [0.0]
        show_mod.time.monotonic, real = (lambda: clock[0]), show_mod.time.monotonic
        try:
            sh.cur["last"] = 0.0
            clock[0] = 1.0
            sh.step()
            assert sh.cur["shown_s"] == 1.0 and sh.public()["state"] == "on"
            obs.program = "replay"
            clock[0] = 20.0
            sh.step()
            assert sh.cur["shown_s"] == 1.0 and sh.public()["state"] == "paused" and sh.public()["remaining_s"] == 2
            # the image left the scene meanwhile (a scene rebuild): back on "stream" it is put back
            obs.call("RemoveInput", {"inputName": f"{IMAGE} {tag}"})
            obs.program = "stream"
            clock[0] = 21.0
            sh.step()
            assert IMAGE in obs.names() and obs.names().index(IMAGE) == obs.names().index("stream overlay") - 1
            assert sh.cur["tag"] != tag and f"{BACKDROP} {tag}" in obs.removed  # new inputs; the old backdrop goes
            assert sh.cur["shown_s"] == 2.0
            clock[0] = 22.5
            sh.step()
            assert sh.cur is None and not obs.mine(IMAGE) and not obs.mine(BACKDROP) and deleted == [name], obs.inputs
            assert sh.public() is None
            # DELETE /show ends one early
            assert sh.request({"file": f, "seconds": 60})[0] == 200
            assert sh.clear() == (200, {"show": None, "ending": True})
            clock[0] = 23.0
            sh.step()
            assert sh.cur is None and not obs.mine(IMAGE) and not obs.mine(BACKDROP)
            assert sh.clear() == (200, {"show": None, "ending": False})
        finally:
            show_mod.time.monotonic = real


def failures():
    with tempfile.TemporaryDirectory() as tmp:
        obs = FakeOBS()
        for n in (IMAGE, "pog show 1a2b3c", "pog show backdrop 1a2b3c"):  # leftovers from before a restart
            obs.inputs[n] = "image_source"
            obs.items.append([obs.next_id, n])
            obs.next_id += 1
        sh, obs, runs, copied, deleted = make(tmp, obs)
        sh.step()
        assert not [n for n in obs.inputs if n.startswith(IMAGE)] and IMAGE not in obs.names(), obs.inputs
        f = png(os.path.join(runs, "a.png"))

        def broken(local, name):
            raise OSError("scp to pogwin failed: Connection refused")
        sh.copy = broken
        code, r = sh.request({"file": f})
        assert code == 502 and "Connection refused" in r["error"] and sh.cur is None, r
        sh.copy = lambda local, name: None
        obs.fail = "SetSceneItemTransform"
        code, r = sh.request({"file": f})
        assert code == 502 and sh.cur is None and not obs.mine(IMAGE) and not obs.mine(BACKDROP), (r, obs.inputs)
        obs.fail = None
        assert sh.request({"file": f})[0] == 200
        # no overlay in the scene: the image stays on top
        obs2 = FakeOBS()
        obs2.items = [x for x in obs2.items if x[1] != "stream overlay"]
        os.makedirs(os.path.join(tmp, "b"))
        sh2, obs2, runs2, _, _ = make(os.path.join(tmp, "b"), obs2)
        assert sh2.request({"file": png(os.path.join(runs2, "b.png"))})[0] == 200
        assert obs2.names()[-1] == IMAGE, obs2.names()


def http_and_hosts():
    import caster
    from serve import Hub, make_handler
    with tempfile.TemporaryDirectory() as tmp:
        sh, obs, runs, _, _ = make(tmp)
        f = png(os.path.join(runs, "c.png"))
        srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: [], show=sh))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_address[1]}/show"

        def request(data=None, method="POST", u=url):
            req = urllib.request.Request(u, data=json.dumps(data).encode() if method == "POST" else None, method=method)
            try:
                with urllib.request.urlopen(req, timeout=5) as r:
                    return r.status, json.load(r)
            except urllib.error.HTTPError as e:
                return e.code, json.load(e)
        try:
            code, r = request({"file": f, "seconds": 45, "label": "Schematic", "by": "op"})
            assert code == 200 and r["seconds"] == 45 and r["label"] == "Schematic", r
            assert request({"file": f})[0] == 409
            assert request({"file": "/etc/hosts"})[0] == 400
            assert request(method="DELETE") == (200, {"show": None, "ending": True})
        finally:
            srv.shutdown()
            srv.server_close()
        srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: []))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            assert request({"file": f}, u=f"http://127.0.0.1:{srv.server_address[1]}/show")[0] == 409
        finally:
            srv.shutdown()
            srv.server_close()
        s = {"agents": [], "show": sh.public()}
        facts = caster.facts_for({"kind": "lull", "angle": "explain"}, s)["on_screen_image"]
        assert facts["shown_as"] == "Schematic" and facts["remaining_s"] == 45, facts


def overlay():
    if not shutil.which("node"):
        print("show overlay: skip (node unavailable)")
        return
    js = r'''
const fs = require('fs'), assert = require('assert');
const code = fs.readFileSync(process.argv[1], 'utf8');
const onecam = true, curMode = 'onecam';
const classes = {toggle() {}, add() {}, remove() {}};
const label = {dataset: {}, classList: classes, children: [],
  set textContent(t) {this.children = [t];}, append(...xs) {this.children.push(...xs);}};
const frame = {querySelector: () => label, classList: classes, style: {removeProperty() {}}};
const $ = id => id === 'cam-main' ? frame : null;
const renderCloud = () => null, el = (tag, cls, text) => text;
eval(code.slice(code.indexOf('  function renderCams(s)'), code.indexOf('  // Space Age panel')));
renderCams({agents: [{name: 'sol', display_name: 'Sol'}], cameras: {main: {agents: ['sol']}},
            show: {label: 'Aethera design (Sol, for LimeLight)', state: 'on'}});
assert(label.children.includes('🖼️') && label.children.includes('Aethera design (Sol, for LimeLight)'), label.children);
'''
    r = subprocess.run(["node", "-e", js, os.path.join(HERE, "static", "overlay.js")],
                       capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr


if __name__ == "__main__":
    checks()
    on_air()
    failures()
    http_and_hosts()
    overlay()
    print("show: ok (checks, on air below the overlay and above the cameras, replay pause, put back, end, leftovers, "
          "failures, HTTP, hosts, caption)")
