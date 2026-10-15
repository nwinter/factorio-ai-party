#!/usr/bin/env python3
"""Console commands that were not harness requests: python3 tools/console_audit.py --world n [--out FILE] [--strict]

The agent-harness mod (control.lua, on_console_command) counts every harness request (`rcon.print(remote.call(
"agent_harness", "dispatch", <long string>))`, what bin/fh sends) and logs every other console command, from a
player or over RCON, grouped by shape (long strings, quoted strings and numbers blanked) with a count, first and
last tick and sample texts. This reads that log (operator RCON) and labels each shape:
- operator: a shape our own tools send (the Lua constants in OPERATOR_SOURCES and the one-liners in KNOWN_LINES);
- server: a plain server command (save, time, players, ...);
- deploy: a runtime install (fh deploy), which the operator does between shifts and an agent never should;
- moderation: the server's /kick, /ban, /unban, /mute, /whitelist, /promote and the like; tools/players.py sends
  /kick and /ban for a carried vote (compare with runs/RUN/votes.jsonl), and nothing else should;
- UNKNOWN: anything else, to read by hand.
Without the broker (POG_BROKER=1) an agent holding the RCON password could still send an operator shape; the
broker takes the password away (docs/LAUNCH-NOTES.md).
Also: --file LOG.json reads a saved log instead of the world (tests, or the --out file of an earlier stop).
"""
import argparse, ast, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Modules whose module-level *_LUA / Lua string constants the operator sends one-lined (placeholders blanked).
OPERATOR_SOURCES = ["tools/pog.py", "tools/stream/harness.py", "tools/stream/viewers.py", "tools/analyst/game.py",
                    "tools/sa_travel.py", "tools/sa_flight.py", "tools/sa_smoke.py"]
KNOWN_LINES = [
    "rcon.print(remote.call(\"agent_harness\",\"bots\"))",
    "rcon.print(remote.call(\"agent_harness\",\"bot_create\",\"x\"))",
    "rcon.print(remote.call(\"agent_harness\",\"bot_remove\",\"x\"))",
    "rcon.print(remote.call(\"agent_harness\",\"shift_start\"))",
    "rcon.print(remote.call(\"agent_harness\",\"shift_start\",1))",
    # tools/start-team.sh: the shift's number and the last shifts' progress lines (tools/progress.py --shift-lines)
    "rcon.print(remote.call(\"agent_harness\",\"shift_start\",1,[==[x]==]))",
    "rcon.print(remote.call(\"agent_harness\",\"cameras\"))",
    "game.tick_paused = true rcon.print('paused at ' .. game.tick)",
    "game.tick_paused = false rcon.print('resumed at ' .. game.tick)",
    "game.tick_paused=false local p=game.get_player(1) rcon.print(p.connected and p.character and \"joined\" or \"waiting\")",
    "local ok,r=pcall(remote.call,\"agent_harness\",\"bot_create\",\"x\") rcon.print(helpers.table_to_json({ok=ok,r=r}))",
    # factorio-harness host: session start and stop, deploy's install limits.
    "rcon.print(\"ready\")",
    "local p=game.players[1]; rcon.print(helpers.table_to_json(p and {name=p.name} or {}))",
    "game.server_save(\"session\"); rcon.print(\"queued\")",
    "local i=remote.interfaces.agent_harness; rcon.print(i and i.install_limits and remote.call(\"agent_harness\",\"install_limits\") or \"{}\")",
]
MODERATION = {"kick", "ban", "unban", "mute", "unmute", "whitelist", "promote", "demote", "permissions", "purge"}
SERVER = {"server-save", "quit", "time", "players", "version", "seed", "evolution", "help", "h", "admins", "save"}
LUA = {"c", "command", "sc", "silent-command", "measured-command"}
DEPLOY = re.compile(r'^silent-command rcon\.print\(remote\.call\("agent_harness", ?"install(_chunk|_commit)?"')
AUDIT_CALL = ("local i=remote.interfaces.agent_harness; rcon.print(i and i.console_log and "
              "remote.call(\"agent_harness\",\"console_log\",{since}) or '{{\"ok\":false,\"error\":\"this world\\'s "
              "agent-harness mod has no console_log: deploy the current mod\"}}')")


SHAPE_MAX = 1000


