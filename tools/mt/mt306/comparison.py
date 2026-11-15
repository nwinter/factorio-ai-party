"""Build a compact matched comparison from completed, boundary-audited native runs."""
import argparse
import json
import sys
from pathlib import Path
from config import TREE
sys.path.insert(0, str(TREE / 'tools/mt'))
from load_bench import profile_completion

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('after', type=Path)
p.add_argument('--label', default='after-cp7')
a = p.parse_args()

def read(folder, name):
    return json.loads((folder / name).read_text())

out = {'baseline': {}, 'after': {}}
for key, folder, label in [('baseline', a.baseline, 'baseline-matched'), ('after', a.after, a.label)]:
    for phase in ('standins', 'all'):
        stem = label + '-' + phase
        audit = read(folder, stem + '-boundaries-audit.json')
        summary = read(folder, stem + '-summary.json')
        windows = summary['windows']
        log = (folder / (stem + '.profile.log')).read_text()
        for w in windows:
            coverage = profile_completion(log, w['from_tick'], w['until_tick'])
            assert coverage['complete'] and w.get('dropped_lines') == 0, coverage
        out[key][phase] = {k: v for k, v in audit.items() if k != 'windows'}
        out[key][phase].update(ups=summary['ups'], calls=summary['calls'], windows=len(windows),
            heap_min=min(w['heap_mb']['min'] for w in windows), heap_max=max(w['heap_mb']['max'] for w in windows))

out['changes_percent'] = {phase: {key: round((out['after'][phase][key] / out['baseline'][phase][key] - 1) * 100, 2)
    for key in ('tick_ms_per_s', 'total_ms_per_s', 'tick_max', 'total_max')}
    for phase in ('standins', 'all')}
target = a.after / (a.label + '-comparison.json')
target.write_text(json.dumps(out, indent=1) + '\n')
for phase in ('standins', 'all'):
    print(phase, json.dumps({key: {m: out[key][phase][m] for m in (
        'tick_ms_per_s', 'total_ms_per_s', 'tick_max', 'total_max', 'ups', 'heap_min', 'heap_max')}
        for key in ('baseline', 'after')}))
