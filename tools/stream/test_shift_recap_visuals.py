#!/usr/bin/env python3
"""Recorded media selection, offline replay and full-canvas presentation states."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shift_recap as R
import shift_recap_visuals as V
import shift_recap_rehearsal as replay

HERE = Path(__file__).resolve().parent


def fixture():
    return {"run": "shift1", "through": 200, "evidence": {"start": 100, "until": 200, "rows": [
        {"id": "ship", "t": 150, "text": "platform Lark left nauvis for gleba", "source": "private/journal.jsonl", "row": 17},
        {"id": "stock", "t": 170, "text": "Production packs on Nauvis"}]},
        "transition": [{"id": "t", "title": "Shift change", "speaker": "Rook", "text": "The shift is ending", "sources": []}],
        "lines": [{"id": "s", "title": "Ship", "speaker": "Rook", "text": "Lark left Nauvis", "sources": ["ship"]},
                  {"id": "p", "title": "Science", "speaker": "Vale", "text": "Packs on Nauvis", "sources": ["stock"]}],
        "stills": [{"asset": "a" * 24 + ".webp", "surface": "nauvis", "t": 130},
                   {"asset": "b" * 24 + ".webp", "surface": "nauvis", "t": 175}]}


class VisualsTest(unittest.TestCase):
    def test_subject_time_and_no_unrelated_ship_picture(self):
        m = V.bind(fixture())
        self.assertIsNone(m["visuals"]["s"]["media"])
        self.assertIsNone(m["visuals"]["t"]["media"])
        self.assertEqual(m["visuals"]["p"]["media"]["asset"], "b" * 24 + ".webp")
        self.assertEqual(m["visuals"]["p"]["time_label"], "Record · " + V.clock(170))
        self.assertEqual(m["visuals"]["p"]["media"]["recorded_time"], V.clock(175))
        # Line order, playback receipt and service/page reload do not rotate pictures.
        m["lines"].reverse()
        self.assertEqual(V.bind(m)["visuals"], m["visuals"])

    def test_ship_clip_wins_over_its_dock_surface(self):
        m = fixture()
        m["stills"].append({"asset": "c" * 24 + ".webm", "platform": "Lark", "t": 145, "offset": 4})
        bound = V.bind(m)
        self.assertEqual(bound["visuals"]["s"]["media"]["kind"], "video")
        self.assertEqual(bound["visuals"]["s"]["media"]["subject"], "Lark")
        # The name is in the cited row, though the spoken line only names the dock.
        m["lines"][0]["text"] = "The ship departed Nauvis."
        self.assertEqual(V.bind(m)["visuals"]["s"]["media"]["subject"], "Lark")

    def test_ambiguous_routes_and_unnamed_refits_are_neutral(self):
        for text in ("A Nauvis-Fulgora trial", "Refitting engines at the true aft end at Nauvis"):
            m = fixture()
            m["lines"][1]["text"] = text
            self.assertIsNone(V.bind(m)["visuals"]["p"]["media"])

    def test_media_bounds_legacy_and_missing_metadata(self):
        m = fixture()
        m["stills"] = [{"asset": "a" * 24 + ".webp", "t": 180,
                        "caption": "Recorded still: nauvis · 13:18 PDT · Graphics copyright Wube Software"}]
        self.assertIsNotNone(V.bind(m)["visuals"]["p"]["media"])
        for change in ({"t": 99}, {"t": 201}, {"t": None}, {"asset": "../private.png"},
                       {"t": float("nan")}, {"caption": ""}, {"caption": "Recorded still: /private · 13:18"}):
            bad = copy.deepcopy(m)
            bad["stills"][0].update(change)
            self.assertIsNone(V.bind(bad)["visuals"]["p"]["media"], change)

    def test_public_view_keeps_technical_evidence_off_screen(self):
        m = V.bind(fixture())
        public = V.public(m, m["lines"][0], "recap")
        self.assertNotIn("sources", public)
        self.assertNotIn("binding", public)
        self.assertNotIn("private/", json.dumps(public))
        self.assertEqual(m["evidence"]["rows"][0]["row"], 17)

    def test_existing_media_catalog_requires_capture_metadata_and_local_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run, out = root / "run", root / "out"
            run.mkdir()
            R.save_json(run / "stream.json", {"shift": {"start": 100}})
            (run / "existing.webm").write_bytes(b"already recorded clip")
            (root / "outside.png").write_bytes(b"outside")
            R.save_json(run / "recap-media.json", [
                {"path": "existing.webm", "platform": "Lark", "t": 160},
                {"path": "existing.webm", "platform": "Lark"},
                {"path": "existing.webm", "platform": "Lark", "t": 210},
                {"path": "../outside.png", "surface": "nauvis", "t": 160}])
            found = R.stills(run, 200, out)
            self.assertEqual(len(found), 1)
            self.assertEqual((out / "assets" / found[0]["asset"]).read_bytes(), b"already recorded clip")
            self.assertEqual(found[0]["platform"], "Lark")

    def test_rehearsal_reuses_actual_pages_and_minimal_startup_state(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            replay.pages(fixture(), out)
            data = json.loads((out / "replay-sequence.json").read_text())
            self.assertEqual(len(data["sequence"]), 3)
            self.assertEqual(data["cases"]["restore"], 3)
            self.assertEqual(data["normal"]["agents"], [])
            for kind, page in (("landscape", "index.html"), ("portrait", "portrait.html")):
                text = (out / f"onair-{kind}.html").read_text()
                self.assertIn((HERE / "static" / "shift-recap.js").read_text(), text)
                self.assertIn((HERE / "static" / "shift-recap.css").read_text(), text)
                self.assertIn('id="side"', text)
                self.assertIn('return early ? {shift_recap:recap}', text)
                self.assertNotIn('https://fonts.googleapis.com', text)
                self.assertNotIn('private/journal', text)

    def test_dom_states(self):
        if not shutil.which("node"):
            self.skipTest("node unavailable")
        subprocess.run(["node", str(HERE / "shift_recap_selftest.mjs")], check=True)


if __name__ == "__main__":
    unittest.main()
