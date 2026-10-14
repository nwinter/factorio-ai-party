#!/usr/bin/env python3
"""Viewer lines are relayed once, across restarts and shifts (operator 08:56: at the 07:44 shift change about ten
viewer lines from 06:27-07:36 were logged again): python3 tools/stream/test_relayed.py

1. The relay keeps the ids it sent in runs/RUN/viewer-relayed.jsonl (beside the switch file) and reads the previous
   run's file (runs/RUN/resumed-from) at start: a line sent before is not offered again ("relayed_before").
2. A restart in the same run reads the same file.
3. The same id offered twice before it goes is queued once.
4. tools/chat-log.py starts a new run's chat.jsonl after the previous run's last seq.
"""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402

NOW = 1_800_000_000.0


class FakeHarness:
    def __init__(self):
        self.says = []

    def command(self, cmd):
        req = json.loads(re.search(r"\[(=*)\[(.*)\]\1\]", cmd).group(2))
        if req["action"] == "votes":
            return json.dumps({"ok": True, "result": {"muted": []}})
        self.says.append(req["args"])
        return json.dumps({"ok": True, "result": {"posted": True}})


def line(i, name="Joonazan", text="@gemini 54 mining drills are out of ore", t=NOW):
    return {"id": f"yt:{i}", "source": "youtube", "author": name.lower(), "name": name, "text": text, "t": t}


def runs():
    root = tempfile.mkdtemp()
    old, new = os.path.join(root, "shift10"), os.path.join(root, "shift11")
    os.makedirs(old); os.makedirs(new)
    with open(os.path.join(new, "resumed-from"), "w") as f:
        f.write("shift10\n")
    with open(os.path.join(old, V.RELAYED_FILE), "w") as f:
        f.write(json.dumps({"id": "yt:1", "t": NOW - 4000, "name": "Joonazan"}) + "\n")
    switch = os.path.join(new, "viewers-relay.on")
    open(switch, "w").close()
    return old, new, switch


def relay_once():
    old, new, switch = runs()
    h = FakeHarness()
    relay = V.Relay(h, switch, gap=0, author_gap=0)
    # 1. sent in the previous shift: not again
    m1 = line(1)
    relay.offer(m1, "joonazan")
    assert m1["delivery"] == "relayed_before" and not relay.q, m1
    # a new line goes, and is written down
    m2 = line(2, text="@sol nothing has been on your Gleba belts for a while")
    relay.offer(m2, "joonazan")
    # 3. the same id again while it waits: queued once
    relay.offer(dict(m2), "joonazan")
    assert len(relay.q) == 1
    assert relay.step(NOW + 1) is m2 and len(h.says) == 1
    rows = [json.loads(l) for l in open(os.path.join(new, V.RELAYED_FILE))]
    assert rows == [{"id": "yt:2", "t": NOW + 1, "name": "Joonazan"}], rows
    relay.offer(dict(m2), "joonazan")
    assert not relay.q
    # 2. a restart reads it back (and the previous run's)
    again = V.Relay(FakeHarness(), switch, gap=0, author_gap=0)
    assert list(again.done) == ["yt:1", "yt:2"]
    m = dict(m2)
    again.offer(m, "joonazan")
    assert m["delivery"] == "relayed_before" and again.dropped["relayed_before"] == 1
    # no switch file: nothing kept, nothing read
    assert V.Relay(FakeHarness(), None).done_path is None
    # a run with no resumed-from reads only its own file
    assert V.previous_run_file(os.path.join(old, V.RELAYED_FILE)) is None


def chat_log_carries_seq():
    """chat-log.py on a new run: the first fh call asks since the previous run's last seq."""
    old, new, _ = runs()
    with open(os.path.join(old, "chat.jsonl"), "w") as f:
        for s in (3475, 3484):
            f.write(json.dumps({"seq": s, "tick": 1, "text": "x", "logged_at": "2026-10-14T06:27:08"}) + "\n")
    # a stand-in fh that prints its --args and stops the logger
    bin_dir = tempfile.mkdtemp()
    root = os.path.join(bin_dir, "root")
    os.makedirs(os.path.join(root, "bin")); os.makedirs(os.path.join(root, "tools"))
    seen = os.path.join(bin_dir, "args.txt")
    fh = os.path.join(root, "bin", "fh")
    with open(fh, "w") as f:
        f.write("#!/bin/sh\nfor a in \"$@\"; do last=\"$a\"; done\necho \"$last\" >> " + seen + "\n"
                "echo '{\"result\":{\"messages\":[]}}'\nkill $PPID\n")
    os.chmod(fh, 0o755)
    script = os.path.join(root, "tools", "chat-log.py")
    with open(os.path.join(HERE, "..", "chat-log.py")) as src, open(script, "w") as dst:
        dst.write(src.read())
    subprocess.run([sys.executable, script, os.path.join(new, "chat.jsonl"), "--every", "0.1"], capture_output=True, timeout=30)
    args = json.loads(open(seen).readline())
    assert args["since"] == 3484, args
    # an existing file keeps its own last seq
    with open(os.path.join(new, "chat.jsonl"), "w") as f:
        f.write(json.dumps({"seq": 3600, "tick": 2, "text": "y"}) + "\n")
    os.remove(seen)
    subprocess.run([sys.executable, script, os.path.join(new, "chat.jsonl"), "--every", "0.1"], capture_output=True, timeout=30)
    assert json.loads(open(seen).readline())["since"] == 3600


def main():
    relay_once()
    chat_log_carries_seq()
    print("relayed: ok (ids kept across restarts and shifts; chat-log starts after the previous run's last seq)")


if __name__ == "__main__":
    main()
