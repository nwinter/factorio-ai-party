#!/usr/bin/env python3
"""What the tour shows over the camera (tourlay.py, static/tourlay.js; d23 batch128 CK3). Offline:
python3 tools/stream/test_tourlay.py

1. Marks: arrow, circle, box, label checked (spots, text, times, colours, sizes); bad ones refused with why.
2. The store (POST /tour/overlay): entries by id, at most KEEP, each gone at its until; DELETE ends them.
3. Off the frame: a mark whose spot leaves the on-air frame while it shows (the view moving) is found.
4. HTTP: the routes and the snapshot's `tour` (serve.py), on an ephemeral port.
5. The page's geometry in node (tourlay_selftest.mjs): the camera path as camerapath.py, world to screen in the hole,
   marks' shapes, times and fades, the entry on now. Skipped without node.
"""
import json, os, shutil, subprocess, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tourlay  # noqa: E402
from tourlay import TourOverlay, check_mark, check_marks, mark_times, offscreen  # noqa: E402


def fails(fn, text):
    try:
        fn()
    except ValueError as x:
        assert text in str(x), (text, str(x))
        return
    raise AssertionError(f"accepted: {text}")


def marks():
    m = check_mark({"type": "arrow", "at": {"x": 1, "y": 2.345}, "text": "  the  pad ", "from": "ne", "to_s": -2})
    assert m == {"type": "arrow", "at": {"x": 1.0, "y": 2.35}, "text": "the pad", "to_s": -2.0, "color": "#ff9f1c",
                 "from": "ne", "length": 110}, m
    assert check_mark({"type": "arrow", "at": {"x": 0, "y": 0}, "from": {"x": -40, "y": 0}})["from"] == {"x": -40.0, "y": 0.0}
    assert check_mark({"type": "circle", "at": {"x": 0, "y": 0}, "color": "green"})["radius"] == 6
    assert check_mark({"type": "box", "at": {"x": 0, "y": 0}, "w": 30, "color": "#123456"})["h"] == 12
    assert check_mark({"type": "label", "at": {"x": 0, "y": 0}, "text": "x", "from_s": "end"})["from_s"] == "end"
    fails(lambda: check_mark({"type": "star", "at": {"x": 0, "y": 0}}), "mark 1: type must be one of arrow")
    fails(lambda: check_mark({"type": "label", "at": {"x": 0, "y": 0}}), "a label needs text")
    fails(lambda: check_mark({"type": "circle", "at": {"x": "a", "y": 0}}), "at x must be a finite number")
    fails(lambda: check_mark({"type": "circle", "at": {"x": 0, "y": 0}, "color": "pink"}), "color is orange")
    fails(lambda: check_mark({"type": "arrow", "at": {"x": 0, "y": 0}, "length": 5}), "length must be 30..400")
    fails(lambda: check_mark({"type": "circle", "at": {"x": 0, "y": 0}, "text": "x" * 61}), "at most 60")
    fails(lambda: check_marks([{"type": "circle", "at": {"x": 0, "y": 0}}] * 13), "at most 12")
    assert check_marks(None) == []
    assert mark_times({}, 20) == (0.0, 20) and mark_times({"from_s": 2, "to_s": -3}, 20) == (2, 17)
    assert mark_times({"from_s": "end"}, 20) == (20, 20)


