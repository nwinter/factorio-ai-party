#!/usr/bin/env python3
"""Before/after for the hosts' copy: replay logged exchanges (their exact facts) through today's writer.

  python3 tools/stream/copy_bench.py tools/stream/logs/caster-20261011-072205.jsonl [more logs] \
      --n 30 --writers cf=@cf/moonshotai/kimi-k2.6,cf=@cf/google/gemma-4-26b-a4b-it --md /tmp/copy.md

For each picked exchange (spread over event kinds) it prints the lines that aired, what the post-filter does to them
(restyle, then style_fault), and each writer's new exchange on the same facts after check_line and tidy_exchange.
The summary counts the tells before and after, the lines kept, write latency and cost. `--writers none` runs the
post-filter alone (no network). Workers AI needs a fresh wrangler login (`npx wrangler whoami`).

Writers: cf=<Workers AI model>, claude=<sonnet|opus|fable> (claude -p on the personal subscription; cost is the
API-equivalent), or=<OpenRouter model id> (OPENROUTER_API_KEY in the environment). The bigger-writer comparison
(HOSTS3 item 6), run from a shell that may reach those services:

  L=~/code/player-of-games/tools/stream/logs
  python3 tools/stream/copy_bench.py $L/caster-20261011-130031.jsonl --n 15 --timeout 20 \\
      --match "walk|motto|still|again|classic|energy|queue" \\
      --writers cf=@cf/moonshotai/kimi-k2.6,claude=sonnet,claude=opus,claude=fable,or=openai/gpt-6.1-sol,or=google/gemini-3.8-flash \\
      --md /tmp/copy-bench-writers.md
"""
import argparse, collections, json, os, random, re, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster  # noqa: E402

# What the hosts sounded like in shake4-6 (docs/AUDIO-NOTES.md, "Hosts that sound human"); each is a share of lines.
TELLS = {
    "dash pivot": r"—|–| -- | - ",
    "X, not Y": caster.NOT_CONTRAST.pattern,
    "three-part list": r"(?:\b[\w'-]+(?: [\w'-]+){0,3}, ){2}(?:and |or )?[\w'-]+(?: [\w'-]+){0,3}[.!?—]",
    "ends on '?'": r"\?\s*$",
    "ends on '!'": r"!\s*$",
    "semicolon": r";",
    "documentary words": caster.DOC_WORDS.pattern,
    "machine metaphor": caster.BODY_WORDS.pattern,
    "stock words": r"\b(?:hum|hums|humming|cook\w*|deep|symphony|orchestra\w*|ballet|dance|alive|heartbeat|"
                   r"masterclass|chaos)\b",
    "simile": r"\b(?!looks |sounds |feels |seems )\w+ like (?:a|an) \w+",
    "opens on a number": r"^(?:\d|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|Eleven|Twelve|Twenty|Thirty|Forty|"
                         r"Fifty|Sixty|Seventy|Eighty|Ninety|A hundred)\b",
}


def tells(lines):
    c = collections.Counter()
    for line in lines:
        for k, rx in TELLS.items():
            if re.search(rx, line if k == "opens on a number" else line.lower() if k != "ends on '!'" else line,
                         re.I if k != "opens on a number" else 0):
                c[k] += 1
    return c


def load(paths):
    """{exchange id: {facts, kind, angle, naturalist, lines: [(who, line)]}} for exchanges a writer wrote."""
    ex = {}
    for path in paths:
        for raw in open(path):
            r = json.loads(raw)
            if r.get("type") != "caster" or "exchange" not in r:
                continue
            x = ex.setdefault((path, r["exchange"]), {"lines": [], "kind": r.get("event"), "angle": r.get("angle"),
                                                      "naturalist": r.get("naturalist"), "backend": r.get("backend")})
            if r.get("facts"):
                x["facts"] = r["facts"]
            if r.get("pushed") and r.get("line"):
                x["lines"].append((r["who"], r["line"]))
    return {k: v for k, v in ex.items() if v.get("facts") and v["lines"] and "template" not in str(v["backend"])}


