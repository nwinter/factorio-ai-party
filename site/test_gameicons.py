#!/usr/bin/env python3
"""The game's icons and Wube's credit (batch270, Nick d27 10:10): python3 site/test_gameicons.py

- site/static/game/ (tools/game_icons.py, tracked in git) has index.json and a file for every name it lists; every
  science pack, the planets and their big pictures are there;
- gameicons.key: a name, a technology level without its own picture (low-density-structure-productivity-10 ->
  the base name; mining-productivity-12 -> mining-productivity-4, the last level with a picture), a name the game
  has no icon for -> None, and img() -> "" so the page keeps its text;
- tools/game_icons.py's prototype reader: an icon in a local, an ingredient row is not a prototype;
- a fixture build: the footer of every page and /about/ carry "Graphics copyright Wube Software"; the icons are
  copied to dist/static/game/ (README left out) and check.py passes.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.path.insert(0, str(SITE.parent / "tools"))
import gameicons as gi  # noqa: E402
import game_icons  # noqa: E402

CREDIT = "Graphics copyright Wube Software"


def main():
    idx = json.loads((gi.GAME / "index.json").read_text())
    for kind, names in idx.items():
        for n in names:
            assert (gi.GAME / kind / f"{n}.webp").is_file(), (kind, n)
    for pack in ("automation", "logistic", "military", "chemical", "production", "utility", "space", "metallurgic",
                 "electromagnetic", "agricultural", "cryogenic", "promethium"):
        assert f"{pack}-science-pack" in idx["item"], pack
    for planet in ("nauvis", "vulcanus", "fulgora", "gleba", "aquilo", "shattered-planet"):
        assert planet in idx["place"] and planet + "-big" in idx["place"], planet
    assert CREDIT in (gi.GAME / "README.md").read_text()

    assert gi.key("tech", "automation") == "automation"
    assert gi.key("tech", "low-density-structure-productivity-10") == "low-density-structure-productivity"
    assert gi.key("tech", "mining-productivity-12") == "mining-productivity-4"
    assert gi.key("tech", "no-such-tech") is None and gi.key("item", "") is None
    assert gi.img("item", "no-such-item") == ""
    i = gi.item("iron-plate", 20)
    assert 'src="/static/game/item/iron-plate.webp"' in i and 'width="20"' in i and 'alt=""' in i
    assert gi.place("vulcanus", 80, big=True).count("vulcanus-big.webp") == 1

    lua = '''local x_icon = "__base__/graphics/technology/x-1.png"
data:extend({ { type = "technology", name = "x-1", icons = util.technology_icon_constant_damage(x_icon),
  unit = { ingredients = { {type = "item", name = "stone-brick", amount = 1} } } },
  { type = "item", name = "stone-brick", icon = "__base__/graphics/icons/stone-brick.png" } })'''
    got = {(t, n): g for t, n, g in game_icons.blocks(lua)}
    assert got[("technology", "x-1")] == ("base", "graphics/technology/x-1.png"), got
    assert got[("item", "stone-brick")] == ("base", "graphics/icons/stone-brick.png"), got

    from test_archive import make  # noqa: E402  (a made-up runs folder: pub1 -> pub2)
    content = dict(json.loads((SITE / "content" / "site.json").read_text()), archive=False, run_start="pub1")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        runs = d / "runs"
        runs.mkdir()
        make(runs)
        (d / "site.json").write_text(json.dumps(content))
        out = d / "dist"
        r = subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                            "--content", str(d / "site.json")], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout[-2000:]
        for p in out.rglob("*.html"):
            assert CREDIT in p.read_text(), p.relative_to(out)
        about = (out / "about" / "index.html").read_text()
        assert 'id="credits"' in about and "Wube Software</a>" in about
        assert (out / "static" / "game" / "item" / "iron-plate.webp").is_file()
        assert (out / "static" / "game" / "index.json").is_file() and not (out / "static" / "game" / "README.md").exists()
    print("test_gameicons: ok (icons on disk, lookups and levels, the prototype reader, the credit on every page)")


if __name__ == "__main__":
    main()
