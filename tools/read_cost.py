#!/usr/bin/env python3
"""What the host services' periodic game reads cost inside the game: per read, the Lua time of one run (LuaProfiler,
the tick it runs in) and the size of its reply. Read-only: each read is run once, as its service sends it, one at a
time with a pause between, its reply kept in the game (only the timing and the byte count come back).

  python3 tools/read_cost.py --world n                 # every read in READS
  python3 tools/read_cost.py --world n basemap extras  # some of them
  python3 tools/read_cost.py --list

2026-10-14 (operator 22:00): the stream service's score read (~0.8 s of Lua) and the live-map read (0.6 s) stalled
the game every few seconds; tools/stream/harness.py logs wall times as [slow-rcon], which include the RCON round trip.
"""
import argparse, json, os, sys, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream"))
sys.dont_write_bytecode = True
import pog  # noqa: E402
import harness as H  # noqa: E402


def timed_lua(body):
    """BODY (a read that ends in rcon.print(...)) run inside a function with rcon.print captured: prints
    "Duration: X ms|BYTES". A body that returns early still stops the timer."""
    return ("local __o local __rp = function(x) __o = x end "
            "local function __body() " + H.one_line(body).replace("rcon.print(", "__rp(") + " end "
            "local __t = helpers.create_profiler() local __ok, __e = pcall(__body) __t.stop() "
            "rcon.print({'', __t, '|', type(__o) == 'string' and #__o or -1, '|', __ok and 'ok' or tostring(__e)})")


def timed_dispatch(req):
    """A harness dispatch (an agent read or an operator read) timed the same way; status is the reply's error message
    when it has one (a refusal is cheap and says nothing of the read's cost). Each call gets its own request id (the
    harness answers a repeated id from its deduplication window)."""
    return ("local __t = helpers.create_profiler() local __ok, __r = pcall(remote.call, 'agent_harness', 'dispatch', "
            + H.lua_string(json.dumps(dict(req, id="read-cost-" + uuid.uuid4().hex[:12]))) + ") __t.stop() "
            "local __err = __ok and type(__r) == 'string' and __r:match('\"message\":\"([^\"]*)\"') "
            "rcon.print({'', __t, '|', type(__r) == 'string' and #__r or -1, '|', __ok and (__err and ('refused: ' .. __err) or 'ok') or tostring(__r)})")


def parse(out):
    """'Duration: 12.3ms|456|ok' -> (12.3, 456, 'ok')."""
    head, size, status = (out.strip().split("|", 2) + ["", ""])[:3]
    ms = float(head.replace("Duration:", "").replace("ms", "").strip())
    return ms, int(size), status


