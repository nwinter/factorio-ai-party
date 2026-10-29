#!/usr/bin/env python3
"""Text lost before speech synthesis (d28 batch319 SU2, viewer Aurora site:5412: "Operator speech is cut to 300
characters, versus 500 for engineer aloud. Preserve each full supported reply part and label any intentional spoken
summary ... test a distinctive final sentence through synthesis and actual playback, including fallback, narration
holds and restart"): python3 tools/stream/test_spokenwhole.py

A distinctive last sentence (accents, a dash) is followed from the reply's text to what TTS reads and the clip the
page plays:
1. an operator reply of two parts (tools/opreply.py, 500 bytes each): each part is said whole, its "@Name (k/n)
   Operator:" heading left out, the last sentence in the last clip (before: speakable(text, 300) cut each part);
2. an aloud say of three parts (host/saysplit.ts "(k/n)"): every part is voiced, in order, the later ones past the
   team gap and the agent's cooldown and past --chat-stale (before: the first part aired, the rest dropped);
   a different line of the same agent still waits for its cooldown;
3. TTS: a provider is never handed a sliced line: past its max_chars it gets the shorter respellings, else a
   TTSError, which TTS.speak's fallback catches and says the same whole text with another voice;
4. a chat line said in part (near --max-chars) is labelled an excerpt (the clip, the caption, the record with what
   was left out);
5. the clip the service sends the page carries the whole text, survives a page reload (replayed once) and is held
   behind a narrated piece (test_segmenthold.py plays it through the page).
"""
import os, re, sys, tempfile, threading, time, types
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import caster  # noqa: E402
import voices  # noqa: E402
import serve  # noqa: E402
import opreply  # noqa: E402

LAST = "The final word goes to the brass lighthouse at Zürich café, naïve and unhurried — end of message."


def reply_text():
    body = " ".join(f"Point {k}: the spidertron route was checked against the batch notes and found clear." for k in range(1, 12))
    return f"Aurora: {body} {LAST}"


def operator_whole():
    lines = opreply.parts("Aurora", reply_text())
    n = len(lines)
    assert n >= 2 and all(len(x.encode()) <= 500 for x in lines), [len(x) for x in lines]
    assert LAST in lines[-1] and re.match(rf"@Aurora \({n}/{n}\) Operator: ", lines[-1]), lines[-1][:40]
    said = []
    stub = types.SimpleNamespace(lock=threading.Lock(), op_q=deque({"text": t} for t in lines), snap={"game_time": "1h00m"},
                                 stats={}, history=deque(maxlen=20), rng=__import__("random").Random(1),
                                 a=types.SimpleNamespace(react=0.0, yield_s=30), agent_free=0, caster_free=0, yielding=None)
    stub.voice = lambda text, voice, c, meta, rec, hold=None: said.append((text, meta)) or 4.0
    stub.voice_operator = lambda *a: caster.Caster.voice_operator(stub, *a)
    caster.Caster.operator_tick(stub)
    texts = [t for t, _ in said]
    assert len(texts) == n, texts
    assert texts[-1].endswith(LAST), texts[-1][-120:]
    assert not any("Operator:" in t or re.search(r"\(\d/\d\)", t) for t in texts), texts
    whole = voices.speakable(" ".join(caster.op_text(x) for x in lines), 10 ** 6)
    assert " ".join(texts) == whole, "every word of both parts is said"
    assert all(len(t) > 300 for t in texts[:-1]), "no part cut at 300"
    old = [voices.speakable(x, 300) for x in lines]
    assert sum(len(o) for o in old) < len(whole) - 100, "before: the 300 cut lost words of the full parts"
    print(f"1. an operator reply of {n} parts ({', '.join(str(len(t)) for t in texts)} characters said): whole, the last sentence heard: ok")


