#!/usr/bin/env python3
"""Speech, the panel's render report and the camera clients in the overlay checks (d29 batch349 SP, viewer Aurora
site:5491: "so 'live' alone cannot pass next shift"): python3 tools/test_speech_cams.py

- speech (the stream service's summary, /overlay/status speech): clips that end played whole; clips that all expire
  (skipped); clips that no page reports (shift100's blank overlay); none posted. Bad only when clips whose time is up
  include none played whole. watch says it once per --again s, and again when it is good;
- the panel: a page's POST /overlay/render keeps its time and right panel height; a report over 90 s old or 0 px high is
  bad; a page that never reported says nothing;
- cams: a camera client in a cutscene (POG_OC_CAMS stub) is bad in status, watch (once per change) and the health line;
  under POG_TEST no world is read without the stub.
"""
import http.server, json, os, subprocess, sys, tempfile, threading, time, types, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
os.environ["POG_TEST"] = "1"
import overlay_check  # noqa: E402
import serve  # noqa: E402
import shift_change  # noqa: E402


def clip(audio, duration=5.0, expires_in=30, channel="caster"):
    audio.push({"channel": channel, "speaker": "Rook", "duration": duration, "expires_in": expires_in}, b"x", "audio/mpeg")
    return audio.order[-1]


def speech_cases():
    t0 = time.time()
    # clips that end played whole
    a = serve.AudioHub()
    ids = [clip(a), clip(a)]
    for i in ids:
        a.played({"id": i, "state": "start"}, now=t0 + 1)
        a.played({"id": i, "state": "end", "played": 5.0, "duration": 5.0}, now=t0 + 6)
    sp = a.speech(now=t0 + 70)
    assert sp["whole_30m"] == 2 and sp["due_15m"] == 2 and sp["due_15m_whole"] == 2, sp
    line, bad = overlay_check.speech({"speech": sp, "now": t0 + 70})
    assert not bad and line == "speech: last clip played whole 1 min ago, 2 in 30 min", line
    # one cut short (played 3 of 5 s): not whole; the other whole: still good
    b = serve.AudioHub()
    x, y = clip(b), clip(b)
    for i, played in ((x, 3.0), (y, 4.6)):
        b.played({"id": i, "state": "start"}, now=t0 + 1)
        b.played({"id": i, "state": "end", "played": played, "duration": 5.0}, now=t0 + 6)
    sp = b.speech(now=t0 + 70)
    assert sp["whole_30m"] == 1 and sp["due_15m_whole"] == 1, sp
    # all expiring in the page's queue (skip, expired): bad
    c = serve.AudioHub()
    for _ in range(3):
        i = clip(c, expires_in=5)
        c.played({"id": i, "state": "skip", "reason": "expired"}, now=t0 + 6)
    line, bad = overlay_check.speech({"speech": c.speech(now=t0 + 60), "now": t0 + 60})
    assert bad and line == "speech NOT playing: 3 clips posted in the last 15 min, none played whole (3 skipped, 0 with no end reported)", line
    # none reported (no page drew: shift100): their time is up once they expire; before that, nothing to say
    d = serve.AudioHub()
    clip(d, expires_in=30); clip(d, expires_in=30)
    line, bad = overlay_check.speech({"speech": d.speech(now=t0 + 10), "now": t0 + 10})
    assert not bad and line == "speech: no clip played whole since the service started", line
    line, bad = overlay_check.speech({"speech": d.speech(now=t0 + 40), "now": t0 + 40})
    assert bad and line.endswith("(0 skipped, 2 with no end reported)"), line
    # none posted, and clips older than 15 min: not bad
    e = serve.AudioHub()
    assert overlay_check.speech({"speech": e.speech(now=t0), "now": t0}) == ("speech: no clip played whole since the service started", False)
    clip(e, expires_in=5)
    assert not overlay_check.speech({"speech": e.speech(now=t0 + 1000), "now": t0 + 1000})[1]
    # control clips do not count
    f = serve.AudioHub()
    clip(f, expires_in=5, channel="control")
    assert f.speech(now=t0 + 60)["due_15m"] == 0
    # a service without the summary: nothing
    assert overlay_check.speech({"now": t0}) == (None, False)
    print("speech: whole, cut short, all expired, none reported, none posted, control clips: ok")


def service(audio):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(serve.Hub(), lambda: [], audio=audio))
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_address[1]}"


def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status


