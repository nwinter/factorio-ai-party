#!/usr/bin/env python3
"""Offline check for tools/shot-sync.sh against a fake game box: fake `ssh` and `scp` map D:\\pog\\inst to a temp
folder. A director client's script-output\\pog\\WS\\NAME.png must land in RUN/WS/shots/NAME.png and leave the box,
and a file is only copied once it was listed on an earlier pass. python3 tools/test_shot_sync.py"""
import json, os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYNC = os.path.join(ROOT, "tools", "shot-sync.sh")

FAKE_SSH = r'''#!/usr/bin/env python3
import os, re, sys
box = os.environ["FAKEBOX"]
def local(p): return os.path.join(box, p.replace("D:\\pog\\inst\\", "").replace("\\", "/"))
cmd = sys.argv[-1]
with open(os.path.join(box, "ssh.log"), "a") as log: log.write(cmd + "\n")
m = re.match(r'if exist (\S+) dir /b /s /a-d (\S+)\\\*\.png$', cmd)
if m:
    top = local(m.group(1))
    for d, _, files in os.walk(top):
        for f in sorted(files):
            if f.endswith(".png"):
                rel = os.path.relpath(os.path.join(d, f), box).replace("/", "\\")
                sys.stdout.write("D:\\pog\\inst\\" + rel + "\r\n")
    sys.exit(0)
m = re.match(r'del "(.+)"$', cmd)
if m:
    os.remove(local(m.group(1))); sys.exit(0)
sys.exit("fake ssh: unexpected command " + cmd)
'''
FAKE_SCP = r'''#!/usr/bin/env python3
import os, shutil, sys
box = os.environ["FAKEBOX"]
src, dst = [a for a in sys.argv[1:] if a != "-q"]
assert src.startswith("pogwin:D:/pog/inst/"), src
shutil.copyfile(os.path.join(box, src[len("pogwin:D:/pog/inst/"):]), dst)
'''


FAKE_FH = r'''#!/usr/bin/env python3
# Fake bin/fh: the screenshot request names pog/WS/TAG.png; "deliver" it the way shot-sync would.
import json, os, sys
args = sys.argv[1:]
log = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fh.log")
open(log, "a").write(json.dumps(args) + "\n")
if os.environ.get("FAKE_FH_FAIL"):
    print("error: action_failed: no graphical client is connected to render a screenshot"); sys.exit(1)
path = json.loads(args[args.index("--args") + 1])["path"]
_, ws, f = path.split("/")
runs = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runs")
for run in os.listdir(runs):
    if os.path.isdir(os.path.join(runs, run, ws, "shots")):
        open(os.path.join(runs, run, ws, "shots", f), "wb").write(b"PNG")
line = "rendered on nauvis centred (5,5) (your character): frame (-15,-6.25)-(25,16.25), 40x22.5 tiles; ours in it: nothing"
if "platform" in json.loads(args[args.index("--args") + 1]):
    line = "rendered on platform Swift Star (surface platform-3) centred (150,-20.5): frame (140,-28)-(160,-13), 20x15 tiles; ours in it: nothing"
print("tick: 1\nqueued: true\npath: " + path + "\nclient: pog-cam1\nline: \"" + line + "\"")
'''


