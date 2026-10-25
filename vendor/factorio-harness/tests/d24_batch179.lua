-- Run from repository root: lua tests/d24_batch179.lua
-- (d24 batch179 QV1; #1989 Astra: Gleba's native drops from Kestrel IVa were never in the ledger; #2024 Sol: receipts
-- pruned before the audit, pod ids lost after departure) the pod ledger (podlog.lua): one journey per cargo pod, up and
-- down, kept per planet, with the pad's free slots and what did not fit; shipment {ledger} filters it.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={cargo_unit=2},events={on_cargo_pod_started_ascending=901,on_cargo_pod_finished_ascending=902,on_cargo_pod_finished_descending=903,
  on_cargo_pod_delivered_cargo=904}}
storage={}
game={tick=1000}
local function inv(list)
  local x={list=list}
  x.get_contents=function() return x.list end
  x.get_item_count=function(id) local n=0 for _,s in ipairs(x.list) do if s.name==(id.name or id) and (s.quality or 'normal')==(id.quality or 'normal') then n=n+s.count end end return n end
  x.count_empty_stacks=function() return x.empty or 0 end
  return x
end
local gleba={name='gleba'}
local nauvis={name='nauvis'}
local cinder={name='Cinder',valid=true,space_location={name='gleba'}}
local meridian={name='Meridian-V',valid=true,space_location={name='nauvis'}}
local plat1={name='platform-1',platform=cinder}
local plat18={name='platform-18',platform=meridian}
local hub={valid=true,type='space-platform-hub',surface=plat1,position={x=0,y=0}}
local hub18={valid=true,type='space-platform-hub',surface=plat18,position={x=0,y=0}}
local silo={valid=true,type='rocket-silo',unit_number=20720,surface=nauvis,position={x=15.5,y=59.5}}
local main,trash=inv({}),inv({})
main.empty,trash.empty=69,13
local pad={valid=true,type='cargo-landing-pad',surface=gleba,position={x=54,y=8}}
pad.get_inventory=function(i) return i==1 and main or trash end
local units=36509000
local function pod(origin,dest,items)
  units=units+1
  local cargo=inv(items)
  local p={valid=true,unit_number=units,cargo_pod_origin=origin,cargo_pod_destination=dest,surface=origin.surface,position={x=-1.75,y=0}}
  p.get_inventory=function(i) eq(i,2); return cargo end
  p.cargo=cargo
  return p
end
local P=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return storage end}
local function ev(name,p) game.tick=game.tick+1; P.on_event{name=defines.events[name],tick=game.tick,cargo_pod=p} end

-- 1. Without pod events (control.lua before d24 batch179): pods.lua's once-a-second read records a hub's pod and its going.
local s1=pod(hub,{station=pad},{{name='pipe',quality='normal',count=20}})
P.sampled(s1,1000)
game.tick=1600
P.gone(s1.unit_number,1600,{x=54,y=8})
local rows,total=P.read{limit=32}
eq(total,1); eq(rows[1].direction,'down'); eq(rows[1].platform,'Cinder'); eq(rows[1].stop,'gleba'); eq(rows[1].surface,'gleba')
eq(rows[1].sent_tick,1000); eq(rows[1].landed_tick,1600); eq(rows[1].items,'pipe*20')
assert(rows[1].line:find('landed in landing pad (54,8) after 10s (to the second)',1,true),rows[1].line)

-- 1b. A pod seen by the sampler before the first pod event: the event's send tick wins.
local s2=pod(hub,{station=pad},{{name='pipe',quality='normal',count=1}})
P.sampled(s2,1500)
game.tick=1610
P.on_event{name=defines.events.on_cargo_pod_started_ascending,tick=1610,cargo_pod=s2}
eq(P.read{limit=1}[1].sent_tick,1610)
P.on_event{name=defines.events.on_cargo_pod_finished_descending,tick=1700,cargo_pod=s2}
assert(not P.read{limit=1}[1].line:find('to the second',1,true))
storage.podlog.open[s2.unit_number]=nil

