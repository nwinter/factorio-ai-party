#!/usr/bin/env python3
"""Live check for valid placements near a refused build (eng/shore: offshore-pump and water refusals list the nearest
spots the game's manual check accepts; the placements read) on a test world.

  POG_WORLD=live python3 tools/live_check_shore.py [--bot ls1] [--keep] [--out runs/live-check-shore]

Run it from a checkout of eng/shore after deploying that runtime (POG_WORLD=live bin/fh deploy); the world needs a
client connected so the game runs (the check stops at once otherwise). Same method as tools/live_check_coverage.py: a
test bot acts through bin/fh, operator Lua stages and reads back, ok/FAIL per step, cleanup at the end. Refuses a, b,
c, n.

Steps: operator Lua turns a 10x10 square of the clear site into water (a lake edge; the old tiles are put back at
cleanup). The bot builds an offshore pump on dry land 5 tiles west of the shore: refused, and the error lists up to 3
placements, nearest first; each one passes the game's own can_place_entity (manual) read back by operator Lua, and the
placements read returns the same list. The bot builds the pump at the first one (read back: position and direction).
Then a boiler half on the water: refused by water, with positions where it fits facing north; the bot builds it at the
first one.
"""
import argparse, math, os, re, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402

ITEMS = {"offshore-pump": 2, "boiler": 1}
POND = (22, 2, 10, 10)   # x, y (from the site's corner), width, height
SPOT = re.compile(r"\((-?[\d.]+),(-?[\d.]+)\) (north|east|south|west)")


def spots(message):
    """The suggestions in a refusal: [(x, y, direction)], in order."""
    tail = message.split("game build check", 1)[-1]
    return [(float(x), float(y), d) for x, y, d in SPOT.findall(tail)]


