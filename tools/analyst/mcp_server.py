#!/usr/bin/env python3
"""Stdio MCP server with the analyst's read-only tools: Factorio knowledge, game reads, run history, notes.

Started by tools/stream/analyst.py for `claude -p --strict-mcp-config --mcp-config ...`. Configuration comes from
the environment: ANALYST_WORLD (default live) and ANALYST_BOT / ANALYST_PLAYER (the identity harness reads use,
always with peek), or ANALYST_REPLAY + ANALYST_AT (a past run's score log); ANALYST_RUN_DIR (agents' notes.md);
POG_KB (knowledge base version). Every tool only reads.
"""
import json, os, sys, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import game as G  # noqa: E402
import history as H  # noqa: E402
from kb import KB  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
NOTES = os.path.join(HERE, "notes")
_kb, _game, _series = None, None, None


def kb():
    global _kb
    if _kb is None:
        _kb = KB()
    return _kb


def game():
    global _game
    if _game is None:
        if os.environ.get("ANALYST_REPLAY"):
            at = os.environ.get("ANALYST_AT")
            _game = G.ReplayGame(os.environ["ANALYST_REPLAY"], float(at) if at else None)
        else:
            p = os.environ.get("ANALYST_PLAYER")
            _game = G.LiveGame(os.environ.get("ANALYST_WORLD", "live"), os.environ.get("ANALYST_BOT") or None,
                               int(p) if p else None, os.environ.get("ANALYST_SURFACE", "all"))
    return _game


def series():
    global _series
    if _series is None:
        _series = H.load_runs(exclude=os.environ.get("ANALYST_REPLAY"))
    return _series


def current_rates():
    snap = game().snapshot()
    return {n: (v.get("m10") or 0) / 10 for n, v in (snap.get("items") or {}).items()}, snap


def agent_notes(agent=None):
    d = os.environ.get("ANALYST_RUN_DIR")
    if not d or not os.path.isdir(d):
        return "no run directory configured (ANALYST_RUN_DIR)"
    names = sorted(n for n in os.listdir(d) if os.path.exists(os.path.join(d, n, "notes.md")))
    if not agent:
        return "agents with notes.md: " + ", ".join(names)
    p = os.path.join(d, agent, "notes.md")
    if not os.path.exists(p):
        return f"no notes for {agent}; agents: {', '.join(names)}"
    text = open(p).read()
    return text[-6000:] if len(text) > 6000 else text


def S(desc, **props):
    req = [k for k, v in props.items() if not v.pop("optional", False)]
    return {"description": desc, "schema": {"type": "object", "properties": props, "required": req}}


STR = lambda d, **k: dict({"type": "string", "description": d}, **k)  # noqa: E731
NUM = lambda d, **k: dict({"type": "number", "description": d}, **k)  # noqa: E731

