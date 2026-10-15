#!/usr/bin/env python3
"""Offline operator platform holds, aboard follows, framing, persistence, hosts, and ephemeral-port HTTP."""
import json, os, shutil, subprocess, sys, tempfile, threading, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world
from test_platformcam import VIEW, plat, snap, team, main_row
from model import platform_shot
from onecam import OneCam, onair_info
from platformcam import PlatformControl


def advance(d, a, p, start, end, **kw):
    for t in range(start, end):
        d.step(snap(a, p, **kw), t)
    return main_row(d, end - 1)


def geometry():
    orbit = platform_shot(VIEW)
    flight = platform_shot(VIEW, travelling=True)
    assert flight["zoom"] < orbit["zoom"] and flight["position"]["y"] < orbit["position"]["y"]
    # Whole build plus the forward asteroid space in the actual cropped viewport; width can be the constraint.
    wide = dict(VIEW, bounds={"left": -40, "top": -10, "right": 40, "bottom": 12})
    for view in (VIEW, wide):
        sh = platform_shot(view, travelling=True, frac=0.62)
        x, y, z = sh["position"]["x"], sh["position"]["y"], sh["zoom"]
        b = view["bounds"]
        assert x - 30 * .62 / z < b["left"] - 8 and x + 30 * .62 / z > b["right"] + 8, sh
        assert y - 17 / z < b["top"] - 32 and y + 17 / z > b["bottom"] + 8, sh


def held():
    d, sent = world(map_every=20, platform_every=20, trio=True, trio_every=20, trio_gap=10)
    a = team()
    advance(d, a, [plat()], 1000, 1003)
    pc = PlatformControl(d)
    assert pc.request({"name": "starling", "seconds": 200, "label": "Asteroid crossing", "by": "nick"}, 1003)[0] == 200
    row = advance(d, a, [plat()], 1003, 1007)
    assert row["platform"]["why"] == "operator" and row["agents"] == [] and row["frame"]["surface"] == "platform-1", row
    assert row["platform"]["label"] == "Starling · in orbit of Nauvis · Asteroid crossing"
    shot = [s for s in sent if s.get("surface") == "platform-1"][-1]
    assert shot["smooth"] is False and shot["zoom"] == platform_shot(VIEW)["zoom"]
    on, n = d.onair, len(sent)
    advance(d, a, [plat()], 1007, 1010)
    assert len(sent) == n  # a held shot does not spam camera commands
    flight = plat(at="nauvis->vulcanus 30%")
    row = advance(d, a, [flight], 1010, 1013)
    assert d.onair == on and row["zoom"] < shot["zoom"] and "travelling to Vulcanus (30%)" in row["platform"]["label"]
    assert sent[-1]["smooth"] is True and sent[-1]["position"]["y"] < shot["position"]["y"]
    n = len(sent)
    advance(d, a, [plat(at="nauvis->vulcanus 31%")], 1013, 1017)
    assert len(sent) == n  # progress/labels refresh without a camera call
    reverse = plat(at="nauvis->vulcanus 31%", toward="nauvis")
    row = advance(d, a, [reverse], 1017, 1020)
    assert "travelling to Nauvis (69%)" in row["platform"]["label"] and len(sent) == n
    # A huge loss and a death elsewhere stay in the inset, even with an ordinary agent follow also active.
    d.set_follow("sol", 1400, now=1020)
    loss = {"id": "loss", "kind": "loss", "t": 1020, "text": "26 lost near (400, 400): 26 gun turret",
            "position": {"x": 400, "y": 400}, "key": "loss:400,400"}
    d.step(snap(a, [flight], alerts=[loss]), 1020)
    assert d.onair == on and d.public(1020)["inset"]["attack"] == loss["text"]
    death = {"id": "death", "kind": "death", "t": 1025, "agent": "sol", "text": "Sol died"}
    d.step(snap(a, [flight], alerts=[death]), 1025)
    assert d.onair == on and d.public(1025)["inset"]["alert"] == "death"
    assert d.request_cloud(now=1026)[0] == 409
    # Segments, cues, periodic visits and the trio cannot interrupt the hold.
    segment = {"id": "seg", "follow": "sol", "zoom": 1, "until": 1200, "label": "Sol"}
    for t in range(1026, 1090):
        s = snap(a, [flight])
        s["voiced"] = [{"id": f"v{t}", "agent": "sol", "look": {"platform": "Starling"}}]
        d.step(s, t, segment)
        assert d.onair == on and d.mode == "onecam", d.public(t)
    row = advance(d, a, [plat(at="vulcanus")], 1090, 1093)
    assert row["zoom"] == shot["zoom"] and "in orbit of Vulcanus" in row["platform"]["label"]
    expanded = dict(VIEW, bounds={"left": -36, "top": -18, "right": 42, "bottom": 24})
    row = advance(d, a, [plat(at="vulcanus", view=expanded)], 1093, 1094)
    assert d.onair == on and row["zoom"] < shot["zoom"] and row["frame"]["position"] == {"x": 3.0, "y": 3.0}
    # Clearing before its deadline must not leave the fixed shot's old until active.
    pc.clear(1094)
    row = advance(d, a, [plat(at="vulcanus")], 1094, 1100)
    assert row["agents"] == ["sol"] and not row.get("platform"), row
    assert d.follow_info(1099)["agent"] == "sol"


