#!/usr/bin/env python3
"""Offline checks for the vote tally (tools/votes.py) and the operator side of player votes (tools/players.py):
python3 tools/test_players.py

- tally: carried at more than half the active agents, failed at more than half against, expired at the deadline,
  ballots of inactive voters ignored; the viewers' rule needs 3 yes and 3 active.
- Book and Activity (the viewers' mute vote): one open vote per kind and target, ballots replaced, decided votes closed.
- tally_pass against a fake world: a carried kick runs `/kick NAME reason` and closes the vote, trust moves the player
  with the operator `player_group`, a protected name is cancelled, a bad name is refused, a failure to run leaves
  the vote open, --dry-run acts on nothing.
- agent/team.md describes the tools only (no should, must, try, when you, if you).
- Vote lines go to the overlay's big chat lane; join and leave lines to the ticker.
- The harness says the same "N yes carry it" as votes.needed (players.lua, run with lua).
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import votes  # noqa: E402
import players  # noqa: E402

AGENTS = votes.RULES["agents"]


def tally():
    t = votes.tally
    r = t({"luna": True, "sol": True}, ["luna", "sol", "grok"], 0, 100, AGENTS)
    assert r["outcome"] == "carried" and r["needed"] == 2 and r["electorate"] == 3, r
    assert t({"luna": True}, ["luna", "sol", "grok", "haiku"], 0, 100, AGENTS)["outcome"] == "open"
    r = t({"luna": True, "sol": True}, ["luna", "sol", "grok", "haiku"], 0, 100, AGENTS)
    assert r["outcome"] == "open" and r["needed"] == 3, r                      # a tie does not carry
    assert t({"luna": True, "sol": False, "grok": False}, ["luna", "sol", "grok"], 0, 100, AGENTS)["outcome"] == "failed"
    assert t({"luna": True}, ["luna", "sol", "grok"], 100, 100, AGENTS)["outcome"] == "expired"
    r = t({"luna": True, "old": True}, ["luna", "sol", "grok"], 0, 100, AGENTS)  # old is no longer active
    assert r["outcome"] == "open" and r["yes"] == ["luna"], r
    assert t({"luna": True}, ["luna"], 0, 100, AGENTS)["outcome"] == "carried"  # alone, one is a majority
    assert t({}, [], 0, 100, AGENTS)["outcome"] == "open"
    viewers = votes.RULES["viewers"]
    assert t({"a": True, "b": True}, ["a", "b"], 0, 600, viewers)["outcome"] == "open"   # 3 yes at least
    assert t({"a": True, "b": True, "c": True}, ["a", "b", "c", "d"], 0, 600, viewers)["outcome"] == "carried"
    assert votes.describe(r) == "1 yes, 0 no of 3 active; 2 needed", votes.describe(r)
    print("tally: ok")


def book():
    rule = votes.RULES["viewers"]
    seen = votes.Activity(rule.window)
    for who in "abcd":
        seen.saw(who, 0)
    seen.saw("e", 700)
    assert seen.active(700) == {"e"}, seen.active(700)
    for who in "abcd":
        seen.saw(who, 700)
    b = votes.Book(rule)
    assert b.cast("a", "mute", "spam9", 700, yes=False) is None
    v = b.cast("a", "mute", "spam9", 700, reason="links")
    assert b.cast("b", "mute", "spam9", 701) is v and v.opened_by == "a" and v.deadline == 1300
    b.cast("c", "mute", "spam9", 702, yes=False)
    assert b.decide(seen.active(705), 705) == []
    b.cast("c", "mute", "spam9", 703)                       # changed their mind
    b.cast("d", "mute", "spam9", 704)
    done = b.decide(seen.active(705), 705)
    assert len(done) == 1 and done[0][1]["outcome"] == "carried" and done[0][1]["yes"] == ["a", "b", "c", "d"], done
    assert b.cast("a", "mute", "spam9", 706).id == 2        # a closed vote does not take ballots
    assert [r["outcome"] for _, r in b.decide(set(), 2000)] == ["expired"]
    print("book and activity: ok")


class FakeGame:
    def __init__(self, open_votes, active, tick=1000, fail_command=False):
        self.state = {"tick": tick, "votes": open_votes, "active": active, "window_ticks": AGENTS.window}
        self.commands, self.ops, self.fail_command = [], [], fail_command

    def command(self, cmd):
        if self.fail_command:
            raise ConnectionError("rcon dropped")
        self.commands.append(cmd)
        return "nick was kicked by <server>."

    def operator(self, action, args=None):
        self.ops.append((action, args))
        if action == "votes_open":
            return self.state
        if action == "player_group":
            return {"name": args["name"], "group": "normal"}
        return {}


def vote(id, kind, player, ballots, reason="mined the [main] bus\nnow", expires=5000):
    return {"id": id, "kind": kind, "player": player, "reason": reason, "opened_by": "luna", "opened_tick": 0,
            "expires_tick": expires, "ballots": ballots}


def operator_pass():
    active = ["luna", "sol", "grok"]
    tmp = tempfile.mkdtemp()
    try:
        log = os.path.join(tmp, "votes.jsonl")
        g = FakeGame([vote(1, "kick", "nick", {"luna": True, "sol": True}), vote(2, "ban", "eve", {"luna": True}),
                      vote(3, "trust", "bob", {"luna": True, "grok": True}), vote(4, "ban", "nick", {"sol": True, "grok": True}),
                      vote(5, "kick", "x y", {"sol": True, "grok": True}), vote(6, "ban", "eve", {"luna": True}, expires=1000),
                      vote(7, "kick", "eve", {"luna": False, "sol": False})], active)
        out = io.StringIO()
        done = players.tally_pass(g, protect=set(), log=log, out=out)
        # 1 carried (kick), 2 open, 3 carried (trust), 4 carried (ban nick), 5 refused name, 6 expired, 7 failed
        assert [(v["id"], o) for v, _, o, _ in done] == [(1, "carried"), (3, "carried"), (4, "carried"), (5, "cancelled"),
                                                          (6, "expired"), (7, "failed")], done
        assert g.commands == ["/kick nick mined the main bus now", "/ban nick mined the main bus now"], g.commands
        assert ("player_group", {"name": "bob", "group": "trusted"}) in g.ops, g.ops
        closes = [a for op, a in g.ops if op == "vote_close"]
        assert [c["id"] for c in closes] == [1, 3, 4, 5, 6, 7], closes
        assert closes[0]["note"] == "2 yes, 0 no of 3 active; 2 needed; /kick nick: nick was kicked by <server>.", closes[0]
        assert closes[1]["note"].endswith("bob moved to the normal group"), closes[1]
        assert "not a player name" in closes[3]["note"], closes[3]
        lines = [json.loads(l) for l in open(log)]
        assert len(lines) == 6 and lines[0]["outcome"] == "carried" and lines[0]["yes"] == ["luna", "sol"], lines
        # A protected name is never kicked or banned.
        g = FakeGame([vote(1, "ban", "nick", {"luna": True, "sol": True})], active)
        players.tally_pass(g, protect={"nick"}, out=io.StringIO())
        assert g.commands == [] and g.ops[-1] == ("vote_close", {"id": 1, "outcome": "cancelled",
                                                                 "note": "2 yes, 0 no of 3 active; 2 needed; nick is protected by the operator"}), g.ops
        # The command fails: the vote stays open for the next pass.
        g = FakeGame([vote(1, "kick", "nick", {"luna": True, "sol": True})], active, fail_command=True)
        out = io.StringIO()
        assert players.tally_pass(g, out=out) == [] and not any(op == "vote_close" for op, _ in g.ops)
        assert "carried but not run: rcon dropped" in out.getvalue(), out.getvalue()
        # Dry run: nothing run, nothing closed.
        g = FakeGame([vote(1, "kick", "nick", {"luna": True, "sol": True})], active)
        out = io.StringIO()
        players.tally_pass(g, dry_run=True, out=out)
        assert g.commands == [] and [op for op, _ in g.ops] == ["votes_open"], g.ops
        assert "would be carried" in out.getvalue()
        assert players.clean_reason("") == "agents' vote" and len(players.clean_reason("x" * 300)) == 100
    finally:
        shutil.rmtree(tmp)
    print("operator pass: ok")


def request_form():
    """players.Game sends the stream service's operator request form (counted as a harness request, not logged,
    by the console audit on eng/broker)."""
    sent = []

    class Stub:
        def command(self, cmd):
            sent.append(cmd)
            return json.dumps({"ok": True, "result": {"tick": 5}})

    g = players.Game.__new__(players.Game)
    g.harness = Stub()
    assert g.operator("votes_open") == {"tick": 5}
    cmd = sent[0]
    prefix = '/silent-command rcon.print(remote.call("agent_harness", "dispatch", [['
    assert cmd.startswith(prefix) and cmd.endswith("]]))"), cmd
    req = json.loads(cmd[len(prefix):-4])
    assert req["operator"] is True and req["action"] == "votes_open" and req["id"].startswith("players-"), req

    class Refused(Stub):
        def command(self, cmd):
            return json.dumps({"ok": False, "error": {"message": "unsupported action; call describe"}})

    g.harness = Refused()
    try:
        g.operator("votes_open")
        raise AssertionError("expected an error")
    except RuntimeError as e:
        assert str(e) == "votes_open: unsupported action; call describe", e
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


LUA = r"""
defines={events={},inventory={},build_check_type={manual_ghost=1}}
local p={index=1,name='nick',valid=true,permission_group={name='Default'}}
game={tick=0,players={p},get_player=function(k) if k==1 or k=='nick' then return p end end}
local s,active,notes={},{},{}
local M=dofile('mod/agent-harness_0.1.0/players.lua'){state=function() return s end,is_human=function(i) return i==1 end,
  active_agents=function() return active end,notice=function(_,t) notes[#notes+1]=t end}
for n=1,7 do
  active={}
  for i=1,n do active[i]='a'..i end
  io.write(M.handlers.vote({index=1000001,name='a1'},{kind='kick',player='nick',reason='x'}).electorate,'\n')
end
"""


def parity():
    if not shutil.which("lua"):
        print("parity: SKIPPED (no lua)")
        return
    out = subprocess.run(["lua", "-e", LUA], cwd=os.path.join(ROOT, "vendor", "factorio-harness"), capture_output=True,
                         text=True, check=True).stdout.splitlines()
    for n, line in enumerate(out, 1):
        assert line == f"{n} agents active in the last 10 minutes; {votes.needed(n, AGENTS)} yes carry it", (n, line)
    assert len(out) == 7
    print("harness parity: ok")


def stream_lane():
    sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
    import model
    assert model.chat_lane({"from": "vote", "text": "#1 kick nick carried (yes 2, no 0)"}) == "talk"
    assert model.chat_lane({"from": "players", "text": "nick joined the game (guest group)"}) == "log"
    print("stream lane: ok")


def docs():
    text = open(os.path.join(ROOT, "agent", "team.md")).read()
    section = text.split("### Human players", 1)[1]
    for tool in ("./fh players", "./fh vote kick|ban|trust", "./fh vote no", "./fh votes", "./fh restore"):
        assert tool in section, tool
    for word in (" should ", " must ", " try ", "when you", "if you"):
        assert word not in section.lower(), word   # tools only, never when or how to use them
    print("agent docs: ok")


if __name__ == "__main__":
    docs()
    stream_lane()
    tally()
    book()
    operator_pass()
    request_form()
    parity()
