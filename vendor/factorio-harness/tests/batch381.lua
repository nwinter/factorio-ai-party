package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,p) assert(s:find(p,1,true),s..' lacks '..p) end
local function fails(fn,p) local ok,err=pcall(fn); assert(not ok); has(tostring(err),p) end
local force={name='player',is_chunk_visible=function() return true end,is_chunk_charted=function() return true end}
local surface={name='test',index=1,find_entities_filtered=function() return {} end}
game={tick=0,forces={player=force},get_surface=function() return surface end}
defines={wire_connector_id={circuit_red=1,circuit_green=2},entity_status={disabled_by_control_behavior=55},inventory={crafter_input=1,assembling_machine_input=1}}
local function belt(x,item)
  local e={valid=true,name='transport-belt',type='transport-belt',unit_number=x+1,position={x=x,y=0},direction=4,surface=surface,force=force,
    bounding_box={left_top={x=x-0.5,y=-0.5},right_bottom={x=x+0.5,y=0.5}},prototype={belt_speed=0.03125},belt_neighbours={inputs={},outputs={}}}
  e.lines={}
  for k=1,2 do
    local l={owner=e,line_length=1,output_lines={}}
    l.get_detailed_contents=function() return {{unique_id=x*10000+k*1000+math.floor(game.tick/32),position=0.25,stack={valid_for_read=true,name=item,count=1}}} end
    l.get_contents=function() return {{name=item,count=1}} end
    l.can_insert_at_back=function() return false end
    l.line_equals=function(other) return other==l end
    e.lines[k]=l
  end
  e.get_transport_line=function(k) return e.lines[k] end
  e.get_max_transport_line_index=function() return 2 end
  return e
