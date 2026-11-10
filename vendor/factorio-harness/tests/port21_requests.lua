package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function fails(fn,x) local ok,e=pcall(fn);assert(not ok);has(tostring(e),x) end
defines={inventory={hub_main=1,hub_trash=2,rocket_silo_rocket=3,crafter_input=4},rocket_silo_status={rocket_ready=9},
 space_platform_state={waiting_at_station=6},logistic_member_index={space_platform_hub_requester=1}}
prototypes={item={iron={weight=1000,stack_size=100}},space_location={nauvis={},vulcanus={}},quality={normal={}},utility_constants={default_rocket_lift_weight=1000000}}
local slots={}
local sec={index=1,is_manual=true,group='',active=true,multiplier=1}
sec.get_slot=function(i) return slots[i] or {} end
sec.set_slot=function(i,f) slots[i]=f end
sec.clear_slot=function(i) slots[i]=nil end
setmetatable(sec,{__index=function(_,k) if k=='filters' then return slots elseif k=='filters_count' then return #slots end end,
 __newindex=function(t,k,v) if k=='filters' then slots=v else rawset(t,k,v) end end})
local secs={sections_count=1,get_section=function() return sec end}
local hub={valid=true,type='space-platform-hub',position={x=0,y=0},providing_to_other_platforms=false,
 get_logistic_sections=function() return secs end,get_item_count=function() return 5 end,
 get_logistic_point=function() return {targeted_items_deliver={{name='iron',quality='normal',count=5}}} end,
 get_inventory=function() return {get_contents=function() return {{name='iron',quality='normal',count=5}} end} end}
local pl={valid=true,index=1,name='orbiter',hub=hub,state=6,space_location={name='nauvis'},surface={name='platform-1'},schedule={current=1,records={{station='nauvis'}}}}
local force={name='player',platforms={pl},unlock_travel_to_space_platforms=false};pl.force=force
local p={name='test',force=force,surface={planet={name='nauvis'}}}
game={tick=1,planets={}}
local K=dofile('mod/agent-harness_0.1.0/keep.lua'){}
local S=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,keep=function() return K end,
 integer=function(v,d,lo,hi) v=v==nil and d or v;assert(type(v)=='number' and v>=lo and v<=hi);return v end}
S.requests(p,{platform='orbiter',set={{item='iron',min=10,max=20,request_from='platforms',from=false,min_payload=1}}})
eq(slots[1].request_from,'platforms');eq(slots[1].import_from,nil)
local r=S.requests(p,{platform='orbiter',set={{item='iron',min=12}}})
eq(slots[1].request_from,'platforms');eq(slots[1].max,20);eq(slots[1].minimum_delivery_count,1)
has(r.sections[1].requests[1],'from anywhere via platforms')
local snap=K.snapshot(hub);slots[1].request_from='all';assert(not K.same(snap,K.snapshot(hub)))
slots[1].request_from='platforms';slots[1].minimum_delivery_count=2;assert(not K.same(snap,K.snapshot(hub)))
slots[1].minimum_delivery_count=1
local MP=dofile('mod/agent-harness_0.1.0/minpayload.lua'){}
r=MP.handler(p,{set={iron=3}});eq(slots[1].request_from,'platforms');eq(slots[1].minimum_delivery_count,3);has(r.lines[1],'anywhere via platforms')
r=S.requests(p,{platform='orbiter',providing_to_other_platforms=true});eq(hub.providing_to_other_platforms,true);eq(r.providing_to_other_platforms,true)
fails(function() S.requests(p,{platform='orbiter',providing_to_other_platforms=false,set={{item='iron',min=1,request_from='bad'}}}) end,'request_from must')
eq(hub.providing_to_other_platforms,true)
fails(function() S.launch(p,{ride=true,auto=true}) end,'travel to space platforms is locked')
assert(K.set_construction(hub,true));eq(hub.request_missing_construction_materials,true);eq(slots[1].request_from,'platforms')
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){}
eq(F.hub_keeps_at(secs,'nauvis').iron,nil)
slots[1].request_from='all';eq(F.hub_keeps_at(secs,'nauvis').iron.max,20);eq(F.hub_keeps_at(secs,'vulcanus').iron.max,20)
slots[1].import_from='vulcanus';eq(F.hub_keeps_at(secs,'nauvis').iron,nil)
-- A platform-only request never examines a planet's silos; it reports native targeted deliveries.
slots[1].request_from='platforms';slots[1].import_from=nil
local SH=dofile('mod/agent-harness_0.1.0/shipment.lua'){
 hub_counts=function(_,q) return {[q and 'iron@normal' or 'iron']=5} end,
 where=function() return {stopped=true,at='nauvis'} end,
 census_typed=function() error('platform-only request must not scan planetary silos') end}
local _,rows=SH.platform(pl,{},nil,true);r={rows=rows};eq(r.rows[1].direction,'platform');eq(r.rows[1].state,'in flight');eq(r.rows[1].on_the_way,5)
-- A native rocket inventory exists before the rocket is ready; missing ingredients must still be reported.
local RL=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
local silo={rocket_parts=0,rocket_silo_status=1,position={x=0,y=0},prototype={rocket_parts_required=50},
 get_recipe=function() return {ingredients={{name='iron',amount=10}}} end,
 get_inventory=function() return {get_item_count=function() return 0 end} end}
eq(RL.parts_short(silo).rows[1].rocket,500);silo.rocket_silo_status=9;eq(RL.parts_short(silo),nil)
-- Legacy callers cannot write the new source field.
script.active_mods.base='2.0.77'
S=dofile('mod/agent-harness_0.1.0/space.lua'){integer=function(v,d) return v or d end}
fails(function() S.check_requests(p,{platform='orbiter',set={{item='iron',min=1,request_from='all'}}},'hub',hub,secs) end,'requires Factorio 2.1')
print('port21 requests: source/location preservation, snapshots, minimum payload, provider switch, retention, native in-flight and travel/parts guards passed')