-- 2. A native pod for a pad request: started_ascending, finished_descending (the pad's free slots, its counts),
-- delivered_cargo (the slots after).
local n1=pod(hub,{station=pad},{{name='pipe',quality='normal',count=20},{name='iron-plate',quality='uncommon',count=5}})
ev('on_cargo_pod_started_ascending',n1)
local sent=game.tick
eq(storage.podlog.events,true)
-- the sampler then records nothing (the events do)
eq(P.sampled(pod(hub,{station=pad},{}),game.tick),nil)
game.tick=game.tick+1000
n1.surface=gleba; n1.position={x=54.5,y=4.5}
ev('on_cargo_pod_finished_descending',n1)
local landed=game.tick
main.list={{name='pipe',quality='normal',count=20},{name='iron-plate',quality='uncommon',count=5}}; main.empty=67
n1.cargo.list={}
ev('on_cargo_pod_delivered_cargo',n1)
eq(P.read{limit=1}[1].pad_free_after,nil,'read the tick after')
P.tick(game.tick)
eq(P.read{limit=1}[1].pad_free_after,nil)
P.tick(game.tick+1)
rows=P.read{limit=1}
local r=rows[1]
eq(r.pod,n1.unit_number); eq(r.sent_tick,sent); eq(r.landed_tick,landed); eq(r.destination,'landing pad (54,8)')
eq(r.items,'pipe*20 iron-plate@uncommon*5'); eq(r.pad_free_before,'main 69, trash 13'); eq(r.pad_free_after,'main 67, trash 13'); eq(r.ground,nil)
assert(r.line:find('down #3, pod '..n1.unit_number..', ',1,true) and r.line:find('Cinder to gleba (at gleba), pipe*20 iron-plate@uncommon*5, sent by the hub',1,true),r.line)
eq(storage.podlog.open[n1.unit_number],nil,'delivered: no longer in flight')

-- 3. A drop (the harness's drop names it at once; the game then sends it) into a full pad: what did not fit is counted.
local d1=pod(hub,{surface='gleba'},{{name='iron-ore',quality='normal',count=50}})
P.sent(d1,{kind='drop',by='sol',drop=1912})
ev('on_cargo_pod_started_ascending',d1)
main.empty,trash.empty=0,0
d1.cargo_pod_destination={station=pad}; d1.surface=gleba
ev('on_cargo_pod_finished_descending',d1)
ev('on_cargo_pod_delivered_cargo',d1)
P.tick(game.tick+1)
r=P.read{limit=1}[1]
eq(r.by,'sol'); eq(r.ground,50); eq(r.pad_free_before,'main 0, trash 0')
assert(r.line:find('drop #1912 by sol',1,true) and r.line:find('50 did not fit in the pad and landed on the ground beside it',1,true),r.line)

-- 4. A rocket up: launch ordered (the pod rides the rocket; no started_ascending), lands on the platform's hub.
local u1=pod(silo,{station=hub18},{{name='uranium-rounds-magazine',quality='normal',count=25}})
P.on_launch{rocket={attached_cargo_pod=u1},tick=game.tick}
ev('on_cargo_pod_finished_ascending',u1)
u1.surface=plat18
ev('on_cargo_pod_finished_descending',u1)
ev('on_cargo_pod_delivered_cargo',u1)
P.tick(game.tick+1)
eq(next(storage.podlog.after),nil)
rows,total=P.read{surfaces={nauvis=true},limit=32}
eq(total,1); eq(rows[1].direction,'up'); eq(rows[1].platform,'Meridian-V'); eq(rows[1].stop,'nauvis'); eq(rows[1].destination,'hub')
assert(rows[1].line:find('nauvis to Meridian-V, uranium-rounds-magazine*25, rocket from silo 20720 (15.5,59.5); landed in hub',1,true),rows[1].line)

-- 5. Filters: direction, platform, item (any quality, or one), send ticks; the newest limit, oldest first.
eq(select(2,P.read{up=true,limit=32}),1); eq(select(2,P.read{up=false,limit=32}),4)
eq(select(2,P.read{platform='Cinder',limit=32}),4); eq(select(2,P.read{platform='Meridian-V',limit=32}),1)
eq(select(2,P.read{item='iron-plate',limit=32}),1); eq(select(2,P.read{item='iron-plate@uncommon',limit=32}),1); eq(select(2,P.read{item='iron-plate@rare',limit=32}),0)
eq(select(2,P.read{from=sent,limit=32}),3); eq(select(2,P.read{from=sent,to=sent,limit=32}),1)
rows=P.read{limit=2}
eq(#rows,2); assert(rows[1].sent_tick<=rows[2].sent_tick)

-- 6. Kept per planet: KEEP journeys, the oldest dropped; a journey still in flight reads so, and after OPEN_TICKS
-- reads as no landing recorded.
P.KEEP=3
for i=1,3 do ev('on_cargo_pod_started_ascending',pod(hub,{station=pad},{{name='wood',quality='normal',count=i}})) end
rows,total=P.read{surfaces={gleba=true},limit=32}
eq(total,3); eq(rows[1].items,'wood*1')
assert(rows[3].line:find('in flight',1,true),rows[3].line)
game.tick=game.tick+P.OPEN_TICKS+1
assert(P.read{surfaces={gleba=true},limit=1}[1].line:find('no landing recorded',1,true))
eq(select(2,P.read{surfaces={nauvis=true},limit=32}),1,'another planet keeps its own')
print('d24_batch179: ok')
