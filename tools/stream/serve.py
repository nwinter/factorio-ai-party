#!/usr/bin/env python3
"""Stream overlay + director service (Mac side). Stdlib only.

  python3 tools/stream/serve.py --mock                         # synthetic 7-agent session
  python3 tools/stream/serve.py --world c --run tools/stream/runs/coop1.json
  python3 tools/stream/serve.py --world live --run RUN.json --cameras 3,4,5
  python3 tools/stream/serve.py --world live --run RUN.json --viewers-youtube @HANDLE --viewers-site   # + viewer chat
  python3 tools/stream/serve.py --mock --viewers-replay tools/stream/runs/viewers-sample.jsonl         # synthetic chat

Serves http://HOST:PORT/ (the overlay page for the OBS browser source), /state.json, /events (SSE, one full
snapshot per update), /director.json (recent camera decisions), and the voice queue: POST /audio (caster.py pushes
clips), /audio-events (SSE, new clips), GET /segments and POST /segment (timed shots for the casters and the
director, tools/stream/segments.py), /audio/clip/ID, POST /audio/played and /audio/status (page playback reports). Director decisions are appended to
tools/stream/logs/director-<start>.jsonl. Only read actions, the operator `camera` function and the operator
`highlights` drawing (seen by the camera clients alone, highlights.py; --no-highlights turns it off) are ever sent.
"""
import argparse, json, mimetypes, os, sys, threading, time, traceback
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

from analyst_board import AnalystBoard  # noqa: E402
from director import Director  # noqa: E402
from onecam import OneCam, onair_doing, onair_info  # noqa: E402
from segments import Segments  # noqa: E402
from replays import Replays  # noqa: E402
from model import Model  # noqa: E402

STATIC = os.path.join(HERE, "static")


def static_version(root=STATIC):
    """A short hash of the pages' files (contents, not mtimes): in every snapshot, so an overlay page loaded before a
    change reloads itself (the vertical canvas's browser source kept the three-camera page after eng/onecam)."""
    import hashlib
    h = hashlib.sha1()
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            if name.endswith((".js", ".css", ".html", ".json")):
                path = os.path.join(dirpath, name)
                h.update(os.path.relpath(path, root).encode())
                with open(path, "rb") as f:
                    h.update(f.read())
    return h.hexdigest()[:12]


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


