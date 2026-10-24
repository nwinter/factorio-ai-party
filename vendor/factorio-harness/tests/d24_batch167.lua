-- Run from the harness root: lua tests/d24_batch167.lua
-- d24 batch167 QJ1 (Sol #2224): watch 331, thruster from Kestrel IVb to Aquilo's pad (-8,-22), read the landed stage 2
-- while received, pods and arrivals read 0: the pod held 2 legendary thrusters, and in 2.0.77 get_item_count(name)
-- counts normal quality only, so the watch never followed the pod, while freight's receipt (cargo by name, every
-- quality) landed it. Now delivery_watch takes quality (or item name@quality); with none it counts every quality and
-- says so; received, arrivals, the landed stage and the stock test count by that rule, from the same arrivals.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s and tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={thruster={}},quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0,hidden=true}}}
local function stack(name,count,q) return {valid_for_read=true,name=name,count=count,quality={name=q}} end
-- an inventory as 2.0.77 counts it: get_item_count(name) normal only, get_item_count{name, quality} that quality
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n)
    local name,q=type(n)=='table' and n.name or n,type(n)=='table' and n.quality or 'normal'
    local c=0 for _,x in ipairs(list) do if x.name==name and x.quality.name==q then c=c+x.count end end return c end
  return t end
local aquilo={name='aquilo'}
aquilo.find_logistic_network_by_position=function() return {network_id=4} end
-- Aquilo's pad (-8,-22): 13 normal thrusters in it (the normal-only where_is's count), the consumer
local pad_items={stack('thruster',13,'normal')}
local pad=ud{valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=-8,y=-22},surface=aquilo,unit_number=22,
  get_inventory=function() return inv(pad_items) end,get_item_count=function(n) return inv(pad_items).get_item_count(n) end}
aquilo.find_entities_filtered=function(f) if f.position and f.position.x==-8 then return {pad} end return {} end
local force={name='player',is_chunk_charted=function() return true end}
local psurf={name='platform-9'}
local hub_items={stack('thruster',2,'legendary')}
local pl={valid=true,name='Kestrel IVb',index=9,surface=psurf,paused=false,space_location={name='aquilo'},schedule={current=1,records={{station='aquilo'}}},
  hub={valid=true,type='space-platform-hub',get_inventory=function() return inv(hub_items) end,get_logistic_sections=function() return {sections_count=0} end}}
force.platforms={pl}
game.forces={player=force}; game.planets={aquilo={surface=aquilo},nauvis={surface={name='nauvis'}}}
local fol={down={},up={}}
local receipts={}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
  freight={where=function() return {at='aquilo',stopped=true} end,receipts_since=function() return receipts end,followed=function() return fol end,spoils=function() return false end}}
