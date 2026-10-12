#!/usr/bin/env python3
"""How the hosts' copy is doing on a run, read only: template fallbacks, lines cut by each check, and the tells left.

  python3 tools/stream/copy_report.py runs/shake7/caster.log [--since 13:30] [--last 30]

Reads the caster's text log: "[Rook] (kind, backend, 2.4s) line" for each aired line, "[pbp] rejected (reason): line"
for each cut, and the "[cost] {...}" stats every 5 minutes (caster_lines, fallbacks). --last N also reports the last N
minutes alone, to see a trend while the run goes on. The shake4-6 shares are the baseline from docs/AUDIO-NOTES.md
("Hosts that sound human").
"""
import argparse, collections, json, re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
from copy_bench import TELLS  # noqa: E402

# Share of shake4-6's 1,393 aired writer lines with each tell (docs/AUDIO-NOTES.md)
BEFORE = {"dash pivot": 62, "ends on '!'": 39, "machine metaphor": 26, "three-part list": 19, "semicolon": 14,
          "stock words": 13, "ends on '?'": 10, "X, not Y": 7, "documentary words": 5, "simile": 3,
          "opens on a number": 24}
LINE = re.compile(r"^(\d\d:\d\d:\d\d) \[(Rook|Vale)\] \(([^,]+), ([^,]+), [\d.]+s\) (.+)$")
CUT = re.compile(r"^(\d\d:\d\d:\d\d) \[(pbp|color)\] rejected \((.+?)\): (.+)$")
REWRITE = re.compile(r"^(\d\d:\d\d:\d\d) \[writer\] rewrite after (.+)$")
COST = re.compile(r"^(\d\d:\d\d:\d\d) \[cost\] (\{.+\})$")


def secs(hms):
    h, m, s = map(int, hms.split(":"))
    return h * 3600 + m * 60 + s


def reason_key(why):
    """Group reasons: 'style: metaphor 'bleed'' -> 'style: metaphor', 'number not in facts: 40' -> 'number not in facts'."""
    if why.startswith("style:"):
        return re.sub(r" '[^']*'$", "", why)  # "style: metaphor 'bleed'" -> "style: metaphor"
    return re.sub(r":.*$", "", why).strip()


def tells(lines):
    c = collections.Counter()
    for line in lines:
        for k, rx in TELLS.items():
            flags = 0 if k == "opens on a number" else re.I
            if re.search(rx, line if k in ("opens on a number", "ends on '!'") else line.lower(), flags):
                c[k] += 1
    return c


def numbers(line):
    import caster
    low = line.lower()
    return len(re.findall(r"\d+(?:,\d{3})*(?:\.\d+)?", low)) + len(caster.spelled_numbers(re.sub(r"\d", " ", low)))


def report(rows, cuts, costs, title, rewrites=()):
    writer = [r for r in rows if r[3] != "template"]
    tmpl = [r for r in rows if r[3] == "template"]
    print(f"== {title}: {len(rows)} aired host lines, {len(writer)} by a writer model, {len(tmpl)} templates "
          f"({100 * len(tmpl) / max(len(rows), 1):.0f}%)")
    if costs:
        a, b = costs[0][1], costs[-1][1]
        fb = b.get("fallbacks", 0) - (a.get("fallbacks", 0) if len(costs) > 1 and title != "whole run" else 0)
        print(f"   [cost] stats at {costs[-1][0]}: caster_lines {b.get('caster_lines')}, fallbacks {b.get('fallbacks')}"
              f", usd_per_hour {b.get('usd_per_hour')}" + (f" (fallbacks in this window: {fb})" if title != "whole run" else ""))
    by = collections.Counter(reason_key(c[2]) for c in cuts)
    style = sum(v for k, v in by.items() if k.startswith("style"))
    print(f"   cuts: {len(cuts)} ({style} for style)" + (f"; style rewrites asked: {len(rewrites)}" if rewrites else ""))
    for k, v in by.most_common():
        ex = next(c[3] for c in cuts if reason_key(c[2]) == k)
        print(f"     {v:4d}  {k:40.40}  e.g. {ex[:90]}")
    t = tells([r[4] for r in writer])
    n = max(len(writer), 1)
    print("   tells left in writer lines (now vs shake4-6):")
    for k in TELLS:
        print(f"     {100 * t[k] / n:5.1f}%  vs {BEFORE.get(k, 0):3d}%  {k}")
    if writer:
        words = [len(r[4].split()) for r in writer]
        many = sum(numbers(r[4]) >= 3 for r in writer)
        print(f"   words a line {sum(words) / n:.1f} (shake4-6: 14.9); lines with 3+ numbers {100 * many / n:.1f}% "
              f"(shake4-6: 13%)")
        # the clipped rhythm the first copy pass gave (shake7's first 46 lines: 4.6 words a sentence, 33% of sentences
        # three words or fewer, 28% of lines three sentences or more)
        sents = [[p for p in re.split(r"(?<=[.!?])\s+", r[4]) if p] for r in writer]
        flat = [len(p.split()) for ss in sents for p in ss]
        print(f"   words a sentence {sum(flat) / max(len(flat), 1):.1f}; sentences of 3 words or fewer "
              f"{100 * sum(x <= 3 for x in flat) / max(len(flat), 1):.0f}%; lines of 3+ sentences "
              f"{100 * sum(len(ss) >= 3 for ss in sents) / n:.0f}%")


