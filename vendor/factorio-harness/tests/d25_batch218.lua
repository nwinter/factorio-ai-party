-- Run with lua tests/d25_batch218.lua: d25 batch218 QAC1 (Sol #2393). At 64185062 a deliveries_wait alert named 7
-- Vulcanus requests in network 22 unfilled 5+ min "while providers or storage hold the item free (electronic-circuit
-- 53287, steel-plate 14496, tungsten-carbide 4401, ...)"; logistics_audit showed every short request asked a quality
-- with none free (rare circuits, steel and carbide at (59.5,52.5); uncommon circuits at (52.5,52.5)). networks.lua now
-- compares by item@quality: the alert, the network read's holds/requests/short, the construction backlog's items, and
-- the stock samples behind the look-ahead.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
defines={flow_precision_index={five_seconds=0,one_hour=3},logistic_member_index={logistic_container=0}}
prototypes={item={}}
local force={name='player',players={{}}}
local list={}
local function inside(p,a) return p.x>=a[1][1] and p.x<=a[2][1] and p.y>=a[1][2] and p.y<=a[2][2] end
local vulcanus={name='vulcanus',index=4,solar_power_multiplier=1,get_property=function() return 100 end}
vulcanus.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(list) do
    local ok=(not f.force or e.force==f.force) and (not f.area or inside(e.position,f.area))
    if f.type then ok=ok and e.type==f.type end
    if f.to_be_deconstructed then ok=ok and e.decon end
    if f.to_be_upgraded then ok=ok and e.upgrade end
    if ok then out[#out+1]=e end
  end
  return out
end
vulcanus.count_entities_filtered=function(f) return #vulcanus.find_entities_filtered(f) end
game={tick=0,forces={player=force},surfaces={vulcanus},get_surface=function() return vulcanus end}

-- The engine's reads by ItemWithQualityID: a name alone is normal quality, {name, quality} that quality.
local function key(id) if type(id)=='table' then return id.quality=='normal' and id.name or id.name..'@'..id.quality end return id end
-- Network 22: free in providers and storage, by item@quality.
local free={['electronic-circuit']=53287,['steel-plate']=14496,['tungsten-carbide']=4401}
local supply_reads={}
local ln={network_id=22,all_logistic_robots=800,available_logistic_robots=798,all_construction_robots=50,available_construction_robots=50,cells={}}
ln.get_supply_counts=function(id) supply_reads[#supply_reads+1]=key(id); return {storage=free[key(id)] or 0} end
ln.get_item_count=function(id) return free[key(id)] or 0 end
ln.get_contents=function()
  local out={}
  for k,n in pairs(free) do local name,q=k:match('^(.-)@(.+)$'); out[#out+1]={name=name or k,quality=q or 'normal',count=n} end
  return out
end
ln.cells[1]={owner={valid=true,position={x=-44,y=117}},logistic_radius=25,construction_radius=55,charging_robot_count=0,to_charge_robot_count=1,
  is_in_construction_range=function(p) return math.abs(p.x+44)<=55 and math.abs(p.y-117)<=55 end}
-- Sol's two requesters: rare circuits, steel and carbide; uncommon circuits. Holding none, nothing on the way.
local function requester(unit,x,filters)
  return {owner={unit_number=unit,position={x=x,y=52.5},get_item_count=function() return 0 end},filters=filters,targeted_items_deliver={}}
end
ln.requester_points={
  requester(701,59.5,{{name='electronic-circuit',quality='rare',count=200},{name='steel-plate',quality='rare',count=100},{name='tungsten-carbide',quality='rare',count=50}}),
  requester(702,52.5,{{name='electronic-circuit',quality='uncommon',count=100}})}
-- Network 8 elsewhere holds rare assembling machines.
local other={network_id=8,all_logistic_robots=5,available_logistic_robots=5,all_construction_robots=5,available_construction_robots=5,
  cells={{owner={valid=true,position={x=400,y=0}},logistic_radius=25,construction_radius=55}},requester_points={}}
other.get_item_count=function(id) return key(id)=='assembling-machine-3@rare' and 4 or 0 end
force.logistic_networks={vulcanus={ln,other}}
local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(sec) for _=1,sec*60 do game.tick=game.tick+1; N.tick(game.tick) end end
local function row()
  storage.networks.views={}
  for _,x in ipairs(N.read({force=force},{}).surfaces[1].logistic) do if x.id==22 then return x end end
end
local function alert(kind) for _,g in ipairs(N.alert_groups(force)) do if g.kind==kind then return g end end end

-- 1. Sol's case: 5+ min short, none of the asked qualities free (53287 normal circuits are): no deliveries, no alert.
run(330)
local r=row()
eq(r.deliveries,nil,'none of the asked qualities is free')
eq(alert('deliveries_wait'),nil,'no deliveries alert')
-- each item@quality asked was read once with its quality
table.sort(supply_reads)
local seen={}
for _,k in ipairs(supply_reads) do seen[k]=true end
assert(seen['electronic-circuit@rare'] and seen['electronic-circuit@uncommon'] and seen['steel-plate@rare'] and seen['tungsten-carbide@rare'],table.concat(supply_reads,','))
assert(not seen['electronic-circuit'],'the normal count is not read for them')
-- The read: each quality its own row; the requests short per quality, not set against the normal stock.
local holds={}
for _,h in ipairs(r.holds) do holds[h.name..(h.quality and '@'..h.quality or '')]=h.count end
eq(holds['electronic-circuit'],53287); eq(r.holds[1].quality,nil,'normal: no quality field')
local asks={}
for _,a in ipairs(r.requests) do asks[a.name..'@'..(a.quality or 'normal')]=a end
eq(asks['electronic-circuit@rare'].asked,200); eq(asks['electronic-circuit@rare'].short,200)
eq(asks['electronic-circuit@uncommon'].asked,100); eq(asks['electronic-circuit@uncommon'].short,100)
eq(asks['electronic-circuit@normal'],nil,'no normal circuits asked')
eq(r.unfilled_items['electronic-circuit@rare'],200); eq(r.unfilled_items['electronic-circuit'],nil)
assert(r.line:find('requesters ask electronic-circuit@rare 200 (200 short), electronic-circuit@uncommon 100 (100 short)',1,true),r.line)
assert(r.line:find('holds electronic-circuit 53287',1,true),r.line)

-- 1b. What is on the way counts at the request's quality (targeted_items_deliver rows carry it): 50 normal gears
-- flying to a chest that asks 50 rare leave the 50 rare short.
ln.requester_points[3]={owner={unit_number=704,position={x=30.5,y=52.5},get_item_count=function() return 0 end},
  filters={{name='iron-gear-wheel',quality='rare',count=50}},targeted_items_deliver={{name='iron-gear-wheel',quality='normal',count=50}}}
r=row()
for _,a in ipairs(r.requests) do if a.name=='iron-gear-wheel' then eq(a.short,50,'normal gears on the way do not fill a rare request'); eq(a.quality,'rare') end end
ln.requester_points[3]=nil
-- 2. 12 rare circuits come free: the alert names item@quality and the free count of that quality.
free['electronic-circuit@rare']=12
r=row()
eq(r.deliveries.stuck,1); eq(r.deliveries.free['electronic-circuit@rare'],12); eq(r.deliveries.free['electronic-circuit'],nil)
local d=alert('deliveries_wait')
eq(d.line,'deliveries waiting on robots: 1 request unfilled 5+ min in network 22 near (-44,117) while providers or storage hold the item free (electronic-circuit@rare 12): 1 robot waiting to charge at 1 roboport; 798 idle logistic robots')
-- A normal request with normal stock free: named without a quality, as before.
ln.requester_points[3]=requester(703,40.5,{{name='steel-plate',quality='normal',count=50}})
run(330)
r=row()
eq(r.deliveries.stuck,2); eq(r.deliveries.free['steel-plate'],14496)
ln.requester_points[3]=nil; free['electronic-circuit@rare']=nil

-- 3. Construction: rare assembling machine ghosts with only normal ones in the network wait on missing items (network
-- 8 holds the rare ones); no "the items are in the network" alert.
free['assembling-machine-3']=40
for i=1,6 do
  list[#list+1]={valid=true,force=force,type='entity-ghost',name='entity-ghost',unit_number=900+i,position={x=-40+i*3,y=110},quality={name='rare'},
    ghost_prototype={items_to_place_this={{name='assembling-machine-3',count=1}}}}
end
run(330)
r=row()
eq(r.backlog.waited_ghosts,6); eq(r.backlog.items_present,false)
assert(r.backlog.cause:find('items missing in this network: assembling-machine-3@rare (held in network #8 near (400,0))',1,true),r.backlog.cause)
eq(alert('construction_wait'),nil,'no construction_wait with the quality missing')
-- with rare ones in the network: present, and the alert
free['assembling-machine-3@rare']=6
r=row()
eq(r.backlog.items_present,true); assert(alert('construction_wait'),'construction_wait with the rare items in')
for _,e in ipairs(list) do e.valid=false end

-- 4. The look-ahead's stock samples: by item@quality. Rare carbide falls 10 a minute from 600 while normal carbide
-- grows: the rare one is running out (summed by name it rose).
storage.networks.stock=nil
free['tungsten-carbide@rare']=600
for _=1,35 do
  free['tungsten-carbide@rare']=free['tungsten-carbide@rare']-10; free['tungsten-carbide']=free['tungsten-carbide']+50
  run(60)
end
local rows=N.running_out(force,5)
local carbide
for _,x in ipairs(rows) do if x.name:find('tungsten') then carbide=x end end
assert(carbide,'rare carbide running out')
eq(carbide.name,'tungsten-carbide@rare'); eq(carbide.id,22)
-- A sample from before (no q: every quality by name) is not compared with one by quality.
for _,h in pairs(storage.networks.stock) do for _,s in ipairs(h.samples) do if s.tick<game.tick-60*60*10 then s.q=nil end end end
local _,enough=N.running_out(force,5)
eq(enough,false,'old samples by name are not set against new ones by quality')
-- 5. gates: a logistic condition on rare steel reads the network's rare steel (the name alone is normal), its split
-- and the pickups robots reserved of that quality.
do
  game={tick=100}
  defines={logistic_mode={requester=1,buffer=2},entity_status={disabled_by_control_behavior=9},inventory={chest=1}}
  local counts={['steel-plate']=732,['steel-plate@rare']=3}
  local net={network_id=22,get_item_count=function(id) return counts[key(id)] or 0 end,
    get_supply_counts=function(id) return key(id)=='steel-plate@rare' and {storage=3} or {storage=732} end,
    provider_points={{targeted_items_pickup={{name='steel-plate',quality='normal',count=100},{name='steel-plate',quality='rare',count=2}}}},
    requester_points={},storages={},passive_provider_points={}}
  local furnace={valid=true,name='electric-furnace',position={x=-64.5,y=-67.5},status=9,
    surface={find_logistic_network_by_position=function() return net end},
    get_control_behavior=function() return {logistic_condition={comparator='>',constant=10,first_signal={type='item',name='steel-plate',quality='rare'}}} end}
  local G=dofile('mod/agent-harness_0.1.0/gates.lua'){circuit_read=function() return {logistic='steel-plate@rare > 10',logistic_met=false} end}
  local line=G.row(furnace).line
  assert(line:find('(network 22: steel-plate@rare 3; the count: storage 3, passive providers 0, active providers 0, buffers 0; robots have reserved 2 for pickup',1,true),line)
  game,defines=nil,nil
end
print('d25_batch218 QAC1: ok')
