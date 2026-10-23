-- d22 batch107 BQ1 (Sol #1950): delivery watch #75 (10000 copper plate to a landing pad on Fulgora that robots empty)
-- read late although all 10 pods of 1000 were received: reached was a stock test only. Now the watch keeps a running
-- total of what the consumer received (count, pods), is complete by receipt (state received), and the stock test stays
-- its own fact.
-- Run from the harness root: lua tests/d22_batch107.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={['copper-plate']={}}}
local function stack(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'}} end
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end return t end
local nets={}
local fulgora={name='fulgora'}
fulgora.find_logistic_network_by_position=function(pos) return nets[pos.x] and {network_id=nets[pos.x]} end
-- pad A (74,208) is Sol's consumer; robots empty it, so it holds 0 at each read; pad B (90,208) another pad
local held={a=0,b=0,chest=0}
local function pad(key,x)
  return ud{valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=x,y=208},surface=fulgora,unit_number=x,
    get_inventory=function() return inv({}) end,get_item_count=function() return held[key] end}
end
local padA,padB=pad('a',74),pad('b',90)
local chest=ud{valid=true,name='steel-chest',type='container',position={x=80,y=200},surface=fulgora,unit_number=80,get_item_count=function() return held.chest end}
fulgora.find_entities_filtered=function(f)
  if f.position and f.position.x==74 then return {padA} elseif f.position and f.position.x==80 then return {chest} end return {}
end
local force={name='player',is_chunk_charted=function() return true end}
local psurf={name='platform-3'}
local pl={valid=true,name='Spindle',index=3,surface=psurf,paused=false,space_location={name='fulgora'},schedule={current=1,records={{station='fulgora'}}},
  hub={valid=true,type='space-platform-hub',get_inventory=function() return inv({stack('copper-plate',7000)}) end,get_logistic_sections=function() return {sections_count=0} end}}
force.platforms={pl}
game.forces={player=force}; game.planets={fulgora={surface=fulgora}}
local fol={down={},up={}}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {padA,padB} end,
  freight={where=function() return {at='fulgora',stopped=true} end,receipts_since=function() return {} end,followed=function() return fol end,spoils=function() return false end}}
local sol={name='sol',index=1,force=force,surface=fulgora}
-- a pod of n copper plate from Spindle's hub to station, followed by the watch pass, gone at tick t (before: just
-- before it is gone)
local unit=100
local function land(n,station,t,before)
  unit=unit+1
  local pinv=inv({stack('copper-plate',n)})
  local pod={valid=true,unit_number=unit,surface=fulgora,position={x=74,y=208},cargo_pod_state='descending',cargo_pod_destination={station=station},get_inventory=function() return pinv end}
  fol.down={{pod=pod,unit=unit,at='fulgora',tick=t-40}}
  game.tick=t-30; W.tick(t-30-(t-30)%60)
  W.pod_tick(t-1)
  if before then before() end
  pod.valid=false; game.tick=t; W.pod_tick(t)
  fol.down={}
end

