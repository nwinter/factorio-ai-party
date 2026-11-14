package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
defines={entity_status={}}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function near(a,b) assert(math.abs(a-b)<1e-6,tostring(a)..' ~= '..tostring(b)) end
local P=dofile('mod/agent-harness_0.1.0/pipes.lua'){}
local pool,pump_held=200,70
local fluid='thruster-fuel';local filter={name=fluid};local all={}
local function entity(name,kind,capacity,shared)
 local e={object_name='LuaEntity',valid=true,name=name,type=kind,fluids_count=1,position={x=#all,y=0},unit_number=#all+1}
 all[#all+1]=e
 e.get_fluid=function(i) eq(i,1);local amount=shared and pool*capacity/1200 or pump_held;return amount>0 and {name=fluid,amount=amount} or nil end
 e.get_fluid_capacity=function(i) eq(i,1);return capacity end
 e.get_fluid_filter=function() return filter end
 e.has_fluid_segment=function(i) eq(i,1);return shared end
 e.get_fluid_segment_id=function() assert(shared);return 41 end
 e.get_fluid_segment_capacity=function() assert(shared);return 1200 end
 e.get_fluid_segment_fluid=function() assert(shared);return pool>0 and {name=fluid,amount=pool} or nil end
 e.get_fluid_segment_filter=function() assert(shared);return filter end
 e.get_fluid_segment_extent_bounding_box=function() assert(shared);return {left_top={x=-1,y=-1},right_bottom={x=4,y=1}} end
 e.get_fluid_box_prototype=function() return {production_type='input-output'} end
 e.get_fluid_box_neighbours=function() return {} end
 e.get_fluid_box_pipe_connections=function() return {} end
 e.clear_fluid_segment_fluid=function() assert(shared);local old=pool;pool=0;return {name=fluid,amount=old} end
 e.clear_fluid=function() assert(not shared);local old=pump_held;pump_held=0;return {name=fluid,amount=old} end
 return setmetatable(e,{__index=function(_,k) assert(k~='fluidbox' and k~='neighbours','removed '..k) end})
end
local thruster=entity('thruster','thruster',1000,true)
local p1=entity('pipe','pipe',100,true);local p2=entity('pipe','pipe',100,true)
local pump=entity('pump','pump',400,false)
thruster.get_fluid_box_neighbours=function() return {{entity=p1,index=1},{entity=p2,index=1}} end
pump.get_fluid_box_neighbours=function() return {{entity=p1,index=1}} end
pump.get_fluid_box_pipe_connections=function() return {{target=p1,target_fluidbox_index=1,flow_direction='output'}} end
local surface={find_entities_filtered=function() return all end}
for _,e in ipairs(all) do e.surface=surface end
local stock=dofile('mod/agent-harness_0.1.0/fluidstock.lua')
for _,order in ipairs{{thruster,p1,p2,pump},{pump,p2,p1,thruster}} do
 local a=stock.new(P.fluid_boxes)
 for _,e in ipairs(order) do a.add(e) end
 a.add(thruster)
 local s=a.finish().stock(fluid)
 near(s.stored,270);near(s.capacity,1600);near(s.thrusters.amount,200*1000/1200)
 near(s.pipes.amount,200*200/1200);near(s.machines.amount,70);eq(s.segments_count,1)
 near(s.thrusters.amount+s.pipes.amount+s.machines.amount,s.stored)
 assert(stock.line(fluid,s):find('connected remainder',1,true))
end
-- A near read of the thruster still includes its whole segment, with unseen members named as remainder.
local a=stock.new(P.fluid_boxes);a.add(thruster);near(a.stock(fluid).stored,200);near(a.stock(fluid).pipes.capacity,200)
local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){fluid_boxes=P.fluid_boxes}
near(E.fuel_aboard({thruster},{pumps={pump},makers={}})[fluid],270)
-- Flush the selected segment once, and retain the pump's separate store.
prototypes={fluid={[fluid]={name=fluid}}}
local F=dofile('mod/agent-harness_0.1.0/flush.lua'){fluid_boxes=P.fluid_boxes,target=function() return p1 end,
 friendly=function() end,integer=function(i) return i end}
local dry=F.handlers.flush({}, {dry_run=true});eq(dry.amount,200);eq(pool,200);eq(pump_held,70)
local result=F.handlers.flush({},{});eq(result.flushed[fluid],200);eq(result.held_before[fluid],200);eq(next(result.held_after),nil)
eq(pool,0);eq(pump_held,70)
-- A selected independent store clears only itself.
local boxes=P.fluid_boxes(pump);eq(boxes.flush(1,'water').water,nil);eq(pump_held,70)
eq(boxes.flush(1,fluid)[fluid],70);eq(pump_held,0)
print('port21 fluid models: segment/own mass and capacity counted once, order independent; near reads; endurance; flush conservation passed')

-- Native boiler conversion uses fluid heat capacities, with no removed box temperature field.
prototypes.fluid.water={name='water',default_temperature=15,heat_capacity=2000}
prototypes.fluid.steam={name='steam',default_temperature=15,heat_capacity=200}
local bp={target_temperature=165,boiler_mode='output-to-separate-pipe',get_max_energy_usage=function() return 30000 end}
local b={valid=true,name='boiler',type='boiler',prototype=bp,quality='normal'}
local bf={get_filter=function(i) return {name=i==1 and 'water' or 'steam'} end,
 get_prototype=function() error('removed minimum_temperature must not be read') end}
local R=dofile('mod/agent-harness_0.1.0/rates.lua'){fluid_boxes=function(e) eq(e,b);return bf end}
local rows=R.compute({force={},surface={}},{b},'second').rows
local by={} for _,row in ipairs(rows) do by[row.item]=row end
near(by.water.consumed,6);near(by.steam.produced,60)
bp.boiler_mode='heat-fluid-inside'
rows=R.compute({force={},surface={}},{b},'second').rows
eq(#rows,2);eq(rows[1].item,'water');eq(rows[2].item,'water 165C');near(rows[2].produced,6)
print('port21 boiler: native heat capacities and heat-fluid-inside mode passed')
