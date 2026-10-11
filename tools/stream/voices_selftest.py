#!/usr/bin/env python3
"""Offline checks for voices.py: lexicon, routing, provider request shapes (HTTP mocked), voice design, cache.
No network, no keys needed: python3 tools/stream/voices_selftest.py"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
TMP = tempfile.mkdtemp(prefix="voices-selftest-")
os.environ["POG_KEY_DIR"] = os.path.join(TMP, "keys")  # fake keys only; the real ~/.config/pog is never read here
os.environ["POG_VOICE_STATE"] = os.path.join(TMP, "state")
os.makedirs(os.environ["POG_KEY_DIR"])

import voices  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    fails += not ok
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


# ---- lexicon ----
p = voices.pronounce
check("Sol said Soul, captions untouched", p("Sol and Sol's belt") == "Soul and Soul's belt")
check("solar left alone", p("solar panels") == "solar panels")
check("capitals-only acronym", p("SPM is up, power-ups too") == "science per minute is up, power-ups too", p("SPM is up, power-ups too"))
check("longest phrase first", p("GPT-6.1 Sol beat GPT-6 Astra") == "G P T six point one Soul beat G P T six Astra",
      p("GPT-6.1 Sol beat GPT-6 Astra"))
check("case-insensitive words", p("BITERS at the wall, biters!") == "byters at the wall, byters!", p("BITERS at the wall, biters!"))
ssml = p("Sol & Grok vs biters <3", "ssml")
check("ssml phoneme tags + escaping",
      ssml == '<phoneme alphabet="ipa" ph="soʊl">Sol</phoneme> &amp; <phoneme alphabet="ipa" ph="ɡɹɑk">Grok</phoneme> '
              'vs <phoneme alphabet="ipa" ph="ˈbaɪtɚz">biters</phoneme> &lt;3', ssml)
check("ssml respells words without IPA", p("GPT", "ssml") == "G P T")
check("cartesia inline ipa, one item per phone", p("Sol", "cartesia") == "<<s|oʊ|l>>"
      and p("Gemini", "cartesia") == "<<ˈ|dʒ|ɛ|m|ɪ|n|aɪ>>", p("Gemini", "cartesia"))
check("slash inline ipa", p("Grok and Sol", "slash") == "/ɡɹɑk/ and /soʊl/")
check("unpronounce undoes every IPA style", all(voices.unpronounce(p("Sol and biters", s)) == "Soul and byters"
                                                for s in ("slash", "cartesia", "ssml")))
check("respelled text is stable (caster.py pre-pronounces)", p(p("Sol, Grok and Vale")) == p("Sol, Grok and Vale"))
rows, _ = voices.lexicon()
check("lexicon has the roster and casters", {"Sol", "Gemini", "Grok", "Luna", "Muse", "Opus", "Rook", "Vale"}
      <= {r[0] for r in rows})

# ---- catalog ----
check("catalog ids fit the harness (<=16 chars, lower case)",
      all(len(v) <= 16 and v == v.lower() for v in voices.CATALOG))
check("every voice has an Aura-2 stand-in", all(e[3] in voices.VOICES for e in voices.CATALOG.values()))
check("role voices are in the catalog", all(v in voices.CATALOG for vs in voices.ROLE_VOICES.values() for v in vs))
check("every catalog voice has a description", all(len(e[2]) > 10 for e in voices.CATALOG.values()))
md = voices.catalog_markdown()
check("catalog markdown leaves out caster voices", "`atlas`" not in md and "`el-liam`" not in md and "`orion`" in md)
check("descriptions avoid gender labels",
      not any(w in md.lower() for w in (" male", "female", " man,", "woman", "feminine", "masculine")))
v = voices.assign_voices([{"name": "a", "voice": "oa-cedar"}, {"name": "b"}])
check("agent can pick a premium voice", v["a"] == "oa-cedar" and v["b"] in voices.VOICES)
check("caster role voices never assigned", not set(voices.assign_voices([{"name": n} for n in "abcdefghij"]).values())
      & {x for vs in voices.ROLE_VOICES.values() for x in vs})

# ---- moods ----
check("mood excited", voices.mood("Red science is ONLINE!") == "excited")
check("mood frustrated", voices.mood("Ugh, the inserters are stuck again.") == "frustrated")
check("mood deadpan", voices.mood("Iron plates. Again. Fine.") in ("deadpan", "frustrated"))

# ---- routing without keys ----
tone = voices.TTS("tone")
check("tone backend uses the Aura-2 stand-in", tone.route("el-george") == ("tone", "draco"))
check("auto without keys falls back to Aura-2", voices.TTS("auto", ai=object()).route("oa-onyx") == ("aura2", "zeus"))
try:
    voices.TTS("eleven")
    check("missing key is an error for a forced provider", False)
except voices.TTSError as x:
    check("missing key is an error for a forced provider", "elevenlabs.key" in str(x) and "no key" in str(x))

# ---- provider requests (HTTP mocked) ----
for name in ("elevenlabs", "openai", "cartesia", "inworld"):
    open(os.path.join(os.environ["POG_KEY_DIR"], name + ".key"), "w").write(f"test-{name}-key\n")
MP3 = voices._tone("one two three four five", "orion")[0] if voices.shutil.which("ffmpeg") else b"\xff\xfb" + b"\0" * 400
calls = []


def fake_http(method, url, headers, body=None, timeout=45):
    calls.append({"method": method, "url": url, "headers": headers, "body": body})
    if url.endswith("/voices:design"):
        return json.dumps({"previewVoices": [{"voiceId": "draft__pog"}]}).encode(), "application/json"
    if url.endswith(":publish"):
        return json.dumps({"voiceId": "workspace__pog-my-muse"}).encode(), "application/json"
    if "inworld.ai/tts/v1/voice" in url:
        import base64
        return json.dumps({"audioContent": base64.b64encode(MP3).decode()}).encode(), "application/json"
    if "/voices?limit=20&q=" in url:
        return json.dumps({"data": [{"id": "0000aaaa-bbbb-cccc-dddd-eeeeffff0000", "name": "Brandon"}]}).encode(), \
            "application/json"
    if body and body.get("model_id") == "eleven_v4_turbo" and REFUSE_TURBO:
        raise voices.TTSError('400 {"detail":{"status":"invalid_model","message":"model eleven_v4_turbo not found"}}')
    if url.endswith("/v1/text-to-voice/design"):
        return json.dumps({"previews": [{"generated_voice_id": "gen123"}]}).encode(), "application/json"
    if url.endswith("/v1/text-to-voice"):
        return json.dumps({"voice_id": "designedVoiceId00001"}).encode(), "application/json"
    if "fail.example" in url:
        raise voices.TTSError("500 boom")
    return MP3, "audio/mpeg"


REFUSE_TURBO = False
voices._http = fake_http


class FakeAI:
    def run(self, model, args, raw=False):
        calls.append({"url": "cf:" + model, "body": args, "headers": {}})
        return MP3, "audio/mpeg"


auto = voices.TTS("auto", ai=FakeAI())
check("auto loads every provider with a key",
      sorted(auto.providers) == ["cartesia", "eleven", "eleven-fast", "inworld", "openai"],
      str(sorted(auto.providers)))
calls.clear()
audio, ctype, dur, lat = auto.speak("Sol finally got red science ONLINE!", "el-george")
c = calls[-1]
check("eleven v4 request", c["url"].startswith("https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb")
      and c["body"]["model_id"] == "eleven_v4" and c["headers"]["xi-api-key"] == "test-elevenlabs-key", c["url"])
check("eleven v4 gets a mood tag and inline IPA", c["body"]["text"].startswith("[excited] /soʊl/ finally"),
      c["body"]["text"])
check("clip is normalised mp3 with a duration", ctype == "audio/mpeg" and dur > 0)
check("cost counted at the provider's rate", abs(auto.spent - len("Sol finally got red science ONLINE!") * 0.08 / 1000) < 1e-9,
      str(auto.spent))

auto.speak("Ugh, Grok, the belt is stuck again.", "oa-cedar")
c = calls[-1]
check("openai request", c["url"] == "https://api.openai.com/v1/audio/speech" and c["body"]["voice"] == "cedar"
      and c["body"]["model"] == "gpt-4o-mini-tts" and "frustrated" in c["body"]["instructions"].lower()
      and c["headers"]["Authorization"] == "Bearer test-openai-key", json.dumps(c["body"]))
check("openai gets the respelling", "Grock" in c["body"]["input"])

flash = voices.TTS("eleven-fast", ai=FakeAI())
flash.speak("Sol holds the line.", "el-daniel")
c = calls[-1]
check("eleven fast asks for v4 Turbo with inline IPA", c["body"]["model_id"] == "eleven_v4_turbo"
      and c["body"]["text"] == "/soʊl/ holds the line.", json.dumps(c["body"]))
REFUSE_TURBO = True
calls.clear()
flash.speak("Sol holds the line again.", "el-daniel")
check("v4 Turbo refused: Flash v2.5 with the respelling, and it sticks",
      [x["body"]["model_id"] for x in calls] == ["eleven_v4_turbo", "eleven_flash_v2_5"]
      and calls[-1]["body"]["text"] == "Soul holds the line again." and flash.providers["eleven-fast"].model
      == "eleven_flash_v2_5", json.dumps([x["body"] for x in calls]))
REFUSE_TURBO = False
flash.speak("Sol holds the line.", "orion")
check("single-provider backend maps an Aura-2 pick to its stand-in", "/v1/text-to-speech/bIHbv24MWmeRgasZH58o" in calls[-1]["url"],
      calls[-1]["url"])
flash.speak("Big push on the west wall!", "atlas", caster="pbp")
check("caster role voice on a single-provider backend", "TX3LPaxmHKxFdv7VOQHJ" in calls[-1]["url"], calls[-1]["url"])

auto.speak("Iron plates. Again. Fine, Muse.", "in-dennis")
c = calls[-1]
check("inworld request", c["url"] == "https://api.inworld.ai/tts/v1/voice" and c["body"]["voiceId"] == "Dennis"
      and c["body"]["modelId"] == "inworld-tts-2" and c["headers"]["Authorization"] == "Basic test-inworld-key"
      and "/mjuːz/" in c["body"]["text"] and c["body"]["instruction"], json.dumps(c["body"]))
auto.speak("Sol is on it!", "ca-daniel")
c = calls[-1]
check("cartesia request", c["url"] == "https://api.cartesia.ai/tts/bytes" and c["body"]["model_id"] == "sonic-3.6"
      and c["body"]["voice"] == {"id": "47c38ca4-5f35-497b-b1a3-415245fb35e1"}
      and c["headers"]["Authorization"] == "Bearer test-cartesia-key" and c["headers"]["Cartesia-Version"]
      and c["body"]["transcript"].startswith("<<s|oʊ|l>>") and c["body"]["generation_config"]["emotion"] == "excited",
      json.dumps(c["body"]))
voices.PREMIUM["ca-test"] = voices.CATALOG["ca-test"] = ("cartesia", "Brandon", "test voice", "luna")
auto.speak("Fine.", "ca-test")
check("cartesia voice by name is looked up once", calls[-2]["url"].endswith("q=Brandon")
      and calls[-1]["body"]["voice"]["id"] == "0000aaaa-bbbb-cccc-dddd-eeeeffff0000")
del voices.PREMIUM["ca-test"], voices.CATALOG["ca-test"]

auto.speak("A big moment for the team!", "atlas", caster="pbp")
check("auto caster takes the first available role voice", "TX3LPaxmHKxFdv7VOQHJ" in calls[-1]["url"])
auto.providers["eleven"].API = "https://fail.example"
auto.speak("A big moment for the team!", "atlas", caster="pbp")
check("provider failure falls back to the voice's Aura-2 stand-in",
      calls[-1]["url"] == "cf:@cf/deepgram/aura-2-en" and calls[-1]["body"]["speaker"] == "aries"
      and auto.last["provider"] == "aura2", json.dumps(calls[-1]["body"]))
auto.providers["eleven"].API = voices.ElevenLabs.API

# ---- voice design ----
calls.clear()
v = voices.assign_voices([{"name": "Grok", "voice_description": "gravelly old prospector, slow drawl, amused"}], tts=auto)
check("designed voice id", v["Grok"] == "my-grok" and voices.DESIGNED["my-grok"][:2] == ("eleven", "designedVoiceId00001"),
      str(v))
check("design calls: design then create", [c["url"].rsplit("/v1/", 1)[-1] for c in calls] == ["text-to-voice/design", "text-to-voice"])
calls.clear()
v2 = voices.assign_voices([{"name": "Grok", "voice_description": "gravelly old prospector, slow drawl, amused"}], tts=auto)
check("designed voice cached (no new calls)", v2 == v and calls == [])
saved = json.load(open(os.path.join(os.environ["POG_VOICE_STATE"], "designed.json")))
check("designed voice saved to disk", saved["my-grok"]["catalog"][1] == "designedVoiceId00001")
auto.speak("Howdy.", "my-grok")
check("designed voice speaks through its provider", "/v1/text-to-speech/designedVoiceId00001" in calls[-1]["url"])
v3 = voices.assign_voices([{"name": "Grok", "voice": "oa-onyx", "voice_description": "anything"}], tts=auto)
check("an explicit voice beats a description", v3["Grok"] == "oa-onyx")
inw = voices.TTS("inworld", ai=FakeAI())
calls.clear()
v4 = voices.assign_voices([{"name": "muse", "voice_description": "dreamy, slow, softly amused narrator"}], tts=inw)
check("inworld voice design: design, publish, cache", v4["muse"] == "my-muse"
      and voices.DESIGNED["my-muse"][:2] == ("inworld", "workspace__pog-my-muse")
      and [c["url"].rsplit("/", 1)[-1] for c in calls] == ["voices:design", "draft__pog:publish"], str(v4))

os.environ["POG_TTS_IPA"] = "0"
auto.speak("Sol, again.", "in-dennis")
check("POG_TTS_IPA=0 forces respellings", calls[-1]["body"]["text"] == "Soul, again.", calls[-1]["body"]["text"])
del os.environ["POG_TTS_IPA"]

# ---- cache ----
cached = voices.TTS("auto", ai=FakeAI(), cache=os.path.join(TMP, "cache"))
calls.clear()
cached.speak("Same line twice.", "oa-nova")
cached.speak("Same line twice.", "oa-nova")
check("cache: second identical line is not synthesised", len(calls) == 1 and cached.last["cached"])

# ---- no key ever reaches stdout/logs: the error text names the file, not the content ----
check("keys only in headers", all("test-" not in json.dumps(c.get("body")) for c in calls))

print(f"\n{'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
