#!/usr/bin/env python3
"""Operator controls for a pog world over RCON (through the SSH tunnel).

Agents never get this tool: it runs privileged Lua. Usage:
  tools/pog.py [--world live] rcon '/time'
  tools/pog.py pause | resume | save | quit
  tools/pog.py score            # JSON snapshot: tick, research, production totals, entity counts
  tools/pog.py peaceful         # Space Age: give every planet surface Nauvis's peaceful/no-enemies flags
"""
import argparse, json, os, socket, struct, sys

PORTS = {"live": 27015, "a": 27021, "b": 27022, "c": 27023, "n": 27025, "sa": 27030}


class Rcon:
    def __init__(self, host, port, password, timeout=15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.next_id = 1
        if self._request(3, password)[0] == -1:
            raise SystemExit("rcon auth failed")

    def _send(self, kind, body):
        rid = self.next_id
        self.next_id += 1
        data = body.encode()
        self.sock.sendall(struct.pack("<iii", len(data) + 10, rid, kind) + data + b"\0\0")
        return rid

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("rcon closed")
            buf += chunk
        return buf

    def _read(self):
        size = struct.unpack("<i", self._recv_exact(4))[0]
        payload = self._recv_exact(size)
        rid, kind = struct.unpack("<ii", payload[:8])
        return rid, kind, payload[8:-2].decode("utf-8", "replace")

    def _request(self, kind, body):
        rid = self._send(kind, body)
        while True:
            got, k, text = self._read()
            if got in (rid, -1):
                return got, text

    def command(self, cmd):
        return self._request(2, cmd)[1]


# Totals cover every surface (Space Age: planets and platforms; the base game has only nauvis). Names missing from
# the loaded mods are skipped. Space Age fields: consumed (science packs used by labs, all surfaces), infinite
# (infinite levels completed per technology), planets (surfaces with our entities), platforms.
# SCORE_LUA is sent as one line, so it must hold no "--" comments (one cut the score in shake8).
# A platform row's hub is false while its record waits for a starter pack (the New platform button).
SCORE_LUA = r"""
local f = game.forces.player
local all = {}
for _, s in pairs(game.surfaces) do all[#all+1] = s end
local packs = {"automation-science-pack","logistic-science-pack","military-science-pack","chemical-science-pack",
  "production-science-pack","utility-science-pack","space-science-pack","metallurgic-science-pack",
  "electromagnetic-science-pack","agricultural-science-pack","cryogenic-science-pack","promethium-science-pack"}
local items, consumed = {}, {}
local names = {"iron-plate","copper-plate","steel-plate","stone-brick","iron-gear-wheel","electronic-circuit",
  "advanced-circuit","processing-unit","plastic-bar","sulfur","rocket-part","low-density-structure","rocket-fuel",
  "tungsten-plate","holmium-plate","carbon-fiber","lithium-plate","quantum-processor"}
for _, n in ipairs(packs) do names[#names+1] = n end
for _, n in ipairs(names) do
  if prototypes.item[n] then
    local made, used = 0, 0
    for _, s in ipairs(all) do
      local stats = f.get_item_production_statistics(s)
      made = made + stats.get_input_count(n)
      used = used + stats.get_output_count(n)
    end
    if made > 0 then items[n] = made end
    if used > 0 and string.find(n, "science", 1, true) then consumed[n] = used end
  end
end
local done, infinite = {}, {}
for name, t in pairs(f.technologies) do
  if t.researched and t.enabled and t.research_unit_count > 0 and not t.prototype.hidden then done[#done+1] = name end
  if t.prototype.max_level == 4294967295 and t.level > t.prototype.level then infinite[name] = t.level - t.prototype.level end
end
table.sort(done)
local counts = {}
for _, n in ipairs({"burner-mining-drill","electric-mining-drill","stone-furnace","steel-furnace","electric-furnace",
  "assembling-machine-1","assembling-machine-2","assembling-machine-3","lab","steam-engine","solar-panel",
  "transport-belt","inserter","oil-refinery","chemical-plant","rocket-silo","biolab","big-mining-drill","foundry",
  "electromagnetic-plant","biochamber","cryogenic-plant","recycler","cargo-landing-pad","space-platform-hub",
  "asteroid-collector","crusher","thruster","railgun-turret"}) do
  if prototypes.entity[n] then
    local c = 0
    for _, s in ipairs(all) do c = c + s.count_entities_filtered{force = f, name = n} end
    if c > 0 then counts[n] = c end
  end
end
local planets, platforms = {}, {}
for _, s in ipairs(all) do
  if s.planet and s.count_entities_filtered{force = f, limit = 1} > 0 then planets[#planets+1] = s.name end
end
for _, p in pairs(f.platforms or {}) do
  if p.valid then platforms[#platforms+1] = {name = p.name, at = p.space_location and p.space_location.name or "in transit",
    hub = (p.hub ~= nil and p.hub.valid) or false} end
end
local cur = f.current_research
rcon.print(helpers.table_to_json{tick = game.tick, ticks_played = game.ticks_played, paused = game.tick_paused,
  rockets = f.rockets_launched, research_done = done, current_research = cur and cur.name or nil,
  produced = items, consumed = next(consumed) and consumed or nil, infinite = next(infinite) and infinite or nil, entities = counts,
  planets = #planets > 0 and planets or nil, platforms = #platforms > 0 and platforms or nil})
"""


# Space Age: each planet surface has its own peaceful/no-enemies flags and is created on first arrival. Copy Nauvis's
# to every planet surface (a world setting, like the map seed). Run after a new planet appears (score lists planets).
PEACEFUL_LUA = r"""
local n = game.surfaces.nauvis
local out = {}
for _, s in pairs(game.surfaces) do
  if s.planet and s ~= n then
    local changed = s.peaceful_mode ~= n.peaceful_mode or s.no_enemies_mode ~= n.no_enemies_mode
    s.peaceful_mode = n.peaceful_mode
    s.no_enemies_mode = n.no_enemies_mode
    out[#out+1] = s.name .. (changed and " set" or " unchanged")
  end
end
rcon.print(helpers.table_to_json{peaceful = n.peaceful_mode, no_enemies = n.no_enemies_mode, planets = out})
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--port", type=int)
    ap.add_argument("cmd", choices=["rcon", "pause", "resume", "save", "quit", "score", "peaceful"])
    ap.add_argument("arg", nargs="?")
    a = ap.parse_args()
    port = a.port or PORTS.get(a.world) or int(os.environ["POG_RCON_PORT"])
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    r = Rcon("127.0.0.1", port, pw)
    if a.cmd == "rcon":
        out = r.command(a.arg)
    elif a.cmd == "pause":
        out = r.command("/silent-command game.tick_paused = true rcon.print('paused at ' .. game.tick)")
    elif a.cmd == "resume":
        out = r.command("/silent-command game.tick_paused = false rcon.print('resumed at ' .. game.tick)")
    elif a.cmd == "save":
        out = r.command("/server-save") or "saved"
    elif a.cmd == "quit":
        r.command("/server-save")
        out = r.command("/quit") or "quit sent"
    elif a.cmd == "peaceful":
        out = r.command("/silent-command " + " ".join(l.strip() for l in PEACEFUL_LUA.strip().splitlines()))
    else:
        out = r.command("/silent-command " + " ".join(l.strip() for l in SCORE_LUA.strip().splitlines()))
    sys.stdout.write(out if out.endswith("\n") else out + "\n")


if __name__ == "__main__":
    main()
