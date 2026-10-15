-- Run from repository root: lua tests/thrust.lua
-- What a platform's thrusters lack and the chain behind it (thrust.lua; operator 10:53, Astra): the walk upstream
-- from a thruster's tank through pipes and pumps (only one pushing toward it) to the machines making the fluid, and
-- for an ingredient a machine lacks, the machines making that, down to the asteroid chunks in the hub.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=1,disabled_by_control_behavior=2,item_ingredient_shortage=3,full_output=4},
  inventory={assembling_machine_input=2,furnace_source=3,hub_main=21},wire_connector_id={circuit_red=1,circuit_green=2}}
local function box(entity,contents,conns,kinds,filters)
  local b={owner=entity}
  for i,c in pairs(contents) do b[i]=c or nil end
  setmetatable(b,{__len=function() return #kinds end})
  b.get_pipe_connections=function(i) return conns[i] or {} end
  b.get_capacity=function() return 1000 end
  -- a crafting machine's boxes merged by its recipe give a list of prototypes
  b.get_prototype=function(i) return {{production_type=kinds[i]}} end
  b.get_filter=function(i) return filters and filters[i] and {name=filters[i]} or nil end
  return b
end
local function entity(name,type_,x,y,status)
  return {valid=true,name=name,type=type_,position={x=x,y=y},status=status,unit_number=math.floor(x*100+y)+5000}
end
-- thruster (0,11.5): fuel 300/1000 fed by a pump; oxidizer 900/1000.
local thruster=entity('thruster','thruster',0,11.5,1)
local pump=entity('pump','pump',-3,9.5,2)
local pipe=entity('pipe','pipe',-4.5,9.5,1)
local plant=entity('chemical-plant','assembling-machine',-6.5,1.5,3)
local crusher=entity('crusher','assembling-machine',-11,1.5,3)
thruster.prototype={fluidbox_prototypes={{volume=1000},{volume=1000}}}
local tbox,pbox,xbox,cbox
tbox=box(thruster,{{name='thruster-fuel',amount=300},{name='thruster-oxidizer',amount=900}},
  {[1]={{flow_direction='input-output',target=nil,target_fluidbox_index=1}}},{'input','input'})
pbox=box(pump,{{name='thruster-fuel',amount=0}},{},{'none'})
xbox=box(pipe,{false},{},{'input-output'})
cbox=box(plant,{{name='water',amount=20},false},{},{'input','output'},{'water','thruster-fuel'})
tbox.get_pipe_connections=function(i) if i==1 then return {{flow_direction='input-output',target=pbox,target_fluidbox_index=1}} end return {} end
pbox.get_pipe_connections=function() return {{flow_direction='output',target=tbox,target_fluidbox_index=1},{flow_direction='input',target=xbox,target_fluidbox_index=1}} end
xbox.get_pipe_connections=function() return {{flow_direction='input-output',target=pbox,target_fluidbox_index=1},{flow_direction='input-output',target=cbox,target_fluidbox_index=2}} end
thruster.fluidbox,pump.fluidbox,pipe.fluidbox,plant.fluidbox=tbox,pbox,xbox,cbox
crusher.fluidbox=box(crusher,{},{},{})
-- The pump: on when signal-B = 1; its red wire carries signal-B 9.
local signal_b={type='virtual',name='signal-B'}
pump.get_control_behavior=function() return {circuit_condition={first_signal=signal_b,comparator='=',constant=1}} end
pump.get_circuit_network=function(w) if w==1 then return {get_signal=function(s) eq(s,signal_b); return 9 end} end end
-- The plant makes thruster fuel from carbon and water; it holds no carbon. The crusher has no chunk.
local fuel_recipe={name='thruster-fuel',ingredients={{type='item',name='carbon',amount=2},{type='fluid',name='water',amount=10}},
  products={{type='fluid',name='thruster-fuel',amount=75}}}
local crush_recipe={name='carbonic-asteroid-crushing',ingredients={{type='item',name='carbonic-asteroid-chunk',amount=1}},
  products={{type='item',name='carbon',amount=10},{type='item',name='carbonic-asteroid-chunk',amount=1,probability=0.05}}}
plant.get_recipe=function() return fuel_recipe end
crusher.get_recipe=function() return crush_recipe end
plant.get_inventory=function() return {get_item_count=function() return 0 end} end
crusher.get_inventory=function() return {get_item_count=function() return 0 end} end
local hub_items={carbon=169}
local surface={}
local pl={valid=true,name='Sunward',force={name='player'},surface=surface,
  hub={valid=true,get_inventory=function() return {get_item_count=function(n) return hub_items[n] or 0 end} end}}
surface.find_entities_filtered=function(f)
  if f.type=='thruster' then return {thruster} end
  return {plant,crusher}
end
surface.count_entities_filtered=function(f) eq(f.type,'asteroid-collector'); return 4 end
local circuit={[pump]={enable='signal-B = 1'}}
local T=dofile('mod/agent-harness_0.1.0/thrust.lua'){circuit=function(e) return circuit[e] end}

local r=T.read(pl)
eq(r.count,1); eq(#r.lines,1)
eq(r.lines[1],'thruster-fuel: thruster (0,11.5) 30%; pump (-3,9.5): off by its circuit condition signal-B = 1 (signal-B 9 on its wires); '..
  'chemical-plant (-6.5,1.5) thruster-fuel: short of an item ingredient (holds carbon 0, water 20); hub carbon 169; '..
  'crusher (-11,1.5) carbonic-asteroid-crushing: short of an item ingredient (holds carbonic-asteroid-chunk 0); '..
  'hub carbonic-asteroid-chunk 0; 4 asteroid collectors')
eq(T.lowest_text(r),'thruster-fuel 30%, thruster-oxidizer 90%')
-- What stays with the thrusters when their pumps stop (Grok, shift17 20:40): own tanks and the pipes before the pump;
-- the burn from that (measured on 2.0.77: from full, 1.7 s at full thrust, 20.1 s to 10%, about 10.3 s of full thrust).
local b=T.burn(1000); eq(b.full_s,1.7); eq(b.to_10_s,20.1); eq(b.equiv_s,10.3); eq(b.empty_s,36.7)
b=T.burn(100); eq(b.to_10_s,0); eq(b.empty_s,16.7)
local ap=T.after_pumps(pl)
eq(ap.lines[1],'thruster-fuel: if its pumps stop, 1 thruster holds 300 and the pipes and tanks between them and the pumps 0 (300 a thruster): '..
  'about 3 s of full thrust, 11.4 s until 10%, then 0.1 a tick until empty at 28.1 s; pump (-3,9.5): off by its circuit condition signal-B = 1 (signal-B 9 on its wires)')
eq(ap.lines[2],'thruster-oxidizer: if its pumps stop, 1 thruster holds 900 and the pipes and tanks between them and the pumps 0 (900 a thruster): '..
  'about 9.5 s of full thrust, 19.2 s until 10%, then 0.1 a tick until empty at 35.9 s; no pump between them and the rest of the line')
assert(ap.rule:find('2 fuel and 2 oxidizer a tick while its tanks are 80% full or more',1,true))
-- A pump pushing away from the thruster feeds nothing: the walk stops there.
pbox.get_pipe_connections=function() return {{flow_direction='input',target=tbox,target_fluidbox_index=1},{flow_direction='output',target=xbox,target_fluidbox_index=1}} end
eq(T.read(pl).lines[1],'thruster-fuel: thruster (0,11.5) 30%; no machine making thruster-fuel is connected to it')
-- Tanks at half or more: no line.
tbox[1].amount=600
eq(#T.read(pl).lines,0)
-- No thrusters.
surface.find_entities_filtered=function() return {} end
eq(T.read(pl).count,0)
print('thrust: ok')
