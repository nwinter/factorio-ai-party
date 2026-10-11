#!/usr/bin/env python3
"""Make sure every team member has a bot: tools/team_bots.py TEAM_FILE WORLD

A fresh world gets one bot_create per member. A resumed save (tools/start-team.sh, POG_RESUME) already holds bots:
those are kept, and only members the save lacks are created (a second bot_create would fail with "already exists").
Prints one line per member: "NAME kept (alive, at x,y)" or "NAME created ...".
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def members(team_file):
    out = []
    for line in open(team_file):
        if line.strip() and not line.startswith("#"):
            out.append(line.split("\t")[0].strip())
    return out


def existing(rcon):
    """{name: bot row} from the runtime's operator interface."""
    reply = rcon.command('/silent-command rcon.print(remote.call("agent_harness","bots"))')
    try:
        j = json.loads(reply)
        assert j.get("ok"), j
        bots = j.get("bots") or []
        if isinstance(bots, dict):  # an empty Lua table comes back as {}
            bots = list(bots.values())
    except (ValueError, AttributeError, AssertionError):
        raise SystemExit(f"cannot list bots (is the runtime deployed?): {reply!r:.200}")
    return {b["name"]: b for b in bots}


def ensure(rcon, names):
    have = existing(rcon)
    lines = []
    for name in names:
        b = have.get(name)
        if b:
            pos = b.get("position") or {}
            where = f"at {pos.get('x', 0):.0f},{pos.get('y', 0):.0f}" if pos else ""
            state = "alive" if b.get("alive") else f"dead until tick {b.get('dead_until_tick')}"
            lines.append(f"{name} kept ({state}{', ' + where if where else ''})")
        else:
            reply = rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","bot_create","{name}"))')
            lines.append(f"{name} created {reply.strip()[:160]}")
    extra = sorted(set(have) - set(names))
    if extra:
        lines.append("not in the team (left as they are): " + ", ".join(extra))
    return lines


def main():
    team_file, world = sys.argv[1:3]
    import pog
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
    rcon = pog.Rcon("127.0.0.1", pog.PORTS[world], pw)
    for line in ensure(rcon, members(team_file)):
        print(line, flush=True)


if __name__ == "__main__":
    main()
