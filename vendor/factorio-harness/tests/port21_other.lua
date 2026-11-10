-- Removed APIs must not be read, including on empty/unpaired entities.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
local function strict(t, removed)
  return setmetatable(t,{__index=function(_,k) assert(not removed[k], 'removed '..k) end,
    __newindex=function(x,k,v) assert(not removed[k], 'removed '..k); rawset(x,k,v) end})
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,e=pcall(fn);assert(not ok and tostring(e):find(text,1,true),tostring(e)) end
local root='mod/agent-harness_0.1.0/'
local function belt(i,kind)
  return strict({valid=true,name='underground-belt',type='underground-belt',unit_number=i,position={x=i,y=0},direction=4,
    belt_to_ground_type=kind,belt_neighbours={inputs={},outputs={}},get_transport_line=function() return {total_segment_length=4} end},{neighbours=true})
end
local a,b=belt(1,'input'),belt(4,'output');a.underground_belt_neighbour=b;b.underground_belt_neighbour=a
local B=dofile(root..'beltseg.lua')()
local walked=B.walk(a,10);eq(#walked.list,2);eq(walked.list[2],b)
eq(#B.walk(b,10).list,2)
a.underground_belt_neighbour=nil;b.underground_belt_neighbour=nil;eq(#B.walk(a,10).list,1)
local fuel=strict({fuel_categories={'chemical','nutrients'},fuel_value=100,stack_size=100},{fuel_category=true})
prototypes={item={mixed=fuel,empty=strict({fuel_categories={},fuel_value=0},{fuel_category=true})}}
local F=dofile(root..'farm.lua'){}
local e={burner={fuel_categories={nutrients=true}}}
assert(F.accepts_fuel(e,'mixed'));assert(not F.accepts_fuel(e,'empty'));eq(F.fuel_items('nutrients')[1],'mixed');eq(F.fuel_items('chemical')[1],'mixed')
local st={valid_for_read=true,name='mixed',count=1,quality={name='normal'},prototype=fuel}
e.burner.inventory={st,is_empty=function() return false end};e.burner.remaining_burning_fuel=0
e.burner.burnt_result_inventory={{valid_for_read=true,name='ash',count=100,prototype={stack_size=100}}}
local Burn=dofile(root..'burnt.lua'){};eq(Burn.full(e).foreign,nil);eq(Burn.unusable(e),nil)
e.burner.fuel_categories={nuclear=true};eq(Burn.full(e).foreign,'mixed');eq(Burn.unusable(e).foreign,'mixed')
defines={inventory={rocket_silo_rocket=11}}
prototypes.utility_constants=strict({default_rocket_lift_weight=1200000},{rocket_lift_weight=true})
prototypes.entity={['rocket-silo']={get_inventory_size=function() return 20 end}}
local Cargo=dofile(root..'cargo.lua'){}
eq(Cargo.limits(),1200000)
eq(Cargo.limits({prototype={lift_weight=2500000},get_inventory=function() return {} end}),2500000)
-- Native 2.1 circuit controls, simultaneous chest read/set, aliases and network selection.
defines.control_behavior={type={logistic_container=1,single_fluid_box=2,assembling_machine=3,cargo_landing_pad=4},
 single_fluid_box={exclusive_mode={none=0,send_contents=1,send_segment_contents=2}}}
defines.wire_connector_id={circuit_red=1,circuit_green=2};defines.wire_type={red=1,green=2}
prototypes.quality={normal={level=0}};prototypes.virtual_signal={};prototypes.fluid={}
local current
local C=dofile(root..'circuits.lua'){entity=function() return current end,friendly=function() end,own_platform=function() return false end}
local p={can_reach_entity=function() return true end}
local function control(kind,typ,fields,removed,mode)
 local cb=strict(fields or {},removed or {});cb.type=defines.control_behavior.type[kind]
 current={name=typ,type=typ,position={x=0,y=0},force={},prototype={logistic_mode=mode},
  get_control_behavior=function() return cb end,get_or_create_control_behavior=function() return cb end,
  get_wire_connectors=function() return {} end,get_circuit_network=function() return nil end}
 return cb
end
local chest=control('logistic_container','logistic-container',{input_networks={red=true,green=true},output_networks={red=true,green=true}},
 {circuit_exclusive_mode_of_operation=true},'requester')
local out=C.handlers.circuit_set(p,{position={0,0},read={contents=true},set_requests=true,settings={input_networks='red',output_networks='green'}})
assert(chest.read_contents and chest.set_requests);eq(chest.input_networks.green,false);eq(chest.output_networks.red,false)
eq(out.circuit.settings.input_networks,'red');eq(out.circuit.settings.output_networks,'green')
C.handlers.circuit_set(p,{position={0,0},settings={circuit_exclusive_mode_of_operation='none'}})
eq(chest.read_contents,false);eq(chest.set_requests,false)
local snap=C.snapshot(current);chest.input_networks={red=false,green=true};C.restore(current,snap);assert(chest.input_networks.red)
local tank=control('single_fluid_box','storage-tank',{}, {read_contents=true})
C.handlers.circuit_set(p,{position={0,0},read={contents=true,temperature=true}});eq(tank.circuit_exclusive_mode_of_operation,1);assert(tank.read_temperature)
C.handlers.circuit_set(p,{position={0,0},read={segment_contents=true}});eq(tank.circuit_exclusive_mode_of_operation,2)
C.handlers.circuit_set(p,{position={0,0},settings={read_contents=false}});eq(tank.circuit_exclusive_mode_of_operation,0)
fails(function() C.handlers.circuit_set(p,{position={0,0},read={contents=true,segment_contents=true}}) end,'choose one')
local machine=control('assembling_machine','assembling-machine',{}, {include_fuel=true})
C.handlers.circuit_set(p,{position={0,0},settings={include_fuel=true}});eq(machine.read_fuel,true)
fails(function() C.handlers.circuit_set(p,{position={0,0},settings={input_networks='red'}}) end,'not a circuit setting')
local pad=control('cargo_landing_pad','cargo-landing-pad',{}, {circuit_exclusive_mode_of_operation=true})
C.handlers.circuit_set(p,{position={0,0},read={contents=true,empty_slots=true},set_requests=true});assert(pad.read_contents and pad.set_requests and pad.read_empty_slots)
prototypes.entity.tank={type='storage-tank',get_max_circuit_wire_distance=function() return 9 end}
C.dry_set('tank',{settings={output_networks='green'},read={segment_contents=true}})
fails(function() C.dry_set('tank',{settings={input_networks='red'}}) end,'not a circuit setting')
control('logistic_container','logistic-container',{}, {},'passive-provider')
fails(function() C.handlers.circuit_set(p,{position={0,0},settings={set_requests=true}}) end,'only requester and buffer')
local CR=dofile(root..'circrecipe.lua'){}
local selector={get_control_behavior=function() return {input_networks={red=true,green=false}} end,
 get_circuit_network=function(w) return {signals={{signal={name='mixed'},count=w==1 and 2 or 9}}} end}
local signals=CR.signals(selector);eq(signals[1].count,2)
selector.get_control_behavior=function() return {input_networks={red=false,green=true}} end
signals=CR.signals(selector);eq(signals[1].count,9)
-- Old engine fixtures still get the original category and capacity APIs.
script.active_mods.base='2.0.77'
prototypes.item.legacy={fuel_category='chemical',fuel_value=100}
F=dofile(root..'farm.lua'){};assert(F.accepts_fuel({burner={fuel_categories={chemical=true}}},'legacy'))
prototypes.utility_constants={rocket_lift_weight=900000};eq(Cargo.limits(),900000)
print('port21 other APIs: strict paired/unpaired belts, multi-category fuels, per-silo lift and circuit controls passed')
