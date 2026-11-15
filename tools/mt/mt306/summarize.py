"""Read saved native evidence only; no server connection."""
import argparse,json,re,statistics,sys
from pathlib import Path
from config import TREE
sys.path.insert(0,str(TREE / "tools/mt"))
from load_bench import window_stats,SECOND
p=argparse.ArgumentParser();p.add_argument('base');p.add_argument('--log');a=p.parse_args()
base=Path(a.base)
bench=Path(str(base)+'.json')
if bench.exists():
 b=json.loads(bench.read_text()); windows=b['windows']; spans=[(w['from_tick'],w.get('until_tick',w['from_tick']+w['seconds']*60)) for w in windows]
else:
 b={}; ready=json.loads(Path(str(base)+'.json.ready').read_text());spans=[(ready['tick'],ready['until_tick'])]
text=Path(a.log or str(base)+'.profile.log').read_text()
kept=[];per={};totals={}
for line in text.splitlines():
 m=SECOND.search(line)
 if not m:continue
 t,key,ms=int(m[1]),m[3].strip(),float(m[4])
 if not any(lo<=t<hi for lo,hi in spans):continue
 per.setdefault(key,{})[t]=ms
 if not key.startswith('part ') and key!='*': totals[t]=totals.get(t,0)+ms
seconds=len(per.get('tick',{}))
out={'seconds':seconds,'ups':b.get('ups'),'windows':b.get('windows'),
 'parts':{k:{'avg_ms_per_s':round(sum(v.values())/max(1,seconds),3),'max_ms_per_s':max(v.values())}
          for k,v in sorted(per.items(),key=lambda p:-sum(p[1].values()))[:35]},
 'worst_total_seconds':sorted(totals.items(),key=lambda p:-p[1])[:8]}
rowsfile=Path(str(base)+'.jsonl')
if rowsfile.exists():
 rows=[json.loads(l) for l in rowsfile.read_text().splitlines()]
 out['calls']={'total':len(rows),'failures':[r for r in rows if not r['ok']],
  'startup_max_ms':max((r['ms'] for r in rows if r.get('phase')=='startup'),default=0),
  'startup_slowest':sorted([r for r in rows if r.get('phase')=='startup'],key=lambda r:-r['ms'])[:6]}
Path(str(base)+'-summary.json').write_text(json.dumps(out,indent=1)+'\n')
print(json.dumps({'seconds':seconds,'ups':out['ups'],'parts':dict(list(out['parts'].items())[:14]),
 'worst_total_seconds':out['worst_total_seconds'][:3], 'calls':{k:v for k,v in out.get('calls',{}).items() if k not in ('startup_slowest','failures')},
 'failed_calls':len(out.get('calls',{}).get('failures',[]))},indent=1))