def as_today(facts, kind, angle=None):
    """Logged facts in today's shape, so the bench tests today's facts as well as today's prompt: no 'walking' doing,
    mottos only on the opener and spotlight cards, the shift fact by number, standing numbers as background on
    event beats, and the card's call on segments."""
    f = json.loads(json.dumps(facts))
    keep_motto = kind == "open" or (f.get("on_screen_now") or {}).get("segment") == "spotlight"
    if not keep_motto:
        f = caster.drop_keys(f, ("motto",))

    def strip(x):
        if isinstance(x, dict):
            return {k: strip(v) for k, v in x.items()
                    if not (k == "doing" and isinstance(v, str) and caster.TRAVEL.match(v))}
        return [strip(v) for v in x] if isinstance(x, list) else x
    f = strip(f)
    sh = f.get("shift")
    if isinstance(sh, dict) and "number" in sh:
        n = sh["number"]
        f["shift"] = {"this_shift": f"shift {n}", "next_shift": f"shift {n + 1}", "earlier_shifts": n - 1,
                      "at_the_deadline": f"the world is saved and shift {n + 1} continues it from there"}
    if kind not in caster.STORY_KINDS and angle not in caster.STORY_ANGLES:
        bg = {k: f.pop(k) for k in caster.BACKGROUND if k in f}
        if bg:
            f["background"] = dict(bg, note="standing numbers for context; mention one only if it matters here")
    seg = f.get("on_screen_now") or {}
    if kind == "segment" and seg.get("segment") in caster.CARD_CALLS:
        f["how_to_call_it"] = caster.CARD_CALLS[seg["segment"]]
    return f


def pick(ex, n, seed):
    """n exchanges spread over event kinds, same picks for the same logs and seed."""
    rng = random.Random(seed)
    by = collections.defaultdict(list)
    for k in sorted(ex):
        by[ex[k]["kind"]].append(k)
    for v in by.values():
        rng.shuffle(v)
    out, kinds = [], sorted(by, key=lambda k: -len(by[k]))
    while len(out) < n and any(by.values()):
        for kind in kinds:
            if by[kind] and len(out) < n:
                out.append(by[kind].pop())
    return out


