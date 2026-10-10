#!/usr/bin/env python3
"""Emit key research milestones and periodic summaries from one or more runs' scores.jsonl.

  tools/watch.py --summary-min 30 --stop-at 1610 runs/RUN_A runs/RUN_B
"""
import argparse, glob, json, os, subprocess, time

KEY = {'automation', 'logistic-science-pack', 'oil-processing', 'plastics', 'advanced-circuit', 'sulfur-processing',
       'chemical-science-pack', 'production-science-pack', 'utility-science-pack', 'rocket-silo', 'rocket-fuel',
       'low-density-structure', 'processing-unit', 'electric-energy-distribution-1', 'construction-robotics',
       'logistic-robotics', 'solar-energy', 'advanced-material-processing', 'military-science-pack', 'space-science-pack'}

ap = argparse.ArgumentParser()
ap.add_argument('runs', nargs='+')
ap.add_argument('--summary-min', type=float, default=30)
ap.add_argument('--stop-at', default='2400')
ap.add_argument('--max-sec', type=float, default=1790)
ap.add_argument('--worlds', default='', help='comma list of worlds to check for harness faults')
a = ap.parse_args()
seen, pos, last = {}, {}, {}
sup_pos, faulted, last_fault_check = {}, set(), 0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for r in a.runs:
    for log in glob.glob(f'{r}/*/supervisor.log'):
        sup_pos[log] = sum(1 for _ in open(log))
start = time.time()
for r in a.runs:
    f = f'{r}/scores.jsonl'
    pos[r] = 0
    if os.path.exists(f):
        for line in open(f):
            try:
                d = json.loads(line); seen[(r, d['world'])] = set(d['score'].get('research_done') or [])
            except Exception:
                pass
        pos[r] = sum(1 for _ in open(f))
while time.strftime('%H%M') < a.stop_at and time.time() - start < a.max_sec:
    for r in a.runs:
        f = f'{r}/scores.jsonl'
        if not os.path.exists(f):
            continue
        lines = open(f).read().splitlines()
        for line in lines[pos[r]:]:
            try:
                d = json.loads(line)
            except Exception:
                continue
            key = (r, d['world']); s = d['score']; done = set(s.get('research_done') or [])
            new = (done - seen.get(key, set())) & KEY; seen[key] = done
            tag = f"{os.path.basename(r)}/{d['world']}"
            if new:
                print(f"{d['t'][11:16]} {tag}: researched {', '.join(sorted(new))} (total {len(done)}, game {s['tick'] // 3600}m)", flush=True)
            if time.time() - last.get(key, start - a.summary_min * 60 + 300) >= a.summary_min * 60:
                last[key] = time.time(); p = s.get('produced') or {}
                print(f"{d['t'][11:16]} {tag}: game {s['tick'] // 3600}m, research {len(done)}, iron {p.get('iron-plate', 0)}, "
                      f"red {p.get('automation-science-pack', 0)}, green {p.get('logistic-science-pack', 0)}, "
                      f"blue {p.get('chemical-science-pack', 0)}, buildings {sum((s.get('entities') or {}).values())}", flush=True)
        pos[r] = len(lines)
    # Supervisor events (blocked agents, nudges) and harness runtime faults.
    for r in a.runs:
        for log in glob.glob(f'{r}/*/supervisor.log'):
            lines = open(log).read().splitlines()
            for line in lines[sup_pos.get(log, 0):]:
                if 'blocked' in line and sup_pos.get(log + ':blocked'):
                    continue
                print(f"{os.path.basename(os.path.dirname(log))} ({os.path.basename(r)}): {line}", flush=True)
                if 'blocked' in line:
                    sup_pos[log + ':blocked'] = 1
                else:
                    sup_pos.pop(log + ':blocked', None)
            sup_pos[log] = len(lines)
    if a.worlds and time.time() - last_fault_check > 120:
        last_fault_check = time.time()
        for w in a.worlds.split(','):
            try:
                out = subprocess.run([f'{ROOT}/bin/fh', 'call', 'status', '--format', 'json'], capture_output=True, text=True,
                                     env=dict(os.environ, POG_WORLD=w), timeout=30).stdout
                fault = json.loads(out).get('result', {}).get('runtime_fault')
            except Exception:
                fault = None
            if fault and w not in faulted:
                faulted.add(w); print(f"HARNESS FAULT in world {w}: {fault}", flush=True)
            elif not fault:
                faulted.discard(w)
    time.sleep(30)
