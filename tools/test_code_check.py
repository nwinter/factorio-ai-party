#!/usr/bin/env python3
"""Tests for tools/code_check.py on a scratch git repository (run: python3 tools/test_code_check.py)."""
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "tools", "code_check.py")


def main():
    with tempfile.TemporaryDirectory() as repo:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t", POG_CODE_ROOT=repo)
        git = lambda *a: subprocess.run(["git", "-C", repo, *a], env=env, check=True, capture_output=True, text=True)

        def write(path, text, commit=None):
            full = os.path.join(repo, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "w").write(text)
            if commit:
                git("add", path)
                git("commit", "-q", "-m", commit)

        def check():
            r = subprocess.run([sys.executable, SCRIPT], env=env, capture_output=True, text=True)
            assert r.returncode == 0, r.stderr
            return r.stdout

        git("init", "-q", "-b", "main")
        write("vendor/factorio-harness/host/cli.ts", "a", "host")
        write("README", "r", "readme")
        git("branch", "launch")
        os.makedirs(os.path.join(repo, "vendor/factorio-harness/dist/host"))
        write("vendor/factorio-harness/dist/host/cli.js", "built")   # untracked, as in the repo (gitignored there)
        git("checkout", "-q", "launch")
        out = check()
        assert out.startswith("code ok: launch"), out

        git("checkout", "-q", "main")
        write("vendor/factorio-harness/mod/runtime.lua", "fix", "runtime fix on main")
        git("checkout", "-q", "-b", "eng/harness", "main")
        write("tools/stream/caster.py", "x", "caster fix on a branch")
        write("docs/x.md", "x", "docs only")
        git("checkout", "-q", "launch")
        out = check()
        assert 'WARNING code: main has 1 commit to vendor/factorio-harness or tools/stream' in out, out
        assert '"runtime fix on main"' in out and "this checkout (launch" in out, out
        assert "WARNING code: branch eng/harness has 1 commit" in out and '"caster fix on a branch"' in out, out
        assert "docs only" not in out

        # A host source newer than the build.
        later = time.time() + 5
        os.utime(os.path.join(repo, "vendor/factorio-harness/host/cli.ts"), (later, later))
        assert "WARNING code: the built host (dist" in check()

    run = lambda text: subprocess.run([sys.executable, SCRIPT, "--deploy-reply"], input=text, capture_output=True,
                                      text=True).stdout.strip()
    assert run('{"ok":true,"result":{},"source_sha256":"0123456789abcdef"}\n') == "ok sha256 0123456789ab"
    assert run('{"ok":false,"error":"syntax error near x"}\n').startswith("FAILED (syntax error")
    assert run("").startswith("FAILED (no reply")
    print("code_check: ok")


if __name__ == "__main__":
    main()
