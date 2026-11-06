package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
defines={flow_precision_index={ten_minutes=1},entity_status={working=1}}
local fluid='thruster-oxidizer'
local function entity(kind,amount,capacity,id,segment,name)
  name=name or fluid
  local fb={{name=name,amount=amount}}
  fb.get_capacity=function() return capacity end
  fb.get_locked_fluid=function() return name end
  fb.get_fluid_segment_id=function() return id end
  fb.get_fluid_segment_contents=function() return segment and {[name]=segment} end
  fb.get_connections=function() return {} end
  fb.get_prototype=function() return {object_name='LuaFluidBoxPrototype',production_type='input'} end
  return {valid=true,name=kind,type=kind,position={x=0,y=0},fluidbox=fb,status=1}
end
local pipe=entity('pipe',100,5100,10240,5100)
pipe.fluidbox.owner=pipe
local fuelpipe=entity('pipe',100,6100,10239,6100,'thruster-fuel')
fuelpipe.fluidbox.owner=fuelpipe
local thrusters={}
for i=1,4 do
  -- Sol's exact native case: 5100 segment contents, 1000 own tank capacity
  -- reported at every thruster anchor. None of the 4000 in tanks is in 5100.
  local e=entity('thruster',1000,1000,10240,5100)
  e.unit_number=i; e.position.x=i
  e.fluidbox.get_connections=function() return {pipe.fluidbox} end
  local oxy=e.fluidbox
  local fuel=entity('thruster',1000,1000,10239,6100,'thruster-fuel').fluidbox
  fuel.get_connections=function() return {fuelpipe.fluidbox} end
  local both={oxy[1],fuel[1]}
  for _,method in ipairs({'get_capacity','get_locked_fluid','get_fluid_segment_id','get_fluid_segment_contents','get_connections','get_prototype'}) do
    both[method]=function(index) return (index==1 and oxy or fuel)[method](1) end
  end
  e.fluidbox=both
  thrusters[i]=e
end
local pump=entity('pump',400,400,nil,nil)
local machine=entity('assembling-machine',42.347,100,nil,nil)
local force={get_fluid_production_statistics=function() return {get_flow_count=function() return 0 end} end}
local entities={thrusters[1],thrusters[2],thrusters[3],thrusters[4],pipe,fuelpipe,pump,machine}
local surface={name='platform-16',platform={force=force}}
surface.find_entities_filtered=function(q)
  local out={}
  local types={}; for _,t in ipairs(type(q.type)=='table' and q.type or {q.type}) do types[t]=true end
  for _,e in ipairs(entities) do if types[e.type] then out[#out+1]=e end end
  return out
end
local S=require('supply'){status_name=function() return 'working' end}
local F=require('fuelstock'){}
local function check()
  local a=S.fluid_supply(surface,force,fluid)
  local b=F.trace{surface=surface,force=force,name='Asterion'}
  local stock=b.fluids[fluid]
  local fuel=S.fluid_supply(surface,force,'thruster-fuel')
  eq(fuel.stored,10100); eq(fuel.capacity,10100)
  eq(b.fluids['thruster-fuel'].stored,fuel.stored)
  eq(b.fluids['thruster-fuel'].capacity,fuel.capacity)
  eq(fuel.thrusters.amount,4000); eq(fuel.thrusters.capacity,4000)
  eq(a.stored,9542.347); eq(a.capacity,9600); assert(a.stored<=a.capacity)
  for _,field in ipairs({'stored','capacity','segments_count'}) do eq(a[field],stock[field]) end
  for _,kind in ipairs({'thrusters','pipes','machines'}) do
    for _,field in ipairs({'amount','capacity'}) do eq(a[kind][field],stock[kind][field]) end
  end
  eq(a.thrusters.amount,4000); eq(a.thrusters.capacity,4000)
  eq(a.pipes.amount,5100); eq(a.pipes.capacity,5100)
  eq(a.machines.amount,442.347); eq(a.machines.capacity,500)
  eq(#a.segments,1); eq(a.segments[1].id,10240); eq(a.segments[1].capacity,5100)
  eq(#stock.segments,1); eq(stock.segments[1].id,10240)
  return a
end
check()
-- Entity order cannot make a thruster's 1000 capacity win over a pipe's 5100.
entities={fuelpipe,pipe,machine,pump,thrusters[4],thrusters[3],thrusters[2],thrusters[1]}
check()
-- A near read with only thrusters resolves the segment via their pipe ports.
entities=thrusters
local near=S.fluid_supply(surface,force,fluid,{position={x=0,y=0},radius=5})
eq(near.stored,9100); eq(near.capacity,9100); eq(#near.segments,1)
-- Empty filtered native tanks still have capacity; actual overcapacity is not
-- hidden by clamping stock, even if a transport anchor gives bad capacity.
local A=require('fluidstock').new()
local empty=entity('thruster',0,1000,nil,nil); empty.fluidbox[1]=nil
setmetatable(empty.fluidbox,{__len=function() return 1 end})
A.add(empty); A.add(empty)
eq(A.stock(fluid).stored,0); eq(A.stock(fluid).capacity,1000)
local bad=entity('pipe',100,1000,10240,5100)
A.add(bad)
eq(A.stock(fluid).stored,5100); eq(A.stock(fluid).capacity,2000)
-- A disconnected segment is included in whole-platform stock, but never
-- mistaken for thruster-connected stock in the existing topology trace.
local extra=entity('storage-tank',10,25000,999,10)
entities={pipe,extra,thrusters[1],pump}
local trace=F.trace{surface=surface,force=force,name='Asterion'}
eq(trace.fluids[fluid].pipes.amount,5110); eq(#trace.fluids[fluid].segments,2)
assert(table.concat(trace.lines,'\n'):find('hold 5100, 0 tanks',1,true))
extra.fluidbox.owner=extra
pump.fluidbox.get_connections=function() return {pipe.fluidbox,extra.fluidbox} end
local pumped=F.trace{surface=surface,force=force,name='Asterion'}
eq(pumped.fluids[fluid].stored,trace.fluids[fluid].stored)
eq(pumped.fluids[fluid].capacity,trace.fluids[fluid].capacity)
eq(#pumped.fluids[fluid].segments,2)
assert(table.concat(pumped.lines,'\n'):find('hold 5110, 1 tank',1,true))
print('fluidstock #2913: native boxes + unique segments, both reads agree')
