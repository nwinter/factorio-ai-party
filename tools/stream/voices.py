"""Voices and text-to-speech backends for the stream audio service (tools/stream/caster.py).

A voice id (at most 16 characters, what an agent passes as `profile {voice: id}`) names one entry of CATALOG: the
provider that speaks it, that provider's voice, a short description of how it sounds, and `like`, the nearest Aura-2
voice, used whenever the provider is unavailable (no key, or failing). The 41 Deepgram Aura-2 speaker names are
catalog ids too, so earlier picks keep working. Agents without a pick get distinct voices chosen from their names.

Backends (`--tts`):
  auto         each voice on its own provider (CATALOG), falling back to its Aura-2 `like`; casters get the best
               available voice for their role (ROLE_VOICES)
  eleven       ElevenLabs Eleven v4: the most expressive (audio tags [excited], [sighs]; inline IPA); $0.08/1k chars
  eleven-fast  ElevenLabs Eleven v4 Turbo (~100 ms), else Flash v2.5 (~75 ms); $0.04/1k chars
  openai       OpenAI gpt-4o-mini-tts: delivery steered by a free-text instruction; ~$0.015 a minute
  cartesia     Cartesia Sonic 3.6: low latency, emotion and speed controls, inline IPA; ~$0.05/1k chars
  inworld      Inworld TTS-2: delivery instruction in words, inline IPA, voice design; $0.025/1k chars
  aura2       @cf/deepgram/aura-2-en, $0.030 per 1k characters, per-voice speakers
  aura1        @cf/deepgram/aura-1, $0.015 per 1k characters, 12 speakers (voice ids map to the nearest one)
  melotts      @cf/myshell-ai/melotts, $0.0002 per audio minute, a single voice (casters only make sense)
  say          macOS `say` + ffmpeg, free, robotic but distinct voices
  tone         ffmpeg-synthesised babble timed like speech: tests the playback path without any TTS service

Keys are files in ~/.config/pog/ (POG_KEY_DIR overrides): elevenlabs.key, openai.key, cartesia.key, inworld.key. A
provider without its key is skipped. Keys are sent only to their own provider and never printed or logged.

Pronunciation: lexicon.tsv (next to this file). `speak()` applies it for the provider in use (inline IPA where the
provider reads it, respellings elsewhere; POG_TTS_IPA=0 forces respellings); captions keep the written text. Callers
pass the caption text: a line already through pronounce() loses the IPA forms (respellings still apply).
"""
import base64, hashlib, json, os, re, shutil, subprocess, tempfile, time, unicodedata
import urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
KEY_DIR = os.path.expanduser(os.environ.get("POG_KEY_DIR", "~/.config/pog"))
STATE_DIR = os.path.expanduser(os.environ.get("POG_VOICE_STATE", "~/.cache/pog/voices"))  # designed voices, id lookups

# ---- Aura-2 (Cloudflare Workers AI) ------------------------------------------------------------------------------
# id: (gender, accent, aura-1 fallback, macOS say voice, say rate). Gender only picks the `tone` pitch and nearest
# say voice; descriptions for agents come from AURA_DESC.
VOICES = {
    "amalthea": ("f", "ph", "asteria", "Samantha", 185), "andromeda": ("f", "us", "luna", "Flo (English (US))", 185),
    "apollo": ("m", "us", "orion", "Reed (English (US))", 190), "arcas": ("m", "us", "arcas", "Eddy (English (US))", 190),
    "aries": ("m", "us", "orpheus", "Rocko (English (US))", 190), "asteria": ("f", "us", "asteria", "Samantha", 190),
    "athena": ("f", "us", "athena", "Shelley (English (US))", 185), "atlas": ("m", "us", "zeus", "Grandpa (English (US))", 175),
    "aurora": ("f", "us", "stella", "Sandy (English (US))", 190), "callista": ("f", "us", "luna", "Kathy", 185),
    "cora": ("f", "us", "stella", "Flo (English (US))", 190), "cordelia": ("f", "us", "hera", "Shelley (English (US))", 180),
    "delia": ("f", "us", "luna", "Sandy (English (US))", 195), "draco": ("m", "gb", "angus", "Daniel", 185),
    "electra": ("f", "us", "stella", "Kathy", 195), "harmonia": ("f", "us", "athena", "Samantha", 180),
    "helena": ("f", "us", "hera", "Shelley (English (US))", 185), "hera": ("f", "us", "hera", "Grandma (English (US))", 175),
    "hermes": ("m", "us", "helios", "Eddy (English (US))", 200), "hyperion": ("m", "au", "perseus", "Rocko (English (UK))", 185),
    "iris": ("f", "us", "luna", "Flo (English (US))", 195), "janus": ("f", "us", "hera", "Shelley (English (US))", 185),
    "juno": ("f", "us", "asteria", "Sandy (English (US))", 185), "jupiter": ("m", "us", "zeus", "Grandpa (English (US))", 180),
    "luna": ("f", "us", "luna", "Samantha", 190), "mars": ("m", "us", "orion", "Rocko (English (US))", 195),
    "minerva": ("f", "us", "athena", "Shelley (English (UK))", 185), "neptune": ("m", "us", "orpheus", "Reed (English (UK))", 180),
    "odysseus": ("m", "us", "arcas", "Eddy (English (UK))", 185), "ophelia": ("f", "us", "stella", "Flo (English (UK))", 185),
    "orion": ("m", "us", "orion", "Reed (English (US))", 200), "orpheus": ("m", "us", "orpheus", "Grandpa (English (UK))", 180),
    "pandora": ("f", "gb", "athena", "Moira", 185), "phoebe": ("f", "us", "luna", "Karen", 190),
    "pluto": ("m", "us", "perseus", "Rishi", 180), "saturn": ("m", "us", "zeus", "Aman", 180),
    "selene": ("f", "us", "stella", "Kathy", 195),
    "thalia": ("f", "us", "stella", "Tessa", 195), "theia": ("f", "au", "asteria", "Karen", 190),
    "vesta": ("f", "us", "hera", "Tara", 185), "zeus": ("m", "us", "zeus", "Daniel", 175),
}
# How each sounds, from Deepgram's catalogue (developers.deepgram.com/docs/tts-models, read 2026-10-10), in terms of
# sound rather than gender: "low"/"baritone" for Deepgram's masculine voices, "bright"/"light" for its feminine ones.
AURA_DESC = {
    "amalthea": "bright young voice, Filipino accent, cheerful and natural",
    "andromeda": "bright, casual and expressive, American, easygoing",
    "apollo": "mid-low, confident and casual, American",
    "arcas": "mid-low, smooth and clear, American, relaxed",
    "aries": "mid-low, warm and energetic, American",
    "asteria": "bright, clear and confident, American, energetic",
    "athena": "bright, mature, calm and smooth, American",
    "atlas": "low, mature, enthusiastic and friendly, American",
    "aurora": "bright, cheerful and expressive, American, high energy",
    "callista": "bright, clear and energetic, American, polished",
    "cora": "bright, smooth and melodic, American, gentle",
    "cordelia": "light young voice, warm and polite, American",
    "delia": "light young voice, breathy and cheerful, American, casual",
    "draco": "warm baritone, British accent, trustworthy",
    "electra": "bright, professional and engaging, American",
    "harmonia": "bright, calm and empathetic, American, steady",
    "helena": "slightly raspy, friendly and positive, American",
    "hera": "smooth and warm, American, professional",
    "hermes": "mid-low, expressive and engaging, American",
    "hyperion": "mid-low, warm, Australian accent, caring",
    "iris": "light young voice, cheerful and upbeat, American",
    "janus": "smooth, Southern American accent, trustworthy",
    "juno": "breathy and melodic, American, natural",
    "jupiter": "baritone, expressive and knowing, American",
    "luna": "light young voice, friendly and natural, American",
    "mars": "smooth baritone, patient, American",
    "minerva": "bright, positive and friendly, American",
    "neptune": "mid-low, patient and polite, American",
    "odysseus": "mid-low, calm and smooth, American",
    "ophelia": "bright, enthusiastic and cheerful, American",
    "orion": "mid-low, calm and approachable, American",
    "orpheus": "mid-low, clear and confident, American",
    "pandora": "smooth and breathy, British accent, calm",
    "phoebe": "bright, warm and energetic, American, casual",
    "pluto": "smooth baritone, calm and empathetic, American",
    "saturn": "baritone, confident and knowing, American",
    "selene": "bright, expressive and energetic, American",
    "thalia": "bright, clear and confident, American, high energy",
    "theia": "expressive and sincere, Australian accent",
    "vesta": "natural and expressive, American, patient",
    "zeus": "deep, smooth and steady, American",
}

