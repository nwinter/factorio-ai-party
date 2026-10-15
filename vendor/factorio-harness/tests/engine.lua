-- Run from repository root: lua tests/engine.lua
-- Astra, 21:20: the instant speed looked settled at 38, 18 and 30 km/s and then rose to 55 under the same throttle;
-- three tuning rounds went by it. A platform's flight over the last 60 and 180 s, sampled once a game second.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={working=1,no_input_fluid=2}}
local used,made={['thruster-fuel']=0,['thruster-oxidizer']=0},{['thruster-fuel']=0,['thruster-oxidizer']=0}
local stats={get_output_count=function(n) return used[n] or 0 end,get_input_count=function(n) return made[n] or 0 end}
local finds=0
local thrusters,pumps={},{}
local surface={find_entities_filtered=function(f) finds=finds+1; return f.type=='thruster' and thrusters or pumps end}
local force={get_fluid_production_statistics=function(s) assert(s==surface); return stats end}
local pl={valid=true,index=1,name='Sunward',surface=surface,force=force,speed=0}
force.platforms={pl}
game={forces={player=force}}
-- A thruster's two input boxes: fuel and oxidizer, as LuaFluidBox reads them.
local function thruster(fuel,ox)
  local boxes={{name='thruster-fuel',amount=fuel},{name='thruster-oxidizer',amount=ox}}
  local fb=setmetatable({get_filter=function(i) return {name=boxes[i].name} end},{__len=function() return 2 end,__index=function(_,k) return boxes[k] end})
  return {valid=true,fluidbox=fb,boxes=boxes}
end
thrusters={thruster(1000,1000),thruster(1000,1000)}
pumps={{valid=true,status=1},{valid=true,status=2}}
local st={}
local E=dofile('mod/agent-harness_0.1.0/engine.lua'){state=function() return st end}
local tick=0
local function second(speed,fuel,ox)
  tick=tick+60
  pl.speed=speed/60
  used['thruster-fuel']=used['thruster-fuel']+fuel; used['thruster-oxidizer']=used['thruster-oxidizer']+ox
  made['thruster-fuel']=made['thruster-fuel']+fuel/2
  E.tick(tick)
end
eq(E.read(pl),nil,'no samples yet')
-- 120 s at 38 km/s burning 10 fuel and 12 oxidizer a second, then 60 s climbing to 55 at 20 and 24, the oxidizer
-- tanks draining; one of two pumps working throughout.
for _=1,121 do second(38,10,12) end
for i=1,60 do
  second(38+17*i/60,20,24)
  for _,t in ipairs(thrusters) do t.boxes[2].amount=t.boxes[2].amount-5 end
end
local r=E.read(pl)
eq(#r.lines,2)
eq(r.lines[1],'last 60 s: speed mean 46.5 km/s (lowest 38, highest 55; 38 -> 55); thruster-fuel used 1200, made 600, thruster tanks 2000 -> 2000; '
  ..'thruster-oxidizer used 1440, made 0, thruster tanks 2000 -> 1410; 2 pumps working 50% of the time')
local w180=r.windows[2]
eq(w180.seconds,180); eq(w180.speed_first,38); eq(w180.fluids['thruster-fuel'].used,10*120+20*60)
eq(finds,8,'thrusters and pumps found again each minute')
-- A short history says how long it covers; a platform gone loses its record.
st.engine={}; tick=tick+60
second(30,1,1); second(31,1,1); second(32,1,1)
r=E.read(pl)
eq(#r.lines,1); eq(r.lines[1]:match('^[^;]*'),'last 2 s (sampled that long): speed mean 31 km/s (lowest 30, highest 32')
force.platforms={}
E.tick(tick+60)
eq(st.engine[1],nil)
print('engine: ok')
