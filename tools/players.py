#!/usr/bin/env python3
"""Operator side of the agents' votes on human players (votes.lua and players.lua in the harness).

    players.py --world W watch [--interval 5] [--protect nick] [--log runs/RUN/votes.jsonl] [--dry-run]
    players.py --world W once [...]            one pass
    players.py --world W show [--minutes 10]   the players read, as the agents see it
    players.py --world W trust NAME            move a player out of the guest group (and keep them out on a later world)
    players.py --world W guest NAME            move a player into the guest group
    players.py --world W trust-names NAME...   names kept out of the guest group when they first join (a fresh save)

The harness decides every vote when a ballot is cast (votes.lua: a majority of the agents active in the last 10
minutes). Mute and unmute act in the game; a carried kick, ban or trust waits for this. Each pass reads them (operator
`votes_pending`), runs each with the server's own command (/kick NAME reason, /ban NAME reason) or the permission
change (operator `player_group`), and closes it as done (operator `vote_close`), which posts the result as a chat
line from `vote`: the stream and the agents see it. A protected name is never kicked or banned (its votes close as
cancelled). --dry-run prints what it would carry out without acting or closing.
"""
import argparse
import json
import os
import re
import sys
import time
import uuid

sys.dont_write_bytecode = True  # tools/__pycache__ is tracked in git; do not rewrite it
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stream.harness import Harness, lua_string  # noqa: E402

NAME = re.compile(r"[A-Za-z0-9_.\-]{1,60}")


def clean_reason(text):
    """A reason safe on the server console: printable ASCII without brackets, one line, up to 100 characters."""
    text = re.sub(r"[^A-Za-z0-9 .,:;!?'()\-]+", " ", text or "")
    return re.sub(r"\s+", " ", text).strip()[:100] or "agents' vote"


class Game:
    """RCON to one world: server commands and the harness's operator requests."""

    def __init__(self, world):
        self.harness = Harness(world)

    def command(self, cmd):
        return self.harness.command(cmd)

    def operator(self, action, args=None):
        req = {"id": "players-" + uuid.uuid4().hex[:12], "action": action, "args": args or {}, "operator": True}
        raw = self.command(f'/silent-command rcon.print(remote.call("agent_harness", "dispatch", {lua_string(json.dumps(req))}))')
        reply = json.loads(raw)
        if not reply.get("ok"):
            raise RuntimeError(f"{action}: {reply.get('error', {}).get('message', raw)}")
        return reply.get("result", {})


def execute(game, vote, protect):
    """Run a carried vote; returns (outcome, note)."""
    name, kind = vote["player"], vote["kind"]
    if not NAME.fullmatch(name):
        return "cancelled", f"not a player name the server accepts: {name!r}"
    if kind in ("kick", "ban") and name.lower() in protect:
        return "cancelled", f"{name} is protected by the operator"
    if kind == "trust":
        out = game.operator("player_group", {"name": name, "group": "trusted"})
        return "done", f"{name} moved to the {out.get('group', 'normal')} group"
    if kind in ("kick", "ban"):
        reply = (game.command(f"/{kind} {name} {clean_reason(vote.get('reason'))}") or "").strip()
        return "done", f"/{kind} {name}" + (f": {reply[:120]}" if reply else "")
    return "cancelled", f"unknown kind {kind}"


def run_pass(game, protect=(), dry_run=False, log=None, out=sys.stdout):
    """One pass: carry out every carried kick, ban and trust vote. Returns [(vote, outcome, note)]."""
    state = game.operator("votes_pending")
    done = []
    for vote in state.get("votes", []):
        if dry_run:
            print(f"dry run: #{vote['id']} {vote['kind']} {vote['player']} (yes: {', '.join(vote.get('yes') or [])}) "
                  "would be carried out", file=out)
            done.append((vote, "dry run", ""))
            continue
        try:
            outcome, note = execute(game, vote, protect)
        except Exception as e:  # the vote stays carried; the next pass tries again
            print(f"#{vote['id']} {vote['kind']} {vote['player']}: carried but not run: {e}", file=out)
            continue
        game.operator("vote_close", {"id": vote["id"], "outcome": outcome, "note": note[:200]})
        line = {"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "tick": state.get("tick"), "id": vote["id"], "kind": vote["kind"],
                "player": vote["player"], "reason": vote.get("reason"), "opened_by": vote.get("opened_by"),
                "outcome": outcome, "note": note, "yes": vote.get("yes") or []}
        print(json.dumps(line), file=out, flush=True)
        if log:
            with open(log, "a") as f:
                f.write(json.dumps(line) + "\n")
        done.append((vote, outcome, note))
    return done


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", required=True)
    ap.add_argument("command", choices=["watch", "once", "show", "trust", "guest", "trust-names"])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--interval", type=float, default=5)
    ap.add_argument("--protect", action="append", default=[], help="a name never kicked or banned (repeatable; also POG_PLAYERS_PROTECT, comma-separated)")
    ap.add_argument("--log")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--minutes", type=int, default=10)
    a = ap.parse_args(argv)
    protect = {n.strip().lower() for n in a.protect + os.environ.get("POG_PLAYERS_PROTECT", "").split(",") if n.strip()}
    game = Game(a.world)
    if a.command in ("trust", "guest"):
        if len(a.names) != 1:
            ap.error(f"{a.command} needs one player NAME")
        print(json.dumps(game.operator("player_group", {"name": a.names[0], "group": "trusted" if a.command == "trust" else "guest"})))
        return 0
    if a.command == "trust-names":
        print(json.dumps(game.operator("trust_names", {"names": a.names})))
        return 0
    if a.command == "show":
        print(json.dumps(game.operator("players", {"minutes": a.minutes}), indent=1))
        return 0
    while True:
        try:
            run_pass(game, protect, a.dry_run, a.log)
        except Exception as e:  # an older runtime, a restart, a dropped connection: report and keep going
            print(f"{time.strftime('%H:%M:%S')} pass failed: {e}", file=sys.stderr, flush=True)
            if a.command == "once":
                return 1
        if a.command == "once":
            return 0
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
