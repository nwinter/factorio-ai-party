#!/usr/bin/env python3
"""Capture bounds, acknowledged subjects and media-only preparation; no live dependencies."""
import base64
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import recap_capture as C
import shift_recap as R
import shift_recap_media as M
import shift_recap_visuals as V


def state(now=1000, subject="Asterion", surface="platform-16", platform=True):
    shot = {"since": now - 10, "framed": now - 10, "sent": now - 1, "surface": surface,
            **({"platform": {"name": subject}} if platform else {})}
    frame = {"client": "main", "surface": surface, **({"platform": {"name": subject}} if platform else {})}
    program = {"frames": {"main": frame}, "cameras": {"main": {"shot": shot, "pending": False}}}
    return {"now": now - 1, "tick": 12000, "cuts": {"connected": True, "t": now - 1, "on_air": program},
            "camera_states": {"main": {"acknowledged": shot, "on_air": shot}}}


def manifest():
    return {"version": 1, "run": "shift1", "through": 1100, "final": True,
            "review": {"mode": "record extracts"}, "stills": [], "transition": [],
            "evidence": {"start": 900, "until": 1100, "rows": [
                {"id": "a", "t": 1000, "text": "platform Asterion left nauvis", "source": "chronicle.jsonl",
                 "row": 1, "game_time": None, "wall_time": "00:16", "kind": "platform"},
                {"id": "n", "t": 1050, "text": "A new belt", "surface": "nauvis", "source": "chronicle.jsonl",
                 "row": 2, "game_time": None, "wall_time": "00:17", "kind": "chronicle"}]},
            "lines": [{"id": "ship", "speaker": "Rook", "title": "Why Asterion Matters", "text": "Asterion departed.", "sources": ["a"]},
                      {"id": "belt", "speaker": "Vale", "title": "Belt", "text": "A new belt.", "sources": ["n"]}]}


class ReceiptsTest(unittest.TestCase):
    def test_subjects_require_visible_acknowledged_fresh_physical_camera(self):
        self.assertEqual(C.candidates(state(), 1000)[0]["subject"], "Asterion")
        self.assertEqual(C.candidates(state(surface="nauvis", platform=False), 1000)[0]["subject"], "nauvis")
        self.assertEqual(C.candidates(state(), 1000, {"main"}), [])
        self.assertEqual(C.candidates(state(), 1020), [])
        self.assertEqual(C.candidates(state(platform=False), 1000), [])
        for modify in (
            lambda s: s["cuts"].update(error="disconnected"),
            lambda s: s["cuts"].update(connected=False),
            lambda s: s["cuts"]["on_air"].update(host=True),
            lambda s: s.update(shift_recap={"active": True}),
            lambda s: s.update(replay={"playing": "clip"}),
            lambda s: s.update(show={"image": "art"}),
            lambda s: s["cuts"]["on_air"]["cameras"]["main"].update(pending=True),
            lambda s: s["camera_states"]["main"].update(acknowledged={"surface": "gleba"}),
            lambda s: s["cuts"]["on_air"].update(frames={}),
            lambda s: s["camera_states"]["main"].update(on_air={"sent": 999, "since": 999}),
        ):
            s = copy.deepcopy(state()); modify(s)
            self.assertEqual(C.candidates(s, 1000), [])


class CaptureTest(unittest.TestCase):
    def setUp(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("capture helper requires Pillow, as mapframes does")
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name)
        self.now = 1000
        buf = io.BytesIO(); Image.new("RGB", (1280, 720), "#284656").save(buf, "JPEG")
        self.data = buf.getvalue()
        self.calls = []
        class OBS:
            def call(obs, method, payload, **kw):
                self.calls.append((method, payload, kw))
                return {"imageData": "data:image/jpeg;base64," + base64.b64encode(self.data).decode()}
        self.obs = OBS()
        self.capture = C.Capture(self.run, self.obs, clock=lambda: self.now)

    def step(self, **kw):
        s = state(self.now, **kw)
        return self.capture.step(s, lambda: s)

    def test_subject_global_and_restart_limits_keep_capture_receipt(self):
        self.assertEqual(self.step()["status"], "saved")
        self.now += 59
        self.capture = C.Capture(self.run, self.obs, clock=lambda: self.now)
        self.assertEqual(self.step(subject="Lark")["status"], "rate limited")
        self.now += 1
        self.assertEqual(self.step()["status"], "no eligible subject")
        self.assertEqual(self.step(surface="nauvis", platform=False)["status"], "saved")
        self.now = 1299
        self.assertEqual(self.step()["status"], "no eligible subject")
        self.now = 1300
        self.assertEqual(self.step()["status"], "saved")
        catalog = R.read_json(self.run / "recap-media.json")
        self.assertEqual([r["t"] for r in catalog], [1000, 1060, 1300])
        self.assertEqual(catalog[0]["subject_type"], "platform")
        self.assertEqual(catalog[0]["surface"], "platform-16")
        self.assertEqual(catalog[0]["receipt"]["tick"], 12000)
        self.assertEqual(catalog[0]["after_receipt"]["frame"]["platform"]["name"], "Asterion")
        for method, payload, kw in self.calls:
            self.assertEqual(method, "GetSourceScreenshot")
            self.assertEqual(payload["sourceName"], "stream cam1")
            self.assertEqual(payload["imageWidth"], 1280)
            self.assertEqual(kw, {"retry": False})

    def test_disk_cap_before_obs_and_corrupt_or_changed_frame(self):
        self.capture.disk_bytes = 500
        self.assertEqual(self.step()["status"], "disk cap")
        self.assertEqual(self.calls, [])
        self.capture.disk_bytes = C.DISK_BYTES
        s = state()
        result = self.capture.step(s, lambda: state(subject="Lark"))
        self.assertEqual(result["status"], "failed")
        self.assertIn("changed", result["error"])
        self.now += 1
        self.assertEqual(self.step()["status"], "rate limited")
        self.now += 60; self.data = b"bad JPEG"
        self.assertEqual(self.step()["status"], "failed")
        self.assertFalse((self.run / "recap-media.json").exists())


class RefreshTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name) / "shift1"; self.out = self.run / "shift-recap"
        self.out.mkdir(parents=True)
        R.save_json(self.run / "stream.json", {"shift": {"start": 900, "end": 1200}})
        R.save_json(self.out / "manifest.json", manifest())
        self.png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1sAAAAASUVORK5CYII=")

    def test_no_media_log_and_review_then_new_media_rebinds_without_narration(self):
        first = R.prepare(self.run, self.out, 1100)
        self.assertTrue(first["media_review"]["no_media"])
        for filename in ("prep.log", "review.md"):
            self.assertIn("NO BOUND MEDIA", (self.out / filename).read_text())
        (self.run / "ship.png").write_bytes(self.png)
        R.save_json(self.run / "recap-media.json", [{"path": "ship.png", "platform": "Asterion", "t": 1101}])
        second = R.prepare(self.run, self.out, 1100)
        self.assertEqual(second["lines"], first["lines"])
        self.assertEqual(second["through"], first["through"])
        self.assertFalse(second["media_review"]["no_media"])
        self.assertEqual(second["visuals"]["ship"]["media"]["t"], 1101)
        # A lost prepared copy is rebuilt from the recorded original, including after restart.
        asset = self.out / "assets" / second["stills"][0]["asset"]
        asset.unlink()
        self.assertEqual(M.refresh_saved(self.run, self.out)["visuals"]["ship"]["media"]["subject"], "Asterion")
        self.assertTrue(asset.is_file())

    def test_missing_and_failed_assets_per_beat_and_surface_record_fallback(self):
        (self.run / "bad.png").write_bytes(b"bad image")
        R.save_json(self.run / "recap-media.json", [
            {"path": "absent.jpg", "platform": "Asterion", "t": 1000},
            {"path": "bad.png", "surface": "nauvis", "t": 1050}])
        result = R.prepare(self.run, self.out, 1100)
        self.assertTrue(result["media_review"]["no_media"])
        for beat in result["media_review"]["beats"]:
            self.assertEqual(len(beat["errors"]), 1)
        self.assertIn("absent.jpg", (self.out / "review.md").read_text())
        (self.run / "bad.png").write_bytes(self.png)
        result = R.prepare(self.run, self.out, 1100)
        self.assertEqual(result["visuals"]["belt"]["media"]["subject"], "nauvis")
        self.assertIsNone(result["visuals"]["ship"]["media"])

    def test_nearest_frame_casefold_and_ship_over_dock(self):
        m = manifest()
        m["stills"] = [{"asset": c * 24 + ".png", "t": t, "platform": "asterion", "surface": "platform-16"}
                       for c, t in (("a", 950), ("b", 1001), ("c", 1070))]
        m["stills"].append({"asset": "d" * 24 + ".png", "t": 1000, "surface": "nauvis"})
        m["lines"][0]["text"] = "Asterion departs Nauvis."
        result = V.bind(m)
        self.assertEqual(result["visuals"]["ship"]["media"]["asset"], "b" * 24 + ".png")
        self.assertEqual(result["visuals"]["belt"]["media"]["subject"], "nauvis")

    def test_service_refreshes_before_first_air_and_on_later_media_arrival(self):
        from shift_recap_air import ShiftRecap, Player
        from serve import AudioHub
        svc = ShiftRecap(self.run, {}, AudioHub())
        svc.player = Player(self.run, self.run, svc.audio)
        jobs = []
        class Thread:
            def __init__(self, target, args, **kw): self.target, self.args = target, args
            def start(self): jobs.append(self)
        with patch("shift_recap_air.threading.Thread", Thread):
            self.assertEqual(svc.step(1201)["text"], "Preparing the recorded recap")
            self.assertIsNone(svc.player.manifest, "stale media cannot air before the first refresh")
            jobs.pop().target([self.run])
            self.assertEqual(svc.step(1202)["id"], "ship")
            (self.run / "ship.png").write_bytes(self.png)
            R.save_json(self.run / "recap-media.json", [{"path": "ship.png", "platform": "Asterion", "t": 1000}])
            svc.step(1262)
            jobs.pop().target([self.run])
            self.assertEqual(svc.step(1263)["media"]["subject"], "Asterion")


if __name__ == "__main__":
    unittest.main()
