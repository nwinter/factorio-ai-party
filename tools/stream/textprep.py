"""Text prep for TTS (tools/stream/voices.py): put the spaces back and say things the way a person would.

Late in long sessions some agents (Sol in runs/shake2) stop writing spaces: "deadline17:59", "fixingall12",
"Coalchestisfull", "Delivered2assemblers5electricinserters3poles". TTS reads those as one mangled word. `normalize()`
rewrites the text sent to TTS only; captions keep what the agent wrote.

  1. spoken forms: game times (41m35 -> 41 minutes 35), units (540kW, 189/min), ~ + # & arrows, compass points
  2. boundaries: letter/digit ("100iron"), camelCase ("AMworking", "NWscout")
  3. word segmentation of glued tokens not in the vocabulary ("repeatcourier" -> "repeat courier"), Viterbi over
     word costs from vocab.tsv (the team's own chat and notes, so "inserter", "handoff" and "AM" are words) with the
     system dictionary as a costly fallback
  4. optionally (`Respacer`): a line still glued after that goes to a cheap model that may only insert spaces; its
     answer is used only if it equals the input with whitespace removed, else the heuristic text stands.

`python3 textprep.py vocab RUN_DIR...` rebuilds vocab.tsv from runs' chat and notes (glued lines left out).
"""
import json, math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
VOCAB_FILE = os.path.join(HERE, "vocab.tsv")
SYSTEM_DICT = "/usr/share/dict/words"

# ---- vocabulary --------------------------------------------------------------------------------------------------
_vocab = None


def vocab():
    """(costs {word: cost}, dictionary set). Cost = -log10 share in the team corpus; dictionary-only words cost more."""
    global _vocab
    if _vocab is not None:
        return _vocab
    counts = {}
    if os.path.exists(VOCAB_FILE):
        for line in open(VOCAB_FILE, encoding="utf-8"):
            if line.startswith("#") or "\t" not in line:
                continue
            w, n = line.rstrip("\n").split("\t")[:2]
            counts[w] = int(n)
    for w in EXTRA_WORDS:
        counts.setdefault(w, 3)
    total = sum(counts.values()) or 1
    costs = {w: -math.log10(n / total) for w, n in counts.items()}
    words = set()
    if os.path.exists(SYSTEM_DICT):
        words = {w.strip().lower() for w in open(SYSTEM_DICT, encoding="utf-8", errors="ignore") if len(w.strip()) >= 4}
    _vocab = (costs, words)
    return _vocab


# Words the corpus may lack; short ones only from here or the corpus (the system dictionary's 1-3 letter entries are
# mostly noise like "ama" and "ere").
EXTRA_WORDS = """a i x y n s e w am an as at be by do go he if in is it me my no of on or so to up us we
all and any are but can did for get got has her him his how its let may new not now off one our out own put say see she
the too two use was way who why yes yet you okay thanks thank please need needs done more most some ready
fit set run lot top bit end few low big red hot via
you'd you'll you're they'll they're they'd we'll we're we'd i'll i'm i'd it's that's there's don't can't won't
isn't aren't didn't doesn't let's what's here's""".split()
DICT_DIGIT = re.compile(r"\d")


def known(word):
    """In the team vocabulary, or a dictionary word (plural and -ed/-ing forms of one count too)."""
    costs, words = vocab()
    w = word.lower()
    if w in costs or w in words:
        return True
    for suf, add in (("s", ""), ("es", ""), ("ed", ""), ("ed", "e"), ("ing", ""), ("ing", "e"), ("d", ""), ("ers", ""),
                     ("ers", "e"), ("er", ""), ("ly", "")):
        if w.endswith(suf) and len(w) - len(suf) >= 3 and (w[:-len(suf)] + add) in words | costs.keys():
            return True
    return False


def piece_cost(w):
    costs, words = vocab()
    if len(w) == 1 and w not in "aixy":  # "m" (from 41m35) and "s" are common tokens but never a glued word
        return None
    if w in costs:
        return costs[w]
    if len(w) >= 4 and known(w):
        return 7.0 + 0.1 * len(w)  # dictionary-only: allowed, but a corpus word wins
    return None  # 1-3 letter pieces only from the corpus or EXTRA_WORDS


def segment(token):
    """Best split of a glued lowercase token into known words, or None. Viterbi; pieces up to 22 letters."""
    s = token.lower()
    n = len(s)
    best = [(0.0, -1)] + [(math.inf, -1)] * n
    for j in range(1, n + 1):
        for i in range(max(0, j - 22), j):
            if best[i][0] == math.inf:
                continue
            c = piece_cost(s[i:j])
            if c is not None and best[i][0] + c + 0.5 < best[j][0]:  # +0.5 a piece: prefer fewer, longer words
                best[j] = (best[i][0] + c + 0.5, i)
    if best[n][0] == math.inf:
        return None
    out, j = [], n
    while j > 0:
        i = best[j][1]
        out.append(token[i:j])  # keep the original letters' case
        j = i
    return list(reversed(out))


# ---- spoken forms ------------------------------------------------------------------------------------------------
DIRS = {"N": "north", "S": "south", "E": "east", "W": "west", "NE": "north-east", "NW": "north-west",
        "SE": "south-east", "SW": "south-west"}
