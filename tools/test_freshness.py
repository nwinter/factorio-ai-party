#!/usr/bin/env python3
"""tools/freshness.py: python3 tools/test_freshness.py

- both fresh: one "freshness: ok" line, exit 0;
- the site's last production deploy or the public repo's last sync older than --max-age, or not on record: a
  "freshness: STALE site" / "STALE public repo" line each, exit 1;
- DIST.deployed stands in for DIST.last-deploy until there is one; --log appends the same lines.
"""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "freshness.py"


def run(*args):
    r = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True, timeout=60,
                       env={k: v for k, v in os.environ.items() if not k.startswith("POG_")})
    return r.returncode, r.stdout.splitlines()


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))[:-2] + ":" + time.strftime("%z", time.localtime(t))[-2:]


def main():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        stamp, status, log = d / "dist.last-deploy", d / "status.json", d / "public-push.log"
        now = time.time()
        stamp.write_text(f"{int(now - 600)}\n")
        status.write_text(json.dumps({"ok": {"t": iso(now - 1200), "public": "a" * 40}}))
        rc, out = run("--site-stamp", stamp, "--public-status", status, "--log", log)
        assert rc == 0 and len(out) == 1 and " freshness: ok (site last production deploy " in out[0] \
            and "public repo last successful sync" in out[0], out
        assert log.read_text().splitlines() == out
        stamp.write_text(f"{int(now - 3 * 3600)}\n")
        rc, out = run("--site-stamp", stamp, "--public-status", status)
        assert rc == 1 and len(out) == 1 and " freshness: STALE site: last production deploy " in out[0] \
            and "(3.0 h ago, limit 2 h)" in out[0], out
        rc, out = run("--site-stamp", stamp, "--public-status", status, "--max-age", 4 * 3600)
        assert rc == 0, out
        stamp.unlink()
        (d / "dist.deployed").write_text(f"{int(now - 60)}\n")   # before the first refresh that writes last-deploy
        status.write_text(json.dumps({"problem": {"t": iso(now), "kind": "delayed"}}))
        rc, out = run("--site-stamp", stamp, "--public-status", status, "--log", log)
        assert rc == 1 and out == [out[0][:8] + " freshness: STALE public repo: no last successful sync on record (limit 2 h)"], out
        (d / "dist.deployed").unlink()
        rc, out = run("--site-stamp", stamp, "--public-status", d / "missing.json")
        assert rc == 1 and len(out) == 2 and "STALE site: no last production deploy on record" in out[0], out
        assert len(log.read_text().splitlines()) == 2
    print("freshness: ok")


if __name__ == "__main__":
    main()
