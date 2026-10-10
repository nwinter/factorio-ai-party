#!/usr/bin/env python3
"""Summarize a run's scores.jsonl: tools/report.py runs/RUN_ID"""
import json, sys
from collections import defaultdict

run = sys.argv[1]
rows = defaultdict(list)
for line in open(f"{run}/scores.jsonl"):
    d = json.loads(line)
    rows[d["world"]].append(d)

KEY = ["iron-plate", "copper-plate", "iron-gear-wheel", "electronic-circuit", "automation-science-pack",
       "logistic-science-pack"]
for world, snaps in sorted(rows.items()):
    print(f"== world {world}")
    print(f"{'wall':>5} {'game':>6} {'res':>3}  " + " ".join(f"{k[:10]:>10}" for k in KEY) + "  entities")
    first_research = {}
    for d in snaps:
        s = d["score"]
        for r in s.get("research_done") or []:
            first_research.setdefault(r, (d["t"][11:16], s["tick"] // 60))
        p = s.get("produced") or {}
        ents = s.get("entities") or {}
        print(f"{d['t'][11:16]:>5} {s['tick'] // 3600:>4}m{(s['tick'] // 60) % 60:02d} {len(s.get('research_done') or []):>3}  "
              + " ".join(f"{p.get(k, 0):>10}" for k in KEY) + "  "
              + ", ".join(f"{k}:{v}" for k, v in sorted(ents.items())))
    for r, (wall, sec) in sorted(first_research.items(), key=lambda x: x[1][1]):
        print(f"   researched {r} by game {sec // 60}m{sec % 60:02d} (wall {wall})")
