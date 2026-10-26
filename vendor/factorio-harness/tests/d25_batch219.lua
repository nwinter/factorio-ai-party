-- Run from repository root: lua tests/d25_batch219.lua
-- d25 batch219 QAD1 (Sol #2394: Astra's queue configured modules on two of Sol's 13 machines on Asterion at tick
-- 64293983; mixed.lua split Sol's uptime watch twice on that tick, the second split kept a part of no ticks, and after
-- more edits the window from 64263843 was gone from the 3 parts kept; uptime@64263843/sol could not be read). A split
-- keeps the closed uptime watch whole as a segment, read by its id or segment_start as a done watch; a window begun on
-- the edit's own tick keeps no part; at most SEGMENTS, the first always kept.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,'should be refused'); return tostring(err) end
game={tick=1000}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3}}
local recipe={name='explosives',ingredients={{type='item',name='coal',amount=1},{type='item',name='sulfur',amount=1}}}
local surface={index=7,name='platform-7'}
local force={name='player'}
local ms={}
for k=1,13 do
  local x,y=k*4+0.5,10.5
  local e={valid=true,name='chemical-plant',type='assembling-machine',position={x=x,y=y},products_finished=0,status='working',unit_number=100+k,
    surface=surface,force=force,bounding_box={left_top={x=x-1.5,y=y-1.5},right_bottom={x=x+1.5,y=y+1.5}}}
  e.get_recipe=function() return recipe,{name='normal'} end
  e.get_fluid_count=function() return 0 end
  e.get_inventory=function() return {get_item_count=function() return 5 end,get_contents=function() return {} end} end
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
local positions={}
for k=1,13 do positions[k]={x=ms[k].position.x,y=10.5} end
local function start()
  U.handler(sol,{positions=positions,seconds=1200})
  st.uptime[1].call={action='uptime',args={positions=positions,seconds=1200}}  -- as runtime.lua's wrapper keeps it
end
local function run(to)
  while game.tick<to do
    game.tick=game.tick+1
    for _,e in ipairs(ms) do if game.tick%60==0 then e.products_finished=e.products_finished+1 end end
    U.tick(game.tick)
  end
end
start()
local first=st.uptime[1]
run(2000)
local at_edit=ms[5].products_finished
-- two configure steps of one queue on one tick, on two of its machines
eq(X.edit(ms[3],'configure modules by astra'),1)
eq(X.edit(ms[7],'configure modules by astra'),1)
local w=st.uptime[1]
eq(w.start,2000,'begun again at the edit'); assert(w~=first)
eq(#w.mixed.parts,1,'the window begun on the edit\'s tick keeps no part'); eq(w.mixed.parts[1].from_tick,1000); eq(w.mixed.parts[1].to_tick,2000)
eq(#w.mixed.edits,2)
eq(#w.segments,1); eq(w.segments[1],first); eq(first.ended_tick,2000); eq(first.result.done,true)
-- the closed window: done at the edit, read by its id as a done watch, its counts frozen there
run(2600)
local seg=U.handler(sol,{read=true,id='uptime@1000/sol'})
eq(seg.id,'uptime@1000/sol'); eq(seg.done,true); eq(seg.watching,nil); eq(seg.to_tick,2000); eq(seg.machines_total,13); eq(seg.samples,first.samples)
eq(seg.segment.segment_start,1000); eq(seg.segment.ended_tick,2000); eq(seg.segment.of,'uptime@2000/sol')
has(seg.segment.closed_by,'configure modules by astra on chemical-plant (12.5,10.5)')
local r5
for _,m in ipairs(seg.machines) do if m.index==5 then r5=m end end
eq(r5.completions,at_edit,'counted to the edit, not after'); assert(ms[5].products_finished>at_edit)
has(seg.line,'uptime segment uptime@1000/sol (closed at tick 2000 by configure modules by astra')
-- by segment_start, and another agent by id
eq(U.handler(sol,{read=true,segment_start=1000}).id,'uptime@1000/sol')
eq(U.handler(astra,{read=true,id='uptime@1000/sol',page=1,page_size=4}).agent,'sol')
eq(first.read_tick,nil,'a segment read does not mark the watch read')
-- the watch now: its own read, and its segments listed
local now=U.handler(sol,{})
eq(now.started_tick,2000); eq(#now.segments,1); eq(now.segments[1].id,'uptime@1000/sol'); eq(now.segments[1].machines,13); eq(now.segments[1].seconds,17)
has(now.segments_note,'uptime {read: true, id}')
eq(U.handler(sol,{read=true}).segments[1].segment_start,1000)
-- more edits: at most SEGMENTS, the first always kept, the second oldest dropped first
for _,t in ipairs({2700,2800,2900,3000}) do run(t); X.edit(ms[3],'configure modules by astra') end
w=st.uptime[1]
eq(w.start,3000); eq(#w.segments,4); eq(w.segments[1].start,1000,'the first kept'); eq(w.segments[2].start,2700); eq(w.segments_dropped,1)
eq(#w.mixed.parts,3,'mixed.parts keeps its 3')
eq(U.handler(sol,{read=true,id='uptime@1000/sol'}).machines_total,13,'the window as begun, readable after 5 splits')
has(refused(function() U.handler(sol,{read=true,id='uptime@2000/sol'}) end),'no uptime watch uptime@2000/sol is kept')
has(refused(function() U.handler(sol,{read=true,segment_start=2000}) end),'segment_start: no segment of that watch starts at tick 2000 (kept: 1000, 2700, 2800, 2900)')
-- their machines together bounded
U.SEGMENT_MACHINES=30
run(3100); X.edit(ms[3],'configure modules by astra')
eq(#st.uptime[1].segments,2,'13 machines each, at most 30 together'); eq(st.uptime[1].segments[1].start,1000)
U.SEGMENT_MACHINES=128
-- refused with no world, as at submit and in dry_run
has(refused(function() U.check_read({read=true,segment_start=-1}) end),'segment_start: a segment\'s start tick')
has(refused(function() U.check_read({segment_start=1000}) end),'id, agent and segment_start go with read: true')
U.check_read({read=true,segment_start=1000,page=2})
print('d25_batch219 QAD1 uptime segments: ok')
