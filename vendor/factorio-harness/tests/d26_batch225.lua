-- Run from repository root: lua tests/d26_batch225.lua
-- d26 batch225 QR (Sol #2413: Astra's 41-machine uptime@65848202/astra could not be read once Astra began
-- uptime@65920807; Sol needed its shortage timing). A new watch keeps the agent's previous one as a done watch
-- (finished at that tick if still running, never sampled again), read by its id; at most KEPT, their machines at most
-- KEPT_MACHINES, the oldest dropped first and logged; a read of a dropped id says when and why.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
local recipe={name='explosives',ingredients={{type='item',name='coal',amount=1},{type='item',name='sulfur',amount=1}}}
local surface={index=7,name='nauvis'}
local force={name='player'}
local ms={}
for k=1,48 do
  local x,y=k*4+0.5,10.5
  local e={valid=true,name='chemical-plant',type='assembling-machine',position={x=x,y=y},products_finished=0,status='working',unit_number=100+k,have=5,
    surface=surface,force=force,bounding_box={left_top={x=x-1.5,y=y-1.5},right_bottom={x=x+1.5,y=y+1.5}}}
  e.get_recipe=function() return recipe,{name='normal'} end
  e.get_fluid_count=function() return 0 end
  e.get_inventory=function() return {get_item_count=function() return e.have end,get_contents=function() return {} end} end
  ms[k]=e
end
local st={}
local names={'sol','astra'}
local Ms=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return st end,who_index=function(i) return names[i] end}
local U
U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,
  remote_entity=function(_,t) for _,e in ipairs(ms) do if e.position.x==t.position.x then return e end end error('none') end,
  status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=30,productivity=0} end,
  who_index=function(i) return names[i] end,watch_id=function(kind,job,i) return Ms.id(kind,job,i) end}
local sol,astra={index=1,valid=true},{index=2,valid=true}
local X=dofile('mod/agent-harness_0.1.0/mixed.lua'){state=function() return st end,player=function(i) return ({sol,astra})[i] end,
  who_index=function(i) return names[i] end,call=function(p,action,args) return U.handler(p,args) end,
  read={uptime=function(job) return U.result(job,false) end},close={uptime=function(job,new,tick,why) return U.close(job,new,tick,why) end}}