-- Sol's watch: 10000 to pad A, 40 minutes; 5 pods of 1000 land, robots empty the pad after each
W.call(sol,{item='copper-plate',count=10000,to={position={x=74,y=208},surface='fulgora'},deadline_min=40,from='Spindle'})
local w=st.delivwatch.list[1]
local h={}; W.lines(sol,h)
for i=1,5 do land(1000,padA,1000+i*600) end
eq(w.received,5000); eq(w.received_pods,5); eq(w.received_tick,4000)
-- a pod to pad B (not the consumer) does not count
land(1000,padB,4300); eq(w.received,5000)
local lines=W.lines(sol,h)
has(lines[5],'delivery watch #1: pod 105 from Spindle\'s hub at fulgora')
has(lines[5],'; received 5000 of 10000 in 5 pods by cargo-landing-pad (74,208) on fulgora since the watch was set, the last at tick 4000')
eq(lines[6]:find('received 5000',1,true),nil,'pad B\'s pod: no total')
-- the deadline passes at 5000: late, and the line says the received total
game.tick=1000+40*3600+20; W.tick(game.tick)
eq(w.state,'late')
lines=W.lines(sol,h)
has(lines[1],'deadline passed, not reached: ')
has(lines[1],'the consumer holds 0 (0 at the start); received 5000 of 10000 in 5 pods by cargo-landing-pad (74,208) on fulgora since the watch was set, the last at tick 4000')
-- the other 5 land late: complete by receipt (received), the stock test named apart
for i=6,10 do land(1000,padA,game.tick+600) end
eq(w.state,'received'); eq(w.received,10000); eq(w.received_pods,10)
eq(w.stages.reached,nil,'the pad never held 10000 more')
lines=W.lines(sol,h)
has(lines[#lines],'delivery watch #1 (10000 copper-plate to cargo-landing-pad (74,208) on fulgora): received 10000 of 10000 in 10 pods by cargo-landing-pad (74,208) on fulgora since the watch was set, the last at tick '..w.received_tick..', late, 50s after the deadline; the stock test not met: the consumer holds 0 now (0 at the start), not seen holding 10000 more')
local row=W.row(w)
eq(row.state,'received'); eq(row.received.count,10000); eq(row.received.pods,10); eq(row.received.by,'cargo-landing-pad (74,208) on fulgora')
eq(row.held,0); eq(row.at_start,0)
eq(row.stages[#row.stages].stage,'received')
has(row.line,', received; deadline ')
-- ended: the watch follows no more pods, and says nothing more
land(1000,padA,game.tick+600); eq(w.state,'received'); eq(w.received,10000); eq(W.lines(sol,h),nil)

-- in time: a 2000 watch to pad A, two pods
W.call(sol,{item='copper-plate',count=2000,to={position={x=74,y=208},surface='fulgora'},deadline_min=60,from='Spindle'})
w=st.delivwatch.list[2]; W.lines(sol,h)
land(1000,padA,game.tick+600); land(1000,padA,game.tick+600)
eq(w.state,'received')
lines=W.lines(sol,h)
has(lines[#lines],'received 2000 of 2000 in 2 pods by cargo-landing-pad (74,208) on fulgora since the watch was set, the last at tick '..game.tick..', in time, ')

-- a chest consumer: pods received by a landing pad in its logistic network count (pad A in #7 with the chest); pad B
-- in #12 does not; the chest holding its count at the last pod is reached, with the total named
nets[74],nets[80],nets[90]=7,7,12
W.call(sol,{item='copper-plate',count=2000,to={position={x=80,y=200},surface='fulgora'},deadline_min=60,from='Spindle'})
w=st.delivwatch.list[3]; W.lines(sol,h)
eq(W.row(w).received.by,'landing pads in the consumer\'s logistic network')
land(1000,padB,game.tick+600); eq(w.received,0,'another network')
land(1000,padA,game.tick+600); eq(w.received,1000)
land(1000,padA,game.tick+600,function() held.chest=2000 end); eq(w.received,2000); eq(w.state,'reached')
lines=W.lines(sol,h)
has(lines[#lines],'delivery watch #3: reached: steel-chest (80,200) holds 2000 copper-plate (0 when the watch was set), in time, ')
has(lines[#lines],'; received 2000 of 2000 in 2 pods by landing pads in the consumer\'s logistic network since the watch was set')

-- a watch set before the total was kept: its arrivals received by the pad itself count, on its next read
w={id=9,setter='sol',index=1,force='player',item='copper-plate',count=3000,from='Spindle',to={name='cargo-landing-pad',position={x=74,y=208},where='fulgora'},
  direction='down',consumer=padA,start=500,deadline=game.tick+3600,base=0,stages={},state='late',blocks={},carrier='Spindle',
  arrivals={{tick=600,count=1000,where='cargo-landing-pad (74,208) on fulgora'},{tick=700,count=1000,where='cargo-landing-pad (90,208) on fulgora'},
    {tick=800,count=1000,where='cargo-landing-pad (74,208) on fulgora'},{tick=900,count=1000,where='cargo-landing-pad (74,208) on fulgora'}}}
st.delivwatch.list[#st.delivwatch.list+1]=w
W.check(w,game.tick)
eq(w.received,3000); eq(w.received_pods,3); eq(w.received_tick,900); eq(w.state,'received'); eq(W.row(w).received.from_arrivals,true)
game,defines,prototypes=nil,nil,nil
print('d22_batch107 BQ1 delivery watch received total: ok')
