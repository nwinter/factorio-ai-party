#!/usr/bin/env python3
"""Read-only game reads for the analyst. Never sends a gameplay action and never moves an agent's hint cursors.

  python3 tools/analyst/game.py --world live snapshot          # research, production rates, machines, enemies
  python3 tools/analyst/game.py --world live machines          # machines by recipe and status (starved, output full)
  python3 tools/analyst/game.py --world live chat [--limit 20] # team chat, read with peek
  python3 tools/analyst/game.py --world live board | status | power
  python3 tools/analyst/game.py --replay runs/shake2 --at 40 snapshot   # a past run's score log at game minute 40

Two kinds of reads, both read-only:
- Harness reads go through `remote.call("agent_harness", "dispatch", ...)`, the call `bin/fh` makes, restricted to the
  harness's read actions and always with `"peek": true`, so the reading identity's chat, board and team hints are left
  for the agent. A failed non-read call would stop a player's action, so nothing else is ever dispatched.
- Statistics reads are plain Lua over RCON that only reads (production and kill statistics, entity counts and status,
  research, evolution, pollution), at the same privilege as `tools/pog.py score` and the stream service's polls.
"""
import argparse, json, os, re, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.dont_write_bytecode = True
import pog  # noqa: E402

READ_ACTIONS = {"status", "chat", "power", "describe", "board", "board_events", "profiles", "labs"}
PACKS = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
         "production-science-pack", "utility-science-pack", "space-science-pack", "metallurgic-science-pack",
         "electromagnetic-science-pack", "agricultural-science-pack", "cryogenic-science-pack", "promethium-science-pack"]

SNAPSHOT_LUA = r"""
local f = game.forces.player
local s = game.surfaces[SURFACE] or game.surfaces.nauvis
local P = defines.flow_precision_index
local function flows(st, inputs)
  local out = {}
  for name, total in pairs(inputs) do
    local m1 = st.get_flow_count{name=name, category="input", precision_index=P.one_minute, count=true}
    local m10 = st.get_flow_count{name=name, category="input", precision_index=P.ten_minutes, count=true}
    local h1 = st.get_flow_count{name=name, category="input", precision_index=P.one_hour, count=true}
    local c10 = st.get_flow_count{name=name, category="output", precision_index=P.ten_minutes, count=true}
    out[name] = {total=total, m1=m1, m10=m10, h1=h1, used10=c10}
  end
  return out
end
local ist = f.get_item_production_statistics(s)
local fst = f.get_fluid_production_statistics(s)
local cur = f.current_research
local queue = {}
for i, t in ipairs(f.research_queue or {}) do queue[#queue+1] = t.name end
local done = {}
for name, t in pairs(f.technologies) do
  if t.researched and t.enabled and not t.prototype.hidden then done[#done+1] = name end
end
table.sort(done)
local partial = {}
for name, t in pairs(f.technologies) do
  local ok, p = pcall(function() return t.saved_progress end)
  if not ok then p = nil end
  if p and p > 0 and not t.researched then partial[name] = p end
end
local counts = {}
for _, e in pairs(s.find_entities_filtered{force=f, type={"assembling-machine","furnace","mining-drill","lab","boiler",
  "generator","solar-panel","accumulator","reactor","offshore-pump","rocket-silo","roboport","ammo-turret",
  "electric-turret","fluid-turret","artillery-turret","radar","inserter","transport-belt","wall","electric-pole",
  "construction-robot","logistic-robot","pumpjack","beacon","car","locomotive","cargo-wagon"}}) do
  counts[e.name] = (counts[e.name] or 0) + 1
end
local kst = f.get_kill_count_statistics(s)
local killed, lost = {}, {}
for n, c in pairs(kst.input_counts) do killed[n] = c end
for n, c in pairs(kst.output_counts) do lost[n] = c end
local lost10 = {}
for n in pairs(kst.output_counts) do
  local c = kst.get_flow_count{name=n, category="output", precision_index=P.ten_minutes, count=true}
  if c > 0 then lost10[n] = c end
end
local players = {}
for _, p in pairs(game.connected_players) do players[#players+1] = p.name end
rcon.print(helpers.table_to_json{tick=game.tick, paused=game.tick_paused, surface=s.name,
  research=cur and cur.name or nil, progress=cur and f.research_progress or nil, queue=queue, done=done,
  saved_progress=partial, items=flows(ist, ist.input_counts), fluids=flows(fst, fst.input_counts), entities=counts,
  killed=killed, lost=lost, lost10=lost10, rockets=f.rockets_launched,
  evolution=game.forces.enemy.get_evolution_factor(s), pollution=s.get_total_pollution(),
  peaceful=s.peaceful_mode, players=players})
"""