local function at(a,b) local out={} for k=a,b do out[#out+1]={x=ms[k].position.x,y=10.5} end return out end
local function start(p,list,secs)
  local r=U.handler(p,{positions=list,seconds=secs})
  st.uptime[p.index].call={action='uptime',args={positions=list,seconds=secs}}  -- as runtime.lua's wrapper keeps it
  return r
end
local function run(to)
  while game.tick<to do
    game.tick=game.tick+1
    for _,e in ipairs(ms) do if game.tick%60==0 and e.status=='working' then e.products_finished=e.products_finished+1 end end
    U.tick(game.tick)
  end
end

-- Astra's 41-machine watch; machine 5 short of coal from tick 1300 to 1600
start(astra,at(1,41),1200)
local first=st.uptime[2]
run(1300); ms[5].status,ms[5].have='item_ingredient_shortage',0
run(1600); ms[5].status,ms[5].have='working',5
run(2000)
local at_new=ms[5].products_finished
-- a new watch: the running one is finished at this tick and kept
local r=start(astra,at(1,13),600)
eq(r.id,'uptime@2000/astra')
eq(#r.kept,1); eq(r.kept[1].id,'uptime@1000/astra'); eq(r.kept[1].machines,41); eq(r.kept[1].ended_tick,2000); eq(r.kept[1].kept_tick,2000); eq(r.dropped,nil)
has(r.replaced,'was finished at this tick and kept as uptime@1000/astra')
has(r.line,'; kept, read by uptime {read: true, id}: uptime@1000/astra (41 machines)')
has(r.kept_note,'at most 4, their machines (their segments\' included) together at most 96')
local w=st.uptime[2]
eq(w.kept[1],first); eq(first.result.done,true); eq(first.result.lines,nil); eq(first.result.group_lines,nil); eq(#first.result.groups,1); eq(first.ended_tick,2000); eq(first.closed_by,'finished 1183s early: a new watch began')
for _,m in ipairs(first.machines) do eq(m.e,nil,'entity refs let go') end
-- no work in the tick: never sampled again
local samples=first.samples
run(2600)
eq(first.samples,samples)
-- another agent reads it by id: done at 2000, its counts and shortage timing frozen there
local k=U.handler(sol,{read=true,id='uptime@1000/astra'})
eq(k.done,true); eq(k.watching,nil); eq(k.agent,'astra'); eq(k.machines_total,41); eq(k.to_tick,2000); eq(k.pages,3)
eq(k.kept_watch.by,'uptime@2000/astra'); eq(k.kept_watch.kept_tick,2000); eq(k.kept_watch.ended_tick,2000)
has(k.line,'uptime watch uptime@1000/astra of astra (done at tick 2000, finished 1183s early: a new watch began; kept since uptime@2000/astra began, ')
local r5
for _,m in ipairs(k.machines) do if m.index==5 then r5=m end end
eq(r5.completions,at_new,'counted to 2000'); assert(ms[5].products_finished>at_new)
local sc,sh=r5.short_counts['coal'],first.machines[5].short['coal']
eq(sc.first_tick,sh.first); eq(sc.last_tick,sh.last); eq(sc.samples,sh.samples); eq(sc.samples,5)
assert(sc.first_tick>1300 and sc.first_tick<=1360 and sc.last_tick>=1540 and sc.last_tick<1600,sc.first_tick..'-'..sc.last_tick)
eq(k.kept,nil,'a kept watch keeps none')
-- the watch now lists it: uptime {} and the paged read
local now=U.handler(astra,{})
eq(now.started_tick,2000); eq(#now.kept,1); eq(now.kept[1].id,'uptime@1000/astra'); eq(now.kept[1].seconds,17); eq(now.kept[1].samples,samples)
has(now.kept_note,'uptime {read: true, id}')
eq(#U.handler(astra,{read=true}).kept,1)
-- the measures card reads the watch now only
eq(Ms.card(2)[1].id,'uptime@2000/astra')

-- a watch done at its end, then a new one: kept as it ended, no closed_by
run(2000+600*60+60)
eq(w.result.done,true)
local before=#st.uptime[2].kept
r=start(astra,at(1,41),600)
local t2=game.tick
eq(#r.kept,before+1); eq(r.kept[2].id,'uptime@2000/astra'); eq(r.kept[2].ended_tick,2000+600*60); eq(r.kept[2].closed_by,nil); eq(r.replaced,nil)
-- the machine bound: 41 + 13 + 41 kept is 95; another 41-machine one makes 136 > 96: the oldest goes
run(t2+600)
r=start(astra,at(1,41),600)
local t25=game.tick
eq(#r.kept,3); eq(r.dropped,nil)
run(t25+600)
r=start(astra,at(1,13),600)
eq(#r.kept,3); eq(r.kept[1].id,'uptime@2000/astra'); eq(r.kept[2].id,'uptime@'..t2..'/astra'); eq(r.kept[3].id,'uptime@'..t25..'/astra')
eq(#r.dropped,1); eq(r.dropped[1].id,'uptime@1000/astra'); eq(r.dropped[1].machines,41); has(r.dropped[1].why,'the kept watches\' machines over 96')
has(r.line,'; dropped: uptime@1000/astra (41 machines) (the kept watches\' machines over 96)')
local t3=game.tick
-- a read of the dropped id: when, why, and what is kept
local e=refused(function() U.handler(sol,{read=true,id='uptime@1000/astra'}) end)
has(e,'uptime watch uptime@1000/astra (41 machines) was dropped at tick '..t3..', when uptime@'..t3..'/astra began: the kept watches\' machines over 96; kept: ')
has(e,'uptime@2000/astra (13 machines)')
eq(#U.handler(astra,{}).kept_dropped,1); eq(U.handler(astra,{}).kept_dropped[1].dropped_tick,t3)

-- the count bound: Sol's 1-machine watches, 4 kept, the fifth start drops the oldest
local ids={}
for n=1,6 do
  run(game.tick+120)
  r=start(sol,at(42,42),60)
  ids[n]=r.id
end
eq(#r.kept,4); eq(r.kept[1].id,ids[2]); eq(r.kept[4].id,ids[5])
eq(#r.dropped,1); eq(r.dropped[1].id,ids[1]); has(r.dropped[1].why,'more than 4 watches kept')
eq(#st.uptime[1].kept_dropped,1)
has(refused(function() U.handler(astra,{read=true,id=ids[1]}) end),'was dropped at tick')
eq(U.handler(astra,{read=true,id=ids[3]}).done,true)
-- the drop log keeps the last 8
for n=1,8 do run(game.tick+120); start(sol,at(42,42),60) end
eq(#st.uptime[1].kept_dropped,8)

-- a watch begun on the same tick holds nothing: not kept
local c=#st.uptime[1].kept
run(game.tick+120)
start(sol,at(43,43),60); r=start(sol,at(44,44),60)
eq(#r.kept,c); assert(r.kept[c].id~='uptime@'..game.tick..'/sol')

-- a split (an edit on a watched machine): the old window is a segment, the kept ones carry on, none dropped
run(game.tick+120)
local cur=st.uptime[2]
local kept=#cur.kept
local logged=#cur.kept_dropped
eq(X.edit(ms[3],'configure modules by sol'),1)
local nw=st.uptime[2]
assert(nw~=cur); eq(#nw.kept,kept); eq(#nw.kept_dropped,logged); eq(#nw.segments,1); eq(nw.segments[1],cur); eq(cur.splitting,nil)
for _,x in ipairs(nw.kept) do assert(x~=cur,'a segment, not kept') end
-- its next start keeps it with the segment, the machines counted with its segment's
run(game.tick+120)
r=start(astra,at(45,45),60)
local last=st.uptime[2].kept[#st.uptime[2].kept]
eq(last,nw); eq(r.kept[#r.kept].segments,1)
-- the segment of a kept watch reads by its id
eq(U.handler(sol,{read=true,id=U.kept_rows(st.uptime[2],2)[#r.kept].id}).kept_watch.by,r.id)
eq(U.handler(sol,{read=true,id=Ms.id('uptime',cur,2)}).segment.of,Ms.id('uptime',nw,2))

-- a store from before this runtime (no kept) starts as before
st.uptime[1]={start=game.tick-60,until_tick=game.tick+600,next_tick=game.tick+1,seconds=600,samples=1,sampled=game.tick-60,machines={}}
run(game.tick+1)
r=start(sol,at(42,42),60)
eq(#r.kept,1); has(r.replaced,'kept as uptime@')
print('d26_batch225 QR uptime kept watches: ok')
