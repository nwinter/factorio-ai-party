#!/usr/bin/env python3
"""Bounded recap stills from existing director/compositor receipts. No game reads.

Only OBS GetSourceScreenshot of a known physical camera source is permitted here.
Polls state.json beside the stream service; never starts a client or changes OBS.
"""
import argparse
import base64
import fcntl
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request

from shift_recap import atomic, read_json, save_json
from shift_recap_visuals import label

SOURCES = {"main": "stream cam1", "cam2": "stream cam2", "cam3": "stream cam3"}
SUBJECT_SECONDS = 300
GLOBAL_SECONDS = 60
DISK_BYTES = 128 * 1024 * 1024
MAX_FRAME_BYTES = 2 * 1024 * 1024
SETTLE_SECONDS = 3
FRESH_SECONDS = 10
WIDTH = 1280


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as response:
        state = json.load(response)
    return state.get("state", state)


def identity(shot):
    return (shot.get("since"), shot.get("surface"), shot.get("follow"),
            (shot.get("platform") or {}).get("name"))


def candidates(state, now, panels=()):
    """Only the acknowledged, visible physical clients; desired/standby shots are not evidence."""
    cuts = state.get("cuts") or {}
    program = cuts.get("on_air") or {}
    if (not cuts.get("connected") or cuts.get("error") or
            not 0 <= now - state.get("now", 0) <= FRESH_SECONDS or state.get("poll_error") or
            program.get("host") or state.get("hostview") or state.get("show") or
            (state.get("shift_recap") or {}).get("active") or
            (state.get("replay") or {}).get("playing")):
        return []
    found = []
    for role, frame in (program.get("frames") or {}).items():
        client = frame.get("client") or role
        if client not in SOURCES or client in panels:
            continue
        camera = (program.get("cameras") or {}).get(client) or {}
        receipts = (state.get("camera_states") or {}).get(client) or {}
        shot = receipts.get("on_air") or {}
        ack = receipts.get("acknowledged") or {}
        if (not shot or camera.get("pending") or not shot.get("sent") or
                identity(shot) != identity(ack) or identity(shot) != identity(camera.get("shot") or {}) or
                now - max(shot.get("since", now), shot.get("framed", 0)) < SETTLE_SECONDS):
            continue
        platform = label((frame.get("platform") or frame.get("ship") or {}).get("name") or
                         (shot.get("platform") or {}).get("name"))
        surface = frame.get("surface") or (frame.get("frame") or {}).get("surface") or shot.get("surface")
        if not surface and shot.get("follow"):
            agent = next((a for a in state.get("agents", []) if a.get("name") == shot["follow"]), {})
            surface = agent.get("surface") or (agent.get("position") or {}).get("surface")
        surface = label(surface)
        if not platform and (not surface or surface.startswith("platform-")):
            continue
        subject, kind = (platform, "platform") if platform else (surface, "surface")
        found.append({"subject": subject, "subject_type": kind, "surface": surface,
                      "platform": platform or None, "client": client, "source": SOURCES[client],
                      "receipt": {"tick": state.get("tick"), "state_t": state["now"], "compositor_t": cuts.get("t"), "role": role,
                                  "on_air": shot, "acknowledged": ack, "frame": frame},
                      "identity": list(identity(shot))})
    return found


