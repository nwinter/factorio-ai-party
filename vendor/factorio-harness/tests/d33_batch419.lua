-- #2870: a stopped/starved platform has a readable speed, including native negative values.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(s:find(part,1,true),s..' lacks '..part) end
game={tick=0}
local pl={name='Asterion',valid=true,speed=1}
local p={force={platforms={pl}}}
local C=require('conditions'){}
local function condition() return {['until']='platform_speed_above',platform='Asterion',above=0,for_s=1} end
local function sample(c,t,value,record)
  game.tick=t; pl.speed=value
  return C.check(p,c,false,record)
end
-- Both wait records and guard conditions reset on zero, -0 and tiny negatives.
for _,recorded in ipairs({false,true}) do
  for _,zero in ipairs({0,-0.0,-1e-12,-1e-9/60}) do
    local c=condition(); local record=recorded and {} or nil; local h=record or c
    eq(sample(c,0,1,record),false); eq(sample(c,60,1,record),true)
    local met,saw=sample(c,70,zero,record)
    eq(met,false); eq(h.speed_since,nil); eq(h.speed_tick,70)
    eq(h.evidence.speed_kms,0); eq(1/h.evidence.speed_kms,math.huge,'normalized positive zero')
    eq(h.evidence.tick,70); eq(h.evidence.source,'LuaSpacePlatform.speed'); eq(h.evidence.elapsed_s,0)
    has(saw,'source LuaSpacePlatform.speed'); has(saw,'read tick 70')
    eq(sample(c,80,1,record),false); eq(h.speed_since,80)
    eq(sample(c,130,1,record),false); eq(sample(c,140,1,record),true)
  end
end
-- Measured starvation is larger than roundoff: preserve signed evidence, never report a read error.
local c=condition()
eq(sample(c,0,1),false); eq(sample(c,60,1),true)
local native=-0.003368769996856992
eq(sample(c,70,native),false); eq(c.speed_since,nil); eq(c.evidence.speed_kms,native*60)
eq(sample(c,80,1),false); eq(c.speed_since,80)
local function fails(part,setup)
  local c=condition(); sample(c,0,1); sample(c,60,1)
  game.tick=70; setup()
  local ok,err=pcall(C.check,p,c)
  eq(ok,false); has(err,part); has(err,'Asterion at tick 70')
  eq(c.evidence,nil); eq(c.speed_since,nil); eq(c.speed_tick,nil)
  setmetatable(pl,nil); pl.valid=true; p.force.platforms={pl}
  eq(sample(c,80,1),false); eq(c.speed_since,80)
end
fails('missing LuaSpacePlatform.speed field',function() pl.speed=nil end)
fails('platform unavailable: no platform of ours named Asterion',function() p.force.platforms={} end)
fails('platform unavailable',function() pl.valid=false end)
fails('unreadable LuaSpacePlatform.speed: native getter failure',function()
  pl.speed=nil; setmetatable(pl,{__index=function(_,k) if k=='speed' then error('native getter failure',0) end end})
end)
for _,v in ipairs({'0',false,math.huge,-math.huge,0/0,1e308}) do
  fails('unreadable LuaSpacePlatform.speed',function() pl.speed=v end)
end
-- Zero is readable through composite guards too, and a later member may satisfy any.
for _,kind in ipairs({'all','any'}) do
  local a=condition(); a.for_s=0
  pl.speed=0; game.tick=100
  local group={['until']=kind,conditions={a,{['until']='tick_at_least',tick=0}}}
  eq(C.check(p,group),kind=='any'); eq(a.evidence.speed_kms,0)
end
print('d33_batch419: zero, signed starvation, missing/unreadable reads, evidence and duration recovery: ok')
