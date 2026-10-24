#!/usr/bin/env python3
"""Space Age smoke test: probe a fresh Space Age world and play a scripted early game with one bot.

World `sa` (docs/SPACEAGE.md): game port 34210, RCON 27030. Needs the RCON tunnel and a deployed runtime:
  tools/winps.sh tools/win/new-instance.ps1 -Name sa -Save sa1 -SpaceAge -Peaceful
  scp ~/.config/pog/rcon-sa.pw pogwin:D:/pog/inst/sa/rcon.pw
  tools/winps.sh tools/win/start-server.ps1 -Name sa -Save sa1 -GamePort 34210 -RconPort 27030
  ssh -N -L 27030:127.0.0.1:27030 pogwin &
  POG_WORLD=sa bin/fh doctor; POG_WORLD=sa bin/fh deploy
  tools/sa_smoke.py [--bot sa1] [--out runs/sa-smoke]

Every step is logged as ok/FAIL with the reply, and later steps still run, so one pass lists everything that breaks.
The world needs a client connected: a headless server with none charts nothing, and nearest reads charted chunks, so
the early game's steps would find nothing; each one skipped is a failed step.
The probe uses operator Lua (like tools/pog.py score); the early game uses only harness actions through a bot.
"""
import argparse, json, os, subprocess, sys, time

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pog  # noqa: E402

PROBE_LUA = r"""
local out = {mods = script.active_mods, planets = {}, surfaces = {}, quality = {}, crash_site = {}, created = nil,
  techs = {}, recipes = {}, items = {}}
for name in pairs(prototypes.space_location or {}) do out.planets[#out.planets+1] = name end
for _, s in pairs(game.surfaces) do out.surfaces[#out.surfaces+1] = s.name end
for name in pairs(prototypes.quality or {}) do out.quality[#out.quality+1] = name end
local s = game.surfaces.nauvis
for _, e in pairs(s.find_entities_filtered{position = {0, 0}, radius = 64}) do
  if string.find(e.name, "crash", 1, true) then out.crash_site[e.name] = (out.crash_site[e.name] or 0) + 1 end
end
if remote.interfaces.freeplay and remote.interfaces.freeplay.get_created_items then out.created = remote.call("freeplay", "get_created_items") end
local f = game.forces.player
for _, n in ipairs({"automation-science-pack", "electronics", "steam-power", "automation", "logistic-science-pack",
  "oil-processing", "rocket-silo", "space-platform", "space-science-pack", "planet-discovery-vulcanus",
  "research-productivity", "promethium-science-pack"}) do
  local t = f.technologies[n]
  if t then
    local trig = t.prototype.research_trigger
    out.techs[n] = {enabled = t.enabled, researched = t.researched, units = t.research_unit_count,
      trigger = trig and trig.type or nil, max_level = t.prototype.max_level}
  else out.techs[n] = "missing" end
end
for _, n in ipairs({"stone-furnace", "burner-mining-drill", "iron-gear-wheel", "electronic-circuit", "lab",
  "automation-science-pack", "rocket-part", "space-platform-starter-pack", "big-mining-drill", "foundry"}) do
  local r = f.recipes[n]
  out.recipes[n] = r and {enabled = r.enabled, ingredients = #r.ingredients} or "missing"
end
for _, n in ipairs({"wood", "coal", "iron-ore", "stone", "biter-egg", "space-platform-foundation", "calcite"}) do
  local p = prototypes.item[n]
  out.items[n] = p and {spoils = p.get_spoil_ticks and p.get_spoil_ticks() or nil} or "missing"
end
out.peaceful = s.peaceful_mode
out.spawn = f.get_spawn_position(s)
rcon.print(helpers.table_to_json(out))
"""


