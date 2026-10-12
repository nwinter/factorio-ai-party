#!/usr/bin/env python3
"""Point site/live/status.json's last run at a finished shift of the long run (tools/site-refresh.sh):

    python3 site/status_update.py RUN [--runs-dir DIR] [--status FILE]

last_run becomes {"id": RUN, "title": "Shift N of the long run", "url": "/runs/long/"} when RUN is a shift of the long
run (site/longrun.py, from site.json's run_start), else {"id": RUN, "title": RUN, "url": "/runs/long/" or null}; `updated` is now. The message
and the next shift stay as they are (the live state's `shift` says when the next one starts).
"""
import argparse, datetime, json, os, sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import longrun  # noqa: E402


def update(status, run, lr):
    shift = next((s for s in (lr or {}).get("shifts", []) if s["id"] == run and s.get("n")), None)
    if shift:
        last = {"id": run, "title": f"Shift {shift['n']} of the long run", "url": "/runs/long/"}
    else:
        last = {"id": run, "title": run, "url": "/runs/long/" if lr else None}
    return dict(status, last_run=last, updated=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--runs-dir", default=str(SITE.parent / "runs"))
    ap.add_argument("--status", default=str(SITE / "live" / "status.json"))
    a = ap.parse_args()
    path = Path(a.status)
    status = json.loads(path.read_text()) if path.exists() else {"schema": 1, "live": False}
    content = Path(os.environ.get("POG_SITE_CONTENT") or SITE / "content" / "site.json")  # as build.py --content
    start = json.loads(content.read_text()).get("run_start")  # shift numbers count from it
    new = update(status, a.run, longrun.load(a.runs_dir, start=start))
    path.write_text(json.dumps(new, indent=2, ensure_ascii=False) + "\n")
    print(f"status.json: last run {new['last_run']['title']} ({a.run})")


if __name__ == "__main__":
    main()
