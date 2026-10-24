-- d24 batch146 PR1 (Sol #2152): delivery watch #305, 1 calcite from Needle to Nauvis's landing pad, ended reached when
-- another carrier's pod of 60 landed (received 0), and stopped counting while Needle's 8 pods brought 32. With from,
-- the watch ends only when its count is received from that platform; the stock test is its own field and line. With
-- none, either test ends it and ended_by says which. An ended watch counts pods on until its deadline.
-- Run from the harness root: lua tests/d24_batch146.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={calcite={}}}
local function stack(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'}} end
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end return t end
local nauvis={name='nauvis'}
nauvis.find_logistic_network_by_position=function() return {network_id=1} end
local held=0
local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-12,y=40},surface=nauvis,unit_number=77,
  get_inventory=function() return inv({}) end,get_item_count=function() return held end}
nauvis.find_entities_filtered=function(f) if f.position and f.position.x==-12 then return {pad} end return {} end
local force={name='player',is_chunk_charted=function() return true end}
local function platform(name,index,n)
  return {valid=true,name=name,index=index,surface={name='platform-'..index},paused=false,space_location={name='nauvis'},schedule={current=1,records={{station='nauvis'},{station='gleba'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return inv({stack('calcite',n)}) end,get_logistic_sections=function() return {sections_count=0} end}}
end
local needle=platform('Needle',6,32)
local other=platform('Kestrel IVb',7,60)
force.platforms={needle,other}
game.forces={player=force}; game.planets={nauvis={surface=nauvis}}
local fol={[6]={down={},up={}},[7]={down={},up={}}}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
  freight={where=function() return {stopped=true,at='nauvis'} end,receipts_since=function() return {} end,followed=function(pl) return fol[pl.index] end,spoils=function() return false end}}
local sol={name='sol',index=1,force=force,surface=nauvis}
local h={}
local unit=500
local function land(from,n,t)
  unit=unit+1
  local pinv=inv({stack('calcite',n)})
  local pod={valid=true,unit_number=unit,surface=nauvis,position={x=-12,y=40},cargo_pod_state='descending',cargo_pod_destination={station=pad},get_inventory=function() return pinv end}
  fol[from.index].down={{pod=pod,unit=unit,at='nauvis',tick=t-40}}
  game.tick=t-30; W.tick(t-30-(t-30)%60)
  W.pod_tick(t-1)
  pod.valid=false; held=held+n; game.tick=t; W.pod_tick(t)
  fol[from.index].down={}
end
local function pass(t) game.tick=t; W.tick(t-t%60) end

-- Sol's watch: 1 calcite from Needle; Kestrel IVb's pod of 60 lands first: the stock test is met, the watch stays open
W.call(sol,{item='calcite',count=1,to={position={x=-12,y=40},surface='nauvis'},deadline_min=60,from='Needle'})
local w=st.delivwatch.list[1]
W.lines(sol,h)
land(other,60,1600)
pass(1620); pass(1680)
eq(w.received,0,'Kestrel IVb\'s pod is not this watch\'s')
local row=W.call(sol,{id=w.id}).watches[1]
eq(row.state,'open','before: reached')
eq(row.stock.reached,true); eq(row.stock.ends_watch,false)
has(row.stock.line,'the stock test: the consumer holds 60, 0 at the start: 1 more reached; with from given it does not end the watch (it ends when 1 is received from Needle)')
local lines=W.lines(sol,h)
has(lines[#lines],'delivery watch #1 (1 calcite to cargo-landing-pad (-12,40) on nauvis): the stock test: the consumer holds 60 now (0 at the start), seen holding 1 more; with from given this does not end the watch: it ends when 1 is received from Needle (received 0 of 1')
-- Needle's first pod of 4: received, ended by the received total, still counting
land(needle,4,2200)
row=W.call(sol,{id=w.id}).watches[1]
eq(row.state,'received'); eq(row.ended_by,'received'); eq(row.reached_tick,2200); eq(row.counting,true)
has(row.line,'; ended by the received total, reached at tick 2200; still counting until the deadline')
lines=W.lines(sol,h)
has(lines[#lines],'received 4 of 1 in 1 pod by cargo-landing-pad (-12,40) on nauvis since the watch was set, the last at tick 2200, in time')
has(lines[#lines],'reached at tick 2200; still counting until the deadline (')
-- its 7 more pods of 4 add to received after the end
for k=1,7 do land(needle,4,2200+k*300) end
eq(w.received,32); eq(w.received_pods,8); eq(w.received_by['Needle'],32)
row=W.call(sol,{id=w.id}).watches[1]
eq(row.received.count,32); eq(row.state,'received')
-- the deadline ends the count, told with the total; kept, then dropped KEEP ticks after
pass(w.deadline+60)
eq(w.counting,nil); assert(w.ended and w.ended>=w.deadline,'ended at the deadline: '..tostring(w.ended))
lines=W.lines(sol,h)
has(lines[#lines],'the deadline ended its count: received 32 of 1 in 8 pods')
land(needle,4,w.deadline+400)
eq(w.received,32,'not counted after the deadline')
row=W.call(sol,{id=w.id}).watches[1]
has(row.line,'; ended by the received total, reached at tick 2200;')

-- no from: the stock test ends it (Kestrel IVb's pod), said; it counts on: a later pod adds to received and by_platform
game.tick=200000; held=0
W.call(sol,{item='calcite',count=50,to={position={x=-12,y=40},surface='nauvis'},deadline_min=60})
local w2=st.delivwatch.list[#st.delivwatch.list]
W.lines(sol,h)
land(other,60,200600)
pass(200620); pass(200680)
row=W.call(sol,{id=w2.id}).watches[1]
eq(row.state,'reached'); eq(row.ended_by,'stock'); eq(row.counting,true); eq(row.stock.ends_watch,true)
lines=W.lines(sol,h)
local ended
for _,l in ipairs(lines) do if l:find('reached by the stock test',1,true) then ended=l end end
has(ended,'delivery watch #2: reached by the stock test: cargo-landing-pad (-12,40) holds 60 calcite (0 when the watch was set), in time')
has(ended,'still counting until the deadline')
land(needle,4,201200)
eq(w2.received,64); eq(w2.received_by['Needle'],4); eq(w2.received_by['Kestrel IVb'],60)
row=W.call(sol,{id=w2.id}).watches[1]
has(row.line,'(from Kestrel IVb 60, Needle 4)')
has(row.line,'; ended by the stock test, reached at tick ')
game,defines,prototypes=nil,nil,nil
print('d24_batch146 PR1 delivery watch: from ends by receipt only, counting on after the end: ok')
