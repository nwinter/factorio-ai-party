#!/usr/bin/env python3
"""The game's icons for the site (batch270, Nick d27 10:10: Wube allows free, non-commercial use with the credit
"Graphics copyright Wube Software"):

    python3 tools/game_icons.py --data DIR [--runs-dir RUNS] [--out site/static/game]

DIR is a Factorio 2.0 `data` folder with base, space-age and quality (prototypes and graphics; the box's
D:\\pog\\factorio-2.0.77-expansion\\data, copied to the Mac with scp). Writes, for what the site shows:
- tech/NAME.webp: every technology (its 256 px picture at 64 px); a page looks up a leveled name without its level
  when the level has no prototype of its own (`low-density-structure-productivity` 10);
- item/NAME.webp: every item and fluid (a blueprint can hold any building), the entities the run's score logs name
  and those in ITEMS below (64 px, the icon's first mipmap);
- place/NAME.webp: the planets and space locations (64 px), and place/NAME-big.webp: a planet's starmap picture at
  160 px (listed as NAME-big);
- index.json: {"tech": [...], "item": [...], "place": [...]}, which the build and the pages read (a name without an
  icon is shown as text).
Recipes, achievements, tiles and the like get no file. A name without one is shown as text. The credit is in the site footer, on /about/ and in OUT/README.md.
"""
import argparse
import io
import json
import re
import sys
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
MODS = ("base", "space-age", "quality", "elevated-rails")
# item-like prototypes: their icon is the item's
ITEM_TYPES = {"item", "tool", "ammo", "capsule", "module", "gun", "armor", "repair-tool", "item-with-entity-data",
              "rail-planner", "space-platform-starter-pack", "fluid"}
PLACE_TYPES = {"planet", "space-location"}
# shown on the site whatever the score logs say (pages name them: platforms, rockets, the stages, deaths)
ITEMS = ["rocket-silo", "rocket-part", "cargo-pod", "space-platform-hub", "space-platform-foundation",
         "space-platform-starter-pack", "asteroid-collector", "thruster", "cargo-bay", "cargo-landing-pad", "lab",
         "biolab", "radar", "gun-turret", "laser-turret", "rocket-turret", "railgun-turret", "tesla-turret",
         "artillery-turret", "artillery-shell", "firearm-magazine", "piercing-rounds-magazine",
         "uranium-rounds-magazine", "rocket", "explosive-rocket", "stone-wall", "repair-pack", "blueprint", "spidertron",
         "car", "tank", "locomotive", "cargo-wagon", "fluid-wagon", "transport-belt", "inserter", "assembling-machine-3",
         "electric-mining-drill", "solar-panel", "accumulator", "steam-engine", "nuclear-reactor", "fusion-reactor",
         "heavy-armor", "power-armor-mk2", "mech-armor", "pistol", "submachine-gun", "grenade", "poison-capsule",
         "big-mining-drill", "foundry", "electromagnetic-plant", "biochamber", "cryogenic-plant", "recycler",
         "agricultural-tower", "captive-biter-spawner", "promethium-asteroid-chunk", "metallic-asteroid-chunk",
         "carbonic-asteroid-chunk", "oxide-asteroid-chunk", "rocket-fuel", "low-density-structure", "processing-unit",
         "raw-fish", "wood", "stone", "coal", "iron-ore", "copper-ore", "uranium-ore", "tungsten-ore", "scrap",
         "holmium-ore", "lithium", "ice", "calcite", "spoilage", "nutrients", "bioflux", "yumako", "jellynut",
         "pentapod-egg", "biter-egg", "quantum-processor", "superconductor", "supercapacitor", "lithium-plate",
         "holmium-plate", "tungsten-plate", "tungsten-carbide", "carbon-fiber", "carbon", "fusion-power-cell",
         "uranium-fuel-cell", "steel-plate", "iron-plate", "copper-plate", "plastic-bar", "sulfur", "battery",
         "electronic-circuit", "advanced-circuit", "iron-gear-wheel", "stone-brick", "concrete", "landfill",
         "foundation", "water", "crude-oil", "petroleum-gas", "lava", "molten-iron", "molten-copper", "fluoroketone-hot",
         "fluoroketone-cold", "ammonia", "electrolyte", "thruster-fuel", "thruster-oxidizer", "steam", "sulfuric-acid",
         "lubricant", "heavy-oil", "light-oil", "holmium-solution", "fluorine", "lithium-brine"]
STRING = r'"((?:[^"\\]|\\.)*)"'
GRAPHIC = re.compile(r'"__([\w-]+)__/(graphics/[^"]+\.png)"')
SIZE = 64


