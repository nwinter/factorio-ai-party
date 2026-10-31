"""Prepared shift recaps: a file-only producer and a receipt-driven player.

Only observe_snapshot receives existing observations. Playback can start with an empty
Model, a paused world, no source connection, and no casters process running yet.
"""
import json
import mimetypes
import os
from pathlib import Path
import re
import threading
import time

import shift_recap as recap
import shift_recap_visuals as visuals


def agents_started(run):
    try:
        return bool(re.search(r"(?m)^.*\bstarted: \d+/\d+ agents\b", (Path(run) / "start.log").read_text()))
    except OSError:
        return False


class Player:
    def __init__(self, run, source, audio, phase="recap", tts_config=None):
        self.run, self.source, self.audio, self.phase = Path(run), Path(source), audio, phase
        self.root = self.source / "shift-recap"
        self.path = self.run / f"shift-recap-{phase}-played.json"
        self.state = recap.read_json(self.path, {}) or {}
        if self.state.get("source") != self.source.name:
            self.state = {"source": self.source.name, "completed": [], "ended": False}
        # Completion just before a service crash may have missed the player's next tick.
        for _, r in recap.rows(self.run / "audio-played.jsonl"):
            tag = r.get("recap") or {}
            if r.get("completed") and tag.get("source") == self.source.name and tag.get("phase") == phase:
                if tag.get("line") not in self.state["completed"]:
                    self.state["completed"].append(tag["line"])
        self.current = None
        self.public = None
        self.retry_at = 0
        self.segment = f"shift-recap:{self.source.name}:{phase}"
        self.manifest = None
        self.mtime = None
        self.synced = False
        self.tts_config = tts_config

    def persist(self):
        recap.save_json(self.path, self.state)

    def finish(self, reason):
        if self.state.get("ended"):
            return
        if self.current:
            self.audio.interrupt(self.current["clip"])
        self.audio.stop_segment(self.segment)
        self.audio.release(self.segment)
        self.state.update(ended=True, reason=reason)
        self.persist()
        self.current, self.public = None, None

    def load(self):
        try:
            modified = (self.root / "manifest.json").stat().st_mtime_ns
        except OSError:
            return
        if self.mtime != modified:
            manifest = recap.read_json(self.root / "manifest.json")
            if self.tts_config is not None and (not isinstance(manifest, dict)
                                                or manifest.get("tts_config") != self.tts_config):
                self.manifest = None
                return  # wait for replacement assets; never play another model's prepared speech
            if isinstance(manifest, dict) and manifest.get("version") == 1 and manifest.get("run") == self.source.name:
                self.manifest, self.mtime = visuals.bind(manifest), modified

    def step(self, now):
        if self.phase == "recap" and agents_started(self.run):
            self.finish("agents started")
        if self.state.get("ended"):
            self.public = None
            return None
        self.load()
        manifest = self.manifest
        if not manifest:
            self.public = {"active": True, "phase": self.phase, "run": self.source.name,
                           "title": "Shift change", "text": "Preparing the recorded recap", "timeline": []}
            return self.public
        lines = manifest["transition"] if self.phase == "transition" else manifest["lines"]
        if self.current:
            cid = self.current["clip"]
            with self.audio.cond:
                complete = cid in self.audio.completed
                failed = cid in self.audio.skipped
            if complete:
                self.state["completed"].append(self.current["line"]["id"])
                self.persist()
                self.current = None
            elif failed or now > self.current["deadline"]:
                # A late page, reload, or missing receipt is not completion. Retry this line.
                self.audio.interrupt(cid)
                self.current = None
                self.retry_at = now + 2
        remaining = [r for r in lines if r["id"] not in self.state["completed"]]
        line = self.current["line"] if self.current else (remaining[0] if remaining else None)
        if line and not self.current and now >= self.retry_at:
            # Wait for the capture page. At startup the OBS source may connect minutes after the service.
            with self.audio.cond:
                # A reconnect doesn't send another page-load receipt. Main's open SSE also
                # establishes readiness; completion still requires capture-only receipts.
                ready = self.audio.listeners > 0 and (not self.audio.require_capture or
                    self.audio.capture_session is not None or (self.audio.pages.get("main") or {}).get("open", 0) > 0)
            if ready and not self.synced:
                self.audio.stop_segment(self.segment)
                self.synced = True
            if ready and line.get("asset"):
                path = self.root / "assets" / Path(line["asset"]).name
                try:
                    audio = path.read_bytes()
                except OSError:
                    self.retry_at = now + 5
                else:
                    at = now + 2
                    meta = self.audio.push({"channel": "caster", "speaker": line["speaker"], "text": line["text"],
                                           "caster": "pbp" if line["speaker"] == "Rook" else "color",
                                           "duration": line["duration"], "at": at, "expires_in": line["duration"] + 30,
                                           "rank": "urgent", "segment": {"id": self.segment, "part": 1, "parts": 2},
                                           "recap": {"source": self.source.name, "phase": self.phase, "line": line["id"]}},
                                          audio, line["ctype"])
                    self.current = {"clip": meta["id"], "line": line, "deadline": at + line["duration"] + 10, "at": at}
        if not line and self.phase == "transition":
            self.finish("transition completed")
            return None
        # Keep the receipt/audio hold until startup ends; the page restores once narration is exhausted.
        held = line or (lines[-1] if lines else {})
        self.public = visuals.public(manifest, held, self.phase, holding=not bool(line),
                                     elapsed=now - self.current["at"] if self.current else 0)
        return self.public