TOOLS = {
    "kb_search": (S("Find prototype names (items, recipes, technologies, entities, fluids) by words or common names "
                    "like 'green science'.", query=STR("words")),
                  lambda a: "\n".join(f"{n} ({k})" for n, k in kb().search(a["query"])) or "nothing found"),
    "kb_recipe": (S("Exact recipe: ingredients, time, machines, which technology unlocks it, what uses it.",
                    name=STR("recipe or item name")),
                  lambda a: kb().recipe_text(kb().resolve(a["name"]) or a["name"])),
    "kb_tech": (S("Exact technology: cost in packs and time, prerequisites, unlocks, what it leads to, trigger techs.",
                  name=STR("technology (or a recipe it unlocks)")),
                lambda a: tech(a["name"])),
    "kb_path": (S("Technologies still needed to reach a goal technology (or the tech unlocking an item), with total "
                  "packs and lab time. from_game=true subtracts what the current game has researched.",
                  goal=STR("technology or item"), from_game={"type": "boolean", "optional": True}),
                lambda a: kb().path_text(kb().resolve(a["goal"]) or a["goal"],
                                         game().snapshot().get("done") if a.get("from_game", True) else [])),
    "kb_ratio": (S("Machines and raw resources to make N of an item per minute (no modules). Machines default to "
                   "assembling-machine-2 and stone-furnace.", item=STR("item"), per_minute=NUM("target rate"),
                   assembler=STR("assembling-machine-1/2/3", optional=True), furnace=STR("stone/steel/electric-furnace", optional=True)),
                 lambda a: kb().ratio_text(a["item"], float(a["per_minute"]), assembler=a.get("assembler"), furnace=a.get("furnace"))),
    "kb_output": (S("What N machines make and use per minute on one recipe (e.g. 4 assembling-machine-1 on "
                    "logistic-science-pack). Use this for any 'how much do X machines make' number.",
                    recipe=STR("recipe or item"), count=NUM("number of machines"),
                    machine=STR("machine name; default assembling-machine-2 / stone-furnace by category", optional=True)),
                  lambda a: kb().output_text(a["recipe"], a.get("machine"), float(a.get("count") or 1))),
    "kb_compare": (S("Compare the current game's production of an item with a target rate: what is short, what the "
                     "target needs.", item=STR("item"), per_minute=NUM("target rate")),
                   lambda a: kb().compare_text(current_rates()[0], a["item"], float(a["per_minute"]))),
    "kb_entity": (S("Exact stats of a building, unit, resource or item (speeds, power, pollution, health, range, stack size).",
                    name=STR("name")),
                  lambda a: kb().entity_text(kb().resolve(a["name"]) or a["name"])),
    "kb_research_time": (S("How long a technology takes with N labs, and the pack rate that needs.",
                           tech=STR("technology"), labs=NUM("number of labs")),
                         lambda a: kb().research_time_text(kb().resolve(a["tech"]) or a["tech"], int(a["labs"]))),
    "kb_planets": (S("Planets, space locations and route lengths (from a Space Age dump; the base dump has only Nauvis)."),
                   lambda a: kb().planets_text()),
    "kb_map_settings": (S("This world's map settings: pollution, evolution factors, expansion, peaceful, mods."),
                        lambda a: json.dumps(kb().settings, indent=0)[:4000]),
    "game_snapshot": (S("Current game: time, research and progress, SPM, production and use per minute (10-min "
                        "average), buildings, enemy evolution, pollution, kills and losses."),
                      lambda a: G.snapshot_text(game().snapshot())),
    "game_machines": (S("Machines grouped by recipe and status: working, no_ingredients (starved), full_output "
                        "(blocked), low_power, no_power, no_fuel, missing_science_packs."),
                      lambda a: G.machines_text(game().machines())),
    "game_chat": (S("Recent team chat (read with peek; agents still see it as unread).", limit=NUM("messages", optional=True)),
                  lambda a: G.chat_text(game().chat(int(a.get("limit") or 25)))),
    "game_board": (S("The team board: requests, claims and their owners (if the runtime has a board)."),
                   lambda a: json.dumps(game().board(), ensure_ascii=False)[:6000]),
    "game_status": (S("Harness status (peek): evolution breakdown, pollution, nearest enemy bases, attack alerts, power warning."),
                    lambda a: json.dumps(trim_status(game().status()), ensure_ascii=False)[:6000]),
    "game_power": (S("Electric networks: production, demand, satisfaction, machines without power."),
                   lambda a: json.dumps(game().power(), ensure_ascii=False)[:5000]),
    "history_at": (S("Every past run at a game minute: techs, SPM, iron plates per minute, labs, assemblers.",
                     minute=NUM("game minute")),
                   lambda a: H.at_text(series(), float(a["minute"]))),
    "history_when": (S("When each past run finished a technology.", tech=STR("technology")),
                     lambda a: H.when_text(series(), kb().resolve(a["tech"]) or a["tech"])),
    "history_milestones": (S("Game minute of every technology and first science pack in one past run.", run=STR("run name")),
                           lambda a: "\n".join(f"{m:5.1f} min  {t}" for t, m in H.milestones(series().get(a["run"], [])).items())
                           or f"runs: {', '.join(series())}"),
    "history_runs": (S("Past runs with score logs, who played, length, final techs and SPM."),
                     lambda a: H.runs_text(series())),
    "history_study": (S("A study document about a past run (shake1, shake2, shake1-transcripts).", name=STR("study")),
                      lambda a: H.study_text(a["name"])[:20000]),
    "notes": (S("Curated notes: milestones, good-vs-poor-play, biters-pollution, space-age, glossary.", topic=STR("file name without .md")),
              lambda a: open(os.path.join(NOTES, os.path.basename(a["topic"]).replace(".md", "") + ".md")).read()),
    "agent_notes": (S("An agent's own notes.md from the current run (their plan and what they think); no agent lists them.",
                      agent=STR("agent folder name", optional=True)),
                    lambda a: agent_notes(a.get("agent"))),
}


def tech(name):
    k = kb()
    n = k.resolve(name) or name
    if n not in k.techs and n in k.unlocked_by:
        return f"({n} is a recipe unlocked by {', '.join(k.unlocked_by[n])})\n" + k.tech_text(k.unlocked_by[n][0])
    return k.tech_text(n)


def trim_status(s):
    if not isinstance(s, dict):
        return s
    keep = ("evolution", "pollution", "enemies", "alerts", "power", "threats_as_of", "combat", "tick", "factory")
    return {k: v for k, v in s.items() if k in keep}


def handle(msg):
    m, mid = msg.get("method"), msg.get("id")
    if m == "initialize":
        return {"protocolVersion": (msg.get("params") or {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": "analyst", "version": "1"}}
    if m == "ping":
        return {}
    if m == "tools/list":
        return {"tools": [{"name": n, "description": t[0]["description"], "inputSchema": t[0]["schema"]} for n, t in TOOLS.items()]}
    if m == "tools/call":
        p = msg.get("params") or {}
        name, args = p.get("name"), p.get("arguments") or {}
        if name not in TOOLS:
            return {"content": [{"type": "text", "text": f"unknown tool {name}"}], "isError": True}
        try:
            text = TOOLS[name][1](args)
            return {"content": [{"type": "text", "text": str(text)}]}
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            return {"content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}], "isError": True}
    if mid is None:
        return None
    raise KeyError(m)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "id" not in msg:
            continue  # notifications
        try:
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": handle(msg)}
        except KeyError as e:
            out = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"method not found: {e}"}}
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--call":  # debugging: mcp_server.py --call TOOL '{"arg": 1}'
        print(TOOLS[sys.argv[2]][1](json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}))
    else:
        main()
