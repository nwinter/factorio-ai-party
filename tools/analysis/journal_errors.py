#!/usr/bin/env python3
"""List harness errors per agent, grouped by action and normalized message: journal_errors.py JOURNAL_DIR [AGENT...]

Also prints what the agent sent next after each error (same action and args = blind retry).
"""
import collections, gzip, json, os, re, sys


def norm(msg):
    msg = re.sub(r"agent-harness/runtime:\d+: ", "", msg)
    msg = re.sub(r"-?\d+(\.\d+)?", "N", msg)
    return msg[:150]


def main():
    root = sys.argv[1]
    only = set(sys.argv[2:])
    for agent in sorted(os.listdir(root)):
        if only and agent not in only:
            continue
        p = os.path.join(root, agent, "journal.jsonl.gz")
        if not os.path.exists(p):
            continue
        reqs, order = {}, []
        errs = []
        with gzip.open(p, "rt") as f:
            for line in f:
                d = json.loads(line)
                if d["event"] == "request":
                    r = d["request"]
                    if r.get("action") in ("status", "queue_status"):
                        continue
                    reqs[r["id"]] = r
                    order.append(r["id"])
                elif d["event"] == "response" and d["response"].get("ok") is False:
                    errs.append(d["response"])
        pos = {rid: i for i, rid in enumerate(order)}
        groups = collections.Counter()
        retry = 0
        for e in errs:
            r = reqs.get(e["id"])
            if not r:
                continue
            groups[(r["action"], norm(e["error"].get("message", e["error"].get("code", ""))))] += 1
            i = pos[e["id"]]
            if i + 1 < len(order):
                nxt = reqs[order[i + 1]]
                if nxt["action"] == r["action"] and nxt.get("args") == r.get("args"):
                    retry += 1
        print(f"== {agent}: {len(errs)} errors, {retry} identical immediate retries")
        for (a, m), n in groups.most_common(12):
            print(f"  {n:3d} {a}: {m}")


if __name__ == "__main__":
    main()
