-- d24 batch155 PY2 (viewer Aurora site:4709): "Train 46 stalled with front fuel 0, rear 147. Could summaries show each
-- locomotive's stored and burning fuel, flagging an unfuelled driving end during automatic service?" A locomotive pulls
-- only the way it faces: the train read and train {all} name each locomotive's fuel slots and what burns now, the way
-- the train drives (its speed, else its path's start), and, in automatic mode, a locomotive facing that way with none.
-- Run from the harness root: lua tests/d24_batch155.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

defines={train_state={on_the_path=0,wait_station=1,no_path=3,manual_control=9}}
prototypes={item={['solid-fuel']={fuel_value=12e6},coal={fuel_value=4e6}}}
local T=dofile('mod/agent-harness_0.1.0/trains.lua'){}

local unit=100
local function loco(x,fuel,left,burning)
  unit=unit+1
  return {valid=true,unit_number=unit,position={x=x,y=219},get_fuel_inventory=function() return {get_contents=function() return fuel end} end,
    burner={remaining_burning_fuel=left or 0,currently_burning=burning and {name={name=burning},quality={name='normal'}} or nil}}
end
-- Train 46 as it stalled: carriage 1 faces its front with nothing, carriage 3 faces its back with solid fuel 147 and
-- burning; automatic, on its path from its front, standing still.
local function train46(t)
  local front,back=loco(68,{},0),loco(81.8,{{name='solid-fuel',quality='normal',count=147}},7.9e6,'solid-fuel')
  t.id=46; t.manual_mode=t.manual_mode or false; t.speed=t.speed or 0
  t.locomotives={front_movers={front},back_movers={back}}
  t.carriages={{unit_number=front.unit_number},{unit_number=1},{unit_number=back.unit_number}}
  t.front_stock=front  -- carriages: other objects than locomotives' (as the engine gives each read)
  t.path=t.path or {valid=true,is_front=true}
  t.schedule={current=1,records={{station='SE Supply'}}}
  t.get_contents=function() return {{name='steel-plate',count=507}} end
  t.get_fluid_contents=function() return {} end
  return t
end
local v=T.train_view(train46({state=0}))
eq(v.fuel[1],"(68,219) carriage 1, faces the train's front (the way it drives): no fuel; nothing burning")
eq(v.fuel[2],"(81.8,219) carriage 3, faces the train's back: solid-fuel 147 (1764 MJ); burning solid-fuel, 7.9 MJ left")
eq(v.driving,'toward its front (its path starts from its front)')
eq(v.fuel_flag,'automatic, driving toward its front: no fuel in the locomotive facing that way at carriage 1; 0 of 1 facing that way have fuel')
eq(v.why,'stands still: no fuel in the locomotive facing the way it drives (toward its front: carriage 1)')

-- Moving toward its back: the rear locomotive pulls, so nothing is flagged.
v=T.train_view(train46({state=0,speed=-0.4,path={valid=false}}))
eq(v.driving,'toward its back (moving)'); eq(v.fuel_flag,nil)
has(v.fuel[2],'faces the train\'s back (the way it drives): solid-fuel 147')
-- Manual mode: the fuel lines, no flag.
v=T.train_view(train46({state=9,manual_mode=true}))
eq(v.fuel_flag,nil); eq(v.why,'manual mode'); has(v.fuel[1],'no fuel; nothing burning')
-- At a stop with no path yet: the way it will drive is not known, so no flag.
v=T.train_view(train46({state=1,path={valid=false}}))
eq(v.driving,nil); eq(v.fuel_flag,nil)

-- train {all}: each locomotive's fuel in the row and line, and the flag.
game={tick=0,train_manager={get_trains=function() return {train46({state=0})} end},get_surface=function(n) return {name=n} end}
local r=T.handlers.train({surface={name='nauvis'},force={}},{all=true})
eq(r.trains[1].fuel[1],'1 faces front: no fuel'); eq(r.trains[1].fuel[2],'3 faces back: solid-fuel 147, burning 7.9 MJ left')
eq(r.lines[1],'train 46 (68,219): on_the_path, stop 1 of 1: SE Supply, 0 km/h; locomotives [1 faces front: no fuel | 3 faces back: solid-fuel 147, burning 7.9 MJ left]'
  ..' (automatic, driving toward its front: no fuel in the locomotive facing that way at carriage 1; 0 of 1 facing that way have fuel); steel-plate*507')
has(r.trains[1].fuel_flag,'no fuel in the locomotive facing that way at carriage 1')
game=nil
print('d24_batch155 PY2 locomotive fuel: ok')
