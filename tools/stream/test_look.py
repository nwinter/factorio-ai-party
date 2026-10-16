#!/usr/bin/env python3
"""Operator position shot (lookcam.py; viewers LimeLight555 11:33 and 12:24 on d16): POST /look points the main camera at
a charted spot for N s, then the director returns. Offline: python3 tools/stream/test_look.py

1. Requests: surface, x, y required; zoom 0.3..3, seconds 1..60 clamped; a platform's name means its surface.
2. Only charted ground: the spot's chunk and every chunk of the on-air frame (409 with why), an unknown surface (400),
   no game (409), a failed read (503). The chart read is one line of Lua with the frame's chunk range.
3. On air: a standby jumps to the spot, the program cuts, the label is "📍 The western wall"; urgent events go in
   the inset, segments, cues and the trio wait, /cloud is refused; after it, the story comes back.
4. Precedence: look over /platform over /follow; each resumes when the one above ends (its time left).
5. director-look.json: a restart keeps it, hand edits are chart-checked, an expired or bad file does nothing.
6. HTTP (ephemeral port), the hosts' facts, the overlay's caption (node, skipped without it).
"""
import json, os, shutil, subprocess, sys, tempfile, threading, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from test_platformcam import plat, snap, main_row  # noqa: E402
from onecam import OneCam, onair_info  # noqa: E402
from platformcam import PlatformControl  # noqa: E402
import lookcam  # noqa: E402
from lookcam import LookControl, chart_lua, frame_half, chunks  # noqa: E402