# (d24 batch158, harness review bug 8: on a fresh headless world sa_smoke passed with its early game skipped: no player
# charts anything, and nearest reads charted chunks only, so it found no stone, coal or iron) the force charts round
# spawn first, and the smoke waits until the chunks round it are charted. Measured on a fresh 2.0.77 world in a
# headless server with no client: force.chart and chart_all left 0 of the 25 chunks charted, so there the chart step
# fails and so does every early-game step it skips (connect a client, as for the live checks).
CHART_R = 128   # tiles round spawn charted
CHART_LUA = r"""
local f, s = game.forces.player, game.surfaces.nauvis
local sp = f.get_spawn_position(s)
f.chart(s, {{sp.x - CHART_R, sp.y - CHART_R}, {sp.x + CHART_R, sp.y + CHART_R}})
rcon.print(helpers.table_to_json{spawn = sp, tick = game.tick})
""".replace("CHART_R", str(CHART_R))
CHARTED_LUA = r"""
local f, s = game.forces.player, game.surfaces.nauvis
local sp = f.get_spawn_position(s)
local n, total = 0, 0
for cx = math.floor(sp.x / 32) - 2, math.floor(sp.x / 32) + 2 do
  for cy = math.floor(sp.y / 32) - 2, math.floor(sp.y / 32) + 2 do
    total = total + 1
    if f.is_chunk_charted(s, {cx, cy}) then n = n + 1 end
  end
end
rcon.print(helpers.table_to_json{charted = n, total = total, tick = game.tick})
"""


class Smoke:
    def __init__(self, world, bot, out):
        self.world, self.bot, self.out = world, bot, out
        os.makedirs(out, exist_ok=True)
        self.log = open(os.path.join(out, "smoke.jsonl"), "a")
        self.fails = 0
        self.rcon = pog.Rcon("127.0.0.1", pog.PORTS[world],
                             open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip())

    def record(self, step, ok, reply):
        self.fails += 0 if ok else 1
        self.log.write(json.dumps({"t": time.strftime("%H:%M:%S"), "step": step, "ok": ok, "reply": reply}) + "\n")
        self.log.flush()
        text = reply if isinstance(reply, str) else json.dumps(reply)
        print(f"{'ok  ' if ok else 'FAIL'} {step}: {text[:400]}")

    def lua(self, step, code):
        out = self.rcon.command("/silent-command " + " ".join(l.strip() for l in code.strip().splitlines()))
        try:
            value = json.loads(out)
        except ValueError:
            self.record(step, False, out)
            return None
        self.record(step, True, value)
        return value

    def fh(self, step, action, args=None, wait=False, timeout_ms=None):
        cmd = [os.path.join(ROOT, "bin", "fh"), "--format", "json", "--bot", self.bot, "call", action]
        if args is not None:
            cmd += ["--args", json.dumps(args)]
        if wait:
            cmd.append("--wait")
        if timeout_ms:
            cmd += ["--wait-timeout", str(timeout_ms)]
        p = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, POG_WORLD=self.world))
        try:
            value = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else None
        except ValueError:
            value = None
        self.record(step, p.returncode == 0, value if value is not None else (p.stdout + p.stderr).strip())
        return value if p.returncode == 0 else None


