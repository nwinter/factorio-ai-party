"""Audit complete profile windows including their first/last partial buckets; offline only."""
import json,sys
from pathlib import Path
from config import TREE
sys.path.insert(0,str(TREE / "tools/mt"))
from load_bench import SECOND
base=Path(sys.argv[1])
windows=json.loads(Path(str(base)+'.json').read_text())['windows']
lines=Path(str(base)+'.profile.log').read_text().splitlines()
out=[]
parts={}
for w in windows:
 lo=w['from_tick']; hi=w['until_tick'] if 'until_tick' in w else lo+60*w['seconds']
 first=lo//60*60; last=hi//60*60
 buckets={}
 for line in lines:
  m=SECOND.search(line)
  if m and first<=int(m[1])<=last:
   buckets.setdefault(int(m[1]),{})[m[3].strip()]={'n':int(m[2]),'ms':float(m[4])}
 for b in buckets.values():
  for key,value in b.items(): parts[key]=parts.get(key,0)+value['ms']
 ticks=sum(b['tick']['n'] for b in buckets.values() if 'tick' in b)
 tick_ms=sum(b['tick']['ms'] for b in buckets.values() if 'tick' in b)
 total_ms=sum(b['*']['ms'] for b in buckets.values() if '*' in b)
 out.append({'from_tick':lo,'until_tick':hi,'profiled_ticks':ticks,'tick_ms':tick_ms,'total_ms':total_ms,
   'tick_max':max(b['tick']['ms'] for b in buckets.values() if 'tick' in b),
   'total_max':max(b['*']['ms'] for b in buckets.values() if '*' in b),
   'boundary_buckets':{t:b for t,b in buckets.items() if 'tick' in b and b['tick']['n']!=60}})
ticks=sum(w['profiled_ticks'] for w in out)
result={'profiled_ticks':ticks,'profiled_game_seconds':ticks/60,
 'tick_ms_per_s':sum(w['tick_ms'] for w in out)*60/ticks,
 'total_ms_per_s':sum(w['total_ms'] for w in out)*60/ticks,
 'tick_max':max(w['tick_max'] for w in out),'total_max':max(w['total_max'] for w in out),'windows':out, 'parts_ms_per_s':{k:round(v*60/ticks,3) for k,v in sorted(parts.items(),key=lambda p:-p[1])}}
Path(str(base)+'-boundaries-audit.json').write_text(json.dumps(result,indent=1)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('windows','parts_ms_per_s')},indent=1))