class AudioHub:
    """Queued voice clips for the overlay page (pushed by caster.py, played by the OBS browser source).

    POST /audio {channel: caster|agent, speaker, text, audio_b64, ctype, duration, expires_in, ...} stores a clip and
    announces it on /audio-events. The page reports playback with POST /audio/played {id, state: start|end}, which
    caster.py reads from /audio/status to avoid talking over a clip that is still playing.
    """

    MAX_CLIPS = 120
    # Clips that ended early (viewer syndesis, shift14 23:04: "spoken lines cut off abruptly"): each report is logged
    # (log_path, beside stream.json) and a clip counts as ended early when it played EARLY_S or more short of its
    # length: cut (a line that mattered more), error, reload (the page loaded again while it played), no_end (no end
    # report within its length + 5 s: the page went away), or short_end (the page reported its end early: the audio
    # stopped by itself). The last hour's count is in the stream state (voice) and /audio/status.
    EARLY_S = 0.5
    WINDOW = 3600.0

    def __init__(self, log_path=None):
        self.cond = threading.Condition()
        self.clips = {}  # id -> (bytes, ctype, meta)
        self.order = []
        self.seq = 0
        self.playing = {}  # id -> {meta, started}
        self.listeners = 0
        self.last_report = None
        self.log_path = log_path
        self.ended = deque()  # (t, row) of the last hour's ends: {id, channel, speaker, agent, state, played, duration, early, reason}
        self.loads = deque()  # times the page loaded
        self._reload_log()

    def _reload_log(self):
        """The last hour's ends and page loads from the log (a service restart keeps the counter)."""
        if not self.log_path or not os.path.exists(self.log_path):
            return
        cutoff = time.time() - self.WINDOW
        try:
            with open(self.log_path) as f:
                lines = f.readlines()[-2000:]
        except OSError:
            return
        for line in lines:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if (r.get("t") or 0) < cutoff:
                continue
            if r.get("state") == "load":
                self.loads.append(r["t"])
            elif r.get("ended"):
                self.ended.append((r["t"], r))

    def _log(self, row):
        if not self.log_path:
            return
        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        except OSError:
            pass

    def _end(self, cid, v, state, now, played=None, duration=None, reason=None):
        """A clip's end: how long it played against its length, logged and counted (caller holds the lock)."""
        length = duration if duration is not None else v.get("audio_s") or v.get("duration")
        if state == "no_end":  # how long it played is not known: the page never said
            played = None
        elif not played:  # no page measure (or an audio clock that did not move): the time between its reports
            played = round(now - v["started"], 2)
        early = state in ("cut", "error", "reload", "no_end") or (length is not None and played < float(length) - self.EARLY_S)
        if state == "end" and early:
            reason = "short_end"
        row = {"t": round(now, 2), "id": cid, "ended": True, "state": state, "channel": v.get("channel"), "speaker": v.get("speaker"),
               "agent": v.get("agent"), "played": round(float(played), 2) if played is not None else None,
               "duration": round(float(length), 2) if length is not None else None,
               "early": bool(early), "reason": (reason or state) if early else None}
        self.ended.append((now, row))
        self._log(row)

    def _trim(self, now):
        while self.ended and now - self.ended[0][0] > self.WINDOW:
            self.ended.popleft()
        while self.loads and now - self.loads[0] > self.WINDOW:
            self.loads.popleft()

    def early(self, now=None):
        """The last hour: clips played, those that ended early (by reason, the agents' apart), the newest 5 of them,
        the page's loads, and skips (expired in the queue, never played)."""
        now = now or time.time()
        with self.cond:
            self._trim(now)
            rows = [r for _, r in self.ended]
            loads = len(self.loads)
        early = [r for r in rows if r["early"] and r["state"] != "skip"]
        played = [r for r in rows if r["state"] != "skip"]
        by_reason = {}
        for r in early:
            by_reason[r["reason"]] = by_reason.get(r["reason"], 0) + 1
        agents = [r for r in early if r.get("channel") == "agent"]
        newest = [{"ago_s": round(now - r["t"]), "speaker": r.get("speaker"), "channel": r.get("channel"),
                   "played": r["played"], "duration": r["duration"], "reason": r["reason"]} for r in early[-5:]][::-1]
        return {"ended_early_last_hour": len(early), "agent_ended_early_last_hour": len(agents), "played_last_hour": len(played),
                "agent_played_last_hour": sum(1 for r in played if r.get("channel") == "agent"),
                "by_reason": by_reason, "skipped_last_hour": sum(1 for r in rows if r["state"] == "skip"),
                "page_loads_last_hour": loads, "newest": newest,
                "line": f"voice: {len(early)} of {len(played)} clips ended early in the last hour"
                        + (f" ({', '.join(f'{k} {n}' for k, n in sorted(by_reason.items()))})" if by_reason else "")
                        + f"; agents {len(agents)} of {sum(1 for r in played if r.get('channel') == 'agent')}"}

    def push(self, meta, audio, ctype):
        with self.cond:
            self.seq += 1
            cid = f"{int(time.time())}-{self.seq}"
            meta = dict(meta, id=cid, url=f"/audio/clip/{cid}", t=time.time())
            meta["expires"] = meta["t"] + float(meta.pop("expires_in", 30))
            self.clips[cid] = (audio, ctype, meta)
            self.order.append(cid)
            while len(self.order) > self.MAX_CLIPS:
                self.clips.pop(self.order.pop(0), None)
            self.cond.notify_all()
            return meta

    def wait(self, seq, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != seq, timeout=timeout)
            return self.seq, [self.clips[c][2] for c in self.order if int(c.split("-")[1]) > seq and c in self.clips]

    def played(self, report, now=None):
        cid, st = report.get("id"), report.get("state")
        now = now or time.time()

        def num(k):
            v = report.get(k)
            return float(v) if isinstance(v, (int, float)) else None
        with self.cond:
            self.last_report = now
            if st == "load":  # the page (re)loaded: what it was playing ended there
                self.loads.append(now)
                self._log({"t": round(now, 2), "state": "load"})
                for k, v in list(self.playing.items()):
                    self._end(k, v, "reload", now)
                    self.playing.pop(k)
            elif cid in self.clips and st == "start":
                self.playing[cid] = {"started": now, **self.clips[cid][2], "audio_s": num("duration")}
            elif st in ("end", "error", "cut"):  # cut: a line that mattered more faded this one out
                v = self.playing.pop(cid, None)
                if v:
                    self._end(cid, v, st, now, num("played"), num("duration"))
            elif st == "skip":  # expired in the page's queue: never played
                self.playing.pop(cid, None)
                meta = self.clips.get(cid, (None, None, {}))[2]
                row = {"t": round(now, 2), "id": cid, "ended": True, "state": "skip", "channel": meta.get("channel"),
                       "speaker": meta.get("speaker"), "agent": meta.get("agent"), "played": 0.0,
                       "duration": meta.get("duration"), "early": False, "reason": None}
                self.ended.append((now, row))
                self._log(row)
            # a page that goes away mid-clip never reports the end; forget clips well past their length
            for k, v in list(self.playing.items()):
                if now - v["started"] > float(v.get("audio_s") or v.get("duration") or 20) + 5:
                    self._end(k, v, "no_end", now, played=None)
                    self.playing.pop(k)

    def status(self):
        now = time.time()
        with self.cond:
            playing = [{"id": k, "channel": v.get("channel"), "speaker": v.get("speaker"),
                        "ends_in": round(max(0.0, v["started"] + float(v.get("duration") or 0) - now), 2)}
                       for k, v in self.playing.items() if now - v["started"] <= float(v.get("duration") or 20) + 5]
            out = {"listeners": self.listeners, "playing": playing, "last_report": self.last_report,
                   "clips": len(self.order)}
        out["voice"] = self.early(now)
        return out


