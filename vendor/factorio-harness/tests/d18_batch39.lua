-- d18 batch39. Run from the harness root: lua tests/d18_batch39.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- B1 (Astra 138h31: silo read ready and not launched, last launch 3 min ago, while shipment showed 1000 cryo launched 32 s
-- before; the journal: the silo read came 14 s before that launch). Both lines name the launch by its ledger id and tick,
-- and the silo line says the tick it was read.
do
  defines={rocket_silo_status={building_rocket=0,rocket_ready=7},inventory={cargo_unit=1},cargo_destination={invalid=0,orbit=1,station=2,surface=3,space_platform=4}}
  game={tick=1000}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end}
  local L=dofile('mod/agent-harness_0.1.0/ledger.lua'){state=function() return st end}
  local surface={name='aquilo'}
  local silo={valid=true,unit_number=77,name='rocket-silo',surface=surface,position={x=17.5,y=-13.5},rocket_silo_status=7,rocket_parts=0,
    prototype={rocket_parts_required=50}}
  local pod={get_inventory=function() return {get_contents=function() return {{name='cryogenic-science-pack',count=1000}} end} end,cargo_pod_destination={type=1}}
  local event={rocket_silo=silo,rocket={attached_cargo_pod=pod}}
  local id=L.on_launch(event)
  eq(id,1)
  event.harness_up=id
  game.tick=1600
  S.on_launch_ordered(event)
  game.tick=3520
  local r=S.rocket(silo)
  has(r.last,'last launch 32s ago (up #1, tick 1600)')
  eq(r.last_launch.up,1); eq(r.read_tick,3520)
  defines,game=nil,nil
end
print('d18_batch39 B1 silo and shipment name the same launch: ok')
