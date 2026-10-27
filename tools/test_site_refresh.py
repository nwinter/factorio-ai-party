#!/usr/bin/env python3
"""tools/site-refresh.sh with a stub wrangler and a made-up runs folder: python3 tools/test_site_refresh.py

- a refresh updates status.json's last run ("Shift 2 of the long run"), builds the long run page, runs the checks and
  deploys to preview, then production;
- a failed preview deploy leaves production alone; a failed production deploy says the preview has the new build;
- --no-deploy builds and checks only;
- (d22 batch97 BG3) one refresh at a time: a lock held by a live process is waited for (up to POG_SITE_REFRESH_WAIT,
  then the refresh fails, naming its pid); one whose process is gone is taken over; the lock goes when it ends;
- (d26 batch241) DIST.deployed only while the build in DIST is the one production has (site/chart_deploy.py);
- (d27 batch265) while a merge is in progress in the checkout (MERGE_HEAD), one line and exit 0: nothing built,
  status.json untouched, nothing deployed, the lock gone; once the merge is committed it builds again. The other
  cases look at a folder with no merge (the gate runs this test in the live checkout mid-merge).
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "site"))
import test_longrun  # noqa: E402  (its made-up shifts: s1, s2 that did not start, s3)

WRANGLER = """#!/usr/bin/env bash
echo "$*" >> "$WRANGLER_LOG"
case " $* " in *" --branch ${WRANGLER_FAIL:-none} "*) echo "deploy failed" >&2; exit 1;; esac
"""


def run(tmp, *args, **env):
    e = dict(os.environ, POG_TEST="1", POG_WRANGLER=str(tmp / "wrangler"), POG_SITE_RUNS=str(tmp / "runs"), POG_SITE_OUT=str(tmp / "dist"),
             POG_SITE_STATUS=str(tmp / "status.json"), POG_SITE_CONTENT=str(tmp / "site.json"), POG_SITE_CARDS="0", POG_SITE_VIDEOS="0",
             WRANGLER_LOG=str(tmp / "wrangler.log"), POG_SITE_REFRESH_LOCK=str(tmp / "lock"),
             **dict({"POG_SITE_GIT": str(tmp / "nogit")}, **env))
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
        assert (tmp / "dist.deployed").is_file(), "(batch241) a build production has is marked"
        r, calls = run(tmp, WRANGLER_FAIL="preview")
        assert r.returncode == 1 and len(calls) == 1 and "--branch preview" in calls[0], calls
        assert "FAILED: deploy to preview (production left as it was)" in r.stdout, r.stdout
        r, calls = run(tmp, WRANGLER_FAIL="main")
        assert r.returncode == 1 and len(calls) == 2 and "preview has the new build" in r.stdout, r.stdout
        assert not (tmp / "dist.deployed").exists(), "a build production does not have is not marked"
        r, calls = run(tmp)
        assert r.returncode == 0 and (tmp / "dist.deployed").is_file(), r.stdout
        r, calls = run(tmp, "--no-deploy")
        assert r.returncode == 0 and calls == [] and "done (--no-deploy)" in r.stdout, r.stdout
        assert not (tmp / "dist.deployed").exists(), "a build not deployed is not marked"
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
        # a merge in progress in the checkout: skipped, one line
        repo = tmp / "repo"
        repo.mkdir()
        git = lambda *a: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                         *a], capture_output=True, text=True)  # noqa: E731
        git("init", "-q")
        (repo / "f.txt").write_text("a\n")
        git("add", "f.txt")
        git("commit", "-qm", "a")
        git("checkout", "-qb", "other")
        (repo / "f.txt").write_text("b\n")
        git("commit", "-qam", "b")
        git("checkout", "-q", "-")
        (repo / "f.txt").write_text("c\n")
        git("commit", "-qam", "c")
        git("merge", "-q", "other")  # a conflict: the merge stays in progress
        assert git("rev-parse", "-q", "--verify", "MERGE_HEAD").returncode == 0, "the test's merge is in progress"
        before = (tmp / "status.json").read_text()
        shutil.rmtree(tmp / "dist", ignore_errors=True)
        r, calls = run(tmp, "--last-run", "s1", POG_SITE_GIT=str(repo))
        lines = [ln for ln in r.stdout.splitlines() if "site-refresh:" in ln]
        assert r.returncode == 0 and calls == [] and len(lines) == 2 and "skipped: a merge is in progress" in lines[1], r.stdout
        assert not (tmp / "dist").exists() and (tmp / "status.json").read_text() == before and not (tmp / "lock").exists()
        git("merge", "--abort")
        r, calls = run(tmp, "--no-deploy", POG_SITE_GIT=str(repo))
        assert r.returncode == 0 and "done (--no-deploy)" in r.stdout and "skipped" not in r.stdout, r.stdout
    print("site refresh: ok (status.json, build, checks, preview then production; failures stop before production; one at a time)")


if __name__ == "__main__":
    main()
