-- Run with lua tests/d26_batch223.lua: d26 batch223 QAG1 (Astra 02:09). shipment judged a waiting request by the first
-- silo with automatic requests on the planet: at tick 65239542 Kestrel II's uranium-rounds-magazine 1525 from Fulgora read
-- "split_networks ... the silo's network can give 0 ... other networks on fulgora: network 96 holds 700" from the silo at
-- (-65.5,90.5) (network 840), while the silo at (-43.5,208.5) in network 96 read matched (can give 700). On a copy of
-- world n's 02:11 save those were Fulgora's two silos, in that order. Now each silo there is judged by its own request
-- row (stopped there) or its network's stock (a stop not reached, the full read alone): the gate leads with a silo that
-- can fill it, and every silo is listed with its network, what it can give, the payload and its rocket parts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function lacks(s,x) assert(not tostring(s):find(x,1,true),tostring(s)..' has '..x) end

defines={inventory={hub_main=1,rocket_silo_rocket=11},logistic_member_index={}}
prototypes={utility_constants={rocket_lift_weight=1000000},
  item={['uranium-rounds-magazine']={weight=10000,stack_size=200},calcite={weight=2000,stack_size=50}},
  quality={normal={level=0},['quality-unknown']={level=0}}}
game={tick=65239542}
local force={name='player',index=1}
-- logistic networks: stock by item (a plain name counts normal, as 2.0.77 does)
local function network(id,stock)
  return {network_id=id,get_item_count=function(item,member)
    local name=type(item)=='table' and item.name or item
    if member=='providers' then return 0 end
    return stock[name] or 0
  end}
end
local n840,n96,n243=network(840,{}),network(96,{['uranium-rounds-magazine']=700}),network(243,{['uranium-rounds-magazine']=6013})
local fulgora={name='fulgora',index=4,planet={name='fulgora'}}
local nauvis={name='nauvis',index=1,planet={name='nauvis'}}
local nets={}
local finds={}
for _,s in ipairs({fulgora,nauvis}) do
  s.find_logistic_network_by_position=function(pos) finds[s.name]=(finds[s.name] or 0)+1; return nets[pos.x..','..pos.y] end
end
force.logistic_networks={fulgora={n840,n96},nauvis={n243}}
local function silo(s,x,y,net,parts,auto)
  nets[x..','..y]=net
  return {valid=true,type='rocket-silo',name='rocket-silo',surface=s,position={x=x,y=y},force=force,use_transitional_requests=auto,
    rocket_parts=parts,prototype={rocket_parts_required=50},unit_number=x*1000+y,
    get_inventory=function() return {get_contents=function() return {} end} end,get_logistic_point=function() return {} end}
end
-- Fulgora's silos in the census's order: (-65.5,90.5) in network 840 first
local a=silo(fulgora,-65.5,90.5,n840,33,true)
local b=silo(fulgora,-43.5,208.5,n96,28,true)
local silos={[4]={a,b},[1]={silo(nauvis,15.5,59.5,n243,11,true),silo(nauvis,-186.5,148.5,nil,50,true)}}
local held={['uranium-rounds-magazine']=825}
local filters={{value={name='uranium-rounds-magazine'},min=1525,import_from='fulgora',minimum_delivery_count=25},
  {value={name='uranium-rounds-magazine'},min=1525,import_from='nauvis',minimum_delivery_count=25}}
local hub={valid=true,get_item_count=function(id) return held[type(id)=='table' and id.name or id] or 0 end,
  get_inventory=function() return {count_empty_stacks=function() return 137 end} end,
  get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
local pl={valid=true,index=7,name='Kestrel II',space_location={name='fulgora'},hub=hub,force=force,
  schedule={current=1,records={{station='fulgora'},{station='nauvis'}}}}
force.platforms={pl}
game.forces={player=force}
game.planets={fulgora={surface=fulgora},nauvis={surface=nauvis}}
local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return {} end}
local where={stopped=true,at='fulgora'}
local SH=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,
  census_typed=function(f,s) return silos[s.index] end,
  hub_counts=function(p,q) if q then return {['uranium-rounds-magazine@normal']=held['uranium-rounds-magazine']} end return held end,
  where=function() return where end,
  request_rows=function(e,f,only) return S.request_rows(e,f,nil,only) end}
