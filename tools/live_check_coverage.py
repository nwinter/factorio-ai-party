#!/usr/bin/env python3
"""Live check for the coverage tools (eng/coverage: circuit wires and settings, trains, rails) on a test world.

  POG_WORLD=live python3 tools/live_check_coverage.py [--bot lc1] [--keep] [--out runs/live-check-coverage]

Needs the world running with the current runtime deployed (bin/fh deploy) and its RCON reachable (the usual tunnel).
A test bot does every step through bin/fh, as an agent would; operator Lua only sets the stage (the bot, its items, a
clear site) and reads back what the game holds afterwards, so a pass means the game took the setting, not just that
the harness replied. Every step prints ok/FAIL and later steps still run. At the end everything the check built is
removed and the bot is deleted (--keep leaves them for a look). Refuses the run worlds (a, b, c, n).

Steps:
  1. circuit: an iron chest and an inserter, wire red between them, inserter enable condition iron-plate < 10.
  2. combinator: a constant combinator sending signal-A=1, wired red to a lamp with enable condition signal-A > 0.
  3. trains: a straight track, two named stops (limit 1 on one), two locomotives back to back with coal, a two-stop
     schedule with automatic=true; then the train's state after a few seconds (informational).
  4. rails: one curved rail (curved-rail-a) beside the track.
"""
import argparse, json, os, subprocess, sys, time

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pog  # noqa: E402

ITEMS = {"iron-chest": 2, "inserter": 2, "constant-combinator": 1, "small-lamp": 1, "rail": 60, "train-stop": 2,
         "locomotive": 2, "coal": 100, "iron-plate": 20}
SITE_W, SITE_H = 36, 14   # tiles the check builds in, cleared of trees and rocks first


def one_line(lua):
    return " ".join(l.strip() for l in lua.strip().splitlines() if l.strip() and not l.strip().startswith("--"))


class Check:
    def __init__(self, world, bot, out):
        self.world, self.bot = world, bot
        os.makedirs(out, exist_ok=True)
        self.log = open(os.path.join(out, "check.jsonl"), "a")
        port = pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
        self.rcon = pog.Rcon("127.0.0.1", port, open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip())
        self.results, self.built = [], []

    def record(self, step, ok, detail):
        self.results.append((step, ok))
        text = detail if isinstance(detail, str) else json.dumps(detail)
        self.log.write(json.dumps({"t": time.strftime("%H:%M:%S"), "step": step, "ok": ok, "detail": detail}) + "\n")
        self.log.flush()
        print(f"{'ok  ' if ok else 'FAIL'} {step}: {text[:300]}", flush=True)
        return ok

    def lua(self, code):
        out = self.rcon.command("/silent-command " + one_line(code))
        try:
            return json.loads(out)
        except ValueError:
            return {"error": out}

    def fh(self, action, args=None, wait=False):
        bot = [] if action == "describe" else ["--bot", self.bot]  # describe needs no bot (the test bot isn't made yet)
        cmd = [os.path.join(ROOT, "bin", "fh"), "--format", "json", *bot, "call", action]
        if args is not None:
            cmd += ["--args", json.dumps(args)]
        if wait:
            cmd.append("--wait")
        p = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, POG_WORLD=self.world))
        try:
            reply = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
        except ValueError:
            reply = {"raw": p.stdout[-400:]}
        if p.returncode != 0 and not reply.get("error"):
            reply["error"] = {"message": (p.stderr or p.stdout)[-400:]}
        return p.returncode == 0, reply

    def step(self, name, action, args=None, wait=False):
        ok, reply = self.fh(action, args, wait)
        if not ok:
            self.record(name, False, (reply.get("error") or {}).get("message") or reply)
            return None
        return reply.get("result", reply)

    def near(self, x, y, force=False):
        """Walk the bot within reach of (x, y), as an agent would (move_to --wait). The position kept between moves is
        an estimate, so force=True always walks (live check 01:31: a stop 11.6 tiles off was taken as near)."""
        here = getattr(self, "here", None)
        if not force and here and abs(here[0] - x) < 5 and abs(here[1] - y) < 5:
            return
        ok, reply = self.fh("move_to", {"position": {"x": x, "y": y - 3}, "tolerance": 1}, wait=True)
        if ok:
            pos = (reply.get("result") or {}).get("position") or {}
            self.here = (pos.get("x", x), pos.get("y", y - 3))
        else:
            self.record(f"move_to near ({x},{y})", False, (reply.get("error") or {}).get("message") or reply)

    def build(self, name, item, x, y, direction=None, entity=None):
        self.near(x, y)
        args = {"item": item, "position": {"x": x, "y": y}}
        if direction:
            args["direction"] = direction
        if entity:
            args["entity"] = entity
        res = self.step(f"build {name}", "build", args)
        ent = (res or {}).get("entity") or {}
        if ent.get("unit_number"):
            self.built.append(ent["unit_number"])
        return ent if res else None


