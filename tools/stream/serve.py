#!/usr/bin/env python3
"""Stream overlay + director service (Mac side). Stdlib only.

  python3 tools/stream/serve.py --mock                         # synthetic 7-agent session
  python3 tools/stream/serve.py --world c --run tools/stream/runs/coop1.json
  python3 tools/stream/serve.py --world live --run RUN.json --cameras 3,4,5

Serves http://HOST:PORT/ (the overlay page for the OBS browser source), /state.json, /events (SSE, one full
snapshot per update), /director.json (recent camera decisions). Director decisions are appended to
tools/stream/logs/director-<start>.jsonl. Only read actions and the operator `camera` function are ever sent.
"""
import argparse, json, mimetypes, os, sys, threading, time, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

from director import Director  # noqa: E402
from model import Model  # noqa: E402

STATIC = os.path.join(HERE, "static")


class Hub:
    """Latest snapshot plus a condition that SSE clients wait on."""

    def __init__(self):
        self.cond = threading.Condition()
        self.version = 0
        self.payload = b"{}"

    def publish(self, snapshot):
        data = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")).encode()
        with self.cond:
            self.version += 1
            self.payload = data
            self.cond.notify_all()

    def wait(self, version, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.version != version, timeout=timeout)
            return self.version, self.payload


def make_handler(hub, decisions):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet: OBS polls constantly
            pass

        def send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                path = "/static/index.html"
            if path == "/state.json":
                return self.send(200, hub.payload, "application/json; charset=utf-8")
            if path == "/director.json":
                return self.send(200, json.dumps(list(decisions())).encode(), "application/json")
            if path == "/events":
                return self.events()
            if path.startswith("/static/"):
                full = os.path.normpath(os.path.join(STATIC, path[len("/static/"):]))
                if full.startswith(STATIC) and os.path.isfile(full):
                    ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
                    if ctype.startswith("text/") or ctype.endswith("javascript"):
                        ctype += "; charset=utf-8"
                    return self.send(200, open(full, "rb").read(), ctype)
            self.send(404, b"not found", "text/plain")

        def events(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            version = -1
            try:
                while True:
                    new, payload = hub.wait(version, 15)
                    if new == version:
                        self.wfile.write(b": keepalive\n\n")
                    else:
                        version = new
                        self.wfile.write(b"data: " + payload + b"\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--mock", action="store_true", help="replay a synthetic 7-agent session")
    src.add_argument("--world", help="pog world to poll read-only (live, a, b, c, ...)")
    ap.add_argument("--run", help="run config JSON (agents: name -> model, harness, role; cameras; landmarks)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--poll", type=float, default=3.0, help="seconds between harness polls (2-5)")
    ap.add_argument("--cameras", help="director player indices, main first (e.g. 3,4,5); overrides the run config")
    ap.add_argument("--no-camera", action="store_true", help="decide and log but never call the camera function")
    ap.add_argument("--profiles", choices=["auto", "on", "off"], default="auto",
                    help="poll `profiles` (auto: only when the harness has the eng/bots camera function)")
    ap.add_argument("--mock-speed", type=float, default=4.0, help="mock: game seconds per wall second")
    ap.add_argument("--mock-start", type=float, default=40.0, help="mock: game minute to start the replay at")
    ap.add_argument("--log-dir", default=os.path.join(HERE, "logs"))
    a = ap.parse_args()

    run_path = a.run or os.path.join(HERE, "runs", "mock9.json" if a.mock else "coop1.json")
    run = json.load(open(run_path))
    slots = run.get("cameras") or [{"slot": "main", "player": 3}, {"slot": "cam2", "player": 4},
                                   {"slot": "cam3", "player": 5}]
    if a.cameras:
        slots = [{"slot": n, "player": int(p)} for n, p in zip(["main", "cam2", "cam3"], a.cameras.split(","))]

    if a.mock:
        from mock import MockSource
        source = MockSource(run, speed=a.mock_speed, start_min=a.mock_start)
        camera = lambda body: {"ok": False, "stub": True, "mock": True}  # noqa: E731
    else:
        from live import LiveSource
        source = LiveSource(a.world, run, profiles=a.profiles)
        camera = source.send_camera
    if a.no_camera:
        camera = lambda body: {"ok": False, "stub": True, "disabled": True}  # noqa: E731

    os.makedirs(a.log_dir, exist_ok=True)
    log_path = os.path.join(a.log_dir, time.strftime("director-%Y%m%d-%H%M%S.jsonl"))
    director = Director(slots, camera, log_path, **(run.get("director") or {}))
    model = Model(run)
    hub = Hub()
    lock = threading.Lock()
    source_info = {"source": getattr(source, "name", "mock"), "poll_ok": None, "poll_error": None}

    def poller():
        while True:
            t = time.time()
            try:
                obs = source.observe()
                with lock:
                    model.ingest(obs, time.time())
                source_info.update(poll_ok=time.time(), poll_error=None)
            except Exception as e:
                source_info["poll_error"] = f"{type(e).__name__}: {e}"
                traceback.print_exc()
            time.sleep(max(0.2, a.poll - (time.time() - t)))

    def ticker():
        cams = {}
        while True:
            now = time.time()
            try:
                with lock:
                    snap = model.snapshot(now, cams)
                cams = director.step(snap, now)
                snap["cameras"] = cams
                for ag in snap["agents"]:
                    ag["camera"] = next((s for s, c in cams.items() if ag["name"] in c["agents"]), None)
                snap.update(source_info)
                hub.publish(snap)
            except Exception:
                traceback.print_exc()
            time.sleep(1.0)

    def decisions(n=60):
        try:
            with open(log_path) as f:
                return [json.loads(l) for l in f.readlines()[-n:]]
        except FileNotFoundError:
            return []

    threading.Thread(target=poller, daemon=True).start()
    threading.Thread(target=ticker, daemon=True).start()
    try:
        server = ThreadingHTTPServer((a.host, a.port), make_handler(hub, decisions))
    except OSError as e:
        sys.exit(f"cannot listen on {a.host}:{a.port}: {e}. Pick another --port and point the reverse tunnel at it: "
                 f"ssh -N -R 8787:127.0.0.1:PORT pogwin")
    server.daemon_threads = True
    print(f"[stream] {source_info['source']} on http://{a.host}:{a.port}/  run={os.path.relpath(run_path)}  "
          f"director log {os.path.relpath(log_path)}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
