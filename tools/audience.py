#!/usr/bin/env python3
"""Operator calls between the stream audience and the team, over RCON (agents never get this tool).

  tools/audience.py [--world live] viewer NAME TEXT...      relay a viewer's chat line into game chat
  tools/audience.py confessions [--since SEQ] [--limit N]   agents' confessionals (fh confess), oldest first

`viewer` posts `viewer NAME: text` in the game chat. Agents read it as chat from "viewer NAME" (flagged viewer: true),
never as a teammate's or the operator's line, and a viewer's @name files no mention. The harness rate-limits it (one
line per viewer every 20 s, 6 a minute in all, counted in game ticks); a dropped line prints `dropped: ...` and exits 3.
Rich text brackets are replaced, newlines flattened, names cut to 24 and text to 200 characters.

The viewer-chat bridge can call the same thing directly: dispatch with `operator: true` and no player,
  {"id":"...","operator":true,"action":"viewer_say","args":{"name":"bob","text":"..."}}
  {"id":"...","operator":true,"action":"confessions","args":{"since":0,"limit":30}}
sent as rcon `/silent-command rcon.print(remote.call("agent_harness","dispatch",<json as a Lua long string>))`.
Add --json for raw replies.
"""
import argparse, json, os, sys, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pog import PORTS, Rcon  # noqa: E402


def dispatch(rcon, action, args):
    payload = json.dumps({"id": "op-" + uuid.uuid4().hex, "action": action, "operator": True, "args": args})
    level = 1
    while "]" + "=" * level + "]" in payload:
        level += 1
    eq = "=" * level
    out = rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","dispatch",[{eq}[{payload}]{eq}]))')
    try:
        reply = json.loads(out)
    except ValueError:
        raise SystemExit(f"unexpected reply (is agent-harness running and current? run fh deploy): {out[:300]}")
    if not reply.get("ok"):
        raise SystemExit("error: " + json.dumps(reply.get("error")))
    return reply["result"]


def main():
    ap = argparse.ArgumentParser(description="Relay viewer chat into the game; read agents' confessionals")
    ap.add_argument("--world", default=os.environ.get("POG_WORLD", "live"))
    ap.add_argument("--port", type=int)
    ap.add_argument("--json", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("viewer"); p.add_argument("name"); p.add_argument("text", nargs="+")
    p = sub.add_parser("confessions"); p.add_argument("--since", type=int, default=0); p.add_argument("--limit", type=int, default=30)
    a = ap.parse_args()
    if a.world in ("a", "b", "c", "n") and not os.environ.get("POG_AUDIENCE_ANY_WORLD"):
        # Run worlds belong to the operator's run tooling; set POG_AUDIENCE_ANY_WORLD=1 to relay there on purpose.
        raise SystemExit(f"world {a.world} is a run world; set POG_AUDIENCE_ANY_WORLD=1 to use it")
    port = a.port or PORTS.get(a.world) or int(os.environ["POG_RCON_PORT"])
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    rcon = Rcon("127.0.0.1", port, pw)

    if a.cmd == "viewer":
        result = dispatch(rcon, "viewer_say", {"name": a.name, "text": " ".join(a.text)})
        if a.json:
            print(json.dumps(result))
        elif result.get("posted"):
            print(f"posted #{result['seq']}: {result['from']}: {result['text']}")
        else:
            print(f"dropped: {result['dropped']} ({result['limit']}); retry in {result['retry_after_s']} s")
        sys.exit(0 if result.get("posted") else 3)
    result = dispatch(rcon, "confessions", {"since": a.since, "limit": a.limit})
    if a.json:
        print(json.dumps(result)); return
    for c in result["confessions"]:
        print(f"{c['seq']} t={c['tick']} {c['from']}: {c['text']}")
    print(f"cursor {result['cursor']}")


if __name__ == "__main__":
    main()