def aboard():
    d, sent = world(platform_every=0, map_every=0)
    a = team()
    d.set_follow("sol", 1200, "Sol's trip", "nick", 1000)
    row = advance(d, a, [plat()], 1000, 1004)
    assert row["agents"] == ["sol"] and not row.get("platform")  # a planet body is not remote platform work
    a[1].update(surface="platform-1", on_platform=True, position={"x": 0, "y": 0})
    p = plat(at="nauvis->vulcanus 30%")
    row = advance(d, a, [p], 1004, 1008)
    assert row["platform"]["why"] == "follow" and row["agents"] == ["sol"]
    assert row["zoom"] == platform_shot(VIEW, travelling=True)["zoom"] and "follow" not in row["frame"], row
    assert "aboard Starling" in row["platform"]["label"] and "Sol's trip" in row["platform"]["label"]
    info = onair_info(snap(a, [p]), d.public(1007))
    assert info["agent"] == "sol" and info["doing"] == "Sol's trip · aboard Starling", info
    # Damage at the body in this shot is already visible, not a new inset or a character-scale cut.
    on = d.onair
    hit = {"id": "hit", "kind": "attack", "t": 1008, "agent": "sol", "text": "Sol under attack",
           "position": {"x": 0, "y": 0, "surface": "platform-1"}}
    d.step(snap(a, [p], alerts=[hit]), 1008)
    assert d.onair == on and d.inset is None and main_row(d, 1008).get("platform")
    a[1].update(surface="vulcanus", on_platform=False, position={"x": 200, "y": 0})
    row = advance(d, a, [plat(at="vulcanus")], 1010, 1015)
    assert row["agents"] == ["sol"] and not row.get("platform") and row["frame"]["follow"] == "sol", row
    # Missing view falls back to the character; it returns to the full ship when the view arrives.
    a[1].update(surface="platform-1", on_platform=True)
    advance(d, a, [plat(view=None)], 1015, 1018)
    row = advance(d, a, [p], 1018, 1022)
    assert row.get("platform"), row
    d.set_follow(None, 0)
    row = advance(d, a, [p], 1022, 1027)
    assert not row.get("platform"), row


def lifecycle():
    # Restarted file loads before the first platform snapshot, then resolves its name on the next step.
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "director-platform.json")
        d, _ = world(platform_every=0, map_every=0)
        advance(d, team(), [plat()], 1000, 1003)
        pc = PlatformControl(d, path)
        assert pc.request({"name": " STARLING ", "seconds": 12}, 1003)[0] == 200
        d2, _ = world(platform_every=0, map_every=0)
        pc2 = PlatformControl(d2, path)
        pc2.sync(1004)
        assert d2.platform_info(1004)["remaining_s"] == 11 and not d2.platform_info(1004)["available"]
        row = advance(d2, team(), [plat()], 1004, 1008)
        assert row["platform"]["why"] == "operator", row
        row = advance(d2, team(), [plat()], 1015, 1020)
        assert not row.get("platform") and d2.platform_info(1019) is None
        # Hand edits and deletion; invalid data never crashes the ticker or leaves an old hold active.
        cases = [{"name": "starling", "until": 1200, "label": "Manual"}, [], None, {"name": "x", "until": "bad"},
                 {"name": "x", "until": float("nan")}, {"name": "x", "until": 900}, {"name": [], "until": 1200}]
        for i, data in enumerate(cases):
            with open(path, "w") as f:
                json.dump(data, f)
            os.utime(path, (2000 + i, 2000 + i))
            pc2.sync(1020)
            assert bool(d2.platform_info(1020)) == (i == 0), (data, d2.platform_follow)
        pc2.request({"name": "Starling"}, 1020)
        os.remove(path)
        pc2.sync(1021)
        assert d2.platform_follow is None
        pc.clear(1022)
        assert not os.path.exists(path)
    # A temporarily absent platform does not pin a stale view; it can return during the requested time.
    d, _ = world(platform_every=0, map_every=0)
    advance(d, team(), [plat()], 1000, 1003)
    pc = PlatformControl(d)
    pc.request({"name": "Starling"}, 1003)
    advance(d, team(), [plat()], 1003, 1007)
    row = advance(d, team(), [], 1007, 1011)
    assert not row.get("platform") and not d.platform_info(1010)["available"], row
    row = advance(d, team(), [plat()], 1011, 1015)
    assert row.get("platform"), row
    # No agent and only one camera still show the requested ship.
    d = OneCam([{"slot": "main", "player": 3}], lambda b: {"ok": True}, None)
    d.step(snap([], [plat()]), 1000)
    PlatformControl(d).request({"name": "Starling"}, 1000)
    assert advance(d, [], [plat()], 1001, 1003)["platform"]["name"] == "Starling"


