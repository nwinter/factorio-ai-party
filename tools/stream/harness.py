"""Read-only access to a pog world for the stream service.

Talks RCON directly (one persistent connection) and sends the same
`remote.call("agent_harness", "dispatch", json)` that `bin/fh` sends, so a poll
costs one round trip instead of a node process. Only whitelisted read actions
can be dispatched: a failed non-read call stops that player's current action.
"""
import json, os, sys, threading, uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.dont_write_bytecode = True  # tools/__pycache__ is tracked in git; do not rewrite it
import pog  # noqa: E402  (tools/pog.py: Rcon client, ports, SCORE_LUA)

# Never add a gameplay action here. `profiles` is read-only per docs/BOTS-API.md, but a runtime that does not
# know it yet treats it as a failed mutation and stops player 1, so callers gate it on `has_bots_runtime()`.
# `board` and `board_events` (docs/BOARD-API.md) are only sent once `describe` (read-only) lists them.
READ_ACTIONS = {"status", "profiles", "chat", "power", "cameras", "describe", "board", "board_events"}
# Operator reads (eng/board audience.lua): every agent's `confess` lines, for viewers only. Gated on `describe`.
OPERATOR_READS = {"confessions"}

# Extra operator reads for the overlay (same privilege level as `pog.py score`): research progress, the costliest
# finished technologies (to seed "recent milestones" on start), machines starved of power, and how dark it is
# (LuaSurface.darkness, 0 at noon; drives the night lift on the camera captures, nightlift.py).
STREAM_LUA = r"""
local f = game.forces.player
local cur = f.current_research
local done = {}
for name, t in pairs(f.technologies) do
  if t.researched and t.enabled and t.research_unit_count > 0 and not t.prototype.hidden then
    done[#done+1] = {name = name, cost = t.research_unit_count * #t.research_unit_ingredients}
  end
end
table.sort(done, function(a, b) return a.cost > b.cost end)
local top = {}
for i = 1, math.min(4, #done) do top[i] = done[i].name end
local machines, starved = 0, 0
for _, s in pairs(game.surfaces) do
  for _, e in pairs(s.find_entities_filtered{force = f, type = {"assembling-machine", "lab", "mining-drill", "furnace", "inserter"}}) do
    if e.prototype.electric_energy_source_prototype then
      machines = machines + 1
      local st = e.status
      if st == defines.entity_status.low_power or st == defines.entity_status.no_power then starved = starved + 1 end
    end
  end
end
rcon.print(helpers.table_to_json{tick = game.tick, paused = game.tick_paused, research = cur and cur.name or nil,
  progress = cur and f.research_progress or nil, top_done = top, electric_machines = machines, starved = starved,
  darkness = game.surfaces.nauvis.darkness, daytime = game.surfaces.nauvis.daytime})
"""

# Production history for sparklines: item counts in the last hour, 2-minute buckets (one_hour precision has
# 300 samples of 12 s; sample 1 is the newest). Summed over every surface (Space Age planets and platforms).
FLOW_LUA = r"""
local all = {}
for _, s in pairs(game.surfaces) do all[#all+1] = game.forces.player.get_item_production_statistics(s) end
local out = {}
for _, n in ipairs(ITEMS) do
  local made = 0
  if prototypes.item[n] then for _, stats in ipairs(all) do made = made + stats.get_input_count(n) end end
  if made > 0 then
  local series = {}
  for b = 30, 1, -1 do
    local c = 0
    for _, stats in ipairs(all) do
      for k = (b - 1) * 10 + 1, b * 10 do
        c = c + stats.get_flow_count{name = n, category = "input", precision_index = defines.flow_precision_index.one_hour, sample_index = k, count = true}
      end
    end
    series[#series+1] = c
  end
  out[n] = series
  end
end
rcon.print(helpers.table_to_json(out))
"""

CAMERA_LUA = r"""
local i = remote.interfaces.agent_harness
if not (i and i.camera) then rcon.print('{"ok":false,"stub":true}') return end
local r = remote.call("agent_harness", "camera", BODY)
rcon.print(type(r) == "string" and r or helpers.table_to_json({ok = true, result = r}))
"""

PROBE_LUA = r"""
local i = remote.interfaces.agent_harness
rcon.print(helpers.table_to_json{harness = i ~= nil, camera = (i and i.camera) ~= nil, cameras = (i and i.cameras) ~= nil})
"""


def lua_string(text):
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[{text}]{eq}]"


def one_line(lua):
    return " ".join(l.strip() for l in lua.strip().splitlines() if l.strip())


class Harness:
    def __init__(self, world):
        self.world = world
        self.port = pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
        self.password = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.lock = threading.Lock()
        self.rcon = None

    def command(self, cmd):
        with self.lock:
            for attempt in (0, 1):
                try:
                    if self.rcon is None:
                        self.rcon = pog.Rcon("127.0.0.1", self.port, self.password, timeout=10)
                    return self.rcon.command(cmd)
                except (OSError, ConnectionError):
                    self.rcon = None
                    if attempt:
                        raise

    def lua(self, lua):
        out = self.command("/silent-command " + one_line(lua))
        return json.loads(out)

    def dispatch(self, action, args=None, player=None, bot=None):
        if action not in READ_ACTIONS:
            raise ValueError(f"{action} is not a read action; the stream service never sends gameplay actions")
        if action == "chat" and not (args or {}).get("peek"):
            raise ValueError("chat must be read with peek:true")
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}}
        if bot:
            req["bot"] = bot
        else:
            req["player"] = player or 1
        raw = self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {}), reply.get("tick")

    def operator_read(self, action, args=None):
        """Operator reads (`operator: true`, no player): a failure stops nobody on a runtime that knows them, but an
        older runtime treats the request as player 1's unknown action, so callers gate on `describe` first."""
        if action not in OPERATOR_READS:
            raise ValueError(f"{action} is not an operator read")
        req = {"id": "stream-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "operator": True}
        raw = self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {}), reply.get("tick")

    def score(self):
        return self.lua(pog.SCORE_LUA)

    def extras(self):
        return self.lua(STREAM_LUA)

    def flows(self, items):
        lua = FLOW_LUA.replace("ITEMS", "{" + ",".join(json.dumps(i) for i in items) + "}")
        return self.lua(lua)

    def probe(self):
        return self.lua(PROBE_LUA)

    def camera(self, body):
        return json.loads(self.command("/silent-command " + one_line(CAMERA_LUA.replace("BODY", lua_string(json.dumps(body))))))
