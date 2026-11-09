#!/usr/bin/env python3
"""Offline launch configuration, every production speech entry point, and restoration/cache checks."""
import ast
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import caster
import hourly
import prepared_audio
import shift_recap
from shift_recap_air import ShiftRecap
import tour
import tts_trial
import voices

ROOT = Path(__file__).resolve().parents[2]
TRIAL = "gpt-4o-mini-tts-2025-03-20"
DEFAULT = "gpt-4o-mini-tts"
TEXT = "The copper line runs again."


class TrialTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.trial = self.root / "trial.json"
        self.trial.write_text(json.dumps({"run": "shift149", "openai_tts_model": TRIAL}))

    def launch_config(self, name):
        # Execute only the real config heredoc: never start a process, camera, or game.
        shell = (ROOT / "tools/start-team.sh").read_text()
        start = shell.index('python3 - "$team" "$rundir/stream.json"')
        code = shell[start:].split("<<'EOF'\n", 1)[1].split("\nEOF", 1)[0]
        run = self.root / name
        run.mkdir(exist_ok=True)
        team = self.root / "team.tsv"
        team.write_text("sol\tcodex\tlocal\tmodel\thigh\tSol\tharness\n")
        env = dict(os.environ, POG_TEST="1", POG_TTS_TRIAL_FILE=str(self.trial))
        subprocess.run([sys.executable, "-", str(team), str(run / "stream.json"), name, "240"],
                       input=code, text=True, env=env, cwd=ROOT, check=True)
        return run, json.loads((run / "stream.json").read_text())

    def test_exact_run_and_prior_settings(self):
        run, config = self.launch_config("shift149")
        self.assertEqual(config["audio"], {"openai_tts_model": TRIAL})
        self.assertIsNone(config["tts_trial"]["prior_audio"])
        for saved in config["tts_trial"]["paths"].values():
            self.assertEqual(saved, dict(prior_setting=None, prior_effective_model=DEFAULT,
                                         trial_effective_model=TRIAL))
        for name in ("shift148", "shift150", "shift149-extra"):
            _, other = self.launch_config(name)
            self.assertNotIn("audio", other)
            self.assertNotIn("tts_trial", other)
            self.assertEqual(voices.configured_openai_model(other), DEFAULT)
        original = {"audio": {"openai_tts_model": DEFAULT, "other": "kept"}}
        changed = tts_trial.apply(original, "shift149", self.trial)
        self.assertEqual(changed["tts_trial"]["prior_audio"], original["audio"])
        self.assertEqual(changed["audio"]["other"], "kept")
        self.assertEqual(original["audio"]["openai_tts_model"], DEFAULT)
        self.assertIs(tts_trial.apply(original, "shift150", self.trial), original)
        for bad in ('{', '{"run":"shift149","openai_tts_model":"typo"}', '{"run":"shift149"}'):
            self.trial.write_text(bad)
            self.assertIs(tts_trial.apply(original, "shift149", self.trial), original)
        self.trial.unlink()
        self.assertIs(tts_trial.apply(original, "shift149", self.trial), original)

    def test_every_path_and_prepared_cache(self):
        payloads, evidence, non_openai = {}, {}, []
        with ExitStack() as stack:
            stack.enter_context(patch.object(voices, "read_key", return_value="offline-test"))
            stack.enter_context(patch.object(voices, "duration", return_value=3))
            stack.enter_context(patch.object(voices, "normalize", side_effect=lambda a, c, t: (a, c)))
            stack.enter_context(patch.object(voices, "respace_model", return_value=None))
            stack.enter_context(patch.dict(os.environ, {"POG_TTS_OFF": "", "POG_TTS_CACHE": "",
                                                       "POG_TTS_IPA": "0", "POG_RECAP_TTS": "auto"}))
            stack.enter_context(patch.object(hourly, "openrouter_key", return_value=None))
            stack.enter_context(patch.object(tour, "voices_in_use", return_value={}))
            stack.enter_context(patch.object(tour.subtitles, "for_clip", return_value=[]))
            stack.enter_context(patch.object(prepared_audio, "transcribe", side_effect=lambda a, c: a.decode()))
            sent = []
            def http(method, url, headers, body=None, timeout=45):
                sent.append((url, body))
                return TEXT.encode(), "audio/mpeg"
            stack.enter_context(patch.object(voices, "_http", side_effect=http))
            manifests = []
            out = self.root / "clips"
            script = self.root / "script.json"
            script.write_text(json.dumps({"stops": [{"id": "a", "target": {"surface": "nauvis", "x": 0, "y": 0},
                                                     "narration": TEXT}]}))
            for name, expected in (("shift149", TRIAL), ("shift150", DEFAULT)):
                run, config = self.launch_config(name)
                evidence[name] = {}
                def speak(path, tts, voice="oa-fable", **kw):
                    tts.speak(TEXT, voice, **kw)
                    body = sent[-1][1]
                    self.assertEqual(body["model"], expected, path)
                    evidence[name][path] = body["model"]
                    payloads.setdefault(path, []).append(body)
                args = caster.parser().parse_args(["--writer", "template", "--classifier", "heuristic",
                    "--tts", "auto", "--tts-fallback", "openai", "--run-dir", str(run), "--log-dir", str(run)])
                host = caster.Caster(args)
                speak("hosts", host.tts, "thalia", caster="color", direction="slow and calm.")
                speak("agent_speech", host.tts)
                speak("caster_fallback", host.tts_fallback)
                host.tts.speak(TEXT, "atlas", caster="pbp", direction="slow and calm.")
                non_openai.append(sent[-1])

                def recap_prepare(*args, **kw):
                    speak("recap_service", kw["tts"], "thalia", caster="color")
                svc = ShiftRecap(run, config, None)
                # Incoming evidence can belong to the prior shift: audio belongs to the playback shift.
                with patch.object(shift_recap, "prepare", side_effect=recap_prepare) as prepare:
                    svc.build(self.root / "shift148", 100, True)
                    self.assertEqual(prepare.call_count, 1)
                def cli_prepare(*args, **kw):
                    speak("recap_cli", kw["tts"], "thalia", caster="color")
                    return {"lines": [], "evidence": {"coverage": {}}, "review": {}}
                with patch.object(sys, "argv", ["shift_recap.py", "prepare", "--run-dir", str(self.root / "shift148"),
                     "--audio-run-dir", str(run), "--out", str(out), "--tts", "auto"]), \
                     patch.object(shift_recap, "prepare", side_effect=cli_prepare):
                    shift_recap.main()

                args = tour.parser().parse_args(["prepare", str(script), "--out", str(out),
                                                 "--voice", "oa-fable", "--run-dir", str(run)])
                before = len(sent)
                self.assertEqual(tour.prepare(args), 0)
                self.assertEqual(len(sent), before + 1, "model switch must synthesize new narration")
                self.assertEqual(sent[-1][1]["model"], expected)
                evidence[name]["tour_narration"] = sent[-1][1]["model"]
                payloads.setdefault("tour_narration", []).append(sent[-1][1])
                manifest = tour.read_manifest(out)
                manifests.append(manifest)
                self.assertIsNotNone(tour.clip_for(manifest, out, tour.checked(tour.load_script(script))[0][1]))
                self.assertEqual(tour.prepare(args), 0)
                self.assertEqual(len(sent), before + 1, "same model reuses the checked clip")
                with patch.object(tour, "VOICES", ["oa-fable"]):
                    airing = hourly.Airing(object(), run_dir=run)
                    hourly_out = self.root / (name + "-hourly")
                    self.assertIsNotNone(airing.renderer(str(script), str(hourly_out)))
                self.assertEqual(sent[-1][1]["model"], expected)
                evidence[name]["hourly_narration"] = sent[-1][1]["model"]
                payloads.setdefault("hourly_narration", []).append(sent[-1][1])

                # Execute the actual standalone CLI body with the same mocked providers.
                tree = ast.parse(Path(voices.__file__).read_text())
                cli = ast.Module(body=[tree.body[-1]], type_ignores=[])
                with patch.object(sys, "argv", ["voices.py", TEXT, "--tts", "openai", "--voice", "oa-fable",
                     "--run-dir", str(run), "--out", str(run)]):
                    exec(compile(cli, voices.__file__, "exec"), dict(vars(voices), __name__="__main__"))
                self.assertEqual(sent[-1][1]["model"], expected)
                evidence[name]["speech_cli"] = sent[-1][1]["model"]
                payloads.setdefault("speech_cli", []).append(sent[-1][1])
                self.assertEqual(set(evidence[name]), set(tts_trial.PATHS))
            self.assertNotEqual(manifests[0]["clips"]["a"]["hash"], manifests[1]["clips"]["a"]["hash"])
            # Reusing restored clips for the trial must fail before contacting the playback service.
            args = tour.parser().parse_args(["run", str(script), "--out", str(out),
                                             "--run-dir", str(self.root / "shift149")])
            with patch.object(tour, "Service", side_effect=AssertionError("must not contact live service")):
                self.assertEqual(tour.run(args), 1)
            self.assertEqual(non_openai[0], non_openai[1], "Rook's provider, voice, and instructions stay identical")
            for path, bodies in payloads.items():
                self.assertEqual([{k: v for k, v in b.items() if k != "model"} for b in bodies][0],
                                 {k: v for k, v in bodies[1].items() if k != "model"}, path)
        print("Effective speech model IDs (mocked requests): " + json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
