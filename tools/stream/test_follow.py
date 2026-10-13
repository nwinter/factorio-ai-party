#!/usr/bin/env python3
"""Operator follow (follow.py, onecam.py; Nick 12:54: "Sol says it's gonna try to fight a Demolisher on Vulcanus. I
would love to see that"): python3 tools/stream/test_follow.py

1. The director: a follow cuts to the agent (standby framed first) and keeps it on air whatever the scores, with no
   rotation, trio, base map, platform visit or segment; other agents' real losses and deaths are insets, its own
   attack is labelled; the label is on the on-air card and in onair; when it runs out, normal directing comes back.
2. FollowControl: agent by name or display name, seconds capped at 1800, kept in director-follow.json; a new service
   (a restart) reads it; a hand edit or removal is picked up; an expired file is no follow.
3. serve.py: POST /follow and DELETE /follow.
"""
import json, os, sys, tempfile, threading, time, urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from follow import FollowControl  # noqa: E402
from onecam import onair_info  # noqa: E402
from test_onecam import agent, world  # noqa: E402


def snap(team, alerts=(), **kw):
    return dict({"agents": team, "alerts": list(alerts)}, **kw)


def onair(d, t):
    return (d.public(t).get("main") or {}).get("agents")


def director():
    d, sent = world(trio=True, trio_every=60, trio_gap=30, map_every=60, map_first=10, platform_every=60,
                    platform_first=10)
    team = [agent("luna", 0, 0, 5), agent("sol", -236, 68, 1), agent("astra", 400, 0, 1)]
    t = 1000
    for k in range(3):
        d.step(snap(team), t + k)
    assert onair(d, t + 2) == ["luna"]
    d.set_follow("sol", t + 600, "Sol vs the Demolisher", "nick", t + 3)
    for k in range(3, 7):
        d.step(snap(team), t + k)
    assert onair(d, t + 6) == ["sol"] and d.cuts[-1][2] == "follow: Sol vs the Demolisher", d.cuts
    assert any(b.get("follow") == "sol" and b["smooth"] is False for b in sent)  # framed off air first
    cuts = len(d.cuts)
    team[0]["interest"] = 80  # luna far more interesting: no rotation, no trio, map or platform shot
    plat = {"name": "Starling", "at": "nauvis", "view": {"surface": "platform-1", "hub": {"x": 0, "y": 0},
                                                        "bounds": {"left": -9, "top": -9, "right": 9, "bottom": 9}}}
    seg = {"id": "s1", "follow": "luna", "zoom": 1.0, "until": t + 400, "label": "Spotlight: Luna"}
    for k in range(7, 400):
        d.step(snap(team, space={"platforms": [plat]}), t + k, seg if 100 <= k < 200 else None)
        assert onair(d, t + k) == ["sol"] and d.mode == "onecam", (k, d.public(t + k), d.cuts[cuts:])
    assert len(d.cuts) == cuts and not d.maps and not d.platforms, (d.cuts[cuts:], d.maps, d.platforms)
    pub = d.public(t + 399)
    assert pub["main"]["follow"] == "Sol vs the Demolisher", pub
    info = onair_info({"agents": team}, pub)
    assert info["agent"] == "sol" and info["doing"] == "Sol vs the Demolisher" and info["follow"] == "Sol vs the Demolisher"
    f = d.follow_info(t + 399)
    assert f == {"agent": "sol", "label": "Sol vs the Demolisher", "until": t + 600.0, "remaining_s": 201, "by": "nick",
                 "until_battle": False, "battle": None, "ended_by": None}, f
    # another agent's real loss and a death: insets, no cut; sol's own attack: labelled on air
    loss = {"id": "l1", "kind": "loss", "t": t + 400, "text": "6 lost near (300, 300): 2 gun turret, 4 stone wall",
            "position": {"x": 300, "y": 300, "extent": 20}, "key": "loss:300,300"}
    d.step(snap(team, [loss]), t + 400)
    assert d.pending is None and d.public(t + 400)["inset"]["attack"] == loss["text"] and len(d.cuts) == cuts
    death = {"id": "d1", "kind": "death", "t": t + 450, "text": "Astra died", "agent": "astra"}
    d.step(snap(team, [death]), t + 450)
    d.step(snap(team), t + 452)
    assert onair(d, t + 452) == ["sol"] and len(d.cuts) == cuts, d.cuts[cuts:]
    fight = {"id": "a1", "kind": "attack", "t": t + 500, "text": "Sol is under attack (demolisher)", "agent": "sol",
             "position": {"x": -236, "y": 68}}
    d.step(snap(team, [fight]), t + 500)
    pub = d.public(t + 500)
    assert pub["main"]["agents"] == ["sol"] and pub["main"]["attack"] == fight["text"] and len(d.cuts) == cuts, pub
    # over: normal directing again (luna, far more interesting, takes the camera)
    for k in range(601, 620):
        d.step(snap(team), t + k)
    assert d.follow_info(t + 620) is None and onair(d, t + 619) == ["luna"], d.cuts[cuts:]
    assert d.cuts[cuts][0] == t + 601 and "beats sol" in d.cuts[cuts][2], d.cuts[cuts:]
    assert "follow" not in d.public(t + 619)["main"]
    # the follow's agent gone (offline): normal directing meanwhile
    d.set_follow("nobody", t + 2000)
    d.step(snap(team), t + 621)
    assert d.fol is None
    print("director: ok (cut to the agent, held 600 s against scores, segments, trio, map and platform; insets for "
          "others' losses and deaths; label; over -> back)")


