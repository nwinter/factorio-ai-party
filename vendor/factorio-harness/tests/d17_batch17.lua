-- Run from the harness root: lua tests/d17_batch17.lua
-- d17 batch17 module contracts (the runtime ones are in tests/d17_batch17_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A1: what goes up beside a load: cargo aboard not in the list, and automatic requests on.
do
  defines={inventory={rocket_silo_rocket=21}}
  prototypes={item={['gun-turret']={weight=20000,stack_size=50},['solid-fuel']={weight=1000,stack_size=50},['iron-plate']={weight=1000,stack_size=100}}}
  game={tick=0}
  local cargo={get_contents=function() return {{name='gun-turret',quality='normal',count=1},{name='solid-fuel',quality='normal',count=10}} end}
  local silo={valid=true,use_transitional_requests=true,get_inventory=function(i) if i==21 then return cargo end end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local up=R.goes_up_with(silo,{{name='solid-fuel',quality='normal',count=10}})
  eq(up.foreign,'gun-turret 1')
  has(up.auto_requests,'automatic requests are on')
  has(up.line,'aboard and not in this load, goes up with it: gun-turret 1; automatic requests are on')
  silo.use_transitional_requests=false
  up=R.goes_up_with(silo,{{name='gun-turret',count=1},{name='solid-fuel',count=10}})
  eq(up.line,nil,'nothing foreign, requests off')
end
print('d17_batch17 A1 what goes up with a load: ok')