if W.reset_qualities then W.reset_qualities() end
local sol={name='sol',index=1,force=force,surface=aquilo}
-- Kestrel IVb's pod of 2 legendary thrusters into the pad, followed by the watch pass, gone at tick t
local unit=35584052
local function land(t)
  unit=unit+1
  hub_items={}
  local pinv=inv({stack('thruster',2,'legendary')})
  local pod={valid=true,unit_number=unit,surface=aquilo,position={x=-8,y=-22},cargo_pod_destination={station=pad},get_inventory=function() return pinv end}
  fol.down={{pod=pod,unit=unit,at='aquilo',tick=t-40}}
  game.tick=t-30; W.tick(t-30-(t-30)%60)
  W.pod_tick(t-1)
  pod.valid=false; pad_items[#pad_items+1]=stack('thruster',2,'legendary'); game.tick=t; W.pod_tick(t)
  fol.down={}
  receipts={{tick=t,kind='received',where='cargo-landing-pad (-8,-22) on aquilo',cargo={thruster=2},cargo_q={['thruster@legendary']=2},unit=unit,
    dest={pad='cargo-landing-pad',position={x=-8,y=-22},surface='aquilo'},stop='aquilo'}}
end

-- no quality given: every quality counted, and said
do
  local r=W.call(sol,{item='thruster',count=2,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=30,from='Kestrel IVb'})
  eq(r.watch.counts,'every quality (no quality given)'); eq(r.watch.quality,nil)
  has(r.line,'; counts every quality (no quality given)')
  eq(r.watch.at_start,13,'13 normal at the start')
  local w=st.delivwatch.list[1]
  has(w.stages.loaded.text,'Kestrel IVb\'s hub holds 2 thruster')
  land(2000)
  game.tick=2040; W.tick(2040)
  eq(w.received,2,'2 legendary received'); eq(w.received_pods,1); eq(w.state,'received')
  local row=W.row(w)
  eq(#row.arrivals,1); eq(row.arrivals[1].count,2); eq(row.arrivals[1].by_quality.legendary,2); eq(row.arrivals[1].by_quality.normal,nil)
  eq(row.arrivals[1].stacks[1].quality,'legendary'); eq(row.arrivals[1].counted_quality,'every quality')
  has(row.arrivals[1].text,'2 thruster (legendary 2; it does not spoil')
  -- the landed stage and received: the same pod
  local landed
  for _,s in ipairs(row.stages) do if s.stage=='landed' then landed=s end end
  eq(landed.text,'2 thruster received by cargo-landing-pad (-8,-22) on aquilo'); eq(landed.tick,2000)
  eq(row.stock.held,15); has(row.stock.line,'the consumer holds 15, 13 at the start: 2 more reached')
end
print('d24_batch167 QJ1 delivery_watch, no quality: 2 legendary received, landed the same pod: ok')

-- quality legendary: that quality only, the stock test too
do
  st.delivwatch=nil; pad_items={stack('thruster',13,'normal')}; hub_items={stack('thruster',2,'legendary')}; game.tick=5000
  local r=W.call(sol,{item='thruster',quality='legendary',count=2,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=30,from='Kestrel IVb'})
  eq(r.watch.counts,'legendary quality only'); eq(r.watch.at_start,0,'no legendary in the pad at the start')
  has(r.line,'delivery watch #1: 2 thruster@legendary to cargo-landing-pad (-8,-22) on aquilo')
  local w=st.delivwatch.list[1]
  land(6000)
  game.tick=6040; W.tick(6040)
  eq(w.received,2); eq(w.state,'received'); eq(W.row(w).stock.held,2)
  has(W.row(w).arrivals[1].text,'2 thruster@legendary (legendary 2;')
end
print('d24_batch167 QJ1 delivery_watch, quality legendary: ok')

-- quality normal: the legendary pod is none of it: not followed, not landed, not received (they agree), no diversion
do
  st.delivwatch=nil; pad_items={stack('thruster',13,'normal')}; hub_items={stack('thruster',2,'legendary')}; game.tick=9000
  local r=W.call(sol,{item='thruster',quality='normal',count=2,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=30,from='Kestrel IVb'})
  eq(r.watch.at_start,13)
  local w=st.delivwatch.list[1]
  eq(w.stages.loaded,nil,'the hub holds no normal thruster')
  land(10000)
  game.tick=10040; W.tick(10040)
  eq(w.received,0); eq(w.stages.landed,nil); eq(w.arrivals,nil); eq(w.state,'open'); eq(W.row(w).stock.held,13)
end
print('d24_batch167 QJ1 delivery_watch, quality normal: the legendary pod not counted: ok')

-- a diversion counts by the watch's quality (freight's cargo_q)
do
  st.delivwatch=nil; pad_items={stack('thruster',13,'normal')}; hub_items={stack('thruster',2,'legendary')}; game.tick=12000
  pl.space_location={name='nauvis'}; pl.schedule={current=1,records={{station='nauvis'},{station='aquilo'}}}
  receipts={{tick=12010,kind='received',where='cargo-landing-pad (5,5) on nauvis',cargo={thruster=2},cargo_q={['thruster@legendary']=2},
    dest={pad='cargo-landing-pad',position={x=5,y=5},surface='nauvis'},stop='nauvis'}}
  W.call(sol,{item='thruster',quality='normal',count=2,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=30,from='Kestrel IVb'})
  local wn=st.delivwatch.list[1]
  W.call(sol,{item='thruster',quality='legendary',count=2,to={position={x=-8,y=-22},surface='aquilo'},deadline_min=30,from='Kestrel IVb'})
  local wl=st.delivwatch.list[2]
  game.tick=12060; W.tick(12060)
  eq(wn.diverted,nil,'normal: none of it diverted'); eq(wl.diverted,2)
  has(wl.diversions[1].text,'2 thruster@legendary received by cargo-landing-pad (5,5) on nauvis')
end
print('d24_batch167 QJ1 delivery_watch: diversions by quality: ok')

-- the schema takes quality (argforms splits item name@quality for an action whose schema has it)
do
  has(W.schema.delivery_watch.quality,'none: every quality')
  local A=dofile('mod/agent-harness_0.1.0/argforms.lua')
  local t={item='thruster@legendary'}
  A.item_quality('delivery_watch',t,W.schema.delivery_watch.quality~=nil)
  eq(t.item,'thruster'); eq(t.quality,'legendary')
end
print('d24_batch167 QJ1 delivery_watch: item name@quality: ok')

-- freight's pad_asked (shipment's "when it left the hub the pad asked"): what the pad held counts every quality
do
  package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
  local held={stack('thruster',13,'normal'),stack('thruster',2,'legendary')}
  local p2=ud{valid=true,position={x=-8,y=-22},get_inventory=function() return inv(held) end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters={{value={name='thruster',quality='legendary'},min=4}}} end} end}
  game.planets.aquilo={surface={name='aquilo',find_entities_filtered=function(f) eq(f.type,'cargo-landing-pad'); return {p2} end}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  local a=F.pad_asked('aquilo',force,{thruster=2})
  eq(a.items.thruster.hold,15,'13 normal and 2 legendary held'); eq(a.items.thruster.ask,4)
end
print('d24_batch167 QJ1 freight pad_asked: held at every quality: ok')
game,defines,prototypes=nil,nil,nil