def make_handler(hub, decisions, audio=None, segments=None, replays=None, analyst=None, follow=None, director=None,
                 platform=None, look=None, show=None):
    audio = audio or AudioHub()
    segments = segments or Segments()
    analyst = analyst or AnalystBoard()

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
            elif path in ("/portrait", "/portrait.html"):  # 1080x1920 page for a 9:16 canvas (docs/STREAM-NOTES.md)
                path = "/static/portrait.html"
            elif path in ("/replay", "/replay.html"):  # REPLAY banner page for the OBS replay scene (replays.py)
                path = "/static/replay.html"
            if path == "/state.json":
                return self.send(200, hub.payload, "application/json; charset=utf-8")
            if path == "/director.json":
                return self.send(200, json.dumps(list(decisions())).encode(), "application/json")
            if path == "/events":
                return self.events()
            if path == "/audio-events":
                return self.audio_events()
            if path == "/replays.json":
                body = replays.public() if replays else {"enabled": False}
                return self.send(200, json.dumps(body).encode(), "application/json")
            if path == "/segments":
                return self.send(200, json.dumps(segments.types()).encode(), "application/json")
            if path == "/audio/status":
                return self.send(200, json.dumps(audio.status()).encode(), "application/json")
            if path == "/analyst.json":
                return self.send(200, json.dumps(analyst.full(), ensure_ascii=False).encode(), "application/json; charset=utf-8")
            if path.startswith("/audio/clip/"):
                clip = audio.clips.get(path.rsplit("/", 1)[-1])
                if clip:
                    return self.send(200, clip[0], clip[1])
            if path.startswith("/static/"):
                full = os.path.normpath(os.path.join(STATIC, path[len("/static/"):]))
                if full.startswith(STATIC) and os.path.isfile(full):
                    ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
                    if ctype.startswith("text/") or ctype.endswith("javascript"):
                        ctype += "; charset=utf-8"
                    return self.send(200, open(full, "rb").read(), ctype)
            self.send(404, b"not found", "text/plain")

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            n = int(self.headers.get("Content-Length") or 0)
            if n > 8 << 20:
                return self.send(413, b"too large", "text/plain")
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self.send(400, b"bad json", "text/plain")
            if path == "/audio":
                import base64
                try:
                    data = base64.b64decode(body.pop("audio_b64"))
                except (KeyError, ValueError):
                    return self.send(400, b"audio_b64 missing", "text/plain")
                ctype = body.pop("ctype", "audio/mpeg")
                meta = audio.push(body, data, ctype)
                return self.send(200, json.dumps(meta).encode(), "application/json")
            if path == "/segment":
                code, reply = segments.request(body)
                return self.send(code, json.dumps(reply, ensure_ascii=False).encode(), "application/json")
            if path == "/audio/played":
                audio.played(body)
                return self.send(200, b"{}", "application/json")
            if path == "/analyst":  # tools/stream/analyst.py posts each cycle
                return self.send(200, json.dumps(analyst.post(body)).encode(), "application/json")
            if path == "/analyst/used":
                return self.send(200, json.dumps(analyst.mark_used(body.get("id"))).encode(), "application/json")
            if path == "/analyst/answer":  # a viewer question the analyst answered, for the hosts (snapshot analyst.answers)
                return self.send(200, json.dumps(analyst.answer(body)).encode(), "application/json")
            if path == "/cloud":  # the operator puts a pollution or spore cloud on air (onecam.py cloud shot)
                if not hasattr(director, "request_cloud"):
                    return self.send(409, b'{"error": "cloud needs the onecam director"}', "application/json")
                code, reply = director.request_cloud(body.get("surface"), body.get("seconds"), body.get("by"))
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if path == "/follow":  # the operator pins the camera on air on one agent (follow.py)
                if not follow:
                    return self.send(409, b'{"error": "follow needs the onecam director"}', "application/json")
                code, reply = follow.request(body)
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if path == "/platform":
                if not platform:
                    return self.send(409, b'{"error": "platform needs the onecam director"}', "application/json")
                code, reply = platform.request(body)
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if path == "/look":  # the operator points the camera on air at a charted spot (lookcam.py)
                if not look:
                    return self.send(409, b'{"error": "look needs the onecam director"}', "application/json")
                code, reply = look.request(body)
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if path == "/show":  # the operator puts a PNG from runs/ over the main camera (show.py)
                if not show:
                    return self.send(409, b'{"error": "show needs OBS (not in --mock)"}', "application/json")
                code, reply = show.request(body)
                return self.send(code, json.dumps(reply, ensure_ascii=False).encode(), "application/json")
            self.send(404, b"not found", "text/plain")

        def do_DELETE(self):
            if self.path.split("?", 1)[0] == "/show" and show:
                code, reply = show.clear()
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if self.path.split("?", 1)[0] == "/look" and look:
                code, reply = look.clear()
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if self.path.split("?", 1)[0] == "/platform" and platform:
                code, reply = platform.clear()
                return self.send(code, json.dumps(reply).encode(), "application/json")
            if self.path.split("?", 1)[0] == "/follow" and follow:
                code, reply = follow.clear()
                return self.send(code, json.dumps(reply).encode(), "application/json")
            self.send(404, b"not found", "text/plain")

        def sse_head(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

        def audio_events(self):
            """New clips only (a page that reconnects does not replay old lines)."""
            self.sse_head()
            seq = audio.seq
            with audio.cond:
                audio.listeners += 1
            try:
                self.wfile.write(b": hello\n\n")
                self.wfile.flush()
                while True:
                    new, clips = audio.wait(seq, 15)
                    if new == seq:
                        self.wfile.write(b": keepalive\n\n")
                    seq = new
                    for c in clips:
                        self.wfile.write(b"data: " + json.dumps(c, ensure_ascii=False).encode() + b"\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return
            finally:
                with audio.cond:
                    audio.listeners -= 1

        def events(self):
            """Snapshots as plain `data:` lines; with ?audio=1 also new voice clips as `event: audio` on the same
            stream. A browser keeps at most 6 connections per host, and every open SSE holds one: in shake7 the
            overlay, portrait and audio-test pages each held /events and /audio-events, all 6 were taken and the
            voice clips never downloaded (the hosts were silent). One stream per page leaves room for the clips."""
            want_audio = "audio=1" in (self.path.split("?", 1)[1] if "?" in self.path else "")
            self.sse_head()
            version, seq, quiet = -1, audio.seq, time.time()
            if want_audio:
                with audio.cond:
                    audio.listeners += 1
            try:
                while True:
                    # with audio, wake often so a clip goes out within ~0.25 s (snapshots come once a second)
                    new, payload = hub.wait(version, 0.25 if want_audio else 15)
                    wrote = False
                    if new != version:
                        version = new
                        self.wfile.write(b"data: " + payload + b"\n\n")
                        wrote = True
                    if want_audio:
                        seq_new, clips = audio.wait(seq, 0)
                        seq = seq_new
                        for c in clips:
                            self.wfile.write(b"event: audio\ndata: " + json.dumps(c, ensure_ascii=False).encode() + b"\n\n")
                            wrote = True
                    if wrote:
                        quiet = time.time()
                    elif time.time() - quiet >= 15:
                        self.wfile.write(b": keepalive\n\n")
                        quiet = time.time()
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return
            finally:
                if want_audio:
                    with audio.cond:
                        audio.listeners -= 1

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
    ap.add_argument("--no-highlights", action="store_true",
                    help="never draw the camera highlights (rings and labels on what agents act on, highlights.py)")
    ap.add_argument("--profiles", choices=["auto", "on", "off"], default="auto",
                    help="poll `profiles` (auto: only when the harness has the eng/bots camera function)")
    ap.add_argument("--mock-speed", type=float, default=4.0, help="mock: game seconds per wall second")
    ap.add_argument("--mock-start", type=float, default=40.0, help="mock: game minute to start the replay at")
    ap.add_argument("--replays", dest="replays", action="store_true", default=None,
                    help="instant replays through the OBS replay buffer (default: on with --world, off with --mock)")
    ap.add_argument("--no-replays", dest="replays", action="store_false")
    ap.add_argument("--night", dest="night", action="store_true", default=None,
                    help="night lift: brighten the game captures in OBS when the game is dark (default: on with "
                         "--world, off with --mock)")
    ap.add_argument("--no-night", dest="night", action="store_false")
    ap.add_argument("--obs", default="127.0.0.1:4455", help="obs-websocket host:port (the SSH tunnel to the box)")
    ap.add_argument("--cams", choices=["onecam", "3cam"],
                    help="onecam: one camera on air, the other clients on standby, cut in OBS (onecam.py, cuts.py); "
                         "3cam: main + two side cameras (default: the run config's camera_mode, else onecam)")
    ap.add_argument("--no-cuts", action="store_true", help="onecam: decide on-air cuts but never touch OBS")
    ap.add_argument("--trio", action="store_true", help="onecam: the three-tile layout whenever three agents can fill "
                                                         "it, held (mock screenshots of it)")
    ap.add_argument("--log-dir", default=os.path.join(HERE, "logs"))
    import viewers
    viewers.add_args(ap.add_argument_group("viewer chat (tools/stream/viewers.py; snapshot lane `viewers`)"),
                     prefix="viewers-")
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
        # the agents' fh journals (runs/RUN/AGENT/journal.jsonl) sit beside the run's stream.json: work.py tails them
        source = LiveSource(a.world, run, profiles=a.profiles,
                            journals=os.path.dirname(os.path.abspath(a.run)) if a.run else None)
        camera = source.send_camera
    if a.no_camera:
        camera = lambda body: {"ok": False, "stub": True, "disabled": True}  # noqa: E731
    # what agents act on, drawn for the camera clients only (highlights.py, the harness's operator `highlights`)
    highlights = None
    if not a.mock and not a.no_camera and not a.no_highlights and run.get("highlights", True) is not False:
        from highlights import Highlights
        highlights = Highlights(source.send_highlights)

    os.makedirs(a.log_dir, exist_ok=True)
    log_path = os.path.join(a.log_dir, time.strftime("director-%Y%m%d-%H%M%S.jsonl"))
    mode = a.cams or run.get("camera_mode") or "onecam"
    cuts = None
    if mode == "onecam":
        import cuts as cuts_mod
        lay = json.load(open(cuts_mod.LAYOUT))
        frac = {"view_frac": cuts_mod.view_frac(lay), "trio_frac": cuts_mod.view_frac(json.load(open(cuts_mod.TRIO)))}
        if a.trio:
            frac.update(trio_force=True)
        director = OneCam(slots, camera, log_path, **dict(frac, **(run.get("director") or {})))
        if a.run and not a.mock:  # the run's own attack history scales the threat scores (threats.py)
            director.set_threat_history(os.path.join(os.path.dirname(os.path.abspath(a.run)), "threat-history.json"))
            # when an agent first stood on each planet (game ticks), kept across restarts and shifts (surface balance)
            director.set_surface_memory(os.path.join(os.path.dirname(os.path.abspath(a.run)), "surface-seen.json"))
        if not a.mock and not a.no_cuts and run.get("cuts", True) is not False:
            from obsws import OBS
            host, _, port = a.obs.partition(":")
            # the captures of the director's clients only (POG_CAMS=1: "stream cam1" alone; tools/cams.py)
            names = [s["slot"] for s in slots]
            cuts = cuts_mod.Cuts(OBS(host, int(port or 4455)), lay, slots=names,
                                 sources=["stream cam1" if n == "main" else f"stream {n}" for n in names])
    else:
        director = Director(slots, camera, log_path, **(run.get("director") or {}))
    segments = Segments(**(run.get("segments") or {}))
    replays = None
    if (a.replays if a.replays is not None else not a.mock) and run.get("replays", True) is not False:
        from obsws import OBS
        host, _, port = a.obs.partition(":")
        replays = Replays(segments, obs=OBS(host, int(port or 4455)), **(run.get("replays") or {}))
    show = None
    if not a.mock and run.get("show", True) is not False:  # an image over the main camera (POST /show)
        from obsws import OBS
        from show import Show
        host, _, port = a.obs.partition(":")
        show = Show(OBS(host, int(port or 4455)), json.load(open(os.path.join(STATIC, "layout.json"))))
    night = None
    if (a.night if a.night is not None else not a.mock) and run.get("night", True) is not False:
        from obsws import OBS
        from nightlift import NightLift
        host, _, port = a.obs.partition(":")
        night = NightLift(obs=OBS(host, int(port or 4455)), **(run.get("night") or {}))
    model = Model(run)
    # token use per agent this shift, from the agents' CLI session logs (tokens.py): a thread of its own reads them
    tokens_feed = None
    if run.get("tokens", True) is not False:
        if a.mock:
            from mock import MockTokens
            tokens_feed = MockTokens(run)
        elif a.run:
            import tokens
            tokens_feed = tokens.TokenFeed(os.path.dirname(os.path.abspath(a.run))).start()
    if a.run and not a.mock:  # where each platform has been, kept across restarts (no false "first" arrivals)
        model.set_space_memory(os.path.join(os.path.dirname(os.path.abspath(a.run)), "space-memory.json"))
        # each platform's creation and departures along the run chain: a first departure is a maiden flight
        import chronicle_log
        model.set_platform_history(chronicle_log.path_for(os.path.dirname(os.path.abspath(a.run))))
    hub = Hub()
    names = [n for k, cfg in (run.get("agents") or {}).items() for n in (k, (cfg or {}).get("display_name")) if n]
    roster = [(k, (cfg or {}).get("display_name")) for k, cfg in (run.get("agents") or {}).items()]
    # viewer lines to the operator ("Operator, ...") go to the run's operator inbox, beside stream.json (not in mock)
    import operator_inbox
    inbox = operator_inbox.path_for(os.path.dirname(os.path.abspath(a.run))) if a.run and not a.mock else None
    model.set_inbox(inbox)  # the Operator's replies thread under those lines too (viewer_replies.py)
    # YouTube deletions, with what they remove, beside it: the site leaves those lines out (site/moderation.py)
    deletions = os.path.join(os.path.dirname(os.path.abspath(a.run)), "viewer-deletions.jsonl") if a.run and not a.mock else None
    feed = viewers.build(a, "viewers_", names, harness=getattr(source, "h", None), log_dir=a.log_dir, loop=a.mock,
                         roster=roster, inbox=inbox, deletions=deletions)
    if feed:
        feed.start()
    # the site's polls (pollstrip.py; RUN/polls.json from site/polls_relay.py): the overlay's strip, the hosts' fact
    import pollstrip
    polls = pollstrip.PollStrip(os.path.join(os.path.dirname(os.path.abspath(a.run)), "polls.json")) \
        if a.run and not a.mock else None
    analyst = AnalystBoard()
    # the voice clips; the director reads which agent line is playing (say look= cues). The page's playback reports go
    # to audio-played.jsonl beside stream.json (the clips that ended early, and why)
    audio = AudioHub(os.path.join(os.path.dirname(os.path.abspath(a.run)), "audio-played.jsonl") if a.run and not a.mock else None)
    follow = platform = look = None
    if mode == "onecam":  # an operator follow, kept beside stream.json so a restart keeps it (follow.py)
        from follow import FollowControl
        from platformcam import PlatformControl
        follow = FollowControl(director, os.path.join(os.path.dirname(os.path.abspath(a.run)), "director-follow.json")
                               if a.run and not a.mock else None, roster)
        platform = PlatformControl(director, os.path.join(os.path.dirname(os.path.abspath(a.run)), "director-platform.json")
                                   if a.run and not a.mock else None)
        import lookcam  # the chart check reads the game; the mock has no chart, so every spot counts as charted
        h = getattr(source, "h", None)
        chart = lookcam.harness_chart(h) if h else (lookcam.mock_chart if a.mock else None)
        look = lookcam.LookControl(director, os.path.join(os.path.dirname(os.path.abspath(a.run)), "director-look.json")
                                   if a.run and not a.mock else None, chart)
    lock = threading.Lock()
    source_info = {"source": getattr(source, "name", "mock"), "poll_ok": None, "poll_error": None}

    def poller():
        while True:
            t = time.time()
            try:
                obs = source.observe()
                with lock:
                    model.ingest(obs, time.time())
                    if tokens_feed:
                        model.set_tokens(tokens_feed.snapshot())
                source_info.update(poll_ok=time.time(), poll_error=None)
            except Exception as e:
                source_info["poll_error"] = f"{type(e).__name__}: {e}"
                traceback.print_exc()
            time.sleep(max(0.2, a.poll - (time.time() - t)))

    # Artillery shells in flight (onecam maybe_artillery; viewer Foobator 12:48): the harness's artillery_live read on
    # its own pace (every half second while a piece is loaded with targets in range, else 10 s), since a shell is up
    # under 4 s and the main poll comes every few seconds; a new shell wakes the ticker at once.
    arty = {"res": None}
    wake = threading.Event()

    def artillery_poller():
        seen = set()
        while True:
            every = 10.0
            h = getattr(source, "h", None)
            if h and getattr(source, "has_artillery", False):
                try:
                    res, _ = h.operator_read("artillery_live", {})
                    res["read_at"] = time.time()
                    with lock:
                        arty["res"] = res
                    every = max(0.5, float(res.get("every") or 10.0))
                    new = [x["key"] for x in res.get("shells") or [] if x.get("key") and x["key"] not in seen]
                    if new:
                        seen.update(new)
                        if len(seen) > 2000:
                            seen = set(new)
                        wake.set()
                except Exception as e:
                    print(f"[artillery] read failed: {type(e).__name__}: {e}", flush=True)
                    every = 30.0
            time.sleep(every)

    page_version = static_version()

    def ticker():
        cams = {}
        while True:
            now = time.time()
            try:
                with lock:
                    snap = model.snapshot(now, cams)
                    snap["artillery"] = arty["res"]
                snap["segment"] = segments.step(snap, now)
                if mode == "onecam":  # no layout change while a replay is (about to be) on air
                    cur = segments.cur
                    director.hold_layout = bool(replays and replays.playing) or bool(
                        cur and cur["type"] == "attack_replay" and cur["state"] in ("starting", "live"))
                if follow:
                    follow.sync(now)
                if platform:
                    platform.sync(now)
                if look:
                    look.sync(now)
                with audio.cond:  # agent lines playing now (the page's start reports): onecam cues their looks
                    snap["voiced"] = [dict(v, id=k) for k, v in audio.playing.items() if v.get("channel") == "agent"]
                snap["voice"] = audio.early(now)  # clips that ended early in the last hour, and why (operator read)
                cams = director.step(snap, now, segments.camera())
                if follow:
                    snap["follow"] = director.follow_info(now)  # the hosts: who the operator pinned on air, and why
                if platform:
                    snap["platform_hold"] = director.platform_info(now)
                if look:
                    snap["look"] = director.look_info(now)
                if show:
                    snap["show"] = show.public()  # an image over the main camera: the page's caption, the hosts
                if hasattr(director, "battle_info"):
                    snap["battle"] = director.battle_info(now)  # a key battle held on air (replays.py covers it)
                if director.last_attack_cut == now:  # main just cut to a fight or death: the segment gives way
                    segments.attack_cut(now)
                    snap["segment"] = segments.public()
                    if replays and not (getattr(director, "fol", None) or getattr(director, "plat", None)
                                        or getattr(director, "look", None)):
                        replays.on_attack_cut(director.last_attack_alert, snap, now, director.last_attack_framed)
                if replays:
                    replays.hold = bool(getattr(director, "fol", None) or getattr(director, "plat", None)
                                        or getattr(director, "look", None))
                    replays.tick(snap, cams, now)
                    snap["replay"] = replays.public()
                if night:
                    night.set_darkness(snap.get("darkness"))
                    snap["night"] = night.public()
                snap["cameras"] = cams
                if mode == "onecam":
                    snap["onair"] = onair_info(snap, cams)  # who viewers watch: the label, the hosts' beats
                    snap["onair"]["layout"] = director.layout_info()  # one camera or three tiles (the hosts, the page)
                    for row in cams.values():  # each tile's label: "Luna · fixing the north wall"
                        if len(row.get("agents") or []) == 1:
                            row["doing"] = onair_doing(snap, row["agents"][0])
                    snap["program"] = director.program()
                    if cuts:
                        cuts.set(snap["program"])
                        snap["cuts"] = cuts.public()
                for ag in snap["agents"]:
                    ag["camera"] = next((s for s, c in cams.items() if ag["name"] in c["agents"]), None)
                snap.update(source_info)
                snap["static_version"] = page_version
                snap["viewers"], snap["viewers_status"] = feed.lane() if feed else ([], None)
                if feed:  # viewers may not pose as an agent under the name it chose either
                    feed.filt.set_agents(names + [n for ag in snap["agents"] for n in (ag["name"], ag.get("display_name"))])
                if feed and feed.relay:  # viewers' questions go to agents in team order, by their chosen names too
                    feed.relay.set_roster([(ag["name"], ag.get("display_name")) for ag in snap["agents"]
                                           if ag.get("activity") != "offline"] or roster)
                snap["analyst"] = analyst.public(now)
                snap["poll"] = polls.step(now) if polls else None
                if highlights:
                    highlights.step(snap, now)
                    snap["highlights"] = highlights.public()
                hub.publish(snap)
            except Exception:
                traceback.print_exc()
            # a cut timed for an artillery impact steps sooner; a new shell wakes it at once (artillery_poller)
            soon = director.next_wake(time.time()) if hasattr(director, "next_wake") else None
            wake.wait(1.0 if soon is None else min(1.0, soon))
            wake.clear()

    def decisions(n=60):
        try:
            with open(log_path) as f:
                return [json.loads(l) for l in f.readlines()[-n:]]
        except FileNotFoundError:
            return []

    threading.Thread(target=poller, daemon=True).start()
    if getattr(source, "h", None):
        threading.Thread(target=artillery_poller, daemon=True).start()
    threading.Thread(target=ticker, daemon=True).start()
    try:
        server = ThreadingHTTPServer((a.host, a.port), make_handler(hub, decisions, segments=segments, replays=replays,
                                                                    analyst=analyst, follow=follow, audio=audio,
                                                                    director=director, platform=platform, look=look,
                                                                    show=show))
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
