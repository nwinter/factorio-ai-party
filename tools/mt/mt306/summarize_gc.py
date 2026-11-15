import json,re,sys,statistics
from pathlib import Path
from config import TREE
sys.path.insert(0,str(TREE / "tools/mt"))
from load_bench import window_stats
p=Path(sys.argv[1]);rows=json.loads(p.read_text());log=p.with_suffix('.profile.log').read_text()
out={'original':rows[0]['original'],'settings':[],'alloc':[],'restored':rows[-1]}
for row in rows:
 if 'stats' not in row:continue
 start=row['profile']; warm=window_stats(log,start['tick']+30*60,start['until_tick'])
 out['settings'].append({'pause':row['pause'],'stepmul':row['stepmul'],'full':row['stats'],'after_30s':warm,
                         'ups_min':min(row['ups']) if row['ups'] else None,'ups_median':statistics.median(row['ups']) if row['ups'] else None})
for line in log.splitlines():
 m=re.search(r'agent-harness profile alloc ticks=(\d+) n=(\d+) key=(.+) kb=(\d+) gc_inside=(\d+)',line)
 if m:
  ticks,n,key,kb,gc=int(m[1]),int(m[2]),m[3].strip(),int(m[4]),int(m[5])
  out['alloc'].append({'key':key,'kb':kb,'kb_per_game_s':round(kb/(ticks/60),2),'bytes_per_call':round(kb*1024/max(1,n),2),'calls':n,'gc_inside':gc})
out['alloc'].sort(key=lambda r:-r['kb'])
p.with_name(p.stem+'-summary.json').write_text(json.dumps(out,indent=1)+'\n')
print(json.dumps({'original':out['original'],'settings':[{'pause':r['pause'],'stepmul':r['stepmul'],'tick':r['after_30s']['tick_ms_per_s'],'heap':r['after_30s']['heap_mb'],'ups_min':r['ups_min']} for r in out['settings']], 'alloc':out['alloc'][:15],'restored':out['restored']},indent=1))
