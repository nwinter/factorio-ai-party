-- Run from the harness root: lua tests/d27_batch260.lua
-- d27 batch260 LB (Sol #2491): the K2 cargo staging audit pieced a launch budget together from requests, platform, silo,
-- inspect and recipes reads of each ship. launch_budget {surface, platform?, manifest?, reserve?} gives each request
-- importing from the planet that its hub lacks (asks, landed, on the way, unlaunched, payload, pods, cargo and its
-- overshoot), the rocket-part ingredients those rockets take at the silos' productivity, and the silos' networks' stock
-- by exact quality against it, for the candidate alone, with the platforms in orbit, and with every platform.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s and tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={logistic_member_index={space_platform_hub_requester=1},inventory={hub_main=1},rocket_silo_status={rocket_ready=9,building_rocket=1}}
prototypes={utility_constants={rocket_lift_weight=1000000},
  item={['uranium-rounds-magazine']={weight=40000,stack_size=200},['fusion-power-cell']={weight=20000,stack_size=50},
    ['space-platform-foundation']={weight=20000,stack_size=50},['processing-unit']={weight=10000,stack_size=100},
    ['low-density-structure']={weight=20000,stack_size=50},['rocket-fuel']={weight=10000,stack_size=20},
    ['explosives']={weight=2000,stack_size=50}},
  quality={normal={level=0},rare={level=2}}}
game={tick=69614146}
function game.get_surface(n) return n=='aquilo' and AQ or nil end
local function counter(t) return function(id) local k=type(id)=='table' and id.name..'@'..id.quality or id; return t[k] or 0 end end
local net348={network_id=348,get_item_count=counter{['processing-unit']=4204,['low-density-structure']=3893,['rocket-fuel']=4214,['uranium-rounds-magazine']=6015}}
local net12={network_id=12,get_item_count=counter{['rocket-fuel']=500}}
local recipe={name='rocket-part',ingredients={{type='item',name='processing-unit',amount=1},{type='item',name='low-density-structure',amount=1},{type='item',name='rocket-fuel',amount=1}},
  prototype={maximum_productivity=3}}
local force
local silo={valid=true,position={x=-18.5,y=17.5},rocket_parts=50,rocket_silo_status=9,productivity_bonus=0.4,use_transitional_requests=true,
  prototype={rocket_parts_required=50},get_recipe=function() return recipe end}
AQ={name='aquilo',planet={name='aquilo'},find_logistic_network_by_position=function() return net348 end,
  find_entities_filtered=function() error('the census list is used') end}
local function filter(name,min,from,mp,q) return {value={name=name,quality=q or 'normal',comparator='='},min=min,import_from={name=from},minimum_delivery_count=mp} end
local function platform(name,loc,station,filters,held,way,free)
  local hub={valid=true,
    get_item_count=counter(held),
    get_logistic_point=function() local list={} for k,n in pairs(way or {}) do list[#list+1]={name=k,quality='normal',count=n} end return {targeted_items_deliver=list} end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end,
    get_inventory=function() return {count_empty_stacks=function() return free or 0 end} end}
  return {valid=true,name=name,hub=hub,space_location=loc and {name=loc} or nil,schedule={current=1,records={{station=station}}}}
end
local asterion=platform('Asterion','aquilo','aquilo',{filter('uranium-rounds-magazine',2150,'aquilo',25)},{},{},118)
local k2=platform('Kestrel II','aquilo','aquilo',{filter('fusion-power-cell',120,'aquilo',50),filter('space-platform-foundation',100,'aquilo',25),
  filter('explosives',500,'fulgora',100)},{['fusion-power-cell']=37},{},204)
local ivb=platform('Kestrel IVb',nil,'aquilo',{filter('space-platform-foundation',60,'aquilo',nil)},{['space-platform-foundation']=10},{})
local done=platform('Petrel','aquilo','aquilo',{filter('space-platform-foundation',50,'aquilo',25)},{['space-platform-foundation']=30},{['space-platform-foundation']=25})
force={name='player',platforms={asterion,k2,ivb,done},recipes={['rocket-part']={productivity_bonus=0.2}},logistic_networks={aquilo={net348,net12}}}
silo.force=force
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){}
local B=dofile('mod/agent-harness_0.1.0/launchbudget.lua'){silo=S,census_typed=function() return {silo} end}
local sol={force=force,surface=AQ}
local function scope(r,i) local t={} for _,x in ipairs(r.budgets[i].items) do t[x.item]=x end return r.budgets[i],t end

-- Asterion's 2150 uranium rounds as the candidate: 86 pods of 25 at +60% (31.25 of each ingredient a rocket)
do
  local r=B.read(sol,{surface='aquilo',platform='Asterion',manifest={['uranium-rounds-magazine']=2150},reserve={['rocket-fuel']=1500}})
  eq(r.read_tick,69614146); eq(#r.silos,1); eq(r.silos[1].network,348); eq(r.silos[1].productivity,'+60%'); eq(r.silos[1].ingredients_per_launch,31.25)
  eq(r.silos[1].rocket_ready,true); eq(r.silos[1].parts_built,50)
  has(r.per_launch,'31.25 of each of processing-unit, low-density-structure, rocket-fuel')
  eq(r.candidate.pods,86); has(r.candidate.rows[1],'Asterion uranium-rounds-magazine: asks 2150, holds 0, 0 on the way, unlaunched 2150; payload 25 (min payload); 86 pods, cargo 2150')
  has(r.candidate.hub_slots,'takes 11 more hub slots; the hub has 118 free')
  -- K2 in orbit: 83 fusion cells lacking at payload 50 is 2 pods (17 over); 100 foundation at 25 is 4; its Fulgora request is not this planet's
  eq(r.competing_pods.here,6)
  has(r.competing[1],'in orbit of aquilo: Kestrel II fusion-power-cell: asks 120, holds 37, 0 on the way, unlaunched 83; payload 50 (min payload); 2 pods, cargo 100 (17 over)')
  has(r.competing[2],'Kestrel II space-platform-foundation: asks 100, holds 0, 0 on the way, unlaunched 100; payload 25 (min payload); 4 pods, cargo 100')
  -- IVb flying here, no min payload: a full rocket by weight (50 foundation) for its 50 unlaunched; Petrel's 30+25 covers its 50
  has(r.competing[3],'flying to aquilo: Kestrel IVb space-platform-foundation: asks 60, holds 10, 0 on the way, unlaunched 50; payload 50 (full rocket by weight); 1 pod, cargo 50')
  eq(#r.competing,3,'Petrel lacks nothing once what is on the way counts'); eq(r.competing_pods.all,7)
  local sc,t=scope(r,1)
  eq(sc.pods,86); eq(t['uranium-rounds-magazine'].cargo,2150); eq(t['uranium-rounds-magazine'].networks_hold,6015); eq(t['uranium-rounds-magazine'].short,nil)
  eq(t['processing-unit'].for_rockets,2688,'86 x 31.25 rounded up'); eq(t['processing-unit'].needs,2688)
  eq(t['rocket-fuel'].reserve,1500); eq(t['rocket-fuel'].needs,4188); eq(t['rocket-fuel'].short,nil); eq(sc.short,'none')
  sc,t=scope(r,2)
  eq(sc.pods,92); eq(t['rocket-fuel'].for_rockets,2875); eq(t['rocket-fuel'].needs,4375); eq(t['rocket-fuel'].short,161)
  eq(t['rocket-fuel'].other_networks,'network 12 holds 500'); eq(t['rocket-fuel'].networks_hold_by,'348: 4214')
  eq(t['fusion-power-cell'].cargo,100); eq(t['fusion-power-cell'].networks_hold,0); eq(t['fusion-power-cell'].short,100)
  has(sc.short,'rocket-fuel 161')
  sc,t=scope(r,3)
  eq(sc.pods,93); eq(t['space-platform-foundation'].cargo,150)
  has(r.line,'aquilo at tick 69614146: 1 silo in network 348, 31.25 a rocket; the candidate alone: 86 pods, short none')
  eq(#r.unknowns,4)
end

-- no candidate: the platforms' own asks; Asterion's request counts among them
do
  local r=B.read(sol,{surface='aquilo'})
  eq(r.candidate,nil); eq(#r.budgets,2); eq(r.competing_pods.here,92); eq(r.budgets[1].scope,'the asks of platforms in orbit now')
end

-- a quality the manifest names is its own item; refusals
do
  local r=B.read(sol,{surface='aquilo',manifest={['processing-unit@rare']=100}})
  local _,t=scope(r,1)
  eq(t['processing-unit@rare'].cargo,100); eq(t['processing-unit@rare'].networks_hold,0); eq(t['processing-unit'].for_rockets,32,'1 pod of 100 at 10 kg')
  local function refused(a,x) local ok,e=pcall(B.read,sol,a); assert(not ok,'accepted'); has(e,x) end
  refused({surface='aquilo',manifest={['no-such']=1}},'manifest: no item no-such')
  refused({surface='aquilo',manifest={['processing-unit']=1.5}},'whole number')
  refused({surface='aquilo',platform='Nobody'},'no platform of ours named Nobody')
  refused({surface='aquilo',network=7},'no silo of ours on aquilo in network 7')
  refused({surface='aquilo',manifest={['processing-unit']={count=5,payload=1}}},'a manifest entry is a count or {count, min_payload}')
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
-- HR (Sol #2494): sends_down_rule says the maxes of every section add up and a min keeps nothing by itself (2.0.77 on a
-- copy of world n: Limestone's two 0..60 small-lamp sections kept 100; one cleared sent 40 down to a pad asking 0)
do
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end}
  has(space.KEEP_RULE,'their maxes added up over every section (a request\'s min is what the hub asks rockets for and keeps nothing by itself)')
  has(space.KEEP_RULE,'small-lamp 0..60 from nauvis in two sections, kept all 100 with the pad asking 1000; with one cleared, 40 went down to the pad asking 0')
end
print('d27_batch260 ok')
