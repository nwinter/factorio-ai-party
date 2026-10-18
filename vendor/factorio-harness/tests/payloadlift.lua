-- A minimum payload heavier than a rocket lifts (batch28 A3, Sol request1001: a railgun turret min 4 silently stopped
-- construction): refused by min_payload, requests and platform_bom's min_payload map, naming the most that fits.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={space_platform_state={},rocket_silo_status={},inventory={hub_main=1}}
prototypes={item={['railgun-turret']={weight=500000},['iron-plate']={weight=1000}},utility_constants={rocket_lift_weight=1000000},
  space_location={nauvis={}}}
game={tick=0,forces={}}
local MP=require('minpayload'){}
fails(function() MP.handler({force={platforms={}}},{set={['railgun-turret']=4}}) end,'set railgun-turret 4: 4 weigh 2000 kg, a rocket lifts 1000 kg: at most 2 fit (set 2)')
local secs={sections_count=0,get_section=function() return nil end}
local pl={valid=true,index=1,name='Kestrel',hub={valid=true,get_logistic_sections=function() return secs end},space_location={name='nauvis'}}
local B=require('platbom'){platform=function() return pl end,state=function() return {} end}
fails(function() B.request({force={name='player'}},{request=true,min_payload={['railgun-turret']=3}},pl) end,'min_payload railgun-turret 3: 3 weigh 1500 kg, a rocket lifts 1000 kg: at most 2 fit (min_payload 2)')
local S=require('space'){integer=function(v,d) return v or d end}
fails(function() S.check_requests({},{platform='Kestrel',set={{item='railgun-turret',min=4,min_payload=4,from='nauvis'}}},'hub',nil,secs) end,
  'min_payload railgun-turret 4: 4 weigh 2000 kg, a rocket lifts 1000 kg: at most 2 fit (min_payload 2)')
-- what fits passes
assert(pcall(S.check_requests,{},{platform='Kestrel',set={{item='railgun-turret',min=4,min_payload=2,from='nauvis'}}},'hub',nil,secs))
print('payloadlift: ok')
