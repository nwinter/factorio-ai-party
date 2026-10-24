"""The narration as timed captions (d23 batch128 CK4, Nick 17:30: "show the narration subtitles on the screen as we
go"): phrases of the text with their times in the clip, from the text and the clip alone (no provider timestamps).

The narrator pauses at punctuation (measured on the el-brian clips: a 0.25-0.45 s silence after each comma and full
stop, none inside a clause), so:
1. the text is cut into pieces at punctuation (, . ; : ! ? and dashes), each weighed by its syllables (vowel groups;
   a number by its digits);
2. the clip's pauses come from ffmpeg silencedetect (noise -35 dB, at least 0.18 s; the lead-in and tail silence
   give where speech starts and ends);
3. each piece boundary's time is estimated from the weights over the speech, then put on the nearest pause not yet
   used (in order, within 1.2 s); a boundary with none keeps its estimate;
4. pieces are grouped into captions of at most MAX_CHARS (two lines on the page), a sentence's end preferred as a
   caption's end (one of MIN_SENTENCE characters or more ends there); a piece longer than that is cut at words, its
   time shared by syllables.
Each caption: {t0, t1, text}, seconds from the clip's start; t1 is the next caption's t0 (or the speech's end + 0.3).
"""
import re, shutil, subprocess

MAX_CHARS = 84
MIN_SENTENCE = 16
SNAP_S = 1.2
NOISE, MIN_PAUSE = "-35dB", 0.18
PIECE_RE = re.compile(r"[^,.;:!?—–]+(?:[,.;:!?—–]+|$)")
SENTENCE_END = (".", "!", "?")


def syllables(word):
    w = word.lower()
    if re.search(r"\d", w):
        return max(1, len(re.sub(r"\D", "", w)))  # "27,400": about a syllable a digit
    n = len(re.findall(r"[aeiouy]+", w))
    if w.endswith("e") and not w.endswith(("le", "ee")) and n > 1:
        n -= 1  # a silent e
    return max(1, n)


def weight(text):
    return sum(syllables(w) for w in re.findall(r"[\w']+", text)) or 1


def pieces(text):
    out = [p.strip() for p in PIECE_RE.findall(" ".join(text.split()))]
    # a "piece" that is only a number's comma ("27,400") belongs with its digits
    merged = []
    for p in out:
        if merged and re.match(r"^\d", p) and re.search(r"\d,$", merged[-1]):
            merged[-1] = merged[-1] + p
        elif p:
            merged.append(p)
    return merged


def pauses(path):
    """[(start, end)] of the clip's silences (ffmpeg silencedetect); [] without ffmpeg or on an error."""
    if not shutil.which("ffmpeg"):
        return []
    try:
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
                            f"silencedetect=noise={NOISE}:d={MIN_PAUSE}", "-f", "null", "-"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    out, start = [], None
    for line in r.stderr.splitlines():
        m = re.search(r"silence_start: ([\d.]+)", line)
        if m:
            start = float(m.group(1))
        m = re.search(r"silence_end: ([\d.]+)", line)
        if m and start is not None:
            out.append((start, float(m.group(1))))
            start = None
    if start is not None:
        out.append((start, None))  # silent to the end
    return out


def timed(text, duration, gaps=()):
    """Captions for `text` in a clip of `duration` s with silences `gaps` [(start, end or None)] -> [{t0, t1, text}]."""
    ps = pieces(text)
    if not ps or not duration or duration <= 0:
        return []
    gaps = [(s, duration if e is None else e) for s, e in gaps]
    begin, end = 0.0, float(duration)
    if gaps and gaps[0][0] <= 0.05:  # the clip's lead-in silence
        begin = gaps[0][1]
        gaps = gaps[1:]
    if gaps and gaps[-1][1] >= duration - 0.05:  # its tail
        end = gaps[-1][0]
        gaps = gaps[:-1]
    end = max(end, begin + 0.5)
    ws = [weight(p) for p in ps]
    total = float(sum(ws))
    # boundary estimates: speech time shared by weight (the pauses inside count as speech time here)
    est, acc = [], 0.0
    for w in ws[:-1]:
        acc += w
        est.append(begin + (end - begin) * acc / total)
    starts, ends = [begin], []
    used = -1
    for b in est:
        best = None
        for k in range(used + 1, len(gaps)):
            mid = (gaps[k][0] + gaps[k][1]) / 2
            if abs(mid - b) <= SNAP_S and (best is None or abs(mid - b) < abs((gaps[best][0] + gaps[best][1]) / 2 - b)):
                best = k
            if mid - b > SNAP_S:
                break
        if best is not None:
            used = best
            ends.append(gaps[best][0])
            starts.append(gaps[best][1])
        else:
            ends.append(b)
            starts.append(b)
    ends.append(end)
    # keep times in order (a snap may not step back past an estimate before it)
    for i in range(1, len(starts)):
        starts[i] = max(starts[i], ends[i - 1])
        ends[i] = max(ends[i], starts[i])
    timed_pieces = [(starts[i], ends[i], ps[i]) for i in range(len(ps))]
    # a piece too long for one caption: cut at words, its time shared by syllables
    split = []
    for t0, t1, p in timed_pieces:
        if len(p) <= MAX_CHARS:
            split.append((t0, t1, p))
            continue
        words, parts, cur = p.split(), [], ""
        n = -(-len(p) // MAX_CHARS)
        size = len(p) / n
        for w in words:
            if cur and len(cur) + 1 + len(w) > size + 8:
                parts.append(cur)
                cur = w
            else:
                cur = f"{cur} {w}".strip()
        parts.append(cur)
        tw = [weight(x) for x in parts]
        acc, span = t0, t1 - t0
        for x, w in zip(parts, tw):
            nxt = acc + span * w / sum(tw)
            split.append((acc, nxt, x))
            acc = nxt
    # group into captions: up to MAX_CHARS, a sentence's end closing one once it has MIN_SENTENCE characters
    caps, cur = [], None
    for t0, t1, p in split:
        if cur and len(cur["text"]) + 1 + len(p) <= MAX_CHARS and not (
                cur["text"].endswith(SENTENCE_END) and len(cur["text"]) >= MIN_SENTENCE):
            cur["text"] += " " + p
            cur["t1"] = t1
        else:
            if cur:
                caps.append(cur)
            cur = {"t0": t0, "t1": t1, "text": p}
    caps.append(cur)
    for i, c in enumerate(caps):  # each stays up to the next one (the pause between too), the last a moment more
        c["t1"] = caps[i + 1]["t0"] if i + 1 < len(caps) else min(duration, c["t1"] + 0.3)
        c["t0"], c["t1"] = round(c["t0"], 2), round(c["t1"], 2)
    return caps


def for_clip(path, text, duration):
    return timed(text, duration, pauses(path))
