#!/usr/bin/env python3
"""The chart to the site within minutes (d26 batch241 CL, viewer-experience review batch237 finding 4: shift80's site
map kept one chart version for 25-31 min at a time, and shift79's v6401 for 50 min after the 06:11 restart, while the
stream service drew a new version every few seconds). The chart reached the site only with a whole site build
(tools/site-refresh.sh: hourly, at a shift change and when the operator deploys), each about 90 s of build and checks.

Every EVERY seconds, under the site refresh's lock (the same one; a refresh going on: this round is skipped), when the
run's chart (runs/RUN/chart/out/) has a cell or labels file the site's does not have, or a file gone, or a surface's
`complete` changed: puts the chart into the build production has (site/dist/live/chart/, swapped in whole; a build is
production's while site/dist.deployed exists, which tools/site-refresh.sh writes after its production deploy) and
deploys that build to production (wrangler pages deploy, branch main). Most versions are cells drawn again the same
(shift81, 12:00: 2 files changed in 150 s, 25 in 45 min), and Pages uploads only content it does not have, so an update
costs the changed cells. push_live reads the deployed index every minute and sends its version; the page fetches the
cells whose version changed.

    python3 site/chart_deploy.py runs/RUN                 # every 120 s (tools/start-team.sh starts it)
    python3 site/chart_deploy.py runs/RUN --once --no-deploy

Stubs for tests: POG_WRANGLER (the deploy command, split on spaces; default npx wrangler), POG_SITE_OUT (the build),
POG_SITE_REFRESH_LOCK (the lock directory)."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
EVERY = 120.0
PROJECT = "player-of-games"


def lock_path():
    return os.environ.get("POG_SITE_REFRESH_LOCK") or os.path.join(os.environ.get("TMPDIR") or tempfile.gettempdir(),
                                                                   "pog-site-refresh.lock")


def take_lock(path):
    """True when this process now holds tools/site-refresh.sh's lock (a directory with its pid; one whose pid is gone is
    taken over, as the refresh does); False while another holds it."""
    for _ in range(2):
        try:
            os.mkdir(path)
        except FileExistsError:
            try:
                holder = int(open(os.path.join(path, "pid")).read().strip())
                os.kill(holder, 0)
                return False
            except ProcessLookupError:
                shutil.rmtree(path, ignore_errors=True)
                continue
            except (OSError, ValueError):
                return False  # a refresh that has made the directory and not yet written its pid
        open(os.path.join(path, "pid"), "w").write(f"{os.getpid()}\n")
        return True
    return False


def digests(d):
    """{relative path: sha1} of the files under d (not .tmp: a file being written)."""
    out = {}
    for root, _, files in os.walk(d):
        for f in files:
            if f.endswith(".tmp"):
                continue
            p = os.path.join(root, f)
            out[os.path.relpath(p, d)] = hashlib.sha1(open(p, "rb").read()).hexdigest()
    return out


def complete(d):
    """{surface: complete} from d/index.json ({} without one)."""
    try:
        idx = json.loads((Path(d) / "index.json").read_text())
        return {k: x.get("complete") is True for k, x in idx["surfaces"].items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def plan(src, dest):
    """What the site lacks of src (the run's chart/out/) against dest (the build's live/chart/, the one production has):
    (cells and labels new or changed, their bytes, files gone, whether a surface's `complete` differs). The index alone
    (new versions and read ticks of cells drawn again the same) is no reason to deploy."""
    before, after = digests(dest) if Path(dest).is_dir() else {}, digests(src)
    changed = [k for k, h in after.items() if k != "index.json" and before.get(k) != h]
    return (changed, sum(os.path.getsize(Path(src) / k) for k in changed), [k for k in before if k not in after],
            complete(src) != complete(dest))


def stage(src, dist):
    """Puts src at dist/live/chart/ in place of the one there, swapped in whole."""
    dest = Path(dist) / "live" / "chart"
    new, old = dest.with_name("chart.new"), dest.with_name("chart.old")
    for d in (new, old):
        shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(src, new, ignore=shutil.ignore_patterns("*.tmp"))
    if dest.exists():
        os.rename(dest, old)
    os.rename(new, dest)
    shutil.rmtree(old, ignore_errors=True)


def run_once(run_dir, dist, st, deploy=True, wrangler=None, runner=subprocess.run, clock=time.time):
    """One round; the log line, or None when there is nothing to say. st (kept between rounds): pending, a chart staged
    into the build and not deployed (a failed deploy: the next round deploys it again); said, the last waiting line
    (said once)."""
    src, dist = Path(run_dir) / "chart" / "out", Path(dist)
    try:
        v = json.loads((src / "index.json").read_text())["v"]
    except (OSError, ValueError, KeyError, TypeError):
        return None  # the service has drawn nothing in this run yet

    def once(line):
        if st.get("said") == line:
            return None
        st["said"] = line
        return line
    if not (dist / "index.html").is_file() or not Path(str(dist) + ".deployed").is_file():
        return once(f"waiting: {dist} is not a build production has (tools/site-refresh.sh makes one)")
    lock = lock_path()
    if not take_lock(lock):
        return once(f"waiting: a site refresh holds {lock}")
    try:
        st["said"] = None
        t0 = clock()
        changed, size, gone, flips = plan(src, dist / "live" / "chart")
        if not (changed or gone or flips or st.get("pending")):
            return None
        stage(src, dist)
        st["pending"] = True
        line = (f"v{v} ({Path(run_dir).name}): {len(changed)} files new or changed, {size:,} bytes"
                + (f", {len(gone)} gone" if gone else "") + (", a surface's `complete` changed" if flips else ""))
        if not deploy:
            return line + ", staged (--no-deploy)"
        if not wrangler and not os.environ.get("POG_WRANGLER") and os.environ.get("POG_TEST") == "1":
            return line + "; deploy refused: POG_TEST=1 without POG_WRANGLER (a test never deploys the site)"
        cmd = (wrangler or (os.environ.get("POG_WRANGLER") or "npx wrangler").split()) + [
            "pages", "deploy", str(dist), "--project-name", PROJECT, "--branch", "main", "--commit-dirty=true"]
        try:
            r = runner(cmd, cwd=str(REPO), capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired) as e:
            return line + f"; deploy FAILED: {type(e).__name__}: {e}"[:200]
        if r.returncode:
            tail = ((r.stderr or "") + (r.stdout or "")).strip().splitlines()[-1:] or [""]
            return line + f"; deploy FAILED (exit {r.returncode}): {tail[0][:160]}"
        st["pending"] = False
        m = re.search(r"Uploaded (\d+) files \((\d+) already uploaded\)", r.stdout or "")
        return line + (f", {m.group(1)} uploaded" if m else "") + f", deployed in {clock() - t0:.1f} s"
    finally:
        shutil.rmtree(lock, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="runs/RUN: the run whose chart the stream service draws")
    ap.add_argument("--every", type=float, default=EVERY, help="seconds between rounds")
    ap.add_argument("--out", default=os.environ.get("POG_SITE_OUT") or str(SITE / "dist"), help="the site build")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--no-deploy", action="store_true", help="stage the chart into the build only")
    a = ap.parse_args()
    st = {}
    print(f"[chart-deploy] {time.strftime('%H:%M:%S')} start: {a.run}/chart/out -> {a.out}/live/chart/, every {a.every:g} s", flush=True)
    while True:
        line = run_once(a.run, a.out, st, deploy=not a.no_deploy)
        if line:
            print(f"[chart-deploy] {time.strftime('%H:%M:%S')} {line}", flush=True)
        if a.once:
            return 0 if line is None or "FAILED" not in line else 1
        time.sleep(a.every)


if __name__ == "__main__":
    sys.exit(main())
