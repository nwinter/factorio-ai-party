-- Run from repository root: lua tests/supply.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and text:find(part,1,true),tostring(text)..' lacks '..part) end
local function lacks(text,part) assert(not (text and text:find(part,1,true)),tostring(text)..' has '..part) end
local function any(list,part) for _,s in ipairs(list or {}) do if s:find(part,1,true) then return s end end error(table.concat(list or {},' | ')..' lacks '..part) end
defines={inventory={chest=1,logistic_container_trash=2,crafter_input=3,lab_input=4,robot_cargo=5,cargo_landing_pad_main=6},
  logistic_mode={active_provider=1,storage=2,requester=3,passive_provider=4,buffer=5},logistic_member_index={logistic_container=0},
  entity_status={disabled_by_control_behavior='disabled_by_control_behavior'},flow_precision_index={ten_minutes=3}}
local AC,EC='advanced-circuit','electronic-circuit'
prototypes={item={[AC]={type='item'},[EC]={type='item'},['plastic-bar']={type='item'},['iron-plate']={type='item'},
  ['automation-science-pack']={type='tool'}},entity={['logistic-robot']={max_payload_size=1}},recipe={}}
local function inv(items)
  items=items or {}
  return {get_item_count=function(name) return items[name] or 0 end,
    get_contents=function() local out={} for k,v in pairs(items) do out[#out+1]={name=k,count=v,quality='normal'} end return out end,
    is_empty=function() return next(items)==nil end}
end
local surface={name='nauvis'}
local other={name='vulcanus'}
local world={}
local n=0
local function entity(e)
  n=n+1; e.valid=true; e.unit_number=n; e.surface=e.surface or surface
  world[#world+1]=e
  return e
end
local function crafter(x,y,name,status,recipe,input,output)
  local e=entity{name=name,type='assembling-machine',position={x=x,y=y},status=status}
  local i,o=inv(input),inv(output)
  e.get_recipe=function() return recipe end
  e.get_inventory=function(id) return id==defines.inventory.crafter_input and i or nil end
  e.get_output_inventory=function() return o end
  e.get_fluid_count=function(name) return (input or {})[name] or 0 end
  return e
end
local AC_RECIPE={name=AC,products={{type='item',name=AC,amount=1}},ingredients={{type='item',name=EC,amount=2},{type='item',name='plastic-bar',amount=2}}}
local PU={name='processing-unit',products={{type='item',name='processing-unit',amount=1}},
  ingredients={{type='item',name=EC,amount=20},{type='item',name=AC,amount=2},{type='fluid',name='sulfuric-acid',amount=5}}}
local CHEM={name='chemical-science-pack',products={{type='item',name='chemical-science-pack',amount=2}},
  ingredients={{type='item',name='engine-unit',amount=2},{type='item',name=AC,amount=3}}}
-- Makers: one working, one short of green circuits, one with its output full.
local m1=crafter(0,0,'assembling-machine-2','working',AC_RECIPE,{[EC]=10,['plastic-bar']=10},{[AC]=5})
local m2=crafter(4,0,'assembling-machine-2','item_ingredient_shortage',AC_RECIPE,{['plastic-bar']=3},{})
local m3=crafter(8,0,'assembling-machine-2','full_output',AC_RECIPE,{[EC]=4,['plastic-bar']=4},{[AC]=200})
-- Users: short of it, working, unpowered, short of it and engines.
local u1=crafter(20,0,'assembling-machine-3','item_ingredient_shortage',PU,{[EC]=40,['sulfuric-acid']=10},{})
local u2=crafter(24,0,'assembling-machine-3','working',PU,{[EC]=40,[AC]=4,['sulfuric-acid']=10},{})
local u3=crafter(28,0,'assembling-machine-3','no_power',PU,{[AC]=1},{})
local u4=crafter(32,0,'assembling-machine-2','item_ingredient_shortage',CHEM,{},{})
-- Far off: a user whose only feeder takes from a requester chest asking for something else.
local u5=crafter(60,40,'assembling-machine-2','item_ingredient_shortage',CHEM,{['engine-unit']=2},{})
-- Logistic networks 11-14.
local function network(id,stock,robots)
  local net={network_id=id,requester_points={},provider_points={},storage_points={},logistic_robots={},
    all_logistic_robots=robots.all,available_logistic_robots=robots.idle,
    cells={{charging_robot_count=robots.charging or 0,to_charge_robot_count=robots.waiting or 0,owner={valid=true,position={x=id,y=0}}}}}
  net.get_supply_counts=function(name) return (stock[name] or {['active-provider']=0,['passive-provider']=0,storage=0,buffer=0}) end
  net.find_cell_closest_to=function() return {is_in_logistic_range=function(pos) return id==11 and pos.x<60 end} end
  return net
end
local N11=network(11,{[AC]={['active-provider']=0,['passive-provider']=0,storage=0,buffer=20}},{all=10,idle=4,charging=1})
local N12=network(12,{[AC]={['active-provider']=0,['passive-provider']=500,storage=0,buffer=0}},{all=300,idle=0,charging=12,waiting=3})
local N13=network(13,{[AC]={['active-provider']=0,['passive-provider']=0,storage=0,buffer=30}},{all=5,idle=2})
local N14=network(14,{},{all=5,idle=5})
local function point(owner,net,mode,filters,extra)
  local pt={owner=owner,logistic_network=net,mode=mode,filters=filters,targeted_items_deliver={},targeted_items_pickup={},logistic_member_index=0,enabled=true}
  for k,v in pairs(extra or {}) do pt[k]=v end
  return pt
end
local function chest(x,y,name,mode,items,net,request,extra)
  extra=extra or {}
  local e=entity{name=name,type=mode and 'logistic-container' or 'container',position={x=x,y=y},prototype={logistic_mode=mode},
    status=extra.status or 'normal',request_from_buffers=extra.buffers}
  local main,trash=inv(items),inv(extra.trash)
  e.get_inventory=function(id) if id==defines.inventory.chest then return main elseif id==defines.inventory.logistic_container_trash then return trash end end
  local pt=point(e,net,mode=='requester' and 3 or mode=='buffer' and 5 or mode=='storage' and 2 or 4,
    request and {{name=AC,count=request,minimum_delivery_count=extra.min}} or {},
    {targeted_items_deliver=extra.incoming and {{name=AC,count=extra.incoming}} or {},targeted_items_pickup=extra.reserved and {{name=AC,count=extra.reserved}} or {}})
  e.get_logistic_point=function() return pt end
  e.get_logistic_sections=function() return extra.sections end
  -- Every requester or buffer chest in range is a requester point, a request or not.
  if net and (mode=='requester' or mode=='buffer') then net.requester_points[#net.requester_points+1]=pt end
  if net and (mode=='passive-provider' or mode=='active-provider' or mode=='buffer') then net.provider_points[#net.provider_points+1]=pt end
  if net and mode=='storage' then net.storage_points[#net.storage_points+1]=pt end
  return e,pt
end
-- Network 11: 3 held in a provider, all 3 reserved; 20 in a buffer chest.
local c1=chest(0,5,'passive-provider-chest','passive-provider',{[AC]=3},N11,nil,{reserved=3})
local c2=chest(20,3,'requester-chest','requester',{},N11,10)
local c3=chest(24,3,'requester-chest','requester',{[AC]=10},N11,10)
local c4=chest(28,3,'requester-chest','requester',{[AC]=4},N11,10,{incoming=6})
local c5=chest(40,3,'requester-chest','requester',{[AC]=40},N11,nil,{sections={sections_count=1,get_section=function() return {is_manual=true,active=false,filters={{value={name=AC},min=50}}} end}})
local c8=chest(44,3,'buffer-chest','buffer',{[AC]=20},N11,20)
local c9=chest(32,3,'requester-chest','requester',{},N11,10,{buffers=true})
-- Network 12: 500 free, no idle robots; a character asks too.
local c10=chest(200,0,'requester-chest','requester',{},N12,50)
local sol=entity{name='character',type='character',position={x=210,y=0}}
sol.get_main_inventory=function() return inv({[AC]=5}) end
sol.get_item_count=function(name) return name==AC and 12 or 0 end
N12.requester_points[#N12.requester_points+1]=point(sol,N12,3,{{name=AC,count=20}})
local off=entity{name='character',type='character',position={x=212,y=0}}
off.get_main_inventory=function() return inv({}) end
N12.requester_points[#N12.requester_points+1]=point(off,N12,3,{{name=AC,count=20}},{enabled=false})
-- Network 13: only buffer chests hold it; one requester takes from buffers but is short less than its minimum delivery.
chest(300,0,'buffer-chest','buffer',{[AC]=30},N13,nil)
local c13=chest(304,0,'requester-chest','requester',{},N13,10)
local c14=chest(308,0,'requester-chest','requester',{[AC]=5},N13,15,{buffers=true,min=20})
-- Network 14: nothing anywhere; one requester is off by its circuit condition.
local c15=chest(400,0,'requester-chest','requester',{},N14,10)
local c16=chest(404,0,'requester-chest','requester',{},N14,10,{status='disabled_by_control_behavior'})
-- Outside every network; a plain chest; a landing pad (its requests come from orbit).
local c7=chest(100,100,'requester-chest','requester',{},nil,5)
local c6=chest(50,0,'steel-chest',nil,{[AC]=100})
local pad=entity{name='cargo-landing-pad',type='cargo-landing-pad',position={x=-30,y=0}}
local padinv=inv({[AC]=7})
pad.get_inventory=function(id) return id==defines.inventory.cargo_landing_pad_main and padinv or nil end
N11.requester_points[#N11.requester_points+1]=point(pad,N11,3,{{name=AC,count=100}})
-- Belts: one carries 7 (two lines), one is empty.
local function belt(x,y,lines)
  local e=entity{name='transport-belt',type='transport-belt',position={x=x,y=y}}
  e.get_max_transport_line_index=function() return 2 end
  e.get_transport_line=function(i) return inv(lines[i]) end
  e.get_item_count=function(name) local n=0 for _,l in ipairs(lines) do n=n+(l[name] or 0) end return n end
  return e
end
local b1=belt(31,-2,{{[AC]=4},{[AC]=3}})
local b2=belt(8,3,{{},{}})
-- Inserters: feeders of users, takers from makers, one holding a circuit.
local function inserter(x,y,status,pickup,drop,held)
  local e=entity{name='fast-inserter',type='inserter',position={x=x,y=y},status=status,pickup_target=pickup,drop_target=drop}
  e.held_stack=held and {valid_for_read=true,name=held[1],count=held[2]} or {valid_for_read=false}
  return e
end
inserter(20,2,'waiting_for_source_items',c2,u1)
inserter(24,2,'working',c3,u2)
inserter(28,2,'no_power',c4,u3)
inserter(32,2,'waiting_for_source_items',b1,u4)
inserter(8,2,'waiting_for_space_in_destination',m3,b2)
inserter(0,2,'working',m1,c1,{AC,1})
local c17=chest(60,43,'requester-chest','requester',{['engine-unit']=10},N11,nil,{sections={sections_count=1,get_section=function() return {is_manual=true,active=false,filters={{value={name=AC},min=10}}} end}})
inserter(60,42,'waiting_for_source_items',c17,u5)
-- Robots: carrying circuits in networks 11 and 12, plates in 12.
local function robot(x,net,items)
  local e=entity{name='logistic-robot',type='logistic-robot',position={x=x,y=1},logistic_network=net}
  local cargo=inv(items)
  e.get_inventory=function(id) return id==defines.inventory.robot_cargo and cargo or nil end
  net.logistic_robots[#net.logistic_robots+1]=e
  return e
end
robot(10,N11,{[AC]=2}); robot(220,N12,{['iron-plate']=1}); robot(230,N12,{[AC]=1})
-- A silo whose rocket is an export: 10 in its rocket, 50 requested.
local silo=entity{name='rocket-silo',type='rocket-silo',position={x=250,y=0},status='waiting_for_space_in_platform_hub'}
local rocket=inv({[AC]=10})
silo.get_inventory=function(id) return id==9 and rocket or nil end
silo.get_item_count=function(name) return rocket.get_item_count(name) end
defines.inventory.rocket_silo_rocket=9
N12.requester_points[#N12.requester_points+1]=point(silo,N12,3,{{name=AC,count=50}})
-- A platform hub on the other surface.
defines.inventory.hub_main=7
local hub=entity{name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},surface=other}
local hubinv=inv({[AC]=25})
hub.get_inventory=function(id) return id==7 and hubinv or nil end
-- The engine's lists, as find_entities_filtered gives them.
local function finder(on)
  return function(f)
    local types={}
    if type(f.type)=='table' then for _,t in ipairs(f.type) do types[t]=true end else types[f.type]=true end
    local out={}
    for _,e in ipairs(world) do
      local inside=not f.position or ((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)<=f.radius^2
      if types[e.type] and e.surface==on and inside and (not f.limit or #out<f.limit) then out[#out+1]=e end
    end
    return out
  end
end
surface.find_entities_filtered=finder(surface)
other.find_entities_filtered=finder(other)
surface.count_entities_filtered=function(f) return #surface.find_entities_filtered(f) end
local force={logistic_networks={nauvis={N11,N12,N13,N14}},worker_robots_storage_bonus=1,
  get_item_production_statistics=function() return {get_flow_count=function(f) return f.category=='input' and 300.4 or 120 end} end}
local luna=entity{name='character',type='character',position={x=0,y=0},surface=other}
luna.get_item_count=function() return 3 end
local agents={{index=1,name='sol'},{index=2,name='luna'}}
local bodies={[1]=sol,[2]=luna}
game={get_surface=function(name) return name=='nauvis' and surface or name=='vulcanus' and other or nil end}
local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.status end,
  position=function(v) assert(type(v)=='table' and v.x and v.y,'position requires x and y'); return {x=v.x,y=v.y} end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  agents=function() return agents end,lookup=function(i) return {character=bodies[i]} end}
local p={surface=surface,force=force,position={x=0,y=0}}
local r=S.supply(p,{item=AC})
eq(r.item,AC); eq(r.surface,'nauvis')
eq(r.flow,'made 300, used 120 in the last 10 min on nauvis')
-- Where it sits: every kind of place, the team's characters on this surface only.
eq(r.where,'462: belts 7, requester chests 59, passive-provider chests 3, buffer chests 50, other chests 100, landing pads 7, machine outputs 205, users\' inputs 5, silo rockets 10, inserter hands 1, robots 3, characters 12 (sol 12)')
eq(r.chests[1],'(50,0) steel-chest 100')
eq(r.chests[2],'(40,3) requester-chest 40 (no request for it: its section asking for it is off)')
eq(r.chests[3],'(300,0) buffer-chest 30 (no request for it)')
eq(r.chests[4],'(44,3) buffer-chest 20 (requests 20)')
eq(#r.chests,5)
-- Network 11: 3 held all reserved, buffers 20 free, 40+10+4 in its requester chests; a robot carries 2; 6 due.
local n11=any(r.networks,'network 11 ')
has(n11,'network 11 (1 roboports (11,0)-(11,0)): providers 3 (3 reserved, 0 free), storage 0, buffers 20 (0 reserved, 20 free), in its requester chests 54')
has(n11,'robots carry 2, 6 due at requesters')
has(n11,'logistic robots 10: 4 idle, 1 out (1 carrying), 1 charging, 0 waiting to charge, 2 items each')
has(n11,'requesters 5: 2 met, 1 on the way, 2 unmet, 20 items short (reasons: 1 all 3 held are reserved for other deliveries; 1 free stock and idle robots)')
any(r.networks,'  unmet (20,3) requester-chest 0/10: all 3 held are reserved for other deliveries')
any(r.networks,'  unmet (32,3) requester-chest 0/10: free stock and idle robots')
-- one held: said in the singular
do
  local saved=N11.get_supply_counts
  N11.get_supply_counts=function() return {['active-provider']=0,['passive-provider']=-2,storage=0,buffer=20} end
  any(S.supply(p,{item=AC}).networks,'  unmet (20,3) requester-chest 0/10: the 1 held is reserved for other deliveries')
  N11.get_supply_counts=saved
end
-- the landing pad's request is filled from orbit: not a robot requester
for _,line in ipairs(r.networks) do lacks(line,'cargo-landing-pad') end
-- Network 12: free stock, no idle robots; a character's request; one with logistics off.
local n12=any(r.networks,'network 12 ')
has(n12,'providers 500 (0 reserved, 500 free)')
has(n12,'logistic robots 300: 0 idle, 2 out (2 carrying), 12 charging, 3 waiting to charge')
has(n12,'requesters 4: 0 met, 0 on the way, 4 unmet, 125 items short (reasons: 3 no idle robots; 1 logistics off)')
any(r.networks,'  unmet (250,0) rocket-silo 10/50: no idle robots')
any(r.networks,'  unmet (200,0) requester-chest 0/50: no idle robots')
any(r.networks,'  unmet (210,0) character sol 5/20: no idle robots')
any(r.networks,'  unmet (212,0) character 0/20: logistics off')
-- Network 13: only buffer chests hold it; the one taking from buffers is short less than its minimum delivery.
any(r.networks,'  unmet (304,0) requester-chest 0/10: only buffer chests hold it (this requester does not take from buffers)')
any(r.networks,'  unmet (308,0) requester-chest 5/15: short 10, below its minimum delivery 20')
-- Network 14: none anywhere; one off by its circuit condition.
any(r.networks,'  unmet (400,0) requester-chest 0/10: none in providers or storage')
any(r.networks,'  unmet (404,0) requester-chest 0/10: off by its circuit condition')
-- Outside every network.
any(r.networks,'1 requesters outside every logistic network')
any(r.networks,'  unmet (100,100) requester-chest 0/5: not in a logistic network')
-- Makers and users by status, with the missing ingredients and the worst three.
eq(r.makers,'3 makers: 1 working, 1 full_output, 1 item_ingredient_shortage (1 missing electronic-circuit); recipes 3 advanced-circuit')
eq(r.makers_worst[1],'(4,0) assembling-machine-2 item_ingredient_shortage (missing electronic-circuit)')
eq(r.makers_worst[2],'(8,0) assembling-machine-2 full_output')
eq(#r.makers_worst,2)
eq(r.users,'5 users: 1 working, 3 item_ingredient_shortage (3 missing advanced-circuit, 1 missing engine-unit), 1 no_power; for 3 processing-unit, 2 chemical-science-pack')
eq(r.users_worst[1],'(28,0) assembling-machine-3 no_power; holds 1; fed from (28,3) requester-chest 4/10 (+6 coming) (on the way), inserter no_power; nearest advanced-circuit: requester-chest (28,3) 3 tiles')
eq(r.users_worst[2],'(20,0) assembling-machine-3 item_ingredient_shortage (missing advanced-circuit); holds 0; fed from (20,3) requester-chest 0/10: all 3 held are reserved for other deliveries, inserter waiting_for_source_items; nearest advanced-circuit: requester-chest (24,3) 5 tiles')
eq(r.users_worst[3],'(32,0) assembling-machine-2 item_ingredient_shortage (missing engine-unit, advanced-circuit); holds 0; fed from transport-belt (31,-2) holding 7, inserter waiting_for_source_items; nearest advanced-circuit: transport-belt (31,-2) 2 tiles')
eq(r.feeders,'5 inserters feed the users: 1 working, 3 waiting_for_source_items (sources with none of it: 2 requester-chest; 1 sources hold it), 1 no_power')
eq(r.takers,'2 inserters take from the makers: 1 working, 1 waiting_for_space_in_destination (output side full: into 1 transport-belt)')
has(r.counted,'9 crafters, ')
has(r.counted,'2 of 2 belts, 7 inserters, 3 robots, 4 logistic networks')
-- A user none of whose feeders takes from a place holding or asking for it.
local w=S.supply(p,{item=AC,near={x=60,y=40},radius=5})
eq(w.users,'1 users: 0 working, 1 item_ingredient_shortage (1 missing advanced-circuit); for 1 chemical-science-pack')
eq(w.users_worst[1],'(60,40) assembling-machine-2 item_ingredient_shortage (missing advanced-circuit); holds 0; none of its 1 feeding inserters takes from a place holding or requesting it (1 requester-chest); requester-chest (60,43): its section asking for it is off')
eq(w.feeders,'1 inserters feed the users: 1 waiting_for_source_items (sources with none of it: 1 requester-chest)')
-- near: only that area; the network covering it is read whole.
local a=S.supply(p,{item=AC,near={x=22,y=0},radius=12})
eq(a.area,'(22,0) radius 12')
eq(a.where,'26: belts 7, requester chests 14, users\' inputs 5')
eq(#a.networks>=1,true)
has(a.networks[1],'network 11 ')
has(a.networks[1],'requesters 4: 1 met, 1 on the way, 2 unmet')
-- the network's own totals stay whole: its requester chests outside the area count
has(a.networks[1],'in its requester chests 54')
for _,line in ipairs(a.networks) do lacks(line,'network 12') end
eq(a.makers,nil)
has(a.users,'4 users: ')
-- nearest first with an area: (20,3) before (32,3)
eq(a.networks[2],'  unmet (20,3) requester-chest 0/10: all 3 held are reserved for other deliveries')
-- The same reply wherever the asker stands.
local far={surface=surface,force=force,position={x=900,y=900}}
eq(S.supply(far,{item=AC}).users_worst[2],r.users_worst[2])
-- Another surface by name; nothing there.
local v=S.supply(p,{item=AC,surface='vulcanus'})
eq(v.where,'28: platform hubs 25, characters 3 (luna 3)'); eq(v.networks,nil); eq(v.users,nil)
bodies[2]=nil
hubinv=inv({})
eq(S.supply(p,{item=AC,surface='vulcanus'}).where,'none on vulcanus')
-- Checks.
local ok,err=pcall(S.supply,p,{item='advanced-circuitt'}); assert(not ok and tostring(err):find('item must be an item name',1,true),err)
ok,err=pcall(S.supply,p,{item=AC,radius=10}); assert(not ok and tostring(err):find('radius needs near',1,true),err)
ok,err=pcall(S.supply,p,{item=AC,surface='mars'}); assert(not ok and tostring(err):find('no surface mars',1,true),err)
assert(S.schema.supply.near and S.schema.supply.radius and S.schema.supply.item and S.schema.supply.surface and S.schema.supply.returns)
print('supply: ok')