local function up(planet,fast)
  local _,rows=SH.platform(pl,{},nil,fast)
  for _,r in ipairs(rows) do if r.direction=='up' and r.planet==planet then return r end end
end

-- 1. Astra's read: the gate leads with the silo in network 96, which can fill it; the other silo says why not
local r=up('fulgora')
eq(r.state,'waiting')
has(r.line,'uranium-rounds-magazine 1525 from fulgora: waiting (the hub holds 825): matched at rocket-silo (-43.5,208.5): Kestrel II asks uranium-rounds-magazine 1525 (holds 825, lacks 700), min payload 25 (its custom minimum), the silo\'s network can give 700 now')
has(r.line,'silos on fulgora for it: can fill it (network 96 can give 700, a rocket waits for 25): rocket-silo (-43.5,208.5) parts 28/50; cannot, split_networks (network 840 can give 0, under the 25 a rocket waits for): rocket-silo (-65.5,90.5) parts 33/50')
has(r.line,'the game\'s pick: no silo on fulgora is filling a rocket for Kestrel II now')
lacks(r.line,'can give 0 now')
eq(#r.silos,2); eq(r.silos[1].network,96); eq(r.silos[1].can_give,700); eq(r.silos[1].payload,25); eq(r.silos[1].parts,'28/50')
eq(r.silos[1].can_fill,true); eq(r.silos[1].flag,'matched'); eq(r.silos[1].position.x,-43.5); eq(r.silos[1].position.y,208.5)
eq(r.silos[2].network,840); eq(r.silos[2].can_give,0); eq(r.silos[2].can_fill,false); eq(r.silos[2].flag,'split_networks')
-- the same in the tick's fast read (the rows the flags came from)
eq(up('fulgora',true).gate,r.gate)
-- 2. the census in the other order: the same verdicts
silos[4]={b,a}
eq(up('fulgora').gate,r.gate)
-- 3. no silo can fill it: no "can fill", the network that holds the most leads
local n96b=network(96,{['uranium-rounds-magazine']=10})
nets['-43.5,208.5']=n96b; force.logistic_networks.fulgora={n840,n96b}
r=up('fulgora')
has(r.line,'below_min_payload at rocket-silo (-43.5,208.5)')
lacks(r.line,'can fill it')
has(r.line,'cannot, below_min_payload (network 96 can give 10, under the 25 a rocket waits for): rocket-silo (-43.5,208.5) parts 28/50')
-- 4. automatic requests off at the silo that holds it: named with its stock, the other's row leads
nets['-43.5,208.5']=n96; force.logistic_networks.fulgora={n840,n96}
b.use_transitional_requests=false
r=up('fulgora')
has(r.line,'automatic requests off (a load_silo or a launch by hand sends it) (network 96 can give 700, a rocket waits for 25): rocket-silo (-43.5,208.5) parts 28/50')
eq(r.silos[1].auto,false); eq(r.silos[1].can_fill,false)
b.use_transitional_requests=true
-- 5. a stop not reached: Nauvis's silos by their networks' stock, in the full read alone
r=up('nauvis')
has(r.line,'uranium-rounds-magazine 1525 from nauvis: waiting (the hub holds 825): the platform is not stopped at nauvis; silos on nauvis for it (their networks\' stock now): can fill it once Kestrel II stops there (network 243 can give 6013, a rocket waits for 25): rocket-silo (15.5,59.5) parts 11/50; cannot now (in no logistic network, under the 25 a rocket waits for): rocket-silo (-186.5,148.5) parts 50/50')
eq(r.silos[1].can_fill,true); eq(r.silos[2].network,nil)
finds={}
r=up('nauvis',true)
eq(r.line,'uranium-rounds-magazine 1525 from nauvis: waiting (the hub holds 825): the platform is not stopped at nauvis')
eq(r.silos,nil); eq(finds.nauvis,nil,'the tick reads no network for a stop not reached')
-- 6. the payload with no custom minimum: a full rocket by weight (1000 kg / 10 kg = 100)
filters[2].minimum_delivery_count=nil
has(up('nauvis').line,'can fill it once Kestrel II stops there (network 243 can give 6013, a rocket waits for 100)')
defines,prototypes,game=nil,nil,nil
print('d26_batch223 QAG1 shipment judges every silo on the planet: ok')
