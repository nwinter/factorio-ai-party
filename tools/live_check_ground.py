#!/usr/bin/env python3
"""Live check for items on the ground (eng/ground: ground_items summaries, status alerts, deconstruct items_on_ground,
pickup over an area) on a test world.

  POG_WORLD=live python3 tools/live_check_ground.py [--bot lg1] [--keep] [--out runs/live-check-ground]

Run it from a checkout of eng/ground after deploying that runtime (POG_WORLD=live bin/fh deploy); the world needs a
client connected so the game runs at full speed (the check stops at once otherwise). Same method as
tools/live_check_coverage.py: a test bot acts through bin/fh, operator Lua stages and reads back, ok/FAIL per step,
cleanup at the end. Refuses a, b, c, n.

Steps: the bot builds a chest; operator Lua lays 160 stacks of 10 iron plates beside it. After the next watch pass
(30 s of game time): status alerts.ground_items names the pile; scan and observe summarize it (no rows); deconstruct
items_on_ground marks all 160 (read back from the game) and cancel_deconstruction unmarks them; pickup over the area
takes them all (picked_up; the area is empty and the bot holds the plates); pickup over an empty area is refused.
Then a cargo landing pad (operator Lua; skipped when the game refuses one here) with every slot filled and 30 coal
stacks around it: after the next pass, status names the full pad and the spill.
"""
import argparse, os, sys, time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_check_coverage as L  # noqa: E402

ITEMS = {"iron-chest": 1}
PILE_STACKS, PILE_COUNT = 160, 10   # 20 x 8 stacks, 0.4 tiles apart
WATCH_TICKS = 1800                   # ground.lua's pass interval