def stage_lua(pos, items):
    """Operator Lua that stages a check: the bot's character, a clear site near it (trees and rocks removed, no water,
    nothing else built there), the bot moved beside the site and given the items. Prints {site, given} or {error}."""
    items = ",".join(f'["{k}"]={v}' for k, v in items.items())
    return f"""
      local s = game.surfaces.nauvis
      local bx, by = {pos['x']}, {pos['y']}
      local body
      for _, e in pairs(s.find_entities_filtered{{type="character", position={{bx, by}}, radius=2}}) do
        if not e.player then body = e end
      end
      if not body then rcon.print(helpers.table_to_json{{error="no bot character near the bot's position"}}) return end
      local site
      for r = 0, 12 do
        for _, d in ipairs{{{{1,0}},{{0,1}},{{-1,0}},{{0,-1}}}} do
          if not site then
            local ox = math.floor(bx / 2) * 2 + d[1] * r * 16
            local oy = math.floor(by / 2) * 2 + 4 + d[2] * r * 16
            local area = {{{{ox, oy}}, {{ox + {SITE_W}, oy + {SITE_H}}}}}
            local water = s.count_tiles_filtered{{area=area, collision_mask="water_tile"}}
            local other = 0
            for _, e in pairs(s.find_entities_filtered{{area=area}}) do
              if e.type ~= "tree" and e.type ~= "simple-entity" and e.type ~= "resource" and e.type ~= "character"
                and e.type ~= "corpse" and e.type ~= "item-entity" then other = other + 1 end
            end
            if water == 0 and other == 0 then site = {{x=ox, y=oy, area=area}} end
          end
        end
      end
      if not site then rcon.print(helpers.table_to_json{{error="no clear site near the bot"}}) return end
      for _, e in pairs(s.find_entities_filtered{{area=site.area, type={{"tree","simple-entity"}}}}) do e.destroy() end
      body.teleport({{site.x + 4, site.y - 2}})
      local given = {{}}
      for name, n in pairs({{{items}}}) do given[name] = body.insert{{name=name, count=n}} end
      rcon.print(helpers.table_to_json{{site={{x=site.x, y=site.y}}, given=given}})
    """


