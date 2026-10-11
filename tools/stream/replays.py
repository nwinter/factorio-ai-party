"""Instant replays from the OBS replay buffer (operator go-ahead in REPLAYS.md; docs/STREAM-NOTES.md "Replays").

Factorio cannot rewind in multiplayer, so the replay is OBS's: the replay buffer keeps the last ~45 s of the program
output. A clip is only worth showing when the main camera was already on the action, so:

  - fight / base attack: the director cut main to it; when the attack hold is nearly over (cut + 17 s) the buffer is
    saved and the last ~15 s (the fight as the camera followed it) are replayed;
  - death: if the main camera showed that agent in the 10 s before, save 5 s after and replay 11 s before to 4 s after.

The clip plays as an `attack_replay` segment (segments.py), so the casters see it and talk over it: on "live" the
program scene switches to the "replay" scene (the clip, muted, under a REPLAY banner page; the stream overlay rides
along off-canvas so the casters' voices keep playing), and when the segment ends or is cut the program goes back to
"stream". A watchdog returns to "stream" whenever "replay" is on air without a replay playing.
"""
import itertools, json, threading, time, traceback
from collections import deque

from obsws import OBS, OBSError

DEFAULTS = {
    "scene": "replay",             # created on first connect if missing
    "stream_scene": "stream",      # always returned to
    "media": "replay clip",        # ffmpeg_source in the replay scene
    "banner": "replay banner",     # browser source with /replay (REPLAY banner)
    "overlay_input": "stream overlay",  # the live overlay's browser source (voices), added off-canvas
    "fight_after": 17.0,           # save this long after an attack cut (attack_hold is 20 s)
    "fight_show": 15.0,            # seconds of the fight shown
    "death_before": 11.0,          # replay window around a death
    "death_after": 4.0,
    "death_save_after": 5.0,
    "seen_window": 10.0,           # a death replays only if main showed that agent this recently
    "spacing": 120.0,              # at most one replay this often
    "max_age": 120.0,              # a clip not played within this long is dropped
    "stats_every": 30.0,
}


