#!/usr/bin/env python3
"""Operator controls for a pog world over RCON (through the SSH tunnel).

Agents never get this tool: it runs privileged Lua. Usage:
  tools/pog.py [--world live] rcon '/time'
  tools/pog.py pause | resume | save | quit
  tools/pog.py score            # JSON snapshot: tick, research, production totals, entity counts
"""
import argparse, json, os, socket, struct, sys

PORTS = {"live": 27015, "a": 27021, "b": 27022}


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


SCORE_LUA = r"""
local f = game.forces.player
local s = game.surfaces.nauvis
local stats = f.get_item_production_statistics(s)
local items = {}
for _, n in ipairs({"iron-plate","copper-plate","steel-plate","stone-brick","iron-gear-wheel","electronic-circuit",
  "advanced-circuit","processing-unit","plastic-bar","sulfur","automation-science-pack","logistic-science-pack",
  "military-science-pack","chemical-science-pack","production-science-pack","utility-science-pack","rocket-part",
  "low-density-structure","rocket-fuel"}) do
  local made = stats.get_input_count(n)
  if made > 0 then items[n] = made end
end
local done = {}
for name, t in pairs(f.technologies) do if t.researched and t.enabled and t.research_unit_count > 0 and not t.prototype.hidden then done[#done+1] = name end end
table.sort(done)
local counts = {}
for _, n in ipairs({"burner-mining-drill","electric-mining-drill","stone-furnace","steel-furnace","electric-furnace",
  "assembling-machine-1","assembling-machine-2","assembling-machine-3","lab","steam-engine","solar-panel",
  "transport-belt","inserter","oil-refinery","chemical-plant","rocket-silo"}) do
  local c = s.count_entities_filtered{force = f, name = n}
  if c > 0 then counts[n] = c end
end
local cur = f.current_research
rcon.print(helpers.table_to_json{tick = game.tick, ticks_played = game.ticks_played, paused = game.tick_paused,
  rockets = f.rockets_launched, research_done = done, current_research = cur and cur.name or nil,
  produced = items, entities = counts})
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--port", type=int)
    ap.add_argument("cmd", choices=["rcon", "pause", "resume", "save", "quit", "score"])
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
    else:
        out = r.command("/silent-command " + " ".join(l.strip() for l in SCORE_LUA.strip().splitlines()))
    sys.stdout.write(out if out.endswith("\n") else out + "\n")


if __name__ == "__main__":
    main()