# ---- the catalog: premium voices --------------------------------------------------------------------------------
# id: (provider, provider's voice, description, Aura-2 `like`). A provider voice that is not a provider id is looked
# up by name once (cached under STATE_DIR). Descriptions come from the providers' own catalogues; check them by ear
# with the bench (`voices.py bench`) before trusting them.
PREMIUM = {
    # ElevenLabs default voices. Ids from a third-party list (wavespeed.ai) matching ElevenLabs' docs where they show
    # them; ElevenLabs retires its default voices on 2026-12-31 and only accounts made before March 2026 have them,
    # so check with `voice_bench.py --list eleven` and prefer designed voices for anything long-lived.
    "el-roger": ("eleven", "CwhRBWXzGAHq8TQ4Fs17", "laid-back, casual, resonant mid-low, American", "apollo"),
    "el-sarah": ("eleven", "EXAVITQu4vr4xnSDxMaL", "young adult, soft and confident, American", "cordelia"),
    "el-laura": ("eleven", "FGY2WhTYpPnrIDTdsKH5", "young adult, quirky and enthusiastic, bright, American", "aurora"),
    "el-charlie": ("eleven", "IKne3meq5aSn9XLyUdCD", "young adult, deep and energetic, Australian accent", "hyperion"),
    "el-george": ("eleven", "JBFqnCBsd6RMkjVDRZzb", "middle-aged, warm storyteller, British accent", "draco"),
    "el-callum": ("eleven", "N2lVS1w4EtoT3dr4eOWO", "middle-aged, husky and a bit mischievous, transatlantic", "jupiter"),
    "el-river": ("eleven", "SAz9YHcvj6GT2YYXdXww", "relaxed, neutral and informative, mid pitch, American", "arcas"),
    "el-liam": ("eleven", "TX3LPaxmHKxFdv7VOQHJ", "young adult, energetic and punchy, American", "aries"),
    "el-alice": ("eleven", "Xb7hH8MSUJpSbSDYk0k2", "middle-aged, clear and engaging, British accent", "pandora"),
    "el-matilda": ("eleven", "XrExE9yKIg1WjnnlVkGX", "middle-aged, knowledgeable and upbeat, American", "electra"),
    "el-will": ("eleven", "bIHbv24MWmeRgasZH58o", "young adult, relaxed optimist, American", "orion"),
    "el-jessica": ("eleven", "cgSgspJ2msm6clMCkdW9", "young adult, playful, bright and warm, American", "ophelia"),
    "el-eric": ("eleven", "cjVigY5qzO86Huf0OWal", "middle-aged, smooth and trustworthy, American", "odysseus"),
    "el-chris": ("eleven", "iP95p4xoKVk53GoZ742B", "middle-aged, charming, down-to-earth, American", "hermes"),
    "el-brian": ("eleven", "nPczCjzI2devNBz1zQrb", "middle-aged, deep, resonant and comforting, American", "pluto"),
    "el-daniel": ("eleven", "onwK4e9ZLuTAKqWW03F9", "middle-aged, steady broadcaster, British accent", "draco"),
    "el-lily": ("eleven", "pFZP5JQG7iQjIQuC4Bku", "middle-aged, velvety, British accent", "pandora"),
    "el-bill": ("eleven", "pqHfZKP75CvOlQylNhV4", "old, wise and crackly, American", "zeus"),
    # OpenAI built-in voices (platform.openai.com/docs/guides/text-to-speech)
    "oa-alloy": ("openai", "alloy", "neutral, even, mid pitch", "arcas"),
    "oa-ash": ("openai", "ash", "mid-low, clear and direct", "orpheus"),
    "oa-ballad": ("openai", "ballad", "soft, melodic, British-leaning", "draco"),
    "oa-coral": ("openai", "coral", "bright, warm and friendly", "phoebe"),
    "oa-echo": ("openai", "echo", "mid-low, calm, resonant", "orion"),
    "oa-fable": ("openai", "fable", "expressive storyteller, British accent", "draco"),
    "oa-nova": ("openai", "nova", "bright, youthful and energetic", "iris"),
    "oa-onyx": ("openai", "onyx", "deep and authoritative", "zeus"),
    "oa-sage": ("openai", "sage", "calm, gentle and thoughtful", "harmonia"),
    "oa-shimmer": ("openai", "shimmer", "bright, clear and upbeat", "selene"),
    "oa-verse": ("openai", "verse", "expressive, animated, mid pitch", "hermes"),
    "oa-marin": ("openai", "marin", "natural and warm, bright, conversational", "juno"),
    "oa-cedar": ("openai", "cedar", "natural and grounded, mid-low, conversational", "mars"),
    # Cartesia Sonic 3.6 recommended voices (docs.cartesia.ai tts-models/latest; the listing gives only locale and a
    # gender tag, so these say little until someone listens)
    "ca-skylar": ("cartesia", "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", "American, lighter voice, even all-rounder", "luna"),
    "ca-daniel": ("cartesia", "47c38ca4-5f35-497b-b1a3-415245fb35e1", "American, lower voice, even all-rounder", "orion"),
    "ca-jacqueline": ("cartesia", "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc", "American, lighter voice, composed", "hera"),
    "ca-gemma": ("cartesia", "62ae83ad-4f6a-430b-af41-a9bede9286ca", "British accent, lighter voice", "pandora"),
    "ca-archie": ("cartesia", "ef191366-f52f-447a-a398-ed8c0f2943a1", "British accent, lower voice", "draco"),
    # Inworld TTS-2 stock voices (docs.inworld.ai descriptions)
    "in-alex": ("inworld", "Alex", "energetic and expressive, mid-range, a little nasal", "aries"),
    "in-ashley": ("inworld", "Ashley", "warm and natural, bright", "minerva"),
    "in-dennis": ("inworld", "Dennis", "middle-aged, smooth, calm and friendly, lower", "odysseus"),
}
CATALOG = {v: ("aura2", v, AURA_DESC[v], v) for v in VOICES}
CATALOG.update(PREMIUM)

