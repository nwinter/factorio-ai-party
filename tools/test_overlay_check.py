#!/usr/bin/env python3
"""The overlay check (d29 batch347 OR, viewer Aurora site:5491: shift100's overlay stayed blank 26 min after its start;
a refreshnocache did not bring it back, a scene item toggle did): python3 tools/test_overlay_check.py

The real stream service handler (tools/stream/serve.py) on a local port, a stand-in overlay page (an event stream
/events?audio=1&page=main, opened or not) and a stand-in OBS (POG_OC_OBS: logs toggle-overlay; the test's page
connects after it when told to):
- the service keeps each page's streams by name: main and portrait apart, a page from before as unnamed; open,
  connects, connected, seen, closed in GET /overlay/status;
- start: a page that connects after the reload: "connected N s after the reload", no toggle; a page that never
  connects until a toggle: one toggle, "toggled the source: connected"; one that never connects: FAILED, exit 1; a
  page connected before the reload (the old one) does not count; only a portrait page connected: not the main one;
- watch: silent while connected; a stream closed past --stale: one toggle and "connected again"; none after it:
  "still not connected", and the next pass within --again says so without a second toggle;
- an older service (no /overlay/status): start says skipped and exits 0, watch says nothing; no service: FAILED;
- the health line (tools/shift_change.py) says overlay connected or overlay NOT connected (bad);
- the pages: index.html is data-page main, portrait.html portrait, and overlay.js and audio.js put the name in the
  one shared event stream.
"""
import http.server, json, os, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
import overlay_check  # noqa: E402
import serve  # noqa: E402
import shift_change  # noqa: E402


class Page:
    """A stand-in overlay page: one event stream held open until closed."""

    def __init__(self, port, name="main"):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        q = "" if name is None else f"&page={name}"
        self.s.sendall(f"GET /events?audio=1{q} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n".encode())
        self.f = self.s.makefile("rb")
        assert b"200" in self.f.readline()
        threading.Thread(target=self.drain, daemon=True).start()

    def drain(self):
        try:
            while self.f.readline():
                pass
        except OSError:
            pass

    def close(self):
        try:
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.s.close()


def service():
    hub, audio = serve.Hub(), serve.AudioHub()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(hub, lambda: [], audio=audio))
    srv.daemon_threads = True
    srv.handle_error = lambda *a: None  # a stand-in page that hangs up resets its connection: not a failure here
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    hub.publish({"tick": 1, "agents": []})

    def tick():  # the live service publishes a snapshot about once a second: a closed page is seen at the next write
        n = 1
        while True:
            n += 1
            hub.publish({"tick": n, "agents": []})
            time.sleep(0.2)
    threading.Thread(target=tick, daemon=True).start()
    return srv, audio


