#!/usr/bin/env python3
"""Delivery stays with durable line IDs; actual backend payloads, timeout retries, and recap caches.
Offline by default; --capture PATH writes sanitized mocked payloads for operator review.
"""
import json
import os
import sys
import threading
from pathlib import Path
from unittest.mock import patch
from contextlib import ExitStack
from collections import deque
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import voices  # noqa: E402


def prompt_and_parse():
    assert "Delivery: ..." in caster.EXCHANGE_RULES and "Delivery: natural" in caster.EXCHANGE_RULES
    text = ("Rook: Biters are hitting Nauvis. A laser turret is taking the fire.\n"
            "Delivery: quick and urgent, stress 'laser turret', rising.\n"
            "Vale: That wall has held all shift. It holds again.\n"
            "Delivery: natural\n"
            "Rook: Opus is on shift there.\n"
            "Rook: And the turrets are fed.\n"
            "Delivery: in a thick Scottish accent, like a pirate.\n")
    dirs = []
    lines = caster.parse_exchange(text, dirs)
    assert [w for w, _ in lines] == ["pbp", "color", "pbp", "pbp"], lines
    assert lines[0][1] == "Biters are hitting Nauvis. A laser turret is taking the fire.", "the words unchanged"
    assert dirs == ["quick and urgent, stress 'laser turret', rising.", None, None, None], dirs
    assert caster.parse_exchange(text) == lines, "without a list: the lines as before"
    assert caster.parse_exchange("Delivery: tense\nVale: Hm.", dirs) == [("color", "Hm.")] and dirs == [None]
    assert caster.clean_direction("Delivery: soft, almost a whisper, slowing on the last word") == \
        "soft, almost a whisper, slowing on the last word."
    long = caster.clean_direction("warm " * 80)
    assert long and len(long) <= caster.DELIVERY_MAX + 1, long
    for d in ("", "natural.", "Natural delivery", "with a British accent", "do an impression of Sol"):
        assert caster.clean_direction(d) is None, d


class FakeTTS:
    backend = "auto"

    def __init__(self):
        self.calls, self.last, self.lock = [], {}, threading.Lock()

    def speak(self, text, voice, caster=None, mood=None, direction=None):
        with self.lock:
            self.calls.append((text, caster, mood, direction))
        self.last = {"provider": "openai", "voice": "ballad", "mood": mood or "neutral", "cached": False}
        return b"mp3", "audio/mpeg", 0.01, 0.0


def speak_lines_path(tmp):
    cs = caster.Caster.__new__(caster.Caster)
    cs.a = SimpleNamespace(dry_run=False, always=True)
    cs.lock, cs.events, cs.prep, cs.stats = threading.Lock(), deque(), [], {"skipped_no_listener": 0}
    cs.tts, cs.tts_fallback = FakeTTS(), None
    cs.breakers = {"tts": caster.Breaker("tts")}
    cs.caster_free = cs.agent_free = 0.0
    cs.next_gap, cs.snap, cs.log_path, pushed = 0.0, None, os.path.join(tmp, "caster.jsonl"), []
    cs.push = lambda meta, audio, ctype: pushed.append(meta) or dict(meta, id=f"clip-{len(pushed)}")
    lines = [("pbp", "Biters are hitting Nauvis."), ("color", "That wall has held all shift.")]
    e = {"kind": "attack", "prio": caster.PRIORITY["attack"], "t": 0, "directions": ["quick and urgent.", None]}
    cs.speak_lines(lines, e, {}, "fake", None, 0.0, 0.0)
    calls = sorted(cs.tts.calls)
    assert ("Biters are hitting Nauvis.", "pbp", "tense", "quick and urgent.") in calls, calls
    assert ("That wall has held all shift.", "color", "tense", None) in calls, calls
    recs = [json.loads(x) for x in open(cs.log_path)]
    assert recs[0]["delivery"] == "quick and urgent." and "delivery" not in recs[1], recs
    assert [m["text"] for m in pushed] == [x for _, x in lines], "the words pushed are the lines"


