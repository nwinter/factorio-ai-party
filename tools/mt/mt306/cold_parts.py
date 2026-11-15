"""Summarize the first ten profiled game seconds, including the cold boundary bucket."""
import argparse
import json
import sys
from pathlib import Path
from config import TREE
sys.path.insert(0, str(TREE / 'tools/mt'))
from load_bench import SECOND

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('base')
a = p.parse_args()
base = Path(a.base)
start = json.loads(Path(str(base) + '.json.ready').read_text())['tick']
parts = {}
for line in Path(str(base) + '.profile.log').read_text().splitlines():
    m = SECOND.search(line)
    if not m or not start // 60 * 60 <= int(m[1]) < start + 600:
        continue
    tick, calls, key, ms = int(m[1]), int(m[2]), m[3].strip(), float(m[4])
    if key not in parts or ms > parts[key]['ms']:
        parts[key] = {'ms': ms, 'calls': calls, 'bucket_tick': tick}
result = {'start_tick': start, 'seconds': 10, 'parts': parts,
          'note': 'Aggregate named-part buckets, not individual-call latency; includes both boundary buckets.'}
Path(str(base) + '-cold-parts.json').write_text(json.dumps(result, indent=1) + '\n')
print(json.dumps({k: parts.get(k) for k in (
    '*', 'tick', 'part research.shift_block', 'part board.team', 'dispatch status',
    'part networks.alert_groups', 'part ground.alerts', 'part survey.summary', 'part threat.summary')}, indent=1))