MACHINES_LUA = r"""
local f = game.forces.player
local s = game.surfaces[SURFACE] or game.surfaces.nauvis
local names = {}
for k, v in pairs(defines.entity_status) do names[v] = k end
local out = {}
for _, e in pairs(s.find_entities_filtered{force=f, type={"assembling-machine","furnace","lab","mining-drill","rocket-silo","boiler","generator"}}) do
  local r = nil
  if e.type == "assembling-machine" or e.type == "furnace" or e.type == "rocket-silo" then
    local ok, rec = pcall(e.get_recipe)
    if ok and rec then r = rec.name
    elseif e.type == "furnace" then
      local ok2, pr = pcall(function() return e.previous_recipe end)
      if ok2 and pr then r = type(pr.name) == "string" and pr.name or pr.name.name end
    end
  elseif e.type == "mining-drill" then
    local t = e.mining_target
    r = t and t.name or nil
  end
  local key = e.name .. "|" .. (r or "-")
  local st = names[e.status or -1] or "unknown"
  out[key] = out[key] or {}
  out[key][st] = (out[key][st] or 0) + 1
end
rcon.print(helpers.table_to_json(out))
"""


def lua_string(text):
    level = 0
    while f"]{'=' * level}]" in text:
        level += 1
    return f"[{'=' * level}[{text}]{'=' * level}]"


def one_line(lua):
    return " ".join(l.strip() for l in lua.strip().splitlines() if l.strip())