ABBREV = [  # (pattern, replacement); applied after spacing, case-sensitive unless (?i)
    (r"\bAMs\b", "assemblers"), (r"(?i)\basms?\b", "assemblers"), (r"\bAM\b", "assembler"),
    (r"(?i)\bapprox\.?(?=\s|$)", "about"), (r"\bETA\b", "E T A"), (r"(?i)\bpls\b", "please"), (r"(?i)\bthx\b", "thanks"),
    (r"(?i)\bw/o\b", "without"), (r"(?i)\bw/(?=\s|\w)", "with "), (r"\be\.g\.", "for example"), (r"\bi\.e\.", "that is"),
    (r"\bvs\.?(?=\s)", "versus"), (r"(?i)\bmins?\b(?=[\s.,;:!?)]|$)", "minutes"), (r"(?i)\bsecs?\b", "seconds"),
    (r"\binv\b", "inventory"), (r"\breqs?\b", "requests"), (r"\bqty\b", "quantity"),
]
ABBREV = [(re.compile(p), r) for p, r in ABBREV]
UNITS = {"kW": "kilowatts", "MW": "megawatts", "GW": "gigawatts", "kJ": "kilojoules", "MJ": "megajoules"}


def spoken_forms(t):
    t = t.replace("→", " to ").replace("->", " to ").replace("⇒", " to ").replace("≈", " about ")
    # game clock: 41m35, 7m42s, 50m07 (minutes and seconds into the run); 57m00 is "57 minutes"
    t = re.sub(r"(?<!\d)(\d{1,3})m00s?(?![\w])", r" \1 minutes ", t)
    t = re.sub(r"(?<!\d)(\d{1,3})m(\d{2})s?(?![\w])", r" \1 minutes \2 ", t)
    t = re.sub(r"(?<!\d)(\d{1,3})m(\d{2})s(?=[A-Za-z])", r" \1 minutes \2 ", t)
    t = re.sub(r"(?<![\d.])(\d+(?:\.\d+)?)\s?(kW|MW|GW|kJ|MJ)\b", lambda m: f"{m.group(1)} {UNITS[m.group(2)]}", t)
    t = re.sub(r"\s?/\s?min\b", " per minute", t)
    t = re.sub(r"(?<=%)(?=[A-Za-z])", " ", t)
    t = re.sub(r"(?<=\d)\s?/\s?s\b", " per second", t)
    t = re.sub(r"(?<=\d)\s?/\s?h\b", " per hour", t)
    t = re.sub(r"~\s?(?=\d)", " about ", t)
    t = re.sub(r"\s?\+(?=\d)", " plus ", t)
    t = re.sub(r"(?<=[\w)])\s?\+\s?(?=[\w(])", " and ", t)
    t = re.sub(r"(?<=\w)\s?&\s?(?=\w)", " and ", t)
    t = re.sub(r"#(?=\d)", " number ", t)
    t = re.sub(r"(?<=\d)x\b", " times", t)  # "x2" stays, "2x" is "2 times"
    return t


def _caps_then_lower(m):
    """AMworking -> AM working; AMsto -> AMs to (a plural acronym glued to the next word); AMs stays."""
    caps, low = m.group(1), m.group(2)
    if low.startswith("s") and len(low) > 2 and (known(low[1:]) or segment(low[1:])) and not known(low):
        return f"{caps}s {low[1:]}"
    return f"{caps} {low}"


def boundaries(t):
    t = re.sub(r"(?<=[A-Za-z])(?=\d)", " ", t)
    t = re.sub(r"(?<=\d)(?=[A-Za-z])(?!(?:st|nd|rd|th)\b)", " ", t)
    t = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", t)
    t = re.sub(r"\b([A-Z]{2,})([a-z]{2,})", _caps_then_lower, t)  # NWscout, AMworking (AMs keeps its plural s)
    t = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z]{2,})", " ", t)  # ZEROBelts -> ZERO Belts
    t = re.sub(r"(?<=[A-Za-z][,;:!?])(?=[A-Za-z0-9])", " ", t)  # "steel,ready", "strip:5" (not 17:59 or 1,000)
    t = re.sub(r"(?<=[a-z]{2}\.)(?=[A-Z][a-z])", " ", t)  # "done.Next"
    t = re.sub(r"(?<=[A-Za-z0-9])\((?=[A-Za-z0-9-])", " (", t)
    t = re.sub(r"(?<=[A-Za-z])/(?=[A-Za-z]{3,})", " / ", t)  # coal/input: segment each side
    return t


TOKEN = re.compile(r"[A-Za-z][A-Za-z']*")


