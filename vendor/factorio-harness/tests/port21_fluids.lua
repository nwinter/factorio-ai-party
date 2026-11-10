-- 2.1 native indexed storage, with distinct own/segment capacities and no legacy fluidbox.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
script={active_mods={base='2.1.24'}}
local P=dofile('mod/agent-harness_0.1.0/pipes.lua'){}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,s) local ok,e=pcall(fn);assert(not ok and tostring(e):find(s,1,true),tostring(e)) end
local water={name='water'};local cap={100,40,50};local held={{name='water',amount=25,temperature=20}}
local prototype={volume=100,filter=water,pipe_connections={}};local merged={{volume=20},{volume=30}}
local e={valid=true,type='pipe',name='pipe',fluids_count=3,position={x=0,y=0},prototype={fluidbox_prototypes={prototype}},surface={find_entities_filtered=function() return {} end}}
local function index(i) assert(type(i)=='number' and i>=1 and i<=e.fluids_count,'invalid storage index') end
local peer={valid=true,type='pipe',name='pipe',fluids_count=1,position={x=1,y=0}}
e.get_fluid=function(i) index(i);return held[i] end
e.get_fluid_capacity=function(i) index(i);return cap[i] end
e.has_fluid_segment=function(i) index(i);return i~=2 end
e.get_fluid_segment_capacity=function(i) assert(e.has_fluid_segment(i),'no segment');return i==1 and 1000 or 500 end
e.get_fluid_segment_fluid=function(i) assert(e.has_fluid_segment(i),'no segment');return i==1 and {name='water',amount=250} or nil end
e.get_fluid_segment_id=function(i) assert(e.has_fluid_segment(i),'no segment');return i==1 and 31 or 32 end
e.get_fluid_segment_filter=function(i) assert(e.has_fluid_segment(i),'no segment');return i==1 and water or nil end
e.get_fluid_filter=function(i) index(i);return i==1 and water or nil end
e.get_fluid_box_prototype=function(i) index(i);return i==1 and prototype or i==2 and merged or nil end
e.get_fluid_segment_extent_bounding_box=function(i) assert(e.has_fluid_segment(i),'no segment');return {left_top={x=0,y=0},right_bottom={x=3,y=0}} end
e.get_fluid_box_pipe_connections=function(i) index(i);return {{target=peer,target_fluidbox_index=1,position={x=0,y=0},target_position={x=1,y=0},connection_type='normal',flow_direction='input-output'}} end
e.get_fluid_box_neighbours=function(i) index(i);return {{entity=peer,index=1}} end
e.set_fluid_filter=function(i,f) index(i);return f~='steam' end
e.set_fluid=function(i,f) index(i);if i==1 and f.name~='water' then return 0 end;held[i]={name=f.name,amount=math.min(cap[i],f.amount),temperature=f.temperature};return held[i].amount end
e.clear_fluid=function(i) index(i);local f=held[i];held[i]=nil;return f end
e.add_fluid=function(i,f) index(i);local old=held[i] and held[i].amount or 0;return e.set_fluid(i,{name=f.name,amount=old+f.amount})-old end
e.remove_fluid=function(i,n) index(i);local f=held[i];if not f then return nil end;local amount=math.min(n,f.amount);f.amount=f.amount-amount;return {name=f.name,amount=amount} end
setmetatable(e,{__index=function(_,k) assert(k~='fluidbox','removed fluidbox') end})
local fb=P.fluid_boxes(e)
eq(#fb,3);eq(fb[1].amount,25);eq(fb[2],nil)
eq(fb.get_own_capacity(1),100);eq(fb.get_capacity(1),1000);eq(fb.get_segment_capacity(1),1000)
eq(fb.get_fluid_segment_contents(1).water,250)
eq(fb.get_fluid_segment_id(2),nil);eq(fb.get_fluid_segment_contents(2),nil);eq(fb.get_segment_capacity(2),nil)
eq(fb.get_fluid_segment_id(3),32);eq(next(fb.get_fluid_segment_contents(3)),nil)
eq(fb.get_filter(1),water);eq(fb.get_locked_fluid(1),'water');eq(fb.get_locked_fluid(3),nil)
eq(#P.fluid_prototypes(e,1),1);eq(#P.fluid_prototypes(e,2),2);eq(#P.fluid_prototypes(e,3),0)
eq(fb.get_pipe_connections(1)[1].target.owner,peer);eq(fb.get_neighbours(1)[1].entity,peer)
assert(P.fluids(e,true):find('water 25/100 (segment holds up to 1000)',1,true))
eq(fb.set_filter(1,{name='steam'}),false);eq(fb.set_filter(1,'water'),true)
fails(function() fb.set_filter(1,{name='water',minimum_temperature=10}) end,'temperature limits')
eq(P.set_fluid(e,1,{name='steam',amount=10}),0);eq(fb[1].amount,25)
eq(P.set_fluid(e,1,{name='water',amount=150}),100);eq(fb[1].amount,100)
eq(fb.remove(1,30).amount,30);eq(fb.add(1,{name='water',amount=50}),30)
eq(fb.clear(1).amount,100);eq(fb[1],nil);eq(P.set_fluid(e,1,nil),0)
fails(function() fb[1]={name='water',amount=1} end,'results must be checked')
fails(function() return fb[4] end,'invalid storage index')
e.type='assembling-machine';eq(fb.get_capacity(1),100)
e.fluids_count=0;eq(#fb,0)
fails(function() P.fluid_boxes({type='unsupported'}) end,'unsupported')
-- A native transport write redistributes immediately: applied amount is not its later proportional share.
local pool=0
local transport={type='pipe',valid=true,fluids_count=1}
transport.get_fluid=function() return pool>0 and {name='water',amount=pool/2} or nil end
transport.set_fluid=function(_,f) pool=pool-pool/2+f.amount;return f.amount end
transport.clear_fluid=function() local n=pool/2;pool=pool-n;return {name='water',amount=n} end
local shared=P.fluid_boxes(transport)
eq(P.set_fluid(transport,1,{name='water',amount=50}),50);eq(shared[1].amount,25)
eq(shared.clear(1).amount,25);eq(pool,25)
-- A 2.1 turret exposes its internal firing buffer as another indexed store.
local turret=setmetatable({fluids_count=2,prototype={name='flamer',attack_parameters={fluids={{type='crude-oil'}}}},
 get_fluid_contents=function() return {['crude-oil']=87} end,
 get_fluid=function(i) return i==2 and {name='crude-oil',amount=87} or nil end,
 get_fluid_capacity=function() return 100 end}, {__index=function(_,k) assert(k~='fluidbox','removed fluidbox') end})
local oil=dofile('mod/agent-harness_0.1.0/flameroil.lua')
local amount,capacity=oil.read(turret);eq(amount,87);eq(capacity,200)
-- Existing 2.0 objects stay unchanged; callers do not mistake an empty store for unsupported storage.
script.active_mods.base='2.0.77';local old={fluidbox={{name='water',amount=7}}}
P=dofile('mod/agent-harness_0.1.0/pipes.lua'){}
eq(P.fluid_boxes(old),old.fluidbox);eq(P.set_fluid(old,1,{name='water',amount=12}),12)
eq(P.set_fluid(old,1,nil),0)
local legacy_total=0
old.fluidbox=setmetatable({get_fluid_segment_contents=function() return {water=legacy_total} end},
 {__index=function(_,k) if k==1 then return {name='water',amount=legacy_total/2} end end,
 __newindex=function(_,k,f) assert(k==1);legacy_total=f and f.amount or 0 end})
eq(P.set_fluid(old,1,{name='water',amount=70.25}),70.25);eq(old.fluidbox[1].amount,35.125)
eq(P.set_fluid(old,1,nil),0);eq(legacy_total,0)
print('port21 fluid core: indexed reads/writes, own/segment capacity, prototype arrays, filters, ids and unsupported/empty states passed')
