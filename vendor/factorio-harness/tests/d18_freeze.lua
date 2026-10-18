-- d18 freeze (operator 03:56 and 03:58: world n froze twice on inspect {platform, area, compact} on Kestrel II).
-- Run from the harness root: lua tests/d18_freeze.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- Belts reading entire_belt_hold on one network: circuits.read runs belt_segment once for the belt read, and
-- belt_segment names the other readers from their settings without reading them again (it called M.read on each,
-- which ran belt_segment on each, without end for two or more).
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2,combinator_output_red=3,combinator_output_green=4},
    control_behavior={type={transport_belt=7},transport_belt={content_read_mode={pulse=0,hold=1,entire_belt_hold=2}}}}
  local belts,conns={},{}
  for i=1,3 do
    local b={valid=true,unit_number=10+i,name='transport-belt',type='transport-belt',position={x=i+0.5,y=0}}
    local l={id='A',get_contents=function() return {} end}; l.line_equals=function(o) return o.id==l.id end
    b.get_transport_line=function() return l end
    b.belt_neighbours={inputs={},outputs={}}
    local cb={type=7,read_contents=true,read_contents_mode=i==3 and 1 or 2}
    b.get_control_behavior=function() return cb end
    b.get_circuit_network=function(w) return w==2 and {network_id=5,signals={}} or nil end
    local c={owner=b,wire_connector_id=2,connections={}}
    b.get_wire_connector=function(w) return w==2 and c or nil end
    belts[i]=b; conns[i]=c
  end
  for i=1,3 do for j=1,3 do if i~=j then table.insert(conns[i].connections,{target=conns[j]}) end end end
  local C=dofile('mod/agent-harness_0.1.0/circuits.lua'){}
  local real,n=C.belt_segment,0
  C.belt_segment=function(e) n=n+1; return real(e) end
  local r=C.read(belts[1])
  eq(n,1,'belt_segment calls')
  has(r.belt_segment,'belts reading their contents on those networks: transport-belt (1.5,0) (this belt) entire_belt_hold, transport-belt (2.5,0) entire_belt_hold, transport-belt (3.5,0) hold')
  eq(#r.belt_readers,3)
  -- a belt_segment that fails leaves the next read free to run one
  C.belt_segment=function() error('boom') end
  assert(not pcall(C.read,belts[2]))
  C.belt_segment=function(e) n=n+1; return real(e) end
  n=0; C.read(belts[2]); eq(n,1,'after a failure')
end
print('d18_freeze belt readers: ok')