def store():
    o = TourOverlay()
    view = {"surface": "nauvis", "position": {"x": 0, "y": 0}, "zoom": 0.5}
    body = lambda i, cut, until: {"id": i, "cut": cut, "until": until, "length": until - cut - 15, "view": view,
                                  "marks": [{"type": "circle", "at": {"x": 1, "y": 1}}]}
    assert o.post(body("a", 1004, 1030), 1000) == (200, {"id": "a", "marks": 1})
    assert o.post(body("b", 1030, 1060), 1026)[0] == 200
    assert [e["id"] for e in o.public(1027)] == ["a", "b"] and o.public(1027)[0]["length"] == 11
    o.post(body("b", 1031, 1061), 1027)  # the same id again replaces it
    assert [e["id"] for e in o.public(1028)] == ["a", "b"] and o.public(1028)[1]["cut"] == 1031
    for i in "cde":
        o.post(body(i, 1040, 1070), 1035)
    assert [e["id"] for e in o.public(1035)] == ["c", "d", "e"], "at most KEEP"
    assert o.public(1071) is None, "each gone at its until"
    assert o.post({"id": "x"}, 1000)[0] == 400 and o.post(body("x", 2000, 2010), 1000)[0] == 400
    assert o.post(dict(body("x", 1000, 1030), marks=[{"type": "nope"}]), 1000)[1]["error"].startswith("mark 1:")
    assert o.post(dict(body("x", 1000, 1030), view=dict(view, move={"segments": []})), 1000)[0] == 400
    # (CK4) captions: kept with their moment and place; bad ones refused
    subs = [{"t0": 0, "t1": 2.5, "text": " Where  it began. "}, {"t0": 2.5, "t1": 4, "text": "Shift one."}]
    code, r = o.post(dict(body("s", 1000, 1030), subs=subs, subs_at=1000.8), 1000)
    e = o.public(1000)[-1]
    assert code == 200 and e["subs"][0] == {"t0": 0.0, "t1": 2.5, "text": "Where it began."} and e["subs_at"] == 1000.8
    assert e["subs_pos"] == "bottom"
    assert o.post(dict(body("s", 1000, 1030), subs=subs, subs_at=1000.8, subs_pos="side"), 1000)[0] == 400
    assert o.post(dict(body("s", 1000, 1030), subs=subs, subs_at=2000), 1000)[0] == 400
    assert o.post(dict(body("s", 1000, 1030), subs=[{"t0": 0, "t1": 1}], subs_at=1000.8), 1000)[0] == 400
    # (CK5) an old clip
    clip = {"url": "https://lib/clips/s1.mp4", "start_s": 2, "play": 20, "caption": "from shift 1", "title": "Opus died"}
    assert o.post(dict(body("v", 1000, 1030), clip=clip), 1000)[0] == 200 and o.public(1000)[-1]["clip"]["play"] == 20
    assert o.post(dict(body("v", 1000, 1030), clip=dict(clip, url="file:///x.mp4")), 1000)[0] == 400
    assert o.post(dict(body("v", 1000, 1030), clip=dict(clip, play=0)), 1000)[0] == 400
    o.post(body("x", 1000, 1030), 1000)
    assert o.clear() == (200, {"tour": None}) and o.public(1001) is None


def off_frame():
    frac = 0.658
    view = {"position": {"x": 0, "y": 0}, "zoom": 1.0}  # ~ +-17.7 x +-14.9 tiles on air
    m = check_marks([{"type": "circle", "at": {"x": 10, "y": 5}}, {"type": "label", "at": {"x": 40, "y": 0}, "text": "x"}])
    assert offscreen(view, m, 20, frac) == [(1, 0.0)]
    moving = dict(view, move={"segments": [{"pts": [{"x": 0, "y": 0, "zoom": 1}, {"x": 60, "y": 0, "zoom": 1}],
                                             "t0": 0, "t1": 20}]})
    assert offscreen(moving, m[:1], 20, frac) == [(0, 10.0)], offscreen(moving, m[:1], 20, frac)
    assert offscreen(moving, check_marks([{"type": "circle", "at": {"x": 10, "y": 5}, "to_s": 4}]), 20, frac) == []


def http():
    from http.server import ThreadingHTTPServer
    import serve
    hub = serve.Hub() if hasattr(serve, "Hub") else None
    if hub is None:
        print("  (serve.Hub not found: HTTP part skipped)")
        return
    o = TourOverlay()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(hub, lambda: [], tour=o))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        now = time.time()
        req = urllib.request.Request(base + "/tour/overlay", method="POST", headers={"Content-Type": "application/json"},
                                     data=json.dumps({"id": "a", "cut": now, "until": now + 30, "view": {"surface": "nauvis",
                                                      "position": {"x": 0, "y": 0}, "zoom": 1}, "marks": []}).encode())
        with urllib.request.urlopen(req, timeout=5) as r:
            assert json.load(r)["id"] == "a"
        assert o.public(now + 1)[0]["id"] == "a"
        req = urllib.request.Request(base + "/tour/overlay", method="DELETE")
        with urllib.request.urlopen(req, timeout=5) as r:
            assert json.load(r) == {"tour": None}
        assert o.public(now + 1) is None
    finally:
        srv.shutdown()


def page():
    node = shutil.which("node")
    if not node:
        print("  (no node: the page's geometry skipped)")
        return
    r = subprocess.run([node, os.path.join(HERE, "tourlay_selftest.mjs")], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr


if __name__ == "__main__":
    for f in (marks, store, off_frame, http, page):
        f()
        print("ok", f.__name__)
    print("test_tourlay: all ok")
