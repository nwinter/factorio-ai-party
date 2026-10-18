#!/usr/bin/env python3
"""Replay viewer lines through Clef with the old and the new criteria, and print each verdict.

  python3 tools/stream/clef_replay.py LOG.jsonl [--sample N] [--before REV]
  python3 tools/stream/clef_replay.py ~/code/player-of-games/tools/stream/logs/viewers-20261018-105134.jsonl --sample 20

d17 batch35 U1 (operator 15:05: Clef refused 13 viewer lines as injection since 10:51, nearly all plain game advice).
LOG is a viewers.py verdict log (tools/stream/logs/viewers-*.jsonl). The lines Clef refused there, and the first N of
the lines it passed (default 20), go to the real @cf/cloudflare/clef-flash twice in one batch each: with CLEF_CRITERIA
from viewers.py at REV (default main) and with the working tree's. Clef credentials as the stream service uses them
(tools/stream/cfai.py). Costs a fraction of a cent. Prints one line a message: id, name, old verdict, new verdict, text.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402


def criteria_at(rev):
    src = subprocess.run(["git", "show", f"{rev}:tools/stream/viewers.py"], capture_output=True, text=True,
                         cwd=os.path.dirname(os.path.dirname(HERE)), check=True).stdout
    i = src.index("CLEF_CRITERIA = {")
    j = src.index("\n}\n", i) + 3
    ns = {}
    exec(src[i:j], ns)
    return ns["CLEF_CRITERIA"]


def lines_of(path, sample):
    refused, passed = [], []
    for row in map(json.loads, open(path)):
        r = {"id": row["id"], "name": row["name"], "text": row["text"], "was": ",".join(row["reasons"]) or "pass"}
        if any(x.startswith("clef:") for x in row["reasons"]):
            refused.append(r)
        elif row["pass"] and row.get("checked") == "clef" and len(passed) < sample:
            passed.append(r)
    return refused + passed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--sample", type=int, default=20)
    ap.add_argument("--before", default="main")
    a = ap.parse_args(argv)
    msgs = lines_of(a.log, a.sample)
    clef = V.Clef()
    old, new = criteria_at(a.before), V.CLEF_CRITERIA
    before, after = {}, {}
    for k in range(0, len(msgs), 48):
        part = msgs[k:k + 48]
        before.update(clef.classify(part, old))
        after.update(clef.classify(part, new))
    changed = 0
    for m in msgs:
        b, c = before.get(m["id"]), after.get(m["id"])
        changed += b != c
        print(f"{m['id']}\t{m['name']}\tlog {m['was']}\told {b}\tnew {c}\t{m['text'][:110]}")
    print(f"\n{len(msgs)} lines; {changed} with a different verdict")


if __name__ == "__main__":
    main()