def resume_and_restart(tmp):
    from playback_memory import PlaybackMemory
    from test_story_receipts import Clock, host, event, speak, played
    clock = Clock()
    with patch("time.time", clock.now), patch("time.sleep", clock.sleep):
        for legacy in (False, True):
            path = str(Path(tmp) / f"playback-{legacy}.json")
            c, hub = host(clock, PlaybackMemory(path))
            calls = []
            def synth(tts, text, voice, **kw):
                calls.append((text, kw.get("direction")))
                return b"audio", "audio/mpeg", 2, 0, {"voice": voice}
            c.speak_clip = synth
            e = dict(event(c, clock), directions=["quick and urgent.", "slow and calm."])
            gid = speak(c, e, clock)
            rows = c.playback().groups[gid]["lines"]
            ids = [r["id"] for r in rows]
            assert len(set(ids)) == 2
            played(hub, rows[0]["cid"], "start", clock)
            played(hub, rows[0]["cid"], "end", clock, played=2)
            played(hub, rows[1]["cid"], "start", clock)
            played(hub, rows[1]["cid"], "cut", clock, played=.4)
            c.playback_receipts(hub.status())
            calls.clear()
            assert c.resume_explanation(hub.status())
            assert calls == [(rows[1]["text"], "slow and calm.")], calls
            assert rows[0]["attempt"] == 1 and rows[1]["attempt"] == 2
            c.playback().change(gid, 1, "interrupted")
            if legacy:
                disk = json.loads(Path(path).read_text())
                g = disk["groups"][gid]
                g.pop("directions")
                g["event"]["directions"] = e["directions"]
                for row in g["lines"]:
                    row.pop("id")
                Path(path).write_text(json.dumps(disk))
            restored = PlaybackMemory(path)
            c, hub = host(clock, restored)
            c.speak_clip = synth
            calls.clear()
            assert c.resume_explanation(hub.status())
            assert calls == [(rows[1]["text"], "slow and calm.")], calls
            group = restored.groups[gid]
            assert [r["id"] for r in group["lines"]] == ids
            assert "directions" not in group["event"]
            assert group["directions"] == dict(zip(ids, e["directions"]))
            assert c.records[-1]["line_id"] == ids[1]
            assert group["lines"][0]["attempt"] == 1 and group["lines"][1]["attempt"] == 3