def wrapper():
    """./shot from tools/new-run.sh: a bot's request goes to pog/WS/, a bad name is made safe, a failed request
    shows its error instead of a silent exit 1."""
    tmp = tempfile.mkdtemp()
    try:
        for d in ("tools", "agent", "bin"):
            os.makedirs(os.path.join(tmp, d))
        for f in ("new-run.sh", "brief.py"):
            shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
        for f in ("PLAYBOOK.md", "time-realtime.md", "compact.md"):
            shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
        shutil.copytree(os.path.join(ROOT, "agent", "ref"), os.path.join(tmp, "agent", "ref"))
        fh = os.path.join(tmp, "bin", "fh")
        open(fh, "w").write(FAKE_FH)
        os.chmod(fh, 0o755)
        env = dict(os.environ, POG_WS="grok", POG_BOT="grok")
        ws = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "t1", "n", "grok", "60"], env=env,
                            capture_output=True, text=True, check=True).stdout.strip()
        assert ws.endswith("runs/t1/grok"), ws
        r = subprocess.run([os.path.join(ws, "shot"), "belt layout"], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        out = r.stdout.strip().splitlines()
        assert out[0] == "shots/belt_layout.png", r.stdout
        # (d21 batch66 AB2) then where the engine rendered it, from the reply's line
        assert out[1].startswith("rendered on nauvis centred (5,5) (your character): frame "), r.stdout
        assert os.path.exists(os.path.join(ws, "shots", "belt_layout.png"))
        sent = open(os.path.join(tmp, "bin", "fh.log")).read()
        assert '"--bot", "grok"' in sent and '\\"path\\":\\"pog/grok/belt_layout-' in sent, sent
        # (d20 batch56 R2) at= centres it by remote view; surface= or platform= names where
        r = subprocess.run([os.path.join(ws, "shot"), "far", "640", "480", "at=150,-20.5", "platform=Swift Star"],
                           capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.splitlines() == ["shots/far.png",
            "rendered on platform Swift Star (surface platform-3) centred (150,-20.5): frame (140,-28)-(160,-13), 20x15 tiles; ours in it: nothing"], (r.returncode, r.stdout, r.stderr)
        sent = json.loads(json.loads(open(os.path.join(tmp, "bin", "fh.log")).read().splitlines()[-1])[-1])
        assert sent["width"] == 640 and sent["height"] == 480 and sent["position"] == {"x": 150, "y": -20.5}, sent
        assert sent["platform"] == "Swift Star" and sent["path"].startswith("pog/grok/far-"), sent
        r = subprocess.run([os.path.join(ws, "shot"), "far", "at=150"], capture_output=True, text=True)
        assert r.returncode == 2 and "usage: ./shot NAME" in r.stderr, (r.returncode, r.stderr)
        r = subprocess.run([os.path.join(ws, "shot"), "x"], capture_output=True, text=True,
                           env=dict(os.environ, FAKE_FH_FAIL="1"))
        assert r.returncode == 1 and "no graphical client is connected" in r.stderr, (r.returncode, r.stderr)
        print("shot wrapper: ok")
    finally:
        shutil.rmtree(tmp)


def main():
    wrapper()
    tmp = tempfile.mkdtemp()
    try:
        bindir, box, run = (os.path.join(tmp, n) for n in ("bin", "box", "run"))
        os.makedirs(bindir)
        for name, text in (("ssh", FAKE_SSH), ("scp", FAKE_SCP)):
            path = os.path.join(bindir, name)
            open(path, "w").write(text)
            os.chmod(path, 0o755)
        out = os.path.join(box, "n-client-cam1", "script-output", "pog")
        os.makedirs(os.path.join(out, "grok"))
        os.makedirs(os.path.join(out, "nobody"))  # a workspace this run does not have: left alone
        os.makedirs(os.path.join(run, "grok", "shots"))
        open(os.path.join(out, "grok", "look-1-2.png"), "wb").write(b"PNG1")
        open(os.path.join(out, "nobody", "x.png"), "wb").write(b"PNG2")
        open(os.path.join(out, "old.png"), "wb").write(b"PNG3")  # no workspace folder: left alone
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], FAKEBOX=box)
        proc = subprocess.Popen(["bash", SYNC, run, "n-client-cam1", "n-client-cam2"], env=env)
        try:
            # First pass lists it; it is copied on the second pass (about a second later).
            time.sleep(0.5)
            assert not os.path.exists(os.path.join(run, "grok", "shots", "look-1-2.png")), "copied on the first sight"
            got = os.path.join(run, "grok", "shots", "look-1-2.png")
            for _ in range(60):
                if os.path.exists(got) and not os.path.exists(os.path.join(out, "grok", "look-1-2.png")):
                    break
                time.sleep(0.1)
            assert open(got, "rb").read() == b"PNG1", "not delivered to the workspace"
            assert not os.path.exists(os.path.join(out, "grok", "look-1-2.png")), "not removed from the box"
            assert not [f for f in os.listdir(os.path.join(run, "grok", "shots")) if f.startswith(".incoming")]
            assert os.path.exists(os.path.join(out, "nobody", "x.png")) and os.path.exists(os.path.join(out, "old.png"))
        finally:
            proc.terminate()
            proc.wait()
        print("shot-sync: ok")
    finally:
        shutil.rmtree(tmp)


if __name__ == "__main__":
    sys.exit(main())
