#!/usr/bin/env python3
"""tools/public-push.sh with a stub sync (a plain bare clone of the source's main, no scrub) and a local bare repo as the
public remote: python3 tools/test_public_push.py

- a first run syncs and pushes main as a fast-forward; the run's summary is copied to DIR/public-sync-summary.md;
- a second run with main unchanged says "up to date" and runs no sync;
- a new commit on main: the next run pushes only it (old..new);
- a sync that exits 1 (scan findings): FAILED, nothing pushed; with main unchanged the next run skips (exit 75, the
  loop looks again in 10 min) without another FAILED line; a new commit tries again;
- a public main that is not an ancestor of the new main: FAILED, the remote keeps its main (never forced);
- (batch290) the sync runs in the clean worktree at main's commit, made on the first run: a merge in progress in the
  source checkout (MERGE_HEAD, a tracked file changed, an untracked one) changes nothing, and the run pushes; a folder
  at the worktree's path that is not a worktree of the source is left alone (FAILED, exit 75);
- a lock held by a live process: skipped, exit 75; a lock whose process is gone is taken over;
- DIR/status.json: the last success (public main, the main it came from, commits pushed), when it last checked, the
  newest failure or delay with a fixed reason and no paths;
- the loop (--start-loop): one per DIR; after a skip it runs again in POG_PUBLIC_RETRY s, after a push it waits
  POG_PUBLIC_EVERY; its lines and tools/freshness.py's after each run also go to the newest started run's
  public-push.log; --check-loop, --stop-loop;
- only the two newest run folders are kept;
- under POG_TEST=1 (tools/testsafe.py) without POG_PUBLIC_REMOTE, POG_PUBLIC_SOURCE, POG_PUBLIC_WORKTREE and
  POG_PUBLIC_DIR: refused, nothing made.
"""
import json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import testsafe  # noqa: E402

SCRIPT = ROOT / "tools" / "public-push.sh"

STUB = """#!/usr/bin/env bash
# stub public_sync.py: WORKDIR --source SRC --ref main
work=$1 src=$3
echo "$work" >> "$STUB_LOG"
echo "$(pwd -P)|$(cat a)|$(ls | tr "\n" " ")" >> "$STUB_SEEN"   # where it ran and what it saw there
git clone -q --bare --single-branch --no-tags --branch main "file://$src" "$work" || exit 2
echo "# Public history of main ($(git -C "$src" rev-parse main | cut -c1-8))" > "$(dirname "$work")/public-sync-summary.md"
if [ -f "$STUB_FAIL" ]; then echo "docs/x.md:3: secret value config/pog/key"; exit 1; fi
echo "main $(git -C "$work" rev-parse main)"
"""


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, name):
    (repo / name).write_text(name + "\n")
    git(repo, "add", name)
    git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", name)
    return git(repo, "rev-parse", "HEAD")


