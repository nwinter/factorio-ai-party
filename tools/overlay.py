#!/usr/bin/env python3
"""Feed the OBS text panel: recent game chat plus factory progress, every few seconds.

  tools/overlay.py --world c [--every 10]
Writes D:\\pog\\overlay\\coop.txt on the game box (the OBS "overlay" text source reads it).
"""
import argparse, json, os, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fh(world, *args):
    env = dict(os.environ, POG_WORLD=world)
    out = subprocess.run([f"{ROOT}/bin/fh", *args, "--format", "json"], capture_output=True, text=True, env=env, timeout=30)
    return json.loads(out.stdout).get("result", {})


def score(world):
    out = subprocess.run(["python3", f"{ROOT}/tools/pog.py", "--world", world, "score"], capture_output=True, text=True, timeout=30)
    return json.loads(out.stdout)


def render(world):
    s = score(world)
    sec = s["tick"] // 60
    done = s.get("research_done") or []
    p = s.get("produced") or {}
    head = (f"game {sec // 3600}h{sec // 60 % 60:02d}m  |  research {len(done)} done, now {s.get('current_research') or '-'}  |  "
            f"iron {p.get('iron-plate', 0):,}  copper {p.get('copper-plate', 0):,}  "
            f"red {p.get('automation-science-pack', 0):,}  green {p.get('logistic-science-pack', 0):,}  "
            f"blue {p.get('chemical-science-pack', 0):,}")
    msgs = fh(world, "call", "chat", "--player", "1", "--args", json.dumps({"since": 0, "limit": 7, "peek": True})).get("messages", [])
    lines = [head, ""] + [f"{m['from']}: {m['text']}" for m in msgs]
    return "\r\n".join(lines)


def push(text):
    subprocess.run(["ssh", "pogwin", "powershell -NoProfile -Command \"[IO.File]::WriteAllText('D:\\pog\\overlay\\coop.txt', [Console]::In.ReadToEnd())\""],
                   input=text, text=True, capture_output=True, timeout=30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="c")
    ap.add_argument("--every", type=float, default=10)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    while True:
        try:
            push(render(a.world))
        except Exception as e:  # keep the overlay loop alive through transient RCON/SSH errors
            print("overlay:", e, flush=True)
        if a.once:
            break
        time.sleep(a.every)


if __name__ == "__main__":
    main()
