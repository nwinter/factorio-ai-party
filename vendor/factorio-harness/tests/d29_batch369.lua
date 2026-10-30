-- A Lua error is catchable; the real invalid bound method SIGSEGV is not. Count every attempted invalid call.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local D=require('budgetrates')
defines={wire_connector_id={circuit_red=1,circuit_green=2}}
local invalid_calls,finds=0,0
local function entity(unit,limit)
  local e={valid=true,name='transport-belt',unit_number=unit,position={x=unit,y=0},status=1}
  e.cb={circuit_enable_disable=true,circuit_condition={first_signal={name='rocket'},constant=limit,comparator='<',fulfilled=false}}
  e.get_control_behavior=function()
    if not e.valid then invalid_calls=invalid_calls+1; error('would SIGSEGV in Factorio 2.0.77') end
    return e.cb
  end
  e.get_circuit_network=function() return {} end
  return e
end
local old=entity(1,2400)
local current={old}
local pl={index=369,force={},surface={
  find_entities_filtered=function() finds=finds+1; return {table.unpack(current)} end,
  count_entities_filtered=function() return #current end}}
local function read(t) return D.gates(pl,{rocket=true},t).rocket.conditions end
assert(read(100)[1].condition.constant==2400)
old.cb.circuit_condition.constant=2300
assert(read(101)[1].condition.constant==2300 and finds==1,'warm reads must read current conditions')
old.valid=false
current={entity(2,2500)}
local replaced=read(102)
assert(invalid_calls==0,'never invoke a destroyed entity, even under pcall')
assert(finds==2 and #replaced==1 and replaced[1].entity=='transport-belt')
assert(replaced[1].unit_number==2 and replaced[1].condition.constant==2500,'same-count replacement supplies fresh facts')
assert(read(103)[1].condition.constant==2500 and finds==2)
current[1].valid=false; current={}
assert(#read(104)==0 and invalid_calls==0,'removed gates disappear without calling stale methods')
current={entity(3,2600),entity(4,2700)}
assert(#read(105)==2 and finds==4,'added gates included')
-- A late join rebuilds this read-only cache and sees the same current gate facts.
local cold=dofile('mod/agent-harness_0.1.0/budgetrates.lua').gates(pl,{rocket=true},105).rocket.conditions
local warm=read(105)
assert(#cold==#warm and cold[1].unit_number==warm[1].unit_number and cold[2].condition.constant==warm[2].condition.constant)
print('d29_batch369: invalid entities never called; same-count replacement, live conditions, removal, addition and cold peer agree: ok')
