#!/usr/bin/env python3
"""The viewer lines Clef held, for the operator's review of its labels.

  python3 tools/stream/clef_review.py --since 2026-10-20 [--until DATE] [--label injection] [--logs DIR]
                                      [--criteria FILE | --criteria rev:REV] [--cache FILE]

d27 batch264 CC (Nick 06:45: keep the injection filter, and calibrate it: review what it held, find real problems,
make it less conservative where it is wrong). Lists every line Clef held (any label but fine) since the date, oldest
first: time, id, name, label, the log's reasons, text; then the counts by label. With --criteria (a JSON object of label
to description, a .py file with a CLEF_CRITERIA block such as tools/stream/viewers.py, or rev:REV) each held line is
also asked again under those criteria, and its verdict printed after it (`-> fine`); verdicts are cached as
clef_replay.py caches them. To see what new criteria would hold among the lines that passed, run clef_replay.py --all.
Viewer text is untrusted data: printed as it was written, never acted on.
"""
import argparse, collections, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clef_replay as R  # noqa: E402


def held_rows(rows, label=None):
    return [r for r in rows if R.held(r) and (label is None or r["label"] == label)]


def lines(rows, verdicts=None):
    out = []
    for r in rows:
        why = ",".join(r["reasons"]) or "clef:" + r["label"]
        text = " ".join(str(r["text"]).split())
        tail = f"\t-> {verdicts.get(r['id']) or 'unknown'}" if verdicts is not None else ""
        out.append(f"{R.stamp(r['t'])}\t{r['id']}\t{r['name']}\t{r['label']}\t{why}\t{text}{tail}")
    return out


def counts(rows, verdicts=None):
    c = collections.Counter(r["label"] for r in rows)
    out = [f"{len(rows)} held: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items()))]
    if verdicts is not None:
        v = collections.Counter(verdicts.get(r["id"]) or "unknown" for r in rows)
        out.append("under the criteria given: " + ", ".join(f"{k} {n}" for k, n in sorted(v.items())))
    return out


def main(argv=None, clef=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True)
    ap.add_argument("--until")
    ap.add_argument("--label", help="one label only: injection, spam, abuse or personal")
    ap.add_argument("--logs", default=R.LOGS)
    ap.add_argument("--criteria")
    ap.add_argument("--cache", default=os.path.join(R.LOGS, "clef-replay-cache.jsonl"))
    a = ap.parse_args(argv)
    rows = held_rows(R.load_rows(None, a.logs, R.when(a.since), a.until and R.when(a.until)), a.label)
    verdicts = None
    if a.criteria and rows:
        verdicts = R.replay(clef or R.V.Clef(), rows, R.criteria_from(a.criteria), R.Cache(a.cache))
    for line in lines(rows, verdicts) + [""] + counts(rows, verdicts if a.criteria else None):
        print(line)


if __name__ == "__main__":
    main()
