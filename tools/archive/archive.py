#!/usr/bin/env python3
"""One shift's archive files in one go (batch126; tools/archive/README.md):

    python3 tools/archive/archive.py RUN --out DIR --recordings DIR [DIR ...] [--runs-dir DIR] [--logs-dir DIR]
                                         [--cut 3] [--no-calibrate]

1. the index without offsets (tools/archive/archive_index.py), to learn which recordings cover the shift;
2. each recording's offset from its voiced lines (tools/archive/calibrate.py), kept in DIR/calibration.json so a rerun
   reads it instead of the master;
3. the index again with the offsets: DIR/RUN-index.json;
4. captions per recording: DIR/RUN-NAME.vtt (tools/archive/captions.py);
5. candidate clips: DIR/clips/candidates.json and review.md, and with --cut N the best N as MP4 (tools/archive/clips.py).

Read-only on the recordings and the logs. No uploads, no game reads.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import archive_index  # noqa: E402
import calibrate  # noqa: E402
import captions  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--out", required=True)
    ap.add_argument("--recordings", nargs="+", required=True)
    ap.add_argument("--runs-dir", default=str(REPO / "runs"))
    ap.add_argument("--logs-dir", default=str(REPO / "tools" / "stream" / "logs"))
    ap.add_argument("--cut", type=int, default=0)
    ap.add_argument("--no-calibrate", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    import moderation  # site/moderation.py (archive_index put site/ on the path)
    hidden = moderation.load(a.runs_dir, REPO / "site" / "hidden-viewers.json")
    cal_path = out / "calibration.json"
    cal = json.loads(cal_path.read_text()) if cal_path.exists() else {}
    idx = archive_index.build(a.run, a.runs_dir, a.logs_dir, a.recordings, cal, hidden=hidden)
    if not a.no_calibrate:
        lines = [(r["t"], r["dur"]) for r in idx["lines"] if r.get("dur")]
        for m in idx["media"]:
            if m["name"] in cal:
                continue
            fit = calibrate.calibrate(m["file"], lines, m["named_t0"], m["duration"])
            cal[m["name"]] = fit
            print(f"{m['name']}: offset {fit['offset']} s, drift {fit['drift_s_per_h']} s/h, "
                  f"{fit['used']} of {len(fit['windows'])} windows")
        cal_path.write_text(json.dumps(cal, indent=1))
        idx = archive_index.build(a.run, a.runs_dir, a.logs_dir, a.recordings, cal, hidden=hidden)
    path = out / f"{a.run}-index.json"
    path.write_text(json.dumps(idx, ensure_ascii=False, separators=(",", ":")))
    for m in idx["media"]:
        (out / f"{a.run}-{Path(m['name']).stem}.vtt").write_text(captions.vtt(idx["lines"], m["t0"]))
    print(f"{path}: {len(idx['events'])} events, {len(idx['onair'])} on-air intervals, {len(idx['lines'])} voiced "
          f"lines, {len(idx['chat'])} chat lines, {len(idx['media'])} recordings, {len(idx['gaps'])} gaps")
    subprocess.run([sys.executable, str(HERE / "clips.py"), str(path), "--out", str(out / "clips"),
                    "--cut", str(a.cut)], check=True)


if __name__ == "__main__":
    main()