def http_and_hosts():
    import caster
    from serve import Hub, make_handler
    d, _ = world()
    d.step(snap(team(), [plat(), plat("Unavailable", view=None)]), 1000)
    pc = PlatformControl(d)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: [], platform=pc, director=d))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/platform"

    def request(data=None, method="POST"):
        req = urllib.request.Request(url, data=json.dumps(data).encode() if method == "POST" else None, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    try:
        code, data = request({"name": "starling", "seconds": 900, "label": "Asteroid crossing", "by": "nick"})
        assert code == 200 and data["name"] == "Starling" and data["seconds"] == 900
        assert request({"name": "missing"})[0] == 400
        assert request({"name": "Unavailable"})[0] == 409
        for bad in (None, [], "bad"):
            assert request(bad)[0] == 400
        for bad in (None, "bad", [], float("nan"), float("inf")):
            assert request({"name": "Starling", "seconds": bad})[0] == 400
        assert request({"name": "Starling", "seconds": 9999})[1]["seconds"] == 1800
        assert request({"name": "Starling", "seconds": 0})[1]["seconds"] == 1
        assert request(method="DELETE") == (200, {"platform": None}) and d.platform_follow is None
    finally:
        srv.shutdown()
        srv.server_close()
    pc.request({"name": "Starling", "label": "Asteroid crossing", "by": "nick"}, 1000)
    advance(d, team(), [plat()], 1001, 1005)
    s = snap(team(), [plat()])
    s.update(onair=onair_info(s, d.public(1004)), platform_hold=d.platform_info(1004))
    facts = caster.facts_for({"kind": "lull", "angle": "explain"}, s)["on_screen_platform"]
    assert facts["why"] == "operator" and facts["hold"]["by"] == "nick" and "Asteroid crossing" in facts["shown_as"]
    s["onair"]["platform"].update(why="follow", agent="sol")
    facts = caster.facts_for({"kind": "lull", "angle": "explain"}, s)["on_screen_platform"]
    assert "aboard" in facts["note"] and "orbit" not in facts["note"]


def overlay():
    """Run the real camera-label renderer for an operator shot and a followed agent aboard."""
    if not shutil.which("node"):
        print("platformhold overlay: skip (node unavailable)")
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
for (const why of ['operator', 'follow']) {
  const agents = why === 'follow' ? ['sol'] : [];
  const text = why === 'follow' ? 'Sol · aboard Starling · travelling to Vulcanus · Asteroid crossing'
                              : 'Starling · in orbit of Nauvis · Asteroid crossing';
  const cam = {agents, platform: {name: 'Starling', why, label: text}};
  const s = {agents: [{name: 'sol', display_name: 'Sol'}], cameras: {main: cam}};
  renderCams(s);
  assert(label.children.includes(text));
  cam.platform.label = text + ' · hub 62%';
  renderCams(s);
  assert(label.children.includes(cam.platform.label));
}
'''
    r = subprocess.run(["node", "-e", js, os.path.join(HERE, "static", "overlay.js")],
                       capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr


if __name__ == "__main__":
    geometry()
    held()
    aboard()
    lifecycle()
    http_and_hosts()
    overlay()
    print("platformhold: ok (whole ship and flight lead, held with urgent insets, aboard follows, restart, expiry, HTTP, hosts)")