# The two casters, by role. With `--tts auto` each role takes the first voice in its list whose provider is
# available; with a single-provider backend it takes the first voice of that provider. Never given to an agent.
ROLE_VOICES = {  # not yet chosen by ear: see docs/AUDIO-NOTES.md "Voices round 2"
    "pbp": ["el-liam", "ca-daniel", "in-alex", "oa-ash", "atlas"],
    "color": ["el-alice", "ca-gemma", "in-ashley", "oa-coral", "thalia"],
}
# Caster voices to design (ElevenLabs or Inworld voice design) as bench candidates: `voice_bench.py --design`.
ROLE_DESIGN = {
    "pbp": "Energetic esports play-by-play commentator in his thirties, American, bright and punchy mid-range voice, "
           "fast clear diction, rises with excitement on big plays, broadcast-quality studio recording.",
    "color": "Warm, witty esports colour commentator in her forties, slight British accent, relaxed and knowing, "
             "a smile in the voice, measured pace, broadcast-quality studio recording.",
}
CASTERS = {"pbp": "atlas", "color": "thalia"}  # Aura-2 picks (docs/AUDIO-NOTES.md "Voices"); caster.py passes these
CASTER_SAY = {"pbp": ("Daniel", 205), "color": ("Karen", 190)}

PRICE = {  # USD per character unless "minutes"; list prices read 2026-10-10 (docs/AUDIO-NOTES.md "Voices round 2")
    "aura2": ("chars", 0.030 / 1000), "aura1": ("chars", 0.015 / 1000), "melotts": ("minutes", 0.0002),
    "eleven": ("chars", 0.08 / 1000), "eleven-fast": ("chars", 0.04 / 1000),  # v4 / v4 Turbo and Flash, API rates
    "openai": ("minutes", 0.015),  # $12 per M audio tokens; ~$0.015 a minute is OpenAI's launch estimate
    "cartesia": ("chars", 0.049 / 1000),  # 1 credit a character; Startup plan overage $45/M, Pro $65/M
    "inworld": ("chars", 0.025 / 1000),  # TTS-2 on demand; $20/M on the Creator plan
    "say": ("chars", 0.0), "tone": ("chars", 0.0), "auto": ("chars", 0.0),
}
MODEL = {"aura2": "@cf/deepgram/aura-2-en", "aura1": "@cf/deepgram/aura-1", "melotts": "@cf/myshell-ai/melotts"}
PROVIDER_KEY = {"eleven": "elevenlabs", "eleven-fast": "elevenlabs", "openai": "openai", "cartesia": "cartesia",
                "inworld": "inworld"}


def voice_ids():
    """Aura-2 ids: the pool for default assignment (always speakable, on every backend through `like`)."""
    return sorted(VOICES)


def provider_of(voice):
    return (CATALOG.get(voice) or DESIGNED.get(voice) or ("aura2",))[0]


def assign_voices(agents, taken=(), tts=None):
    """{agent name: voice id}. An agent's own valid `voice` wins, then a designed voice from its `voice_description`
    (when `tts`, by default the latest premium-backend TTS made, can design one), and the rest get distinct voices
    by name hash."""
    tts = tts or _designer
    if tts is not None and tts.providers:  # only the voices the casters will use on this backend are held back
        reserved = {tts.caster_voice(r) for r in ROLE_VOICES}
    else:
        reserved = {v for vs in ROLE_VOICES.values() for v in vs}
    out, used = {}, set(taken) | set(CASTERS.values()) | reserved
    for a in agents:
        v = (a.get("voice") or "").strip().lower()
        if v in CATALOG or v in DESIGNED:
            out[a["name"]] = v
            used.add(v)
        elif a.get("voice_description") and tts is not None:
            v = tts.designed_voice(a["name"], a["voice_description"])
            if v:
                out[a["name"]] = v
    # defaults: the premium voices this TTS can speak first, then Aura-2 (deterministic for a given set of keys)
    fams = {FAMILY[p] for p in tts.providers} if tts is not None and tts.providers else set()
    pools = [sorted(v for v, e in PREMIUM.items() if FAMILY.get(e[0]) in fams),
             [v for v in voice_ids() if v not in CASTERS.values()]]
    for a in sorted(agents, key=lambda a: a["name"]):
        if a["name"] in out:
            continue
        h = int(hashlib.sha1(a["name"].encode()).hexdigest(), 16)
        v = None
        for pool in [p for p in pools if p]:
            free = [pool[(h + k) % len(pool)] for k in range(len(pool))]
            v = next((x for x in free if x not in used), None)
            if v:
                break
        v = v or pools[1][h % len(pools[1])]
        out[a["name"]] = v
        used.add(v)
    return out


COORDS = re.compile(r"\(?\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)?|\b[xy]\s*=?\s*-?\d+(?:\.\d+)?(?:\s*\.\.\s*-?\d+(?:\.\d+)?)?")


def has_coords(text):
    return bool(COORDS.search(str(text)))


