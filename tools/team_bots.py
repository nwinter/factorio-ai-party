#!/usr/bin/env python3
"""Make sure every team member has a bot: tools/team_bots.py TEAM_FILE WORLD [FORCE]

A fresh world gets one bot_create per member. A resumed save (tools/start-team.sh, POG_RESUME) already holds bots:
those are kept, and only members the save lacks are created (a second bot_create would fail with "already exists").
Prints one line per member: "NAME kept (alive, at x,y)" or "NAME created ...".
FORCE: each bot is created in that force (`bot_create NAME FORCE`), and a bot row that names another force is printed
as a mismatch; members of other forces are not listed.
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


def ensure(rcon, names, force=None):
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
            extra_arg = f',"{force}"' if force else ""
            reply = rcon.command(f'/silent-command rcon.print(remote.call("agent_harness","bot_create","{name}"{extra_arg}))')
            lines.append(f"{name} created {reply.strip()[:160]}")
    if force:
        now = existing(rcon)
        for name in names:
            got = (now.get(name) or {}).get("force")
            if got != force:
                lines.append(f"{name} FORCE MISMATCH: wanted {force}, the bots row says {got or 'no force'}")
    extra = sorted(set(have) - set(names))
    if extra and not force:
        lines.append("not in the team (left as they are): " + ", ".join(extra))
    return lines


def main():
    team_file, world = sys.argv[1:3]
    force = sys.argv[3] if len(sys.argv) > 3 else None
    import pog
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{world}.pw")).read().strip()
    rcon = pog.Rcon(pog.HOSTS.get(world, "127.0.0.1"), pog.PORTS[world], pw)
    for line in ensure(rcon, members(team_file), force):
        print(line, flush=True)


if __name__ == "__main__":
    main()
