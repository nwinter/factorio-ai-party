-- #2918: four staggered thrusters, one pipe bridging each pair's oxidizer ports.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=1}}
local T=dofile('mod/agent-harness_0.1.0/thrust.lua'){}
local serial=0
local function entity(kind,x,y,ids,fluids)
  serial=serial+1
  local e={valid=true,type=kind,name=kind,unit_number=serial,position={x=x,y=y},status=1}
  local ports={}
  local fb=setmetatable({owner=e},{__len=function() return #ids end})
  for i,id in ipairs(ids) do ports[i]={}; fb[i]={name=fluids[i],amount=10} end
  fb.get_pipe_connections=function(i) return ports[i] end
  fb.get_fluid_segment_id=function(i) return ids[i] end
  fb.get_filter=function(i) return {name=fluids[i]} end
  fb.get_capacity=function() return 1000 end
  fb.get_prototype=function() return {{production_type=kind=='assembling-machine' and 'output' or 'input'}} end
  e.fluidbox=fb
  e.prototype={fluidbox_prototypes={{volume=1000},{volume=1000}}}
  e.ports=ports
  return e
end
local function join(a,i,b,j,flow,back)
  a.ports[i][#a.ports[i]+1]={target=b.fluidbox,target_fluidbox_index=j,flow_direction=flow or 'input-output'}
  b.ports[j][#b.ports[j]+1]={target=a.fluidbox,target_fluidbox_index=i,flow_direction=back or 'input-output'}
end
local fuel,oxidizer='thruster-fuel','thruster-oxidizer'
local engines={}
for i=1,4 do engines[i]=entity('thruster',-14+5*(i-1),375.5-2*(i-1),{10300+i,10240},{fuel,oxidizer}) end
local bridges={}
for i=1,3 do
  local p=entity('pipe',engines[i].position.x+2.5,engines[i].position.y-2,{10240},{oxidizer})
  bridges[i]=p
  join(engines[i],2,p,1); join(p,1,engines[i+1],2)
end
local throttle=entity('pump',3.5,365,{10237},{oxidizer})
local upstream=entity('pipe',3.5,363.5,{10237},{oxidizer})
local source=entity('assembling-machine',-28.5,172.5,{10237},{oxidizer})
source.get_recipe=function() return {name='thruster-oxidizer',ingredients={},products={{type='fluid',name=oxidizer}}} end
join(engines[4],2,throttle,1,'input','output')
join(throttle,1,upstream,1,'input','output'); join(upstream,1,source,1)
-- A second source on the other box must never be reached from oxidizer.
local fuel_source=entity('assembling-machine',-16,372,{10301},{fuel})
join(engines[1],1,fuel_source,1)
for _,e in ipairs(engines) do
  eq(e.fluidbox.get_fluid_segment_id(2),bridges[1].fluidbox.get_fluid_segment_id(1),'shared native segment')
  assert(e.fluidbox.get_fluid_segment_id(1)~=e.fluidbox.get_fluid_segment_id(2),'separate fluids')
  local r=T.upstream(e.fluidbox,2)
  eq(#r.pumps,1); eq(r.pumps[1],throttle)
  eq(#r.makers,1); eq(r.makers[1].entity,source); eq(r.makers[1].index,1)
  eq(#r.tanks,0,'thrusters are not storage tanks')
end
eq(T.upstream(engines[1].fluidbox,1).makers[1].entity,fuel_source)
eq(#T.upstream(engines[4].fluidbox,1).makers,0,'another box on a reached thruster is not connected')
-- Choose the furthest engine as the first low tank, as thrust_inputs does.
local surface={find_entities_filtered=function() return engines end,count_entities_filtered=function() return 0 end}
local pl={surface=surface,force={name='player'}}
local r=T.read(pl)
local line
for _,s in ipairs(r.lines) do if s:find('thruster-oxidizer:',1,true)==1 then line=s end end
assert(line and line:find('assembling-machine (-28.5,172.5)',1,true),line)
assert(not line:find('no machine',1,true),line)
-- An empty connected segment still passes through the filtered thruster box.
for _,e in ipairs(engines) do e.fluidbox[2]=nil end
for _,p in ipairs(bridges) do p.fluidbox[1]=nil end
eq(T.upstream(engines[1].fluidbox,2).makers[1].entity,source)
-- Cycle detection is per box and still terminates if a second pipe route closes a loop.
join(engines[1],2,engines[4],2)
eq(#T.upstream(engines[1].fluidbox,2).makers,1)
-- Reverse the pump: same downstream segment does not imply upstream supply.
throttle.ports[1][1].flow_direction='input'
throttle.ports[1][2].flow_direction='output'
for _,e in ipairs(engines) do
  r=T.upstream(e.fluidbox,2); eq(#r.makers,0); eq(#r.pumps,0)
end
print('thrust pass-through: ok')
