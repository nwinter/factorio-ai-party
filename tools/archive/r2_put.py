#!/usr/bin/env python3
"""Upload a folder of archive files to the R2 bucket under a key prefix (batch126 CI4), with wrangler:

    python3 tools/archive/r2_put.py DIR PREFIX [--bucket pog-archive] [--jobs 4] [--dry-run]

Each file under DIR goes to BUCKET/PREFIX/<its path under DIR> with its content type and a cache rule: segments,
init files, clips and captions never change once written (a year, immutable); playlists and JSON may be rebuilt
(5 minutes). Runs `npx wrangler r2 object put --remote` from site/worker (the site's Cloudflare account; wrangler must
be logged in). Never for masters: the bucket holds web renditions only (operator d23 14:45).

Bucket layout (report-d20-batch126.md):
  SHIFT/hls/master.m3u8, SHIFT/hls/{1080,540}/{init.mp4,segNNNN.m4s,index.m3u8}   a whole shift
  SHIFT/sample-HHMM/...                                                           a test sample (same inside)
  SHIFT/captions.vtt, SHIFT/index.json                                            per shift
  SHIFT/clips/CLIP-ID.mp4, SHIFT/clips/CLIP-ID.vtt                                clips (ids from the index)
  player/index.html                                                               the prototype page
"""
import argparse
import functools
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
TYPES = {".m3u8": "application/vnd.apple.mpegurl", ".m4s": "video/iso.segment", ".mp4": "video/mp4",
         ".vtt": "text/vtt; charset=utf-8", ".json": "application/json", ".html": "text/html; charset=utf-8",
         ".jpg": "image/jpeg", ".png": "image/png"}
LONG = "public, max-age=31536000, immutable"
SHORT = "public, max-age=300"
MASTER_SUFFIXES = {".mkv", ".mov", ".flv"}


def plan(root, prefix):
    """[(file, key, content type, cache control)] for every file under root; masters refused."""
    out = []
    for p in sorted(Path(root).rglob("*")):
        if not p.is_file() or p.name.startswith("."):
            continue
        if p.suffix.lower() in MASTER_SUFFIXES:
            raise SystemExit(f"{p}: a master or recording; the bucket holds web renditions only")
        ctype = TYPES.get(p.suffix.lower())
        if not ctype:
            continue
        key = f"{prefix.strip('/')}/{p.relative_to(root).as_posix()}"
        cache = SHORT if p.suffix.lower() in (".m3u8", ".json", ".html") else LONG
        out.append((p, key, ctype, cache))
    return out


@functools.lru_cache(maxsize=1)
def wrangler(npx_cache=Path.home() / ".npm" / "_npx"):
    """The command that runs wrangler: node on npx's cached copy (the newest there) when there is one, which saves the
    npm wrapper's start (about 2.1 s of CPU a call against 0.7 s, batch211), else `npx wrangler`."""
    best = None
    for pkg in Path(npx_cache).glob("*/node_modules/wrangler/package.json"):
        try:
            v = tuple(int(x) for x in json.loads(pkg.read_text())["version"].split("."))
        except (OSError, ValueError, KeyError):
            continue
        js = pkg.parent / "bin" / "wrangler.js"
        if js.exists() and (best is None or v > best[0]):
            best = (v, js)
    return ["node", str(best[1])] if best else ["npx", "wrangler"]


def put(bucket, item, tries=3, nice=0):
    """One object; the API answers an occasional 502, so up to `tries` attempts. `nice` lowers wrangler's priority."""
    p, key, ctype, cache = item
    cmd = (["nice", "-n", str(nice)] if nice else []) + wrangler() + [
        "r2", "object", "put", f"{bucket}/{key}", "--file", str(Path(p).resolve()), "--remote",
        "--content-type", ctype, "--cache-control", cache]
    for k in range(tries):
        r = subprocess.run(cmd, cwd=REPO / "site" / "worker", capture_output=True, text=True)
        if r.returncode == 0:
            return key, 0, []
        time.sleep(2 * (k + 1))
    err = [x for x in (r.stderr + r.stdout).splitlines() if "ERROR" in x][:1]
    return key, r.returncode, err


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("prefix")
    ap.add_argument("--bucket", default="pog-archive")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only", nargs="+", help="put just these keys (a rerun of the failed ones)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    items = [it for it in plan(a.dir, a.prefix) if not a.only or it[1] in a.only]
    total = sum(p.stat().st_size for p, *_ in items)
    print(f"{len(items)} files, {total / 1e6:.1f} MB to {a.bucket}/{a.prefix.strip('/')}/")
    if a.dry_run:
        for p, key, ctype, cache in items:
            print(f"{key}\t{ctype}\t{cache}")
        return
    failed = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for key, code, err in ex.map(lambda it: put(a.bucket, it), items):
            if code:
                failed.append(key)
                print(f"failed {key}: {err}", file=sys.stderr)
    print(f"done: {len(items) - len(failed)} put, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