class ShiftRecap:
    def __init__(self, run, config, audio):
        import voices
        self.run, self.config, self.audio = Path(run), config, audio
        self.root = self.run / "shift-recap"
        self.shift = config.get("shift") or {}
        previous = recap.parent_run(self.run)
        self.tts_model = voices.configured_openai_model(config)
        self.tts_backend = os.environ.get("POG_RECAP_TTS", "auto")
        self.tts_config = {"backend": self.tts_backend, "openai_tts_model": self.tts_model}
        self.player = (Player(self.run, previous, audio, tts_config=self.tts_config)
                       if previous and not agents_started(self.run) else None)
        self.previous = previous
        self.latest = None
        self.public = None
        self.last_record = 0
        self.busy = False
        self.next_try = 0
        self.closed = threading.Event()
        self.final_previous = not bool(self.player)

    def observe_snapshot(self, snap, board=None):
        self.latest = {"t": snap.get("t", time.time()), "tick": snap.get("tick"),
                       **{k: snap.get(k) for k in ("alerts", "analyst", "research", "space", "plan")},
                       "board": board or snap.get("board")}

    def build(self, source, until, final):
        """Runs on a separate thread: neither preparation nor TTS can stall the stream ticker."""
        try:
            import voices
            import hourly
            writer = None
            if not final and hourly.openrouter_key():
                writer = hourly.make_writer(os.environ.get("POG_RECAP_MODEL", hourly.MODEL))
            tts = voices.TTS(self.tts_backend, openai_model=self.tts_model)
            out = source / "shift-recap"
            recap.prepare(source, out, until, writer=writer, tts=tts,
                          logs=recap.HERE / "logs", final=final)
            print(f"[shift-recap] {'final' if final else 'prepared'} {source.name} through {until}", flush=True)
        except Exception as exc:
            print(f"[shift-recap] preparation failed: {type(exc).__name__}: {exc}", flush=True)
        finally:
            self.busy = False

    def schedule(self, source, until, final, now):
        if self.busy or now < self.next_try:
            return
        self.busy = True
        self.next_try = now + 60
        threading.Thread(target=self.build, args=(source, until, final), daemon=True).start()

    def step(self, now):
        if self.latest and now - self.last_record >= 60:
            self.run.mkdir(parents=True, exist_ok=True)
            with (self.run / "recap-record.jsonl").open("a") as f:
                f.write(json.dumps(self.latest, ensure_ascii=False) + "\n")
            self.last_record = now
        start, end = self.shift.get("start"), self.shift.get("end")
        if self.previous and not self.final_previous:
            old = recap.read_json(self.previous / "shift-recap" / "manifest.json", {}) or {}
            prev_config = recap.read_json(self.previous / "stream.json", {}) or {}
            until = recap.record_end(self.previous, (prev_config.get("shift") or {}).get("end") or now)
            if old.get("final") and old.get("through", 0) >= until and old.get("tts_config") == self.tts_config:
                self.final_previous = True
            else:
                # If the old service was killed at the deadline, the successor finishes from files.
                self.schedule(self.previous, until, bool(old), now)
        elif start and end and now >= min(start + recap.PREPARE_AFTER, end - 120):
            own = recap.read_json(self.root / "manifest.json", {}) or {}
            if not own or own.get("tts_config") != self.tts_config or (now >= end and not own.get("final")):
                self.schedule(self.run, min(now, end), bool(own), now)
        if end and end - recap.TRANSITION_BEFORE <= now < end:
            if not self.player or self.player.phase != "transition":
                self.player = Player(self.run, self.run, self.audio, "transition", tts_config=self.tts_config)
        elif end and now >= end and self.player and self.player.phase == "transition":
            self.player.finish("shift deadline")
        self.public = self.player.step(now) if self.player else None
        return self.public

    def asset(self, name):
        if not visuals.ASSET.fullmatch(name):
            return None
        root = self.player.root if self.player else self.root
        path = root / "assets" / name
        try:
            return path.read_bytes(), mimetypes.guess_type(path)[0] or "application/octet-stream"
        except OSError:
            return None

    def start(self):
        def loop():
            while not self.closed.is_set():
                try:
                    self.step(time.time())
                except Exception as exc:
                    print(f"[shift-recap] {type(exc).__name__}: {exc}", flush=True)
                self.closed.wait(0.5)
        threading.Thread(target=loop, daemon=True).start()
        return self