def names_in(facts):
    names = set()
    for k in ("agent",):
        if isinstance(facts.get(k), dict) and facts[k].get("name"):
            names.add(facts[k]["name"])
    for key in ("on_camera", "agents", "observed", "busy_agents"):
        for a in facts.get(key) or []:
            if isinstance(a, dict) and a.get("name"):
                names.add(a["name"])
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+", help="caster-*.jsonl logs")
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--seed", type=int, default=6)
    ap.add_argument("--writers", default="cf=" + caster.DEFAULT_MODEL, help="comma list of kind=model, or 'none'")
    ap.add_argument("--timeout", type=float, default=12)
    ap.add_argument("--per-hour", type=float, default=300,
                    help="exchanges per stream hour, for cost per hour (shake7 aired about 310 an hour)")
    ap.add_argument("--md", help="also write the before/after as markdown here")
    ap.add_argument("--match", help="only exchanges whose aired lines match this regex (e.g. 'walk|motto|classic')")
    a = ap.parse_args()
    ex = load(a.logs)
    if a.match:
        ex = {k: v for k, v in ex.items() if any(re.search(a.match, l, re.I) for _, l in v["lines"])}
    keys = pick(ex, a.n, a.seed)
    roster = {"Astra", "Sol", "Luna", "Opus", "Sonnet", "Haiku", "Grok", "Gemini", "Muse"}
    for x in ex.values():
        roster |= names_in(x["facts"])
    writers = [] if a.writers == "none" else [caster.LLMWriter(*(s.split("=", 1) + [None])[:2], timeout=a.timeout)
                                              for s in a.writers.split(",")]
    md, before, filtered = [], [], []
    stats = {w.name: {"lines": [], "lat": [], "kept": 0, "asked": 0, "fails": 0} for w in writers}
    for i, k in enumerate(keys, 1):
        x = ex[k]
        facts = as_today(x["facts"], x["kind"], x["angle"])
        e = {"kind": x["kind"], "angle": x["angle"], "naturalist": x["naturalist"], "t": time.time(),
             "prio": caster.PRIORITY.get(x["kind"], 1)}
        md.append(f"### {i}. {x['kind']}{'/' + x['angle'] if x['angle'] else ''} ({os.path.basename(k[0])})")
        md.append("Aired:")
        for who, line in x["lines"]:
            before.append(line)
            new = caster.restyle(line)
            why = caster.style_fault(new, caster.known_text(facts))
            filtered.append(None if why else new)
            md.append(f"- {caster.CASTERS[who]['name']}: {line}")
            md.append(f"  - post-filter: " + (f"rejected ({why})" if why else new if new != line else "unchanged"))
        first = x["lines"][0][0]
        for w in writers:
            s = stats[w.name]
            t0 = time.time()
            try:
                cand = w.exchange(e, facts, [], first, max(2, len(x["lines"])), naturalist=bool(x["naturalist"]),
                                  show=caster.show_for(facts if facts.get("space") else {}))
            except Exception as err:
                s["fails"] += 1
                md.append(f"{w.name}: failed ({type(err).__name__}: {str(err)[:120]})")
                continue
            s["lat"].append(time.time() - t0)
            kept, why = [], None
            for who, line in cand[:4]:
                why = caster.check_line(line, facts, sorted(roster), [l for _, l in kept])
                if why:
                    break
                kept.append((who, line))
            kept = caster.tidy_exchange(kept)
            s["kept"] += len(kept)
            s["asked"] += max(2, len(x["lines"]))
            s["lines"] += [l for _, l in kept]
            md.append(f"{w.name} ({s['lat'][-1]:.1f}s):")
            md += [f"- {caster.CASTERS[who]['name']}: {line}" for who, line in kept]
            if why:
                md.append(f"- (cut: {why}: {cand[len(kept)][1] if len(cand) > len(kept) else ''})")
        md.append("")
    out = "\n".join(md)
    print(out)
    summary = [f"{len(keys)} exchanges, {len(before)} aired lines."]
    tb, tf = tells(before), tells([l for l in filtered if l])
    summary.append("| tell | aired | after the post-filter |" + "".join(f" {n} |" for n in stats))
    summary.append("|---|---|---|" + "---|" * len(stats))
    tw = {n: tells(s["lines"]) for n, s in stats.items()}
    nf = sum(1 for l in filtered if l)
    for k in TELLS:
        row = [f"{tb[k]}/{len(before)}", f"{tf[k]}/{nf}"] + [f"{tw[n][k]}/{len(s['lines'])}" for n, s in stats.items()]
        summary.append(f"| {k} | " + " | ".join(row) + " |")
    summary.append(f"Post-filter: {len(before) - nf} of {len(before)} aired lines rejected, "
                   f"{sum(1 for b, f in zip(before, filtered) if f and f != b)} rewritten.")
    for n, s in stats.items():
        w = next(w for w in writers if w.name == n)
        lat = sorted(s["lat"]) or [0]
        words = [len(l.split()) for l in s["lines"]] or [0]
        summary.append(f"{n}: kept {s['kept']}/{s['asked']} lines, {s['fails']} failed calls, latency median "
                       f"{statistics.median(lat):.1f}s p90 {lat[int(0.9 * (len(lat) - 1))]:.1f}s, "
                       f"{statistics.mean(words):.1f} words a line, ${(w.spent or w.equiv) / max(len(s['lat']), 1) * 1000:.2f}"
                       f" per 1,000 exchanges, ${(w.spent or w.equiv) / max(len(s['lat']), 1) * a.per_hour:.2f} per stream "
                       f"hour at {a.per_hour:.0f} exchanges" + (" (API-equivalent; claude -p runs on the subscription)"
                                                                if w.kind == "claude" else ""))
    print("\n".join(summary))
    if a.md:
        open(a.md, "w").write("\n".join(summary) + "\n\n" + out + "\n")


if __name__ == "__main__":
    main()
