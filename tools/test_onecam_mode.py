#!/usr/bin/env python3
"""One-camera mode for Sunday 2026-10-18 (POG_CAMS=1: Nick plays his own Factorio on the box, the stream runs on cam1
and OBS): python3 tools/test_onecam_mode.py

1. tools/cams.py: POG_CAMS as a count or names -> the cameras, the count (POG_EXPECT_CAMS), the director's slots.
2. start-cams.sh with POG_CAMS=1 starts and waits for cam1 only (the stubs of test_shift_change.py).
3. shift_change.py carries POG_CAMS from switches.env to the next shift; POG_CAMS set by the operator at the change
   wins (POG_CAMS=1 on Saturday 21:30, POG_CAMS=3 to go back); start-team writes POG_CAMS and POG_EXPECT_CAMS.
4. The director with one client: it moves that client to a new subject (a jump, logged as a program cut with its
   reason) where three clients would cut; never an inset or a trio; urgent shots, a /look and a /platform hold use it.
5. cuts.py with the one capture: it stays on air in the main hole; the other camera captures are turned off (Nick's
   own Factorio on the box must not show through one), and on again when the director has three.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
import cams  # noqa: E402
import shift_change as sc  # noqa: E402


def cams_values():
    assert cams.cams("") == ["cam1", "cam2", "cam3"] and cams.cams("1") == ["cam1"] and cams.cams("2") == ["cam1", "cam2"]
    assert cams.cams("cam1 cam3") == ["cam1", "cam3"] and cams.cams("cam3,cam1") == ["cam1", "cam3"]
    assert cams.cams("0") == cams.cams("9") == cams.cams("nonsense") == ["cam1", "cam2", "cam3"]
    assert cams.slots("1") == [{"slot": "main", "player": 1}]
    assert cams.slots("") == [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2}, {"slot": "cam3", "player": 3}]
    assert cams.slots("cam1 cam3") == [{"slot": "main", "player": 1}, {"slot": "cam3", "player": 3}]
    assert cams.source("main") == "stream cam1" and cams.source("cam3") == "stream cam3"
    env = dict(os.environ, POG_CAMS="1")
    out = lambda what: subprocess.run([sys.executable, os.path.join(ROOT, "tools", "cams.py"), what], env=env,
                                      capture_output=True, text=True).stdout.strip()
    assert out("list") == "cam1" and out("count") == "1" and json.loads(out("slots")) == [{"slot": "main", "player": 1}]


def start_cams_one():
    import test_shift_change as t
    tmp = tempfile.mkdtemp(prefix="onecam")
    bin_ = os.path.join(tmp, "bin")
    os.makedirs(bin_)
    for name, body in (("winps", t.CAM_WINPS), ("rcon", t.CAM_RCON), ("obs", t.CAM_OBS)):
        open(os.path.join(bin_, name), "w").write(body)
        os.chmod(os.path.join(bin_, name), 0o755)
    state = tempfile.mkdtemp(dir=tmp)
    log = os.path.join(tmp, "calls.log")
    open(log, "w").close()
    e = {k: v for k, v in os.environ.items() if not k.startswith("POG_")}
    e.update(STUB_LOG=log, CAM_STATE=state, POG_CAM_WINPS=f"{bin_}/winps", POG_CAM_RCON=f"{bin_}/rcon",
             POG_CAM_OBS=f"{bin_}/obs", POG_CAM_WAIT="2", POG_CAM_POLL="0.2", POG_CAMS="1")
    r = subprocess.run([os.path.join(ROOT, "tools", "start-cams.sh"), "n", "34205"], cwd=ROOT, env=e,
                       capture_output=True, text=True, timeout=60)
    calls = open(log).read().splitlines()
    assert r.returncode == 0, r.stdout + r.stderr
    starts = [l for l in calls if "start-client.ps1" in l]
    assert len(starts) == 1 and "pog-cam1" in starts[0] and "-Sound" in starts[0], calls
    steps = [l for l in r.stdout.splitlines() if "OBS captures" not in l]  # (the rehook turns all three on: harmless)
    assert r.stdout.count("joined after") == 1 and not any("cam2" in l or "cam3" in l for l in steps), r.stdout


def switches():
    tmp = tempfile.mkdtemp(prefix="onecamsw")
    prev = os.path.join(tmp, "shift25")
    os.makedirs(prev)
    open(os.path.join(prev, "switches.env"), "w").write("POG_BROKER=1\nPOG_CAMS=1\nPOG_EXPECT_CAMS=1\n")
    old = os.environ.pop("POG_CAMS", None)
    try:
        assert sc.switches(prev)["POG_CAMS"] == ("1", "switches.env")  # Sunday's later changes keep one camera
        os.environ["POG_CAMS"] = "3"
        assert sc.switches(prev)["POG_CAMS"] == ("3", "the environment")  # Monday: the operator's setting wins
        os.environ["POG_CAMS"] = " "
        assert sc.switches(prev)["POG_CAMS"] == ("1", "switches.env")  # set but empty: not a setting
        os.environ.pop("POG_CAMS")
        open(os.path.join(prev, "switches.env"), "w").write("POG_BROKER=1\n")  # a run from before: nothing carried
        assert "POG_CAMS" not in sc.switches(prev)
        os.environ["POG_CAMS"] = "1"
        assert sc.switches(prev)["POG_CAMS"] == ("1", "the environment")  # the Saturday 21:30 change
    finally:
        os.environ.pop("POG_CAMS", None)
        if old is not None:
            os.environ["POG_CAMS"] = old
    src = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    block = src.split('> "$rundir/switches.env"', 1)[0].rsplit("printf '%s\\n'", 1)[1]
    assert '"POG_CAMS=' in block and '"POG_EXPECT_CAMS=' in block, block
    assert '"cameras": cam_slots()' in src and 'export POG_EXPECT_CAMS=$(python3 tools/cams.py count)' in src
    assert 'for c in $cams; do shot_dirs+=' in src  # shot-sync reads the running clients' folders only
    assert "for cam in $(python3 tools/cams.py list); do" in open(os.path.join(ROOT, "tools", "start-cams.sh")).read()


def director_one():
    from test_onecam import agent
    from test_platformcam import plat, snap, main_row
    from onecam import OneCam
    from lookcam import LookControl
    from platformcam import PlatformControl
    sent = []
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "director.jsonl")
        one = OneCam(cams.slots("1"), lambda b: sent.append(b) or {"ok": True}, log)
        one.started = 0
        assert one.cfg["trio"] is False and one.standbys() == []
        team = [agent("luna", 0, 0, 5), agent("sol", 300, 0, 1), agent("astra", -300, 0, 1)]
        t = 1000
        for t in range(1000, 1010):
            one.step(snap(team), t)
        assert main_row(one, t)["agents"] == ["luna"]
        # sol becomes far more interesting: three clients would frame a standby and cut; one client jumps there
        team[1]["interest"] = 50
        for t in range(1010, 1400):
            one.step(snap(team), t)
            if (main_row(one, t).get("agents") or [None])[0] == "sol":
                break
        assert main_row(one, t)["agents"] == ["sol"], one.public(t)
        moved = [b for b in sent if b.get("follow") == "sol"]
        assert moved and moved[0]["player"] == 1 and moved[0]["smooth"] is False, sent[-3:]
        rows = [json.loads(l) for l in open(log)]
        prog = [r for r in rows if r["slot"] == "program"]
        assert prog and prog[-1]["reason"].startswith("move main: ") and "sol" in prog[-1]["reason"] \
            and "initial" not in prog[-1]["reason"], prog[-1]
        assert one.cuts and one.cuts[-1][1] == "main" and one.last_program_cut == t
        # an alert elsewhere: no inset (no client free); a death still cuts
        loss = {"id": "l1", "kind": "loss", "t": t + 1, "text": "3 lost near (400, 400): 3 gun turret",
                "position": {"x": 400, "y": 400}, "key": "loss:400,400"}
        one.step(snap(team, alerts=[loss]), t + 1)
        assert one.inset is None and "inset" not in one.public(t + 1)
        death = {"id": "d1", "kind": "death", "t": t + 40, "agent": "astra", "text": "Astra died",
                 "position": {"x": -300, "y": 0}}
        for k in range(t + 40, t + 44):
            one.step(snap(team, alerts=[death] if k == t + 40 else []), k)
        assert main_row(one, t + 43).get("alert") == "death" and one.inset is None, one.public(t + 43)
        # a /look and a /platform hold move the one client too, and the story comes back after
        t = t + 200
        for k in range(t, t + 60):
            one.step(snap(team, [plat()]), k)
        LookControl(one, None, lambda *a: {"surface": True, "chunks": 4, "charted": 4, "center": True}).request(
            {"surface": "nauvis", "x": 50, "y": 50, "seconds": 10, "label": "Wall"}, t + 60)
        for k in range(t + 60, t + 63):
            one.step(snap(team, [plat()]), k)
        assert main_row(one, t + 62)["look"]["label"] == "Wall" and sent[-1]["position"] == {"x": 50.0, "y": 50.0}
        PlatformControl(one).request({"name": "Starling", "seconds": 20}, t + 75)
        for k in range(t + 75, t + 79):
            one.step(snap(team, [plat()]), k)
        assert main_row(one, t + 78)["platform"]["why"] == "operator" and sent[-1]["surface"] == "platform-1"
        for k in range(t + 100, t + 110):
            one.step(snap(team, [plat()]), k)
        assert main_row(one, t + 109)["agents"], one.public(t + 109)
        # never an inset or a trio, and every command went to the one client
        assert all(b["player"] == 1 for b in sent) and one.mode == "onecam"


class FakeOBS:
    def __init__(self):
        self.items = [[1, "stream background"], [4, "stream cam3"], [2, "stream cam1"], [3, "stream cam2"],
                      [5, "stream overlay"]]
        self.calls = []
        self.on = {}

    def call(self, req, data=None):
        data = data or {}
        self.calls.append((req, data))
        if req == "GetSceneItemList":
            return {"sceneItems": [{"sceneItemId": i, "sourceName": n, "sceneItemIndex": k, "sceneItemEnabled": self.on.get(i, True)}
                                   for k, (i, n) in enumerate(self.items)]}
        if req == "SetSceneItemEnabled":
            self.on[data["sceneItemId"]] = data["sceneItemEnabled"]
        if req == "GetSceneItemTransform":
            return {"sceneItemTransform": {"sourceWidth": 1920, "sourceHeight": 1080}}
        if req == "SetSceneItemIndex":
            it = next(x for x in self.items if x[0] == data["sceneItemId"])
            self.items.remove(it)
            self.items.insert(data["sceneItemIndex"], it)
        return {}


def cuts_one():
    import cuts as cuts_mod
    obs = FakeOBS()
    names = [s["slot"] for s in cams.slots("1")]
    c = cuts_mod.Cuts(obs, json.load(open(cuts_mod.LAYOUT)), slots=names, sources=[cams.source(n) for n in names],
                      start=False, vertical=None, log=lambda m: None)
    c.set({"onair": "main", "inset": None, "layout": "onecam"})
    c.work()
    moved = {d["sceneItemId"] for r, d in obs.calls if r in ("SetSceneItemTransform", "SetSceneItemIndex")}
    assert moved == {2}, obs.calls  # only stream cam1: placed in the main hole and restacked
    # the idle captures are turned off (Nick's own Factorio on the box must not show through one of them)
    assert obs.on == {3: False, 4: False}, obs.on
    t = next(d["sceneItemTransform"] for r, d in obs.calls if r == "SetSceneItemTransform")
    x, y, w, h = json.load(open(cuts_mod.LAYOUT))["cams"]["main"]
    assert (t["positionX"], t["positionY"], t["boundsWidth"], t["boundsHeight"]) == (x, y, w, h), t
    assert c.public()["onair"] == "main" and c.public()["inset"] is None
    n = len(obs.calls)
    c.set({"onair": "main", "inset": None, "layout": "onecam"})
    c.work()
    assert len(obs.calls) == n  # the same program again: nothing sent
    # back to three cameras (Monday): their captures come on again
    c3 = cuts_mod.Cuts(obs, json.load(open(cuts_mod.LAYOUT)), start=False, vertical=None, log=lambda m: None)
    c3.set({"onair": "cam2", "inset": None, "layout": "onecam"})
    c3.work()
    assert obs.on == {3: True, 4: True}, obs.on
    src = open(os.path.join(ROOT, "tools", "stream", "serve.py")).read()
    assert "cuts_mod.Cuts(OBS(host, int(port or 4455)), lay, slots=names," in src


if __name__ == "__main__":
    cams_values()
    start_cams_one()
    switches()
    director_one()
    cuts_one()
    print("one-camera mode: ok (POG_CAMS count or names, start-cams cam1 only, carried and overridden at a change, "
          "the director moves its one client with no inset or trio, cuts.py keeps cam1 on air)")