# ---- pronunciation ------------------------------------------------------------------------------------------------
LEXICON_FILE = os.path.join(HERE, "lexicon.tsv")
_lex = None


def lexicon(path=None):
    """[(written, say, ipa)] from lexicon.tsv, and one regex over all of them (longest first)."""
    global _lex
    if _lex is not None and path is None:
        return _lex
    rows = []
    for line in open(path or LEXICON_FILE, encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        cols = (line.rstrip("\n").split("\t") + ["", "", ""])[:3]
        written, say, ipa = (c.strip() for c in cols)
        if written and (say or ipa):
            rows.append((written, say or written, ipa))
    rows.sort(key=lambda r: -len(r[0]))
    alts = []
    for i, (w, _, _) in enumerate(rows):
        body = re.escape(w)
        alts.append(f"(?P<w{i}>{body})" if w.upper() == w and re.search("[A-Z]", w) else f"(?P<w{i}>(?i:{body}))")
    pat = re.compile(r"(?<![\w-])(?:" + "|".join(alts) + r")(?![\w])") if alts else None
    out = (rows, pat)
    if path is None:
        _lex = out
    return out


def _xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# One IPA phone: diphthongs, affricates and r-coloured vowels stay whole, length marks stay on their vowel, stress
# marks are their own item (Cartesia's <<k|ɑ|ɹ|ˈ|t|i>> form).
IPA_PHONE = re.compile(r"tʃ|dʒ|eɪ|aɪ|ɔɪ|oʊ|aʊ|[^\sː]ː?")


def unpronounce(text):
    """Undo pronounce() IPA forms (/ipa/, <<i|p|a>>, <phoneme>) back to respellings, e.g. when a request falls back
    to a model without phoneme support."""
    rows, _ = lexicon()
    for written, say, ipa in rows:
        if ipa:
            text = text.replace(f"/{ipa}/", say).replace("<<" + "|".join(IPA_PHONE.findall(ipa)) + ">>", say)
    return re.sub(r'<phoneme alphabet="ipa" ph="[^"]*">([^<]*)</phoneme>', lambda m: pronounce(m.group(1)), text)


def pronounce(text, style="respell"):
    """Rewrite lexicon words for TTS. style: "respell" (every provider), "ssml" (<phoneme alphabet="ipa">, the rest of
    the text XML-escaped), "cartesia" (<<i|p|a>> inline IPA), "slash" (/ipa/ inline, Inworld). Words without IPA are
    respelled in every style."""
    rows, pat = lexicon()
    if pat is None:
        return text
    out, last = [], 0
    for m in pat.finditer(text):
        written, say, ipa = rows[int(m.lastgroup[1:])]
        plain = text[last:m.start()]
        out.append(_xml(plain) if style == "ssml" else plain)
        word = m.group()
        if not ipa or style == "respell":
            out.append(_xml(say) if style == "ssml" else say)
        elif style == "ssml":
            out.append(f'<phoneme alphabet="ipa" ph="{ipa}">{_xml(word)}</phoneme>')
        elif style == "cartesia":
            out.append("<<" + "|".join(IPA_PHONE.findall(ipa)) + ">>")
        elif style == "slash":
            out.append(f"/{ipa}/")
        else:
            out.append(say)
        last = m.end()
    tail = text[last:]
    out.append(_xml(tail) if style == "ssml" else tail)
    return "".join(out)


def speakable(text, limit=220):
    """Strip what TTS reads badly: emoji, markdown, URLs, @handles, map coordinates; cut at a sentence."""
    text = re.sub(r"\s*(?:\b(?:at|near|to|from)\s+)?(?:" + COORDS.pattern + ")", "", text)
    text = re.sub(r"\(\s*\)", "", re.sub(r"(?:,\s*)+(?=[,.;:!?)]|$)", "", text))
    text = re.sub(r"\s+([,.;:!?])", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_`#>\[\]{}|~]", "", text)
    text = re.sub(r"@(\w+)", r"\1", text)
    text = "".join(ch for ch in text if unicodedata.category(ch)[0] != "S" or ch in "%$+=")
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        cut = max(text.rfind(p, 0, limit) for p in (". ", "! ", "? "))
        text = text[:cut + 1] if cut > limit // 3 else text[:limit].rsplit(" ", 1)[0] + "..."
    return text


# ---- delivery: how a line should sound ----------------------------------------------------------------------------
FRUSTRATED = re.compile(r"\b(ugh+|argh+|again|why (?:is|does|won't|can't)|stuck|broken|starv\w*|damn|seriously|come on|"
                        r"keeps?|still|nope|annoying|great, just)\b", re.I)
EXCITED = re.compile(r"\b(yes+|huge|finally|boom|let's go|wow|incredible|done|online|we did it|massive|nice)\b", re.I)


def mood(text, caster=None):
    """excited | frustrated | deadpan | neutral: a cheap guess from the words, steering expressive providers."""
    if FRUSTRATED.search(text) and (caster is None):
        return "frustrated"
    if text.count("!") >= 1 or EXCITED.search(text) or re.search(r"\b[A-Z]{4,}\b", text):
        return "excited"
    if caster is None and len(text) < 70 and text.rstrip().endswith("."):
        return "deadpan"
    return "neutral"


ROLE_STYLE = {
    "pbp": "Esports play-by-play caster calling a live match: quick, punchy, clear diction, energy rising on big plays.",
    "color": "Esports colour commentator: warm, wry and conversational, a smile in the voice, a touch slower than "
             "the play-by-play.",
}
MOOD_STYLE = {
    "excited": "Excited and proud, a little breathless.",
    "frustrated": "Exasperated and frustrated, clipped, with a sigh.",
    "deadpan": "Deadpan and dry, flat understated delivery.",
    "neutral": "Natural and conversational, like talking to teammates mid-task.",
}
V3_TAG = {"excited": "[excited]", "frustrated": "[sighs]", "deadpan": "[deadpan]", "neutral": ""}  # Eleven v3/v4
CARTESIA_EMOTION = {"excited": "excited", "frustrated": "frustrated", "deadpan": "calm", "neutral": "neutral"}


def style_for(text, caster=None):
    """(mood, instruction text)."""
    m = mood(text, caster)
    base = ROLE_STYLE.get(caster, "A player in a live co-op Factorio stream, speaking to teammates.")
    return m, base + " " + MOOD_STYLE[m]


# ---- HTTP ---------------------------------------------------------------------------------------------------------
class TTSError(RuntimeError):
    pass


def read_key(name):
    """The key in KEY_DIR/<name>.key, or None. Never logged."""
    path = os.path.join(KEY_DIR, name + ".key")
    try:
        k = open(path).read().strip()
        return k or None
    except OSError:
        return None


def _http(method, url, headers, body=None, timeout=45):
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    if body is not None and not isinstance(body, bytes):
        headers = dict(headers, **{"Content-Type": "application/json"})
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read(), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        raise TTSError(f"{e.code} {e.read()[:300].decode(errors='replace')}") from None
    except urllib.error.URLError as e:
        raise TTSError(f"unreachable: {e.reason}") from None


def _json(method, url, headers, body=None, timeout=45):
    raw, _ = _http(method, url, headers, body, timeout)
    return json.loads(raw)


def _state(name):
    try:
        return json.load(open(os.path.join(STATE_DIR, name)))
    except (OSError, ValueError):
        return {}


def _save_state(name, data):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = os.path.join(STATE_DIR, name + ".tmp")
    json.dump(data, open(tmp, "w"), indent=1, sort_keys=True)
    os.replace(tmp, os.path.join(STATE_DIR, name))


# ---- providers ----------------------------------------------------------------------------------------------------
class Provider:
    """One TTS service. synth(text, ref, mood, instruction) -> (audio bytes, content type)."""
    name = key_name = None
    phonemes = "respell"  # pronounce() style
    max_chars = 1000

    def __init__(self):
        self.key = read_key(self.key_name) if self.key_name else None

    def available(self):
        return bool(self.key)

    def synth(self, text, ref, mood, instruction):
        raise NotImplementedError

    def voices(self):
        """[(id, name, description)] the account can use; for the bench and catalog upkeep."""
        return []


DESIGN_SAMPLE = ("Belts are moving, the furnaces are hot, and I have opinions about where the next smelter goes. "
                 "Give me a minute and I will show you what a proper factory looks like.")


class ElevenLabs(Provider):
    """api.elevenlabs.io text-to-speech. Eleven v4 is the expressive model (audio tags like [excited] or [sighs],
    inline /IPA/); the fast backend asks for Eleven v4 Turbo and drops to Flash v2.5 (respellings) when the account
    or endpoint refuses it."""
    key_name = "elevenlabs"
    API = "https://api.elevenlabs.io"
    MODELS = {"eleven": ["eleven_v4", "eleven_v3"], "eleven-fast": ["eleven_v4_turbo", "eleven_flash_v2_5"]}

    def __init__(self, name="eleven"):
        super().__init__()
        self.name = name
        self.models = list(self.MODELS[name])

    @property
    def model(self):
        return self.models[0]

    @property
    def phonemes(self):
        return "slash" if self.model.startswith("eleven_v4") else "respell"

    @property
    def max_chars(self):
        return 5000 if self.model == "eleven_v3" else 10000

    def _h(self):
        return {"xi-api-key": self.key, "Accept": "audio/mpeg"}

    def synth(self, text, ref, mood, instruction):
        while True:
            body = {"text": text, "model_id": self.model}
            if self.model in ("eleven_v4", "eleven_v3"):
                tag = V3_TAG.get(mood, "")
                body["text"] = (tag + " " + text).strip() if tag else text
                body["voice_settings"] = {"stability": 0.5}  # v3/v4: 0.0 creative, 0.5 natural, 1.0 robust
            else:
                body["voice_settings"] = {"stability": 0.4, "similarity_boost": 0.75, "style": 0.3, "speed": 1.05}
            url = f"{self.API}/v1/text-to-speech/{ref}?output_format=mp3_44100_128"
            try:
                return _http("POST", url, self._h(), body)
            except TTSError as x:
                # a model this account or endpoint does not serve: use the next one from now on
                if len(self.models) > 1 and str(x)[:3] in ("400", "403", "422") and "model" in str(x).lower():
                    self.models.pop(0)
                    text = unpronounce(text)
                    text = pronounce(text, self.phonemes) if self.phonemes != "respell" else text
                    continue
                raise

    def voices(self):
        out, token = [], None
        while True:
            q = "page_size=100" + (f"&next_page_token={urllib.parse.quote(token)}" if token else "")
            res = _json("GET", f"{self.API}/v2/voices?{q}", {"xi-api-key": self.key})
            for v in res.get("voices", []):
                labels = v.get("labels") or {}
                desc = ", ".join(str(labels[k]) for k in ("age", "accent", "description", "descriptive", "use_case")
                                 if labels.get(k))
                out.append((v["voice_id"], v.get("name", ""), desc or (v.get("description") or "")[:120]))
            token = res.get("next_page_token")
            if not res.get("has_more") or not token:
                return out

    def design(self, description, name):
        """Voice design: previews from the description, keep the first as a permanent voice. -> voice_id. Costs the
        preview text's characters; the saved voice takes one of the plan's voice slots."""
        res = _json("POST", f"{self.API}/v1/text-to-voice/design", {"xi-api-key": self.key},
                    {"voice_description": description[:1000], "text": DESIGN_SAMPLE, "model_id": "eleven_ttv_v3"},
                    timeout=120)
        previews = res.get("previews") or []
        if not previews:
            raise TTSError("voice design returned no previews")
        made = _json("POST", f"{self.API}/v1/text-to-voice", {"xi-api-key": self.key},
                     {"voice_name": f"pog-{name}"[:40], "voice_description": description[:1000],
                      "generated_voice_id": previews[0]["generated_voice_id"]}, timeout=60)
        return made["voice_id"]


class OpenAITTS(Provider):
    """api.openai.com /v1/audio/speech with gpt-4o-mini-tts: delivery steered by `instructions`."""
    name, key_name = "openai", "openai"
    URL = "https://api.openai.com/v1/audio/speech"
    max_chars = 4096

    def __init__(self, model="gpt-4o-mini-tts"):
        super().__init__()
        self.model = model

    def synth(self, text, ref, mood, instruction):
        body = {"model": self.model, "voice": ref, "input": text, "instructions": instruction,
                "response_format": "mp3"}
        return _http("POST", self.URL, {"Authorization": "Bearer " + self.key}, body)

    def voices(self):
        return [(r, r, d) for _, (p, r, d, _) in PREMIUM.items() if p == "openai"]


class Cartesia(Provider):
    """api.cartesia.ai /tts/bytes with Sonic 3.6: emotion and speed controls, inline IPA <<s|oʊ|l>>."""
    name, key_name = "cartesia", "cartesia"
    API = "https://api.cartesia.ai"
    VERSION = "2026-08-14"
    phonemes = "cartesia"

    def __init__(self, model="sonic-3.6"):
        super().__init__()
        self.model = model

    def _h(self):
        return {"Authorization": "Bearer " + self.key, "Cartesia-Version": self.VERSION}

    def resolve(self, ref):
        """A voice id, or a stock voice name looked up once (cached in STATE_DIR)."""
        if re.fullmatch(r"[0-9a-f-]{36}", ref):
            return ref
        ids = _state("cartesia-names.json")
        if ref not in ids:
            res = _json("GET", f"{self.API}/voices?limit=20&q={urllib.parse.quote(ref)}", self._h())
            hit = next((v for v in res.get("data", []) if v.get("name", "").lower() == ref.lower()), None)
            if not hit:
                raise TTSError(f"no Cartesia voice named {ref!r}")
            ids[ref] = hit["id"]
            _save_state("cartesia-names.json", ids)
        return ids[ref]

    def synth(self, text, ref, mood, instruction):
        body = {"model_id": self.model, "transcript": text, "voice": {"id": self.resolve(ref)},
                "output_format": {"container": "mp3", "sample_rate": 44100, "bit_rate": 128000}, "language": "en",
                "generation_config": {"emotion": CARTESIA_EMOTION.get(mood, "neutral"),
                                      "speed": 1.08 if mood == "excited" else 1.0}}
        return _http("POST", f"{self.API}/tts/bytes", self._h(), body)

    def voices(self):
        out, after = [], None
        while True:
            res = _json("GET", f"{self.API}/voices?limit=100" + (f"&starting_after={after}" if after else ""),
                        self._h())
            rows = res.get("data", [])
            out += [(v["id"], v.get("name", ""), (v.get("description") or v.get("tagline") or "")[:120]) for v in rows]
            if not res.get("has_more") or not rows:
                return out
            after = rows[-1]["id"]


class Inworld(Provider):
    """api.inworld.ai TTS-2: a stock or designed voice plus a delivery instruction in words, inline /IPA/ per word.
    The key file holds the Base64 credential exactly as the Inworld portal shows it."""
    name, key_name = "inworld", "inworld"
    API = "https://api.inworld.ai"
    phonemes = "slash"
    max_chars = 2000

    def __init__(self, model="inworld-tts-2"):
        super().__init__()
        self.model = model

    def _h(self):
        return {"Authorization": "Basic " + self.key}

    def synth(self, text, ref, mood, instruction):
        body = {"text": text, "voiceId": ref, "modelId": self.model, "instruction": instruction[:300],
                "audioConfig": {"audioEncoding": "MP3", "sampleRateHertz": 48000, "bitRate": 128000}}
        res = _json("POST", f"{self.API}/tts/v1/voice", self._h(), body)
        return base64.b64decode(res["audioContent"]), "audio/mpeg"

    def voices(self):
        res = _json("GET", f"{self.API}/voices/v1/voices", self._h())
        return [(v.get("voiceId", ""), v.get("displayName", ""), (v.get("description") or "")[:120])
                for v in res.get("voices", [])]

    def design(self, description, name):
        res = _json("POST", f"{self.API}/voices/v1/voices:design", self._h(),
                    {"designPrompt": description[:1000], "previewText": DESIGN_SAMPLE[:400],
                     "voiceDesignConfig": {"numberOfSamples": 1}}, timeout=120)
        draft = (res.get("previewVoices") or [{}])[0].get("voiceId")
        if not draft:
            raise TTSError("voice design returned no preview")
        made = _json("POST", f"{self.API}/voices/v1/voices/{urllib.parse.quote(draft)}:publish", self._h(),
                     {"displayName": f"pog-{name}"[:40], "description": description[:300]}, timeout=60)
        return made.get("voiceId") or draft


PROVIDERS = {"eleven": lambda: ElevenLabs("eleven"), "eleven-fast": lambda: ElevenLabs("eleven-fast"),
             "openai": OpenAITTS, "cartesia": Cartesia, "inworld": Inworld}
# Which provider family speaks a catalog voice (eleven-fast speaks the ElevenLabs voices too).
FAMILY = {"eleven": "eleven", "eleven-fast": "eleven", "openai": "openai", "cartesia": "cartesia", "inworld": "inworld"}


def available_providers():
    """Provider names whose key file exists (no network)."""
    return [p for p in PROVIDERS if read_key(PROVIDER_KEY[p])]


# Designed voices: {catalog id: (provider, ref, description, like)}, loaded from STATE_DIR/designed.json.
DESIGNED = {}
_designer = None  # the latest TTS on a premium backend: assign_voices() designs voices with it (caster.py unchanged)


def _load_designed():
    for vid, entry in _state("designed.json").items():
        DESIGNED[vid] = tuple(entry["catalog"])


_load_designed()


class TTS:
    def __init__(self, backend="aura2", ai=None, target=-18.0, cache=None):
        self.backend = backend
        self.ai = ai
        self.target = target if shutil.which("ffmpeg") else None  # LUFS every cloud clip is brought to
        self.cache = cache or os.environ.get("POG_TTS_CACHE")  # directory of clips keyed by provider+voice+text
        self.spent = 0.0
        self.chars = 0
        self.seconds = 0.0
        self.last = {}  # provider, voice, mood, cached of the latest clip
        self.providers = {}
        for name, make in PROVIDERS.items():
            if backend in ("auto", name):
                p = make()
                if p.available():
                    self.providers[name] = p
        if backend in PROVIDERS and backend not in self.providers:
            raise TTSError(f"{backend}: no key at {os.path.join(KEY_DIR, PROVIDER_KEY[backend] + '.key')}")
        if self.providers:
            global _designer
            _designer = self
        if (backend in MODEL or backend == "auto") and ai is None:
            try:
                from cfai import WorkersAI
                self.ai = WorkersAI()
            except Exception:
                if backend != "auto":
                    raise

    # which provider and provider voice speak `voice` on this backend
    def effective(self, voice, caster=None):
        """The catalog id that speaks: a caster's role voice on the premium backends, else `voice`."""
        if caster and self.backend in ("auto",) + tuple(PROVIDERS):
            return self.caster_voice(caster)
        return voice

    def route(self, voice, caster=None):
        voice = self.effective(voice, caster)
        prov, ref, _, like = CATALOG.get(voice) or DESIGNED.get(voice) or CATALOG["orion"]
        if self.backend == "auto":
            if prov == "aura2" or prov not in self.providers:
                return "aura2", like
            return prov, ref
        if self.backend in PROVIDERS:
            if FAMILY.get(prov) == FAMILY[self.backend]:
                return self.backend, ref
            return self.backend, self.stand_in(like)
        return self.backend, like

    def caster_voice(self, role):
        for v in ROLE_VOICES.get(role, []):
            p = provider_of(v)
            if self.backend == "auto" and (p == "aura2" or p in self.providers):
                return v
            if self.backend in PROVIDERS and FAMILY.get(p) == FAMILY[self.backend]:
                return v
        return CASTERS.get(role, "orion")

    def stand_in(self, aura):
        """A voice of this backend's family for an Aura-2 id (agents who picked an Aura-2 voice)."""
        fam = FAMILY[self.backend]
        same = [r for p, r, _, like in PREMIUM.values() if FAMILY.get(p) == fam and like == aura]
        if same:
            return same[0]
        pool = sorted(r for p, r, _, _ in PREMIUM.values() if FAMILY.get(p) == fam)
        return pool[int(hashlib.sha1(aura.encode()).hexdigest(), 16) % len(pool)]

    def speak(self, text, voice, caster=None):
        """-> (audio bytes, content type, duration seconds, latency seconds). `text` is the caption text; the
        lexicon is applied here, for the provider that speaks it."""
        t0 = time.time()
        prov, ref = self.route(voice, caster)
        m, instruction = style_for(text, caster)
        key = None
        if self.cache:
            key = hashlib.sha1(json.dumps([prov, getattr(self.providers.get(prov), "model", ""), ref, m, instruction,
                                           text, self.target]).encode()).hexdigest()
            path = os.path.join(self.cache, key[:2], key + ".mp3")
            if os.path.exists(path):
                audio = open(path, "rb").read()
                dur = duration(audio)
                self.last = {"provider": prov, "voice": ref, "mood": m, "cached": True}
                self.seconds += dur
                return audio, "audio/mpeg", dur, time.time() - t0
        try:
            audio, ctype = self._synth(prov, text, ref, m, instruction, caster, voice)
        except TTSError:
            if self.backend != "auto" or prov == "aura2" or self.ai is None:
                raise
            vid = self.effective(voice, caster)
            like = (CATALOG.get(vid) or DESIGNED.get(vid) or CATALOG["orion"])[3]
            prov, ref = "aura2", like  # a premium provider failed: the voice's Aura-2 stand-in speaks
            audio, ctype = self._synth(prov, text, ref, m, instruction, caster, voice)
        if prov not in ("say", "tone") and self.target is not None:
            audio, ctype = normalize(audio, ctype, self.target)
        dur = duration(audio, ctype)
        unit, rate = PRICE[prov]
        self.spent += rate * (len(text) if unit == "chars" else dur / 60)
        self.chars += len(text)
        self.seconds += dur
        self.last = {"provider": prov, "voice": ref, "mood": m, "cached": False}
        if key:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").write(audio)
        return audio, ctype, dur, time.time() - t0

    def _synth(self, prov, text, ref, m, instruction, caster, voice):
        if prov in self.providers:
            p = self.providers[prov]
            style = p.phonemes if os.environ.get("POG_TTS_IPA", "1") != "0" else "respell"  # 0: respellings only
            return p.synth(pronounce(text, style)[:p.max_chars], ref, m, instruction)
        said = pronounce(text)
        if prov == "aura2":
            return self.ai.run(MODEL["aura2"], {"text": said, "speaker": ref, "encoding": "mp3"}, raw=True)
        if prov == "aura1":
            return self.ai.run(MODEL["aura1"], {"text": said, "speaker": VOICES.get(ref, VOICES["orion"])[2],
                                                "encoding": "mp3"}, raw=True)
        if prov == "melotts":
            return self.ai.run(MODEL["melotts"], {"prompt": said, "lang": "en"}, raw=True)
        if prov == "say":
            name, rate = CASTER_SAY[caster] if caster else VOICES.get(ref, VOICES["orion"])[3:5]
            return _say(said, name, rate)
        if prov == "tone":
            return _tone(said, ref)
        raise ValueError(f"unknown TTS backend {prov}")

    def designed_voice(self, agent, description):
        """A catalog id for a voice designed from `description` (ElevenLabs, else Inworld), made once per agent and
        description and remembered in STATE_DIR/designed.json. None when no provider can design one."""
        description = " ".join(str(description).split())[:400]
        if not description:
            return None
        vid = ("my-" + re.sub(r"[^a-z0-9]", "", agent.lower()))[:16]
        saved = _state("designed.json")
        h = hashlib.sha1(description.encode()).hexdigest()[:12]
        if saved.get(vid, {}).get("hash") == h:
            DESIGNED[vid] = tuple(saved[vid]["catalog"])
            return vid
        for prov in ("eleven", "eleven-fast", "inworld"):
            p = self.providers.get(prov) or (PROVIDERS[prov]() if self.backend == "auto" else None)
            if not p or not p.available() or not hasattr(p, "design"):
                continue
            if saved.get(vid, {}).get("failed") == h:
                return None
            try:
                ref = p.design(description, vid)
            except (TTSError, KeyError, ValueError) as x:
                saved[vid] = {"failed": h, "error": str(x)[:200]}
                _save_state("designed.json", saved)
                return None
            like = sorted(VOICES)[int(h, 16) % len(VOICES)]
            entry = (FAMILY[prov], ref, description, like)
            saved[vid] = {"hash": h, "catalog": list(entry), "agent": agent, "made": time.strftime("%Y-%m-%d %H:%M")}
            _save_state("designed.json", saved)
            DESIGNED[vid] = entry
            return vid
        return None


def _ffmpeg(args, data=None):
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found (brew install ffmpeg)")
    return subprocess.run(["ffmpeg", "-loglevel", "error", "-y"] + args, input=data, capture_output=True, check=True).stdout


def _say(text, name, rate):
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "say.aiff")
        subprocess.run(["say", "-v", name, "-r", str(rate), "-o", wav, text], check=True, capture_output=True)
        if os.path.getsize(wav) < 8192:
            raise RuntimeError("`say` produced no audio (speech service unavailable, e.g. inside a sandbox)")
        mp3 = _ffmpeg(["-i", wav, "-af", "loudnorm=I=-16:TP=-1.5", "-ac", "1", "-b:a", "64k", "-f", "mp3", "-"])
        return mp3, "audio/mpeg"


def _tone(text, voice):
    """Babble at ~15 characters per second: a pitched, syllable-gated tone per voice, loudness like speech."""
    secs = max(1.2, len(text) / 15.0)
    h = int(hashlib.sha1(voice.encode()).hexdigest(), 16)
    f0 = (110 if VOICES.get(voice, ("m",))[0] == "m" else 200) + h % 60
    expr = f"0.5*sin(2*PI*{f0}*t)*(0.55+0.45*sin(2*PI*4.3*t))+0.25*sin(2*PI*{2 * f0 + 7}*t)"
    mp3 = _ffmpeg(["-f", "lavfi", "-i", f"aevalsrc='{expr}':s=24000:d={secs:.2f}", "-af",
                   "afade=t=in:d=0.05,afade=t=out:st=%.2f:d=0.2,volume=0.6" % (secs - 0.2), "-ac", "1", "-b:a", "48k",
                   "-f", "mp3", "-"])
    return mp3, "audio/mpeg"


def duration(audio, ctype="audio/mpeg"):
    if shutil.which("ffprobe"):
        ext = {"audio/mpeg": ".mp3", "audio/wav": ".wav", "audio/ogg": ".ogg"}.get(ctype.split(";")[0], ".mp3")
        with tempfile.NamedTemporaryFile(suffix=ext) as f:  # a pipe makes ffprobe guess the length from the bitrate
            f.write(audio)
            f.flush()
            p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                f.name], capture_output=True)
        try:
            return float(p.stdout.strip())
        except ValueError:
            pass
    return len(audio) / 8000.0  # ~64 kbit/s mp3


WHISPER = "@cf/openai/whisper-large-v3-turbo"
WHISPER_PRICE = 0.00051  # USD per audio minute


def loudness(path):
    """Integrated loudness (LUFS) and true peak (dBTP) of a file, via ffmpeg's ebur128 filter."""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    tail = p.stderr[p.stderr.rfind("Summary:"):]
    lufs = re.search(r"I:\s+(-?[\d.]+) LUFS", tail)
    peak = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    return {"lufs": float(lufs.group(1)) if lufs else None, "peak": peak.group(1) if peak else None}


def normalize(audio, ctype, target=-18.0):
    """Static gain to `target` LUFS with a -1.5 dBTP limiter: Aura-2 voices range from -19 to -30 LUFS raw."""
    ext = {"audio/wav": ".wav", "audio/ogg": ".ogg"}.get(ctype.split(";")[0], ".mp3")
    with tempfile.NamedTemporaryFile(suffix=ext) as f:
        f.write(audio)
        f.flush()
        lufs = loudness(f.name)["lufs"]
        if lufs is None or lufs < -70:
            return audio, ctype
        gain = max(-12.0, min(18.0, target - lufs))
        mp3 = _ffmpeg(["-i", f.name, "-af", f"volume={gain:.1f}dB,alimiter=limit=0.84:level=false", "-ac", "1",
                       "-b:a", "64k", "-f", "mp3", "-"])
    return mp3, "audio/mpeg"


def transcribe(ai, audio):
    res = ai.run(WHISPER, {"audio": base64.b64encode(audio).decode()})
    return (res.get("text") or "").strip()


def word_accuracy(said, heard):
    """Share of the intended words that come back from the transcript, in order (LCS over words)."""
    ones = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen " \
           "seventeen eighteen nineteen".split()
    tens = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
    num = lambda m: ones[int(m)] if int(m) < 20 else tens[int(m) // 10] + ("" if int(m) % 10 == 0 else " " + ones[int(m) % 10])
    norm = lambda s: re.findall(r"[a-z']+|\d+", re.sub(r"\b\d{1,2}\b", lambda m: num(m.group()),
                                                     s.lower().replace("%", " percent").replace("per cent", "percent").replace("-", " ")))
    a, b = norm(said), norm(heard)
    if not a:
        return 1.0
    row = [0] * (len(b) + 1)
    for x in a:
        prev = 0
        for j, y in enumerate(b, 1):
            cur = row[j]
            row[j] = prev + 1 if x == y else max(row[j], row[j - 1])
            prev = cur
    return row[-1] / len(a)


def catalog_markdown(providers=None):
    """The agent-facing voice list (agent/voices.md): voices of the given providers (default: all) plus Aura-2."""
    providers = set(providers if providers is not None else PROVIDERS)
    reserved = set(CASTERS.values()) | {v for vs in ROLE_VOICES.values() for v in vs}
    fams = {FAMILY[p] for p in providers}
    lines = []
    for vid, (prov, _, desc, _) in sorted(CATALOG.items(), key=lambda kv: (kv[1][0] == "aura2", kv[0])):
        if vid in reserved or (prov != "aura2" and FAMILY.get(prov) not in fams):
            continue
        lines.append(f"- `{vid}`: {desc}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Speak a line with a backend and voice; prints latency and cost. "
                                             "`voices.py catalog` writes agent/voices.md; the bench is voice_bench.py.")
    ap.add_argument("text")
    ap.add_argument("--tts", default="aura2", choices=list(PRICE))
    ap.add_argument("--voice", default="orion", help="voice id, or 'all' to render every voice")
    ap.add_argument("--caster", choices=list(CASTERS), help="speak as this caster (role voice and delivery)")
    ap.add_argument("--out", default=".", help="directory for the mp3 files")
    ap.add_argument("--check", action="store_true",
                    help="also measure loudness and transcribe each clip back with Whisper (word accuracy)")
    ap.add_argument("--providers", help="catalog: comma-separated providers to list (default: all)")
    a = ap.parse_args()
    if a.text == "catalog":
        md = catalog_markdown(a.providers.split(",") if a.providers else None)
        path = os.path.join(HERE, "..", "..", "agent", "voices.md")
        open(path, "w").write(md)
        print(f"wrote {os.path.normpath(path)}: {md.count(chr(10))} voices")
        raise SystemExit
    os.makedirs(a.out, exist_ok=True)
    tts = TTS(a.tts)
    whisper = 0.0
    for v in (voice_ids() if a.voice == "all" else [a.voice]):
        audio, ctype, dur, lat = tts.speak(speakable(a.text), v, caster=a.caster)
        path = os.path.join(a.out, f"{a.tts}-{v}.mp3")
        open(path, "wb").write(audio)
        row = {"voice": v, "file": path, "seconds": round(dur, 2), "latency": round(lat, 2), **tts.last}
        if a.check:
            row.update(loudness(path))
            heard = transcribe(tts.ai, audio)
            whisper += WHISPER_PRICE * dur / 60
            row.update(heard=heard, accuracy=round(word_accuracy(a.text, heard), 2))
        print(json.dumps(row), flush=True)
    print(f"spent ${tts.spent + whisper:.5f} for {tts.chars} chars, {tts.seconds:.1f} s of audio")