def say_parts():
    full = reply_text()[8:] + " " + reply_text()[8:]
    chunks, rest = [], full
    while rest:  # as host/saysplit.ts posts a long say: "(k/n) " parts of up to 500 bytes
        cut = rest[:480].rfind(". ") + 1 if len(rest) > 480 else len(rest)
        chunks.append(rest[:cut].strip())
        rest = rest[cut:].strip()
    n = len(chunks)
    assert n >= 3 and chunks[-1].endswith(LAST), n
    p = caster.TalkPicker(gap=12, cooldown=50, stale=30)
    t0 = 1000.0
    msgs = [{"agent": "sol", "text": f"({k + 1}/{n}) {c}", "aloud": True, "t": t0, "seq": 10 + k} for k, c in enumerate(chunks)]
    other = {"agent": "sol", "text": "Moving to Vulcanus now to check the foundries.", "aloud": True, "t": t0, "seq": 99}
    p.add(t0, msgs + [other])
    heard, now = [], t0
    for _ in range(n + 2):
        pick = p.next(now)
        if not pick:
            break
        m, label, text = pick
        heard.append(text)
        p.aired_now(now, m, text)
        now += 35  # each part ~30 s of speech: the third comes 70 s after it was posted, past --chat-stale 30
    assert len(heard) == n and heard[-1].endswith(LAST), (len(heard), heard[-1][-80:] if heard else None)
    assert " ".join(heard) == voices.speakable(full, 10 ** 6), "every part, in order, nothing cut"
    assert all(w[0]["seq"] != 99 for w in p.waiting), "the agent's other line was dropped behind its cooldown, as before"
    print(f"2. an aloud say of {n} parts: every part voiced in order past the gap, cooldown and stale limit: ok")


class Prov(voices.Provider):
    def __init__(self, max_chars):
        self.max_chars, self.phonemes, self.got = max_chars, "respell", []

    def synth(self, text, ref, mood, instruction):
        self.got.append(text)
        return b"ID3audio", "audio/mpeg"


def tts_limits():
    t = object.__new__(voices.TTS)
    t.respacer = lambda x: x
    t.providers = {"small": Prov(80), "big": Prov(4096)}
    line = voices.speakable(reply_text(), 10 ** 6)
    try:
        t._synth("small", line, "v", None, None, None, "v")
        raise AssertionError("a sliced line reached the provider")
    except voices.TTSError as x:
        assert "not cut" in str(x) and not t.providers["small"].got, x
    t._synth("big", line, "v", None, None, None, "v")
    assert t.providers["big"].got[0].endswith(voices.pronounce(LAST, "respell")[-30:]), t.providers["big"].got[0][-60:]
    # TTS.speak's fallback catches TTSError and synthesises the same `text` with another provider (voices.py speak)
    src = open(os.path.join(HERE, "voices.py")).read()
    body = src[src.index("    def speak("):src.index("    def last_here(")]
    assert "except (TTSError, KeyError, ValueError) as x:" in body and body.count("self._synth(prov, text,") >= 3
    print("3. TTS: past a provider's limit no slice (TTSError, the fallback says it whole); within it the whole line: ok")


def excerpt_label():
    long = "We are building the second rail line to the copper field because the first one jams at the junction. " * 4
    ok, label, text = caster.talk_pick({"agent": "sol", "text": long, "aloud": False}, "strategy", 200, caster.ALOUD_LIMIT)
    whole = caster.talk_text(long, 10 ** 6, "sol")
    assert ok and len(text) <= 200 and len(whole) > len(text) + 100
    src = open(os.path.join(HERE, "caster.py")).read()
    assert '"excerpt": excerpt' in src and '"left_out"' in src
    js = open(os.path.join(HERE, "static", "audio.js")).read()
    assert '(clip.excerpt ? " (excerpt)" : "")' in js
    print("4. a chat line said in part: labelled excerpt (clip, caption, record with what was left out): ok")


def through_service():
    with tempfile.TemporaryDirectory() as d:
        h = serve.AudioHub(os.path.join(d, "audio-played.jsonl"))
        lines = opreply.parts("Aurora", reply_text())
        last = voices.speakable_parts(caster.op_text(lines[-1]), caster.OP_CLIP_CHARS)[-1]
        c = h.push({"channel": "operator", "speaker": "Operator", "rank": "agent", "text": last, "duration": 20,
                    "expires_in": 60}, b"ID3", "audio/mpeg")
        assert c["text"].endswith(LAST)
        replay = h.pending()  # a page that (re)connects gets it, whole
        assert [x["id"] for x in replay] == [c["id"]] and replay[0]["text"].endswith(LAST)
        h.played({"id": c["id"], "state": "start", "duration": 20})
        h.played({"id": c["id"], "state": "end", "played": 20, "duration": 20})
        assert h.pending() == [], "played once: not replayed again"
    print("5. the clip the page gets carries the whole text, is replayed to a reloaded page once, then never again: ok")


if __name__ == "__main__":
    operator_whole()
    say_parts()
    tts_limits()
    excerpt_label()
    through_service()
    print("test_spokenwhole: all ok")
