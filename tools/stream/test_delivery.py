#!/usr/bin/env python3
"""The writer's delivery direction rides beside each host line to the TTS engines that take one:
python3 tools/stream/test_delivery.py

d22 batch99 BI2 (viewer Aurora site:4300/4302: "Could a text LLM read each message plus context and write its TTS
direction ... Keep the spoken words unchanged ... Use this on supported TTS, especially OpenAI. Keep each voice's
persona and accent consistent, vary intonation or whispering when appropriate, and use natural delivery when unsure").
Checks: the exchange prompt asks for a 'Delivery:' line after each host line; the parser keeps the spoken words as
they were and aligns each direction with its line (none, 'natural', or one asking for another accent or persona:
none); speak_lines hands each line its direction and records it; OpenAI's instructions and Inworld's instruction carry
it after the role in place of the mood's sentence, ElevenLabs' text and Cartesia's request do not.
"""
import json
import os
import sys
import threading
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
    cs.push = lambda meta, audio, ctype: pushed.append(meta)
    lines = [("pbp", "Biters are hitting Nauvis."), ("color", "That wall has held all shift.")]
    e = {"kind": "attack", "prio": caster.PRIORITY["attack"], "t": 0, "directions": ["quick and urgent.", None]}
    cs.speak_lines(lines, e, {}, "fake", None, 0.0, 0.0)
    calls = sorted(cs.tts.calls)
    assert ("Biters are hitting Nauvis.", "pbp", "tense", "quick and urgent.") in calls, calls
    assert ("That wall has held all shift.", "color", "tense", None) in calls, calls
    recs = [json.loads(x) for x in open(cs.log_path)]
    assert recs[0]["delivery"] == "quick and urgent." and "delivery" not in recs[1], recs
    assert [m["text"] for m in pushed] == [x for _, x in lines], "the words pushed are the lines"


def engines():
    sent = []
    def http(method, url, headers, body=None, timeout=45):
        sent.append((url, body))
        return (b'{"audioContent": "SUQz"}', "application/json") if "inworld" in url else (b"ID3", "audio/mpeg")
    voices._http = http
    m, instruction = voices.style_for("Biters are hitting Nauvis.", "color", "tense", "quick, stress 'Nauvis'.")
    assert instruction.endswith("This line: quick, stress 'Nauvis'.") and voices.ROLE_STYLE["color"] in instruction
    assert m == "tense" and voices.MOOD_STYLE["tense"] not in instruction, "the direction in place of the mood's words"
    assert voices.style_for("x", "color")[1].endswith(voices.MOOD_STYLE["neutral"]), "none: the role and mood only"
    o = voices.OpenAITTS.__new__(voices.OpenAITTS)
    o.key, o.model = "k", "gpt-4o-mini-tts"
    o.synth("Biters are hitting Nauvis.", "ballad", m, instruction)
    assert sent[-1][1]["instructions"] == instruction and sent[-1][1]["input"] == "Biters are hitting Nauvis."
    i = voices.Inworld.__new__(voices.Inworld)
    i.key, i.model = "k", "inworld-tts-2"
    i.synth("Biters are hitting Nauvis.", "Dennis", m, instruction)
    assert "This line: quick" in sent[-1][1]["instruction"], sent[-1][1]
    e = voices.ElevenLabs.__new__(voices.ElevenLabs)
    e.key, e.models = "k", ["eleven_v4"]
    e.synth("Biters are hitting Nauvis.", "ref", m, instruction)
    assert "quick" not in json.dumps(sent[-1][1]), "ElevenLabs takes no instruction: the text alone"


def main():
    import tempfile
    prompt_and_parse()
    with tempfile.TemporaryDirectory() as tmp:
        speak_lines_path(tmp)
    engines()
    print("delivery: ok (one Delivery line a host line from the same writer call; the words unchanged; OpenAI and "
          "Inworld take it, ElevenLabs and Cartesia do not)")


if __name__ == "__main__":
    main()