class Capture:
    def __init__(self, run, obs, *, clock=time.time, disk_bytes=DISK_BYTES):
        self.run, self.obs, self.clock, self.disk_bytes = Path(run), obs, clock, disk_bytes
        self.folder = self.run / "recap-frames"
        config = read_json(self.run / "stream.json", {}) or {}
        self.panels = {r["slot"] for r in config.get("cameras", []) if r.get("panel")}

    def step(self, state, recheck):
        self.folder.mkdir(parents=True, exist_ok=True)
        # A second helper or a restart cannot bypass the persistent attempt/cap bounds.
        with (self.folder / ".lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"status": "busy"}
            now = self.clock()
            status = read_json(self.folder / "status.json", {}) or {}
            if now - status.get("attempt_t", -1e20) < GLOBAL_SECONDS:
                return {"status": "rate limited"}
            catalog = read_json(self.run / "recap-media.json", None if (self.run / "recap-media.json").exists() else [])
            if not isinstance(catalog, list):
                return {"status": "invalid recap-media.json"}
            last = {}
            for row in catalog:
                if isinstance(row, dict) and isinstance(row.get("t"), (int, float)):
                    key = (row.get("subject_type"), str(row.get("subject", "")).casefold())
                    last[key] = max(last.get(key, 0), row["t"])
            ready = [r for r in candidates(state, now, self.panels)
                     if now - last.get((r["subject_type"], r["subject"].casefold()), -1e20) >= SUBJECT_SECONDS]
            if not ready:
                return {"status": "no eligible subject"}
            # Prefer subjects not photographed yet; ties keep the main role first.
            row = min(ready, key=lambda r: last.get((r["subject_type"], r["subject"].casefold()), 0))
            used = sum(p.stat().st_size for p in self.folder.iterdir() if p.is_file())
            index = self.run / "recap-media.json"
            used += index.stat().st_size if index.exists() else 0
            # Reserve one bounded response plus index growth/atomic replacement before even asking OBS.
            if used + MAX_FRAME_BYTES + 2 * (index.stat().st_size if index.exists() else 0) + 65536 > self.disk_bytes:
                return {"status": "disk cap"}
            status = {"attempt_t": now, "subject": row["subject"], "status": "attempting"}
            save_json(self.folder / "status.json", status)
            try:
                started = time.monotonic()
                response = self.obs.call("GetSourceScreenshot", {"sourceName": row["source"], "imageFormat": "jpg",
                                         "imageWidth": WIDTH, "imageCompressionQuality": 80}, retry=False)
                finished = self.clock()
                status["elapsed_ms"] = round((time.monotonic() - started) * 1000, 1)
                if finished - now > FRESH_SECONDS:
                    raise ValueError("screenshot exceeded receipt freshness window")
                # state.json is published on the service tick. An immediate GET may
                # return the pre-capture snapshot; wait for an actual later receipt.
                deadline = time.monotonic() + SETTLE_SECONDS
                after_state = recheck()
                while after_state.get("now", 0) < finished and time.monotonic() < deadline:
                    time.sleep(.2)
                    after_state = recheck()
                if after_state.get("now", 0) < finished:
                    raise ValueError("no post-capture receipt")
                after = next((r for r in candidates(after_state, self.clock(), self.panels)
                              if all(r[k] == row[k] for k in ("client", "subject", "subject_type", "surface", "identity"))), None)
                if after is None:
                    raise ValueError("camera changed during screenshot")
                data = base64.b64decode(response["imageData"].split(",", 1)[1], validate=True)
                if len(data) > MAX_FRAME_BYTES:
                    raise ValueError("screenshot exceeds frame cap")
                from PIL import Image
                with Image.open(io.BytesIO(data)) as image:
                    size = list(image.size)
                    if max(size) > WIDTH or min(size) <= 0:
                        raise ValueError("unexpected screenshot size")
                    image.load()
                name = f"{int(now * 1000)}-{hashlib.sha256(data).hexdigest()[:16]}.jpg"
                row.pop("identity")
                row.update(path="recap-frames/" + name, t=now, capture_finished=finished, px=size,
                           bytes=len(data), after_receipt=after["receipt"])
                new_catalog = catalog + [row]
                payload = json.dumps(new_catalog, ensure_ascii=False, indent=2) + "\n"
                if used + len(data) + len(payload.encode()) + 65536 > self.disk_bytes:
                    raise ValueError("capture metadata exceeds disk cap")
                atomic(self.folder / name, data)
                atomic(index, payload)
                status.update(status="saved", path=row["path"], bytes=len(data))
            except Exception as exc:
                status.update(status="failed", error=f"{type(exc).__name__}: {exc}")
            save_json(self.folder / "status.json", status)
            return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--url", default="http://127.0.0.1:8788/state.json")
    parser.add_argument("--obs", default="127.0.0.1:4455")
    args = parser.parse_args()
    from obsws import OBS
    host, _, port = args.obs.partition(":")
    capture = Capture(args.run_dir, OBS(host, int(port or 4455), timeout=5))
    print(f"[recap-capture] {WIDTH}px JPEG; subject >= {SUBJECT_SECONDS}s; global >= {GLOBAL_SECONDS}s; "
          f"disk cap {DISK_BYTES // 1024 // 1024} MiB", flush=True)
    previous = None
    while True:
        try:
            result = capture.step(fetch(args.url), lambda: fetch(args.url))
        except Exception as exc:
            result = {"status": "failed", "error": f"{type(exc).__name__}: {exc}"}
        if result != previous:
            print("[recap-capture] " + json.dumps(result), flush=True)
            previous = result
        time.sleep(2)


if __name__ == "__main__":
    main()
