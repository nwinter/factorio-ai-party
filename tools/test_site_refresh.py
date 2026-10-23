#!/usr/bin/env python3
"""tools/site-refresh.sh with a stub wrangler and a made-up runs folder: python3 tools/test_site_refresh.py

- a refresh updates status.json's last run ("Shift 2 of the long run"), builds the long run page, runs the checks and
  deploys to preview, then production;
- a failed preview deploy leaves production alone; a failed production deploy says the preview has the new build;
- --no-deploy builds and checks only;
- (d22 batch97 BG3) one refresh at a time: a lock held by a live process is waited for (up to POG_SITE_REFRESH_WAIT,
  then the refresh fails, naming its pid); one whose process is gone is taken over; the lock goes when it ends.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "site"))
import test_longrun  # noqa: E402  (its made-up shifts: s1, s2 that did not start, s3)

WRANGLER = """#!/usr/bin/env bash
echo "$*" >> "$WRANGLER_LOG"
case " $* " in *" --branch ${WRANGLER_FAIL:-none} "*) echo "deploy failed" >&2; exit 1;; esac
"""


def run(tmp, *args, **env):
    e = dict(os.environ, POG_WRANGLER=str(tmp / "wrangler"), POG_SITE_RUNS=str(tmp / "runs"), POG_SITE_OUT=str(tmp / "dist"),
             POG_SITE_STATUS=str(tmp / "status.json"), POG_SITE_CONTENT=str(tmp / "site.json"), POG_SITE_CARDS="0",
             WRANGLER_LOG=str(tmp / "wrangler.log"), POG_SITE_REFRESH_LOCK=str(tmp / "lock"), **env)
    (tmp / "wrangler.log").write_text("")
    r = subprocess.run([str(ROOT / "tools" / "site-refresh.sh"), *args], cwd=ROOT, env=e, capture_output=True, text=True,
                       timeout=300)
    return r, (tmp / "wrangler.log").read_text().splitlines()


def main():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "runs").mkdir()
        test_longrun.make(tmp / "runs")
        content = json.loads((ROOT / "site" / "content" / "site.json").read_text())
        content.pop("run_start", None)  # the made-up shifts' longest chain (site.json's run_start is a real run id)
        (tmp / "site.json").write_text(json.dumps(content))
        (tmp / "wrangler").write_text(WRANGLER)
        (tmp / "wrangler").chmod(0o755)
        (tmp / "status.json").write_text(json.dumps({"schema": 1, "live": False, "message": "Between shifts.", "next": None,
                                                     "last_run": None}))
        r, calls = run(tmp, "--last-run", "s3")
        assert r.returncode == 0, r.stdout + r.stderr
        assert calls == [f"pages deploy {tmp / 'dist'} --project-name player-of-games --branch preview --commit-dirty=true",
                         f"pages deploy {tmp / 'dist'} --project-name player-of-games --branch main --commit-dirty=true"], calls
        st = json.loads((tmp / "status.json").read_text())
        assert st["last_run"] == {"id": "s3", "title": "Shift 2 of the long run", "url": "/runs/long/"} and st["message"] == "Between shifts."
        assert json.loads((tmp / "dist" / "live" / "status.json").read_text())["last_run"]["id"] == "s3"  # deployed with it
        assert (tmp / "dist" / "runs" / "long" / "index.html").exists()
        assert "site-refresh: done" in r.stdout.splitlines()[-1], r.stdout
        r, calls = run(tmp, WRANGLER_FAIL="preview")
        assert r.returncode == 1 and len(calls) == 1 and "--branch preview" in calls[0], calls
        assert "FAILED: deploy to preview (production left as it was)" in r.stdout, r.stdout
        r, calls = run(tmp, WRANGLER_FAIL="main")
        assert r.returncode == 1 and len(calls) == 2 and "preview has the new build" in r.stdout, r.stdout
        r, calls = run(tmp, "--no-deploy")
        assert r.returncode == 0 and calls == [] and "done (--no-deploy)" in r.stdout, r.stdout
        assert not (tmp / "lock").exists(), "the lock goes with the refresh"
        holder = subprocess.Popen(["sleep", "30"])
        try:
            (tmp / "lock").mkdir()
            (tmp / "lock" / "pid").write_text(f"{holder.pid}\n")
            r, calls = run(tmp, "--no-deploy", POG_SITE_REFRESH_WAIT="5")
            assert r.returncode == 1 and f"another site refresh (pid {holder.pid}) held the lock" in r.stdout \
                and f"waiting for another site refresh (pid {holder.pid})" in r.stdout and calls == [], r.stdout
        finally:
            holder.kill()
            holder.wait()
        r, calls = run(tmp, "--no-deploy")
        assert r.returncode == 0 and "done (--no-deploy)" in r.stdout, "a lock whose pid is gone is taken over: " + r.stdout
    print("site refresh: ok (status.json, build, checks, preview then production; failures stop before production; one at a time)")


if __name__ == "__main__":
    main()