class Chart:
    """A fake team chart: charted chunks as a set of (surface, cx, cy); records each read."""
    def __init__(self, charted=None, surfaces=("nauvis", "vulcanus", "platform-1")):
        self.charted, self.surfaces, self.reads = charted, set(surfaces), []

    def __call__(self, surface, x, y, hw, hh):
        self.reads.append((surface, x, y, hw, hh))
        if surface not in self.surfaces:
            return {"surface": False}
        cx0, cy0, cx1, cy1 = chunks(x, y, hw, hh)
        cells = [(surface, cx, cy) for cx in range(cx0, cx1 + 1) for cy in range(cy0, cy1 + 1)]
        ok = (lambda c: True) if self.charted is None else (lambda c: c in self.charted)
        return {"surface": True, "chunks": len(cells), "charted": sum(map(ok, cells)),
                "center": ok((surface, int(x // 32), int(y // 32))), "visible": False}


def team():
    return [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3)]


def run(d, a, start, end, plats=(), segment=None, **kw):
    for t in range(start, end):
        d.step(snap(a, plats, **kw), t, segment)
    return main_row(d, end - 1)


def requests():
    d, _ = world()
    ch = Chart()
    lc = LookControl(d, None, ch)
    ok = lambda b: lc.request(b, 1000)
    assert ok({"surface": "nauvis", "x": 10, "y": 20})[0] == 200
    code, r = ok({"surface": "Nauvis", "x": -180.26, "y": 40, "zoom": 9, "seconds": 600, "label": " The western wall ",
                  "by": "operator"})
    assert code == 200 and r["surface"] == "nauvis" and r["zoom"] == 3.0 and r["seconds"] == 60, r
    assert r["position"] == {"x": -180.3, "y": 40.0} and r["label"] == "The western wall" and r["until"] == 1060.0
    assert ok({"surface": "nauvis", "x": 0, "y": 0, "zoom": 0.01, "seconds": 0})[1]["zoom"] == 0.3
    assert ok({"surface": "nauvis", "x": 0, "y": 0})[1]["seconds"] == 30
    for bad in (None, [], "x", {}, {"surface": " ", "x": 0, "y": 0}, {"surface": "nauvis", "x": 0},
                {"surface": "nauvis", "x": "1", "y": float("nan")}, {"surface": "nauvis", "x": True, "y": 0},
                {"surface": "nauvis", "x": 0, "y": 0, "seconds": "soon"},
                {"surface": "nauvis", "x": 0, "y": 0, "zoom": float("inf")}):
        assert ok(bad)[0] == 400, bad
    # a platform's name: its surface
    d.step(snap(team(), [plat()]), 1000)
    code, r = ok({"surface": "STARLING", "x": 0, "y": 0})
    assert code == 200 and r["surface"] == "platform-1" and r["platform"] == "Starling", r
    # the chart read covers the frame on air at that zoom (the program's crop of the width)
    hw, hh = frame_half(0.75, d.cfg["view_frac"])
    assert ch.reads[-1][3:] == (hw, hh) and hw < 40 * d.cfg["view_frac"] and 20 < hh < 23, ch.reads[-1]


def charted_only():
    d, _ = world()
    home = {("nauvis", cx, cy) for cx in range(-4, 4) for cy in range(-4, 4)}  # 256 x 256 tiles around the centre
    lc = LookControl(d, None, Chart(home))
    assert lc.request({"surface": "nauvis", "x": 0, "y": 0}, 1000)[0] == 200
    code, r = lc.request({"surface": "nauvis", "x": 500, "y": 0}, 1000)
    assert code == 409 and "(500, 0) on nauvis is not charted" in r["error"], r
    code, r = lc.request({"surface": "nauvis", "x": 100, "y": 0, "zoom": 0.3}, 1000)  # spot charted, frame edge not
    assert code == 409 and "chunks the frame at zoom 0.3 covers" in r["error"] and r["charted"] < r["chunks"], r
    assert lc.request({"surface": "nauvis", "x": 100, "y": 0, "zoom": 2}, 1000)[0] == 200  # closer: all charted
    assert d.look_hold["position"] == {"x": 100.0, "y": 0.0}
    code, r = lc.request({"surface": "mars", "x": 0, "y": 0}, 1000)
    assert code == 400 and "no surface 'mars'" in r["error"]
    assert LookControl(d, None, None).request({"surface": "nauvis", "x": 0, "y": 0}, 1000)[0] == 409

    def broken(*a):
        raise OSError("rcon down")
    code, r = LookControl(d, None, broken).request({"surface": "nauvis", "x": 0, "y": 0}, 1000)
    assert code == 503 and "rcon down" in r["error"]
    # the Lua: one line once joined, no comments, the chunk range and spot filled in, the surface quoted
    from harness import one_line
    lua = one_line(chart_lua("platform-X]]", -40.5, 70, 30, 17))
    assert "--" not in lua and "_X_" not in lua and "_SURF_" not in lua and "_CX0_" not in lua, lua
    assert "for cx = -3, -1 do" in lua and "for cy = 1, 2 do" in lua and "math.floor(-40.5 / 32)" in lua, lua
    assert "game.get_surface([=[platform-X]]]=])" in lua, lua
    assert lookcam.mock_chart("nauvis", 0, 0, 30, 17)["charted"] == 4


def on_air():
    d, sent = world(map_every=0, platform_every=0, trio=True, trio_every=20, trio_gap=10)
    a = team()
    row = run(d, a, 1000, 1004)
    assert row["agents"] == ["luna"], row
    lc = LookControl(d, None, Chart())
    lc.request({"surface": "nauvis", "x": -180, "y": 40, "zoom": 1.5, "seconds": 40, "label": "The western wall",
                "by": "nick"}, 1004)
    d.step(snap(a), 1004)
    framed = sent[-1]
    assert framed["position"] == {"x": -180.0, "y": 40.0} and framed["zoom"] == 1.5 and framed["smooth"] is False
    assert framed["surface"] == "nauvis" and main_row(d, 1004)["agents"] == ["luna"]  # framing first, then the cut
    row = run(d, a, 1005, 1008)
    assert row["agents"] == [] and row["look"]["label"] == "The western wall" and row["look"]["by"] == "nick", row
    assert row["frame"]["position"] == {"x": -180.0, "y": 40.0} and d.look_info(1007)["remaining_s"] == 37
    on, n = d.onair, len(sent)
    run(d, a, 1008, 1012)
    assert len(sent) == n  # a held spot sends no more camera commands
    # a death elsewhere goes in the inset; a segment, a cue and the trio wait; /cloud is refused
    death = {"id": "death", "kind": "death", "t": 1012, "agent": "sol", "text": "Sol died"}
    d.step(snap(a, alerts=[death]), 1012)
    assert d.onair == on and d.public(1012)["inset"]["alert"] == "death"
    assert d.request_cloud(now=1013)[0] == 409 and "DELETE /look" in d.request_cloud(now=1013)[1]["error"]
    segment = {"id": "seg", "follow": "sol", "zoom": 1, "until": 1100, "label": "Sol"}
    for t in range(1013, 1044):
        s = snap(a)
        s["voiced"] = [{"id": f"v{t}", "agent": "sol", "look": {"position": {"x": 300, "y": 0}}}]
        d.step(s, t, segment)
        assert d.onair == on and d.mode == "onecam" and main_row(d, t).get("look"), (t, d.public(t))
    # the 40 s are up: the story comes back
    row = run(d, a, 1044, 1050)
    assert not row.get("look") and row["agents"] in (["luna"], ["sol"]) and d.look_info(1049) is None, row
    info = onair_info(snap(a), d.public(1049))
    assert info["look"] is None
    # cleared early: back at once; the same spot again only updates the label and time
    lc.request({"surface": "nauvis", "x": 10, "y": 10, "label": "Upcycler"}, 1050)
    row = run(d, a, 1050, 1054)
    assert row["look"]["label"] == "Upcycler"
    n = len(sent)
    lc.request({"surface": "nauvis", "x": 10, "y": 10, "label": "LimeLight555's upcycler", "seconds": 60}, 1054)
    row = run(d, a, 1054, 1056)
    assert len(sent) == n and row["look"]["label"] == "LimeLight555's upcycler"
    lc.clear(1056)
    row = run(d, a, 1056, 1060)
    assert not row.get("look") and row["agents"], row
    # no label: the spot ("Vulcanus · (120, -40)"); one client: retargeted on air
    d1 = OneCam([{"slot": "main", "player": 3}], lambda b: {"ok": True}, None)
    d1.step(snap(team()), 1000)
    LookControl(d1, None, Chart()).request({"surface": "vulcanus", "x": 120, "y": -40}, 1000)
    row = run(d1, team(), 1001, 1003)
    assert row["look"]["label"] == "Vulcanus · (120, -40)" and row["frame"]["surface"] == "vulcanus", row


def precedence():
    """look > platform hold > follow; each resumes after the one above if its time is not up."""
    d, _ = world(map_every=0, platform_every=0)
    a, p = team(), [plat()]
    run(d, a, 1000, 1003, p)
    d.set_follow("sol", 1300, "Sol's turn", "nick", 1003)
    row = run(d, a, 1003, 1008, p)
    assert row["agents"] == ["sol"] and row.get("follow") == "Sol's turn", row
    PlatformControl(d).request({"name": "Starling", "seconds": 120}, 1008)
    row = run(d, a, 1008, 1012, p)
    assert row["platform"]["why"] == "operator", row  # platform over follow
    lc = LookControl(d, None, Chart())
    lc.request({"surface": "nauvis", "x": 50, "y": 50, "seconds": 20, "label": "Wall"}, 1012)
    row = run(d, a, 1012, 1016, p)
    assert row.get("look") and not row.get("platform"), row  # look over platform (and follow)
    assert d.platform_info(1015)["remaining_s"] > 0 and d.follow_info(1015)
    row = run(d, a, 1032, 1036, p)  # look over: the platform hold resumes
    assert not row.get("look") and row["platform"]["why"] == "operator", row
    lc.request({"surface": "nauvis", "x": 50, "y": 50, "seconds": 10}, 1036)
    row = run(d, a, 1036, 1040, p)
    assert row.get("look"), row
    row = run(d, a, 1130, 1134, p)  # the look and the platform hold are both over: the follow resumes
    assert not row.get("look") and not row.get("platform") and row["agents"] == ["sol"], row
    # a look while a follow alone is on; the follow comes back after
    lc.request({"surface": "nauvis", "x": -20, "y": 0, "seconds": 5}, 1134)
    row = run(d, a, 1134, 1138, p)
    assert row.get("look") and d.follow_info(1137), row
    row = run(d, a, 1139, 1144, p)
    assert row["agents"] == ["sol"] and not row.get("look"), row


def persistence():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "director-look.json")
        d, _ = world(map_every=0)
        LookControl(d, path, Chart()).request({"surface": "nauvis", "x": 5, "y": 6, "seconds": 30, "label": "W"}, 1000)
        assert json.load(open(path))["until"] == 1030.0
        d2, _ = world(map_every=0)
        ch = Chart()
        lc2 = LookControl(d2, path, ch)
        lc2.sync(1001)
        assert d2.look_info(1001)["label"] == "W" and len(ch.reads) == 1  # a restart keeps it (checked again)
        row = run(d2, team(), 1001, 1005)
        assert row["look"]["label"] == "W", row
        home = {("nauvis", 0, 0)}
        lc2.chart = Chart(home)
        cases = [({"surface": "nauvis", "position": {"x": 16, "y": 16}, "zoom": 3, "until": 1200, "label": "M"}, True),
                 ({"surface": "nauvis", "position": {"x": 900, "y": 5}, "until": 1200}, False),  # not charted
                 ({"surface": "nauvis", "position": {"x": 5, "y": 5}, "until": 900}, False),  # expired
                 ([], False), (None, False), ({"surface": "nauvis", "position": {"x": "a", "y": 5}, "until": 1200}, False),
                 ({"surface": 3, "position": {"x": 5, "y": 5}, "until": 1200}, False),
                 ({"surface": "nauvis", "position": {"x": 5, "y": 5}, "until": float("nan")}, False)]
        for i, (data, on) in enumerate(cases):
            with open(path, "w") as f:
                json.dump(data, f)
            os.utime(path, (3000 + i, 3000 + i))
            lc2.sync(1010)
            assert bool(d2.look_info(1010)) == on, (data, d2.look_hold)
        os.remove(path)
        lc2.sync(1011)
        assert d2.look_hold is None
        LookControl(d2, path, Chart()).request({"surface": "nauvis", "x": 0, "y": 0}, 1012)
        LookControl(d2, path, Chart()).clear(1013)
        assert not os.path.exists(path) and d2.look_hold is None


def http_and_hosts():
    import caster
    from serve import Hub, make_handler
    d, _ = world()
    d.step(snap(team()), 1000)
    lc = LookControl(d, None, Chart({("nauvis", 0, 0), ("nauvis", -1, 0), ("nauvis", 0, -1), ("nauvis", -1, -1)}))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: [], look=lc, director=d))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/look"

    def request(data=None, method="POST"):
        req = urllib.request.Request(url, data=json.dumps(data).encode() if method == "POST" else None, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    try:
        code, r = request({"surface": "nauvis", "x": 1, "y": 1, "zoom": 3, "seconds": 45, "label": "Upcycler", "by": "op"})
        assert code == 200 and r["seconds"] == 45 and r["chunks"] == 4 and r["visible"] is False, r
        code, r = request({"surface": "nauvis", "x": 400, "y": 1})
        assert code == 409 and "not charted" in r["error"], r
        assert request({"surface": "nauvis"})[0] == 400
        assert request(method="DELETE") == (200, {"look": None}) and d.look_hold is None
    finally:
        srv.shutdown()
        srv.server_close()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: []))  # another director: no look
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/look"
    try:
        assert request({"surface": "nauvis", "x": 1, "y": 1})[0] == 409
    finally:
        srv.shutdown()
        srv.server_close()
    assert lc.request({"surface": "nauvis", "x": 1, "y": 1, "zoom": 3, "label": "Upcycler", "by": "op"}, 1000)[0] == 200
    run(d, team(), 1001, 1005)
    s = snap(team())
    s.update(onair=onair_info(s, d.public(1004)), look=d.look_info(1004))
    facts = caster.facts_for({"kind": "lull", "angle": "explain"}, s)["on_screen_look"]
    assert facts["shown_as"] == "Upcycler" and facts["remaining_s"] == 26 and facts["surface"] == "nauvis", facts


def overlay():
    """The real camera-label renderer: the look's caption with its pin."""
    if not shutil.which("node"):
        print("look overlay: skip (node unavailable)")
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
const cam = {agents: [], look: {label: 'The western wall', by: 'op'}};
renderCams({agents: [], cameras: {main: cam}});
assert(label.children.includes('📍') && label.children.includes('The western wall'), label.children);
'''
    r = subprocess.run(["node", "-e", js, os.path.join(HERE, "static", "overlay.js")],
                       capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr


if __name__ == "__main__":
    requests()
    charted_only()
    on_air()
    precedence()
    persistence()
    http_and_hosts()
    overlay()
    print("look: ok (requests, charted ground only, on air with insets, look > platform > follow, file, HTTP, hosts, caption)")