def blocks(text):
    """(type, name, graphic) for each prototype table `{ type = "T", name = "N", ... }` in a Lua file with an icon:
    its `icon`/`icons` key, a string or a local holding one (`icon = x_icon`, `icons = util.f(x_icon)`), else the
    first `__mod__/graphics/...png` after that key. An ingredient (`{type = "item", name = "x", amount = 1}`) has none."""
    local = {m.group(1): (m.group(2), m.group(3))
             for m in re.finditer(r'local\s+(\w+)\s*=\s*"__([\w-]+)__/(graphics/[^"]+\.png)"', text)}
    heads = list(re.finditer(r'type\s*=\s*' + STRING + r'\s*,\s*name\s*=\s*' + STRING, text))
    out = []
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        body = text[m.end():end]
        g = None
        icon = re.search(r'\bicons?\s*=\s*(?:[\w.]+\s*\(\s*)?(?:\{\s*\{\s*icon\s*=\s*)?(\w+|"[^"]*")', body)
        if icon and icon.group(1) in local:
            g = local[icon.group(1)]
        elif icon:  # an ingredient or a result (`{type = "item", name = "x", amount = 1}`) has no icon of its own
            hit = GRAPHIC.search(body, icon.start())
            g = (hit.group(1), hit.group(2)) if hit else None
        out.append((m.group(1), m.group(2), g))
    return out


def prototypes(data):
    """{type: {name: (mod, graphics path)}} over every mod's prototypes (later mods override earlier ones)."""
    found = {}
    for mod in MODS:
        for f in sorted((data / mod / "prototypes").rglob("*.lua")) if (data / mod / "prototypes").is_dir() else []:
            for typ, name, g in blocks(f.read_text(errors="replace")):
                if g:
                    found.setdefault(typ, {})[name] = g
    return found


def first_mip(path, size):
    """A Factorio icon's largest mipmap (the square at the left of the strip), resized to size px."""
    im = Image.open(path).convert("RGBA")
    side = im.height
    im = im.crop((0, 0, side, side)) if im.width > side else im
    return im.resize((size, size), Image.LANCZOS)


def webp(im):
    b = io.BytesIO()
    im.save(b, "WEBP", quality=88, method=6)
    return b.getvalue()


def run_names(runs_dir):
    """Items, fluids and entities the run's score logs name (the newest row of each shift)."""
    names = set()
    for f in sorted(Path(runs_dir).glob("*/scores.jsonl")) if runs_dir else []:
        last = None
        for line in f.read_text(errors="replace").splitlines():
            if line.strip():
                last = line
        try:
            s = json.loads(last)["score"] if last else {}
        except (ValueError, KeyError, TypeError):
            continue
        for key in ("produced", "consumed", "entities"):
            if isinstance(s.get(key), dict):
                names |= set(s[key])
        for key in ("current_packs", "entities_counted"):
            if isinstance(s.get(key), list):
                names |= {x for x in s[key] if isinstance(x, str)}
    return names


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, required=True)
    ap.add_argument("--runs-dir", type=Path, default=Path.home() / "code" / "player-of-games" / "runs")
    ap.add_argument("--out", type=Path, default=REPO / "site" / "static" / "game")
    a = ap.parse_args(argv)
    protos = prototypes(a.data)
    resolve = lambda g: a.data / g[0] / g[1]  # noqa: E731
    techs = protos.get("technology", {})
    items = {}
    for typ in ITEM_TYPES:
        items.update({n: g for n, g in protos.get(typ, {}).items() if n not in items})
    # every item and fluid: the blueprint library can hold any building, the live page names any item
    wanted = run_names(a.runs_dir) | set(ITEMS) | set(items)
    written = {"tech": [], "item": [], "place": []}
    total = 0
    for kind in written:
        (a.out / kind).mkdir(parents=True, exist_ok=True)

    def put(kind, name, src, size=SIZE, suffix=""):
        nonlocal total
        if not src.is_file():
            return False
        b = webp(first_mip(src, size) if size <= SIZE else Image.open(src).convert("RGBA").resize((size, size), Image.LANCZOS))
        (a.out / kind / f"{name}{suffix}.webp").write_bytes(b)
        total += len(b)
        return True

    for name, g in sorted(techs.items()):
        if put("tech", name, resolve(g)):
            written["tech"].append(name)
    entities = {}
    for typ, rows in protos.items():
        if typ not in ITEM_TYPES and typ not in PLACE_TYPES and typ != "technology" and typ != "recipe":
            entities.update({n: g for n, g in rows.items() if n not in entities})
    for name in sorted(wanted):
        g = items.get(name) or entities.get(name)
        if g and "/icons/" in g[1] and put("item", name, resolve(g)):
            written["item"].append(name)
    for typ in PLACE_TYPES:
        for name, g in sorted(protos.get(typ, {}).items()):
            if put("place", name, resolve(g)):
                written["place"].append(name)
                stem = "starmap-shattered-planet" if name == "shattered-planet" else f"starmap-planet-{name}"
                big = next((p for p in (a.data / m / "graphics" / "icons" / f"{stem}.png" for m in MODS) if p.is_file()),
                           Path("/nonexistent"))
                if big.is_file() and put("place", name, big, 160, "-big"):
                    written["place"].append(name + "-big")
    for kind in written:
        written[kind] = sorted(set(written[kind]))
    (a.out / "index.json").write_text(json.dumps(written, separators=(",", ":")) + "\n")
    (a.out / "README.md").write_text(
        "# Game graphics\n\nGraphics copyright Wube Software. Factorio's icons and pictures, used with Wube's "
        "permission for this free, non-commercial site; written by `tools/game_icons.py` from the game's data.\n")
    print(f"{sum(len(v) for v in written.values())} icons ({', '.join(f'{len(v)} {k}' for k, v in written.items())}), "
          f"{total / 1e6:.2f} MB into {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
