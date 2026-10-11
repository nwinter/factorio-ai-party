#!/usr/bin/env python3
"""Is this run launching from the code the fixes are in? For tools/start-team.sh (docs/studies/shake5.md, P1 item 7:
shake5 ran 41f8a20 while three harness fixes for shake4 sat on eng/harness3, merged an hour later).

  tools/code_check.py [--hours N]

Checks the harness (vendor/factorio-harness) and the stream helpers (tools/stream), read-only:
- main has commits to them that this checkout's HEAD lacks;
- another local branch has commits to them from the last N hours (default 24) that neither HEAD nor main has;
- the built host (vendor/factorio-harness/dist/host/cli.js, what bin/fh runs) is older than its sources
  (vendor/factorio-harness/host/*.ts): `npm run build` in vendor/factorio-harness.
The Lua runtime and the mod are deployed from this checkout at each start (fh deploy, scp), so they follow HEAD.
Prints one line per finding, "WARNING ..." first, then "code ok" when there is nothing to warn about.
"""
import glob
import json
import os
import subprocess
import sys
import time

ROOT = os.environ.get("POG_CODE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATHS = ["vendor/factorio-harness", "tools/stream"]


def git(*args):
    r = subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def missing(ref, since=None, not_main=False):
    """Commits on ref touching PATHS that HEAD (and with not_main, main) lacks: [(hash, epoch, subject)], newest first."""
    args = ["log", "--no-merges", "--format=%h %ct %s", ref, "^HEAD"] + (["^main"] if not_main else [])
    if since:
        args.append(f"--since={int(since)}")
    out = git(*args, "--", *PATHS)
    rows = []
    for line in out.splitlines():
        h, t, s = line.split(" ", 2)
        rows.append((h, int(t), s))
    return rows


def describe(rows):
    h, t, s = rows[0]
    return (f"{len(rows)} commit{'s' if len(rows) > 1 else ''} to {' or '.join(PATHS)}, newest {h} "
            f"{time.strftime('%m-%d %H:%M', time.localtime(t))} \"{s[:70]}\"")


def check(hours=24):
    warnings = []
    head = git("rev-parse", "--short", "HEAD")
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    main_rows = missing("main") if git("rev-parse", "--verify", "-q", "main") else []
    if main_rows:
        warnings.append(f"WARNING code: main has {describe(main_rows)} that this checkout ({branch} {head}) lacks")
    since = time.time() - hours * 3600
    for ref in git("for-each-ref", "--format=%(refname:short)", "refs/heads").splitlines():
        if ref in ("main", branch):
            continue
        rows = missing(ref, since, not_main=bool(main_rows is not None and git("rev-parse", "--verify", "-q", "main")))
        if rows:
            warnings.append(f"WARNING code: branch {ref} has {describe(rows)} that neither this checkout nor main has")
    host = glob.glob(os.path.join(ROOT, "vendor/factorio-harness/host/*.ts"))
    built = os.path.join(ROOT, "vendor/factorio-harness/dist/host/cli.js")
    if host:
        newest = max(host, key=os.path.getmtime)
        if not os.path.exists(built):
            warnings.append("WARNING code: vendor/factorio-harness/dist/host/cli.js is missing; run `npm run build` in "
                            "vendor/factorio-harness")
        elif os.path.getmtime(newest) > os.path.getmtime(built):
            warnings.append(f"WARNING code: the built host (dist, {time.strftime('%m-%d %H:%M', time.localtime(os.path.getmtime(built)))}) "
                            f"is older than host/{os.path.basename(newest)} "
                            f"({time.strftime('%m-%d %H:%M', time.localtime(os.path.getmtime(newest)))}); fh runs the old "
                            "code until `npm run build` in vendor/factorio-harness")
    return warnings or [f"code ok: {branch} {head} has main's and recent branches' harness and stream commits, "
                        "and the built host is newer than its sources"]


def deploy_reply(text):
    """`fh deploy --format json` stdout -> "ok sha256 <12 hex>" or "FAILED ..." for start.log."""
    try:
        r = json.loads(text.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return f"FAILED (no reply: {text.strip()[:120]!r})"
    if not r.get("ok"):
        return f"FAILED ({str(r.get('error'))[:160]})"
    return f"ok sha256 {str(r.get('source_sha256'))[:12]}"


def main():
    if sys.argv[1:2] == ["--deploy-reply"]:
        print(deploy_reply(sys.stdin.read()))
        return
    hours = 24
    if "--hours" in sys.argv:
        hours = float(sys.argv[sys.argv.index("--hours") + 1])
    for line in check(hours):
        print(line)


if __name__ == "__main__":
    main()
