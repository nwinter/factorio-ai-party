-- d23 batch134 PF1 (Sol #2096): delivery watch #254, 1 processing unit to Gleba's landing pad (54,8) with no from,
-- guessed Kestrel IVa (paused, holding 150) as its carrier; Solstice's pod of 365 landed at the pad and the watch read
-- reached by stock with received 0 of 1 in 0 pods. With no from, the pods of any platform of ours sent down there
-- with the item count, each named by the platform it came from; the carrier stays a guess, said so; with from given
-- only that platform's pods count; the stock test is its own field.
-- Run from the harness root: lua tests/d23_batch134.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=1000}
defines={inventory={hub_main=1,cargo_unit=3,cargo_landing_pad_main=4,chest=5}}
prototypes={item={['processing-unit']={}}}
local function stack(name,count) return {valid_for_read=true,name=name,count=count,quality={name='normal'}} end
local function inv(list) local t={} for i,x in ipairs(list) do t[i]=x end
  t.get_item_count=function(n) local c=0 for _,x in ipairs(list) do if x.name==n then c=c+x.count end end return c end return t end
local gleba={name='gleba'}
gleba.find_logistic_network_by_position=function() return {network_id=98} end
local held=0
local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=54,y=8},surface=gleba,unit_number=342731,
  get_inventory=function() return inv({}) end,get_item_count=function() return held end}
gleba.find_entities_filtered=function(f) if f.position and f.position.x==54 then return {pad} end return {} end
local force={name='player',is_chunk_charted=function() return true end}
local function platform(name,index,n,paused,at)
  return {valid=true,name=name,index=index,surface={name='platform-'..index},paused=paused,space_location={name=at},schedule={current=1,records={{station='gleba'},{station='nauvis'}}},
    hub={valid=true,type='space-platform-hub',get_inventory=function() return inv({stack('processing-unit',n)}) end,get_logistic_sections=function() return {sections_count=0} end}}
end
local iva=platform('Kestrel IVa',4,150,true,'nauvis')
local sol_pl=platform('Solstice',9,365,false,'gleba')
force.platforms={iva,sol_pl}
game.forces={player=force}; game.planets={gleba={surface=gleba}}
local fol={[4]={down={},up={}},[9]={down={},up={}}}
local st={}
local W=dofile('mod/agent-harness_0.1.0/delivwatch.lua'){state=function() return st end,who=function(p) return p.name end,census_typed=function() return {pad} end,
  freight={where=function() return {} end,receipts_since=function() return {} end,followed=function(pl) return fol[pl.index] end,spoils=function() return false end}}
local sol={name='sol',index=1,force=force,surface=gleba}
local unit=31627530
local function land(from,n,t)
  unit=unit+1
  local pinv=inv({stack('processing-unit',n)})
  local pod={valid=true,unit_number=unit,surface=gleba,position={x=54,y=8},cargo_pod_state='descending',cargo_pod_destination={station=pad},get_inventory=function() return pinv end}
  fol[from.index].down={{pod=pod,unit=unit,at='gleba',tick=t-40}}
  game.tick=t-30; W.tick(t-30-(t-30)%60)
  W.pod_tick(t-1)
  pod.valid=false; held=held+n; game.tick=t; W.pod_tick(t)
  fol[from.index].down={}
end

-- no from: the guess is Kestrel IVa (the first holding it whose schedule stops at gleba); Solstice's pod counts
W.call(sol,{item='processing-unit',count=1,to={position={x=54,y=8},surface='gleba'},deadline_min=60})
local w=st.delivwatch.list[1]
local row=W.call(sol,{id=w.id}).watches[1]
eq(row.carrier,'Kestrel IVa'); eq(row.carrier_guessed,true)
has(row.carrier_note,'a guess (no from given): the first platform of ours seen holding processing-unit whose schedule stops at gleba')
has(row.carrier_note,'received counts the pods from any platform of ours landing here (received.by_platform)')
land(sol_pl,365,1600)
eq(w.received,365,'before: 0 (only the guessed carrier\'s pods were followed)'); eq(w.received_pods,1)
row=W.call(sol,{id=w.id}).watches[1]
eq(row.received.by_platform['Solstice'],365)
eq(row.state,'reached')
eq(row.stock.reached,true); eq(row.stock.at_start,0)
has(row.stock.line,'the stock test: the consumer holds 365, 0 at the start: 1 more reached')
has(row.line,'received 365 of 1 in 1 pod by cargo-landing-pad (54,8) on gleba since the watch was set (from Solstice 365)')
local landed
for _,s in ipairs(row.stages) do if s.stage=='landed' then landed=s.text end end
has(landed,'365 processing-unit received by cargo-landing-pad (54,8) on gleba (from Solstice)')
has(row.arrivals[1].text,'from Solstice\'s hub at gleba')

-- from given: only that platform's pods count
held=0
W.call(sol,{item='processing-unit',count=400,to={position={x=54,y=8},surface='gleba'},deadline_min=60,from='Kestrel IVa'})
local w2=st.delivwatch.list[2]
land(sol_pl,365,2800)
eq(w2.received,0,'from given: Solstice\'s pod is not this watch\'s')
game.tick=2820; W.tick(2820); W.tick(2880)
local r2=W.call(sol,{id=w2.id}).watches[1]
eq(r2.carrier,'Kestrel IVa'); eq(r2.carrier_guessed,nil); eq(r2.carrier_note,nil)
eq(r2.stock.reached,false); has(r2.stock.line,'the consumer holds 365, 0 at the start: 400 more not reached')
land(iva,150,3400)
eq(w2.received,150)
game.tick=3420; W.tick(3420); W.tick(3480)
local r3=W.call(sol,{id=w2.id}).watches[1]
eq(r3.stock.reached,true,'the stock test, its own fact: 515 held'); eq(r3.received.count,150); eq(r3.state,'reached')
eq(W.call(sol,{id=w2.id}).watches[1].line:find('(from ',1,true),nil,'from given: the received line names no platforms')
print('d23_batch134 PF1 delivery watch from any platform: ok')
