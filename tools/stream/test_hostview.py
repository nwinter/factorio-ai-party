#!/usr/bin/env python3
"""Host view (hostview.py; Nick 16:39: "it would be interesting for the stream viewers to also see my view, so I can
show them things"). Offline: python3 tools/stream/test_hostview.py

1. The host's chat commands: "!view", "!view CAPTION", "!view off"; anything else is chat.
2. POST /hostview: on with seconds (default 20 min, at most 60) and caption; off; refused while his client is not in
   the game; the time limit and his client leaving end it; a chat notice when it starts and ends; the file keeps it
   over a restart.
3. The director holds while it is on: no cut, no inset (an urgent shot waits), no trio; program host; on-air label
   "NickWinter (host) · CAPTION"; with three clients and with one (POG_CAMS=1). After it the story goes on.
4. The viewer feed: the host's "!view" is a command (not shown, not relayed); a viewer's "!view" is chat.
5. HTTP: POST and DELETE /hostview on the service; 409 without the onecam director.
"""
import json, os, sys, tempfile, threading, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_onecam import agent, world  # noqa: E402
from onecam import OneCam  # noqa: E402
import hostview  # noqa: E402
from hostview import HostControl, parse_command  # noqa: E402
import viewers as V  # noqa: E402


def snap(agents, alerts=()):
    return {"agents": agents, "alerts": list(alerts), "fights": []}


def team():
    return [agent("luna", 0, 0, 5), agent("sol", 300, 0, 3), agent("astra", -300, 0, 1)]


def commands():
    assert parse_command("!view") == ("on", None)
    assert parse_command("  !View the new smelting column ") == ("on", "the new smelting column")
    assert parse_command("!view off") == ("off",) and parse_command("!VIEW stop") == ("off",)
    assert parse_command("view") is None and parse_command("hello !view") is None and parse_command("!viewers") is None
    print("1. chat commands: ok")


def control():
    d, _ = world()
    said = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "director-host.json")
    hc = HostControl(d, path, said.append)
    t = 1000.0
    hc.sync(t, ["nick", "pog-director"])
    code, r = hc.request({"on": True, "caption": "the new smelting column"}, t)
    assert code == 200 and r["hostview"]["seconds"] == 1200 and r["hostview"]["label"] == "NickWinter (host) · the new smelting column", r
    assert said[-1] == "Nick is showing his view on stream: the new smelting column" and d.hosting(t + 1)
    assert json.load(open(path))["until"] == t + 1200
    code, r = hc.request({"on": True, "seconds": 99999}, t)
    assert r["hostview"]["seconds"] == 3600 and r["hostview"]["label"] == "NickWinter (host) · showing the stream around", r
    assert len(said) == 1, "still on: no second start notice"
    assert hc.request({"on": "yes"}, t)[0] == 400 and hc.request({"on": True, "seconds": "x"}, t)[0] == 400
    code, r = hc.request({"on": False}, t + 5)
    assert code == 200 and r == {"hostview": None} and not d.hosting(t + 6) and not os.path.exists(path)
    assert said[-1] == "Nick's view is off; back to the cameras (turned off)"
    # his client not in the game: refused; leaving ends it; the time limit ends it
    hc.sync(t + 10, ["pog-director"])
    code, r = hc.request({"on": True}, t + 10)
    assert code == 409 and "nick's client is not in the game" in r["error"], r
    hc.sync(t + 11, ["nick"])
    hc.request({"on": True, "seconds": 60}, t + 11)
    hc.sync(t + 20, ["pog-director"])
    assert not d.hosting(t + 21) and said[-1] == "Nick's view is off; back to the cameras (his client left the game)"
    hc.sync(t + 30, ["nick"])
    hc.request({"on": True, "seconds": 60}, t + 30)
    hc.sync(t + 100, ["nick"])
    assert not d.hosting(t + 100) and said[-1] == "Nick's view is off; back to the cameras (its time ran out)"
    # a restart: the file brings it back
    hc.request({"on": True, "seconds": 600, "caption": "rail loop"}, t + 200)
    d2, _ = world()
    hc2 = HostControl(d2, path, None)
    hc2.sync(t + 210, None)
    assert d2.hosting(t + 211)["caption"] == "rail loop"
    # chat: only the host
    assert hc.command({"host": True, "text": "!view off"}, t + 220) and not d.hosting(t + 221)
    assert not hc.command({"text": "!view hacked"}, t + 222) and not d.hosting(t + 223)
    assert hc.command({"host": True, "text": "!view the bus"}, t + 224) and d.hosting(t + 225)["label"] == "NickWinter (host) · the bus"
    print("2. control: ok")