def panel_cases():
    audio = serve.AudioHub()
    url = service(audio)
    st = overlay_check.read(url)
    assert overlay_check.panel(st) == (None, False) and "speech" in st, st  # no report yet: nothing said
    assert post(url + "/overlay/render", {"page": "main", "height": 1012}) == 200
    post(url + "/overlay/render", {"page": "bad name!", "height": 5})  # not a page name: ignored
    st = overlay_check.read(url)
    p = overlay_check.page(st)
    assert p["panel_px"] == 1012 and p["rendered"] and "bad name!" not in st["pages"], st
    line, bad = overlay_check.panel(st)
    assert not bad and line.startswith("panel drew 1012 px"), line
    st["now"] = p["rendered"] + 120
    assert overlay_check.panel(st) == ("panel NOT drawn (its last report 120 s ago)", True)
    post(url + "/overlay/render", {"page": "main", "height": 0})
    line, bad = overlay_check.panel(overlay_check.read(url))
    assert bad and "0 px" in line, line
    print("panel: render reports kept by page name, fresh, stale, 0 px: ok")


def cams_cases():
    tmp = tempfile.mkdtemp()
    stub = os.path.join(tmp, "cams.sh")

    def cams(rows):
        with open(stub, "w") as f:
            f.write("#!/bin/sh\necho '" + json.dumps(rows) + "'\n")
        os.chmod(stub, 0o755)
    os.environ.pop("POG_OC_CAMS", None)
    assert overlay_check.cameras() is None  # POG_TEST: no world read without a stub
    os.environ["POG_OC_CAMS"] = stub
    cams([{"name": "pog-cam1", "controller": "spectator", "connected": True}, {"name": "pog-cam2", "controller": "cutscene", "connected": False}])
    assert overlay_check.cams_line(overlay_check.cameras()) == ("cams: pog-cam1 spectator", False)
    cams([{"name": "pog-cam1", "controller": "cutscene", "connected": True}])
    assert overlay_check.cams_line(overlay_check.cameras()) == ("cams: pog-cam1 cutscene", True)
    cams({})  # an empty Lua table reads {}
    assert overlay_check.cams_line(overlay_check.cameras()) == ("cams: none connected", False)
    # watch: a pass with a connected page prints the camera only when it changes to bad (and when good again)
    audio = serve.AudioHub()
    url = service(audio)
    state = os.path.join(tmp, "state.json")
    a = types.SimpleNamespace(service=url, stale=120, wait=1, again=600, state=state, world=None)
    st = overlay_check.read(url)

    def run():
        out = subprocess.run([sys.executable, os.path.join(HERE, "overlay_check.py"), "watch", "--service", url, "--state", state, "--stale", "99999"],
                             capture_output=True, text=True, env=dict(os.environ))
        return out.returncode, out.stdout.strip()
    cams([{"name": "pog-cam1", "controller": "spectator", "connected": True}])
    assert run() == (0, ""), run()
    cams([{"name": "pog-cam1", "controller": "cutscene", "connected": True}])
    rc, out = run()
    assert rc == 1 and out.endswith("CAMS: cams: pog-cam1 cutscene"), out
    rc, out = run()
    assert rc == 1 and out == "", out  # the same: said once
    cams([{"name": "pog-cam1", "controller": "spectator", "connected": True}])
    rc, out = run()
    assert rc == 0 and out.endswith("cams: cams: pog-cam1 spectator"), out
    # speech in watch: once per --again s while bad
    for _ in range(2):
        i = clip(audio, expires_in=5)
        audio.played({"id": i, "state": "skip", "reason": "expired"}, now=time.time())
    st = overlay_check.read(url)
    st["now"] = time.time() + 10
    with open(state, "w") as f:
        json.dump({}, f)
    printed = []
    real = print
    try:
        import builtins
        builtins.print = lambda *x, **k: printed.append(" ".join(str(v) for v in x))
        assert overlay_check.watch_more(a, st) == 1
        assert overlay_check.watch_more(a, st) == 1
    finally:
        builtins.print = real
    assert len([p for p in printed if "SPEECH" in p]) == 1, printed
    # the health line: the camera in a cutscene is bad
    cams([{"name": "pog-cam1", "controller": "cutscene", "connected": True}])
    line = shift_change.overlay_status(url + "/state.json")
    assert "cams: pog-cam1 cutscene" in line and "speech NOT playing" in line, line
    print("cams: stub read, POG_TEST guard, watch once per change, health line: ok")


def main():
    speech_cases()
    panel_cases()
    cams_cases()
    page = open(os.path.join(HERE, "stream", "static", "overlay.js")).read()
    assert "/overlay/render" in page and "reportRender();" in page
    print("speech and cams: ok")


if __name__ == "__main__":
    main()