def resegment(t, min_len=3):
    """Split glued alphabetic tokens that are not words. Returns (text, tokens still unknown and long)."""
    left = []

    def fix(m):
        tok = m.group()
        core = tok.rstrip("'")
        if len(core) < min_len or known(core) or (core.isupper() and len(core) <= 5) or core in DIRS \
                or re.fullmatch(r"[A-Z]{2,}s", core):
            return tok
        parts = segment(core)
        if parts and len(parts) > 1 and len(parts) <= max(2, len(core) // 2):
            return " ".join(parts) + tok[len(core):]
        if len(core) >= 10:
            left.append(core)
        return tok

    return TOKEN.sub(fix, t), left


def directions(t):
    return re.sub(r"(?<![\w'-])(N|S|E|W|NE|NW|SE|SW)(?![\w'-])", lambda m: DIRS[m.group(1)], t)


def abbreviations(t):
    for pat, rep in ABBREV:
        t = pat.sub(rep, t)
    return t


def glued(text):
    """How glued a line looks: alphabetic tokens of 13+ letters that are not words, plus letter-digit joins."""
    n = sum(1 for w in TOKEN.findall(text) if len(w) >= 13 and not known(w))
    return n + len(re.findall(r"[a-z]{3,}\d|\d[a-z]{3,}", text))


def normalize(text):
    """The text TTS should read. Returns the normalized string (unchanged when nothing needs fixing)."""
    return _normalize(text)[0]


def _normalize(text):
    t = spoken_forms(text)
    t = boundaries(t)
    t, left = resegment(t)
    t = directions(t)
    t = abbreviations(t)
    t = re.sub(r"\s+([,.;:!?)])", r"\1", t)
    t = re.sub(r"\(\s+", "(", t)
    t = re.sub(r"(?<=[A-Za-z0-9])\(", " (", t)
    return re.sub(r"\s{2,}", " ", t).strip(), left


# ---- model fallback ----------------------------------------------------------------------------------------------
RESPACE_PROMPT = ("The text below is a chat line from a Factorio game in which the writer forgot many spaces. Return the "
                  "same text with spaces inserted between words. Insert spaces only: do not add, remove, reorder or "
                  "change any other character, do not correct spelling, do not expand anything. Return only the text.")


def same_but_spaces(original, rewrite):
    return re.sub(r"\s+", "", original) == re.sub(r"\s+", "", rewrite)


class Respacer:
    """normalize(), plus a model pass for lines the heuristics leave glued. The model may only insert spaces: an
    answer that differs from the input in anything but whitespace is thrown away and the heuristic text is used.
    `ask(prompt, text) -> str` is the model call (see voices.respace_model); results are cached per line."""

    def __init__(self, ask=None, min_left=1, timeout=4.0):
        self.ask = ask
        self.min_left = min_left
        self.timeout = timeout
        self.cache = {}
        self.stats = {"lines": 0, "heuristic": 0, "model": 0, "model_rejected": 0, "model_failed": 0}

    def __call__(self, text):
        self.stats["lines"] += 1
        if text in self.cache:
            return self.cache[text]
        t, left = _normalize(text)
        if not left or self.ask is None or len(left) < self.min_left:
            self.stats["heuristic"] += 1
            return t
        try:
            fixed = (self.ask(RESPACE_PROMPT, text) or "").strip().strip('"')
        except Exception:  # noqa: BLE001  any failure: keep the heuristic text
            self.stats["model_failed"] += 1
            return t
        if not fixed or not same_but_spaces(text, fixed):
            self.stats["model_rejected"] += 1
            self.cache[text] = t
            return t
        self.stats["model"] += 1
        out = _normalize(fixed)[0]
        self.cache[text] = out
        return out


# ---- vocab builder -----------------------------------------------------------------------------------------------
def build_vocab(run_dirs, out=VOCAB_FILE, min_count=2):
    """Word counts from runs' chat logs and notes, leaving out glued lines; written to vocab.tsv."""
    global _vocab
    _vocab = ({}, vocab()[1])  # judge glue against the system dictionary only
    counts = {}
    texts = []
    for d in run_dirs:
        for name in ("chat.jsonl", "chat-full.jsonl"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                for line in open(p, encoding="utf-8"):
                    try:
                        texts.append(json.loads(line).get("text", ""))
                    except ValueError:
                        pass
        for sub in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            p = os.path.join(d, sub, "notes.md")
            if os.path.exists(p):
                texts += open(p, encoding="utf-8", errors="ignore").read().splitlines()
    kept = 0
    for t in texts:
        if glued(t):
            continue
        kept += 1
        for w in re.findall(r"[A-Za-z][a-z']*|[A-Z]{2,}s?", t):
            w = w.lower().strip("'")
            if 1 <= len(w) <= 22:
                counts[w] = counts.get(w, 0) + 1
    rows = sorted(((w, n) for w, n in counts.items() if n >= min_count), key=lambda r: (-r[1], r[0]))
    with open(out, "w", encoding="utf-8") as f:
        f.write(f"# word counts for textprep.segment(): {kept} unglued lines from {len(run_dirs)} runs' chat and notes\n")
        for w, n in rows:
            f.write(f"{w}\t{n}\n")
    _vocab = None
    return len(rows), kept


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 2 and sys.argv[1] == "vocab":
        n, kept = build_vocab(sys.argv[2:])
        print(f"wrote {VOCAB_FILE}: {n} words from {kept} lines")
    else:
        for line in sys.argv[1:] or sys.stdin:
            print(normalize(line.rstrip("\n")))