def game_time(tick):
    m = int(tick // 3600)
    return f"{m // 60}h{m % 60:02d}m"


class LiveGame:
    def __init__(self, world="live", bot=None, player=None, surface="nauvis", port=None):
        self.world, self.bot, self.player, self.surface = world, bot, player, surface
        port = port or pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
        pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
        self.rc = pog.Rcon("127.0.0.1", port, pw, timeout=20)
        self._describe = None

    def lua(self, lua):
        out = self.rc.command("/silent-command " + one_line(lua.replace("SURFACE", json.dumps(self.surface))))
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            raise RuntimeError(out[:300])

    def dispatch(self, action, args=None):
        if action not in READ_ACTIONS:
            raise ValueError(f"{action} is not a read action")
        args = dict(args or {}, peek=True)
        req = {"id": "analyst-" + uuid.uuid4().hex[:10], "action": action, "args": args}
        if self.bot:
            req["bot"] = self.bot
        else:
            req["player"] = self.player or 1
        raw = self.rc.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {(reply.get('error') or {}).get('message', raw)[:200]}")
        return reply.get("result")

    def actions(self):
        """Actions the runtime knows (describe is a read on every runtime)."""
        if self._describe is None:
            try:
                d = self.dispatch("describe")
                acts = d.get("actions") if isinstance(d, dict) else None
                self._describe = set(acts if isinstance(acts, list) else (acts or {}).keys()) if acts else set()
            except Exception:
                self._describe = set()
        return self._describe

    def snapshot(self):
        return self.lua(SNAPSHOT_LUA)

    def machines(self):
        return self.lua(MACHINES_LUA)

    def chat(self, limit=20):
        r = self.dispatch("chat", {"limit": limit})
        return r.get("messages", r) if isinstance(r, dict) else r

    def board(self):
        if "board" not in self.actions():
            return {"available": False}
        return self.dispatch("board", {"limit": 40})

    def status(self):
        return self.dispatch("status")

    def power(self):
        return self.dispatch("power")


class ReplayGame:
    """A past run's scores.jsonl (cumulative production, research, entities every ~2 min) seen at one game minute."""

    def __init__(self, run_dir, at_minute=None):
        self.run_dir = run_dir
        self.rows = [json.loads(l)["score"] for l in open(os.path.join(run_dir, "scores.jsonl")) if l.strip()]
        self.at = at_minute

    def _row(self, minute):
        rows = [r for r in self.rows if r["tick"] / 3600 <= minute + 1e-6] or self.rows[:1]
        return rows[-1]

    def snapshot(self):
        minute = self.at if self.at is not None else self.rows[-1]["tick"] / 3600
        r = self._row(minute)
        prev10 = self._row(r["tick"] / 3600 - 10)
        span = max((r["tick"] - prev10["tick"]) / 3600, 1e-9)
        items = {}
        for n, total in (r.get("produced") or {}).items():
            before = (prev10.get("produced") or {}).get(n, 0)
            m10 = (total - before) * (10 / span) if span >= 1 else 0
            items[n] = {"total": total, "m10": m10, "m1": m10 / 10, "h1": None, "used10": None}
        return {"tick": r["tick"], "paused": r.get("paused"), "research": r.get("current_research"), "progress": None,
                "queue": [], "done": r.get("research_done") or [], "items": items, "fluids": {},
                "entities": r.get("entities") or {}, "rockets": r.get("rockets", 0), "replay": os.path.basename(self.run_dir.rstrip("/"))}

    def machines(self):
        return {}

    def chat(self, limit=20):
        p = os.path.join(self.run_dir, "chat-full.jsonl")
        if not os.path.exists(p):
            p = os.path.join(self.run_dir, "chat.jsonl")
        if not os.path.exists(p):
            return []
        tick = self.snapshot()["tick"]
        rows = [json.loads(l) for l in open(p) if l.strip()]
        rows = [m for m in rows if (m.get("tick") or 0) <= tick]
        return rows[-limit:]

    def board(self):
        return {"available": False}

    def status(self):
        return {}

    def power(self):
        return {}


# ---- text for the analyst --------------------------------------------------------------------------------------
def spm(snap, window="m10"):
    """Science packs made per minute, all colours summed, over the 10-minute window (or m1)."""
    per = {}
    for p in PACKS:
        it = (snap.get("items") or {}).get(p)
        if it and it.get(window):
            per[p] = it[window] / (10 if window == "m10" else 1)
    return sum(per.values()), per


def snapshot_text(snap, kb=None):
    t = snap["tick"]
    lines = [f"game time {game_time(t)} (tick {t})" + (" PAUSED" if snap.get("paused") else "")
             + (f", replay of {snap['replay']}" if snap.get("replay") else "")]
    total, per = spm(snap)
    lines.append(f"science per minute (10-min average): {total:.1f}" + (
        " = " + ", ".join(f"{p.replace('-science-pack', '')} {v:.1f}" for p, v in per.items()) if per else ""))
    if snap.get("research"):
        prog = snap.get("progress")
        lines.append(f"researching {snap['research']}" + (f" at {prog * 100:.0f}%" if prog is not None else "")
                     + (f"; queue {', '.join(snap['queue'][1:6])}" if len(snap.get("queue") or []) > 1 else ""))
    else:
        lines.append("no research running (labs idle unless a queue is set)")
    if snap.get("saved_progress"):
        lines.append("partly researched (progress kept): " + ", ".join(f"{k} {v * 100:.0f}%" for k, v in snap["saved_progress"].items()))
    done = snap.get("done") or []
    lines.append(f"{len(done)} technologies researched: {', '.join(done)}")
    items = snap.get("items") or {}
    rows = sorted(items.items(), key=lambda kv: -(kv[1].get("m10") or 0))
    prod = [f"{n} {v['m10'] / 10:.1f}/min" + (f" (used {v['used10'] / 10:.1f})" if v.get("used10") else "")
            + f" [total {v['total']}]" for n, v in rows if (v.get("m10") or 0) > 0][:30]
    lines.append("production per minute, last 10 min: " + ("; ".join(prod) or "nothing"))
    idle = [n for n, v in rows if not v.get("m10") and v.get("total", 0) > 50][:12]
    if idle:
        lines.append("made before but not in the last 10 min: " + ", ".join(idle))
    fl = [f"{n} {v['m10'] / 10:.0f}/min" for n, v in sorted((snap.get("fluids") or {}).items(), key=lambda kv: -(kv[1].get("m10") or 0)) if v.get("m10")]
    if fl:
        lines.append("fluids per minute: " + ", ".join(fl[:8]))
    ents = snap.get("entities") or {}
    lines.append("buildings: " + ", ".join(f"{n} {c}" for n, c in sorted(ents.items(), key=lambda kv: -kv[1])))
    if "evolution" in snap:
        lines.append(f"enemy evolution {snap['evolution'] * 100:.1f}%" + (" (peaceful mode)" if snap.get("peaceful") else "")
                     + f"; pollution on the map {snap.get('pollution', 0):.0f}")
    if snap.get("killed"):
        lines.append("we have killed: " + ", ".join(f"{n} {c}" for n, c in sorted(snap["killed"].items(), key=lambda kv: -kv[1])[:8]))
    if snap.get("lost"):
        lines.append("we have lost (destroyed by enemies or otherwise): " + ", ".join(f"{n} {c}" for n, c in sorted(snap["lost"].items(), key=lambda kv: -kv[1])[:8])
                     + ("; last 10 min: " + ", ".join(f"{n} {c}" for n, c in snap["lost10"].items()) if snap.get("lost10") else ""))
    if snap.get("rockets"):
        lines.append(f"rockets launched: {snap['rockets']}")
    if snap.get("players"):
        lines.append("connected players: " + ", ".join(snap["players"]))
    return "\n".join(lines)


def machines_text(m):
    if not m:
        return "no machine status available"
    out = []
    for key, sts in sorted(m.items(), key=lambda kv: -sum(kv[1].values())):
        name, recipe = key.split("|")
        n = sum(sts.values())
        working = sts.get("working", 0)
        rest = ", ".join(f"{k} {v}" for k, v in sorted(sts.items(), key=lambda kv: -kv[1]) if k != "working")
        out.append(f"{n} {name}" + (f" on {recipe}" if recipe != "-" else "") + f": {working} working" + (f", {rest}" if rest else ""))
    return "\n".join(out)


def chat_text(msgs):
    out = []
    for m in msgs or []:
        who = m.get("from") or m.get("name") or m.get("player") or "?"
        t = m.get("tick")
        out.append(f"[{game_time(t) if t else '?'}] {who}: {m.get('text') or m.get('message')}")
    return "\n".join(out) or "no chat"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--bot", default=os.environ.get("ANALYST_BOT"))
    ap.add_argument("--player", type=int)
    ap.add_argument("--surface", default="nauvis")
    ap.add_argument("--replay", help="run directory with scores.jsonl instead of a live world")
    ap.add_argument("--at", type=float, help="game minute for --replay")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("cmd", choices=["snapshot", "machines", "chat", "board", "status", "power"])
    a = ap.parse_args()
    g = ReplayGame(a.replay, a.at) if a.replay else LiveGame(a.world, a.bot, a.player, a.surface)
    if a.cmd == "snapshot":
        s = g.snapshot()
        print(json.dumps(s) if a.json else snapshot_text(s))
    elif a.cmd == "machines":
        m = g.machines()
        print(json.dumps(m) if a.json else machines_text(m))
    elif a.cmd == "chat":
        c = g.chat(a.limit)
        print(json.dumps(c) if a.json else chat_text(c))
    else:
        print(json.dumps(getattr(g, a.cmd)(), indent=1)[:6000])


if __name__ == "__main__":
    main()
