#!/usr/bin/env python3
"""tools/site-refresh.sh with a stub wrangler and a made-up runs folder: python3 tools/test_site_refresh.py

- a refresh updates status.json's last run ("Shift 2 of the long run"), builds the long run page, runs the checks and
  deploys to preview, then production;
- a failed preview deploy leaves production alone; a failed production deploy says the preview has the new build;
- --no-deploy builds and checks only;
- (d22 batch97 BG3) one refresh at a time: a lock held by a live process is waited for (up to POG_SITE_REFRESH_WAIT,
  then the refresh fails, naming its pid); one whose process is gone is taken over; the lock goes when it ends;
- (d26 batch241) DIST.deployed only while the build in DIST is the one production has (site/chart_deploy.py);
- (d27 batch290) the refresh runs the clean copy of main (tools/clean-main.sh): a source repo (this branch's tracked
  files, committed) with a merge in progress, a tracked file changed and an untracked one builds and deploys main's
  files, with runs/ and the other paths it writes linked to the source's; DIST.last-deploy stays through later
  builds; a folder at the copy's path that is not a worktree is left alone (FAILED, nothing deployed). The other
  cases build in place (a test run without POG_SITE_WORKTREE);
- (d28 batch315) the YouTube list tools/yt_archive.py's follower writes in video-work (POG_SITE_YT_VIDEOS here) is the
  one the build reads; without it, site/content/videos.json.
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
             WRANGLER_LOG=str(tmp / "wrangler.log"), POG_SITE_REFRESH_LOCK=str(tmp / "lock"))
    e.update(env)
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
        assert (tmp / "dist.last-deploy").is_file(), "the last production deploy stays through a --no-deploy build"
        # (d28 batch315) the YouTube list the follower writes outside any checkout reaches the build
        (tmp / "videos-site.json").write_text(json.dumps({"s3": {"id": "VIDs3abcdef", "shift": 2, "title": "Shift 2",
                                                                  "description": "d", "chapters": [], "privacy": "public"}}))
        r, calls = run(tmp, "--no-deploy", POG_SITE_VIDEOS="1", POG_SITE_R2_REFRESH="0",
                       POG_SITE_YT_VIDEOS=str(tmp / "videos-site.json"))
        assert r.returncode == 0 and "YouTube videos from the follower's list (1)" in r.stdout, r.stdout + r.stderr
        assert "VIDs3abcdef" in (tmp / "dist" / "runs" / "long" / "index.html").read_text()
        r, calls = run(tmp, "--no-deploy", POG_SITE_VIDEOS="1", POG_SITE_R2_REFRESH="0",
                       POG_SITE_YT_VIDEOS=str(tmp / "none.json"))
        assert r.returncode == 0 and "YouTube videos from site/content/videos.json" in r.stdout, r.stdout + r.stderr
        assert "VIDs3abcdef" not in (tmp / "dist" / "runs" / "long" / "index.html").read_text()
        # a merge in progress in the source checkout: built from the clean copy of main
        src, wt = tmp / "src", tmp / "wt"
        git = lambda repo, *a: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                               *a], capture_output=True, text=True)  # noqa: E731
        files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True,
                               text=True, check=True).stdout.split("\0")
        for f in files:
            if f and (ROOT / f).is_file() and not (ROOT / f).is_symlink():
                (src / f).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / f, src / f)
        (src / ".gitignore").write_text("runs/\nsite/dist/\nsite/content/r2.json\nsite/og/shifts/\nsite/og/thumbs/\nsite/.wrangler/\n__pycache__/\n")
        git(src, "init", "-q", "-b", "main")
        git(src, "add", "-A")
        assert git(src, "commit", "-qm", "main").returncode == 0
        git(src, "checkout", "-qb", "other")
        (src / "f.txt").write_text("b\n")
        git(src, "add", "f.txt")
        git(src, "commit", "-qm", "b")
        git(src, "checkout", "-q", "main")
        (src / "f.txt").write_text("c\n")
        git(src, "add", "f.txt")
        git(src, "commit", "-qm", "c")
        git(src, "merge", "-q", "other")  # a conflict: the merge stays in progress
        assert git(src, "rev-parse", "-q", "--verify", "MERGE_HEAD").returncode == 0, "the test's merge is in progress"
        css = (src / "site" / "static" / "style.css").read_text()
        (src / "site" / "static" / "style.css").write_text(css + "\n/* a branch's uncommitted change */\n")
        (src / "site" / "untracked.txt").write_text("x\n")
        shutil.rmtree(tmp / "dist", ignore_errors=True)
        r, calls = run(tmp, "--last-run", "s1", POG_SITE_SOURCE=str(src), POG_SITE_WORKTREE=str(wt))
        assert r.returncode == 0 and len(calls) == 2 and "skipped" not in r.stdout, r.stdout + r.stderr
        head = git(src, "rev-parse", "main").stdout.strip()
        assert f"site-refresh: from the clean copy of main {head[:8]} ({wt})" in r.stdout, r.stdout
        assert (tmp / "dist" / "static" / "style.css").read_text() == css, "built from main, not the working tree"
        assert not (wt / "site" / "untracked.txt").exists() and (wt / "runs").is_symlink()
        assert os.readlink(wt / "site" / "live" / "status.json") == str((src / "site" / "live" / "status.json").resolve())
        assert json.loads((tmp / "status.json").read_text())["last_run"]["id"] == "s1"
        assert (tmp / "dist.deployed").is_file() and (tmp / "dist.last-deploy").is_file() and not (tmp / "lock").exists()
        assert git(src, "rev-parse", "-q", "--verify", "MERGE_HEAD").returncode == 0, "the source's merge left alone"
        r, calls = run(tmp, "--no-deploy", POG_SITE_SOURCE=str(src), POG_SITE_WORKTREE=str(wt))   # again: the copy is reused
        assert r.returncode == 0 and "done (--no-deploy)" in r.stdout and (tmp / "dist.last-deploy").is_file(), r.stdout
        plain = tmp / "plain"
        plain.mkdir()
        (plain / "keep.txt").write_text("mine\n")
        r, calls = run(tmp, POG_SITE_SOURCE=str(src), POG_SITE_WORKTREE=str(plain))
        assert r.returncode == 1 and calls == [] and "is not a worktree of" in r.stdout and "FAILED" in r.stdout, r.stdout
        assert (plain / "keep.txt").read_text() == "mine\n"
    print("site refresh: ok (status.json, build, checks, preview then production; failures stop before production; one at a time)")


if __name__ == "__main__":
    main()
