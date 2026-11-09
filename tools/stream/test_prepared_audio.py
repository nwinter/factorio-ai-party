#!/usr/bin/env python3
"""Offline spoken-content gate, cache integrity, exact retry, and a complete mocked tour stop."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepared_audio as P
import tour
import shift_recap
import voices


class Checks(unittest.TestCase):
    def test_content_and_duration(self):
        script = "Gemini has the copper line running again."
        self.assertTrue(P.compare(script, script, 3)["passed"])
        for heard in ("Gemini " + script, "Warm and unhurried. " + script, script + " Thank you.",
                      "Me " * 22 + script, "Gemini has the copper."):
            self.assertFalse(P.compare(script, heard, 3)["passed"], heard)
        for duration in (0, 0.1, 20, float("nan")):
            self.assertFalse(P.compare(script, script, duration)["passed"])
        self.assertTrue(P.compare("23 rockets at 18:19 PDT.", "Twenty-three rockets at 1819 Pacific Daylight Time.", 4)["passed"])

    def test_retry_skip_unavailable_and_cache(self):
        with tempfile.TemporaryDirectory() as d:
            checker = P.Checker(Path(d) / "check.jsonl", lambda data, ctype: data.decode())
            calls = []
            script = "The copper line runs again."
            def synth(plain):
                calls.append(plain)
                return (script if plain else "Warmly. " + script).encode(), "audio/mpeg", 3, {}
            result = P.prepare(script, synth, checker, "one")
            self.assertEqual(calls, [False, True])
            self.assertTrue(P.valid(result[3]["audio_check"], script, result[0]))
            self.assertFalse(P.valid(result[3]["audio_check"], script + " changed", result[0]))
            self.assertFalse(P.valid(result[3]["audio_check"], script, b"changed audio"))
            calls.clear()
            P.prepare(script, synth, checker, "cached", cached=result)
            self.assertEqual(calls, [])
            always_bad = lambda plain: (b"Different words.", "audio/mpeg", 3, {})
            self.assertIsNone(P.prepare(script, always_bad, checker, "bad"))
            checker.transcriber = lambda *_: (_ for _ in ()).throw(TimeoutError("offline"))
            self.assertIsNone(P.prepare(script, synth, checker, "unavailable"))
            rows = [json.loads(l) for l in checker.log_path.read_text().splitlines()]
            self.assertEqual(sum(r.get("action") == "skip" for r in rows), 2)
            self.assertTrue(any(r.get("reused") for r in rows))

    def test_plain_payload_and_cache_bypass(self):
        with tempfile.TemporaryDirectory() as d, patch.object(voices, "read_key", return_value="test"), \
             patch.object(voices, "duration", return_value=3), patch.object(voices, "normalize", side_effect=lambda a,c,t:(a,c)):
            tts = voices.TTS("eleven", cache=d)
            payloads = []
            tts.prep = lambda _: self.fail("plain retry rewrote script")
            with patch.object(voices, "_http", side_effect=lambda m,u,h,b: (payloads.append(b) or b"mp3", "audio/mpeg")):
                tts.speak("Gemini has 23 copper plates.", "el-brian", direction="warmly", mood="excited", plain=True)
                tts.speak("Gemini has 23 copper plates.", "el-brian", plain=True)
            self.assertEqual([r["text"] for r in payloads], ["Gemini has 23 copper plates."] * 2)
            self.assertEqual(list(Path(d).rglob("*.mp3")), [])

    def test_preparation_and_full_stop(self):
        from test_tour import Clock, FakeService, LOOK
        with tempfile.TemporaryDirectory() as d:
            script = "The copper line runs again. The furnaces are full."
            calls = []
            class TTS:
                def speak(self, text, voice, **kw):
                    calls.append((text, kw))
                    return (text if kw.get("plain") else "Warm and unhurried. " + text).encode(), "audio/mpeg", 6, 0
                def last_here(self): return {"provider": "eleven"}
            checker = P.Checker(Path(d) / "checks.jsonl", lambda data, ctype: data.decode())
            rows = tour.checked([dict(LOOK, narration=script)])
            with patch.object(tour.subtitles, "for_clip", return_value=[
                    {"t0": 0, "t1": 3, "text": "The copper line runs again."},
                    {"t0": 3, "t1": 6, "text": "The furnaces are full."}]):
                clips, err = tour.render_all(rows, d, "el-brian", TTS(), None, checker=checker)
            self.assertIsNone(err)
            self.assertEqual(calls, [(script, {"direction": tour.DIRECTION}), (script, {"plain": True})])
            manifest = {"voice": "el-brian", "clips": clips}
            clock = Clock(); svc = FakeService(clock)
            runner = tour.Tour(svc, rows, manifest, d, str(Path(d)/"tour.jsonl"),
                               hush_file=str(Path(d)/"hush"), stop_file=str(Path(d)/"stop"),
                               clock=clock, sleep=clock.sleep, agent_gaps=False)
            self.assertEqual(runner.run(rows), (1, 0))
            fixture = Path(d)/"stop.json"
            fixture.write_text(json.dumps({"overlay": next(e for e in svc.overlays if e), "clip": svc.clips[0]}))
            if shutil.which("node"):
                subprocess.run(["node", str(Path(__file__).with_name("playback_clock_selftest.mjs")), str(fixture)], check=True, timeout=30)
            # Cached bytes cannot be swapped after checking.
            Path(d, clips["a"]["file"]).write_bytes(b"tampered")
            self.assertIsNone(tour.clip_for(manifest, d, rows[0][1]))

    def test_skip_tour_and_recap(self):
        from test_tour import Clock, FakeService, LOOK
        with tempfile.TemporaryDirectory() as d:
            class BadTTS:
                def speak(self, text, voice, **kw): return b"wrong words", "audio/mpeg", 3, 0
                def last_here(self): return {"provider": "eleven"}
            checker = P.Checker(Path(d) / "checks.jsonl", lambda data, ctype: data.decode())
            rows = tour.checked([LOOK]); tts = BadTTS()
            clips, err = tour.render_all(rows, d, "el-brian", tts, None, checker=checker)
            self.assertIsNone(err); self.assertTrue(clips["a"]["skipped"])
            clock = Clock(); svc = FakeService(clock)
            runner = tour.Tour(svc, rows, {"voice":"el-brian", "clips":clips}, d, str(Path(d)/"tour.jsonl"),
                               hush_file=str(Path(d)/"hush"), stop_file=str(Path(d)/"stop"),clock=clock,sleep=clock.sleep)
            self.assertEqual(runner.run(rows), (0, 1)); self.assertFalse(svc.clips)
            lines = [{"speaker":"Rook", "text":"The copper line runs again.", "title":"Copper", "sources":[]}]
            self.assertEqual(shift_recap.render_lines(lines, d, tts, checker), [])


if __name__ == "__main__":
    unittest.main()
