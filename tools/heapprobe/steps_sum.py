import re, sys, statistics
rows=[(int(m[1]),float(m[2]),int(m[3])) for m in re.finditer(r"S (\d+) Duration: ([\d.]+)ms kb=(\d+)", open(sys.argv[1]).read())]
ms=sorted(r[1] for r in rows)
print(len(rows), 'steps; sum', round(sum(ms),1),'ms; median', round(statistics.median(ms),3), 'p90', round(ms[int(len(ms)*0.9)],3), 'p99', round(ms[int(len(ms)*0.99)],2), 'max', round(ms[-1],2))
top=sorted(rows,key=lambda r:-r[1])[:12]
print('longest (step, ms, heap MB):', [(r[0], round(r[1],2), round(r[2]/1024)) for r in top])
# phases: heap falling = sweep
fall=[r for i,r in enumerate(rows[1:],1) if r[2] < rows[i-1][2]]
print('steps where heap fell (sweep):', len(fall), 'first at', fall[0][0] if fall else None, 'sum ms in them', round(sum(r[1] for r in fall),1))