def widest(lo, hi, cell=64):
    """The widest part of [lo, hi] inside one 64-tile cell: the pile must sit in one cell to count as a pile."""
    cuts = [lo] + [k * cell for k in range(int(lo // cell) + 1, int(hi // cell) + 1)] + [hi]
    return max(zip(cuts, cuts[1:]), key=lambda s: s[1] - s[0])


def tick(c):
    return (c.lua("rcon.print(helpers.table_to_json{tick = game.tick})") or {}).get("tick") or 0


def wait_pass(c, since, sleep=time.sleep):
    """Wait until a watch pass is due: WATCH_TICKS of game time after `since` (at most 120 s of wall time)."""
    for _ in range(60):
        if tick(c) >= since + WATCH_TICKS + 30:
            return True
        sleep(2)
    return False


def lines_with(reply, *parts):
    lines = (((reply or {}).get("alerts") or {}).get("ground_items")) or []
    return [l for l in lines if all(p in l for p in parts)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bot", default="lg1")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--out", default=os.path.join(L.ROOT, "runs", "live-check-ground"))
    a = ap.parse_args()
    world = os.environ.get("POG_WORLD", "live")
    if world in ("a", "b", "c", "n"):
        sys.exit(f"refusing: {world} is a run world; this check builds and deletes things")
    c = L.Check(world, a.bot, a.out)
    ok, desc = c.fh("describe")
    actions = (desc.get("result") or {}).get("actions") or {}
    if not c.record("runtime has pickup area and deconstruct items_on_ground",
                    ok and "area" in (actions.get("pickup") or {}) and "items_on_ground" in (actions.get("deconstruct") or {}),
                    None):
        sys.exit(f"deploy the eng/ground runtime first: POG_WORLD={world} bin/fh deploy (from that branch)")
    if not c.game_running():
        sys.exit(L.PAUSED_HINT)
    created = c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))')
    bot_unit = ((created or {}).get("bot") or {}).get("unit_number")
    if not c.record("bot_create", bot_unit is not None, created):
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

    # The pile: in the widest part of the site's east side that lies in one 64-tile cell, beside a chest of ours.
    x0, x1 = widest(ox + 12, ox + L.SITE_W - 1)
    y0, y1 = widest(oy + 1, oy + L.SITE_H - 1)
    chest = c.build("iron chest (our building)", "iron-chest", int(x0) + 0.5, int(y0) + 0.5)
    px, py = int(x0) + 2, int(y0) + 1
    area = {"left_top": {"x": px - 1, "y": py - 1}, "right_bottom": {"x": px + 10, "y": py + 5}}
    laid = c.lua(f"""
      local s, n = game.surfaces.nauvis, 0
      for i = 0, {PILE_STACKS - 1} do
        local e = s.create_entity{{name="item-on-ground", position={{{px} + (i % 20) * 0.4, {py} + math.floor(i / 20) * 0.4}},
          stack={{name="iron-plate", count={PILE_COUNT}}}}}
        if e then n = n + 1 end
      end
      rcon.print(helpers.table_to_json{{laid = n, tick = game.tick}})
    """)
    c.record(f"stage: {PILE_STACKS} stacks of {PILE_COUNT} iron plates at ({px},{py})", laid.get("laid") == PILE_STACKS, laid)
    area_lua = f"{{{{{area['left_top']['x']}, {area['left_top']['y']}}}, {{{area['right_bottom']['x']}, {area['right_bottom']['y']}}}}}"

    def ground_lua():
        """Item stacks in the pile's area as the game holds them: count, marked, iron plates."""
        return c.lua(f"""
          local n, marked, plates = 0, 0, 0
          for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{area={area_lua}, type="item-entity"}}) do
            n = n + 1
            if e.to_be_deconstructed() then marked = marked + 1 end
            if e.stack.valid_for_read and e.stack.name == "iron-plate" then plates = plates + e.stack.count end
          end
          rcon.print(helpers.table_to_json{{stacks = n, marked = marked, plates = plates}})
        """)

    # Status alert after the next watch pass, and the same line in the reply's team alerts.
    if not c.record("game: a watch pass is due", wait_pass(c, laid.get("tick") or tick(c)), None):
        sys.exit(1)
    ok, st = c.fh("status")
    res = st.get("result") or {}
    want = f"{PILE_STACKS} item stacks on the ground at"
    found = lines_with(res, want, f"{PILE_STACKS * PILE_COUNT} iron-plate", "near our buildings")
    c.record("status alerts.ground_items names the pile", bool(found), found or (res.get("alerts") or {}).get("ground_items"))
    team = [l for l in ((res.get("team") or {}).get("alerts") or []) if want in l]
    c.record("the reply's team.alerts carries it once", bool(team), team or res.get("team"))
    ok, again = c.fh("status")
    team2 = [l for l in (((again.get("result") or {}).get("team") or {}).get("alerts") or []) if want in l]
    c.record("not repeated on the next reply", ok and not team2, team2)

    # scan and observe: a summary, no rows.
    scan = c.step("scan the pile", "scan", {"area": area}) or {}
    g = scan.get("ground_items") or {}
    top = (g.get("items") or [{}])[0]
    rows = [e for e in scan.get("entities") or [] if e.get("name") == "item-on-ground"]
    c.record("scan: ground_items 160 stacks, 1600 iron-plate, no rows",
             g.get("stacks") == PILE_STACKS and top.get("name") == "iron-plate" and top.get("count") == PILE_STACKS * PILE_COUNT
             and not rows, {"ground_items": g, "rows": len(rows)})
    rows = (c.step("scan filtered for item-entity", "scan", {"area": area, "type": "item-entity", "limit": 5}) or {})
    c.record("scan type=item-entity: rows", len(rows.get("entities") or []) == 5, {"rows": len(rows.get("entities") or [])})
    obs = c.step("observe at the pile", "observe", {"position": {"x": px + 4, "y": py + 1.5}, "radius": 6}) or {}
    og = obs.get("ground_items") or {}
    orows = [e for e in obs.get("entities") or [] if e.get("name") == "item-on-ground"]
    c.record("observe: ground_items, no rows", (og.get("stacks") or 0) >= 100 and not orows, {"stacks": og.get("stacks"), "rows": len(orows)})

    # Deconstruction marks, read back from the game, then cancelled.
    marked = c.step("deconstruct items_on_ground", "deconstruct", {"area": area, "items_on_ground": True}) or {}
    got = ground_lua()
    c.record("game: all 160 stacks marked for deconstruction", marked.get("item_stacks") == PILE_STACKS
             and got.get("marked") == PILE_STACKS, {"reply": marked, "game": got})
    if chest:
        alive = c.lua(f"""
          local e = game.get_entity_by_unit_number({chest.get('unit_number') or 0})
          rcon.print(helpers.table_to_json{{marked = e and e.to_be_deconstructed() or false}})
        """)
        c.record("game: our chest is not marked", alive.get("marked") is False, alive)
    unmarked = c.step("cancel_deconstruction items_on_ground", "cancel_deconstruction", {"area": area, "items_on_ground": True}) or {}
    got = ground_lua()
    c.record("game: no stack marked after cancel", unmarked.get("item_stacks") == PILE_STACKS and got.get("marked") == 0,
             {"reply": unmarked, "game": got})

    # pickup over the area: all of it, then an empty area is refused.
    before = c.lua(f"""
      local body = game.get_entity_by_unit_number({bot_unit})
      rcon.print(helpers.table_to_json{{plates = body and body.get_item_count("iron-plate") or 0}})
    """)
    ok, picked = c.fh("pickup", {"area": area, "ticks": 7200}, wait=True)
    res = picked.get("result") or {}
    last = res.get("last") or (res.get("completion") or {}).get("last") or {}
    got = ground_lua()
    after = c.lua(f"""
      local body = game.get_entity_by_unit_number({bot_unit})
      rcon.print(helpers.table_to_json{{plates = body and body.get_item_count("iron-plate") or 0}})
    """)
    gained = (after.get("plates") or 0) - (before.get("plates") or 0)
    c.record("pickup area: picked_up, area empty, bot holds the plates",
             ok and last.get("outcome") == "picked_up" and got.get("stacks") == 0 and gained == PILE_STACKS * PILE_COUNT,
             {"ok": ok, "last": last, "game": got, "gained": gained, "error": picked.get("error")})
    ok, refused = c.fh("pickup", {"area": area})
    msg = ((refused.get("error") or {}).get("message") or "")
    c.record("pickup on an empty area is refused", not ok and "no items on the ground" in msg, msg[:200])

    # A full cargo landing pad with a spill around it (the game may refuse a second pad on this surface: skipped).
    pad = c.lua(f"""
      local s = game.surfaces.nauvis
      local ok, pad = pcall(function() return s.create_entity{{name="cargo-landing-pad", position={{{ox + 5}, {oy + 7}}}, force="player"}} end)
      if not (ok and pad) then rcon.print(helpers.table_to_json{{error = ok and "create_entity returned nil" or tostring(pad)}}) return end
      local inv = pad.get_inventory(defines.inventory.cargo_landing_pad_main)
      for i = 1, #inv do inv[i].set_stack{{name="stone", count=50}} end
      local n = 0
      for i = 0, 29 do
        if s.create_entity{{name="item-on-ground", position={{{ox + 1} + (i % 10) * 0.5, {oy + 12} + math.floor(i / 10) * 0.5}},
          stack={{name="coal", count=20}}}} then n = n + 1 end
      end
      rcon.print(helpers.table_to_json{{unit = pad.unit_number, x = pad.position.x, y = pad.position.y, slots = #inv,
        empty = inv.count_empty_stacks(), spilled = n, tick = game.tick}})
    """)
    if pad.get("unit"):
        c.built.append(pad["unit"])
        c.record("stage: a full cargo landing pad and 30 coal stacks", pad.get("empty") == 0 and pad.get("spilled") == 30, pad)
        if c.record("game: a watch pass is due (pad)", wait_pass(c, pad.get("tick") or tick(c)), None):
            ok, st = c.fh("status")
            res = st.get("result") or {}
            where = f"cargo landing pad at ({int(pad['x'] // 1)},{int(pad['y'] // 1)}) on nauvis is full ({pad['slots']}/{pad['slots']} slots)"
            found = lines_with(res, where, "pods spill", "coal")
            c.record("status alerts.ground_items names the full pad and the spill", bool(found),
                     found or (res.get("alerts") or {}).get("ground_items"))
    else:
        c.record("cargo landing pad (informational: the game refused one here)", True, pad)

    if a.keep:
        print(f"--keep: left the site at ({ox},{oy}) and bot {a.bot}")
    else:
        gone = c.lua(L.cleanup_lua(c.built, ox, oy, ["iron-chest", "cargo-landing-pad", "item-on-ground"]))
        c.record("cleanup: built entities removed", "removed" in gone, gone)
        c.record("cleanup: bot removed", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{a.bot}"))'))
    fails = [s for s, ok in c.results if not ok]
    print(f"\n{len(c.results) - len(fails)} ok, {len(fails)} failed" + (": " + "; ".join(fails) if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
