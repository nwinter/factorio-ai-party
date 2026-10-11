#!/usr/bin/env python3
"""Browser connection budget for the OBS pages: python3 tools/stream/test_connections.py

OBS's browser (Chromium) keeps at most 6 connections per host, and an open event stream holds one for good. In
shake7 the overlay, portrait and audio-test pages each opened /events and /audio-events on 127.0.0.1:8787, all 6 were
taken, and the voice clips (/audio/clip/...) never downloaded: the hosts were silent.

1. Static: every page opens at most one EventSource (overlay.js and audio.js share window.pogEvents), so the overlay,
   audio-test (the same page), portrait and replay pages on one host hold 4 connections and leave 2 for clips.
2. Live: a server with those 4 streams open delivers a clip announcement on the audio streams only, and the clip
   downloads on a fifth connection while all four streams stay open.
"""
import http.client, json, os, re, socket, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
STATIC = os.path.join(HERE, "static")
LIMIT = 6  # Chromium's per-host connection limit (HTTP/1.1)


def page_streams(page):
    """Event streams a page opens: one per `new EventSource(` in its scripts, shared ones (window.pogEvents) once."""
    html = open(os.path.join(STATIC, page)).read()
    texts = [m for m in re.findall(r"<script>(.*?)</script>", html, re.S)]
    for src in re.findall(r'<script src="(?:/static/)?([^"]+)"', html):
        path = os.path.join(STATIC, src)
        if os.path.exists(path):
            texts.append(open(path).read())
    own, shared = 0, set()
    for t in texts:
        for m in re.finditer(r"(window\.pogEvents \|\| \(window\.pogEvents = )?new EventSource\(\"([^\"]+)\"", t):
            if m.group(1):
                shared.add(m.group(2))
            else:
                own += 1
    return own + len(shared), shared


def static_check():
    pages = {"overlay": "index.html", "audio-test": "index.html", "portrait": "portrait.html", "replay": "replay.html"}
    total = 0
    for name, page in pages.items():
        n, shared = page_streams(page)
        assert n == 1, f"{name} ({page}) opens {n} event streams"
        total += n
    assert page_streams("index.html")[1] == {"/events?audio=1"}, page_streams("index.html")
    assert total <= LIMIT - 2, f"{total} streams on one host leave {LIMIT - total} connections for clips"
    return total


def read_events(conn_file, want, timeout=5):
    """Read SSE lines until an event of type `want` ('message' or 'audio') arrives -> its data."""
    end = time.time() + timeout
    kind = "message"
    while time.time() < end:
        line = conn_file.readline().decode().rstrip("\n")
        if line.startswith("event: "):
            kind = line[7:]
        elif line.startswith("data: "):
            if kind == want:
                return line[6:]
            kind = "message"
    raise AssertionError(f"no {want} event within {timeout} s")


def live_check():
    from http.server import ThreadingHTTPServer
    import serve
    hub, audio = serve.Hub(), serve.AudioHub()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), serve.make_handler(hub, lambda: [], audio=audio))
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    hub.publish({"tick": 1, "agents": []})

    def stream(path):
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n".encode())
        f = s.makefile("rb")
        assert b"200" in f.readline()
        while f.readline() not in (b"\r\n", b""):
            pass
        return s, f

    pages = [stream("/events?audio=1"), stream("/events?audio=1"), stream("/events?audio=1"), stream("/events")]
    for _, f in pages:  # every stream gets the snapshot first
        assert json.loads(read_events(f, "message"))["tick"] == 1
    meta = audio.push({"channel": "caster", "speaker": "ada", "text": "hello", "duration": 1.0}, b"RIFFclip", "audio/wav")
    for _, f in pages[:3]:
        clip = json.loads(read_events(f, "audio"))
        assert clip["id"] == meta["id"] and clip["url"] == meta["url"], clip
    # a fifth connection fetches the clip while all four streams are open
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", meta["url"])
    r = c.getresponse()
    assert r.status == 200 and r.read() == b"RIFFclip"
    hub.publish({"tick": 2, "agents": []})
    data = read_events(pages[3][1], "message")  # the replay page's plain stream: snapshots, never a clip
    assert json.loads(data)["tick"] == 2 and "url" not in json.loads(data)
    for s, _ in pages:
        s.close()
    srv.shutdown()


def main():
    n = static_check()
    live_check()
    print(f"connections: ok ({n} event streams for overlay, audio-test, portrait and replay on one host; "
          f"{LIMIT - n} left for clips)")


if __name__ == "__main__":
    main()
