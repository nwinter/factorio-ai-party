#!/usr/bin/env python3
"""Run the mock session through the model and director on a fake clock and report camera statistics.

  python3 tools/stream/simulate.py [--minutes 30] [--run tools/stream/runs/mock9.json] [--set main_dwell=25 ...]
  python3 tools/stream/simulate.py --cams onecam      # one camera on air (onecam.py): the "program" row is the cuts
  python3 tools/stream/simulate.py --log tools/stream/logs/director-....jsonl     # stats for a real log

Use it to tune the director weights (director.DEFAULTS, or "director" in a run config) before a stream.
"""
import argparse, json, os, statistics, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True


class Clock:
    def __init__(self, t):
        self.t = t

    def time(self):
        return self.t

    def __getattr__(self, name):  # strftime, localtime, ... from the real module
        import time as real
        return getattr(real, name)


def stats(rows, minutes):
    cuts = [r for r in rows if r["reason"] not in ("reframe", "pair", "unpair") and not r["reason"].startswith("zoom ")]
    zooms = [r for r in rows if r["reason"].startswith("zoom ")]
    out = {}
    for slot in sorted({r["slot"] for r in rows}):
        times = [r["t"] for r in cuts if r["slot"] == slot]
        zoom_by = {}
        for r in zooms:
            if r["slot"] == slot:
                kind = r["reason"].rsplit("(", 1)[-1].rstrip(")")
                zoom_by[kind] = zoom_by.get(kind, 0) + 1
        dwell = [b - a for a, b in zip(times, times[1:])]
        pairs = [r for r in rows if r["slot"] == slot and r.get("target") and len(r["target"]["agents"]) > 1]
        subjects = {}
        for r in cuts:
            if r["slot"] == slot and r.get("target"):
                who = (r["target"]["agents"] or ["@base attack"])[0]
                subjects[who] = subjects.get(who, 0) + 1
        out[slot] = {
            "cuts_per_min": round(len(times) / max(minutes, 1e-9), 2),
            "dwell_median_s": round(statistics.median(dwell), 1) if dwell else None,
            "dwell_min_s": round(min(dwell), 1) if dwell else None,
            "pair_decisions": len(pairs),
            "zoom_changes_per_min": round(sum(zoom_by.values()) / max(minutes, 1e-9), 2),
            "zoom_changes_by_activity": dict(sorted(zoom_by.items(), key=lambda kv: -kv[1])),
            "subjects": dict(sorted(subjects.items(), key=lambda kv: -kv[1])),
        }
    reasons = {}
    for r in cuts:
        why = r["reason"]
        key = ("bow" if why.startswith("platform bow") else "after the bow" if why.startswith("after the bow") else
               "attack" if why.startswith("attack") else "challenger" if " beats " in why else "rotate" if why.startswith("rotate") else
               "subject unavailable" if why.endswith("unavailable") else "swap" if "swap" in why else "taken by higher camera" if "taken" in why else why)
        reasons[key] = reasons.get(key, 0) + 1
    out["reasons"] = reasons
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--run", default=os.path.join(HERE, "runs", "mock9.json"))
    ap.add_argument("--poll", type=float, default=3.0)
    ap.add_argument("--set", action="append", default=[], help="director tuning override, e.g. main_dwell=25")
    ap.add_argument("--log", help="report on an existing director log instead of simulating")
    ap.add_argument("--cams", choices=["onecam", "3cam"], default="3cam", help="onecam: onecam.OneCam (serve.py's default)")
    ap.add_argument("--clients", type=int, choices=[1, 2, 3], help="camera clients (POG_CAMS=1: one camera)")
    ap.add_argument("--long-flight", action="store_true",
                    help="a ship flying from the solar system edge (mock.long_flight_step): onecam's bow shots")
    a = ap.parse_args()
    if a.log:
        rows = [json.loads(l) for l in open(a.log)]
        minutes = (rows[-1]["t"] - rows[0]["t"]) / 60 if len(rows) > 1 else 0
        print(json.dumps(stats(rows, minutes), indent=1))
        return

    import director, mock, model, onecam
    clock = Clock(1_800_000_000.0)
    for mod in (director, mock, model, onecam):
        mod.time = clock
    run = json.load(open(a.run))
    if a.long_flight:
        run["mock_long_flight"] = True
    tuning = dict(run.get("director") or {})
    for kv in a.set:
        k, v = kv.split("=", 1)
        tuning[k] = float(v)
    log = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False).name
    src = mock.MockSource(run)
    m = model.Model(run)
    slots = run.get("cameras") or [{"slot": "main", "player": 1}, {"slot": "cam2", "player": 2}, {"slot": "cam3", "player": 3}]
    d = (onecam.OneCam if a.cams == "onecam" else director.Director)(slots[:a.clients] if a.clients else slots,
                          lambda body: {"ok": False, "stub": True}, log, **tuning)
    import contextlib, io
    end = clock.t + a.minutes * 60
    next_poll = clock.t
    cams = {}
    with contextlib.redirect_stdout(io.StringIO()):
        while clock.t < end:
            if clock.t >= next_poll:
                m.ingest(src.observe(), clock.t)
                next_poll += a.poll
            cams = d.step(m.snapshot(clock.t, cams), clock.t)
            clock.t += 1.0
    rows = [json.loads(l) for l in open(log)]
    extra = {}
    if getattr(d, "bows", None) is not None and a.long_flight:  # (QM1) each bow shot: minute, why the round was over
        extra["bows"] = [[round((t - (end - a.minutes * 60)) / 60, 1), why] for t, _, why in d.bows]
    print(json.dumps({"tuning": {**director.DEFAULTS, **tuning}, "log": log, **stats(rows, a.minutes), **extra}, indent=1))


if __name__ == "__main__":
    main()