def until(fn, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False


def main():
    with tempfile.TemporaryDirectory() as d:
        log, mode = os.path.join(d, "toggles.log"), {"connect_on_toggle": False}
        stub = os.path.join(d, "obs")
        open(stub, "w").write(f"#!{sys.executable}\nimport sys\nopen({log!r}, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                              "print('stream overlay: toggled off and on (item 5)')\n")
        os.chmod(stub, 0o755)
        srv, audio = service()
        port = srv.server_address[1]
        url = f"http://127.0.0.1:{port}"
        pages = []

        def toggles():
            return open(log).read().splitlines() if os.path.exists(log) else []

        def on_toggle():  # the page comes back once its source is toggled
            seen = 0
            while True:
                n = len(toggles())
                if n > seen:
                    seen = n
                    if mode["connect_on_toggle"]:
                        time.sleep(0.3)
                        pages.append(Page(port))
                time.sleep(0.05)
        threading.Thread(target=on_toggle, daemon=True).start()
        env = dict(os.environ, POG_OC_OBS=stub, POG_OC_SLEEP="0.1")

        def cli(*args):
            return subprocess.run([sys.executable, os.path.join(HERE, "overlay_check.py"), *args, "--service", url,
                                   "--state", os.path.join(d, "state.json")], capture_output=True, text=True, env=env, timeout=60)

        # the service: pages by name, apart
        portrait, old = Page(port, "portrait"), Page(port, None)
        assert until(lambda: set(overlay_check.read(url)["pages"]) == {"portrait", "unnamed"})
        st = overlay_check.read(url)
        assert st["pages"]["portrait"]["open"] == 1 and st["pages"]["portrait"]["connects"] == 1 and st["up"] <= st["now"], st
        assert not overlay_check.connected(st), "a portrait page is not the main overlay"
        old.close()
        assert until(lambda: overlay_check.read(url)["pages"]["unnamed"]["open"] == 0)
        assert overlay_check.read(url)["pages"]["unnamed"]["closed"], "closed stamped"

        # start: only the portrait page: not connected; with no toggle effect: FAILED, one toggle
        t0 = time.time()
        r = cli("start", "--since", str(t0), "--wait", "1")
        assert r.returncode == 1 and "overlay: FAILED: not connected 1 s after the reload nor 1 s after a toggle" in r.stdout, r.stdout + r.stderr
        assert toggles() == ["toggle-overlay"], toggles()
        # a page that connects after the reload: no toggle
        t1 = time.time()
        threading.Timer(0.4, lambda: pages.append(Page(port))).start()
        r = cli("start", "--since", str(t1), "--wait", "3")
        assert r.returncode == 0 and "overlay: connected 0 s after the reload" in r.stdout, r.stdout + r.stderr
        assert len(toggles()) == 1, "no toggle when it connected"
        # that page (connected before) does not count for a new reload; the page comes back after a toggle
        for p in pages:
            p.close()
        pages.clear()
        mode["connect_on_toggle"] = True
        t2 = time.time() + 0.01
        r = cli("start", "--since", str(t2), "--wait", "1")
        assert r.returncode == 0 and "not connected 1 s after the reload; toggled the source: connected 0 s later" in r.stdout, r.stdout + r.stderr
        assert len(toggles()) == 2, toggles()
        # status and the health line: connected
        r = cli("status")
        assert r.returncode == 0 and r.stdout.startswith("overlay connected (1 stream"), r.stdout
        assert shift_change.overlay_status(url + "/state.json") == "overlay connected"
        # the health line: connected, and which way the start's check went (start.log)
        rd = os.path.join(d, "run")
        os.makedirs(rd)
        open(os.path.join(rd, "team.txt"), "w").write("")
        open(os.path.join(rd, "start.log"), "w").write("09:06:52 obs-steps: overlay: not connected 30 s after the reload; toggled the source: connected 2 s later\n")
        ok, line = shift_change.health(rd, os.path.join(rd, "team.txt"), time.time(), obs=["true"], state_url=url + "/state.json")
        assert "overlay connected (after a toggle at the start)" in line, line

        # watch: silent while connected
        r = cli("watch", "--stale", "0.5")
        assert r.returncode == 0 and not r.stdout, r.stdout
        # its stream closed past --stale: one toggle, connected again
        for p in pages:
            p.close()
        pages.clear()
        assert until(lambda: overlay_check.read(url)["pages"]["main"]["open"] == 0)
        time.sleep(1.1)
        assert shift_change.overlay_status(url + "/state.json").startswith("overlay NOT connected (its stream closed"), "health: NOT"
        ok, line = shift_change.health(rd, os.path.join(rd, "team.txt"), time.time(), obs=["true"], state_url=url + "/state.json")
        assert not ok and "overlay NOT connected" in line, line
        r = cli("watch", "--stale", "1", "--wait", "1")
        assert r.returncode == 0 and "OVERLAY: no main overlay stream for 1 s; toggled the source: connected again" in r.stdout, r.stdout + r.stderr
        assert len(toggles()) == 3, toggles()
        # no page after a toggle: still not connected, then the next pass within --again: no second toggle
        for p in pages:
            p.close()
        pages.clear()
        mode["connect_on_toggle"] = False
        assert until(lambda: overlay_check.read(url)["pages"]["main"]["open"] == 0)
        time.sleep(1.1)
        os.remove(os.path.join(d, "state.json"))
        r = cli("watch", "--stale", "1", "--wait", "1")
        assert r.returncode == 1 and "toggled the source: still not connected" in r.stdout, r.stdout + r.stderr
        assert len(toggles()) == 4, toggles()
        r = cli("watch", "--stale", "1", "--again", "600")
        assert r.returncode == 1 and "still not connected (toggled" in r.stdout and len(toggles()) == 4, (r.stdout, toggles())
        # past --again: a toggle again
        r = cli("watch", "--stale", "1", "--again", "0", "--wait", "1")
        assert len(toggles()) == 5, toggles()
        portrait.close()
        srv.shutdown()

        # an older service (no /overlay/status): start skipped, watch silent, the health line leaves it out
        class Old(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
        old_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Old)
        threading.Thread(target=old_srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{old_srv.server_address[1]}"
        r = cli("start", "--since", str(time.time()), "--wait", "1")
        assert r.returncode == 0 and "overlay check: skipped (the service has no /overlay/status)" in r.stdout, r.stdout
        r = cli("watch")
        assert r.returncode == 0 and not r.stdout, r.stdout
        assert shift_change.overlay_status(url + "/state.json") is None
        old_srv.shutdown()
        # no service at all
        url = "http://127.0.0.1:9"
        r = cli("start", "--since", str(time.time()), "--wait", "1")
        assert r.returncode == 1 and "the stream service does not answer" in r.stdout, r.stdout
        assert shift_change.overlay_status(url + "/state.json").startswith("overlay NOT connected (no status")

    # the pages name themselves in their one event stream
    static = os.path.join(HERE, "stream", "static")
    assert 'data-page="main"' in open(os.path.join(static, "index.html")).read()
    assert 'data-page="portrait"' in open(os.path.join(static, "portrait.html")).read()
    for js in ("overlay.js", "audio.js"):
        text = open(os.path.join(static, js)).read()
        assert 'new EventSource("/events?audio=1&page=" + encodeURIComponent(' in text and "dataset.page" in text, js
    print("overlay check: ok (pages by name; start: connected, toggled then connected, FAILED; watch: silent, toggle "
          "once, no second toggle within --again; older service skipped; health line; the pages name themselves)")


if __name__ == "__main__":
    main()
