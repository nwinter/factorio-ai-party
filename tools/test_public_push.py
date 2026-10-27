#!/usr/bin/env python3
"""tools/public-push.sh with a stub sync (a plain bare clone of the source's main, no scrub) and a local bare repo as the
public remote: python3 tools/test_public_push.py

- a first run syncs and pushes main as a fast-forward; the run's summary is copied to DIR/public-sync-summary.md;
- a second run with main unchanged says "up to date" and runs no sync;
- a new commit on main: the next run pushes only it (old..new);
- a sync that exits 1 (scan findings): FAILED, nothing pushed; with main unchanged the next run skips without another
  FAILED line; a new commit tries again;
- a public main that is not an ancestor of the new main: FAILED, the remote keeps its main (never forced);
- while MERGE_HEAD exists in the source checkout: one "skipped" line, no sync, nothing pushed;
- a lock held by a live process: skipped; a lock whose process is gone is taken over;
- only the two newest run folders are kept;
- under POG_TEST=1 (tools/testsafe.py) without POG_PUBLIC_REMOTE and POG_PUBLIC_SOURCE: refused, nothing made.
"""
import subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import testsafe  # noqa: E402

SCRIPT = ROOT / "tools" / "public-push.sh"

STUB = """#!/usr/bin/env bash
# stub public_sync.py: WORKDIR --source SRC --ref main
work=$1 src=$3
echo "$work" >> "$STUB_LOG"
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
        src, remote, state = tmp / "src", tmp / "public.git", tmp / "state"
        subprocess.run(["git", "init", "-q", "-b", "main", str(src)], check=True)
        c1 = commit(src, "a")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
        git(src, "push", "-q", str(remote), "main")
        c2 = commit(src, "b")
        stub = tmp / "stub.sh"
        stub.write_text(STUB)
        stub.chmod(0o755)
        log, failflag = tmp / "stub.log", tmp / "fail"
        env = testsafe.env(POG_PUBLIC_SOURCE=src, POG_PUBLIC_REMOTE=remote, POG_PUBLIC_DIR=state, POG_PUBLIC_SYNC=stub,
                           STUB_LOG=log, STUB_FAIL=failflag)
        # a test run without both paths refuses: no push to the live remote
        r = subprocess.run(["bash", str(SCRIPT)], env=testsafe.env(POG_PUBLIC_DIR=state), capture_output=True, text=True)
        assert r.returncode == 2 and "POG_TEST=1: no public push" in r.stdout and not state.exists(), r.stdout

        def run():
            before = log.read_text() if log.exists() else ""
            r = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)
            synced = (log.read_text() if log.exists() else "") != before
            return r, synced

        r, synced = run()
        assert r.returncode == 0 and synced, r.stdout + r.stderr
        assert git(remote, "rev-parse", "main") == c2
        assert f"pushed {c1[:8]}..{c2[:8]} (1 commits)" in r.stdout, r.stdout
        assert all(" public-push: " in l for l in r.stdout.splitlines()), r.stdout
        assert (state / "public-sync-summary.md").read_text().startswith(f"# Public history of main ({c2[:8]})")

        r, synced = run()
        assert r.returncode == 0 and not synced and "up to date: main " + c2[:8] in r.stdout, r.stdout

        c3 = commit(src, "c")
        r, synced = run()
        assert r.returncode == 0 and synced and f"pushed {c2[:8]}..{c3[:8]} (1 commits)" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == c3

        failflag.write_text("1")
        c4 = commit(src, "d")
        r, synced = run()
        assert r.returncode == 1 and synced and "public-push: FAILED: sync exit 1, 1 scan findings; nothing pushed" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == c3, "a scan finding pushes nothing"
        r, synced = run()
        assert r.returncode == 0 and not synced and "FAILED" not in r.stdout and f"main {c4[:8]} is the commit that failed" in r.stdout, r.stdout
        failflag.unlink()
        c5 = commit(src, "e")
        r, synced = run()
        assert r.returncode == 0 and f"pushed {c3[:8]}..{c5[:8]} (2 commits)" in r.stdout, r.stdout

        # the public main moved off main's line: never forced
        other = tmp / "other"
        subprocess.run(["git", "clone", "-q", str(remote), str(other)], check=True)
        stray = commit(other, "stray")
        git(other, "push", "-q", "origin", "main")
        c6 = commit(src, "f")
        r, synced = run()
        assert r.returncode == 1 and f"is not an ancestor of {c6[:8]}" in r.stdout and "public-push: FAILED" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == stray
        git(remote, "update-ref", "refs/heads/main", c5)

        # a merge in progress in the source checkout
        c7 = commit(src, "g")
        (src / ".git" / "MERGE_HEAD").write_text(c7 + "\n")
        r, synced = run()
        assert r.returncode == 0 and not synced and "skipped: a merge is in progress" in r.stdout, r.stdout
        assert git(remote, "rev-parse", "main") == c5
        (src / ".git" / "MERGE_HEAD").unlink()

        # a lock held by a live process, then by a gone one
        (state / "lock").mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        (state / "lock" / "pid").write_text(str(sleeper.pid))
        r, synced = run()
        assert r.returncode == 0 and not synced and f"another run (pid {sleeper.pid})" in r.stdout, r.stdout
        sleeper.kill()
        sleeper.wait()
        r, synced = run()
        assert r.returncode == 0 and synced and f"pushed {c5[:8]}..{c7[:8]} (2 commits)" in r.stdout, r.stdout
        assert not (state / "lock").exists()
        assert len(list((state / "runs").iterdir())) == 2, list((state / "runs").iterdir())
    print("test_public_push: ok")


if __name__ == "__main__":
    sys.exit(main())