def director():
    for slots in (3, 1):
        if slots == 3:
            d, _ = world(map_every=0)
        else:
            d = OneCam([{"slot": "main", "player": 3}], lambda b: {"ok": True}, None, trio=False, map_every=0)
            d.started = 0
        t = 1000
        for k in range(3):
            d.step(snap(team()), t + k)
        t += 3
        before = d.onair
        d.set_host({"until": t + 300, "caption": None, "label": "NickWinter (host) · showing the stream around", "by": "operator"}, t)
        assert d.program().get("host") is True
        n = len(d.cuts)
        # an attack far off meanwhile (with three clients an inset otherwise): no cut, no inset
        att = {"id": "a1", "kind": "attack", "t": t + 1, "text": "Base under attack near (200, 200): gun turret",
               "position": {"x": 200, "y": 200, "extent": 32}, "key": "area:200,200"}
        for k in range(1, 30):
            d.step(snap(team(), [dict(att, t=t + k)]), t + k)
        assert len(d.cuts) == n and d.onair == before and d.inset is None and d.pending is None, (d.cuts[n:], d.inset)
        info = d.host_info(t + 30)
        assert info["label"] == "NickWinter (host) · showing the stream around" and info["remaining_s"] == 270, info
        d.set_host(None, t + 31)
        d.step(snap(team()), t + 31)
        assert "host" not in d.program()
        d.step(snap(team(), [dict(att, id="a2", t=t + 32)]), t + 32)  # after it, the same attack is an inset again
        if slots == 3:
            assert d.inset and d.public(t + 32)["inset"]["attack"] == att["text"], d.public(t + 32)
        for k in range(33, 40):
            d.step(snap(team()), t + k)  # the story goes on
    print("3. director: ok (three clients and one)")


def feed():
    calls = []
    f = V.Feed({}, V.Filter(["astra", "sol"]))
    f.commands = lambda m, now: calls.append(m["text"]) or True
    now = 1_000_000.0
    f.ingest([{"id": "s:1", "source": "site", "author": "h", "name": "Nick", "host": True, "text": "!view the bus", "t": now},
              {"id": "s:2", "source": "site", "author": "v", "name": "ann", "text": "!view pls", "t": now}], [], now=now)
    lane, _ = f.lane()
    texts = [m["text"] for m in lane]
    assert calls == ["!view the bus"] and texts == ["!view pls"], (calls, texts)
    print("4. feed: ok (the host's !view is a command, a viewer's is chat)")


def http():
    from serve import Hub, make_handler
    d, _ = world()
    hc = HostControl(d, None, None)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: [], director=d, host=hc))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/hostview"

    def request(data=None, method="POST", u=url):
        req = urllib.request.Request(u, data=json.dumps(data).encode() if method == "POST" else None, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    try:
        code, r = request({"on": True, "seconds": 120, "caption": "the mall"})
        assert code == 200 and r["hostview"]["seconds"] == 120, r
        assert request(method="DELETE") == (200, {"hostview": None}) and d.host_hold is None
    finally:
        srv.shutdown(); srv.server_close()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Hub(), lambda: []))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert request({"on": True}, u=f"http://127.0.0.1:{srv.server_address[1]}/hostview")[0] == 409
    finally:
        srv.shutdown(); srv.server_close()
    print("5. http: ok")


def main():
    commands()
    control()
    director()
    feed()
    http()
    print("test_hostview: ok")


if __name__ == "__main__":
    main()
