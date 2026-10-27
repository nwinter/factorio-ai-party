"""The game's icons on the site's pages (batch270; tools/game_icons.py writes site/static/game/, see its README for
the credit: Graphics copyright Wube Software). A name with no icon gives "" and the page keeps its text."""
import html
import json
import re
from pathlib import Path

GAME = Path(__file__).resolve().parent / "static" / "game"
CREDIT = "Graphics copyright Wube Software"


def _load():
    try:
        d = json.loads((GAME / "index.json").read_text())
        return {k: set(v) for k, v in d.items()}
    except (OSError, ValueError):
        return {}


INDEX = _load()


def key(kind, name):
    """The icon's name for a game name, or None: the name itself; a technology's level without its own picture
    (`low-density-structure-productivity-10`, `mining-productivity-12`) falls back to the leveled name below it or the
    base name; an item's `-N` quality or level suffix likewise."""
    have = INDEX.get(kind) or set()
    name = (name or "").strip().lower().replace(" ", "-")
    if name in have:
        return name
    if kind == "item" and name.endswith("-rail") and "rail" in have:  # straight-rail, curved-rail-a: the rail item
        return "rail"
    m = re.match(r"^(.*?)-(\d+)$", name)
    if m:
        base, n = m.group(1), int(m.group(2))
        for k in range(min(n, 20), 0, -1):
            if f"{base}-{k}" in have:
                return f"{base}-{k}"
        if base in have:
            return base
    return None


def url(kind, name, big=False):
    k = key(kind, name)
    if not k:
        return None
    if big and k + "-big" in (INDEX.get(kind) or set()):
        return f"/static/game/{kind}/{k}-big.webp"
    return f"/static/game/{kind}/{k}.webp"


def img(kind, name, size=24, alt="", cls="gi", big=False):
    """<img> of a game icon at size CSS px (64 px files, so sharp on 2x screens), or "" when the game has none.
    alt "" for an icon beside its own text."""
    u = url(kind, name, big)
    if not u:
        return ""
    return (f'<img class="{cls}" src="{u}" width="{size}" height="{size}" alt="{html.escape(alt)}" loading="lazy" '
            f'decoding="async">')


def tech(name, size=24, alt=""):
    return img("tech", name, size, alt)


def item(name, size=24, alt=""):
    return img("item", name, size, alt)


def place(name, size=24, alt="", big=False):
    return img("place", name, size, alt, big=big)


def first_icon(f, size=22):
    """The game's icon for one of the run's firsts (longrun.py keys: tech:, pack:, planet:, arrive:, depart:, rockets:,
    platform...), or ""."""
    kind, _, name = f["key"].partition(":")
    if kind == "tech":
        return tech(name, size)
    if kind == "techs":
        return item("lab", size)
    if kind == "pack":
        return item(name, size)
    if kind in ("planet", "arrive", "depart"):
        return place(name, size)
    if kind == "rockets":
        return item("rocket-part", size)
    if kind in ("platform", "platform-lost"):
        return item("space-platform-hub", size)
    if kind == "loss":
        return item("stone-wall", size)
    return ""
