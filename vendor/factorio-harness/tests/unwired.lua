-- Run from repository root: lua tests/unwired.lua
-- d20 batch65 AA8 (Astra 19:02: place_ghosts took an inserter's enable condition with no wire planned; inspect later said
-- the game ignored it): circuits.lua signal_needs (circuit_set arguments and a blueprint's control_behavior) and
-- unwired_plan (a call's entries: its own wires, another entry's wire to it, one on what stands there).
-- Read on a private copy (2.0.77) with no red or green wire: an enable condition ignored, the inserter ran; set filters,
-- stack size, recipe and requests kept the entity's own.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(t,part) assert(t and tostring(t):find(part,1,true),tostring(t)..' lacks '..part) end
defines={control_behavior={type={inserter=1}},wire_connector_id={circuit_red=1,circuit_green=2,combinator_output_red=3,combinator_output_green=4}}
prototypes={entity={['fast-inserter']={type='inserter',tile_width=1,tile_height=1},['assembling-machine-2']={type='assembling-machine',tile_width=3,tile_height=3},
    ['requester-chest']={type='logistic-container',tile_width=1,tile_height=1},['train-stop']={type='train-stop',tile_width=2,tile_height=2},
    ['wooden-chest']={type='container',tile_width=1,tile_height=1}},
  item={['iron-plate']={},['fast-inserter']={place_result={name='fast-inserter'}}},fluid={},virtual_signal={['signal-check']={}}}
local C=require('circuits'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end}
-- what needs a signal
local n=C.signal_needs('fast-inserter',{enable='signal-check > 0'})
eq(#n,1); eq(n[1],'its enable condition signal-check > 0: the game ignores this condition and the fast-inserter runs')
n=C.signal_needs('fast-inserter',{enable={signal='iron-plate',comparator='<',value=100},settings={circuit_set_filters=true,circuit_set_stack_size=true}})
eq(#n,3); eq(n[1],'its enable condition iron-plate < 100: the game ignores this condition and the fast-inserter runs')
eq(n[2],'set filters: the game keeps its own filters'); eq(n[3],'set stack size: the game keeps its own hand size')
eq(#C.signal_needs('fast-inserter',{read={hand=true},logistic='iron-plate < 5'}),0,'reads and a logistic condition need no wire')
eq(#C.signal_needs('fast-inserter',{remove_condition=true}),0)
has(C.signal_needs('fast-inserter',{switch_off=true})[1],'switch_off): the game ignores this condition and the fast-inserter runs')
eq(C.signal_needs('assembling-machine-2',{settings={circuit_set_recipe=true}})[1],'set recipe: the game keeps its own recipe')
eq(C.signal_needs('requester-chest',{set_requests=true})[1],'set requests: the game keeps its own requests')
eq(C.signal_needs('requester-chest',{enable='iron-plate > 0'})[1],'its enable condition iron-plate > 0: the game ignores this condition')
eq(C.signal_needs('train-stop',{settings={set_trains_limit=true}})[1],'set trains limit: no signal reaches it')
-- a blueprint's control_behavior, as 2.0.77 writes it
n=C.signal_needs('fast-inserter',{circuit_enabled=true,circuit_condition={first_signal={type='virtual',name='signal-check'},comparator='>',constant=0},circuit_set_filters=true},true)
eq(n[1],'its enable condition signal-check > 0: the game ignores this condition and the fast-inserter runs'); eq(n[2],'set filters: the game keeps its own filters')
eq(C.signal_needs('assembling-machine-2',{set_recipe=true},true)[1],'set recipe: the game keeps its own recipe')
eq(C.signal_needs('requester-chest',{circuit_mode_of_operation=1},true)[1],'set requests: the game keeps its own requests')
eq(#C.signal_needs('wooden-chest',{read_contents=true},true),0)
-- a call's entries: Astra's inserter with no wire planned
local ins={name='fast-inserter',position={x=3.5,y=4.5},circuit={enable='signal-check > 0'}}
local u=C.unwired_plan({ins},nil,true)
eq(u,'fast-inserter (3.5,4.5): no red or green wire connects it (none in this call, none on what stands there): once built, its enable condition signal-check > 0: the game ignores this condition and the fast-inserter runs')
eq(C.unwired_plan({ins},nil,false):find('once built',1,true),nil,'a build says it of the building')
-- its own red wire in the call: none; a copper wire or a disconnect does not count
ins.wires={{to={x=3.5,y=7.5},color='red'}}
eq(C.unwired_plan({ins},nil,true),nil)
ins.wires={{to={x=3.5,y=7.5},color='green',disconnect=true}}
has(C.unwired_plan({ins},nil,true),'fast-inserter (3.5,4.5)')
ins.wires=nil
-- another entry's wire to it (to on its tile; to anywhere on a 3x3 machine)
local cc={name='wooden-chest',position={x=3.5,y=7.5},wires={{to={x=3.5,y=4.5},color='green'}}}
eq(C.unwired_plan({ins,cc},nil,true),nil)
local am={name='assembling-machine-2',position={x=10.5,y=0.5},circuit={settings={circuit_set_recipe=true}}}
local cc2={name='wooden-chest',position={x=13.5,y=0.5},wires={{to={x=11.5,y=1.5},color='red'}}}
eq(C.unwired_plan({am,cc2},nil,true),nil)
cc2.wires={{to={x=12.5,y=1.5},color='red'}}
has(C.unwired_plan({am,cc2},nil,true),'assembling-machine-2 (10.5,0.5): no red or green wire connects it (none in this call, none on what stands there): once built, set recipe: the game keeps its own recipe')
-- a wire on what stands there already
eq(C.unwired_plan({ins},function(name,pos) return name=='fast-inserter' and pos.x==3.5 end,true),nil)
-- a build entry by item; a blueprint entity's precomputed needs
has(C.unwired_plan({{item='fast-inserter',position={x=1.5,y=1.5},circuit={enable='iron-plate > 0'}}},nil,false),'fast-inserter (1.5,1.5)')
has(C.unwired_plan({{name='requester-chest',position={x=2.5,y=2.5},needs={'set requests: the game keeps its own requests'}}},nil,true),'requester-chest (2.5,2.5): no red or green wire connects it (none in this call, none on what stands there): once built, set requests')
-- more than 4: counted
local many={}
for i=1,6 do many[i]={name='fast-inserter',position={x=i+0.5,y=0.5},circuit={enable='iron-plate > 0'}} end
has(C.unwired_plan(many,nil,true),'; +2 more entities')
-- the entry tables are left as they were
eq(ins.__wired,nil); eq(cc.__wired,nil)
print('unwired ok')
