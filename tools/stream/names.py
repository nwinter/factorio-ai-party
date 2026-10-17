"""Reserved viewer names (Nick 17:11 on d16: "a host link so I can have verified comments and disallow similar nicks";
viewers had posted as "NickWinter"). The site's Worker (site/worker/worker.js reservedName) applies the same rule to
names typed without the host token; the relay (viewers.py) applies it to the site's rows, older ones included, and to
YouTube display names. Test vectors shared by both: tools/stream/test_names.py.

normalize: zero-width characters out; Cyrillic and Greek look-alikes to Latin; compatibility forms folded and accents
dropped; lower case; leetspeak (0 o, 1 l | i, 3 e, 4 @ a, 5 $ s, 7 t); then only a-z kept.
reserved: contains "nickwinter" or "nickw"; equals "nick", "winter", "operator", an agent's name, "server" or another
staff word; or within edit distance 2 of "nickwinter" or "operator".
"""
import unicodedata

HOST_NAME = "NickWinter"
HOST_LABEL = "NickWinter (host)"
# Nick's YouTube channel: the author of his 16:55 and 16:56 messages on 2026-10-16 (the relay log keeps
# author_key("yt", id) = "yt:c71bef0777f3", which this id gives; the id from youtube.com/@NickWinter)
HOST_YOUTUBE_CHANNEL = "UCKimIvyUjBQIZlu7KIhBuAA"

ZERO_WIDTH = {0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
              0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068,
              0x2069, 0x3164, 0xFE0F, 0xFEFF, 0xFFA0}
# Look-alikes, before and after lower-casing (Greek capital Nu is "N", its small form looks like "v")
HOMOGLYPHS = {
    # Cyrillic
    "А": "a", "В": "b", "Е": "e", "Ё": "e", "К": "k", "М": "m", "Н": "h", "О": "o", "Р": "p", "С": "c", "Т": "t",
    "Х": "x", "У": "y", "І": "i", "Ї": "i", "Ј": "j", "Ѕ": "s", "Ԁ": "d", "Ԛ": "q", "Ԝ": "w", "Ү": "y", "Һ": "h",
    "а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t",
    "х": "x", "у": "y", "і": "i", "ї": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w", "ү": "y", "һ": "h",
    "ɡ": "g", "ո": "n", "ս": "u", "ⅰ": "i",
    # Greek
    "Α": "a", "Β": "b", "Ε": "e", "Ζ": "z", "Η": "h", "Ι": "i", "Κ": "k", "Μ": "m", "Ν": "n", "Ο": "o", "Ρ": "p",
    "Τ": "t", "Υ": "y", "Χ": "x", "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "i", "κ": "k", "ν": "v", "ο": "o",
    "ρ": "p", "τ": "t", "υ": "u", "χ": "x", "ω": "w", "ϲ": "c", "ϳ": "j",
}
LEET = {"0": "o", "1": "i", "l": "i", "|": "i", "3": "e", "4": "a", "@": "a", "5": "s", "$": "s", "7": "t"}
AGENTS = ("astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse", "fable")
STAFF = ("server", "operator", "mod", "moderator", "admin", "caster", "system", "playerofgames", "pog")
CONTAINS = ("nickwinter", "nickw")
EXACT = ("nick", "winter") + AGENTS + STAFF
NEAR = ("nickwinter", "operator")


def normalize(name):
    s = "".join(c for c in str(name or "") if ord(c) not in ZERO_WIDTH)
    s = "".join(HOMOGLYPHS.get(c, c) for c in s)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = "".join(HOMOGLYPHS.get(c, LEET.get(c, c)) for c in s)
    return "".join(c for c in s if "a" <= c <= "z")


def distance(a, b, cap=3):
    """Levenshtein distance, stopping at cap."""
    if abs(len(a) - len(b)) >= cap:
        return cap
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        if min(cur) >= cap:
            return cap
        prev = cur
    return min(prev[-1], cap)


EXACT_N = {normalize(w): w for w in EXACT}  # (leetspeak makes "sol" "soi": the list goes through the same steps)


def reserved(name):
    """Why this name is reserved ("contains nickwinter", "is sol", "near operator"), or None."""
    n = normalize(name)
    if not n:
        return None
    for w in CONTAINS:
        if w in n:
            return "contains " + w
    if n in EXACT_N:
        return "is " + EXACT_N[n]
    for w in NEAR:
        if distance(n, w) <= 2:
            return "near " + w
    return None
