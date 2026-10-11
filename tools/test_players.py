#!/usr/bin/env python3
"""Offline checks for the operator side of the agents' votes on human players (tools/players.py):
python3 tools/test_players.py

The votes themselves (mute, unmute, kick, ban, trust: who is active, majorities, expiry, cooldown) are decided in the
harness (votes.lua) and tested there: tests/players.lua, tests/viewers.lua, tests/bots.lua.
- run_pass against a fake world: a carried kick runs `/kick NAME reason` and closes the vote as done, a ban runs
  `/ban`, trust moves the player with the operator `player_group`, a protected name is cancelled, a bad name is
  refused, a failure to run leaves the vote carried for the next pass, --dry-run acts on nothing.
- The operator request form, and the direct trust, guest and trust-names commands.
- agent/team.md describes the tools only (no should, must, try, when you, if you).
- Vote notices go to the overlay's ticker, like the other harness notices.
"""
import io
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import players  # noqa: E402


class FakeGame:
    def __init__(self, pending, tick=1000, fail_command=False):
        self.state = {"tick": tick, "votes": pending}
        self.commands, self.ops, self.fail_command = [], [], fail_command

    def command(self, cmd):
        if self.fail_command:
            raise ConnectionError("rcon dropped")
        self.commands.append(cmd)
        return "nick was kicked by <server>."

    def operator(self, action, args=None):
        self.ops.append((action, args))
        if action == "votes_pending":
            return self.state
        if action == "player_group":
            return {"name": args["name"], "group": "normal"}
        return {}


def vote(id, kind, player, yes=("luna", "sol"), reason="mined the [main] bus\nnow"):
    return {"id": id, "kind": kind, "player": player, "reason": reason, "opened_by": "luna", "decided_tick": 900, "yes": list(yes)}


def operator_pass():
    tmp = tempfile.mkdtemp()
    try:
        log = os.path.join(tmp, "votes.jsonl")
        g = FakeGame([vote(1, "kick", "nick"), vote(3, "trust", "bob", ("luna", "grok")), vote(4, "ban", "nick"),
                      vote(5, "kick", "x y")])
        done = players.run_pass(g, protect=set(), log=log, out=io.StringIO())
        assert [(v["id"], o) for v, o, _ in done] == [(1, "done"), (3, "done"), (4, "done"), (5, "cancelled")], done
        assert g.commands == ["/kick nick mined the main bus now", "/ban nick mined the main bus now"], g.commands
        assert ("player_group", {"name": "bob", "group": "trusted"}) in g.ops, g.ops
        closes = [a for op, a in g.ops if op == "vote_close"]
        assert [c["id"] for c in closes] == [1, 3, 4, 5], closes
        assert closes[0] == {"id": 1, "outcome": "done", "note": "/kick nick: nick was kicked by <server>."}, closes[0]
        assert closes[1]["note"] == "bob moved to the normal group", closes[1]
        assert "not a player name" in closes[3]["note"] and closes[3]["outcome"] == "cancelled", closes[3]
        lines = [json.loads(l) for l in open(log)]
        assert len(lines) == 4 and lines[0]["outcome"] == "done" and lines[0]["yes"] == ["luna", "sol"], lines
        # A protected name is never kicked or banned.
        g = FakeGame([vote(1, "ban", "nick")])
        players.run_pass(g, protect={"nick"}, out=io.StringIO())
        assert g.commands == [] and g.ops[-1] == ("vote_close", {"id": 1, "outcome": "cancelled",
                                                                 "note": "nick is protected by the operator"}), g.ops
        # The command fails: the vote stays carried for the next pass.
        g = FakeGame([vote(1, "kick", "nick")], fail_command=True)
        out = io.StringIO()
        assert players.run_pass(g, out=out) == [] and not any(op == "vote_close" for op, _ in g.ops)
        assert "carried but not run: rcon dropped" in out.getvalue(), out.getvalue()
        # Dry run: nothing run, nothing closed.
        g = FakeGame([vote(1, "kick", "nick")])
        out = io.StringIO()
        players.run_pass(g, dry_run=True, out=out)
        assert g.commands == [] and [op for op, _ in g.ops] == ["votes_pending"], g.ops
        assert "#1 kick nick (yes: luna, sol) would be carried out" in out.getvalue(), out.getvalue()
        assert players.clean_reason("") == "agents' vote" and len(players.clean_reason("x" * 300)) == 100
    finally:
        shutil.rmtree(tmp)
    print("operator pass: ok")


def request_form():
    """players.Game sends the stream service's operator request form (counted as a harness request, not logged,
    by the console audit)."""
    sent = []

    class Stub:
        def command(self, cmd):
            sent.append(cmd)
            return json.dumps({"ok": True, "result": {"tick": 5}})

    g = players.Game.__new__(players.Game)
    g.harness = Stub()
    assert g.operator("votes_pending") == {"tick": 5}
    cmd = sent[0]
    prefix = '/silent-command rcon.print(remote.call("agent_harness", "dispatch", [['
    assert cmd.startswith(prefix) and cmd.endswith("]]))"), cmd
    req = json.loads(cmd[len(prefix):-4])
    assert req["operator"] is True and req["action"] == "votes_pending" and req["id"].startswith("players-"), req

    class Refused(Stub):
        def command(self, cmd):
            return json.dumps({"ok": False, "error": {"message": "unsupported action; call describe"}})

    g.harness = Refused()
    try:
        g.operator("votes_pending")
        raise AssertionError("expected an error")
    except RuntimeError as e:
        assert str(e) == "votes_pending: unsupported action; call describe", e
    # The CLI's direct controls: trust, guest and trust-names (a fresh save's operator names, start-team.sh).
    calls = []

    class Direct:
        def __init__(self, world):
            calls.append(("world", world))

        def operator(self, action, args=None):
            calls.append((action, args))
            return {"ok": True}

    real, players.Game = players.Game, Direct
    try:
        out = io.StringIO()
        sys.stdout, saved = out, sys.stdout
        try:
            assert players.main(["--world", "x", "trust-names", "nick", "zed"]) == 0
            assert players.main(["--world", "x", "trust", "nick"]) == 0
            assert players.main(["--world", "x", "guest", "eve"]) == 0
        finally:
            sys.stdout = saved
    finally:
        players.Game = real
    assert calls == [("world", "x"), ("trust_names", {"names": ["nick", "zed"]}), ("world", "x"),
                     ("player_group", {"name": "nick", "group": "trusted"}), ("world", "x"),
                     ("player_group", {"name": "eve", "group": "guest"})], calls
    print("request form: ok")


def stream_lane():
    sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
    import model
    assert model.chat_lane({"from": "vote", "notice": True, "text": "#1 kick nick carried (2 of 3 active agents: luna, sol)"}) == "log"
    assert model.chat_lane({"from": "players", "notice": True, "text": "nick joined the game (guest group)"}) == "log"
    print("stream lane: ok")


def docs():
    text = open(os.path.join(ROOT, "agent", "team.md")).read()
    section = text.split("### Human players and viewers", 1)[1]
    for tool in ("./fh players", "./fh vote mute", "./fh vote kick", "./fh vote no", "./fh vote list", "./fh restore"):
        assert tool in section, tool
    assert text.count("./fh vote mute") == 1, "one place describes fh vote"
    for word in (" should ", " must ", " try ", "when you", "if you"):
        assert word not in section.lower(), word   # tools only, never when or how to use them
    print("agent docs: ok")


if __name__ == "__main__":
    docs()
    stream_lane()
    operator_pass()
    request_form()