def main():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        src, remote, state, wt = tmp / "src", tmp / "public.git", tmp / "state", tmp / "wt"
        subprocess.run(["git", "init", "-q", "-b", "main", str(src)], check=True)
        c1 = commit(src, "a")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
        git(src, "push", "-q", str(remote), "main")
        c2 = commit(src, "b")
        stub = tmp / "stub.sh"
        stub.write_text(STUB)
        stub.chmod(0o755)
        log, seen, failflag = tmp / "stub.log", tmp / "seen.log", tmp / "fail"
        env = testsafe.env(POG_PUBLIC_SOURCE=src, POG_PUBLIC_REMOTE=remote, POG_PUBLIC_DIR=state, POG_PUBLIC_SYNC=stub,
                           POG_PUBLIC_WORKTREE=wt, STUB_LOG=log, STUB_SEEN=seen, STUB_FAIL=failflag)
        # a test run without all four paths refuses: no push to the live remote, nothing made in the live checkout
        for drop in ("POG_PUBLIC_REMOTE", "POG_PUBLIC_SOURCE", "POG_PUBLIC_WORKTREE", "POG_PUBLIC_DIR"):
            for args in ([], ["--start-loop", str(tmp)]):
                r = subprocess.run(["bash", str(SCRIPT), *args], env={k: v for k, v in env.items() if k != drop},
                                   capture_output=True, text=True)
                assert r.returncode == 2 and "POG_TEST=1: no public push" in r.stdout, (drop, r.stdout)
        assert not state.exists() and not wt.exists()

        def run():
            before = log.read_text() if log.exists() else ""
            r = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)
            synced = (log.read_text() if log.exists() else "") != before
            return r, synced

        def status():
            return json.loads((state / "status.json").read_text())

        r, synced = run()
        assert r.returncode == 0 and synced, r.stdout + r.stderr
        assert git(remote, "rev-parse", "main") == c2
        assert f"pushed {c1[:8]}..{c2[:8]} (1 commits)" in r.stdout and "made the clean copy of main" in r.stdout, r.stdout
        assert all(" public-push: " in l for l in r.stdout.splitlines()), r.stdout
        assert (state / "public-sync-summary.md").read_text().startswith(f"# Public history of main ({c2[:8]})")
        assert git(wt, "rev-parse", "HEAD") == c2 and seen.read_text().split("|")[0] == str(wt.resolve()), seen.read_text()
        st = status()
        assert st["ok"]["public"] == c2 and st["ok"]["source"] == c2 and st["ok"]["pushed"] == 1, st
        assert "problem" not in st and st["checked"] == st["ok"]["t"] and st["every_s"] == 3600 and st["retry_s"] == 600, st

        r, synced = run()
        assert r.returncode == 0 and not synced and "up to date: main " + c2[:8] in r.stdout, r.stdout

        shutil.rmtree(wt)   # a clean copy deleted by hand (still registered): made again in its place
        c3 = commit(src, "c")
        r, synced = run()
        assert "made the clean copy of main" in r.stdout and git(wt, "rev-parse", "HEAD") == c3, r.stdout
        assert r.returncode == 0 and synced and f"pushed {c2[:8]}..{c3[:8]} (1 commits)" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == c3

        failflag.write_text("1")
        c4 = commit(src, "d")
        r, synced = run()
        assert r.returncode == 1 and synced and "public-push: FAILED: sync exit 1, 1 scan findings; nothing pushed" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == c3, "a scan finding pushes nothing"
        st = status()
        assert st["problem"]["kind"] == "failed" and st["problem"]["source"] == c4, st
        assert st["problem"]["reason"] == f"the scan found 1 findings in main {c4[:8]}; nothing pushed", st
        assert st["ok"]["public"] == c3, st
        r, synced = run()
        assert r.returncode == 75 and not synced and "FAILED" not in r.stdout and f"main {c4[:8]} is the commit that failed" in r.stdout, r.stdout
        failflag.unlink()
        c5 = commit(src, "e")
        r, synced = run()
        assert r.returncode == 0 and f"pushed {c3[:8]}..{c5[:8]} (2 commits)" in r.stdout, r.stdout
        st = status()
        assert st["ok"]["public"] == c5 and st["problem"]["source"] == c4 and st["problem"]["t"] <= st["ok"]["t"], st

        # the public main moved off main's line: never forced
        other = tmp / "other"
        subprocess.run(["git", "clone", "-q", str(remote), str(other)], check=True)
        stray = commit(other, "stray")
        git(other, "push", "-q", "origin", "main")
        c6 = commit(src, "f")
        r, synced = run()
        assert r.returncode == 1 and f"is not an ancestor of {c6[:8]}" in r.stdout and "public-push: FAILED" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == stray
        assert status()["problem"]["reason"] == "the public main is not an ancestor of the new one (not a fast-forward); nothing pushed"
        git(remote, "update-ref", "refs/heads/main", c5)

        # a merge in progress in the source checkout (as the gate leaves it): the run syncs from the clean copy
        c7 = commit(src, "g")
        (src / ".git" / "MERGE_HEAD").write_text(c6 + "\n")
        (src / "a").write_text("a branch's uncommitted change\n")
        (src / "untracked.py").write_text("x\n")
        r, synced = run()
        assert r.returncode == 0 and synced and f"pushed {c5[:8]}..{c7[:8]} (2 commits)" in r.stdout, r.stdout
        where, a, files = seen.read_text().splitlines()[-1].split("|")
        assert where == str(wt.resolve()) and a == "a" and "untracked.py" not in files, seen.read_text()
        assert git(remote, "rev-parse", "main") == c7
        (src / ".git" / "MERGE_HEAD").unlink()
        git(src, "checkout", "-q", "--", "a")

        # a lock held by a live process, then by a gone one
        (state / "lock").mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        (state / "lock" / "pid").write_text(str(sleeper.pid))
        c8 = commit(src, "h")
        r, synced = run()
        assert r.returncode == 75 and not synced and f"another run (pid {sleeper.pid})" in r.stdout, r.stdout
        assert status()["problem"] == {"t": status()["problem"]["t"], "kind": "delayed",
                                       "reason": "another public push was still running", "source": ""}, status()
        sleeper.kill()
        sleeper.wait()
        (wt / "stray.txt").write_text("left by hand\n")   # the next run cleans the copy
        r, synced = run()
        assert r.returncode == 0 and synced and f"pushed {c7[:8]}..{c8[:8]} (1 commits)" in r.stdout, r.stdout
        assert not (state / "lock").exists() and not (wt / "stray.txt").exists()
        assert len(list((state / "runs").iterdir())) == 2, list((state / "runs").iterdir())
        text = (state / "status.json").read_text()
        assert str(tmp) not in text and "/Users/" not in text, text   # no paths for the site

        # a folder at the worktree's path that is not a worktree of the source: left alone
        env2 = dict(env, POG_PUBLIC_WORKTREE=str(tmp / "plain"))
        (tmp / "plain").mkdir()
        (tmp / "plain" / "keep.txt").write_text("mine\n")
        c9 = commit(src, "i")
        r = subprocess.run(["bash", str(SCRIPT)], env=env2, capture_output=True, text=True, timeout=120)
        assert r.returncode == 75 and "is not a worktree of" in r.stdout and "FAILED" in r.stdout, r.stdout
        assert (tmp / "plain" / "keep.txt").read_text() == "mine\n" and status()["problem"]["reason"] == \
            "the clean copy of main could not be made", status()

        # the loop: one per DIR, 0.3 s after a skip, 30 s after a push; lines in the run's log too
        rundir = tmp / "runs" / "shift99"
        rundir.mkdir(parents=True)
        (tmp / "dist.last-deploy").write_text(f"{int(time.time())}\n")
        lenv = dict(env, POG_PUBLIC_FIRST="0.2", POG_PUBLIC_RETRY="0.3", POG_PUBLIC_EVERY="30",
                    POG_SITE_STAMP=str(tmp / "dist.last-deploy"))
        (state / "lock").mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        (state / "lock" / "pid").write_text(str(sleeper.pid))
        try:
            r = subprocess.run(["bash", str(SCRIPT), "--start-loop", str(rundir)], env=lenv, capture_output=True,
                               text=True, timeout=30)
            assert r.returncode == 0 and "public-push loop started: pid" in r.stdout, r.stdout
            pid = int((state / "loop.pid").read_text())
            r = subprocess.run(["bash", str(SCRIPT), "--start-loop", str(rundir)], env=lenv, capture_output=True, text=True)
            assert f"public-push loop running (pid {pid}): kept" in r.stdout, r.stdout
            r = subprocess.run(["bash", str(SCRIPT), "--check-loop"], env=lenv, capture_output=True, text=True)
            assert r.returncode == 0 and f"running (pid {pid}" in r.stdout, r.stdout
            deadline = time.time() + 20
            while time.time() < deadline and (state / "public-push.log").read_text().count("skipped: another run") < 3:
                time.sleep(0.1)
            assert (state / "public-push.log").read_text().count("skipped: another run") >= 3, (state / "public-push.log").read_text()
            assert "skipped: another run" in (rundir / "public-push.log").read_text()
            sleeper.kill()
            sleeper.wait()
            while time.time() < deadline and "done in" not in (state / "public-push.log").read_text():
                time.sleep(0.1)
            assert f"..{c9[:8]} (1 commits)" in (rundir / "public-push.log").read_text(), (state / "public-push.log").read_text()
            assert git(remote, "rev-parse", "main") == c9
            while time.time() < deadline and "freshness: ok" not in (rundir / "public-push.log").read_text():
                time.sleep(0.1)
            # after each run: tools/freshness.py, in the loop's log and the run's (the site stamp is fresh, the public
            # status had a sync from the runs above)
            assert "freshness: ok (site last production deploy" in (rundir / "public-push.log").read_text()
            n = (state / "public-push.log").read_text().count("public-push:")
            time.sleep(1.5)   # after a push it waits POG_PUBLIC_EVERY
            assert (state / "public-push.log").read_text().count("public-push:") == n, (state / "public-push.log").read_text()
        finally:
            r = subprocess.run(["bash", str(SCRIPT), "--stop-loop"], env=lenv, capture_output=True, text=True)
            if sleeper.poll() is None:
                sleeper.kill()
        assert "stopped the loop" in r.stdout, r.stdout
        time.sleep(0.3)
        r = subprocess.run(["bash", str(SCRIPT), "--check-loop"], env=lenv, capture_output=True, text=True)
        assert r.returncode == 1 and "not running" in r.stdout, r.stdout
        git(src, "worktree", "remove", "--force", str(wt))
    print("test_public_push: ok")


if __name__ == "__main__":
    sys.exit(main())
