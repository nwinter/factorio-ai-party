#!/usr/bin/env python3
"""Time the site map's base read (harness.BASEMAP_LUA) once on a world, read-only: the game's own profiler around the
read (the time the game spends in it) and the RCON round trip, without and with ore.

    python3 tools/stream/basemap_time.py [--world live] [--save OUT.json]
"""
import argparse, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default="live")
    ap.add_argument("--save", help="write the read (with ore) here, e.g. to render the map from it")
    a = ap.parse_args()
    h = harness.Harness(a.world)
    for ore in (False, True):
        lua = harness.basemap_lua(ore=ore).rstrip()
        assert lua.endswith("})") and "rcon.print(helpers.table_to_json{" in lua, "BASEMAP_LUA no longer ends in rcon.print(...{...})"
        lua = lua.replace("rcon.print(helpers.table_to_json{", "local __j = helpers.table_to_json{")[:-1]  # drop print's ")"
        lua = "local __p = helpers.create_profiler()\n" + lua + \
            '\n__p.stop()\nrcon.print({"", "game time ", __p})\nrcon.print(__j)'
        t = time.time()
        raw = h.command("/silent-command " + harness.one_line(lua))
        dt = time.time() - t
        prof, body = raw.split("\n", 1)
        m = json.loads(body)
        core = m.get("core") or {}
        print(f"ore={ore}: {prof.strip()}; round trip {dt * 1000:.0f} ms; {len(body):,} bytes; {m['buildings']:,} buildings; "
              f"overview {m['w']}x{m['h']} at {m['cell']} tiles; core {core.get('w')}x{core.get('h')} at {core.get('cell')} "
              f"tile(s) from ({core.get('x0')}, {core.get('y0')})")
        if ore and a.save:
            json.dump(m, open(a.save, "w"))


if __name__ == "__main__":
    main()