class Replays:
    def __init__(self, segments, overlay_url="http://127.0.0.1:8787/replay", obs=None, log=print, start=True, **cfg):
        self.cfg = dict(DEFAULTS, **{k: v for k, v in cfg.items() if v is not None})
        self.segments = segments
        segments.replays = self
        self.overlay_url = overlay_url
        self.obs = obs or OBS()
        self.log = log
        self.lock = threading.Lock()
        self.ids = itertools.count(1)
        self.pending = None      # {kind, label, agent, save_at, show_from, show_to}
        self.clip = None         # saved, not yet played: {id, path, saved_t, show_from, show_to, label, kind, agent}
        self.playing = None      # clip id on air
        self.last_replay = -1e9
        self.main_seen = deque(maxlen=60)  # (t, [agents on main])
        self.status = {"enabled": True, "connected": False, "buffer_active": None, "error": None, "stats": None,
                       "replays": 0, "last": None, "program": None}
        self.prev_stats = None
        self.next_stats = 0
        self.next_buffer_try = 0
        self.scene_ready = False
        self.next_watch = 0
        self.refreshed = None  # segment id whose banner page was reloaded
        if start:  # selftest drives work() by hand
            threading.Thread(target=self.run, daemon=True).start()

    # ---- availability for segments.py --------------------------------------------------------------------------
    def why(self, now=None):
        now = now or time.time()
        if not self.status["connected"]:
            return "OBS not connected" + (f" ({self.status['error']})" if self.status["error"] else "")
        if not self.status["buffer_active"]:
            return "OBS replay buffer not running"
        if not self.clip or now - self.clip["show_to"] > self.cfg["max_age"]:
            return "no fresh clip (one is saved after a fight or death on the main camera)"
        return None

    def facts(self, now):
        c = self.clip
        return {"event": c["label"], "kind": c["kind"], "agent": c.get("agent_name"),
                "seconds": round(c["show_to"] - c["show_from"]), "ago_s": round(now - c["show_to"])}, c["id"]

    # ---- hooks from serve.py's ticker ---------------------------------------------------------------------------
    def tick(self, snap, cams, now):
        main = (cams or {}).get("main") or {}
        self.main_seen.append((now, list(main.get("agents") or [])))

    def on_attack_cut(self, alert, snap, now):
        """The director just cut main to a fight, base attack, loss or death."""
        if not alert or now - self.last_replay < self.cfg["spacing"]:
            return
        with self.lock:
            if alert["kind"] == "death":
                name = alert.get("agent")
                seen = any(name in agents for t, agents in self.main_seen if now - t <= self.cfg["seen_window"])
                if not name or not seen:
                    return  # it died off camera: there is nothing in the buffer worth showing
                ag = next((a for a in snap.get("agents") or [] if a["name"] == name), {})
                self.pending = {"kind": "death", "label": alert["text"], "agent": name,
                                "agent_name": ag.get("display_name") or name, "save_at": now + self.cfg["death_save_after"],
                                "show_from": now - self.cfg["death_before"], "show_to": now + self.cfg["death_after"]}
            elif not self.pending:  # a death already pending wins over the fight around it
                save = now + self.cfg["fight_after"]
                ag = next((a for a in snap.get("agents") or [] if a["name"] == alert.get("agent")), {})
                self.pending = {"kind": alert["kind"], "label": alert["text"], "agent": alert.get("agent"),
                                "agent_name": ag.get("display_name"), "save_at": save,
                                "show_from": save - self.cfg["fight_show"], "show_to": save}
            self.log(f"[replays] pending {self.pending['kind']}: {self.pending['label']}")

    # ---- worker ------------------------------------------------------------------------------------------------
    def run(self):
        while True:
            try:
                self.work(time.time())
            except (OSError, OBSError) as e:
                self.status.update(connected=False, error=str(e)[:200])
                self.scene_ready = False
                time.sleep(5)
            except Exception as e:
                self.status["error"] = f"{type(e).__name__}: {e}"[:200]
                traceback.print_exc()
                time.sleep(2)
            time.sleep(0.5)

    def work(self, now):
        o = self.obs
        if not self.scene_ready:
            self.ensure_scene()
            self.scene_ready = True
            self.status.update(connected=True, error=None)
        if now >= self.next_stats:
            self.next_stats = now + self.cfg["stats_every"]
            self.read_stats()
        if not self.status["buffer_active"]:  # re-read every loop until it runs (it takes a moment to start)
            self.status["buffer_active"] = o.call("GetReplayBufferStatus").get("outputActive")
            if not self.status["buffer_active"] and now >= self.next_buffer_try:
                self.next_buffer_try = now + 60
                try:
                    o.call("StartReplayBuffer")
                    self.log("[replays] started the OBS replay buffer")
                except OBSError as e:
                    self.status["error"] = str(e)[:200]
        with self.lock:
            p = self.pending
        if p and now >= p["save_at"] and self.status["buffer_active"]:
            self.save(p, now)
        self.offer(now)
        self.follow_segment(now)

    def save(self, p, now):
        o = self.obs
        try:
            before = o.call("GetLastReplayBufferReplay").get("savedReplayPath")
        except OBSError:  # nothing saved yet this OBS session
            before = None
        saved_t = now  # the clip ends here (the worker's clock, within a second of SaveReplayBuffer)
        o.call("SaveReplayBuffer")
        path = None
        for _ in range(16):  # the file is written asynchronously; the reported path changes when it is done
            time.sleep(0.5)
            try:
                path = o.call("GetLastReplayBufferReplay").get("savedReplayPath")
            except OBSError:
                continue
            if path and path != before:
                time.sleep(0.5)  # let the muxer finish the file
                break
        with self.lock:
            self.pending = None
            if not path or path == before:
                self.status["error"] = "SaveReplayBuffer produced no new file"
                return
            self.clip = dict(p, id=f"clip-{next(self.ids)}", path=path, saved_t=saved_t)
            self.status["replays"] += 1
        self.log(f"[replays] saved {path} for {p['label']}")

    def offer(self, now):
        """Ask segments.py to put the clip on air (bypassing segment spacing; still waits for a busy slot)."""
        c = self.clip
        if not c or self.playing:
            return
        if now - c["show_to"] > self.cfg["max_age"]:
            self.log(f"[replays] dropped {c['id']} (never got a free moment)")
            self.clip = None
            return
        cur = self.segments.cur
        if cur and cur["type"] == "attack_replay" and cur.get("clip") == c["id"]:
            return  # already queued or on air
        code, rep = self.segments.request({"type": "attack_replay", "by": "director", "reason": "replay",
                                           "seconds": c["show_to"] - c["show_from"]}, now, ignore_spacing=True)
        if code == 200:
            self.log(f"[replays] queued {c['id']} as {rep['id']}")

    def follow_segment(self, now):
        """Switch to the replay scene when the replay segment goes live; back to stream when it is over."""
        o = self.obs
        cur = self.segments.cur
        live = cur if cur and cur["type"] == "attack_replay" and cur["state"] in ("starting", "live") else None
        if live and live["state"] == "starting" and self.refreshed != live["id"]:
            self.refreshed = live["id"]
            try:  # reload the banner page 2.5 s ahead: a browser source that once failed to load stays blank
                o.call("PressInputPropertiesButton", {"inputName": self.cfg["banner"], "propertyName": "refreshnocache"})
            except OBSError as e:
                self.log(f"[replays] banner refresh failed: {e}")
        elif live and not self.playing and live["state"] == "live":
            c = self.clip
            if not c or c["id"] != live.get("clip"):
                return
            self.play(c)
            self.playing = c["id"]
            self.last_replay = now
            self.clip = None
            self.status["last"] = {"id": c["id"], "label": c["label"], "t": now, "path": c["path"]}
        elif self.playing and not live:
            self.to_stream("replay over")
            self.playing = None
        elif not self.playing and now >= self.next_watch:  # watchdog: never leave the replay scene on air by itself
            self.next_watch = now + 5
            prog = o.call("GetCurrentProgramScene").get("currentProgramSceneName")
            self.status["program"] = prog
            if prog == self.cfg["scene"]:
                self.to_stream("watchdog")

    def play(self, c):
        o, m = self.obs, self.cfg["media"]
        o.call("SetInputSettings", {"inputName": m, "inputSettings": {"local_file": c["path"]}, "overlay": True})
        dur = None
        for _ in range(20):
            time.sleep(0.15)
            st = o.call("GetMediaInputStatus", {"inputName": m})
            if st.get("mediaDuration"):
                dur = st["mediaDuration"]
                break
        if dur:  # the clip ends at saved_t; start it show_from seconds back from there
            start = max(0, int(dur - (c["saved_t"] - c["show_from"]) * 1000))
            o.call("SetMediaInputCursor", {"inputName": m, "mediaCursor": start})
        o.call("TriggerMediaInputAction", {"inputName": m, "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PLAY"})
        o.call("SetCurrentProgramScene", {"sceneName": self.cfg["scene"]})
        self.log(f"[replays] on air: {c['label']} ({c['path']}, from {start if dur else 0} ms of {dur} ms)")

    def to_stream(self, why):
        try:
            self.obs.call("SetCurrentProgramScene", {"sceneName": self.cfg["stream_scene"]})
            self.obs.call("TriggerMediaInputAction", {"inputName": self.cfg["media"],
                                                      "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"})
        finally:
            self.log(f"[replays] back to {self.cfg['stream_scene']} ({why})")

    # ---- OBS setup and health ----------------------------------------------------------------------------------
    def ensure_scene(self):
        """The replay scene: clip (muted, full canvas), REPLAY banner page on top, the live overlay off-canvas so
        its voices stay in the mix. Created once; an existing scene is left as the operator arranged it."""
        o, c = self.obs, self.cfg
        scenes = [s["sceneName"] for s in o.call("GetSceneList")["scenes"]]
        if c["scene"] in scenes:
            return
        o.call("CreateScene", {"sceneName": c["scene"]})
        inputs = {i["inputName"] for i in o.call("GetInputList")["inputs"]}
        if c["media"] not in inputs:
            o.call("CreateInput", {"sceneName": c["scene"], "inputName": c["media"], "inputKind": "ffmpeg_source",
                                   "inputSettings": {"is_local_file": True, "local_file": "", "looping": False,
                                                     "restart_on_activate": False, "close_when_inactive": False,
                                                     "clear_on_media_end": False}})
        else:
            o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["media"]})
        o.call("SetInputMute", {"inputName": c["media"], "inputMuted": True})  # its audio has the old voices in it
        if c["banner"] not in inputs:
            o.call("CreateInput", {"sceneName": c["scene"], "inputName": c["banner"], "inputKind": "browser_source",
                                   "inputSettings": {"url": self.overlay_url, "width": 1920, "height": 1080, "fps": 30,
                                                     "fps_custom": True, "css": "", "shutdown": False,
                                                     "restart_when_active": False}})
        else:
            o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["banner"]})
        if c["overlay_input"] in inputs:
            item = o.call("CreateSceneItem", {"sceneName": c["scene"], "sourceName": c["overlay_input"]})["sceneItemId"]
            o.call("SetSceneItemTransform", {"sceneName": c["scene"], "sceneItemId": item,
                                             "sceneItemTransform": {"positionX": 4000.0, "positionY": 0.0}})
        self.log(f"[replays] created OBS scene {c['scene']!r}")

    def read_stats(self):
        """Encoder health while stream + recording + buffer run: skipped frames since the last read."""
        o = self.obs
        st = o.call("GetStats")
        outs = {}
        for req in ("GetStreamStatus", "GetRecordStatus"):
            try:
                outs[req[3:-6].lower()] = o.call(req).get("outputActive")
            except OBSError:
                pass
        self.status["buffer_active"] = o.call("GetReplayBufferStatus").get("outputActive")
        cur = {k: st.get(k) for k in ("renderSkippedFrames", "renderTotalFrames", "outputSkippedFrames",
                                       "outputTotalFrames")}
        prev, self.prev_stats = self.prev_stats, cur
        delta = {k: cur[k] - prev[k] for k in cur if prev and cur[k] is not None and prev.get(k) is not None}
        self.status["stats"] = {"cpu": round(st.get("cpuUsage") or 0, 1), "fps": round(st.get("activeFps") or 0, 1),
                                "render_ms": round(st.get("averageFrameRenderTime") or 0, 2),
                                "skipped_since_last": delta, "outputs": dict(outs, replay_buffer=self.status["buffer_active"]),
                                "t": time.time()}

    def public(self):
        s = dict(self.status)
        s.update(pending=self.pending and {k: self.pending[k] for k in ("kind", "label")},
                 clip=self.clip and {k: self.clip[k] for k in ("id", "label", "path")}, playing=self.playing)
        return s