def reads(bot="sol", platform="Aegis"):
    """name -> (who and how often, the timed command). The periods are the services' own (see the report). Agent
    reads go as `bot` with peek (no cursor moves); board_events is left out (the stream reads it without peek)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("analyst_game", os.path.join(os.path.dirname(os.path.abspath(__file__)), "analyst", "game.py"))
    A = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(A)
    import model  # tools/stream: the stream's own item lists
    flow_items = model.SPARK_ITEMS
    packs = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
             "production-science-pack", "utility-science-pack", "space-science-pack", "metallurgic-science-pack",
             "electromagnetic-science-pack", "agricultural-science-pack", "cryogenic-science-pack"]

    def op(action, args=None):
        return lambda: timed_dispatch({"action": action, "args": args or {}, "operator": True})

    def agent(action, args=None):
        return lambda: timed_dispatch({"action": action, "args": dict(args or {}, peek=True), "bot": bot, "reader": "read_cost"})

    def items(lua, names):
        return lua.replace("ITEMS", "{" + ",".join(json.dumps(i) for i in names) + "}")

    def surface_all(lua):
        return lua.replace("SURFACE", json.dumps("all"))

    return {
        "score": ("stream 3 s, score loop 120 s: pog.SCORE_LUA", timed_lua(pog.SCORE_LUA)),
        "extras": ("stream 3 s: harness STREAM_LUA", timed_lua(H.STREAM_LUA)),
        "flows": ("stream 30 s: harness FLOW_LUA (the stream's SPARK_ITEMS)", timed_lua(items(H.FLOW_LUA, flow_items))),
        "used_flows": ("stream 30 s: harness USED_FLOW_LUA", timed_lua(items(H.USED_FLOW_LUA, packs))),
        "basemap": ("stream 60 s: harness BASEMAP_LUA (live map)", timed_lua(H.basemap_lua())),
        "basemap_ore": ("stream 300 s: BASEMAP_LUA with ore", timed_lua(H.basemap_lua(ore=True))),
        "platforms_view": ("stream 15 s: harness PLATFORM_LUA", timed_lua(H.PLATFORM_LUA)),
        "planets": ("stream 60 s: harness PLANET_READ_LUA, the list", timed_lua(H.planet_read_lua())),
        "planet_map": ("stream 60 s: harness PLANET_READ_LUA, one planet (vulcanus)", timed_lua(H.planet_read_lua("vulcanus"))),
        "probe": ("stream at start: harness PROBE_LUA", timed_lua(H.PROBE_LUA)),
        "snapshot": ("analyst 90 s: analyst/game.py SNAPSHOT_LUA", timed_lua(surface_all(A.SNAPSHOT_LUA))),
        "machines": ("analyst 90 s: analyst/game.py MACHINES_LUA", timed_lua(surface_all(A.MACHINES_LUA))),
        "status_brief": ("stream 3-9 s per agent: status brief alerts", agent("status", {"brief": True, "alerts": True})),
        "status": ("analyst 90 s: status", agent("status")),
        "profiles": ("stream 3 s: profiles", agent("profiles")),
        "chat": ("stream 3 s, analyst 90 s, chat-log 5 s: chat", agent("chat", {"limit": 30})),
        "board": ("stream 15 s: board limit 60", agent("board", {"limit": 60})),
        "board_claims": ("stream 15 s: board claims", agent("board", {"kind": "claim", "limit": 30})),
        "board_projects": ("stream 15 s: board projects", agent("board", {"kind": "project", "status": "active", "limit": 12})),
        "platforms": ("stream 15 s per platform: platforms", agent("platforms")),
        "describe": ("stream 300 s while something is missing: describe", agent("describe")),
        "confessions": ("stream 3 s: operator read", op("confessions", {"limit": 30})),
        "tells": ("stream 3 s: operator read", op("tells", {"limit": 30})),
        "operator_requests": ("stream 3 s: operator read", op("operator_requests", {"limit": 30})),
        "attack_groups_live": ("stream 3-10 s: operator read", op("attack_groups_live")),
        "big_enemies_live": ("stream 3-10 s: operator read", op("big_enemies_live")),
        "hauling": ("stream 300 s: operator read", op("hauling", {"top": 10})),
        "loadout": ("stream 3 s: operator read", op("loadout", {"top": 8})),
        "clouds": ("stream 60 s: operator read", op("clouds")),
        "efficiency": ("stream 300 s: operator read", op("efficiency")),
        "votes": ("viewer relay 60 s: operator read", op("votes")),
        "blueprint_library": ("bplibrary 60 s: operator read", op("blueprint_library")),
        "idle_report": ("idle nudge 60 s: operator read", op("idle_report")),
        "census_extras": ("inside extras: operator read census", op("census", {"part": "extras"})),
        "census_basemap": ("inside basemap: operator read census", op("census", {"part": "basemap"})),
        "census_snapshot": ("inside snapshot: operator read census", op("census", {"part": "snapshot"})),
        "census_machines": ("inside machines: operator read census", op("census", {"part": "machines"})),
        # Agent reads on request, not on a period (d15 blockers, seen but not fixed): one platform's endurance (its
        # route, rates, ingredient caps) and every artillery piece with its targets and the enemy units near it.
        "platform_endurance": ("agents on request: platform_endurance (--platform)", agent("platform_endurance", {"platform": platform})),
        "artillery": ("agents on request: artillery (up to 8 pieces)", agent("artillery")),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--pause", type=float, default=2.0, help="seconds between reads (default 2)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", action="store_true", help="one JSON row per read")
    ap.add_argument("--bot", default="sol", help="the bot the agent reads go as (peek; default sol)")
    ap.add_argument("--platform", default="Aegis", help="the platform platform_endurance reads (default Aegis)")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args(argv)
    table = reads(a.bot, a.platform)
    if a.list:
        for name, (who, _) in table.items():
            print(f"{name:20} {who}")
        return 0
    names = a.names or list(table)
    unknown = [n for n in names if n not in table]
    if unknown:
        print("unknown: " + ", ".join(unknown), file=sys.stderr)
        return 2
    h = H.Harness(a.world)
    for i, name in enumerate(names):
        if i:
            time.sleep(a.pause)
        cmd = table[name][1]
        out = h.command("/silent-command " + (cmd() if callable(cmd) else cmd))
        try:
            ms, size, status = parse(out)
        except ValueError:
            print(f"{name:20} unreadable: {out[:200]}")
            continue
        if a.json:
            print(json.dumps({"name": name, "ms": ms, "bytes": size, "status": status}))
        else:
            print(f"{name:20} {ms:9.2f} ms {size:8d} B  {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
