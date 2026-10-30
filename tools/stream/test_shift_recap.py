#!/usr/bin/env python3
"""Offline shift recap: sourced preparation, deadline coda, restart and agent-ready handoff."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shift_recap as R
from shift_recap_air import Player, ShiftRecap, agents_started
from serve import AudioHub, Hub, make_handler
from segments import Segments

T0 = 1793349751


def jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records))


class TTS:
    backend = "stub"

    def speak(self, text, voice, **kwargs):
        return b"stub audio", "audio/mpeg", 6.0, 0


class RecapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.old, self.run = self.root / "shift1", self.root / "shift2"
        self.old.mkdir()
        self.run.mkdir()
        (self.run / "resumed-from").write_text("shift1")
        self.config = {"shift": {"start": T0, "end": T0 + 14400}}
        R.save_json(self.old / "stream.json", self.config)
        self.events = [
            {"type": "event", "id": 1, "kind": "platform_created", "platform": "Lark", "at": "nauvis",
             "line": "Lark was created at nauvis", "tick": 3600, "t": T0 + 10},
            {"type": "event", "id": 2, "kind": "platform_left", "platform": "Lark", "at": "nauvis", "to": "gleba",
             "line": "Lark left nauvis for gleba", "tick": 7200, "t": T0 + 20},
            {"type": "event", "id": 3, "kind": "research", "line": "Research finished: logistics 2",
             "tick": 10800, "t": T0 + 30},
            {"type": "entry", "seq": 1, "agent": "sol", "title": "Refit", "text": "The refit passed its test.",
             "tick": 14400, "t": T0 + 40},
            {"type": "event", "id": 4, "kind": "platform_lost", "platform": "Lark", "line": "Lark was lost to asteroids",
             "tick": 18000, "t": T0 + 13000}]
        jsonl(self.old / "chronicle.jsonl", self.events)
        jsonl(self.old / "chat.jsonl", [{"from": "sol", "text": "The new belt is in place.",
                                        "logged_at": R.dt.datetime.fromtimestamp(T0 + 60).isoformat()}])
        jsonl(self.old / "recap-record.jsonl", [{"t": T0 + 60, "board": {"items": [{"id": 3, "title": "Build belt", "status": "done"}]},
                                                "analyst": {"talking_points": [{"text": "The refit has passed its test."}]}}])
        R.save_json(self.old / "plan.json", {"goals": "Build another ship", "goals_tick": 14000})
        jsonl(self.old / "sol" / "journal.jsonl", [{"at": R.dt.datetime.fromtimestamp(T0 + 60).isoformat(),
            "event": "request", "request": {"action": "tell", "args": {"to": "luna", "text": "Refit passed."}}}])
        self.out = self.old / "shift-recap"

    def prepare(self, final=False):
        return R.prepare(self.old, self.out, T0 + (14400 if final else 10800), tts=TTS(), final=final)

    def audio(self):
        audio = AudioHub()
        audio.listeners = 1
        return audio

    def test_record_only_early_and_late(self):
        first = self.prepare()
        early = first["lines"]
        self.assertTrue(all(r["t"] <= T0 + 10800 for r in first["evidence"]["rows"]))
        self.assertFalse(any("was lost" in l["text"] for l in early))
        self.assertIsNone(R.check(early, first["evidence"]))
        self.assertTrue(all(first["evidence"]["coverage"][k] for k in ("board", "plan", "tell", "chat", "analyst", "chronicle")))
        final = self.prepare(final=True)
        self.assertEqual(final["lines"][:len(early)], early)
        self.assertTrue(final["final"])
        self.assertTrue(any("was lost" in l["text"] for l in final["lines"][len(early):]))
        self.assertTrue((self.out / "cards.html").is_file())

    def test_final_save_extends_deadline_without_duplicate_coda(self):
        self.prepare()
        first = self.prepare(final=True)
        extra = dict(self.events[-1], id=5, t=T0 + 14500, tick=21600, platform="Swift", line="Swift was lost to asteroids")
        jsonl(self.old / "chronicle.jsonl", self.events + [extra])
        R.save_json(self.old / "stopped.json", {"stop_utc": R.dt.datetime.fromtimestamp(T0 + 14600, R.dt.timezone.utc).isoformat()})
        until = R.record_end(self.old, T0 + 14400)
        final = R.prepare(self.old, self.out, until, tts=TTS(), final=True)
        self.assertEqual(final["lines"][:first["base_count"]], first["lines"][:first["base_count"]])
        self.assertEqual(sum("Lark was lost" in r["text"] for r in final["lines"]), 1)
        self.assertTrue(any("Swift was lost" in r["text"] for r in final["lines"]))
        # An old preparation finishing late cannot replace the final script.
        self.assertEqual(R.prepare(self.old, self.out, T0 + 10800, tts=TTS()), final)

    def test_bad_source_number_time_and_prompt_injection(self):
        e = R.gather(self.old, T0 + 10800)
        line = {"speaker": "Vale", "title": "Research", "text": "Research finished: logistics 3",
                "sources": [next(r["id"] for r in e["rows"] if r["kind"] == "research")]}
        self.assertIn("number", R.check([line], e))
        line["text"] = "Five minutes later research finished: logistics 2"
        self.assertIn("number", R.check([line], e))
        line["text"] = "At game 3h00m research finished: logistics 2"
        self.assertIsNotNone(R.check([line], e))
        line["sources"] = ["invented"]
        self.assertIn("source", R.check([line], e))
        self.assertEqual(R.clean("secret in /Users/nick/key"), "")
        class Writer:
            def complete(self, *a, **kw):
                return json.dumps({"lines": [line]})
        script, review = R.write_script(e, Writer())
        self.assertEqual(review["mode"], "record extracts")
        self.assertIsNone(R.check(script, e))

    def test_semantic_rejection_falls_back(self):
        e = R.gather(self.old, T0 + 10800)
        lines = R.fallback(e)
        class Writer:
            def complete(self, system, *a, **kw):
                return json.dumps({"ok": False, "reason": "unsupported cause"} if system.startswith("Fact-check") else {"lines": lines})
        _, review = R.write_script(e, Writer())
        self.assertEqual(review["mode"], "record extracts")

    def test_firsts_dedup_chain_and_rename(self):
        before = self.root / "shift0"
        before.mkdir()
        (self.old / "resumed-from").write_text("shift0")
        jsonl(before / "chronicle.jsonl", self.events[:2])
        # Carried rows aren't new firsts; an unknown ship's first sighting isn't a first either.
        unknown = dict(self.events[1], id=9, platform="Unknown", t=T0 + 70)
        jsonl(self.old / "chronicle.jsonl", self.events + [unknown])
        e = R.gather(self.old, T0 + 10800)
        self.assertFalse(any("First departure" in r["text"] for r in e["rows"]))

    def test_stills_cutoff_and_safe_assets(self):
        d = self.old / "mapframes"
        d.mkdir()
        for name, t in (("early", T0 + 10), ("late", T0 + 13000)):
            R.save_json(d / (name + ".json"), {"t": t, "surface": "nauvis"})
            (d / (name + ".webp")).write_bytes(b"fake image " + name.encode())
        manifest = self.prepare()
        self.assertEqual(len(manifest["stills"]), 1)
        svc = ShiftRecap(self.run, {}, self.audio())
        self.assertIsNone(svc.asset("../../stream.json"))
        self.assertEqual(svc.asset(manifest["stills"][0]["asset"])[0], b"fake image early")
        (d / "early.webp").write_bytes(b"a newer image replaced this area")
        final = self.prepare(final=True)
        self.assertIn(manifest["stills"][0], final["stills"], "the first pass's still survives the final refresh")

    def test_restart_replays_only_unfinished_and_stops_at_partial_started(self):
        manifest = self.prepare()
        audio = self.audio()
        p = Player(self.run, self.old, audio)
        p.step(T0)
        first = p.current["line"]["id"]
        audio.completed.add(p.current["clip"])
        p.step(T0 + 8)
        self.assertIn(first, p.state["completed"])
        new = Player(self.run, self.old, self.audio())
        new.step(T0 + 10)
        self.assertNotEqual(new.current["line"]["id"], first)
        self.assertEqual(new.current["line"]["id"], p.current["line"]["id"])
        (self.run / "start.log").write_text("05:55:01 started: 8/9 agents (not started: luna); deadline later\n")
        self.assertIsNone(new.step(T0 + 11))
        self.assertTrue(new.state["ended"])
        self.assertTrue(any(m[2].get("cancel") for m in new.audio.clips.values()))
        self.assertTrue(any(m[2].get("release") for m in new.audio.clips.values()))
        self.assertIsNone(Player(self.run, self.old, self.audio()).step(T0 + 12))

    def test_receipt_recovery_delayed_page_and_failed_clip(self):
        m = self.prepare()
        jsonl(self.run / "audio-played.jsonl", [{"completed": True, "recap": {"source": "shift1", "phase": "recap", "line": m["lines"][0]["id"]}}])
        audio = self.audio()
        audio.listeners = 0
        p = Player(self.run, self.old, audio)
        self.assertTrue(p.step(T0)["active"])
        self.assertIsNone(p.current)
        audio.listeners = 1
        p.step(T0 + 20)
        ident = p.current["line"]["id"]
        self.assertEqual(ident, m["lines"][1]["id"])
        audio.skipped.add(p.current["clip"])
        p.step(T0 + 21)
        p.step(T0 + 24)
        self.assertEqual(ident, p.current["line"]["id"])

    def test_capture_reconnect_does_not_need_a_new_load(self):
        self.prepare()
        audio = AudioHub(require_capture=True)
        audio.listeners = 1
        audio.page_event("main", "open", now=T0)
        self.assertIsNone(audio.capture_session)
        p = Player(self.run, self.old, audio)
        p.step(T0)
        self.assertIsNotNone(p.current)
        self.assertTrue(any(m[2].get("stop_segment") == p.segment for m in audio.clips.values()))

    def test_exhaustion_holds_cards_without_repeating(self):
        m = self.prepare()
        p = Player(self.run, self.old, self.audio())
        p.state["completed"] = [l["id"] for l in m["lines"]]
        self.assertTrue(p.step(T0)["holding"])
        self.assertIsNone(p.current)
        self.assertEqual(len(p.audio.clips), 0)
        p = Player(self.old, self.old, self.audio(), "transition")
        p.state["completed"] = [l["id"] for l in m["transition"]]
        self.assertIsNone(p.step(T0))

    def test_service_scheduling_is_independent_of_world(self):
        svc = ShiftRecap(self.old, self.config, self.audio())
        calls = []
        svc.schedule = lambda *args: calls.append(args)
        svc.step(T0 + 10799)
        self.assertEqual(calls, [])
        svc.step(T0 + 10800)
        self.assertEqual(calls[-1][1:3], (T0 + 10800, False))
        self.prepare()
        svc.step(T0 + 14400 - 35)
        self.assertEqual(svc.public["phase"], "transition")
        svc.step(T0 + 14400)
        self.assertEqual(calls[-1][1:3], (T0 + 14400, True))
        self.assertIsNone(svc.public)
        # New service performs a missing deadline pass while the source is entirely absent.
        svc2 = ShiftRecap(self.run, {}, self.audio())
        svc2.schedule = lambda *args: calls.append(args)
        svc2.step(T0 + 14401)
        self.assertEqual(calls[-1][0], self.old)
        self.assertTrue(svc2.public["active"])

    def test_midshift_restart_does_not_replay_or_build_previous(self):
        (self.run / "start.log").write_text("05:55:01 started: 9/9 agents; deadline later\n")
        svc = ShiftRecap(self.run, {}, self.audio())
        calls = []
        svc.schedule = lambda *args: calls.append(args)
        self.assertIsNone(svc.step(T0 + 14401))
        self.assertEqual(calls, [])

    def test_audio_receipt_persists_line_and_interrupts_started_audio(self):
        audio = AudioHub(str(self.run / "audio-played.jsonl"))
        tag = {"source": "shift1", "phase": "recap", "line": "prepared-line"}
        clip = audio.push({"channel": "caster", "speaker": "Vale", "duration": 6, "recap": tag}, b"x", "audio/mpeg")
        audio.played({"id": clip["id"], "state": "start", "duration": 6})
        self.assertTrue(audio.interrupt(clip["id"]))
        audio.played({"id": clip["id"], "state": "end", "duration": 6, "played": 6})
        records = list(R.rows(self.run / "audio-played.jsonl"))
        self.assertEqual(records[-1][1]["recap"], tag)
        self.assertTrue(records[-1][1]["completed"])

    def test_segments_and_casters_yield(self):
        segs = Segments()
        snap = {"shift_recap": {"active": True}, "alerts": []}
        self.assertIsNone(segs.step(snap, T0))
        code, result = segs.request({"type": "research"}, T0)
        self.assertEqual(code, 409)
        self.assertEqual(result["why"], "shift recap on air")
        import caster
        fake = type("Fake", (), {"snap": snap, "caster_free": 0, "playback_receipts": lambda *_: None})()
        caster.Caster.caster_tick(fake, T0, {})
        self.assertEqual(fake.caster_free, T0)


if __name__ == "__main__":
    unittest.main()