def nearest_first(want, found, radius):
    d = [math.hypot(x - want[0], y - want[1]) for x, y, _ in found]
    return bool(found) and d == sorted(d) and d[-1] <= radius + 0.01


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bot", default="ls1")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out", default=os.path.join(L.ROOT, "runs", "live-check-shore"))
    a = ap.parse_args()
    world = os.environ.get("POG_WORLD", "live")
    if world in ("a", "b", "c", "n"):
        sys.exit(f"refusing: {world} is a run world; this check builds and deletes things")
    c = L.Check(world, a.bot, a.out)
    ok, desc = c.fh("describe")
    actions = (desc.get("result") or {}).get("actions") or {}
    if not c.record("runtime has the placements read", ok and "placements" in actions, None):
        sys.exit(f"deploy the eng/shore runtime first: POG_WORLD={world} bin/fh deploy (from that branch)")
    if not c.game_running():
        sys.exit(L.PAUSED_HINT)
    created = c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))')
    if not c.record("bot_create", ((created or {}).get("bot") or {}).get("unit_number") is not None, created):
        sys.exit(1)
    ok, st = c.fh("status")
    pos = (st.get("result") or {}).get("position")
    if not c.record("bot status", ok and pos is not None, pos):
        sys.exit(1)
    stage = c.lua(L.stage_lua(pos, ITEMS))
    if not c.record("stage: site and items", "site" in stage, stage):
        sys.exit(1)
    ox, oy = stage["site"]["x"], stage["site"]["y"]
    c.here = (ox + 4, oy - 2)

    # The lake: water tiles on the site's east side; the old tile names kept to put back.
    px, py, pw, ph = ox + POND[0], oy + POND[1], POND[2], POND[3]
    dug = c.lua(f"""
      local s, old, tiles = game.surfaces.nauvis, {{}}, {{}}
      for x = {px}, {px + pw - 1} do
        for y = {py}, {py + ph - 1} do
          old[#old + 1] = {{x, y, s.get_tile(x, y).name}}
          tiles[#tiles + 1] = {{name = "water", position = {{x, y}}}}
        end
      end
      s.set_tiles(tiles)
      rcon.print(helpers.table_to_json{{old = old, water = s.count_tiles_filtered{{area = {{{{{px}, {py}}}, {{{px + pw}, {py + ph}}}}}, name = "water"}}}})
    """)
    old = dug.get("old") or []
    c.record(f"stage: {pw}x{ph} water at ({px},{py})", dug.get("water") == pw * ph, {"water": dug.get("water")})

    def game_accepts(name, found):
        """Each suggestion as the game's manual build check sees it."""
        rows = ",".join(f'{{{x},{y},defines.direction.{d}}}' for x, y, d in found)
        got = c.lua(f"""
          local s, ok = game.surfaces.nauvis, {{}}
          for _, r in ipairs{{{rows}}} do
            ok[#ok + 1] = s.can_place_entity{{name = "{name}", position = {{r[1], r[2]}}, direction = r[3], force = "player",
              build_check_type = defines.build_check_type.manual}}
          end
          rcon.print(helpers.table_to_json{{ok = ok}})
        """)
        return got.get("ok") or [], got

    def build_at(name, item, x, y, d):
        """Build and wait: a build whose footprint holds the bot steps aside first (a timed action; the entity is in
        last.result). The game is asked what stands at the spot by name and position, whatever the reply held."""
        c.near(x, y)
        ok, reply = c.fh("build", {"item": item, "position": {"x": x, "y": y}, "direction": d}, wait=True)
        res = reply.get("result") or {}
        last = res.get("last") or (res.get("completion") or {}).get("last") or {}
        entity = res.get("entity") or (last.get("result") or {}).get("entity") or {}
        c.record(f"build {name}", ok, {"entity": entity, "aside": res.get("aside"), "outcome": last.get("outcome"),
                                        "error": reply.get("error")})
        got = c.lua(f"""
          local e = game.surfaces.nauvis.find_entity("{item}", {{{x}, {y}}})
          rcon.print(helpers.table_to_json(e and {{name = e.name, unit = e.unit_number, x = e.position.x, y = e.position.y,
            direction = e.direction}} or {{}}))
        """)
        if got.get("unit"):
            c.built.append(got["unit"])
        return got

    dirs = {"north": 0, "east": 4, "south": 8, "west": 12}

    # A pump on dry land, 5 tiles west of the shore: refused, with suggestions.
    want = (px - 5.5, py + 5)
    c.near(*want, force=True)
    ok, refused = c.fh("build", {"item": "offshore-pump", "position": {"x": want[0], "y": want[1]}})
    msg = (refused.get("error") or {}).get("message") or ""
    found = spots(msg)
    c.record("offshore pump on dry land: refused with up to 3 placements", not ok and "nearest valid offshore-pump placements" in msg
             and 1 <= len(found) <= 3, msg[:400])
    c.record("placements nearest first, within 12 tiles", nearest_first(want, found, 12), found)
    accepted, raw = game_accepts("offshore-pump", found)
    c.record("game: can_place_entity (manual) accepts each", bool(found) and accepted == [True] * len(found), raw)
    read = c.step("placements read", "placements", {"name": "offshore-pump", "position": {"x": want[0], "y": want[1]}}) or {}
    listed = [(p["position"]["x"], p["position"]["y"], p["direction"]) for p in read.get("placements") or []]
    c.record("placements read: the same list", listed == found and (read.get("checked") or 0) <= 400,
             {"read": listed, "checked": read.get("checked")})
    if found:
        x, y, d = found[0]
        got = build_at("offshore pump at the first placement", "offshore-pump", x, y, d)
        c.record("game: the pump stands there, facing that way", got.get("name") == "offshore-pump"
                 and abs(got.get("x", 1e9) - x) < 0.01 and abs(got.get("y", 1e9) - y) < 0.01 and got.get("direction") == dirs[d], got)

    # A boiler half on the water: refused by water, with positions where it fits facing north.
    want = (px + 0.5, py + 9)
    c.near(px - 4, want[1], force=True)
    ok, refused = c.fh("build", {"item": "boiler", "position": {"x": want[0], "y": want[1]}})
    msg = (refused.get("error") or {}).get("message") or ""
    found = spots(msg)
    c.record("boiler on water: refused by water, with positions facing north", not ok and "by tiles: water" in msg
             and "nearest positions where boiler fits facing north" in msg and found and all(d == "north" for *_, d in found), msg[:400])
    c.record("boiler positions nearest first, within 6 tiles", nearest_first(want, found, 6), found)
    accepted, raw = game_accepts("boiler", found)
    c.record("game: can_place_entity (manual) accepts each boiler position", bool(found) and accepted == [True] * len(found), raw)
    if found:
        x, y, d = found[0]
        got = build_at("boiler at the first position", "boiler", x, y, d)
        c.record("game: the boiler stands there", got.get("name") == "boiler" and abs(got.get("x", 1e9) - x) < 0.01
                 and abs(got.get("y", 1e9) - y) < 0.01, got)

    if a.keep:
        print(f"--keep: left the site at ({ox},{oy}), the water and bot {a.bot}")
    else:
        gone = c.lua(L.cleanup_lua(c.built, ox, oy, ["offshore-pump", "boiler"]))
        c.record("cleanup: built entities removed", "removed" in gone, gone)
        rows = ",".join(f'{{name="{n}",position={{{x},{y}}}}}' for x, y, n in old)
        back = c.lua(f"""
          local s = game.surfaces.nauvis
          s.set_tiles{{{rows}}}
          rcon.print(helpers.table_to_json{{water = s.count_tiles_filtered{{area = {{{{{px}, {py}}}, {{{px + pw}, {py + ph}}}}}, name = "water"}}}})
        """)
        c.record("cleanup: the old tiles are back", bool(old) and back.get("water") == 0, back)
        c.record("cleanup: bot removed", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{a.bot}"))'))
    fails = [s for s, ok in c.results if not ok]
    print(f"\n{len(c.results) - len(fails)} ok, {len(fails)} failed" + (": " + "; ".join(fails) if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
