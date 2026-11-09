"""Spoken-content gate for prepared tours/recaps only; never on the live host path.

Whisper-1, unprompted English transcription: $0.006/audio minute (2026-10-31).
Receipts bind the exact script and audio bytes to this policy version. Fail closed.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import time
import unicodedata
import urllib.error
import urllib.request
import uuid

VERSION = 1
BACKEND = "openai/whisper-1"
USD_PER_MINUTE = 0.006


def digest(data):
    return hashlib.sha256(data).hexdigest()


def transcribe(audio, ctype="audio/mpeg"):
    """No script/prompt: supplying expected words can conceal unwanted speech."""
    import voices
    key = voices.read_key("openai")
    if not key:
        raise RuntimeError("transcription key unavailable")
    boundary = uuid.uuid4().hex
    chunks = []
    for k, v in (("model", "whisper-1"), ("language", "en"), ("response_format", "verbose_json"),
                 ("temperature", "0")):
        chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    ext = "wav" if "wav" in ctype else "mp3"
    chunks += [f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="clip.{ext}"\r\n'
               f'Content-Type: {ctype}\r\n\r\n'.encode(), audio, f'\r\n--{boundary}--\r\n'.encode()]
    req = urllib.request.Request("https://api.openai.com/v1/audio/transcriptions", data=b"".join(chunks),
                                 headers={"Authorization": "Bearer " + key,
                                          "Content-Type": "multipart/form-data; boundary=" + boundary})
    try:
        with urllib.request.urlopen(req, timeout=45) as res:
            result = json.load(res)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"transcription HTTP {exc.code}") from None
    if not isinstance(result.get("text"), str):
        raise RuntimeError("transcription response lacks text")
    return result


def words(text):
    # Treat punctuation, hyphens, contractions and ordinary written numbers equally.
    text = unicodedata.normalize("NFKD", text).lower().replace("’", "'")
    text = text.replace("%", " percent").replace("per cent", "percent")
    text = re.sub(r"\b(\d{1,2}):(\d{2})\b", r"\1\2", text)
    text = re.sub(r"\bpdt\b", "pacific daylight time", text)
    text = re.sub(r"\bpst\b", "pacific standard time", text)
    small = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
    tens = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()

    def number(n):
        if n < 20:
            return small[n]
        if n < 100:
            return tens[n // 10] + (" " + small[n % 10] if n % 10 else "")
        if n < 1000:
            return small[n // 100] + " hundred" + (" " + number(n % 100) if n % 100 else "")
        if n < 1000000:
            return number(n // 1000) + " thousand" + (" " + number(n % 1000) if n % 1000 else "")
        return str(n)

    text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", text)
    text = re.sub(r"\b\d+\b", lambda m: number(int(m[0])), text)
    return re.findall(r"[a-z0-9]+", text.replace("'", ""))


def compare(script, heard, duration):
    a, b = words(script), words(heard)
    # Levenshtein alignment counts substitutions, omissions AND inserted speech.
    dp = [list(range(len(b) + 1))]
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1):
            row.append(min(dp[i-1][j] + 1, row[j-1] + 1, dp[i-1][j-1] + (x != y)))
        dp.append(row)
    i, j, ops = len(a), len(b), []
    while i or j:
        # Prefer matches on ties; repeated emphasis at the front stays an insertion.
        if i and j and dp[i][j] == dp[i-1][j-1] + (a[i-1] != b[j-1]):
            ops.append(("equal" if a[i-1] == b[j-1] else "replace", b[j-1])); i -= 1; j -= 1
        elif j and dp[i][j] == dp[i][j-1] + 1:
            ops.append(("insert", b[j-1])); j -= 1
        else:
            ops.append(("delete", a[i-1])); i -= 1
    ops.reverse()
    leading, trailing = [], []
    for op, token in ops:
        if op != "insert": break
        leading.append(token)
    for op, token in reversed(ops):
        if op != "insert": break
        trailing.insert(0, token)
    wer = dp[-1][-1] / max(1, len(a))
    cps = len(script.strip()) / duration if duration > 0 else 0
    reasons = []
    if not a or not b or wer > 0.20:
        reasons.append("word_error")
    if leading:
        reasons.append("extra_leading_speech")
    if trailing:
        reasons.append("extra_trailing_speech")
    # Broad pace bounds; short utterances include fixed lead/tail silence.
    if not math.isfinite(duration) or duration <= 0 or duration > 2 + len(script.strip()) / 7 or duration < len(script.strip()) / 35:
        reasons.append("duration_vs_characters")
    return {"passed": not reasons, "reasons": reasons, "wer": round(wer, 4), "leading": leading,
            "trailing": trailing, "chars_per_second": round(cps, 3), "words": len(a)}


def valid(receipt, script, audio):
    return bool(receipt and receipt.get("version") == VERSION and receipt.get("passed") is True
                and receipt.get("script_sha256") == digest(script.encode())
                and receipt.get("audio_sha256") == digest(audio))


class Checker:
    def __init__(self, log_path, transcriber=None):
        self.log_path = Path(log_path)
        self.transcriber = transcriber or transcribe

    def log(self, row):
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.log_path.open("a") as f:
            f.write(json.dumps(dict(at=time.time(), **row), ensure_ascii=False) + "\n")

    def check(self, script, audio, ctype, duration, *, clip, attempt, previous=None):
        start = time.monotonic()
        if valid(previous, script, audio):
            self.log(dict(previous, clip=clip, attempt=attempt, reused=True, check_seconds=0, estimated_usd=0))
            return previous
        row = {"version": VERSION, "backend": BACKEND, "clip": clip, "attempt": attempt,
               "script_sha256": digest(script.encode()), "audio_sha256": digest(audio), "script": script,
               "duration": duration, "estimated_usd": round(duration / 60 * USD_PER_MINUTE, 6)}
        try:
            result = self.transcriber(audio, ctype)
            heard = result["text"] if isinstance(result, dict) else result
            row.update(compare(script, heard, duration), transcript=heard)
        except Exception as exc:
            row.update(passed=False, reasons=["transcription_unavailable"], error=type(exc).__name__ + ": " + str(exc)[:120])
        row["check_seconds"] = round(time.monotonic() - start, 3)
        self.log(row)
        return row


def prepare(script, synth, checker, clip, cached=None):
    """synth(plain) -> bytes, type, duration, metadata. One plain retry; None means skip.

    A legacy cached rendition counts as attempt one. Retry bypasses every TTS cache.
    """
    for attempt in (1, 2):
        previous = None
        if attempt == 1 and cached:
            audio, ctype, duration, meta = cached
            previous = meta.get("audio_check")
        else:
            try:
                audio, ctype, duration, meta = synth(attempt == 2)
            except Exception as exc:
                checker.log({"clip": clip, "attempt": attempt, "action": "skip", "reason": "synthesis_failed",
                             "error": type(exc).__name__})
                if attempt == 1:
                    raise
                return None
        receipt = checker.check(script, audio, ctype, duration, clip=clip, attempt=attempt, previous=previous)
        if receipt["passed"]:
            return audio, ctype, duration, dict(meta, audio_check=receipt)
    checker.log({"clip": clip, "action": "skip", "reason": "failed_both_checks"})
    return None
