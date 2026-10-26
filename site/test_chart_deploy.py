#!/usr/bin/env python3
"""The chart deployed on its own within minutes (d26 batch241 CL, site/chart_deploy.py): python3 site/test_chart_deploy.py

- nothing before the run has a chart; nothing (said once) while the build is not one production has (no DIST.deployed);
- the first round puts the run's chart into the build (no .tmp) and deploys it to production (branch main);
- a new version that only redraws cells the same (the index alone): no deploy; a changed cell: deployed, its bytes said;
  a surface's `complete` changed or a file gone: deployed;
- a site refresh holding the lock: this round waits (its lock left alone); one whose pid is gone is taken over;
- a failed deploy: the next round deploys again with nothing new;
- POG_TEST=1 without POG_WRANGLER: never the live wrangler;
- (cp2) a round every 5 minutes (POG_CHART_DEPLOY_EVERY tunes it), none while the 1-minute load average is over 3 x the
  cores.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
import chart_deploy  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    fails += 0 if ok else 1


class Runner:
    def __init__(self):
        self.calls, self.code = [], 0

    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        out = "✨ Success! Uploaded 1 files (646 already uploaded) (3.14 sec)\n" if not self.code else ""
        return subprocess.CompletedProcess(cmd, self.code, out, "deploy failed" if self.code else "")


def main():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        os.environ["POG_SITE_REFRESH_LOCK"] = str(tmp / "lock")
        run, dist = tmp / "runs" / "shift81", tmp / "dist"
        out = run / "chart" / "out"
        st, rn, clock = {}, Runner(), iter(range(0, 10000, 7)).__next__

        busy = [1.0]

        def once():
            return chart_deploy.run_once(run, dist, st, wrangler=["wr"], runner=rn, clock=clock, load=lambda: (busy[0], 0, 0), cores=lambda: 8)

        def index(v, complete=True):
            (out / "index.json").write_text(json.dumps({"v": v, "surfaces": {"nauvis": {"cells": {"0,0": [v, 1, 2, 3]}, "complete": complete}}}))
        check("no chart in the run yet: nothing", once() is None and rn.calls == [])
        (out / "nauvis").mkdir(parents=True)
        (out / "nauvis" / "0_0.png").write_bytes(b"png-a" * 100)
        (out / "nauvis" / "0_0.labels.json").write_text("{}")
        (out / "nauvis" / "1_0.png.tmp").write_text("half")
        index(10)
        (dist / "live" / "chart").mkdir(parents=True)
        (dist / "index.html").write_text("<html>")
        line = once()
        check("a build production does not have (no dist.deployed): waiting, said once", line and line.startswith("waiting: ")
              and once() is None and rn.calls == [], line)
        Path(str(dist) + ".deployed").write_text("1")
        line = once()
        check("the first round: the chart staged into the build and deployed to production",
              rn.calls == [["wr", "pages", "deploy", str(dist), "--project-name", "player-of-games", "--branch", "main", "--commit-dirty=true"]]
              and (dist / "live" / "chart" / "nauvis" / "0_0.png").read_bytes() == b"png-a" * 100
              and not (dist / "live" / "chart" / "nauvis" / "1_0.png.tmp").exists() and not (tmp / "lock").exists(), rn.calls)
        check("its line: version, run, files and bytes, uploads, time", line == "v10 (shift81): 2 files new or changed, 502 bytes, a surface's `complete` changed, 1 uploaded, deployed in 7.0 s", line)
        index(55)
        check("a new version that redraws cells the same (the index alone): no deploy", once() is None and len(rn.calls) == 1, rn.calls)
        (out / "nauvis" / "0_0.png").write_bytes(b"png-b" * 300)
        index(56)
        line = once()
        check("a changed cell: deployed with the index", len(rn.calls) == 2 and line.startswith("v56 (shift81): 1 files new or changed, 1,500 bytes")
              and json.loads((dist / "live" / "chart" / "index.json").read_text())["v"] == 56, line)
        index(57, complete=False)
        line = once()
        check("a surface's `complete` changed: deployed", len(rn.calls) == 3 and "`complete` changed" in line, line)
        (out / "nauvis" / "0_0.labels.json").unlink()
        line = once()
        check("a file gone: deployed", len(rn.calls) == 4 and ", 1 gone" in line and not (dist / "live" / "chart" / "nauvis" / "0_0.labels.json").exists(), line)
        holder = subprocess.Popen(["sleep", "30"])
        try:
            (tmp / "lock").mkdir()
            (tmp / "lock" / "pid").write_text(f"{holder.pid}\n")
            (out / "nauvis" / "0_0.png").write_bytes(b"png-c")
            line = once()
            check("a site refresh holds the lock: this round waits, its lock left", line and "a site refresh holds" in line
                  and len(rn.calls) == 4 and (tmp / "lock" / "pid").exists(), line)
        finally:
            holder.kill()
            holder.wait()
        line = once()
        check("a lock whose pid is gone is taken over", len(rn.calls) == 5 and "deployed" in line and not (tmp / "lock").exists(), line)
        (out / "nauvis" / "0_0.png").write_bytes(b"png-d")
        rn.code = 1
        line = once()
        check("a failed deploy says so", len(rn.calls) == 6 and "deploy FAILED (exit 1): deploy failed" in line, line)
        rn.code = 0
        line = once()
        check("and the next round deploys again with nothing new", len(rn.calls) == 7 and line.endswith("s") and "0 files new" in line, line)
        check("then nothing to do", once() is None and len(rn.calls) == 7)
        (out / "nauvis" / "0_0.png").write_bytes(b"png-f")
        busy[0] = 24.5
        line = once()
        check("(cp2) the 1-minute load average over 3 x the cores: the round waits, said once", line == "waiting: load average 24.5 over 3 x 8 cores"
              and once() is None and len(rn.calls) == 7, line)
        busy[0] = 24.0
        line = once()
        check("at 3 x the cores: the round goes, its files and bytes logged", len(rn.calls) == 8 and line.startswith("v57 (shift81): 1 files new or changed, 5 bytes"), line)
        check("(cp2) a round every 5 minutes by default", chart_deploy.EVERY == 300 or os.environ.get("POG_CHART_DEPLOY_EVERY"), chart_deploy.EVERY)
        r = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import chart_deploy; print(chart_deploy.EVERY)", str(SITE)],
                           env=dict(os.environ, POG_CHART_DEPLOY_EVERY="90"), capture_output=True, text=True, timeout=30)
        check("POG_CHART_DEPLOY_EVERY tunes it", r.stdout.strip() == "90.0", r.stdout + r.stderr)
        (out / "nauvis" / "0_0.png").write_bytes(b"png-e")
        os.environ.pop("POG_WRANGLER", None)
        os.environ["POG_TEST"] = "1"
        line = chart_deploy.run_once(run, dist, st, runner=rn, clock=clock, load=lambda: (0.5, 0, 0), cores=lambda: 8)
        check("POG_TEST=1 without POG_WRANGLER: no deploy (a test never deploys the site)", len(rn.calls) == 8 and "deploy refused" in line, line)
    if fails:
        sys.exit(f"chart deploy: {fails} failed")
    print("chart deploy: ok (the run's changed cells deployed under the refresh's lock, into a build production has; the index alone is not)")


if __name__ == "__main__":
    main()
