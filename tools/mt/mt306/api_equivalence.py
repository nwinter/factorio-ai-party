"""Native read-only checks for the proposed engine-count fast paths; run between measured phases."""
import json,subprocess
from padlib import lua,raw,record
import os
from config import TREE
LUA=os.environ.get('LUA_BIN','lua')
TREE=TREE/'vendor/factorio-harness'
text=subprocess.check_output([LUA,'-e',"for _,r in ipairs(dofile('mod/agent-harness_0.1.0/unlocks.lua')) do for _,n in ipairs(r[2]) do print(n) end end"],cwd=TREE,text=True)
names='{'+','.join(json.dumps(n) for n in sorted(set(text.splitlines())))+'}'
r=lua('''local names='''+names+'''
local out={tick=game.tick,presence_checks=0,mismatches={},belts=0,empty=0,item_count_errors=0,empty_mismatches={}}
for _,name in ipairs(names) do if prototypes.entity[name] then
 for _,fname in ipairs({'red','blue','green','yellow'}) do
  local f=game.forces[fname]; local old=0
  for _,sf in pairs(game.surfaces) do old=old+sf.count_entities_filtered{force=f,name=name,limit=1}; if old>0 then break end end
  local new=f.get_entity_count(name); out.presence_checks=out.presence_checks+1
  if (old>0)~=(new>0) then out.mismatches[#out.mismatches+1]={force=fname,name=name,old=old,new=new} end
 end
end end
local es=game.surfaces.nauvis.find_entities_filtered{type={'transport-belt','underground-belt','splitter'},limit=1000}
for _,e in ipairs(es) do
 out.belts=out.belts+1
 local ok,n=pcall(e.get_item_count)
 if not ok then out.item_count_errors=out.item_count_errors+1
 elseif n==0 then
  out.empty=out.empty+1; local sum=0
  for i=1,e.get_max_transport_line_index() do
   for _,st in ipairs(e.get_transport_line(i).get_contents()) do sum=sum+st.count end
  end
  if sum>0 then out.empty_mismatches[#out.empty_mismatches+1]={name=e.name,unit=e.unit_number,items=sum} end
 end
end
rcon.print(helpers.table_to_json(out))
''')
record('api-equivalence',r)
print(json.dumps(r),flush=True)
assert not r['mismatches'] and not r['empty_mismatches'],r

# Alternating native timings on the same 1,000 belts. GC stays enabled;
# preserve each observation rather than presenting one tail as the mean.
code="""
local es=game.surfaces.nauvis.find_entities_filtered{type={'transport-belt','underground-belt','splitter'},limit=1000}
local function count(skip_empty)
 local sum=0
 for _,e in ipairs(es) do
  if not skip_empty or e.get_item_count()>0 then
   for i=1,e.get_max_transport_line_index() do
    for _,st in ipairs(e.get_transport_line(i).get_contents()) do sum=sum+st.count end
   end
  end
 end
 return sum
end
for i=1,8 do
 local p=helpers.create_profiler(); local old=count(false); p.stop()
 local q=helpers.create_profiler(); local new=count(true); q.stop()
 assert(old==new,'belt fast path changed the aggregate')
 rcon.print({'','mt306 belt iteration=',i,' old=',p,' guarded=',q,' total=',old})
end
"""
print(raw('/silent-command '+ ' '.join(code.splitlines())),flush=True)
