#!/usr/bin/env python3
"""The portrait (vertical) page with one camera on air: python3 tools/stream/test_portrait_onecam.py

1. layout-portrait.json: one camera in the band the three had (y 112..995, full width), an inset, no side cameras;
   the page's markup has no panel that would fill an old side-camera hole.
2. Segment cards are a strip at the camera's bottom, never over the middle (a capped height, above the bar).
3. A page loaded before the service's files changed reloads itself: serve.py puts static_version (a hash of the page
   files' contents) in every snapshot and overlay.js reloads when it differs from the one it first saw (the vertical
   canvas kept the three-camera page after eng/onecam).
"""
import json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
sys.path.insert(0, HERE)
import serve  # noqa: E402


def layout():
    lay = json.load(open(os.path.join(STATIC, "layout-portrait.json")))
    assert lay["mode"] == "onecam" and set(lay["cams"]) == {"main", "inset"}, lay
    x, y, w, h = lay["cams"]["main"]
    assert (x, y, w, y + h) == (24, 112, 1032, 995), lay  # the band the three cameras had
    land = json.load(open(os.path.join(STATIC, "layout.json")))["cams"]["main"]
    assert abs(w / h - land[2] / land[3]) < 0.01  # the same crop as landscape: one capture serves both
    old = json.load(open(os.path.join(STATIC, "layout-portrait-3cam.json")))
    assert set(old["cams"]) == {"main", "cam2", "cam3"}


def cards():
    css = open(os.path.join(STATIC, "overlay.css")).read()
    assert "body.portrait.onecam #segment.lower .spanel { margin-right: 0; max-height: 220px; overflow: hidden; }" in css
    js = open(os.path.join(STATIC, "overlay.js")).read()
    assert "const FULL = {};" in js  # no segment covers the camera
    assert 'if (!l.cams[c.dataset.slot]) c.remove();' in js  # no side-camera holes (and no desk fills in them)


def reload():
    d = tempfile.mkdtemp()
    try:
        for name in ("overlay.js", "overlay.css", "layout-portrait.json"):
            shutil.copy(os.path.join(STATIC, name), d)
        v1 = serve.static_version(d)
        assert v1 == serve.static_version(d) and len(v1) == 12
        os.utime(os.path.join(d, "overlay.js"))  # a touch (a checkout) is no change
        assert serve.static_version(d) == v1
        with open(os.path.join(d, "layout-portrait.json"), "a") as f:
            f.write(" ")
        assert serve.static_version(d) != v1
    finally:
        shutil.rmtree(d)
    js = open(os.path.join(STATIC, "overlay.js")).read()
    assert "if (staleCheck(s)) return;" in js and "location.reload();" in js
    src = open(os.path.join(HERE, "serve.py")).read()
    assert 'snap["static_version"] = page_version' in src


def main():
    layout()
    cards()
    reload()
    print("portrait onecam: ok (one camera in the old three's band, cards a bottom strip, stale pages reload)")


if __name__ == "__main__":
    main()