def engines(tmp):
    sent = []
    text = "The wall has held all shift."
    direction = "slow and calm."
    class AI:
        def run(self, model, body, **kw):
            sent.append({"endpoint": "workers-ai:" + model, "body": body})
            return b"ID3", "audio/mpeg"
    def http(method, url, headers, body=None, timeout=45):
        # Deliberately never record headers or credentials, even in the mock evidence.
        sent.append({"endpoint": url, "body": body})
        return (b'{"audioContent": "SUQz"}', "application/json") if "inworld" in url else (b"ID3", "audio/mpeg")
    with ExitStack() as stack:
        stack.enter_context(patch.object(voices, "read_key", lambda name: "test-key"))
        stack.enter_context(patch.object(voices, "_http", http))
        stack.enter_context(patch.object(voices, "duration", lambda *a: 1.0))
        stack.enter_context(patch.object(voices, "respace_model", lambda *a: None))
        stack.enter_context(patch.dict(os.environ, {"POG_TTS_OFF": "", "POG_TTS_IPA": "0", "POG_TTS_CACHE": ""}))
        def local(name):
            def synth(*args):
                sent.append({"endpoint": "local:" + name, "args": list(args)})
                return b"ID3", "audio/mpeg"
            return synth
        stack.enter_context(patch.object(voices, "_say", local("say")))
        stack.enter_context(patch.object(voices, "_tone", local("tone")))
        def make(backend="auto", **kw):
            return voices.TTS(backend, ai=AI(), target=None, **kw)
        auto = make()
        for voice, role in [("atlas", "pbp"), ("thalia", "color"), ("el-george", None),
                            ("oa-cedar", None), ("ca-daniel", None), ("in-dennis", None)]:
            auto.speak(text, voice, caster=role, direction=direction)
            directed = sent[-1]
            auto.speak(text, voice, caster=role)
            plain = sent[-1]
            body, base = directed["body"], plain["body"]
            assert directed["endpoint"] == plain["endpoint"]
            for key in ("voice", "voiceId", "model", "model_id", "modelId"):
                assert body.get(key) == base.get(key), (body, base)
            if "elevenlabs" in directed["endpoint"]:
                assert body["text"] == base["text"] and "slow and calm" not in body["text"], body
            elif "inworld" in directed["endpoint"]:
                assert body["text"] == "[slow and calm.] " + text, body
                assert "instruction" not in body
            elif "openai" in directed["endpoint"]:
                assert body["input"] == text and body["instructions"].endswith("This line: " + direction)
            else:
                assert body["transcript"] == text and body["generation_config"] == {"speed": .9, "emotion": "calm"}
            directed.update(case="host-" + role if role else "agent-" + voice, mode="mock")
        # Flash has speed, not instruction tags. A rejected Turbo request must not leak its tag into Flash.
        fast = make("eleven-fast", cache=str(Path(tmp) / "cache-flash"))
        def refuse(method, url, headers, body=None, timeout=45):
            response = http(method, url, headers, body, timeout)
            if body.get("model_id") == "eleven_v4_turbo":
                raise voices.TTSError("403 model unavailable")
            return response
        with patch.object(voices, "_http", refuse):
            fast.speak(text, "el-eric", direction=direction)
        assert sent[-1]["body"]["text"] == text
        assert sent[-1]["body"]["voice_settings"]["speed"] == .9
        assert sent[-1]["endpoint"] == sent[-2]["endpoint"]
        assert not list(Path(fast.cache).rglob("*.mp3")), "Flash must not be cached as a directed Turbo clip"
        sent[-1].update(case="eleven-flash-fallback", mode="mock")
        for backend in ("aura2", "aura1", "melotts", "say", "tone"):
            tts = make(backend)
            tts.speak(text, "atlas", caster="pbp", direction=direction)
            directed = sent[-1]
            tts.speak(text, "atlas", caster="pbp")
            assert directed == sent[-1], (backend, directed, sent[-1])
            directed.update(case=backend, mode="mock")
        for unsupported in ("tts-1", "tts-1-hd"):
            p = voices.OpenAITTS(unsupported)
            p.synth(text, "ballad", "neutral", direction, direction=direction)
            assert "instructions" not in sent[-1]["body"]
        assert voices.delivery_controls("not excited, not fast") == {}
        assert voices.delivery_controls("stress 'excited' and 'quick'") == {}
        assert voices.delivery_controls("slow then quick") == {}
        assert voices.clean_direction({"tone": "sad"}) is None
        assert voices.clean_direction("a different voice") is None
        assert voices.clean_direction("[]") is None and voices.clean_direction("[natural]") is None
        assert "[" not in voices.clean_direction("[slow]")
        # Every cloud route retries timeout with the same voice, natural delivery, no directed-cache entry.
        for voice, role in [("atlas", "pbp"), ("thalia", "color"), ("el-george", None),
                            ("ca-daniel", None), ("in-dennis", None), ("orion", None)]:
            tts = make(cache=str(Path(tmp) / ("cache-" + voice)))
            original = tts._synth_once
            count = 0
            def timeout_once(*args):
                nonlocal count
                count += 1
                response = original(*args)
                if count == 1:
                    raise voices.TTSError("unreachable: timed out")
                return response
            with patch.object(tts, "_synth_once", timeout_once):
                tts.speak(text, voice, caster=role, mood="excited", direction=direction)
            assert count == 2 and tts.last_here()["retried"] == "timeout_plain"
            assert tts.last_here()["mood"] == "neutral"
            a, b = sent[-2:]
            assert a["endpoint"] == b["endpoint"]
            for key in ("voice", "voiceId", "speaker", "model", "model_id", "modelId"):
                assert a["body"].get(key) == b["body"].get(key)
            assert "instructions" not in b["body"]
            assert not b["body"].get("text", "").startswith("[")
            if "generation_config" in b["body"]:
                assert b["body"]["generation_config"] == {"emotion": "neutral", "speed": 1.0}
            assert not list(Path(tts.cache).rglob("*.mp3"))
            b.update(case="timeout-plain-" + voice, mode="mock")
        assert voices.is_timeout(TimeoutError())
        assert voices.is_timeout(voices.urllib.error.URLError(TimeoutError()))
        assert voices.is_timeout(voices.TTSError("504 upstream"))
        tts = make()
        with patch.object(tts, "_synth_once", side_effect=TimeoutError()) as fail:
            try:
                tts.speak(text, "atlas", caster="pbp", direction=direction)
                assert False, "double timeout must terminate"
            except voices.TTSTimeout:
                assert fail.call_count == 2 and not tts.down, "no voice swap on timeout"
        # A retry should not overwrite the directed cache; a later successful rendition is reusable.
        tts = make(cache=str(Path(tmp) / "cache-success"))
        for d in (direction, "quick and excited.", direction):
            tts.speak(text, "oa-ballad", direction=d)
        assert tts.last_here()["cached"]
        # Both configured models make requests with distinct cache entries; restarting reuses only its own model.
        model_cache = str(Path(tmp) / "model-cache")
        start = len(sent)
        for model in voices.OPENAI_TTS_MODELS * 2:
            tts = make("openai", cache=model_cache, openai_model=model)
            tts.speak(text, "thalia", caster="color", direction=direction)
            assert tts.last_here()["model"] == model
        assert [r["body"]["model"] for r in sent[start:]] == list(voices.OPENAI_TTS_MODELS)
        assert len(list(Path(model_cache).rglob("*.mp3"))) == 2
        for row in sent[start:]:
            row.update(case="persistent-model-selector", mode="mock")
        # Actual host startup (primary AND fallback) reads the saved setting anew, without altering it.
        run = Path(tmp) / "run"
        run.mkdir()
        args = caster.parser().parse_args(["--writer", "template", "--classifier", "heuristic", "--tts", "openai",
                                          "--tts-fallback", "openai", "--run-dir", str(run), "--log-dir", str(run)])
        assert voices.configured_openai_model(run_dir=run) == voices.DEFAULT_OPENAI_TTS_MODEL
        for model in voices.OPENAI_TTS_MODELS:
            config = {"audio": {"openai_tts_model": model}}
            (run / "stream.json").write_text(json.dumps(config))
            host = caster.Caster(args)
            assert host.tts.providers["openai"].model == host.tts_fallback.providers["openai"].model == model
            assert json.loads((run / "stream.json").read_text()) == config
        try:
            voices.configured_openai_model({"audio": {"openai_tts_model": "typo"}})
            assert False, "invalid setting must fail clearly"
        except ValueError:
            pass
    return [dict(row, keys=sorted(row.get("body", {}))) for row in sent]


def main():
    import argparse
    import tempfile
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    prompt_and_parse()
    with tempfile.TemporaryDirectory() as tmp:
        speak_lines_path(tmp)
        resume_and_restart(tmp)
        requests = engines(tmp)
    if args.capture:
        args.capture.write_text(json.dumps(requests, indent=2) + "\n")
    print("delivery: ok (durable line IDs, legacy restart, model-specific payloads, same-voice natural timeout retry)")


if __name__ == "__main__":
    main()