def find(value, key):
    """First value under `key` anywhere in a reply."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for v in value.values():
            got = find(v, key)
            if got is not None:
                return got
    elif isinstance(value, list):
        for v in value:
            got = find(v, key)
            if got is not None:
                return got
    return None


def nearest(s, name):
    rows = find(s.fh(f"nearest {name}", "nearest", {"name": name, "radius": 64, "limit": 1}), "entities")
    return rows[0]["position"] if rows else None


def skipped(s, step, name):
    """A step of the early game that could not run is a failed step (it was passed over in silence before)."""
    s.record(f"{step}: skipped", False, f"no {name} within 64 tiles in charted chunks: nearest found none")


def chart(s, sleep=time.sleep, tries=30):
    """Chart round spawn and wait until the 25 chunks round it are charted (a step: ok or FAIL)."""
    s.lua("chart round spawn", CHART_LUA)
    got = None
    for _ in range(tries):
        out = s.rcon.command("/silent-command " + " ".join(l.strip() for l in CHARTED_LUA.strip().splitlines()))
        try:
            got = json.loads(out)
        except ValueError:
            got = {"error": out}
        if got.get("total") and got.get("charted") == got.get("total"):
            break
        sleep(2)
    done = bool(got and got.get("total") and got.get("charted") == got.get("total"))
    if not done and isinstance(got, dict):
        got = dict(got, note="a headless server with no client connected charts nothing (2.0.77): connect a client")
    s.record("chunks round spawn charted", done, got)


def gather(s, name, ticks):
    """Walk to the nearest `name` and hand-mine it for `ticks`."""
    pos = nearest(s, name)
    if not pos:
        skipped(s, f"gather {name}", name)
        return False
    s.fh(f"move_to {name}", "move_to", {"position": pos, "tolerance": 1.5}, wait=True)
    return s.fh(f"mine {name}", "mine", {"position": pos, "ticks": ticks}, wait=True) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="sa")
    ap.add_argument("--bot", default="sa1")
    ap.add_argument("--out", default=os.path.join(ROOT, "runs", "sa-smoke"))
    a = ap.parse_args()
    if a.world in ("a", "b", "c", "n", "live"):
        sys.exit("refusing: the smoke test creates a bot and plays; use its own world (sa)")
    s = Smoke(a.world, a.bot, a.out)

    # 1. What the world is: mods, planets, crash site, starting items, tech tree, spoilage, quality.
    probe = s.lua("probe", PROBE_LUA)
    if probe:
        s.record("space-age mod active", "space-age" in (probe.get("mods") or {}), probe.get("mods"))
        s.record("peaceful", probe.get("peaceful") is True, probe.get("peaceful"))
    s.lua("score", pog.SCORE_LUA)

    # 2. A bot and the harness's own reads.
    s.lua("bot_create", f'rcon.print(remote.call("agent_harness","bot_create","{a.bot}"))')
    chart(s)
    for action in ("status", "describe", "status", "observe", "map", "craftable", "technologies", "platforms"):
        s.fh(action, action, {"available": True} if action == "technologies" else None)

    # 3. Scripted early game: mine, craft, build, fuel, smelt, research.
    gather(s, "stone", 600)
    gather(s, "coal", 600)
    s.fh("craft stone-furnace", "craft", {"recipe": "stone-furnace", "count": 2})
    iron = nearest(s, "iron-ore")
    if iron:
        s.fh("move_to iron", "move_to", {"position": iron, "tolerance": 2}, wait=True)
        s.fh("build burner-mining-drill", "build", {"item": "burner-mining-drill", "position": iron, "direction": "east"})
        s.fh("build stone-furnace", "build", {"item": "stone-furnace", "position": {"x": iron["x"] + 2, "y": iron["y"]}})
        s.fh("refuel", "refuel", {"radius": 8}, wait=True)
        s.fh("mine iron-ore", "mine", {"position": iron, "ticks": 600}, wait=True)
        s.fh("wait for plates", "wait_until", {"until": "item_count", "item": "iron-plate", "at_least": 1,
                                               "timeout": 3600}, wait=True)
        s.fh("collect", "collect", {"radius": 8}, wait=True)
    else:
        skipped(s, "drill, furnace and smelting on iron", "iron-ore")
    s.fh("craft iron-gear-wheel", "craft", {"recipe": "iron-gear-wheel", "count": 2})
    s.fh("research report", "research")
    s.fh("research automation", "research", {"technology": "automation"})
    s.fh("research queue", "research", {"research_queue": ["automation", "logistics", "electronics"]})
    s.fh("final status", "status")
    s.lua("final score", pog.SCORE_LUA)
    print(f"{s.fails} failed steps; log: {os.path.join(a.out, 'smoke.jsonl')}")
    sys.exit(1 if s.fails else 0)


if __name__ == "__main__":
    main()