end
local a,b=belt(1,'iron-plate'),belt(20,'copper-plate')
local state={}; local p={index=1,valid=true,force=force}
local api={state=function() return state end,remote_entity=function(_,args) return args.position.x==1 and a or b end}
local S=require('beltsample')(api)
local one=S.handler(p,{position=a.position,seconds=20})
local two=S.handler(p,{position=b.position,exact_tile=true,seconds=2})
assert(one.id~=two.id); eq(S.handler(p,{id=one.id}).id,one.id)
local three=S.handler(p,{position=a.position,seconds=20})
local four=S.handler(p,{position=b.position,seconds=20})
fails(function() S.handler(p,{position=a.position,seconds=20}) end,'all 4 watch slots')
eq(S.handler(p,{}).id,four.id)
fails(function() S.handler({index=2},{id=one.id}) end,'not retained for this agent')
for t=1,130 do game.tick=t; S.tick(t) end
local r=S.handler(p,{id=two.id}); eq(r.id,two.id); assert(r.done); has(r.left.items,'copper-plate')
local W=require('measures'){state=api.state}
eq(#W.list(1),4); assert(W.running(1))
local five=S.handler(p,{position=a.position,seconds=20})
eq(five.evicted_id,two.id); has(five.warning,two.id)
fails(function() S.handler(p,{id=two.id}) end,'unknown or evicted')
eq(S.handler(p,{id=one.id}).sampling,true)
-- Reloads retain IDs and each result; invalid starts do not evict a completed result.
S=require('beltsample')(api)
eq(S.handler(p,{id=one.id}).id,one.id)
for t=131,1400 do game.tick=t; S.tick(t) end
has(S.handler(p,{id=one.id}).points[1].left.items,'iron-plate')
has(S.handler(p,{id=four.id}).points[1].left.items,'copper-plate')
fails(function() S.handler(p,{position=a.position,seconds=1}) end,'seconds:')
eq(S.handler(p,{id=one.id}).id,one.id)
-- An edit splits only the affected watch, with the same ID, even when it is not latest.
state={}; game.tick=2000
one=S.handler(p,{position=a.position,seconds=20}); two=S.handler(p,{position=b.position,seconds=20})
for _,j in ipairs(require('beltwatches').list(state,'belt_flow',1)) do j.call={action='belt_flow',args={position=j.id==one.id and a.position or b.position,seconds=20}} end
local X=require('mixed'){state=api.state,player=function() return p end,read={belt_flow=S.finish},call=function(_,_,args) return S.handler(p,args) end}
game.tick=2300; S.tick(game.tick); eq(X.edit(a,'rotate by test'),1)
local original=require('beltwatches').find(state,1,one.id)
eq(original.start,2300); eq(original.id,one.id); eq(#original.mixed.parts,1)
eq(require('beltwatches').find(state,1,two.id).start,2000)
do
  local old={start=87000000,result={}}
  local newer={serial=1,result={}}
  eq(require('beltwatches').room({belt_flow={[1]=newer},belt_flow_kept={[1]={old,{serial=2},{serial=3}}}},1),old)
end
-- Native connections detect a two-lane-to-one merge even when both lanes carry the same item or are empty.
local dest=belt(3,'iron-plate'); dest.belt_neighbours.inputs={a}
a.lines[1].output_lines={dest.lines[2]}; a.lines[2].output_lines={dest.lines[2]}
a.lines[1].get_detailed_contents=function() return {{position=0.8,stack={valid_for_read=true,name='coal',count=1}},{position=0.1,stack={valid_for_read=true,name='iron-plate',count=2}}} end
local i={valid=true,unit_number=90,name='inserter',position={x=3,y=1},status='waiting_for_space_in_destination',pickup_position=dest.position,drop_position={x=3,y=2},pickup_target=dest,pickup_from_left_lane=false,pickup_from_right_lane=true,held_stack={valid_for_read=true,name='iron-plate',count=2},get_circuit_network=function() return {} end}
local C={conditions=function() return {enable='signal-A > 0',enable_met=false,logistic='iron-plate < 5',logistic_met=true} end,condition_parts=function() return {'signal-A 0; false now','iron-plate 2; true now'} end}
local F=require('lanefacts'){status_name=function(e) return e.status end,circuits=function() return C end,lane_near=function() return 2 end,is_belt=function() return true end}
local facts=F.read({{tiles={dest}}},function() return {by_pick={[dest.unit_number]={{e=i}}},by_drop={}} end)
eq(#facts.side_loads,1); eq(facts.side_loads[1].destination_lane.index,2)
eq(facts.side_loads[1].source_lanes[1].front.name,'iron-plate')
eq(facts.side_loads[1].source_lanes[1].items,3)
eq(facts.inserters[1].near_lane,'right'); eq(facts.inserters[1].far_lane,'left')
eq(facts.inserters[1].pickup_from_left_lane,false); eq(facts.inserters[1].controls.enable_met,false)
eq(facts.belts[1].controls.logistic_met,true); eq(facts.belts[1].lanes[2].can_insert_at_back,false)
facts=F.read({{tiles={dest}}},function() return {by_pick={[dest.unit_number]={{e=i}}},by_drop={}} end,function(q) return q==dest.position end)
eq(#facts.inserters,0); eq(#facts.side_loads,0)
-- An inserter with no native target still has a pickup point on the belt footprint.
i.pickup_target=nil; i.status='disabled_by_control_behavior'
facts=F.read({{tiles={dest}}},function() return {by_pick={},by_drop={},by_pick_tile={['3,0']={{e=i}}}} end)
eq(#facts.inserters,1); eq(facts.inserters[1].status,'disabled_by_control_behavior'); eq(facts.inserters[1].pickup_target,nil)
-- Native input counts retain recipe quality; fluid-only inputs do not invent missing item counts.
local arms={}
local m={type='assembling-machine',force=force,status='item_ingredient_shortage',bounding_box={left_top={x=0,y=0},right_bottom={x=3,y=3}},surface={find_entities_filtered=function() return arms end},get_recipe=function() return {},{name='rare'} end,
  get_inventory=function() return {get_item_count=function(q) eq(q.quality,'rare'); return 0 end} end,get_fluid_count=function() return 10 end}
local P=require('makerinput'){status_name=function(e) return e.status end}
local recipe={ingredients={{name='iron-plate',type='item'},{name='water',type='fluid'}}}
r=P.read(m,recipe); eq(r.input_inserters,0); eq(#r.missing,1); has(r.line,'no input inserter or loader'); has(r.line,'input holds none of: iron-plate')
arms={{type='loader',loader_container=m,loader_type='input'},{type='inserter',drop_position={x=1,y=1}},{type='inserter',pickup_target=m}}
r=P.read(m,recipe); eq(r.input_loaders,1); eq(r.input_inserters,1); eq(r.output_inserters,1)
m.status='full_output'; eq(P.read(m,recipe).status,'full_output')
-- Wildcard fulfillment is native; a numeric get_signal(wildcard) is not its current value.
local Circuits=require('circuits'){}
local parts=Circuits.condition_parts({status=55,get_circuit_network=function() error('wildcards have no scalar count') end},
  {enable='signal-everything = 0',enable_met=false}, {circuit_condition={first_signal={type='virtual',name='signal-everything'},constant=0}})
has(parts[1],'false now'); assert(not parts[1]:find('on its wires',1,true))
print('batch381: independent watches, bounds, reload, edit split, native lanes/controls and maker inputs ok')
