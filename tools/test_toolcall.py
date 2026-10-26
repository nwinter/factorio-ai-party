#!/usr/bin/env python3
"""Offline checks for tools/toolcall.py (d26 batch238 BT): the agent CLIs' tool hooks record each call, and a tell's
reply (tools/fh_broker.py) and a relayed viewer line (tools/stream/viewers.py) say when the addressee's model has been
inside one call a minute or more. Fixed times only, no clock. python3 tools/test_toolcall.py"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.dont_write_bytecode = True
import toolcall  # noqa: E402
import fh_broker  # noqa: E402
import viewers  # noqa: E402

T0 = 1793030828.0   # d26 09:07:08 PDT, when Opus's westsweep.py call began


def clock(t):
    return time.strftime("%H:%M:%S", time.localtime(t))


def bash(command, cid="toolu_1", d=None):
    return {"cwd": d, "tool_name": "Bash", "tool_use_id": cid, "tool_input": {"command": command}}


def wakes():
    # A call that is only fh sleep or fh wait (and filters) ends when a tell wakes it: the model reads it at once.
    for command in ("./fh sleep 300", "./fh sleep 300 > /dev/null", "./fh wait --until alert --max 240 2>&1 | tail -1",
                    './fh wait --until "alert" --max 240 2>&1 | tail -1; ./fh call scan --args \'{"x":1}\' | grep -iE "a|b"'):
        assert toolcall.wakes(command), command
    # Scripts, loops and plain sleeps keep the model away whatever fh does inside them (batch234: hold.py's sleeps).
    for command in ("python3 tools/westsweep.py 1150 450 2>&1 | tail -2", "python3 tools/hold.py 1150",
                    "for i in 1 2; do ./fh sleep 60; done", "while true; do ./fh sleep 60; done", "sleep 60",
                    "./fh call status", "./fh sleep 60 && python3 tools/x.py", "echo 'unclosed"):
        assert not toolcall.wakes(command), command
    print("wakes: ok")


def record():
    d = tempfile.mkdtemp()
    try:
        assert toolcall.fact("opus", d, T0) is None, "no record: no fact"
        toolcall.started(d, bash("python3 tools/westsweep.py 1150 450 2>&1 | tail -2", "toolu_A"), now=T0)
        assert toolcall.fact("opus", d, T0 + 59) is None, "under a minute: nothing"
        assert toolcall.fact("opus", d, T0 + 15 * 60 + 50) == (
            f"opus: one tool call running since {clock(T0)} (15 min); tells reach it when it ends")
        assert toolcall.fact("opus", d, T0 + 120, what="messages").endswith("(2 min); messages reach it when it ends")
        # Another tool's end (Claude Code records Bash starts only) leaves it open; its own end closes it.
        toolcall.ended(d, {"tool_name": "Read", "tool_use_id": "toolu_R"}, now=T0 + 200)
        assert toolcall.fact("opus", d, T0 + 300)
        toolcall.ended(d, {"tool_name": "Bash", "tool_use_id": "toolu_A"}, now=T0 + 1151)
        assert toolcall.fact("opus", d, T0 + 1200) is None
        assert toolcall.load(d)["ended"] == T0 + 1151
        # One batch starts together: two open calls; the older start is said.
        toolcall.started(d, bash("python3 a.py", "toolu_B"), now=T0)
        toolcall.started(d, bash("python3 b.py", "toolu_C"), now=T0 + 2)
        assert f"opus: 2 tool calls running since {clock(T0)} (5 min)" in toolcall.fact("opus", d, T0 + 300)
        # A call left open (an interrupt: no PostToolUse) is dropped when the model starts another one later.
        toolcall.started(d, bash("./fh call status", "toolu_D"), now=T0 + 400)
        assert list(toolcall.load(d)["calls"]) == ["toolu_D"]
        # A direct fh sleep is no fact: a tell ends it, so the model reads the tell at once.
        toolcall.started(d, bash("./fh sleep 600 | tail -1", "toolu_E"), now=T0 + 500)
        assert toolcall.fact("opus", d, T0 + 900) is None
        # An end with no id (a CLI that sends none) closes them all; Muse's id is tool_call_id.
        toolcall.started(d, {"tool_name": "shell", "tool_call_id": "m1", "tool_input": {"cmd": "python3 x.py"}}, now=T0)
        assert toolcall.load(d)["calls"]["m1"]["wakes"] is False
        toolcall.ended(d, {"tool_name": "shell"}, now=T0 + 90)
        assert toolcall.load(d)["calls"] == {}
        open(os.path.join(d, toolcall.STATE), "w").write("not json")
        assert toolcall.fact("opus", d, T0) is None, "a broken file: no fact"
    finally:
        shutil.rmtree(d)
    print("record: ok")


def hooks():
    """The real hook entry points: tools/permit.py (Claude Code's PreToolUse), tools/context.py hook pre-tool and
    post-tool; nothing outside an agent workspace."""
    d = tempfile.mkdtemp()
    try:
        def run(args, payload):
            return subprocess.run([sys.executable, *args], input=json.dumps(payload), capture_output=True, text=True,
                                  check=True).stdout

        out = run([os.path.join(ROOT, "tools", "permit.py")], bash("./fh call status", "toolu_P", d))
        assert json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "allow", "still answers allow"
        assert not os.path.exists(os.path.join(d, toolcall.STATE)), "no workspace marker: nothing recorded"
        open(os.path.join(d, toolcall.MARKER), "w").write("claude claude-opus-5.5 250000\n")
        run([os.path.join(ROOT, "tools", "permit.py")], bash("python3 tools/westsweep.py 1150 450", "toolu_P", d))
        call = toolcall.load(d)["calls"]["toolu_P"]
        assert call["tool"] == "Bash" and call["wakes"] is False, call
        run([os.path.join(ROOT, "tools", "context.py"), "hook", "post-tool"], {"cwd": d, "tool_use_id": "toolu_P"})
        assert toolcall.load(d)["calls"] == {}
        run([os.path.join(ROOT, "tools", "context.py"), "hook", "pre-tool"],
            {"cwd": d, "tool_name": "run_terminal_cmd", "tool_use_id": "g1", "tool_input": {"command": "python3 x.py"}})
        assert list(toolcall.load(d)["calls"]) == ["g1"], "Grok and Muse: context.py hook pre-tool"
        # Muse's hooks.json and the repo's Grok hooks name pre-tool; Claude Code's PreToolUse is permit.py
        # (tools/clean-profile.py).
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "context.py"), "setup", "muse", "muse-spark-1.3", d],
                       capture_output=True, check=True)
        muse = json.load(open(os.path.join(d, ".muse", "hooks.json")))["hooks"]
        assert "hook pre-tool" in muse["PreToolUse"][0]["hooks"][0]["command"], muse
        grok = json.load(open(os.path.join(ROOT, ".grok", "hooks", "context.json")))["hooks"]
        assert "hook pre-tool" in grok["PreToolUse"][0]["hooks"][0]["command"], grok
        assert "permit.py" in open(os.path.join(ROOT, "tools", "clean-profile.py")).read()
    finally:
        shutil.rmtree(d)
    print("hooks: ok")


def broker():
    run_dir = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(run_dir, "opus"))
        os.makedirs(os.path.join(run_dir, "luna"))
        toolcall.started(os.path.join(run_dir, "opus"), bash("python3 tools/westsweep.py 1150 450", "toolu_A"), now=T0)
        tell = json.dumps({"id": "r1", "ok": True, "tick": 66724543, "result": {
            "seq": 91971, "to": ["opus", "luna", "../opus"], "away": "opus is on Nauvis",
            "note": "in their next reply (team: tells), waking them if asleep; not in chat"}})
        out = json.loads(fh_broker.with_tool_calls(tell, {"action": "tell"}, run_dir, now=T0 + 170))
        assert out["result"]["in_tool_call"] == [
            f"opus: one tool call running since {clock(T0)} (2 min); tells reach it when it ends"], out
        assert out["result"]["note"].startswith("in their next reply"), "the harness's note stays"
        assert fh_broker.with_tool_calls(tell, {"action": "tell"}, run_dir, now=T0 + 30) == tell, "under a minute"
        assert fh_broker.with_tool_calls(tell, {"action": "say"}, run_dir, now=T0 + 900) == tell, "a tell only"
        assert fh_broker.with_tool_calls(tell, {"action": "tell"}, None, now=T0 + 900) == tell, "no run folder"
        refused = json.dumps({"id": "r2", "ok": False, "error": {"message": "no such teammate"}})
        assert fh_broker.with_tool_calls(refused, {"action": "tell"}, run_dir, now=T0 + 900) == refused
        # serve() takes the run folder from the socket folder (runs/RUN/.sock).
        b = fh_broker.Broker(1, "x", os.path.join(run_dir, "broker.log"))
        sock_dir = os.path.join(run_dir, ".sock")
        b.serve(sock_dir, [])
        assert b.run_dir == run_dir, b.run_dir
        b.stop()
    finally:
        shutil.rmtree(run_dir)
    print("broker: ok")


class FakeGame:
    """The relay's harness: viewer_say posts, votes has nobody muted (tools/stream/test_relayrecord.py's)."""

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": [], "open": []}})
        return json.dumps({"ok": True, "result": {"posted": True, "seq": 24423}})


class AI:
    def run(self, model, body):
        return {"answers": {k: {"choice": "fine"} for k in body["questions"]}}


def relay():
    """batch234's site:5017, relayed to Astra and Opus while Opus's model sat in its westsweep.py call: the relayed
    record and the site's delivery say so for Opus, nothing for Astra."""
    viewers.log = lambda msg: None
    run_dir = tempfile.mkdtemp()
    try:
        for a in ("astra", "opus"):
            os.makedirs(os.path.join(run_dir, a))
        # the relay reads the wall clock: a call started 15 min ago
        toolcall.started(os.path.join(run_dir, "opus"), bash("python3 tools/westsweep.py 1150 450", "toolu_A"),
                         now=time.time() - 15 * 60 - 5)
        toolcall.started(os.path.join(run_dir, "astra"), bash("./fh sleep 300", "toolu_S"), now=time.time() - 200)
        switch = os.path.join(run_dir, "viewers-relay.on")
        open(switch, "w").close()
        agents = ["astra", "opus"]
        r = viewers.Relay(FakeGame(), switch, gap=0, author_gap=0, roster=[(a, None) for a in agents])
        feed = viewers.Feed({}, viewers.Filter(agents), viewers.Clef(AI()), relay=r)
        now = T0 + 15 * 60
        feed.ingest([{"id": "site:5017", "source": "site", "author": "site:Aurora", "name": "Aurora", "t": now,
                      "text": "@astra @opus Could a ready pilot scout a new frontier by Spidertron now?"}], [], now=now)
        sent = r.step(now + 1)
        assert sent and sent["to_all"] == ["astra", "opus"], sent
        said = " (15 min); messages reach it when it ends"
        row = [json.loads(l) for l in open(os.path.join(run_dir, viewers.RELAYED_FILE))][-1]
        assert row["why"].startswith("opus: one tool call running since ") and row["why"].endswith(said), row
        assert "astra" not in row["why"], "a direct fh sleep ends on the line: no fact"
        why = {d["id"]: d for d in feed.lane()[1]["delivery"]}["site:5017"]["why"]
        assert why == row["why"], why   # the site: "delivered to Astra, Opus: opus: one tool call running since ..."
        assert viewers.Relay(None, None).in_tool_call(["opus"]) == [], "no run folder: nothing"
    finally:
        shutil.rmtree(run_dir)
    print("relay: ok")


def main():
    wakes()
    record()
    hooks()
    broker()
    relay()
    print("ok")


if __name__ == "__main__":
    main()
