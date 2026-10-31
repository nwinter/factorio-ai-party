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
        return text.encode(), "audio/mpeg", max(1, len(text) / 15), 0


class RecapTest(unittest.TestCase):
    def setUp(self):
        import prepared_audio
        transcript = patch.object(prepared_audio, "transcribe", lambda audio, ctype: audio.decode())
        transcript.start()
        self.addCleanup(transcript.stop)
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

    def test_writer_delivery_stays_on_accepted_line(self):
        e = R.gather(self.old, T0 + 10800)
        source = next(r["id"] for r in e["rows"] if r["kind"] == "research")
        lines = [dict(speaker="Rook", title="Research", text="Research finished: logistics 53.",
                      sources=[source], direction="quick and excited."),
                 dict(speaker="Vale", title="Research", text="Research finished: logistics 2.",
                      sources=[source], direction="slow and calm.")]
        class Writer:
            def complete(self, system, user, **kw):
                if system.startswith("Fact-check"):
                    script = json.loads(user)["script"]
                    assert [r["line"] for r in script] == [2]
                    return json.dumps({"lines": [{"line": 2, "ok": True}]})
                return json.dumps({"lines": lines})
        script, review = R.write_script(e, Writer())
        self.assertEqual(script, lines[1:])
        self.assertEqual(review["attempts"][0]["failures"][0]["number"], "53")
        self.assertIsNone(R.check(script, e))
        self.assertTrue(all("direction" not in row for row in R.fallback(e)))

    def test_delivery_render_cache_and_natural_timeout(self):
        calls = []
        class Capture(TTS):
            retried = None
            def speak(self, text, voice, **kw):
                calls.append((text, voice, kw))
                return super().speak(text, voice, **kw)
            def last_here(self):
                return {"retried": self.retried}
        tts = Capture()
        line = dict(speaker="Vale", title="Research", text="Research finished: logistics 2.", sources=["r"])
        plain = R.render_lines([line], self.out, tts)[0]
        directed = R.render_lines([dict(line, direction="slow and calm.")], self.out, tts)[0]
        again = R.render_lines([dict(line, direction="slow and calm.")], self.out, tts)[0]
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][2], {"caster": "color"})
        self.assertEqual(calls[1][2], {"caster": "color", "direction": "slow and calm."})
        self.assertNotEqual(plain["id"], directed["id"])
        self.assertEqual(directed, again)
        tts.retried = "timeout_plain"
        new = dict(line, direction="quick and excited.")
        R.render_lines([new], self.out, tts)
        R.render_lines([new], self.out, tts)
        self.assertEqual(len(calls), 4, "timeout audio must be synthesized again, not cached as directed")

    def test_model_switch_rebuilds_final_manifest_before_playback(self):
        import voices
        from types import SimpleNamespace
        class ModelTTS(TTS):
            backend = "auto"
            def __init__(self, model):
                self.openai_model, self.calls, self.last = model, [], {}
                self.providers = {"openai": SimpleNamespace(model=model)}
            def route(self, voice, role):
                return "openai", "cedar" if role == "pbp" else "ballad"
            def speak(self, text, voice, **kw):
                self.calls.append(text)
                self.last = dict(provider="openai", voice=self.route(voice, kw["caster"])[1], model=self.openai_model)
                return super().speak(text, voice, **kw)
            def last_here(self):
                return self.last
        default, snapshot = [ModelTTS(m) for m in voices.OPENAI_TTS_MODELS]
        old = R.prepare(self.old, self.out, T0 + 14400, tts=default, final=True)
        audio = self.audio()
        player = Player(self.run, self.old, audio, tts_config=voices.audio_config(snapshot))
        player.state["completed"] = [old["lines"][0]["id"]]
        self.assertEqual(player.step(T0 + 14401)["title"], "Shift change")
        self.assertFalse(audio.clips, "old prepared audio must not play during replacement")
        new = R.prepare(self.old, self.out, T0 + 14400, tts=snapshot, final=True)
        for field in ("evidence", "review", "through", "final"):
            self.assertEqual(old[field], new[field], field)
        for section in ("lines", "transition"):
            for a, b in zip(old[section], new[section]):
                self.assertEqual(a["id"], b["id"], "heard-line identity survives an asset/model change")
                self.assertEqual(a["text"], b["text"])
                self.assertNotEqual(a["asset"], b["asset"])
        count = len(snapshot.calls)
        self.assertEqual(R.prepare(self.old, self.out, T0 + 14400, tts=snapshot, final=True), new)
        self.assertEqual(len(snapshot.calls), count)
        player.step(T0 + 14402)
        self.assertTrue(audio.clips)
        self.assertEqual(player.current["line"]["id"], old["lines"][1]["id"])
        back = R.prepare(self.old, self.out, T0 + 14400, tts=default, final=True)
        self.assertEqual([r["asset"] for r in back["lines"]], [r["asset"] for r in old["lines"]])
        # The service reads the selector at startup, uses it for recap builds and waits on incompatible manifests.
        cfg = {"audio": {"openai_tts_model": snapshot.openai_model}}
        svc = ShiftRecap(self.run, cfg, self.audio())
        calls = []
        svc.schedule = lambda *args: calls.append(args)
        svc.step(T0 + 14401)
        self.assertTrue(calls and not svc.final_previous)
        with patch.object(voices, "TTS", return_value=snapshot) as factory, patch.object(R, "prepare"):
            svc.build(self.old, T0 + 14400, True)
        factory.assert_called_once_with("auto", openai_model=snapshot.openai_model)

    def test_legacy_cache_keeps_receipt_without_new_synthesis(self):
        class Routed(TTS):
            def __init__(self): self.last, self.calls = {}, 0
            def route(self, voice, role): return "openai", "ballad"
            def last_here(self): return self.last
            def speak(self, text, voice, **kw):
                self.calls += 1
                self.last = {"provider": "openai", "voice": "ballad"}
                return super().speak(text, voice, **kw)
        line = {"speaker": "Vale", "title": "Copper", "text": "The copper line runs again.", "sources": []}
        rendered = R.render_lines([line], self.out, Routed())[0]
        path = (self.out / "assets" / rendered["asset"]).with_suffix(".json")
        meta = R.read_json(path); meta.pop("audio_check"); R.save_json(path, meta)
        fresh = Routed()
        R.render_lines([line], self.out, fresh)
        self.assertEqual(fresh.calls, 0)
        self.assertTrue(R.read_json(path)["audio_check"]["passed"])
        with patch("prepared_audio.transcribe", side_effect=AssertionError("checked cache was retranscribed")):
            self.assertEqual(R.render_lines([line], self.out, fresh)[0]["asset"], rendered["asset"])
        self.assertEqual(fresh.calls, 0)

    def test_legacy_and_changed_audio_require_preparation(self):
        import prepared_audio
        manifest = self.prepare()
        first = manifest["lines"][0]
        first.pop("audio_check")
        meta_path = (self.out / "assets" / first["asset"]).with_suffix(".json")
        meta = R.read_json(meta_path)
        meta.pop("audio_check")
        R.save_json(meta_path, meta)
        manifest.pop("audio_check_v")
        R.save_json(self.out / "manifest.json", manifest)
        audio = self.audio()
        player = Player(self.run, self.old, audio)
        player.step(T0 + 14401)
        self.assertFalse(any(m[2].get("channel") == "caster" for m in audio.clips.values()))
        rebuilt = self.prepare()
        self.assertEqual(rebuilt["audio_check_v"], prepared_audio.VERSION)
        self.assertTrue(R.read_json(meta_path)["audio_check"]["passed"])
        player.step(T0 + 14407)
        self.assertTrue(any(m[2].get("channel") == "caster" for m in audio.clips.values()))
        # A changed file cannot be vouched for by a receipt for its old bytes.
        audio2 = self.audio()
        (self.out / "assets" / first["asset"]).write_bytes(b"other speech")
        Player(self.run, self.old, audio2).step(T0 + 14408)
        self.assertFalse(any(m[2].get("channel") == "caster" for m in audio2.clips.values()))

    def test_exact_number_forms_and_citation_scope(self):
        e = {"rows": [{"id": "a", "text": "Astra reported four new stern railguns and two aft engines. "
                       "Sol reported sixMIL resumed, a twenty-minute test, zero active reminders, and 4,000 bricks.",
                       "source": "chat.jsonl", "row": 38, "wall_time": "09:42 PDT"},
                      {"id": "b", "text": "There were 57 launches.", "source": "scores.jsonl", "row": 2}]}
        line = {"speaker": "Vale", "title": "Progress", "sources": ["a"],
                "text": "Astra reported 4 new stern railguns and 2 aft engines. Sol reported 6 military science makers, "
                        "a 20-minute test, 0 active reminders and 4000 bricks."}
        self.assertIsNone(R.check([line], e))
        e["run"] = "shift106"
        line["text"] = "In shift 106, Astra reported 4 new stern railguns."
        self.assertIsNone(R.check([line], e))
        line["text"] = "Astra reported 106 railguns."
        self.assertEqual(R.claim_issues([line], e)[0]["number"], "106")
        line["text"] = "Sol reported fifty-seven launches."
        issue = R.claim_issues([line], e)[0]
        self.assertEqual(issue["number"], "fifty-seven")
        self.assertEqual(issue["value"], "57")
        self.assertEqual(issue["claim"], line["text"])
        self.assertEqual(issue["uncited_matches"][0]["id"], "b")
        line["text"] = "Sol reported 42 launches."  # clock components are not quantities
        self.assertEqual(R.claim_issues([line], e)[0]["number"], "42")
        line["text"], line["title"] = "Astra reported 4 new stern railguns.", "Eight engines"
        self.assertEqual(R.claim_issues([line], e)[0]["field"], "title")
        line["title"], line["text"] = "Progress", "Astra reported progress at 09:43."
        self.assertEqual(R.claim_issues([line], e)[0]["number"], "09:43")

    def test_refusals_keep_drafts_and_surviving_narrative(self):
        e = R.gather(self.old, T0 + 10800)
        source = next(r["id"] for r in e["rows"] if r["kind"] == "research")
        lines = [{"speaker": "Rook", "title": "Research", "text": "Research finished: logistics 2.", "sources": [source]},
                 {"speaker": "Vale", "title": "Research", "text": "Research finished: logistics 53.", "sources": [source]},
                 {"speaker": "Rook", "title": "Research", "text": "The research caused the ship's destruction.", "sources": [source]}]
        class Writer:
            def complete(self, system, *a, **kw):
                if system.startswith("Fact-check"):
                    return json.dumps({"lines": [{"line": 1, "ok": True}, {"line": 3, "ok": False,
                        "claim": lines[2]["text"], "reason": "no causal evidence"}]})
                return json.dumps({"lines": lines})
        script, review = R.write_script(e, Writer(), self.out / "audit")
        self.assertEqual(script, lines[:1])
        self.assertEqual(review["mode"], "model plus evidence review")
        self.assertEqual(review["attempts"][0]["failures"][0]["number"], "53")
        self.assertEqual(review["attempts"][0]["failures"][1]["claim"], lines[2]["text"])
        audits = list((self.out / "audit").glob("*.json"))
        self.assertEqual(len(audits), 2)
        for path in audits:
            saved = R.read_json(path)
            self.assertEqual(json.loads(saved["raw_draft"])["lines"], lines)
            self.assertEqual(saved["accepted"], [1])
            self.assertIn("raw_review", saved)

    def test_repaired_citation_outside_selection_reaches_reviewer(self):
        e = {"rows": [{"id": "a", "text": "The recorded total was 20 launches."},
                      {"id": "b", "text": "The recorded total was 57 launches."}]}
        class Writer:
            drafts = 0
            def complete(inner, system, user, **kw):
                if system.startswith("Fact-check"):
                    rows = {r["id"]: r for r in json.loads(user)["evidence"]["rows"]}
                    self.assertIn("b", rows)
                    return json.dumps({"lines": [{"line": 1, "ok": True}]})
                inner.drafts += 1
                return json.dumps({"lines": [{"speaker": "Rook", "title": "Launches",
                    "text": "The recorded total was 57 launches.", "sources": ["a" if inner.drafts == 1 else "b"]}]})
        with patch.object(R, "selection", return_value=e["rows"][:1]):
            script, review = R.write_script(e, Writer())
        self.assertEqual(review["mode"], "model plus evidence review")
        self.assertEqual(script[0]["sources"], ["b"])
        self.assertEqual(review["attempts"][0]["failures"][0]["uncited_matches"][0]["id"], "b")

    def test_readable_extracts_and_headline_titles(self):
        R.save_json(self.old / "host-memo.json", {"headlines": [
            {"t": T0 + 50, "text": "Rocket 76912 launched, the first this shift"},
            {"t": T0 + 55, "text": "Swift was lost to asteroids"}]})
        e = R.gather(self.old, T0 + 10800)
        for text in ("Laneinjection nowindependentFe rightjam", "CellA2818 retained. 2821 sixMIL",
                     "sol said: Fuel4/Fe5000 all8guarded, next5min proof."):
            e["rows"].append({"kind": "chat", "text": text, "id": text, "weight": 10, "t": T0})
        e["rows"].append({"kind": "tell", "text": "This is a perfectly readable tell but still excluded.",
                          "id": "tell", "weight": 10, "t": T0})
        script = R.fallback(e)
        refs = {r["id"]: r for r in e["rows"]}
        self.assertTrue(script)
        self.assertTrue(all(refs[l["sources"][0]]["kind"] in {"chat", "chronicle", "milestone", "loss", "research"} for l in script))
        self.assertFalse(any("Laneinjection" in l["text"] or "CellA" in l["text"] or "Fuel4" in l["text"] for l in script))
        launch = next(l for l in script if "Rocket 76912" in l["text"])
        self.assertEqual(launch["title"], "Rocket launches")
        self.assertEqual(refs[launch["sources"][0]]["kind"], "milestone")
        self.assertEqual(next(l["title"] for l in script if "Swift" in l["text"]), "Recorded loss")

    def test_shift106_saved_record_replays_as_narrative(self):
        fixture = R.read_json(Path(__file__).parent / "fixtures" / "shift106-recap.json")
        class Writer:
            def complete(self, system, *a, **kw):
                return json.dumps(fixture["review"] if system.startswith("Fact-check") else fixture["draft"])
        script, review = R.write_script(fixture["evidence"], Writer(), self.out / "audit")
        self.assertEqual(review["mode"], "model plus evidence review")
        self.assertEqual(review["attempts"][0]["accepted"], fixture["expected_accepted"])
        self.assertGreaterEqual(len(script), 24)
        self.assertIsNone(R.check(script, fixture["evidence"]))
        self.assertTrue(any("Asterion" in line["text"] for line in script))
        self.assertTrue(any(f.get("number", "").lower() == "three" for f in review["attempts"][0]["failures"]))

    def test_pre_cp3_manifest_can_receive_final_pass(self):
        m = self.prepare()
        m["review"] = {"mode": "record extracts", "attempts": ["number absent from cited record"]}
        R.save_json(self.out / "manifest.json", m)
        final = self.prepare(final=True)
        self.assertTrue(final["final"])
        self.assertIn("original draft was not retained", (self.out / "review.md").read_text())

    def test_malformed_draft_is_durable_before_fallback(self):
        e = R.gather(self.old, T0 + 10800)
        class Writer:
            def complete(self, *a, **kw):
                return '{"lines": [cut off'
        script, review = R.write_script(e, Writer(), self.out / "audit")
        self.assertEqual(review["mode"], "record extracts")
        self.assertTrue(script)
        self.assertEqual(len(list((self.out / "audit").glob("*.json"))), 2)
        for path in (self.out / "audit").glob("*.json"):
            self.assertEqual(R.read_json(path)["raw_draft"], '{"lines": [cut off')

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

    def test_early_service_publishes_current_beat_before_agents_and_restores_on_end(self):
        p = Player(self.run, self.old, self.audio())
        self.assertTrue(p.step(T0)["active"], "preparing card needs no world snapshot")
        manifest = self.prepare()
        first = p.step(T0 + 1)
        self.assertEqual(first["id"], manifest["lines"][0]["id"])
        self.assertIn("time_label", first)
        self.assertNotIn("sources", first)
        self.assertNotIn("timeline", first)
        self.assertEqual(p.step(T0 + 4)["id"], first["id"], "page reload receives the current beat")
        self.assertEqual(p.public["elapsed"], 1)
        p.finish("interrupted")
        self.assertIsNone(p.step(T0 + 5))
        self.assertIsNone(Player(self.run, self.old, self.audio()).step(T0 + 6))

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
