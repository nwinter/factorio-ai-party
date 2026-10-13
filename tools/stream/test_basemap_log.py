#!/usr/bin/env python3
"""The basemap log for the site's time-lapse: python3 tools/stream/test_basemap_log.py

- save() writes runs/RUN/basemap/TICK.json with the grid, core and nests (no ore), at most one per 10 game minutes,
  and again after the world went back to an earlier tick;
- nothing without a run folder, rows or a tick;
- live.py saves after its basemap read; the logger's --once polls a state.json and writes the same file.
"""
import http.server, json, os, subprocess, sys, tempfile, threading

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import basemap_log  # noqa: E402


def bm(tick):
    return {"tick": tick, "cell": 8, "x0": -16, "y0": -16, "w": 4, "h": 2, "rows": ["..AB", "SS.."],
            "core": {"cell": 2, "x0": 0, "y0": 0, "w": 2, "h": 1, "rows": ["AB"]}, "nests": [[1, 2, "w"]],
            "ore": {"cell": 8, "rows": ["iiii"]}, "buildings": 12}


run = tempfile.mkdtemp()
assert basemap_log.save(run, bm(1000)).endswith(os.path.join("basemap", "1000.json"))
saved = json.load(open(os.path.join(run, "basemap", "1000.json")))
assert "ore" not in saved and "buildings" not in saved and saved["core"]["rows"] == ["AB"] and saved["nests"], saved
assert basemap_log.save(run, bm(1000 + 35999)) is None  # within 10 game minutes
assert basemap_log.save(run, bm(1000 + 36000))  # 10 minutes on
assert basemap_log.save(run, bm(500))  # an earlier save loaded: a new series
assert basemap_log.newest(run) == 37000
assert basemap_log.save(None, bm(99999)) is None and basemap_log.save(run, {"tick": 99999}) is None
assert basemap_log.save(run, dict(bm(99999), tick=None)) is None

# live.py saves after its basemap read, into the run folder (its journals dir; None writes nothing, as above)
import inspect  # noqa: E402
import live  # noqa: E402

assert 'basemap_log.save(self.journals, obs["basemap"])' in inspect.getsource(live.LiveSource)

# the logger: --once against a state.json
state = {"tick": 300000, "basemap": bm(300000)}


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(state).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
r = subprocess.run([sys.executable, os.path.join(HERE, "basemap_log.py"), run, "--once",
                    "--url", f"http://127.0.0.1:{srv.server_port}/state.json"], capture_output=True, text=True)
srv.shutdown()
assert r.returncode == 0 and os.path.exists(os.path.join(run, "basemap", "300000.json")), (r.stdout, r.stderr)
print("basemap log: ok (one per 10 game minutes, no ore, earlier save, live.py hook, logger --once)")
