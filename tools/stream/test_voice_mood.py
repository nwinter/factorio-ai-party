#!/usr/bin/env python3
"""A voiced line's mood comes from its moment, not its words: python3 tools/stream/test_voice_mood.py

d22 batch99 BI1 (viewer Aurora site:4295: "Routine words like still or broken can trigger frustration. Use a natural
default, infer emotion from context"). Checks: routine lines from shifts 58-59 that the word guess read as frustrated or
excited are neutral; the hosts' exchange takes its event's mood (a fight tense; a loss, death or destroyed platform
concerned; a space moment excited); an agent's line takes a strong moment of the last 90 s that names it or (not a
space moment) happened on its surface; the caster records those moments from the feed's alerts and hands the mood to
TTS, and the OpenAI instruction says it.
"""
import os
import sys
import threading
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import voices  # noqa: E402

# lines from shift58's caster logs that the word guess voiced as frustrated or excited
ROUTINE = [
    "Back on Gleba. Science stays automatic. The two epic quality modules are not here yet, Kestrel IVc is still on "
    "the way from Aquilo, and I am leaving the science chambers alone until they land.",  # frustrated: "still"
    "Foobator, it is still unproven. The Gleba test changes only two efficiency modules in one science chamber, keeps "
    "both speed modules.",  # frustrated: "still", "keeps"
    "Caleb, the Gleba packs ran low again at fifty-five percent, so I have switched to artillery range while the next "
    "science shipment travels. Spidertron keeps its progress.",  # frustrated: "again", "keeps"
    "done: I fuelled the burner inserter on the stone belt with 5 coal.",  # excited: "done"
    "Caleb, yes. I will check the turbo belt stock and plan the upgrade after this measurement window.",  # excited: "yes"
]


def words_are_neutral():
    for t in ROUTINE:
        assert voices.mood(t) == "neutral" and voices.mood(t, "pbp") == "neutral", t
        m, instruction = voices.style_for(t)
        assert m == "neutral" and "Natural and conversational" in instruction, instruction


def host_moments():
    assert caster.moment_mood({"kind": "attack"}) == "tense"
    assert caster.moment_mood({"kind": "loss"}) == "concerned" and caster.moment_mood({"kind": "death"}) == "concerned"
    assert caster.moment_mood({"kind": "headline", "facts": {"headline": "platform_destroyed"}}) == "concerned"
    assert caster.moment_mood({"kind": "space", "facts": {"headline": "shift_rocket"}}) == "excited"
    assert caster.moment_mood({"kind": "space", "facts": {"headline": "maiden_flight"}}) == "excited"
    # a platform's first orbit of a planet, or a first return: routine trips (shift58's "This one's routine now")
    assert caster.moment_mood({"kind": "space", "facts": {"headline": "orbit"}}) == "neutral"
    assert caster.moment_mood({"kind": "space", "facts": {"headline": "platform_arrival"}}) == "neutral"
    assert caster.moment_mood({"kind": "space", "facts": {"headline": "platform_arrival", "team_first": True}}) == "excited"
    for k in ("arrival", "chat", "viewer_reply", "research", "segment", "open", "lull", "camera"):
        assert caster.moment_mood({"kind": k}) == "neutral", k
    assert caster.moment_mood(None) == "neutral"


def agent_moments():
    now = 1000.0
    ms = [{"t": now - 30, "mood": "tense", "agent": None, "surface": "nauvis"},
          {"t": now - 20, "mood": "excited", "agent": "Sol", "surface": "nauvis"},
          {"t": now - 200, "mood": "concerned", "agent": "grok", "surface": "gleba"}]
    assert caster.agent_mood(ms, "luna", "nauvis", now) == "tense", "a fight on its surface"
    assert caster.agent_mood(ms, "sol", "fulgora", now) == "excited", "a space moment naming it"
    assert caster.agent_mood(ms, "opus", "vulcanus", now) == "neutral"
    assert caster.agent_mood(ms[1:], "astra", "nauvis", now) == "neutral", "a space moment elsewhere's agent: not this one"
    assert caster.agent_mood(ms, "grok", "gleba", now) == "neutral", "older than 90 s"
    assert caster.agent_mood(ms + [{"t": now - 5, "mood": "concerned", "agent": "luna", "surface": "nauvis"}],
                             "luna", "nauvis", now) == "concerned", "the strongest"
    assert caster.agent_mood(None, "luna", "nauvis", now) == "neutral"


class FakeTTS:
    backend = "auto"

    def __init__(self):
        self.calls, self.last = [], {}

    def speak(self, text, voice, caster=None, mood=None):
        self.calls.append((text, caster, mood))
        self.last = {"provider": "openai", "voice": "verse", "mood": voices.mood(text, caster, mood), "cached": False}
        return b"mp3", "audio/mpeg", 1.5, 0.3


def caster_path():
    cs = caster.Caster.__new__(caster.Caster)
    cs.lock, cs.differ, cs.events, cs.chat_q = threading.Lock(), caster.Differ(), deque(), deque()
    base = {"alerts": [], "chat": [], "agents": [{"name": "luna", "surface": "nauvis"}, {"name": "sol", "surface": "fulgora"}]}
    cs.on_snapshot(base)
    cs.on_snapshot(dict(base, alerts=[
        {"id": "a1", "kind": "attack", "text": "Base under attack: laser turret", "surface": "nauvis"},
        {"id": "a2", "kind": "space", "text": "Meridian-V launched", "facts": {"headline": "maiden_flight", "agent": "sol"}},
        {"id": "a3", "kind": "research", "text": "Spidertron researched"}]))
    kinds = [m["kind"] for m in cs.moments]
    assert kinds == ["attack", "space"], cs.moments
    import time
    assert caster.agent_mood(cs.moments, "luna", "nauvis", time.time()) == "tense"
    assert caster.agent_mood(cs.moments, "sol", "fulgora", time.time()) == "excited"
    # the clip takes the mood; neutral is not passed (an older TTS without the argument keeps working)
    t = FakeTTS()
    r = cs.speak_clip(t, "Biters on the wall.", "atlas", caster="pbp", mood="tense")
    assert t.calls[-1] == ("Biters on the wall.", "pbp", "tense") and r[4]["mood"] == "tense", (t.calls, r[4])
    cs.speak_clip(t, "Kestrel is still on the way.", "atlas", caster="pbp", mood="neutral")
    assert t.calls[-1][2] is None

    class OldTTS(FakeTTS):
        def speak(self, text, voice, caster=None):
            return FakeTTS.speak(self, text, voice, caster)
    assert cs.speak_clip(OldTTS(), "Hello", "atlas", caster="pbp")[0] == b"mp3"


def openai_instruction():
    calls = []
    voices._http = lambda method, url, headers, body=None, timeout=45: (calls.append(body) or (b"ID3", "audio/mpeg"))
    p = voices.OpenAITTS.__new__(voices.OpenAITTS)
    p.key, p.model = "k", "gpt-4o-mini-tts"
    for m in voices.MOODS:
        mood, instruction = voices.style_for("x", "color", m)
        p.synth("x", "ballad", mood, instruction)
        assert voices.MOOD_STYLE[m] in calls[-1]["instructions"], calls[-1]
    assert "Exasperated" not in " ".join(c["instructions"] for c in calls)


def main():
    words_are_neutral()
    host_moments()
    agent_moments()
    caster_path()
    openai_instruction()
    print("voice mood: ok (routine words neutral; the hosts' event and an agent's recent moment pick the mood; "
          "passed to TTS)")


if __name__ == "__main__":
    main()
