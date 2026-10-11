#!/usr/bin/env python3
"""Summarise a caster log: lines, voices, latency, cost, and whether a caster clip started over an agent clip.

  python3 tools/stream/caster_report.py [tools/stream/logs/caster-*.jsonl]   (default: the newest log)

Clip times are push times plus clip length; the page plays a clip as soon as it arrives unless its channel is busy,
so a caster clip pushed inside an agent clip's span is a caster talking over an agent (ducked, but still overlap).
"""
import glob, json, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
path = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob(os.path.join(HERE, "logs", "caster-*.jsonl")),
                                                  key=os.path.getmtime)
rows = [json.loads(l) for l in open(path) if l.strip()]
clips = [r for r in rows if r.get("type") in ("caster", "agent") and r.get("pushed")]
if not clips:
    sys.exit(f"{path}: no pushed clips")
span = max(r["t"] for r in rows) - min(r["t"] for r in rows)
cast = [r for r in clips if r["type"] == "caster"]
agent = [r for r in clips if r["type"] == "agent"]
print(f"{os.path.basename(path)}: {span / 60:.1f} min, {len(cast)} caster clips, {len(agent)} agent clips")
if len(cast) > 1:
    gaps = [b["t"] - a["t"] for a, b in zip(cast, cast[1:])]
    print(f"caster gap: median {statistics.median(gaps):.0f} s, min {min(gaps):.0f} s")
    # silence: time between the end of one clip (either channel) and the start of the next
    spans = sorted((r["t"], r["t"] + r.get("seconds", 0)) for r in clips)
    quiet, end = [], spans[0][1]
    for s, e in spans[1:]:
        if s > end:
            quiet.append(s - end)
        end = max(end, e)
    talk = sum(e - s for s, e in spans)
    first, last = spans[0][0], max(e for _, e in spans)
    print(f"airtime: voices {100 * min(1, talk / max(1e-6, last - first)):.0f}% of the cast; silences median "
          f"{statistics.median(quiet) if quiet else 0:.1f} s, longest {max(quiet) if quiet else 0:.1f} s")
    ex = {}
    for r in cast:
        ex.setdefault(r.get("exchange"), []).append(r)
    if len(ex) > 1 or None not in ex:
        sizes = [len(v) for k, v in ex.items() if k is not None]
        print(f"exchanges: {len(sizes)}, lines per exchange {statistics.mean(sizes):.1f}; angles "
              f"{sorted({r.get('angle') or r.get('event') for r in cast})}; naturalist "
              f"{sum(1 for v in ex.values() if v[0].get('naturalist') or v[0].get('angle') == 'naturalist')}")
for key in ("write_latency", "tts_latency", "seconds"):
    vals = [r[key] for r in clips if isinstance(r.get(key), (int, float))]
    if vals:
        print(f"{key}: median {statistics.median(vals):.2f}, max {max(vals):.2f}")
backends = {}
for r in cast:
    backends[r.get("backend")] = backends.get(r.get("backend"), 0) + 1
print("caster writer:", backends, "| rejected:", sum(1 for r in cast if r.get("rejected")))
dec = [r for r in rows if r.get("type") == "chat_decision"]
labels = {}
for r in dec:
    labels[r["label"]] = labels.get(r["label"], 0) + 1
print(f"chat: {len(dec)} messages, labels {labels}, voiced {len(agent)}")
over = [(c["line"][:50], a["line"][:40]) for c in cast for a in agent
        if a["t"] - 0.2 <= c["t"] < a["t"] + a.get("seconds", 0)]
same = [(x["line"][:40], y["line"][:40]) for ch in (cast, agent) for x, y in zip(ch, ch[1:])
        if y["t"] < x["t"] + x.get("seconds", 0)]
print(f"caster clips pushed during an agent clip: {len(over)}", *[f"\n  {c!r} over {a!r}" for c, a in over])
under = [(a["line"][:40], c["line"][:50]) for c in cast for a in agent
         if c["t"] - 0.2 <= a["t"] < c["t"] + c.get("seconds", 0)]
print(f"agent clips pushed during a caster clip (caster ducks): {len(under)}",
      *[f"\n  {a!r} over {c!r}" for a, c in under])
print(f"same-channel clips pushed before the previous one ended (queued, not overlapping): {len(same)}")
costs = [r for r in rows if r.get("type") == "cost"]
if costs:
    print("cost:", {k: v for k, v in costs[-1].items() if k not in ("type", "t")})
