#!/usr/bin/env python3
"""How old the public site and the public repo are (d27 batch290: the site stayed at its 15:19 build and the public
repo at Oct 18 while every hourly run skipped a gate merge, and nothing said so):

  tools/freshness.py [--max-age SECONDS] [--log FILE] [--site-stamp FILE] [--public-status FILE]

One line each, "HH:MM:SS freshness: STALE site: ..." or "... STALE public repo: ...", when the last production deploy of
the site (SITE_STAMP: POG_SITE_STAMP, else site/dist.last-deploy, which tools/site-refresh.sh writes after each one,
epoch seconds; site/dist.deployed until there is one) or the last successful public repo sync (PUBLIC_STATUS:
tools/public-push.sh's status.json, ok.t) is older than --max-age (7200) or missing; else one "freshness: ok" line
with both times. Exit 1 when anything is stale. --log also
appends the lines to FILE. tools/public-push.sh's loop runs it after each run (every 10 to 60 minutes), so the lines
are in its log and the newest run's public-push.log, where the operator's watcher reads them.
"""
import argparse
import datetime
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ages(site_stamp, public_status, now=None):
    """{name: (seconds old or None when unknown, when as datetime or None, what)}."""
    now = time.time() if now is None else now
    out = {}
    out["site"] = (None, None, "last production deploy")
    # DIST.deployed (gone while a build runs) until the first refresh that writes DIST.last-deploy
    for f in (site_stamp, site_stamp[:-len(".last-deploy")] + ".deployed" if site_stamp.endswith(".last-deploy") else None):
        try:
            t = float(open(f).read().split()[0])
            out["site"] = (now - t, datetime.datetime.fromtimestamp(t), "last production deploy")
            break
        except (OSError, ValueError, IndexError, TypeError):
            pass
    try:
        t = datetime.datetime.fromisoformat(json.load(open(public_status))["ok"]["t"])
        out["public repo"] = (now - t.timestamp(), t.astimezone().replace(tzinfo=None), "last successful sync")
    except (OSError, ValueError, KeyError, TypeError):
        out["public repo"] = (None, None, "last successful sync")
    return out


def lines(a, max_age, stamp=None):
    stamp = stamp or time.strftime("%H:%M:%S")
    stale = []
    for name, (age, at, what) in a.items():
        if age is None:
            stale.append(f"{stamp} freshness: STALE {name}: no {what} on record (limit {max_age / 3600:g} h)")
        elif age > max_age:
            stale.append(f"{stamp} freshness: STALE {name}: {what} {at:%a %H:%M} ({age / 3600:.1f} h ago, limit "
                         f"{max_age / 3600:g} h)")
    if stale:
        return stale, True
    return [f"{stamp} freshness: ok (" + ", ".join(f"{name} {what} {at:%H:%M}" for name, (_, at, what) in a.items())
            + ")"], False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--max-age", type=float, default=7200)
    ap.add_argument("--log")
    ap.add_argument("--site-stamp", default=os.environ.get("POG_SITE_STAMP") or os.path.join(ROOT, "site", "dist.last-deploy"))
    ap.add_argument("--public-status", default=os.path.join(
        os.environ.get("POG_PUBLIC_DIR") or os.path.expanduser("~/.cache/pog-public"), "status.json"))
    a = ap.parse_args(argv)
    out, stale = lines(ages(a.site_stamp, a.public_status), a.max_age)
    print("\n".join(out), flush=True)
    if a.log:
        try:
            with open(a.log, "a") as f:
                f.write("".join(l + "\n" for l in out))
        except OSError:
            pass
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
