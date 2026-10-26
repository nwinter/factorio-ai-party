#!/usr/bin/env python3
"""Urgent messages during a 20-minute tool call, through the real hooks (d26 batch238; viewer Aurora 11:50: "Could
batch234 test urgent messages during a 20-minute job? Present them at safe checkpoints and allow a safe handoff. Keep
unseen messages unread, including across restart."). batch234's shift80 as it happened: Opus's model sat in one
`python3 tools/westsweep.py 1150 450 2>&1 | tail -2` call while its script woke on Astra's tells and acked them.

1. The sender's reply says the addressee's model is inside the call (tools/fh_broker.py; the relay the same).
2. The post-call hook shows what the call's replies carried, newest first, however the script acked it.
3. A shift that ends inside a call: the next run's first call shows what the model never saw, once, no duplicates.
Fixed times in the journal; the hooks stamp the call's start themselves, so the test moves it back. No network.
python3 tools/test_urgent_handoff.py"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import fh_broker  # noqa: E402
import toolcall  # noqa: E402

T0 = 1793030828.0   # d26 09:07:08 PDT


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))


def clock(t):
    return time.strftime("%H:%M:%S", time.localtime(t))


def hook(args, payload):
    out = subprocess.run([sys.executable, *args], input=json.dumps(payload), capture_output=True, text=True,
                         check=True).stdout
    return json.loads(out)["hookSpecificOutput"].get("additionalContext", "") if out.strip() else ""


class Workspace:
    def __init__(self, runs, run, agent="opus", prev=None):
        self.d = os.path.join(runs, run, agent)
        os.makedirs(self.d)
        if prev:
            open(os.path.join(runs, run, "resumed-from"), "w").write(prev + "\n")
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "context.py"), "setup", "claude", "claude-opus-5.5",
                        self.d], capture_output=True, check=True)
        self.journal = os.path.join(self.d, "journal.jsonl")
        self.n = 0

    def reply(self, t, action, **team):
        """One fh reply in the journal (the script's own requests), carrying a team block."""
        self.n += 1
        with open(self.journal, "a") as f:
            f.write(json.dumps({"at": iso(t), "event": "response", "response": {
                "id": f"r{self.n}", "ok": True, "tick": 66700000 + self.n, "result": {
                    "closed": 1 if action == "chat_ack" else None, "team": team}}}) + "\n")

    def start(self, command, cid, since):
        """The model's Bash call: Claude Code's PreToolUse (tools/permit.py), its start then set to `since`."""
        hook([os.path.join(ROOT, "tools", "permit.py")], {"cwd": self.d, "tool_name": "Bash", "tool_use_id": cid,
                                                        "tool_input": {"command": command}})
        state = toolcall.load(self.d)
        state["calls"][cid]["since"] = since
        toolcall.save(self.d, state)

    def end(self, cid, stdout):
        """The call ends: Claude Code's PostToolUse (tools/context.py hook post-tool); what it adds to the model's view."""
        return hook([os.path.join(ROOT, "tools", "context.py"), "hook", "post-tool"],
                    {"cwd": self.d, "tool_name": "Bash", "tool_use_id": cid, "tool_response": {"stdout": stdout}})


TELL_91971 = "astra (on Aquilo), 0s ago: Aurora24395 asks regular Spidertron recon including thisshift andnext."
TELL_91979 = "astra (on Aquilo), 0s ago: Operator24399 says batch224 ready but no spider outing this shift."
AURORA = ("viewer Aurora (site) @you, 45s ago: @astra @opus Could a ready pilot scout a new frontier by Spidertron now, "
          "log nests and return to supplied cover?")
TELL_92032 = "astra (on Aquilo), 0s ago: Aurora24423 asks actual outing NOW. No reply to91971/91979 yet."
TELL_92045 = "astra (on Aquilo), 0s ago: I started 27069154 toward (-410,-400),(-600,-560) at66780652 after tell92032."


def main():
    runs = tempfile.mkdtemp()
    try:
        ws = Workspace(runs, "shift80")
        ws.reply(T0 - 60, "status")
        assert ws.end("toolu_0", "status ok") == "", "nothing carried yet"
        # 1. The 20-minute call. Its script sleeps, wakes on each tell and acks it (chat_ack seq all) at once.
        ws.start("python3 tools/westsweep.py 1150 450 2>&1 | tail -2", "toolu_W", since=T0)
        for t, kind, text in ((T0 + 33, "tells", TELL_91971), (T0 + 206, "tells", TELL_91979),
                              (T0 + 951, "mentions", AURORA), (T0 + 951, "tells", TELL_92032)):
            ws.reply(t, "sleep_check", **{kind: [text]})
            ws.reply(t + 0.1, "chat_ack")   # the script's ack: read in the game, not by the model
        # Astra's tell 92032 at 09:22:58: its reply says where Opus's model is.
        sent = json.dumps({"id": "a1", "ok": True, "tick": 66778956, "result": {
            "seq": 92032, "to": ["opus"], "note": "in their next reply (team: tells), waking them if asleep; not in chat"}})
        reply = json.loads(fh_broker.with_tool_calls(sent, {"action": "tell"}, os.path.join(runs, "shift80"), now=T0 + 950))
        assert reply["result"]["in_tool_call"] == [
            f"opus: one tool call running since {clock(T0)} (15 min); tells reach it when it ends"], reply
        # 2. The call ends at 09:26:19 with two lines of its own output: the hook shows the four, newest first.
        shown = ws.end("toolu_W", "09:19:12 0 bases, shells 877 []\n09:23:13 0 bases, shells 877 []")
        lines = shown.splitlines()
        assert lines[0] == f"TELL (reply {clock(T0 + 951)}): {TELL_92032}", lines
        assert lines[1] == f"MENTION (reply {clock(T0 + 951)}): {AURORA}", lines
        assert lines[2].endswith(TELL_91979) and lines[3].endswith(TELL_91971), lines
        assert lines[4].startswith("(From your fh replies' team block since your last tool call, newest first"), lines
        assert toolcall.load(ws.d)["calls"] == {}, "the call is closed"
        assert ws.end("toolu_X", "") == "", "shown once"
        # 3. The next call runs past the shift's end: no PostToolUse in shift80.
        ws.start("python3 tools/hold.py 1150 2>&1 | tail -2", "toolu_H", since=T0 + 1300)
        ws.reply(T0 + 1352, "sleep_check", tells=[TELL_92045])
        ws.reply(T0 + 1352.1, "chat_ack")
        ws.reply(T0 + 1500, "sleep_check", mentions=["viewer Caleb (site) @you, 3s ago: @opus is the west quiet?"])
        # shift81 resumes from shift80: the first reply re-delivers 92045 as unread, and a new tell comes.
        nxt = Workspace(runs, "shift81", prev="shift80")
        nxt.reply(T0 + 4000, "status", tells=[
            "1 unread tell (chat_ack {seq: N} or {seq: \"all\"}, or a tells read, marks them read):",
            "unread #92045 astra (on Aquilo), waiting 2648s: I started 27069154 toward (-410,-400),(-600,-560) at66780652 a..."])
        nxt.reply(T0 + 4010, "status", tells=["luna, 0s ago: pad footprint clear"])
        first = nxt.end("toolu_1", "status ok").splitlines()
        assert first[0] == f"TELL (reply {clock(T0 + 4010)}): luna, 0s ago: pad footprint clear", first
        assert sum("I started 27069154" in l for l in first) == 1, ("92045 once", first)
        assert not any("1 unread tell (" in l for l in first), ("an unread list's heading is no message", first)
        assert any(l.startswith("TELL (reply ") and "27069154" in l for l in first), first
        caleb = [l for l in first if "Caleb" in l]
        assert caleb == [f"MENTION (reply {clock(T0 + 1500)}, shift80): viewer Caleb (site) @you, 3s ago: @opus is the "
                         "west quiet?"], first
        assert not any("Aurora24423" in l for l in first), "what the model saw in shift80 is not shown again"
        assert nxt.end("toolu_2", "") == "", "once"
        # A restart within shift81 (the agent CLI started again: same workspace and state): only what is new.
        nxt.reply(T0 + 4100, "status", tells=["sol, 0s ago: coolant ok"])
        assert nxt.end("toolu_3", "").startswith("TELL (reply "), "a new item after the restart"
        # Another workspace resuming from shift80 again (a rerun of the shift start) carries nothing twice.
        again = Workspace(runs, "shift81b", prev="shift80")
        again.reply(T0 + 4200, "status")
        assert again.end("toolu_1", "") == "", "carried once"
        prev_state = json.load(open(os.path.join(ws.d, ".context-state.json")))
        assert prev_state["carried_to"] == "shift81", prev_state
    finally:
        shutil.rmtree(runs)
    print("urgent hand-off: ok (busy fact to the sender, newest first after the call, unseen carried across a shift once)")


if __name__ == "__main__":
    main()