def shape(name, text, limit=SHAPE_MAX):
    """The mod's shape key (control.lua `shape`): long strings and numbers blanked, cut at 1000 characters."""
    s = re.sub(r"\[(=*)\[.*?\]\1\]", "[[]]", text, flags=re.S)
    s = re.sub(r"[0-9]+", "0", s)
    return (name + " " + s)[:limit]


def one_line(lua):
    return " ".join(l.strip() for l in lua.strip().splitlines() if l.strip())


def operator_shapes():
    """Shapes of the Lua our own tools send, from their source (parsed, not imported)."""
    texts = list(KNOWN_LINES)
    for rel in OPERATOR_SOURCES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        for node in ast.walk(ast.parse(open(path).read())):
            if (isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
                    and any(isinstance(t, ast.Name) and "LUA" in t.id for t in node.targets)):
                texts.append(node.value.value)
    texts.append(AUDIT_CALL.format(since=0))
    out = set()
    for t in texts:
        # The placeholders the tools fill in: a long string, a quoted string, the relay function, an item list.
        t = t.replace("BODY", "[[]]").replace("SURFACE", '""').replace("FN", "viewer_relay").replace("ITEMS", '{""}')
        for line in (one_line(t), " ".join(l.strip() for l in t.strip().splitlines())):  # pog.py's join keeps blanks
            out.add(loose(shape("silent-command", line, None)))
    return out


def loose(key):
    """A shape with quoted strings blanked and lists of them collapsed, for matching: the tools fill in bot,
    surface and item names."""
    key = re.sub(r"'[^']*'", "''", re.sub(r'"[^"]*"', '""', key))
    return re.sub(r'""(\s*,\s*"")+', '""', key)


def label(entry, known):
    name = entry.get("command", "")
    key = entry.get("shape") or shape(name, entry.get("first_text", ""))
    if DEPLOY.match(key):
        return "deploy"
    # A key the mod cut at 1000 characters matches the start of a known one, up to the cut's last 50 characters
    # (an item list moves the cut, and the cut can split a quoted string).
    head = loose(key)[:-50]
    if loose(key) in known or (len(key) >= SHAPE_MAX and any(k.startswith(head) for k in known)):
        return "operator"
    if name in MODERATION:
        return "moderation"
    if name in SERVER:
        return "server"
    return "UNKNOWN"


def fetch(world, since=0):
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import pog
    port = pog.PORTS.get(world) or int(os.environ["POG_RCON_PORT"])
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
    raw = pog.Rcon("127.0.0.1", port, pw).command("/silent-command " + AUDIT_CALL.format(since=int(since)))
    return json.loads(raw)


def report(log, world="?"):
    """(lines, unknown entries) for a console_log reply."""
    if not log.get("ok"):
        return [f"console audit, world {world}: unavailable ({log.get('error')})"], []
    known = operator_shapes()
    groups = {}
    for e in log.get("entries", []):
        e["label"] = label(e, known)
        groups.setdefault(e["label"], []).append(e)
    lines = [f"console audit, world {world} at tick {log.get('tick')}: {log.get('harness', 0)} harness requests, "
             f"{log.get('other', 0)} other commands in {len(log.get('entries', []))} shapes"
             + (f" ({log['dropped']} older shapes dropped)" if log.get("dropped") else "")]
    for name in ("operator", "server"):
        g = groups.get(name, [])
        lines.append(f"{name}: {len(g)} shapes, {sum(e['count'] for e in g)} commands")
    for name in ("deploy", "moderation", "UNKNOWN"):
        g = groups.get(name, [])
        lines.append(f"{name}: " + (f"{len(g)} shapes, {sum(e['count'] for e in g)} commands" if g else "none"))
        for e in g:
            text = e.get("last_text") or e.get("first_text") or ""
            lines.append(f"  tick {e.get('first_tick')}-{e.get('last_tick')} x{e['count']} by {','.join(e.get('players', []))}: "
                         f"/{e.get('command')} {text[:200]}")
    return lines, groups.get("UNKNOWN", [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--file", help="a saved console_log reply instead of the world")
    ap.add_argument("--out", help="also save the reply, with labels, to this file")
    ap.add_argument("--strict", action="store_true", help="exit 2 when there are UNKNOWN commands")
    a = ap.parse_args()
    log = json.load(open(a.file)) if a.file else fetch(a.world)
    lines, unknown = report(log, a.world)
    print("\n".join(lines))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(log, f, indent=1)
    sys.exit(2 if a.strict and unknown else 0)


if __name__ == "__main__":
    main()