def cleanup_lua(units, ox, oy, names):
    """Operator Lua that removes what a check built: by unit number, then anything of these names left on the site."""
    units = ",".join(str(u) for u in units)
    names = ",".join(f'"{n}"' for n in names)
    return f"""
      local n = 0
      for _, u in ipairs{{{units}}} do
        local e = game.get_entity_by_unit_number(u)
        if e and e.valid then e.destroy(); n = n + 1 end
      end
      local s = game.surfaces.nauvis
      local area = {{{{{ox}, {oy}}}, {{{ox + SITE_W}, {oy + SITE_H}}}}}
      for _, e in pairs(s.find_entities_filtered{{area=area, name={{{names}}}}}) do e.destroy(); n = n + 1 end
      rcon.print(helpers.table_to_json{{removed = n}})
    """


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bot", default="lc1")
    ap.add_argument("--keep", action="store_true", help="leave what the check built and the bot")
    ap.add_argument("--out", default=os.path.join(ROOT, "runs", "live-check-coverage"))
    a = ap.parse_args()
    world = os.environ.get("POG_WORLD", "live")
    if world in ("a", "b", "c", "n"):
        sys.exit(f"refusing: {world} is a run world; this check builds and deletes things")
    c = Check(world, a.bot, a.out)

    # The runtime must have the new actions.
    ok, desc = c.fh("describe")
    actions = (desc.get("result") or {}).get("actions") or {}
    if not c.record("runtime has circuit, train and wire color", ok and "circuit" in actions and "train" in actions
                    and "color" in (actions.get("wire") or {}), sorted(k for k in ("circuit", "train") if k in actions)):
        sys.exit("deploy the current runtime first: POG_WORLD=%s bin/fh deploy" % world)

    # Stage: the bot, a clear site next to it, its items.
    c.record("bot_create", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))'))
    ok, st = c.fh("status")
    pos = (st.get("result") or {}).get("position")
    if not c.record("bot status", ok and pos is not None, pos):
        sys.exit(1)
    stage = c.lua(stage_lua(pos, ITEMS))
    if not c.record("stage: site and items", "site" in stage, stage):
        sys.exit(1)
    ox, oy = stage["site"]["x"], stage["site"]["y"]
    c.here = (ox + 4, oy - 2)

    # 1. Circuit: chest <-red-> inserter, enable condition iron-plate < 10.
    chest = c.build("iron-chest", "iron-chest", ox + 2.5, oy + 0.5)
    ins = c.build("inserter", "inserter", ox + 3.5, oy + 0.5, "east")
    if chest and ins:
        c.near(ins["position"]["x"], ins["position"]["y"])
        w = c.step("wire red chest-inserter", "wire", {"from": chest["position"], "to": ins["position"], "color": "red"})
        cond = c.step("circuit enable on inserter", "circuit",
                      {"position": ins["position"], "enable": {"signal": "iron-plate", "comparator": "<", "value": 10}})
        got = c.lua(f"""
          local s = game.surfaces.nauvis
          local i = s.find_entities_filtered{{name="inserter", position={{{ins['position']['x']}, {ins['position']['y']}}}, radius=0.3}}[1]
          local ch = s.find_entities_filtered{{name="iron-chest", position={{{chest['position']['x']}, {chest['position']['y']}}}, radius=0.3}}[1]
          local cb = i.get_control_behavior()
          local a = ch.get_wire_connector(defines.wire_connector_id.circuit_red, false)
          local b = i.get_wire_connector(defines.wire_connector_id.circuit_red, false)
          local c = cb and cb.circuit_condition
          rcon.print(helpers.table_to_json{{wired = a ~= nil and b ~= nil and a.is_connected_to(b),
            enable = cb and cb.circuit_enable_disable, signal = c and c.first_signal and c.first_signal.name,
            comparator = c and c.comparator, constant = c and c.constant}})
        """)
        c.record("game: chest and inserter wired red", w is not None and got.get("wired") is True, got)
        c.record("game: inserter enable iron-plate < 10", cond is not None and got.get("enable") is True
                 and got.get("signal") == "iron-plate" and got.get("comparator") == "<" and got.get("constant") == 10, got)

    # 2. Combinator: constant combinator signal-A=1 <-red-> lamp with enable signal-A > 0.
    comb = c.build("constant-combinator", "constant-combinator", ox + 6.5, oy + 0.5)
    lamp = c.build("small-lamp", "small-lamp", ox + 8.5, oy + 0.5)
    if comb and lamp:
        c.near(lamp["position"]["x"], lamp["position"]["y"])
        sig = c.step("circuit signals on combinator", "circuit",
                     {"position": comb["position"], "signals": [{"signal": "signal-A", "count": 1}]})
        w = c.step("wire red combinator-lamp", "wire", {"from": comb["position"], "to": lamp["position"], "color": "red"})
        cond = c.step("circuit enable on lamp", "circuit",
                      {"position": lamp["position"], "enable": {"signal": "signal-A", "comparator": ">", "value": 0}})
        got = c.lua(f"""
          local s = game.surfaces.nauvis
          local k = s.find_entities_filtered{{name="constant-combinator", position={{{comb['position']['x']}, {comb['position']['y']}}}, radius=0.3}}[1]
          local l = s.find_entities_filtered{{name="small-lamp", position={{{lamp['position']['x']}, {lamp['position']['y']}}}, radius=0.3}}[1]
          local kb, lb = k.get_control_behavior(), l.get_control_behavior()
          local sec = kb and kb.sections_count > 0 and kb.get_section(1)
          local f = sec and sec.filters and sec.filters[1]
          local a = k.get_wire_connector(defines.wire_connector_id.circuit_red, false)
          local b = l.get_wire_connector(defines.wire_connector_id.circuit_red, false)
          local cc = lb and lb.circuit_condition
          rcon.print(helpers.table_to_json{{signal = f and f.value and f.value.name, count = f and f.min,
            wired = a ~= nil and b ~= nil and a.is_connected_to(b), enable = lb and lb.circuit_enable_disable,
            lamp_signal = cc and cc.first_signal and cc.first_signal.name, comparator = cc and cc.comparator,
            constant = cc and cc.constant}})
        """)
        c.record("game: combinator sends signal-A=1", sig is not None and got.get("signal") == "signal-A" and got.get("count") == 1, got)
        c.record("game: combinator and lamp wired red", w is not None and got.get("wired") is True, got)
        c.record("game: lamp enable signal-A > 0", cond is not None and got.get("enable") is True
                 and got.get("lamp_signal") == "signal-A" and got.get("comparator") == ">" and got.get("constant") == 0, got)

    # 3. Trains: a straight east-west track of 2x2 straight rails, then stops, locomotives, fuel, schedule.
    ry = oy + 7          # rails sit on the 2-tile grid; try the odd row first, then the even one
    track = []
    for attempt, y in enumerate((ry, ry + 1)):
        track = []
        for k in range(16):
            ent = c.build(f"straight rail {k + 1} (row {y})", "rail", ox + 1 + 2 * k, y, "east")
            if not ent:
                break
            track.append(ent)
        if len(track) == 16:
            ry = track[0]["position"]["y"]
            break
    c.record("rails: 16 straight pieces", len(track) == 16, f"{len(track)} placed at y={ry}")
    stops = {}
    if len(track) == 16:
        east_end, west_end = track[-1]["position"]["x"], track[0]["position"]["x"]
        # A train stop goes on the right of the direction of travel: south of an eastbound track, north of a westbound.
        for name, x, side, direction in (("LC-East", east_end - 1, 2, "east"), ("LC-West", west_end + 1, -2, "west")):
            for dy in (side, side + (1 if side > 0 else -1)):
                ent = c.build(f"train stop {name}", "train-stop", x, ry + dy, direction)
                if ent:
                    stops[name] = ent
                    break
        for name, ent in stops.items():
            args = {"position": ent["position"], "station": name}
            if name == "LC-East":
                args["limit"] = 1
            c.near(ent["position"]["x"], ent["position"]["y"], force=True)
            res = c.step(f"train name stop {name}", "train", args)
            c.record(f"stop {name} named", res is not None and res.get("stop") == name, res)
        mid = track[8]["position"]["x"]
        loco1 = c.build("locomotive east", "locomotive", mid + 3.5, ry, "east")
        loco2 = c.build("locomotive west", "locomotive", mid - 3.5, ry, "west")
        for loco in (loco1, loco2):
            if loco:
                c.near(loco["position"]["x"], loco["position"]["y"])
                c.step("fuel locomotive", "transfer", {"position": loco["position"], "item": "coal", "count": 20,
                                                       "direction": "to_entity"})
        if loco1 and len(stops) == 2:
            c.near(loco1["position"]["x"], loco1["position"]["y"], force=True)
            res = c.step("train schedule two stops, automatic", "train", {
                "position": loco1["position"], "automatic": True,
                "schedule": [{"station": "LC-East", "wait": [{"type": "time", "ticks": 300}]},
                             {"station": "LC-West", "wait": [{"type": "time", "ticks": 300}]}]})
            got = c.lua(f"""
              local s = game.surfaces.nauvis
              local l = s.find_entities_filtered{{name="locomotive", position={{{loco1['position']['x']}, {loco1['position']['y']}}}, radius=2}}[1]
              local t = l and l.train
              local sch = t and t.schedule
              local names = {{}}
              for i, r in ipairs(sch and sch.records or {{}}) do names[i] = r.station end
              local stop = s.find_entities_filtered{{name="train-stop", position={{{stops['LC-East']['position']['x']}, {stops['LC-East']['position']['y']}}}, radius=0.5}}[1]
              rcon.print(helpers.table_to_json{{records = names, manual = t and t.manual_mode, carriages = t and #t.carriages,
                stop_name = stop and stop.backer_name, stop_limit = stop and stop.trains_limit}})
            """)
            c.record("game: schedule LC-East, LC-West", res is not None and got.get("records") == ["LC-East", "LC-West"], got)
            c.record("game: train automatic", got.get("manual") is False, got)
            c.record("game: stop LC-East named, limit 1", got.get("stop_name") == "LC-East" and got.get("stop_limit") == 1, got)
            c.record("game: two locomotives coupled (informational)", True, f"carriages {got.get('carriages')}")
            time.sleep(5)
            st = c.lua(f"""
              local l = game.surfaces.nauvis.find_entities_filtered{{name="locomotive", position={{{loco1['position']['x']}, {loco1['position']['y']}}}, radius=4}}[1]
              local t = l and l.train
              local names = {{}}
              for k, v in pairs(defines.train_state) do names[v] = k end
              rcon.print(helpers.table_to_json{{state = t and names[t.state], speed = t and t.speed}})
            """)
            c.record("train state after 5 s (informational)", True, st)
    # 4. A curved rail beside the track.
    if track:
        cur = c.build("curved rail (curved-rail-a)", "rail", track[4]["position"]["x"], ry + 6, "north", entity="curved-rail-a")
        c.record("rails: curved-rail-a placed", cur is not None and cur.get("name") == "curved-rail-a", cur)

    # Clean up: everything built here, then the bot.
    if a.keep:
        print(f"--keep: left the site at ({ox},{oy}) and bot {a.bot}")
    else:
        gone = c.lua(cleanup_lua(c.built, ox, oy, ["iron-chest", "inserter", "constant-combinator", "small-lamp",
                                                  "straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail",
                                                  "train-stop", "locomotive"]))
        c.record("cleanup: built entities removed", "removed" in gone, gone)
        c.record("cleanup: bot removed", True, c.lua(f'rcon.print(remote.call("agent_harness","bot_remove","{a.bot}"))'))
    fails = [s for s, ok in c.results if not ok]
    print(f"\n{len(c.results) - len(fails)} ok, {len(fails)} failed" + (": " + "; ".join(fails) if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