def by_writer(paths, text_log=None):
    """Per writer backend: aired lines, words a line and write latency (per exchange); the share of the run with
    nobody speaking; cost per hour from the [cost] rows; write failures and timeouts from the text log."""
    import statistics
    rows, costs = [], []
    for p in paths:
        for raw in open(p):
            r = json.loads(raw)
            if r.get("type") in ("caster", "agent"):
                rows.append(r)
            elif r.get("type") == "cost":
                costs.append(r)
    aired = [r for r in rows if r.get("pushed")]
    if not aired:
        return
    span = max(r["t"] for r in rows) - min(r["t"] for r in rows)
    spans = sorted((r["t"], r["t"] + float(r.get("seconds") or 0)) for r in aired)
    talk, (cs, ce) = 0.0, spans[0]
    for s0, e0 in spans[1:]:
        if s0 > ce:
            talk, cs, ce = talk + ce - cs, s0, e0
        else:
            ce = max(ce, e0)
    talk += ce - cs
    hours = span / 3600
    print(f"== by writer ({len(paths)} jsonl, {span / 60:.0f} min): a voice on air {100 * talk / span:.0f}% of the "
          f"time, silence {100 - 100 * talk / span:.0f}%")
    for b in sorted({r.get("backend") for r in aired if r.get("type") == "caster"}, key=str):
        lines = [r for r in aired if r.get("type") == "caster" and r.get("backend") == b]
        ex = {r["exchange"]: r.get("write_latency") for r in lines if r.get("write_latency") is not None}
        lat = sorted(ex.values()) or [0]
        words = [len(r["line"].split()) for r in lines]
        print(f"   {str(b):36.36} {len(lines):4d} lines ({len(lines) / hours:.0f}/h), {sum(words) / len(words):.1f} "
              f"words a line, write latency median {statistics.median(lat):.1f}s p90 "
              f"{lat[int(0.9 * (len(lat) - 1))]:.1f}s over {len(ex)} exchanges")
    if costs:
        # one [cost] series per caster process (its minutes start again at a restart): sum each series' last row
        series, cur = [], [costs[0]]
        for c in costs[1:]:
            if c["minutes"] >= cur[-1]["minutes"]:
                cur.append(c)
            else:
                series.append(cur)
                cur = [c]
        series.append(cur)
        mins = sum(sr[-1]["minutes"] for sr in series)
        usd = {k: sum(sr[-1].get(k) or 0 for sr in series) for k in ("writer_usd", "tts_usd", "classifier_usd")}
        print(f"   cost over {mins:.0f} min: writer ${usd['writer_usd']:.2f} (${60 * usd['writer_usd'] / mins:.2f}/h), "
              f"TTS ${usd['tts_usd']:.2f} (${60 * usd['tts_usd'] / mins:.2f}/h), all ${60 * sum(usd.values()) / mins:.2f}/h")
    if text_log:
        fails = [l for l in open(text_log, errors="replace") if "[writer] failed" in l]
        tos = [l for l in fails if re.search(r"time(d)? ?out", l, re.I)]
        print(f"   writer failures {len(fails)}, of them timeouts {len(tos)}"
              + (f"; e.g. {fails[0].strip()[:120]}" if fails else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", help="runs/<run>/caster.log")
    ap.add_argument("--since", help="HH:MM: only from this time on")
    ap.add_argument("--last", type=int, help="also report the last N minutes alone")
    ap.add_argument("--jsonl", nargs="+", help="the run's tools/stream/logs/caster-*.jsonl: per writer, latency, "
                                               "timeouts, silence share and cost per hour")
    a = ap.parse_args()
    rows, cuts, costs, rewrites = [], [], [], []
    start = secs(a.since + ":00") if a.since else 0
    for raw in open(a.log, errors="replace"):
        raw = raw.rstrip("\n")
        m = LINE.match(raw)
        if m and secs(m.group(1)) >= start:
            rows.append(m.groups())
            continue
        m = CUT.match(raw)
        if m and secs(m.group(1)) >= start:
            cuts.append(m.groups())
            continue
        m = REWRITE.match(raw)
        if m and secs(m.group(1)) >= start:
            rewrites.append(m.groups())
            continue
        m = COST.match(raw)
        if m and secs(m.group(1)) >= start:
            try:
                costs.append((m.group(1), json.loads(m.group(2))))
            except ValueError:
                pass
    if not rows:
        sys.exit(f"{a.log}: no aired host lines" + (f" since {a.since}" if a.since else ""))
    report(rows, cuts, costs, "whole run", rewrites)
    if a.jsonl:
        by_writer(a.jsonl, a.log)
    if a.last:
        end = secs(rows[-1][0])
        keep = lambda x: secs(x[0]) >= end - a.last * 60
        report([r for r in rows if keep(r)], [c for c in cuts if keep(c)], [c for c in costs if keep(c)],
               f"last {a.last} minutes", [w for w in rewrites if keep(w)])


if __name__ == "__main__":
    main()
