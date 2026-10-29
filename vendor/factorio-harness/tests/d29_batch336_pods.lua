-- Run from repository root: lua tests/d29_batch336_pods.lua
-- (d29 batch336 FL4) running pod totals per platform (podlog.lua totals): pods up (rockets) and down (hub pods), cargo by
-- item, the planets, and windows by buckets; shipment {totals, platform?} reads them. Mocks as tests/d25_batch203.lua.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,e=pcall(f); assert(not ok,'should fail: '..x); has(e,x) end
defines={inventory={cargo_unit=2},events={on_cargo_pod_started_ascending=901,on_cargo_pod_finished_ascending=902,on_cargo_pod_finished_descending=903,
  on_cargo_pod_delivered_cargo=904},rocket_silo_status={building_rocket=0,rocket_ready=7,launch_started=9}}
storage={}
game={tick=1000,surfaces={nauvis={}},get_player=function() return nil end}
prototypes={item={}}
local function inv(list) local x={list=list}; x.get_contents=function() return x.list end; x.get_item_count=function() return 0 end; return x end
local nauvis={name='nauvis'}
local weaver={name='Weaver',valid=true,space_location={name='nauvis'}}
local hub={valid=true,type='space-platform-hub',surface={name='platform-19',platform=weaver},position={x=0,y=0}}
local silo={valid=true,type='rocket-silo',name='rocket-silo',unit_number=7,surface=nauvis,position={x=1,y=2}}
local units=0
local function pod(origin,items,dest)
  units=units+1
  local cargo=inv(items)
  local p={valid=true,unit_number=units,cargo_pod_origin=origin,cargo_pod_destination=dest or {station=hub,type=1},surface=nauvis,position={x=0,y=0}}
  p.get_inventory=function() return cargo end
  return p
end
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}
local H=216000

-- a rocket up, seen twice (launch and finished ascending): counted once
local p1=pod(silo,{{name='advanced-circuit',quality='normal',count=100}})
P.on_launch{rocket={attached_cargo_pod=p1},rocket_silo=silo,tick=1000}
P.on_event{name=902,tick=2650,cargo_pod=p1}
local t=P.totals('Weaver')
eq(#t,1); eq(t[1].up_pods,1); eq(t[1].down_pods,0); eq(t[1].up_items,'advanced-circuit*100'); eq(t[1].from,'nauvis 1'); eq(t[1].since_tick,1000)
-- 12 game hours later: another rocket (rare rounds) and a hub pod down to Nauvis
game.tick=1000+12*H
P.on_launch{rocket={attached_cargo_pod=pod(silo,{{name='uranium-rounds-magazine',quality='rare',count=50}})},rocket_silo=silo,tick=game.tick}
P.on_event{name=901,tick=game.tick+60,cargo_pod=pod(hub,{{name='advanced-circuit',quality='normal',count=20}},{surface='nauvis',type=2})}
t=P.totals('Weaver')[1]
eq(t.up_pods,2); eq(t.down_pods,1); eq(t.up_items,'advanced-circuit*100, uranium-rounds-magazine@rare*50'); eq(t.down_items,'advanced-circuit*20'); eq(t.to,'nauvis 1')
local w={} for _,x in ipairs(t.windows) do w[x.window]=x end
eq(w['1h'].up_pods,1); eq(w['1h'].down_pods,1); eq(w['1h'].up_items,'uranium-rounds-magazine@rare*50')
eq(w['10h'].up_pods,1)                       -- the first rocket is 12 h back
eq(w['50h'].up_pods,2); eq(w['250h'].up_pods,2); eq(w['250h'].from_tick,0)
-- a pod with no cargo read is not counted; past TOTAL_ITEMS names the rest is other
P.on_event{name=901,tick=game.tick+120,cargo_pod=pod(hub,{},{surface='nauvis',type=2})}
eq(P.totals('Weaver')[1].down_pods,1)
P.TOTAL_ITEMS=2
P.on_launch{rocket={attached_cargo_pod=pod(silo,{{name='rail',quality='normal',count=7}})},rocket_silo=silo,tick=game.tick+200}
has(P.totals('Weaver')[1].up_items,'other 7 (past 2 names)')
-- shipment {totals}
local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){pod_totals=function(pl) return P.totals(pl) end,state=function() return storage end}
local r=S.read({},{totals=true})
has(r.lines[1],'Weaver since tick 1000: up 3 pods (from nauvis 3): advanced-circuit*100, uranium-rounds-magazine@rare*50, other 7 (past 2 names); down 1 pod (to nauvis 1): advanced-circuit*20; 1h 2 up/1 down, 10h 2 up/1 down, 50h 3 up/1 down, 250h 3 up/1 down')
has(r.note,'launches before the count are not in it')
eq(S.read({},{totals=true,platform='Nobody'}).lines[1],'no pod counted for Nobody')
fails(function() S.read({},{totals=true,item='rail'}) end,'totals takes platform only')
print('d29_batch336_pods FL4: ok')
