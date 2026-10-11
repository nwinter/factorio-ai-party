"""Voices and text-to-speech backends for the stream audio service (tools/stream/caster.py).

Voice ids are Deepgram Aura-2 speaker names (Cloudflare Workers AI `@cf/deepgram/aura-2-en`). Agents pick one with
`profile {voice: "orion"}`; without a pick, `assign_voices` gives each agent a distinct voice chosen deterministically
from its name. Every voice also maps to a macOS `say` voice so the whole pipeline works offline (`--tts say`).

Backends (`--tts`):
  aura2   @cf/deepgram/aura-2-en, $0.030 per 1k characters, per-voice speakers (default)
  aura1   @cf/deepgram/aura-1, $0.015 per 1k characters, 12 speakers (voice ids map to the nearest one)
  melotts @cf/myshell-ai/melotts, $0.0002 per audio minute, a single voice (casters only make sense)
  say     macOS `say` + ffmpeg, free, robotic but distinct voices
  tone    ffmpeg-synthesised babble timed like speech: tests the playback path without any TTS service
"""
import hashlib, os, re, shutil, subprocess, tempfile, time, unicodedata

# id: (gender, accent, aura-1 fallback, macOS say voice, say rate)
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
# The two casters. Kept out of the agent pool so a caster never sounds like a player.
CASTERS = {"pbp": "atlas", "color": "thalia"}  # why these two: docs/AUDIO-NOTES.md "Voices"
CASTER_SAY = {"pbp": ("Daniel", 205), "color": ("Karen", 190)}

PRICE = {  # USD, from developers.cloudflare.com/workers-ai/platform/pricing (checked 2026-10-10)
    "aura2": ("chars", 0.030 / 1000), "aura1": ("chars", 0.015 / 1000), "melotts": ("minutes", 0.0002),
    "say": ("chars", 0.0), "tone": ("chars", 0.0),
}
MODEL = {"aura2": "@cf/deepgram/aura-2-en", "aura1": "@cf/deepgram/aura-1", "melotts": "@cf/myshell-ai/melotts"}


def voice_ids():
    return sorted(VOICES)


def assign_voices(agents, taken=()):
    """{agent name: voice id}. An agent's own valid `voice` wins; the rest get distinct voices by name hash."""
    out, used = {}, set(taken) | set(CASTERS.values())
    for a in agents:
        v = (a.get("voice") or "").strip().lower()
        if v in VOICES:
            out[a["name"]] = v
            used.add(v)
    pool = [v for v in voice_ids() if v not in CASTERS.values()]
    for a in sorted(agents, key=lambda a: a["name"]):
        if a["name"] in out:
            continue
        h = int(hashlib.sha1(a["name"].encode()).hexdigest(), 16)
        for k in range(len(pool)):
            v = pool[(h + k) % len(pool)]
            if v not in used:
                break
        out[a["name"]] = v
        used.add(v)
    return out


def speakable(text, limit=220):
    """Strip what TTS reads badly: emoji, markdown, URLs, @handles, long numbers lists; cut at a sentence."""
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_`#>\[\]{}|~]", "", text)
    text = re.sub(r"@(\w+)", r"\1", text)
    text = "".join(ch for ch in text if unicodedata.category(ch)[0] != "S" or ch in "%$+=")
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        cut = max(text.rfind(p, 0, limit) for p in (". ", "! ", "? "))
        text = text[:cut + 1] if cut > limit // 3 else text[:limit].rsplit(" ", 1)[0] + "..."
    return text


class TTS:
    def __init__(self, backend="aura2", ai=None, target=-18.0):
        self.backend = backend
        self.ai = ai
        self.target = target if shutil.which("ffmpeg") else None  # LUFS every cloud clip is brought to
        self.spent = 0.0
        self.chars = 0
        self.seconds = 0.0
        if backend in MODEL and ai is None:
            from cfai import WorkersAI
            self.ai = WorkersAI()

    def speak(self, text, voice, caster=None):
        """-> (audio bytes, content type, duration seconds, latency seconds)."""
        t0 = time.time()
        if self.backend == "aura2":
            audio, ctype = self.ai.run(MODEL["aura2"], {"text": text, "speaker": voice, "encoding": "mp3"}, raw=True)
        elif self.backend == "aura1":
            audio, ctype = self.ai.run(MODEL["aura1"], {"text": text, "speaker": VOICES.get(voice, VOICES["orion"])[2],
                                                        "encoding": "mp3"}, raw=True)
        elif self.backend == "melotts":
            audio, ctype = self.ai.run(MODEL["melotts"], {"prompt": text, "lang": "en"}, raw=True)
        elif self.backend == "say":
            name, rate = CASTER_SAY[caster] if caster else VOICES.get(voice, VOICES["orion"])[3:5]
            audio, ctype = _say(text, name, rate)
        elif self.backend == "tone":
            audio, ctype = _tone(text, voice)
        else:
            raise ValueError(f"unknown TTS backend {self.backend}")
        if self.backend in MODEL and self.target is not None:
            audio, ctype = normalize(audio, ctype, self.target)
        dur = duration(audio, ctype)
        unit, rate = PRICE[self.backend]
        self.spent += rate * (len(text) if unit == "chars" else dur / 60)
        self.chars += len(text)
        self.seconds += dur
        return audio, ctype, dur, time.time() - t0


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
    import base64
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


if __name__ == "__main__":
    import argparse, json
    ap = argparse.ArgumentParser(description="Speak a line with a backend and voice; prints latency and cost.")
    ap.add_argument("text")
    ap.add_argument("--tts", default="aura2", choices=list(PRICE))
    ap.add_argument("--voice", default="orion", help="voice id, or 'all' to render every voice")
    ap.add_argument("--out", default=".", help="directory for the mp3 files")
    ap.add_argument("--check", action="store_true",
                    help="also measure loudness and transcribe each clip back with Whisper (word accuracy)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tts = TTS(a.tts)
    whisper = 0.0
    for v in (voice_ids() if a.voice == "all" else [a.voice]):
        audio, ctype, dur, lat = tts.speak(speakable(a.text), v)
        path = os.path.join(a.out, f"{a.tts}-{v}.mp3")
        open(path, "wb").write(audio)
        row = {"voice": v, "file": path, "seconds": round(dur, 2), "latency": round(lat, 2)}
        if a.check:
            row.update(loudness(path))
            heard = transcribe(tts.ai, audio)
            whisper += WHISPER_PRICE * dur / 60
            row.update(heard=heard, accuracy=round(word_accuracy(a.text, heard), 2))
        print(json.dumps(row), flush=True)
    print(f"spent ${tts.spent + whisper:.5f} for {tts.chars} chars, {tts.seconds:.1f} s of audio")