def control():
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "director-follow.json")
    d, _ = world()
    roster = [("sol", "Sol"), ("luna", "Luna the Wall")]
    fc = FollowControl(d, path, roster)
    now = 5000.0
    code, r = fc.request({"agent": "nobody"}, now)
    assert code == 400 and r["agents"] == ["sol", "luna"], r
    code, r = fc.request({"agent": "Luna the Wall", "seconds": 99999, "label": "Luna holds the gate", "by": "nick"}, now)
    assert code == 200 and r["agent"] == "luna" and r["seconds"] == 1800 and d.follow["until"] == now + 1800, r
    assert json.load(open(path)) == {"agent": "luna", "until": now + 1800, "label": "Luna holds the gate", "by": "nick"}
    code, r = fc.request({"agent": "SOL"}, now)
    assert code == 200 and r["seconds"] == 600 and r["label"] is None and d.follow["agent"] == "sol", r
    # a restart: a new service reads the file
    d2, _ = world()
    fc2 = FollowControl(d2, path, roster)
    fc2.sync(now + 10)
    assert d2.follow and d2.follow["agent"] == "sol" and d2.follow["until"] == now + 600
    # a hand edit, then the file removed
    json.dump({"agent": "luna", "until": now + 100, "label": "x"}, open(path, "w"))
    os.utime(path, (now + 1, now + 1))
    fc2.sync(now + 20)
    assert d2.follow["agent"] == "luna" and d2.follow["label"] == "x"
    os.remove(path)
    fc2.sync(now + 21)
    assert d2.follow is None
    # an expired file: no follow
    json.dump({"agent": "luna", "until": time.time() - 5}, open(path, "w"))
    d3, _ = world()
    FollowControl(d3, path, roster).sync()
    assert d3.follow is None
    # DELETE
    fc.request({"agent": "sol"}, now)
    fc.clear(now)
    assert d.follow is None and not os.path.exists(path)
    # no file (the mock): in memory only
    d4, _ = world()
    fc4 = FollowControl(d4, None, roster)
    assert fc4.request({"agent": "sol", "seconds": 60}, now)[0] == 200 and d4.follow["until"] == now + 60
    print("control: ok")


def http():
    from serve import Hub, make_handler
    d, _ = world()
    fc = FollowControl(d, None, [("sol", "Sol")])
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: [], follow=fc))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}/follow"
    try:
        req = urllib.request.Request(base, data=json.dumps({"agent": "sol", "seconds": 900, "label": "Sol vs the Demolisher",
                                                            "by": "nick"}).encode(), method="POST")
        r = json.load(urllib.request.urlopen(req))
        assert r["agent"] == "sol" and r["seconds"] == 900 and d.follow["label"] == "Sol vs the Demolisher", r
        try:
            urllib.request.urlopen(urllib.request.Request(base, data=b'{"agent": "x"}', method="POST"))
            raise AssertionError("unknown agent accepted")
        except urllib.error.HTTPError as e:
            assert e.code == 400
        r = json.load(urllib.request.urlopen(urllib.request.Request(base, method="DELETE")))
        assert r == {"follow": None} and d.follow is None
    finally:
        srv.shutdown()
    print("http: ok")


if __name__ == "__main__":
    director()
    control()
    http()
