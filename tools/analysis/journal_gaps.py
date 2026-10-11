#!/usr/bin/env python3
"""Cross-agent timing and error summary from harness journals.

Usage: journal_gaps.py JOURNAL_DIR [START_PDT END_PDT]
JOURNAL_DIR holds <agent>/journal.jsonl.gz. Prints, per agent: request counts, the wall-clock gaps between one
response and the next request (time the agent spent outside the game: model thinking, shell work, sleeps), bucketed,
and an error taxonomy. Timed actions block inside `fh --wait` by polling `status`, so polls are folded into the
action that started them when the journal still has them.
"""
import collections, datetime as dt, gzip, json, os, re, statistics, sys

POLL = {"status", "queue_status"}
BUCKETS = [(0, 2), (2, 10), (10, 30), (30, 60), (60, 120), (120, 300), (300, 1e9)]


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def pdt(t):
    return dt.datetime.fromtimestamp(t, dt.timezone(dt.timedelta(hours=-7))).strftime("%H:%M:%S")


def err_class(msg):
    m = msg.lower()
    rules = [
        ("unknown field/arg", r"unknown (field|arg|key|option)|unexpected (field|arg)|not a valid|invalid arg|expected .* got|must be one of|requires? (a|an) "),
        ("blocked placement", r"blocked|collid|cannot place|can't place|not buildable|overlap"),
        ("missing items", r"not enough|missing|have 0|insufficient|no .* in inventory|lacks"),
        ("out of reach/range", r"reach|too far|out of range|distance"),
        ("not found/visible", r"not found|no entity|nothing (at|to)|no such|unknown entity|not visible"),
        ("busy/interrupted", r"busy|interrupt|already running|in progress"),
        ("path/move", r"path|arrived_near|unreachable"),
        ("queue-only action", r"queue"),
        ("dead/respawn", r"dead|respawn|corpse"),
        ("player id", r"playeridentification"),
        ("timeout", r"timeout|timed out"),
    ]
    for name, rx in rules:
        if re.search(rx, m):
            return name
    return "other"


def load(path):
    reqs, resps = {}, {}
    with gzip.open(path, "rt") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("event") == "request":
                r = d["request"]
                reqs[r["id"]] = (ts(d["at"]), r.get("action"), r.get("args") or {})
            elif d.get("event") == "response":
                r = d["response"]
                resps[r.get("id")] = (ts(d["at"]), r.get("ok"), r.get("error"), r.get("result"))
    rows = []
    for rid, (t0, action, args) in reqs.items():
        t1, ok, err, res = resps.get(rid, (t0, None, None, None))
        rows.append(dict(t0=t0, t1=t1, action=action, args=args, ok=ok, err=err, res=res))
    rows.sort(key=lambda r: r["t0"])
    return rows


def main():
    root = sys.argv[1]
    lo = hi = None
    if len(sys.argv) > 3:
        day = "2026-10-10T"
        lo = ts(day + sys.argv[2] + "-07:00")
        hi = ts(day + sys.argv[3] + "-07:00")
    summary = {}
    for agent in sorted(os.listdir(root)):
        p = os.path.join(root, agent, "journal.jsonl.gz")
        if not os.path.exists(p):
            continue
        rows = load(p)
        if lo:
            rows = [r for r in rows if lo <= r["t0"] <= hi]
        acts = [r for r in rows if r["action"] not in POLL]
        polls = [r for r in rows if r["action"] in POLL]
        # Gap from the end of one non-poll request to the start of the next; polls in between count as waiting.
        gaps = []
        for a, b in zip(acts, acts[1:]):
            inner = [p_ for p_ in polls if a["t0"] <= p_["t0"] <= b["t0"]]
            end = max([a["t1"]] + [p_["t1"] for p_ in inner])
            gaps.append((max(0.0, b["t0"] - end), (end - a["t1"]), a, b))
        think = [g for g, _, _, _ in gaps]
        waitpoll = sum(w for _, w, _, _ in gaps)
        buckets = collections.Counter()
        bsum = collections.Counter()
        for g in think:
            for b in BUCKETS:
                if b[0] <= g < b[1]:
                    key = f"{b[0]}-{b[1] if b[1] < 1e9 else 'inf'}s"
                    buckets[key] += 1
                    bsum[key] += g
        errs = [r for r in acts if r["ok"] is False]
        ecls = collections.Counter(err_class((r["err"] or {}).get("message", "") + " " + (r["err"] or {}).get("code", "")) for r in errs)
        ecode = collections.Counter((r["err"] or {}).get("code", "?") for r in errs)
        byact = collections.Counter(r["action"] for r in acts)
        erract = collections.Counter(r["action"] for r in errs)
        span = (acts[-1]["t0"] - acts[0]["t0"]) if acts else 0
        longest = sorted(gaps, key=lambda g: -g[0])[:6]
        s = dict(
            agent=agent, first=pdt(acts[0]["t0"]) if acts else None, last=pdt(acts[-1]["t0"]) if acts else None,
            span_min=round(span / 60, 1), actions=len(acts), polls=len(polls),
            gap_total_min=round(sum(think) / 60, 1), gap_median_s=round(statistics.median(think), 1) if think else None,
            gap_p90_s=round(sorted(think)[int(0.9 * len(think))], 1) if think else None,
            waitpoll_min=round(waitpoll / 60, 1),
            gap_buckets={k: [buckets[k], round(bsum[k] / 60, 1)] for k in sorted(buckets, key=lambda k: float(k.split('-')[0]))},
            errors=len(errs), err_classes=dict(ecls.most_common()), err_codes=dict(ecode.most_common()),
            err_by_action=dict(erract.most_common(8)), top_actions=dict(byact.most_common(14)),
            longest_gaps=[(pdt(b["t0"]), round(g), a["action"], b["action"]) for g, _, a, b in longest],
        )
        summary[agent] = s
    json.dump(summary, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
