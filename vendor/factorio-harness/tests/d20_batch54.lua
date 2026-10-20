-- Run from repository root: lua tests/d20_batch54.lua
-- d20 batch54 N1 (viewer Aurora, shift46 12:25: "Could fuel alerts show time since departure and compare the existing
-- 60/180-second samples? K2's warning cleared without edits").
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end

-- N1: the fuel outlook flying says how long since the platform left its stop and the engine's 60 and 180 s samples
-- side by side, with the part of each sample spent at the stop before it left.
do
  defines={flow_precision_index={one_minute=1},entity_status={working=1}}
  -- At the stop until 140 s (tanks full, nothing used or made), then 8000/min used and 1500/min made of each fluid.
  local DEP=140
  local function burned(t) return t>DEP and (t-DEP)*8000/60 or 0 end
  local function made(t) return t>DEP and (t-DEP)*1500/60 or 0 end
  local now=0
  local fb={{name='thruster-fuel',amount=25000},{name='thruster-oxidizer',amount=25000}}
  setmetatable(fb,{__len=function() return 2 end})
  fb.get_filter=function(i) return {name=i==1 and 'thruster-fuel' or 'thruster-oxidizer'} end
  local thruster={valid=true,type='thruster',fluidbox=fb}
  local surface={find_entities_filtered=function(f)
    if f.type=='thruster' or type(f.type)=='table' then return {thruster} end
    return {} end}
  local stats={get_output_count=function() return burned(now) end,get_input_count=function() return made(now) end,
    get_flow_count=function(a) return a.category=='input' and 1500 or 8000 end}
  local force={get_fluid_production_statistics=function() return stats end}
  local pl={index=4,name='Kestrel II',surface=surface,force=force,speed=50/60,space_connection={}}
  local store={}
  local EN=require('engine'){state=function() return store end}
  for t=0,180 do
    now=t
    local left=25000-math.max(0,burned(t)-made(t))
    fb[1].amount,fb[2].amount=left,left
    EN.sample(pl,t*60)
  end
  game={tick=180*60}
  local segs={{kind='stop',at='aquilo',start=0,['end']=DEP*60},{kind='leg',from='aquilo',to='gleba',start=DEP*60}}
  local E=require('endurance'){leg=function() return {from='aquilo',to='gleba',left_km=28000} end,segments=function() return segs end,
    engine=function(p) return EN.read(p) end}
  local o=E.fuel_outlook(pl)
  eq(o.short and o.short[1],"thruster-fuel",o.line)
  eq(o.since_departure_s,40)
  eq(o.samples[1].seconds,60); eq(o.samples[1].at_stop_s,20); eq(o.samples[2].seconds,180); eq(o.samples[2].at_stop_s,140)
  eq(o.samples[1].fluids['thruster-fuel'].used_per_min,5333); eq(o.samples[2].fluids['thruster-fuel'].used_per_min,1778)
  eq(o.since_line,'left aquilo 0m40s ago; samples last 60 s (20 s of it at the stop before it left): thruster-fuel used 5333/min, made 1000/min, '
    ..'thruster tanks 25000 -> 20667, thruster-oxidizer used 5333/min, made 1000/min, thruster tanks 25000 -> 20667 | last 180 s (140 s of it '
    ..'at the stop before it left): thruster-fuel used 1778/min, made 333/min, thruster tanks 25000 -> 20667, thruster-oxidizer used 1778/min, '
    ..'made 333/min, thruster tanks 25000 -> 20667')
  -- the outlook's own line stays as it was (platform_endurance and platform_digest read it)
  eq(o.line:find('left aquilo',1,true),nil)
  -- a leg first seen under way (the runtime loaded mid-flight): its start is when it was first seen, said so
  segs[2].partial=true
  has(E.fuel_outlook(pl).since_line,'under way 0m40s since first seen (the departure was before the runtime counted); samples last 60 s: ')
  segs[2].partial=nil
  -- stopped: no departure line
  segs[2]['end']=game.tick; segs[3]={kind='stop',at='gleba',start=game.tick}
  eq(E.since_departure(pl),nil)
  -- no engine samples yet
  segs[3]=nil; segs[2]['end']=nil
  local E2=require('endurance'){leg=function() return {from='aquilo',to='gleba',left_km=28000} end,segments=function() return segs end}
  eq(E2.since_departure(pl).line,'left aquilo 0m40s ago; no engine samples yet')
  defines,game=nil,nil
end
print('d20_batch54 N1 fuel alert since departure: ok')
