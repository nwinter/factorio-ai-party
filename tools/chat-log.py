#!/usr/bin/env python3
"""Append every game-chat message to a JSONL file (the in-game log keeps only the last 200).

  tools/chat-log.py --world n --bot astra runs/RUN/chat.jsonl
Read-only: `chat` with peek, so nobody's unread cursor moves.
"""
import argparse, json, os, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--world", default="n")
ap.add_argument("--bot", default="")
ap.add_argument("--player", default="1")
ap.add_argument("--every", type=float, default=5)
a = ap.parse_args()
target = ["--bot", a.bot] if a.bot else ["--player", a.player]
seen = 0
if os.path.exists(a.out):
    for line in open(a.out):
        try: seen = max(seen, json.loads(line)["seq"])
        except Exception: pass
while True:
    try:
        out = subprocess.run([f"{ROOT}/bin/fh", "call", "chat", *target, "--format", "json", "--args",
                              json.dumps({"since": seen, "limit": 100, "peek": True})],
                             capture_output=True, text=True, env=dict(os.environ, POG_WORLD=a.world), timeout=30).stdout
        msgs = json.loads(out).get("result", {}).get("messages", [])
        with open(a.out, "a") as f:
            for m in msgs:
                if m["seq"] > seen:
                    f.write(json.dumps({**m, "logged_at": time.strftime("%FT%T")}) + "\n"); seen = m["seq"]
    except Exception as e:
        print("chat-log:", e, flush=True)
    time.sleep(a.every)
